-- =====================================================================
-- 대체강사 판정에 강사 수업 가능 시간(tutor_availability) 연결 (2026-10-28 대표 지적: 한국 20시 수업에 Benny가 가능으로 나옴)
--  - 반영 목록 8번: 가능 시간은 운영 DB에 넣어 놓고 대체강사 판정(lms_sub_conflict)에 연결이 빠져 있었음
--  - 수업 시작 시각이 강사 가능 시간(시작 기준, 끝 시각 포함, 행마다 그 시간대 현지 요일·시각) 밖이면 '강사 수업 가능 시간 밖'
--    (코드 booking.ts startsWithinAvailability 와 같은 기준). 가능 시간이 한 줄도 없는 강사는 이 검사 안 함
--  - 같은 함수를 쓰는 곳 모두 적용: 대체강사 목록(admin_leave_sub_options) · 대체강사 고르기(admin_leave_choose) ·
--    강사 가능 처리(admin_leave_sub_ok) · 기존 강사 보강 가능 날짜(admin_leave_makeup_options)
-- 기존 표·데이터를 지우지 않음. 다시 실행해도 같은 결과
-- =====================================================================

create or replace function lms_tutor_available(p_tutor uuid, p_start timestamptz) returns boolean
language sql stable security definer set search_path = public as $$
  select not exists (select 1 from tutor_availability a where a.tutor_id = p_tutor)
      or exists (select 1 from tutor_availability a
                 where a.tutor_id = p_tutor
                   and a.effective_from <= (p_start at time zone 'Asia/Seoul')::date
                   and (a.effective_to is null or a.effective_to >= (p_start at time zone 'Asia/Seoul')::date)
                   and extract(dow from (p_start at time zone a.timezone)) = a.weekday
                   and (p_start at time zone a.timezone)::time between a.start_local and a.end_local)
$$;
revoke all on function lms_tutor_available(uuid, timestamptz) from public, anon, authenticated;

create or replace function lms_sub_conflict(p_tutor uuid, p_start timestamptz, p_end timestamptz, p_except_lesson uuid)
returns text
language plpgsql stable security definer set search_path = public as $$
declare
  v_break constant interval := interval '10 minutes';   -- POL-OP-21 (policy.ts CONFIRMED.minBreakMin)
begin
  if exists (select 1 from tutor_time_off o where o.tutor_id = p_tutor and o.starts_at < p_end and p_start < o.ends_at) then
    return '강사 휴무';
  end if;
  if not lms_tutor_available(p_tutor, p_start) then
    return '강사 수업 가능 시간 밖';
  end if;
  if exists (select 1 from lessons x where x.tutor_id = p_tutor and x.state <> 'canceled' and x.id is distinct from p_except_lesson
             and x.starts_at < p_end + v_break and p_start - v_break < x.ends_at) then
    return '강사 다른 수업(휴식 10분 포함)';
  end if;
  return null;
end $$;
revoke all on function lms_sub_conflict(uuid, timestamptz, timestamptz, uuid) from public, anon, authenticated;
