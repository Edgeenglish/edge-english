-- =====================================================================
-- 강사 가능 시간 = '보통 수업하는 시간' (2026-10-28 대표: 예외가 항상 있음, 그 밖이 무조건 안 되는 뜻이 아님)
--  - 2400에서 가능 시간 밖이면 대체강사로 못 고르게 막은 것을 되돌림: 막는 것은 휴무·다른 수업(휴식 10분)·강사가 불가라고 답한 수업만
--  - 대체강사 목록: free = 보통 시간 안에서 맡을 수 있는 횟수(많은 순), busy_dates = 못 하는 날짜, off_hours = 보통 시간 밖 날짜(골라도 됨)
--  - 기존 강사 보강 가능 날짜 제안은 보통 시간 안에서만
-- 기존 표·데이터를 지우지 않음. 다시 실행해도 같은 결과
-- =====================================================================

create or replace function lms_sub_conflict(p_tutor uuid, p_start timestamptz, p_end timestamptz, p_except_lesson uuid)
returns text
language plpgsql stable security definer set search_path = public as $$
declare
  v_break constant interval := interval '10 minutes';   -- POL-OP-21 (policy.ts CONFIRMED.minBreakMin)
begin
  if exists (select 1 from tutor_time_off o where o.tutor_id = p_tutor and o.starts_at < p_end and p_start < o.ends_at) then
    return '강사 휴무';
  end if;
  if exists (select 1 from lessons x where x.tutor_id = p_tutor and x.state <> 'canceled' and x.id is distinct from p_except_lesson
             and x.starts_at < p_end + v_break and p_start - v_break < x.ends_at) then
    return '강사 다른 수업(휴식 10분 포함)';
  end if;
  return null;
end $$;
revoke all on function lms_sub_conflict(uuid, timestamptz, timestamptz, uuid) from public, anon, authenticated;

create or replace function lms_sub_option_rows(p_items uuid[])
returns table (id uuid, name text, timezone text, free integer, busy_dates text[], off_hours text[])
language sql stable security definer set search_path = public as $$
  with x as (
    select t.id, t.name, t.timezone, i.starts_at,
           lms_sub_conflict(t.id, i.starts_at, i.ends_at, i.lesson_id) is not null or t.id = any(i.sub_declined) as blocked,
           lms_tutor_available(t.id, i.starts_at) as usual
    from tutors t cross join leave_items i
    where i.id = any(p_items) and t.id <> i.tutor_id and t.active
  )
  select x.id, x.name, x.timezone,
         (count(*) filter (where not x.blocked and x.usual))::int,
         coalesce(array_agg(to_char(x.starts_at at time zone 'Asia/Seoul', 'FMMM/FMDD') order by x.starts_at) filter (where x.blocked), '{}'),
         coalesce(array_agg(to_char(x.starts_at at time zone 'Asia/Seoul', 'FMMM/FMDD') order by x.starts_at) filter (where not x.blocked and not x.usual), '{}')
  from x group by x.id, x.name, x.timezone
$$;
revoke all on function lms_sub_option_rows(uuid[]) from public, anon, authenticated;

create or replace function admin_leave_sub_options(p_items uuid[])
returns table (tutor_id uuid, name text, timezone text, free integer, busy_dates text[])
language plpgsql stable security definer set search_path = public as $$
begin
  if not is_admin() then raise exception '운영자(추가 인증 완료)만 볼 수 있습니다.' using errcode = '42501'; end if;
  return query
  select x.id, x.name, x.timezone, x.free, x.busy_dates from lms_sub_option_rows(p_items) x order by x.free desc, x.name;
end $$;
revoke all on function admin_leave_sub_options(uuid[]) from public, anon;
grant execute on function admin_leave_sub_options(uuid[]) to authenticated;

-- 보통 시간 밖 날짜 (강사마다). 목록 화면이 admin_leave_sub_options 와 같이 읽음
create or replace function admin_leave_sub_off_hours(p_items uuid[])
returns table (tutor_id uuid, off_hours text[])
language plpgsql stable security definer set search_path = public as $$
begin
  if not is_admin() then raise exception '운영자(추가 인증 완료)만 볼 수 있습니다.' using errcode = '42501'; end if;
  return query select x.id, x.off_hours from lms_sub_option_rows(p_items) x;
end $$;
revoke all on function admin_leave_sub_off_hours(uuid[]) from public, anon;
grant execute on function admin_leave_sub_off_hours(uuid[]) to authenticated;

create or replace function admin_leave_makeup_options(p_items uuid[])
returns table (section text, starts_at timestamptz, ends_at timestamptz)
language plpgsql stable security definer set search_path = public as $$
declare
  it leave_items;
  e enrollments;
  v_back date;
  v_today date := (now() at time zone 'Asia/Seoul')::date;
  v_need integer;
begin
  if not is_admin() then raise exception '운영자(추가 인증 완료)만 볼 수 있습니다.' using errcode = '42501'; end if;
  select * into it from leave_items where id = any(p_items) order by starts_at limit 1;
  if not found then return; end if;
  if exists (select 1 from leave_items where id = any(p_items) and student_id <> it.student_id) then
    raise exception '한 학생의 수업만 골라 주세요.';
  end if;
  select count(*) into v_need from leave_items where id = any(p_items);
  select * into e from enrollments where id = it.enrollment_id;
  select (o.ends_at at time zone 'Asia/Seoul')::date into v_back from tutor_time_off o where o.id = it.time_off_id;

  return query
  with rs as (
    select r.weekday, r.start_time_kst from regular_schedules r
    where r.student_id = it.student_id and r.tutor_id = it.tutor_id and (r.effective_to is null or r.effective_to >= v_today)
  ),
  slots as (
    select 'in_period'::text as sec, ((d::date + t.start_time_kst) at time zone 'Asia/Seoul') as s
    from generate_series(greatest(v_today + 1, v_back), e.final_end_date, interval '1 day') d
    cross join (select distinct start_time_kst from rs) t
    where extract(dow from d) not in (select weekday from rs)
    union all
    select 'after_end', ((d::date + rs.start_time_kst) at time zone 'Asia/Seoul')
    from generate_series(greatest(e.final_end_date + 1, v_back, v_today + 1), greatest(e.final_end_date + 1, v_back, v_today + 1) + 180, interval '1 day') d
    join rs on rs.weekday = extract(dow from d)
  ),
  free as (
    select x.sec, x.s, x.s + make_interval(mins => e.duration_min) as f from slots x
    where x.s > now()
      and lms_sub_conflict(it.tutor_id, x.s, x.s + make_interval(mins => e.duration_min), null) is null
      and lms_tutor_available(it.tutor_id, x.s)   -- 보강 가능한 날짜 제안은 강사 보통 수업 시간 안에서만 (2700)
      and not exists (select 1 from lessons l where l.student_id = it.student_id and l.state <> 'canceled'
                      and l.starts_at < x.s + make_interval(mins => e.duration_min) and x.s < l.ends_at)
  )
  select z.sec, z.s, z.f from (
    select f1.sec, f1.s, f1.f, row_number() over (partition by f1.sec order by f1.s) as n from free f1
  ) z
  where z.sec = 'in_period' or z.n <= v_need
  order by z.s;
end $$;
revoke all on function admin_leave_makeup_options(uuid[]) from public, anon;
grant execute on function admin_leave_makeup_options(uuid[]) to authenticated;
