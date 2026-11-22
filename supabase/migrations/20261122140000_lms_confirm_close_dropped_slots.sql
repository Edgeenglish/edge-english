-- =====================================================================
-- 일정 확정 때 새 일정에 없는 요일의 예전 정규 시간도 닫기 (2026-11-22, 대표 '응')
--  고장: lms_confirm_plan 은 새 일정과 같은 요일만 닫음 → 주 횟수가 줄면(3→2, 2→1) 빠진 요일이 열린 채 남음
--   (오O수 STU-0010 재등록: 수·금 17:00 이 남아 정규 시간이 월·수·목·금으로 보임)
--  고침: 확정 때 새 일정에 없는 요일의 열린 정규 시간을 새 수강권 시작 전날로 닫음 (수업·기록은 건드리지 않음)
-- =====================================================================
create or replace function lms_close_dropped_slots(p_student uuid, p_slots jsonb, p_start date)
returns integer
language plpgsql security definer set search_path = public as $$
declare n integer;
begin
  update regular_schedules r set effective_to = p_start - 1
  where r.student_id = p_student and r.effective_to is null and r.effective_from < p_start
    and not exists (select 1 from jsonb_array_elements(p_slots) x where (x ->> 'weekday')::smallint = r.weekday);
  get diagnostics n = row_count;
  return n;
end $$;
revoke all on function lms_close_dropped_slots(uuid, jsonb, date) from public, anon, authenticated;


create or replace function lms_confirm_plan_partial(p_plan_id uuid, p_me uuid)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  pl record;
  e record;
  sp jsonb;
  b jsonb;
  s jsonb;
  x jsonb;
  v_lesson uuid;
  v_item uuid;
  n_ok integer := 0;
  n_leave integer := 0;
  n_pending integer := 0;
