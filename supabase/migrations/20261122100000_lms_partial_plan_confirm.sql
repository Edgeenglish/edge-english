-- =====================================================================
-- 일정 일부만 먼저 확정 (2026-11-22, 오O수 재등록 24회: 확정 9 · 강사 휴무 4 · 강사 해외 체류 시간 밖 11)
--  지금까지: 24회 중 하나라도 강사 휴무·해외 체류 시간과 겹치면 일정 전체를 저장·확정하지 못함
--  고침 (일정안 partial = true 일 때만, 기존 일정안은 그대로):
--   - 등록된 강사 휴무(kind 'leave', 철회 안 됨)와 겹치는 회차 → 수업을 만들고 바로 기존 휴무 절차에 붙임
--     (leave_items 'undecided' + 학생 lesson_notices 'leave_options' = admin_leave_create 와 같은 기록)
--     → 학생·강사·운영자 화면에 처음부터 '강사 휴무 처리 중', 입장 링크·정상 수업 취급 없음 (기존 leave_open 표시)
--   - 강사 해외 체류 기간 근무 시간 밖인 회차 → 수업을 만들지 않고 plan_pending_lessons 에 회차·원래 날짜·시각·까닭을 남김
--     (수업이 아니므로 알림·출결·입장 대상 아님)
--   - 다른 수업·쉬는 시간·재등록 대기 시간·그 밖의 겹침은 지금처럼 막음
--   - 수 검사: 만든 수업 + 협의 필요 회차 = 등록 회차
-- =====================================================================

alter table schedule_plans add column if not exists partial boolean not null default false;

create table if not exists plan_pending_lessons (
  id uuid primary key default gen_random_uuid(),
  plan_id uuid not null references schedule_plans(id),
  enrollment_id uuid not null references enrollments(id),
  student_id uuid not null references students(id),
  tutor_id uuid not null references tutors(id),
  seq integer not null,
  original_date date not null,
  time_kst time not null,
  reason text not null check (reason in ('tutor_travel_hours')),
  lesson_id uuid references lessons(id),
  resolved_at timestamptz,
  created_by uuid,
  created_at timestamptz not null default now(),
  unique (enrollment_id, seq)
);
alter table plan_pending_lessons enable row level security;
drop policy if exists plan_pending_lessons_admin_read on plan_pending_lessons;
create policy plan_pending_lessons_admin_read on plan_pending_lessons for select using (is_admin());
revoke insert, update, delete on plan_pending_lessons from anon, authenticated;
drop trigger if exists plan_pending_lessons_no_delete on plan_pending_lessons;
create trigger plan_pending_lessons_no_delete before delete on plan_pending_lessons for each row execute function forbid_delete();
drop trigger if exists plan_pending_lessons_audit on plan_pending_lessons;
create trigger plan_pending_lessons_audit after insert or update or delete on plan_pending_lessons for each row execute function write_audit();

-- 회차 하나 판정: ok · leave(등록된 휴무) · travel(해외 체류 근무 시간 밖) · block(그 밖의 겹침)
create or replace function lms_partial_kind(p_tutor uuid, p_date date, p_time text, p_dur smallint)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  c jsonb;
  x jsonb;
  t0 timestamptz := (p_date + p_time::time) at time zone 'Asia/Seoul';
  t1 timestamptz := t0 + make_interval(mins => p_dur);
  v_leave uuid;
  v_travel boolean := false;
  v_block jsonb := '[]'::jsonb;
begin
  select o.id into v_leave from tutor_time_off o
  where o.tutor_id = p_tutor and o.kind = 'leave' and o.withdrawn_at is null and o.starts_at < t1 and t0 < o.ends_at
  order by o.starts_at limit 1;
  c := lms_plan_conflicts(p_tutor, jsonb_build_array(jsonb_build_object('weekday', extract(dow from p_date)::int, 'time', p_time)), p_date, p_date, p_dur);
  for x in select * from jsonb_array_elements(c) loop
    if x ->> 'reason' = 'tutor_travel_hours' then v_travel := true;
    elsif x ->> 'reason' = 'tutor_time_off' and v_leave is not null
          and exists (select 1 from tutor_time_off o where o.id = v_leave
                      and o.starts_at = (x ->> 'other_starts_at')::timestamptz and o.ends_at = (x ->> 'other_ends_at')::timestamptz) then
      null;
    else v_block := v_block || jsonb_build_array(x);
    end if;
  end loop;
  return jsonb_build_object('date', p_date, 'time', p_time, 'starts_at', t0, 'ends_at', t1,
    'kind', case when jsonb_array_length(v_block) > 0 then 'block' when v_leave is not null then 'leave' when v_travel then 'travel' else 'ok' end,
    'time_off_id', v_leave, 'conflicts', v_block);
end $$;

-- 수강 기간 전체 회차 나누기 (요일 반복 일정안만)
create or replace function lms_partial_split(p_tutor uuid, p_slots jsonb, p_start date, p_end date, p_dur smallint)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  d date := p_start;
  s jsonb;
  n integer := 0;
  out jsonb := '[]'::jsonb;
begin
  while d <= p_end loop
    select x into s from jsonb_array_elements(p_slots) x where (x ->> 'weekday')::int = extract(dow from d);
    if found then
      n := n + 1;
      out := out || jsonb_build_array(lms_partial_kind(p_tutor, d, s ->> 'time', p_dur) || jsonb_build_object('seq', n));
    end if;
    d := d + 1;
  end loop;
  return out;
