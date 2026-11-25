-- 고르기 창 속도 (11/23): 학생 1명 11회 8.3초 → 0.14초, 시험 DB 14쌍 결과 전과 똑같음 확인. 같은 주 회차는 강사 가능 시간 칸을 한 번만 계산,
-- 가능 시간·휴무·겹침은 함수 호출 대신 표 조인으로 (lms_ttl_conflict 와 같은 규칙, 결과는 전과 같음 — 확정 때는 그대로 lms_ttl_conflict 로 다시 검사)
--  칸 조건 = lms_tutor_location_at(t) = 임시 지역 and lms_tutor_available(t) 와 같은 규칙
--  (lms_tutor_start_ok 현지 06:00~22:30 · tutor_availability(location_id) · tutor_open_once)
create or replace function lms_ttl_week_slots(p_tutor uuid, p_location uuid, p_monday date)
returns setof timestamptz
language sql stable security definer set search_path = public as $$
  select s.t
  from tutor_locations loc,
       lateral (select ((p_monday + d)::timestamp + make_interval(mins => n * 30)) at time zone 'Asia/Seoul' as t
                from generate_series(0, 6) d, generate_series(0, 47) n) s
  where loc.id = p_location and loc.tutor_id = p_tutor
    and s.t > now()
    and (select l.id from tutor_locations l
         where l.tutor_id = p_tutor and l.starts_on <= (s.t at time zone l.timezone)::date
           and (l.ends_on is null or l.ends_on >= (s.t at time zone l.timezone)::date)
         order by l.starts_on desc limit 1) = p_location
    and (s.t at time zone loc.timezone)::time between time '06:00' and time '22:30'
    and (exists (select 1 from tutor_availability a
                 where a.tutor_id = p_tutor and a.location_id = p_location
                   and a.effective_from <= (s.t at time zone a.timezone)::date
                   and (a.effective_to is null or a.effective_to >= (s.t at time zone a.timezone)::date)
                   and extract(dow from (s.t at time zone a.timezone)) = a.weekday
                   and (s.t at time zone a.timezone)::time between a.start_local and a.end_local)
         or exists (select 1 from tutor_open_once o where o.tutor_id = p_tutor and o.starts_at <= s.t and s.t < o.ends_at))
  order by s.t
$$;

create or replace function lms_ttl_options(p_tutor uuid, p_student uuid)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_rows jsonb;
  weekly jsonb;
  need integer;
begin
  with x as materialized (
    select x.*, lms_rc_monday((x.orig_starts_at at time zone 'Asia/Seoul')::date) as wk
    from lms_ttl_rows(p_tutor, p_student) x
    where x.state is null or x.state in ('later', 'returned')
  ), w as materialized (
    select g.tutor_id, g.location_id, g.wk, s.t
    from (select distinct tutor_id, location_id, wk from x) g, lms_ttl_week_slots(g.tutor_id, g.location_id, g.wk) s(t)
  ), hs as materialized (
    select rs.tutor_id, rs.student_id, rs.weekday, rs.start_time_kst, rs.duration_min, le.end_date
    from regular_schedules rs
    join (select e2.student_id, max(e2.final_end_date) as end_date from enrollments e2
          where e2.status in ('confirmed', 'active') group by e2.student_id) le on le.student_id = rs.student_id
    where rs.tutor_id in (select tutor_id from x)
      and rs.effective_from <= le.end_date and (rs.effective_to is null or rs.effective_to >= le.end_date)
      and now() < ((le.end_date + 1)::timestamp at time zone 'Asia/Seoul')
  ), r as materialized (
    select x.*, coalesce((
      select array_agg(w.t order by w.t)
      from w join enrollments e on e.id = x.enrollment_id
      where w.tutor_id = x.tutor_id and w.location_id = x.location_id and w.wk = x.wk
        and (w.t at time zone 'Asia/Seoul')::date between e.start_date and e.final_end_date
        and not exists (select 1 from tutor_time_off o where o.tutor_id = x.tutor_id and o.kind in ('leave', 'block')
                        and o.starts_at < w.t + make_interval(mins => x.minutes) and w.t < o.ends_at)
        and not exists (select 1 from lessons y where y.tutor_id = x.tutor_id and y.state <> 'canceled' and y.id is distinct from x.lesson_id
                        and y.starts_at < w.t + make_interval(mins => x.minutes) + interval '10 minutes' and w.t - interval '10 minutes' < y.ends_at)
        and not exists (select 1 from lessons y where y.student_id = x.student_id and y.id is distinct from x.lesson_id and y.state <> 'canceled'
                        and y.voided_at is null and y.starts_at < w.t + make_interval(mins => x.minutes) and w.t < y.ends_at)
        and not exists (select 1 from temp_location_moves m where m.tutor_id = x.tutor_id and m.state = 'proposed' and m.student_id <> x.student_id
                        and m.new_starts_at is not null
                        and m.new_starts_at < w.t + make_interval(mins => x.minutes) + interval '10 minutes'
                        and w.t - interval '10 minutes' < m.new_starts_at + make_interval(mins => m.minutes))
        and not exists (select 1 from hs
                        cross join lateral (select (((w.t at time zone 'Asia/Seoul')::date + hs.start_time_kst) at time zone 'Asia/Seoul') as o0) h
                        where hs.tutor_id = x.tutor_id and hs.student_id <> x.student_id
                          and (w.t at time zone 'Asia/Seoul')::date > hs.end_date
                          and extract(dow from (w.t at time zone 'Asia/Seoul')::date)::int = hs.weekday
                          and h.o0 < w.t + make_interval(mins => x.minutes) + interval '10 minutes'
                          and w.t - interval '10 minutes' < h.o0 + make_interval(mins => hs.duration_min))
    ), '{}') as cands
    from x
  )
  select coalesce(jsonb_agg(jsonb_build_object('key', r.key, 'orig', r.orig_starts_at, 'minutes', r.minutes, 'state', r.state,
                                               'cands', to_jsonb(r.cands)) order by r.orig_starts_at), '[]'::jsonb),
         (select coalesce(jsonb_agg(jsonb_build_object('dow', w.dow, 'time', w.tm, 'sample', w.sample) order by (w.dow + 6) % 7, w.tm), '[]'::jsonb)
          from (select extract(dow from c at time zone 'Asia/Seoul')::int as dow, to_char(c at time zone 'Asia/Seoul', 'HH24:MI') as tm, min(c) as sample
                from r, unnest(r.cands) c group by 1, 2) w),
         (select coalesce(max(n), 0) from (select count(*) n from r group by r.wk) k)
    into v_rows, weekly, need
  from r;
  return jsonb_build_object('rows', v_rows, 'weekly', weekly, 'need', need,
    'rc_pending', exists (select 1 from regular_change_requests q where q.student_id = p_student and q.status = 'pending'),
    'proposed', exists (select 1 from temp_location_moves m where m.tutor_id = p_tutor and m.student_id = p_student and m.state = 'proposed'));
end $$;

revoke all on function lms_ttl_week_slots(uuid, uuid, date), lms_ttl_options(uuid, uuid) from public, anon, authenticated;
