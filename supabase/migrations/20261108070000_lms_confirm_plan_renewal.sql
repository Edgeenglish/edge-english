-- =====================================================================
-- 재등록 수강권 일정 확정 (2026-11-08, 송O나 STU-0004 재등록 정규 일정)
--  lms_confirm_plan 이 정규 일정(regular_schedules)을 늘 새로 넣어서, 재등록 때 지난 수강권의 끝없는 정규 일정과 겹쳐 확정이 막혔음
--  고침: 같은 요일에
--   - 같은 강사·시각·길이의 정규 일정이 이미 이어지고 있으면 그대로 씀 (새로 넣지 않음)
--   - 다른 정규 일정이 열려 있으면 새 수강권 시작 전날로 끝냄 → 새 일정 넣음
--  나머지(충돌 검사·수업 만들기·안내 카드)는 그대로
-- =====================================================================
create or replace function lms_confirm_plan(p_plan_id uuid, p_me uuid)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  pl record;
  e record;
  conflicts jsonb;
  s jsonb;
  d date;
  n integer := 0;
  t0 timestamptz;
begin
  select * into pl from schedule_plans where id = p_plan_id for update;
  if not found then raise exception '일정안이 없습니다.'; end if;
  if pl.state = 'confirmed' then
    return jsonb_build_object('plan_id', pl.id, 'version', pl.version, 'state', 'confirmed', 'repeated', true,
                              'lessons', (select count(*) from lessons where enrollment_id = pl.enrollment_id and kind = 'regular'))
           || lms_plan_notice_ids(pl.id);
  end if;
  if pl.state <> 'proposed' then raise exception '닫힌 일정안(%)은 확정할 수 없습니다.', pl.state; end if;
  perform lms_check_plan_shape_lessons(pl.enrollment_id, pl.tutor_id, pl.slots, pl.start_date, pl.lesson_dates);
  select * into e from enrollments where id = pl.enrollment_id;

  -- 제안 뒤에 다른 수업·휴무가 생겼을 수 있어 다시 검사
  if pl.lesson_dates is null then
    conflicts := lms_plan_conflicts(pl.tutor_id, pl.slots, e.start_date, e.base_end_date, e.duration_min);
  else
    conflicts := lms_lessons_conflicts(pl.tutor_id, pl.lesson_dates, e.duration_min);
  end if;
  if jsonb_array_length(conflicts) > 0 then
    raise exception '일정 충돌 %건 — 확정하지 않았습니다.', jsonb_array_length(conflicts)
      using errcode = 'P0001', detail = conflicts::text, hint = 'schedule_conflict';
  end if;

  for s in select * from jsonb_array_elements(pl.slots) loop
    -- 재등록: 같은 강사·시각·길이 정규 일정이 이미 이어지면 그대로
    if exists (select 1 from regular_schedules r
               where r.student_id = e.student_id and r.weekday = (s ->> 'weekday')::smallint
                 and r.effective_to is null and r.effective_from <= e.start_date
                 and r.tutor_id = pl.tutor_id and r.start_time_kst = (s ->> 'time')::time and r.duration_min = e.duration_min) then
      continue;
    end if;
    -- 다른 정규 일정이 열려 있으면 새 수강권 시작 전날로 끝냄
    update regular_schedules set effective_to = e.start_date - 1
    where student_id = e.student_id and weekday = (s ->> 'weekday')::smallint
      and effective_to is null and effective_from < e.start_date;
    insert into regular_schedules (student_id, tutor_id, weekday, start_time_kst, duration_min, effective_from)
    values (e.student_id, pl.tutor_id, (s ->> 'weekday')::smallint, (s ->> 'time')::time, e.duration_min, e.start_date);
  end loop;
  if pl.lesson_dates is null then
    d := e.start_date;
    while d <= e.base_end_date loop
      select x into s from jsonb_array_elements(pl.slots) x where (x ->> 'weekday')::int = extract(dow from d);
      if found then
        n := n + 1;
        t0 := (d + (s ->> 'time')::time) at time zone 'Asia/Seoul';
        insert into lessons (enrollment_id, student_id, tutor_id, kind, seq, starts_at, ends_at, created_by)
        values (e.id, e.student_id, pl.tutor_id, 'regular', n, t0, t0 + make_interval(mins => e.duration_min), p_me);
      end if;
      d := d + 1;
    end loop;
  else
    -- 회차별 날짜·시각을 정한 일정안: 그 목록 그대로 날짜순으로 수업을 만듦 (정규 요일 반복 아님)
    for s in select x from jsonb_array_elements(pl.lesson_dates) x order by x ->> 'date' loop
      n := n + 1;
      t0 := ((s ->> 'date')::date + (s ->> 'time')::time) at time zone 'Asia/Seoul';
      insert into lessons (enrollment_id, student_id, tutor_id, kind, seq, starts_at, ends_at, created_by)
      values (e.id, e.student_id, pl.tutor_id, 'regular', n, t0, t0 + make_interval(mins => e.duration_min), p_me);
    end loop;
  end if;
  if n <> e.lessons_purchased then
    raise exception '만들어진 정규 수업 수(%)가 등록 회차(%)와 다릅니다.', n, e.lessons_purchased;
  end if;

  update schedule_plans set state = 'confirmed', confirmed_at = now(), confirmed_by = p_me where id = pl.id;
  insert into schedule_notices (plan_id, recipient_kind, recipient_id, channel) values
    (pl.id, 'tutor', pl.tutor_id, 'whatsapp_manual'),
    (pl.id, 'student', e.student_id, 'kakao_manual')
  on conflict (plan_id, recipient_kind) do nothing;
  update admin_tasks set tutor_id = pl.tutor_id, tutor_assigned_at = now()
  where kind = 'new_student_matching' and enrollment_id = e.id and status = 'open';

  return jsonb_build_object('plan_id', pl.id, 'version', pl.version, 'state', 'confirmed', 'lessons', n) || lms_plan_notice_ids(pl.id);
end $$;