end $$;

create or replace function lms_partial_blocks(p_split jsonb)
returns jsonb language sql immutable as $$
  select coalesce(jsonb_agg(c), '[]'::jsonb)
  from jsonb_array_elements(p_split) x, jsonb_array_elements(x -> 'conflicts') c
  where x ->> 'kind' = 'block'
$$;

-- 일부 확정용 일정안 만들기 (lms_new_plan_lessons 의 요일 반복 판과 같고, 충돌 판정만 다름)
create or replace function lms_new_plan_partial(p_plan_id uuid, p_enrollment uuid, p_tutor uuid, p_slots jsonb, p_start date, p_me uuid)
returns integer
language plpgsql security definer set search_path = public as $$
declare
  e record;
  v integer;
  sp jsonb;
  b jsonb;
begin
  if exists (select 1 from schedule_plans where enrollment_id = p_enrollment and state = 'confirmed') then
    raise exception '이미 확정된 일정이 있습니다. 확정 후 변경은 일정 변경 기능으로 (아직 없음).';
  end if;
  update enrollments set start_date = p_start, base_end_date = p_start + (weeks / 4 * 28 - 1)
  where id = p_enrollment and p_start is not null and start_date is distinct from p_start and weeks is not null
    and not exists (select 1 from lessons where enrollment_id = p_enrollment);
  perform lms_check_plan_shape(p_enrollment, p_tutor, p_slots, p_start);
  select * into e from enrollments where id = p_enrollment;
  sp := lms_partial_split(p_tutor, p_slots, e.start_date, e.base_end_date, e.duration_min);
  b := lms_partial_blocks(sp);
  if jsonb_array_length(b) > 0 then
    raise exception '일정 충돌 %건 — 저장하지 않았습니다.', jsonb_array_length(b)
      using errcode = 'P0001', detail = b::text, hint = 'schedule_conflict';
  end if;
  if jsonb_array_length(sp) <> e.lessons_purchased then
    raise exception '수업 날짜 수(%)가 등록 회차(%)와 다릅니다.', jsonb_array_length(sp), e.lessons_purchased;
  end if;
  update schedule_plans set state = 'withdrawn', closed_at = now(), close_reason = '다른 안으로 바꿈'
  where enrollment_id = p_enrollment and state = 'proposed';
  select coalesce(max(version), 0) + 1 into v from schedule_plans where enrollment_id = p_enrollment;
  insert into schedule_plans (id, enrollment_id, version, tutor_id, slots, start_date, lesson_dates, created_by, partial)
  values (p_plan_id, p_enrollment, v, p_tutor, p_slots, p_start, null, p_me, true);
  return v;
end $$;

-- 일부 확정 실행 (lms_confirm_plan 에서 partial 일정안일 때 부름)
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

-- 기존 확정 함수: partial 일정안이면 위 함수로 (나머지는 그대로)
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

-- 운영자 화면용: 일부 확정 미리 보기 (회차별 판정) · 일정안 만들고 바로 확정
create or replace function admin_partial_preview(p_enrollment uuid, p_tutor uuid, p_slots jsonb, p_start date)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  e record;
begin
  if not is_admin() then raise exception '운영자(추가 인증 완료)만 볼 수 있습니다.' using errcode = '42501'; end if;
  select * into e from enrollments where id = p_enrollment;
  if not found then raise exception '수강등록이 없습니다.'; end if;
  return lms_partial_split(p_tutor, p_slots, p_start, p_start + (e.weeks / 4 * 28 - 1), e.duration_min);
end $$;

create or replace function admin_confirm_partial_schedule(p_plan_id uuid, p_enrollment uuid, p jsonb)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  pl record;
begin
  if not is_admin() then raise exception '운영자(추가 인증 완료)만 일정을 확정할 수 있습니다.' using errcode = '42501'; end if;
  if p_plan_id is null then raise exception '요청 번호가 없습니다.'; end if;
  perform pg_advisory_xact_lock(hashtextextended(p_enrollment::text, 0));
  select * into pl from schedule_plans where id = p_plan_id;
  if found then
    if pl.enrollment_id <> p_enrollment then raise exception '요청 번호가 다른 등록에 쓰였습니다.'; end if;
    if pl.state = 'confirmed' then return lms_confirm_plan(p_plan_id, me); end if;
    return jsonb_build_object('plan_id', pl.id, 'version', pl.version, 'state', pl.state, 'repeated', true);
  end if;
  perform set_config('app.actor_id', me::text, true);
  perform set_config('app.actor_via', 'admin_confirm_partial_schedule', true);
  perform lms_new_plan_partial(p_plan_id, p_enrollment, nullif(p ->> 'tutor_id', '')::uuid, coalesce(p -> 'slots', '[]'::jsonb), (p ->> 'start_date')::date, me);
  return lms_confirm_plan(p_plan_id, me);
end $$;

revoke all on function lms_partial_kind(uuid, date, text, smallint), lms_partial_split(uuid, jsonb, date, date, smallint),
  lms_new_plan_partial(uuid, uuid, uuid, jsonb, date, uuid), lms_confirm_plan_partial(uuid, uuid) from public, anon, authenticated;
revoke all on function admin_partial_preview(uuid, uuid, jsonb, date), admin_confirm_partial_schedule(uuid, uuid, jsonb) from public, anon;
grant execute on function admin_partial_preview(uuid, uuid, jsonb, date), admin_confirm_partial_schedule(uuid, uuid, jsonb) to authenticated;
