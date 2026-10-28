-- =====================================================================
-- 강사 장기휴무로 못 들은 수업 = '휴무로 미뤄진 수업' (2026-10-28 대표 최종: 종료일 연장 유지 + 구분만)
--  - 수강기간은 기존처럼 마지막 휴무 보강일까지 연장(A20), 재등록 결제 마감 = 연장된 종료일 23:59 — 기존 그대로
--  - DB에서 일반 보강과 휴무로 미뤄진 수업을 구분(학생 화면 표시 · 나중에 강사 인센티브 근거)
--  - 다음 수강권 정규 수업은 이전 수강권의 휴무로 미뤄진 수업을 마친 뒤부터 (정규 수업 넣을 때 DB가 막음)
-- 기존 표·데이터를 지우거나 바꾸지 않음. 다시 실행해도 같은 결과
-- =====================================================================

-- 휴무로 미뤄진 수업인지: 강사 장기휴무로 취소된 수업의 보강, 또는 시트에서 넘어온 강사 휴가 보강을 예약한 수업
create or replace function lms_is_leave_postponed(p_lesson uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from lessons l join lessons o on o.id = l.makeup_of
                 where l.id = p_lesson and o.class_status = 'Tutor long-term leave')
      or exists (select 1 from migrated_items m where m.lesson_id = p_lesson and m.tutor_leave)
$$;
revoke all on function lms_is_leave_postponed(uuid) from public, anon, authenticated;

-- 다음 정규 수업을 시작할 수 있는 첫날: 종료일 다음 날, 휴무로 미뤄진 수업이 그 뒤에 잡혀 있으면 마지막 수업 다음 날
-- 날짜를 아직 안 잡은 휴무로 미뤄진 수업이 있으면 null (날짜부터 잡아야 함)
create or replace function lms_next_regular_from(p_enrollment uuid) returns date
language sql stable security definer set search_path = public as $$
  select case
    when exists (select 1 from lessons l where l.enrollment_id = p_enrollment and l.voided_at is null and l.class_status = 'Tutor long-term leave'
                 and not exists (select 1 from lessons x where x.makeup_of = l.id and x.state <> 'canceled'))
      or exists (select 1 from migrated_items m where m.enrollment_id = p_enrollment and m.kind = 'makeup_open' and m.tutor_leave)
    then null
    else greatest((select e.final_end_date from enrollments e where e.id = p_enrollment),
                  coalesce((select max((l.starts_at at time zone 'Asia/Seoul')::date) from lessons l
                            where l.enrollment_id = p_enrollment and l.state <> 'canceled' and l.voided_at is null and lms_is_leave_postponed(l.id)),
                           (select e.final_end_date from enrollments e where e.id = p_enrollment))) + 1 end
$$;
revoke all on function lms_next_regular_from(uuid) from public, anon, authenticated;

-- 다음 수강권 정규 수업이 이전 수강권의 휴무로 미뤄진 수업보다 먼저 생기지 않게
create or replace function lessons_after_leave_postponed() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  prev uuid;
  v_from date;
begin
  if new.kind <> 'regular' then return new; end if;
  select e.previous_enrollment_id into prev from enrollments e where e.id = new.enrollment_id;
  if prev is null then return new; end if;
  if not exists (select 1 from lessons l where l.enrollment_id = prev and lms_is_leave_postponed(l.id))
     and not exists (select 1 from lessons l where l.enrollment_id = prev and l.class_status = 'Tutor long-term leave')
     and not exists (select 1 from migrated_items m where m.enrollment_id = prev and m.tutor_leave) then
    return new;   -- 휴무로 미뤄진 수업이 없던 수강권은 그대로
  end if;
  v_from := lms_next_regular_from(prev);
  if v_from is null then
    raise exception '이전 수강권에 날짜를 안 잡은 휴무로 미뤄진 수업이 있어요. 그 날짜를 먼저 잡아 주세요.' using hint = 'leave_postponed_open';
  end if;
  if (new.starts_at at time zone 'Asia/Seoul')::date < v_from then
    raise exception '다음 정규 수업은 휴무로 미뤄진 수업을 마친 뒤(%부터) 시작할 수 있어요.', v_from using hint = 'leave_postponed_first';
  end if;
  return new;
end $$;
revoke all on function lessons_after_leave_postponed() from public, anon, authenticated;
drop trigger if exists lessons_after_leave_postponed on lessons;
create trigger lessons_after_leave_postponed before insert on lessons for each row execute function lessons_after_leave_postponed();