begin
  select * into pl from schedule_plans where id = p_plan_id for update;
  perform lms_check_plan_shape(pl.enrollment_id, pl.tutor_id, pl.slots, pl.start_date);
  select * into e from enrollments where id = pl.enrollment_id;
  -- 제안 뒤에 다른 수업·휴무가 생겼을 수 있어 다시 판정
  sp := lms_partial_split(pl.tutor_id, pl.slots, e.start_date, e.base_end_date, e.duration_min);
  b := lms_partial_blocks(sp);
  if jsonb_array_length(b) > 0 then
    raise exception '일정 충돌 %건 — 확정하지 않았습니다.', jsonb_array_length(b)
      using errcode = 'P0001', detail = b::text, hint = 'schedule_conflict';
  end if;
  if jsonb_array_length(sp) <> e.lessons_purchased then
    raise exception '만들어질 회차 수(%)가 등록 회차(%)와 다릅니다.', jsonb_array_length(sp), e.lessons_purchased;
  end if;

  for s in select * from jsonb_array_elements(pl.slots) loop
    if exists (select 1 from regular_schedules r
               where r.student_id = e.student_id and r.weekday = (s ->> 'weekday')::smallint
                 and r.effective_to is null and r.effective_from <= e.start_date
                 and r.tutor_id = pl.tutor_id and r.start_time_kst = (s ->> 'time')::time and r.duration_min = e.duration_min) then
      continue;
    end if;
    update regular_schedules set effective_to = e.start_date - 1
    where student_id = e.student_id and weekday = (s ->> 'weekday')::smallint
      and effective_to is null and effective_from < e.start_date;
    insert into regular_schedules (student_id, tutor_id, weekday, start_time_kst, duration_min, effective_from)
    values (e.student_id, pl.tutor_id, (s ->> 'weekday')::smallint, (s ->> 'time')::time, e.duration_min, e.start_date);
  end loop;
  perform lms_close_dropped_slots(e.student_id, pl.slots, e.start_date);

  for x in select * from jsonb_array_elements(sp) loop
    if x ->> 'kind' = 'travel' then
      insert into plan_pending_lessons (plan_id, enrollment_id, student_id, tutor_id, seq, original_date, time_kst, reason, created_by)
      values (pl.id, e.id, e.student_id, pl.tutor_id, (x ->> 'seq')::int, (x ->> 'date')::date, (x ->> 'time')::time, 'tutor_travel_hours', p_me);
      n_pending := n_pending + 1;
      continue;
    end if;
    insert into lessons (enrollment_id, student_id, tutor_id, kind, seq, starts_at, ends_at, created_by)
    values (e.id, e.student_id, pl.tutor_id, 'regular', (x ->> 'seq')::int, (x ->> 'starts_at')::timestamptz, (x ->> 'ends_at')::timestamptz, p_me)
    returning id into v_lesson;
    if x ->> 'kind' = 'leave' then
      insert into leave_items (time_off_id, tutor_id, student_id, enrollment_id, lesson_id, starts_at, ends_at, choice, created_by)
      values ((x ->> 'time_off_id')::uuid, pl.tutor_id, e.student_id, e.id, v_lesson,
              (x ->> 'starts_at')::timestamptz, (x ->> 'ends_at')::timestamptz, 'undecided', p_me)
      returning id into v_item;
      insert into lesson_notices (leave_item_id, event, recipient_kind, recipient_id) values (v_item, 'leave_options', 'student', e.student_id);
      n_leave := n_leave + 1;
    else
      n_ok := n_ok + 1;
    end if;
  end loop;
  if n_ok + n_leave + n_pending <> e.lessons_purchased then
    raise exception '만든 수업(%)과 협의 필요 회차(%)의 합이 등록 회차(%)와 다릅니다.', n_ok + n_leave, n_pending, e.lessons_purchased;
  end if;

  update schedule_plans set state = 'confirmed', confirmed_at = now(), confirmed_by = p_me where id = pl.id;
  insert into schedule_notices (plan_id, recipient_kind, recipient_id, channel) values
    (pl.id, 'tutor', pl.tutor_id, 'whatsapp_manual'),
    (pl.id, 'student', e.student_id, 'kakao_manual')
  on conflict (plan_id, recipient_kind) do nothing;
  update admin_tasks set tutor_id = pl.tutor_id, tutor_assigned_at = now()
  where kind = 'new_student_matching' and enrollment_id = e.id and status = 'open';

  return jsonb_build_object('plan_id', pl.id, 'version', pl.version, 'state', 'confirmed', 'lessons', n_ok + n_leave,
                            'confirmed', n_ok, 'leave', n_leave, 'pending', n_pending) || lms_plan_notice_ids(pl.id);
end $$;

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
  if pl.partial then return lms_confirm_plan_partial(p_plan_id, p_me); end if;
  perform lms_check_plan_shape_lessons(pl.enrollment_id, pl.tutor_id, pl.slots, pl.start_date, pl.lesson_dates);
  select * into e from enrollments where id = pl.enrollment_id;

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
    if exists (select 1 from regular_schedules r
               where r.student_id = e.student_id and r.weekday = (s ->> 'weekday')::smallint
                 and r.effective_to is null and r.effective_from <= e.start_date
                 and r.tutor_id = pl.tutor_id and r.start_time_kst = (s ->> 'time')::time and r.duration_min = e.duration_min) then
      continue;
    end if;
    update regular_schedules set effective_to = e.start_date - 1
    where student_id = e.student_id and weekday = (s ->> 'weekday')::smallint
      and effective_to is null and effective_from < e.start_date;
    insert into regular_schedules (student_id, tutor_id, weekday, start_time_kst, duration_min, effective_from)
    values (e.student_id, pl.tutor_id, (s ->> 'weekday')::smallint, (s ->> 'time')::time, e.duration_min, e.start_date);
  end loop;
  perform lms_close_dropped_slots(e.student_id, pl.slots, e.start_date);
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
