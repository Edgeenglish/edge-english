-- =====================================================================
-- 정규 시간 변경: '매주 비어 있는 시간' 검사를 실제로 옮겨질 수업이 있는 주만 (정책 원본 H26(208) 보충 10, 대표 11/23)
--  계기: 운영 STU-0007 — 강사 휴무(12/22~1/4)·해외 임시 근무 주까지 검사해 고를 시간이 0개였는데,
--        확정 때 쓰는 [정규 일정 수정](admin_regular_change)은 휴무 처리 중인 수업을 옮기지 않아 문제없이 확정됨.
--  옮겨질 수업 = admin_regular_change 와 같은 기준: 이 강사의 앞으로 정규 수업, 대체강사 아님, 휴무 처리 중 아님
--  그런 수업이 있는 주의 새 요일·시각만 검사 (그 주에 해외 임시 근무가 걸리면 그 근무 시간대로 검사됨)
-- 지우는 문장 없음 (같은 이름 함수 교체)
-- =====================================================================
create or replace function lms_rc_free(p_tutor uuid, p_student uuid, p_from date, p_until date, p_dow int, p_time time, p_min int)
returns boolean language plpgsql stable security definer set search_path = public as $$
declare
  d date;
  t0 timestamptz;
  t1 timestamptz;
  n int := 0;
begin
  d := lms_rc_day(lms_rc_monday(p_from), p_dow);
  if d < p_from then d := d + 7; end if;
  while d <= p_until loop
    if exists (select 1 from lessons x
               where x.student_id = p_student and x.kind = 'regular' and x.state = 'scheduled' and x.voided_at is null
                 and x.tutor_id = p_tutor and x.original_tutor_id is null and x.starts_at > now()
                 and lms_rc_monday((x.starts_at at time zone 'Asia/Seoul')::date) = lms_rc_monday(d)
                 and not exists (select 1 from leave_items li where li.lesson_id = x.id and li.lesson_gone_at is null)) then
      t0 := (d + p_time) at time zone 'Asia/Seoul';
      t1 := t0 + make_interval(mins => p_min);
      if not lms_tutor_start_ok(p_tutor, t0) or not lms_tutor_available(p_tutor, t0) then return false; end if;
      if exists (select 1 from tutor_time_off o where o.tutor_id = p_tutor and o.starts_at < t1 and t0 < o.ends_at) then return false; end if;
      if exists (select 1 from lessons y where y.tutor_id = p_tutor and y.state <> 'canceled' and y.voided_at is null
                   and not (y.student_id = p_student and y.kind = 'regular' and y.state = 'scheduled')
                   and y.starts_at < t1 + interval '10 minutes' and t0 - interval '10 minutes' < y.ends_at) then return false; end if;
      if exists (select 1 from lms_slot_hold_hits(p_tutor, t0, t1) h where h.student_id <> p_student) then return false; end if;
      n := n + 1;
    end if;
    d := d + 7;
  end loop;
  return n > 0;
end $$;
revoke all on function lms_rc_free(uuid, uuid, date, date, int, time, int) from public, anon, authenticated;
