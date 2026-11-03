-- =====================================================================
-- 4200 강사 현지 06:00~22:30 시작 — DB에서 막기 (2026-11-03 대표: 현지 06:00 전은 절대 안 됨, 강사 컨디션 컴플레인 / 22:30까지 허용 / 한국시간 제한 없음, POL-OP-02)
--  - lms_tutor_start_ok: 강사 현지 시각으로 06:00~22:30 시작인지 (서머타임은 그날 실제 시차)
--  - lms_tutor_available: 강사가 직접 연 시간(tutor_availability)만 가능. 가능 시간을 안 넣은 강사는 어느 시간도 '가능'이 아님
--    (전에는 줄이 없으면 하루 종일 가능 → 보강 날짜에 새벽이 뜰 수 있었음, 11/3 대표·ChatGPT 확인). 칸 = 수업 시작 가능 시각 그대로(POL-TU-11)
--    → 학생 보강 가능한 날짜·대체강사 '평소 시간' 표시·My hours 판정에 그대로 반영
--  - lms_makeup_conflict: 범위 밖이면 충돌 → 운영진 보강·보상 확정, 강사 화면 busy, 강사 '가능' 답 모두 거절
--  - 운영진이 직접 넣는 신규 등록·기존 학생 입력 시각은 이번에 건드리지 않음
-- 기존 표·데이터를 바꾸지 않음. 다시 실행해도 같은 결과
-- =====================================================================

create or replace function lms_tutor_start_ok(p_tutor uuid, p_start timestamptz) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select (p_start at time zone t.timezone)::time between time '06:00' and time '22:30' from tutors t where t.id = p_tutor), false)
$$;
revoke all on function lms_tutor_start_ok(uuid, timestamptz) from public, anon, authenticated;

create or replace function lms_tutor_available(p_tutor uuid, p_start timestamptz) returns boolean
language sql stable security definer set search_path = public as $$
  select lms_tutor_start_ok(p_tutor, p_start)
     and exists (select 1 from tutor_availability a
                 where a.tutor_id = p_tutor
                   and a.effective_from <= (p_start at time zone 'Asia/Seoul')::date
                   and (a.effective_to is null or a.effective_to >= (p_start at time zone 'Asia/Seoul')::date)
                   and extract(dow from (p_start at time zone a.timezone)) = a.weekday
                   and (p_start at time zone a.timezone)::time between a.start_local and a.end_local)
$$;
revoke all on function lms_tutor_available(uuid, timestamptz) from public, anon, authenticated;

create or replace function lms_makeup_conflict(p_tutor uuid, p_student uuid, p_start timestamptz, p_end timestamptz, p_student_wants boolean)
returns text
language plpgsql stable security definer set search_path = public as $$
declare
  v_break constant interval := interval '10 minutes';      -- POL-OP-21 (policy.ts CONFIRMED.minBreakMin)
  v_b2b_min constant integer := 20;                         -- POL-OP-21 예외 (policy.ts CONFIRMED.backToBackNoBreakDurationMin)
  v_b2b_max constant integer := 2;                          -- POL-OP-21 예외 (policy.ts CONFIRMED.backToBackNoBreakMaxLessons)
  v_new_b2b boolean := p_student_wants and p_end - p_start = make_interval(mins => v_b2b_min);
  v_near uuid[];
  v_chain integer;
begin
  -- 강사 현지 06:00~22:30 시작만 (POL-OP-02, 4200)
  if not lms_tutor_start_ok(p_tutor, p_start) then
    return '강사 현지 06:00~22:30 밖의 시작 시각';
  end if;
  if exists (select 1 from tutor_time_off o where o.tutor_id = p_tutor and o.starts_at < p_end and p_start < o.ends_at) then
    return '강사 휴무';
  end if;
  if exists (select 1 from lessons x where x.tutor_id = p_tutor and x.state <> 'canceled'
             and x.starts_at < p_end + v_break and p_start - v_break < x.ends_at
             and (x.starts_at < p_end and p_start < x.ends_at
                  or not (v_new_b2b and x.student_id = p_student and x.ends_at - x.starts_at = make_interval(mins => v_b2b_min)))) then
    return '강사 다른 수업(휴식 10분 포함)';
  end if;
  select coalesce(array_agg(x.id), '{}') into v_near from lessons x
  where x.tutor_id = p_tutor and x.state <> 'canceled'
    and x.starts_at < p_end + v_break and p_start - v_break < x.ends_at;
  if cardinality(v_near) = 0 then return null; end if;
  select 1 + cardinality(v_near) + count(distinct y.id) into v_chain from lessons y
  where y.tutor_id = p_tutor and y.state <> 'canceled' and y.id <> all(v_near)
    and not (y.starts_at < p_end + v_break and p_start - v_break < y.ends_at)
    and exists (select 1 from lessons x where x.id = any(v_near)
                and y.starts_at < x.ends_at + v_break and x.starts_at - v_break < y.ends_at);
  if v_chain > v_b2b_max then
    return format('쉬지 않고 이어 붙이는 수업(%s분 %s개까지)', v_b2b_min, v_b2b_max);
  end if;
  return null;
end $$;
revoke all on function lms_makeup_conflict(uuid, uuid, timestamptz, timestamptz, boolean) from public, anon, authenticated;
