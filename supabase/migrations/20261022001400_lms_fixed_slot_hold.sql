-- =====================================================================
-- 재등록 대기 자리 맡아 두기 (정책 원본 A22 · POL-RN-02, 2026-10-22 대표 '넣어', 마감 오후 11:59 확인)
--  - 수업 중인 학생의 고정 시간(regular_schedules)은 그 학생의 마지막 수강 종료일 23:59 KST까지
--    종료일 '뒤' 날짜에서도 다른 학생에게 배정하지 않는다 (재등록하면 같은 시간 유지, POL-RN-03)
--  - 종료일 안쪽은 실제 수업(lessons)이 이미 막고 있으므로, 여기서는 종료일 다음 날부터만 계산
--  - 마감(종료일 23:59)이 지나면 자동으로 풀림. 재등록하면 새 등록의 수업·종료일 기준으로 다시 계산
--  - 대상: 결제 확인·수강 중(confirmed·active) 등록이 있는 학생. 결제 대기·완료·취소 등록만 있으면 대상 아님
--  - 쓰는 곳: 일정안 충돌(lms_plan_conflicts → 신규 등록·강사 시간 고르기·확정 재검사), 기존 학생 입력(lms_import_conflicts)
--  - 아직 없는 것: 운영자가 '재등록 안 함'으로 미리 푸는 버튼 (필요해지면 추가, 대표 2026-10-22)
-- 기존 표·데이터를 바꾸지 않음 (함수만 교체). 다시 실행해도 같은 결과
-- =====================================================================

-- 강사의 [p_start, p_end) 수업 후보가 재등록 대기 중인 고정 시간과 겹치거나 휴식 10분 안인지
create or replace function lms_slot_hold_hits(p_tutor uuid, p_start timestamptz, p_end timestamptz)
returns table (student_id uuid, student_name text, hold_end date, o0 timestamptz, o1 timestamptz)
language sql stable security definer set search_path = public as $$
  with last_end as (
    select e.student_id, max(e.final_end_date) as end_date
    from enrollments e
    where e.status in ('confirmed', 'active')
    group by e.student_id
  ), day as (
    select ((p_start at time zone 'Asia/Seoul')::date) as d
  )
  select rs.student_id, st.name_ko, le.end_date, x.o0, x.o0 + make_interval(mins => rs.duration_min)
  from regular_schedules rs
  join last_end le on le.student_id = rs.student_id
  join students st on st.id = rs.student_id
  cross join day
  cross join lateral (select ((day.d + rs.start_time_kst) at time zone 'Asia/Seoul') as o0) x
  where rs.tutor_id = p_tutor
    and day.d > le.end_date                                                   -- 종료일 뒤 날짜만 (안쪽은 실제 수업이 막음)
    and extract(dow from day.d)::int = rs.weekday
    and rs.effective_from <= le.end_date and (rs.effective_to is null or rs.effective_to >= le.end_date)
    and now() < ((le.end_date + 1)::timestamp at time zone 'Asia/Seoul')     -- 종료일 23:59 KST까지
    and x.o0 < p_end + interval '10 minutes' and p_start - interval '10 minutes' < x.o0 + make_interval(mins => rs.duration_min)
$$;
revoke all on function lms_slot_hold_hits(uuid, timestamptz, timestamptz) from public, anon, authenticated;

create or replace function lms_plan_conflicts(p_tutor uuid, p_slots jsonb, p_start date, p_end date, p_dur smallint)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_break interval := interval '10 minutes';   -- POL-OP-21 (코드 CONFIRMED.minBreakMin 과 같아야 함)
  d date := p_start;
  s jsonb;
  t0 timestamptz;
  t1 timestamptz;
  out jsonb := '[]'::jsonb;
begin
  while d <= p_end loop
    select x into s from jsonb_array_elements(p_slots) x where (x ->> 'weekday')::int = extract(dow from d);
    if found then
      t0 := (d + (s ->> 'time')::time) at time zone 'Asia/Seoul';
      t1 := t0 + make_interval(mins => p_dur);
      out := out || coalesce((
        select jsonb_agg(jsonb_build_object('date', d, 'time', s ->> 'time', 'reason',
                 case when l.starts_at < t1 and t0 < l.ends_at then (case when l.kind = 'regular' then 'tutor_regular' else 'tutor_makeup' end) else 'break' end,
                 'other_starts_at', l.starts_at, 'other_ends_at', l.ends_at))
        from lessons l
        where l.tutor_id = p_tutor and l.state <> 'canceled'
          and l.starts_at < t1 + v_break and t0 - v_break < l.ends_at), '[]'::jsonb);
      out := out || coalesce((
        select jsonb_agg(jsonb_build_object('date', d, 'time', s ->> 'time', 'reason', 'tutor_time_off',
                 'other_starts_at', o.starts_at, 'other_ends_at', o.ends_at))
        from tutor_time_off o where o.tutor_id = p_tutor and o.starts_at < t1 and t0 < o.ends_at), '[]'::jsonb);
      -- 재등록 대기 중인 다른 학생의 고정 시간 (A22, migration 1400)
      out := out || coalesce((
        select jsonb_agg(jsonb_build_object('date', d, 'time', s ->> 'time', 'reason', 'tutor_hold',
                 'other_starts_at', h.o0, 'other_ends_at', h.o1, 'other', h.student_name, 'hold_end', h.hold_end))
        from lms_slot_hold_hits(p_tutor, t0, t1) h), '[]'::jsonb);
    end if;
    d := d + 1;
  end loop;
  return out;
end $$;
revoke all on function lms_plan_conflicts(uuid, jsonb, date, date, smallint) from public, anon, authenticated;

create or replace function lms_import_conflicts(p jsonb)
returns jsonb
language sql stable security definer set search_path = public as $$
  with c as (select * from lms_import_candidates(p)),
  brk as (select interval '10 minutes' as v),   -- A38 (코드 CONFIRMED.minBreakMin 과 같아야 함)
  hits as (
    -- 같은 강사의 기존 수업: 겹치면 그 수업 종류, 휴식 10분 안이면 break
    select c.n, c.kind, c.kst_date, c.kst_time,
           case when l.starts_at < c.ends_at and c.starts_at < l.ends_at
                then case when l.kind = 'regular' then 'tutor_regular' else 'tutor_makeup' end else 'break' end as reason,
           l.starts_at as o0, l.ends_at as o1, s.name_ko as other
    from c join lessons l on l.tutor_id = c.tutor_id and l.state <> 'canceled'
                         and l.starts_at < c.ends_at + (select v from brk) and c.starts_at - (select v from brk) < l.ends_at
    left join students s on s.id = l.student_id
    union all
    select c.n, c.kind, c.kst_date, c.kst_time, 'tutor_time_off', o.starts_at, o.ends_at, coalesce(o.reason, '휴무')
    from c join tutor_time_off o on o.tutor_id = c.tutor_id and o.starts_at < c.ends_at and c.starts_at < o.ends_at
    union all
    -- 재등록 대기 중인 다른 학생의 고정 시간 (A22, migration 1400)
    select c.n, c.kind, c.kst_date, c.kst_time, 'tutor_hold', h.o0, h.o1, h.student_name || ' · ' || to_char(h.hold_end, 'MM/DD') || ' 23:59까지'
    from c cross join lateral lms_slot_hold_hits(c.tutor_id, c.starts_at, c.ends_at) h
    union all
    -- 이번 입력끼리: 같은 강사면 휴식 10분까지, 다른 강사여도 학생 본인 시간이 겹치면
    select a.n, a.kind, a.kst_date, a.kst_time,
           case when b.starts_at < a.ends_at and a.starts_at < b.ends_at then 'self' else 'break' end,
           b.starts_at, b.ends_at, '이번 입력'
    from c a join c b on a.n <> b.n
      and ((a.tutor_id = b.tutor_id and b.starts_at < a.ends_at + (select v from brk) and a.starts_at - (select v from brk) < b.ends_at)
           or (b.starts_at < a.ends_at and a.starts_at < b.ends_at))
  )
  select coalesce(jsonb_agg(jsonb_build_object('date', kst_date, 'time', kst_time, 'kind', kind, 'reason', reason,
                                               'other_starts_at', o0, 'other_ends_at', o1, 'other', other) order by n), '[]'::jsonb)
  from hits
$$;
revoke all on function lms_import_conflicts(jsonb) from public, anon, authenticated;
