-- =====================================================================
-- 회차별 수업 날짜 (2026-11-06 대표 요청 · 정책 원본 H26(60)·(61))
--  - 일정안(schedule_plans)에 lesson_dates 추가: null = 예전처럼 정규 요일대로 자동 생성,
--    값 = [{date, time}] 실제 수업 날짜·시각(KST) 전체 목록. 첫 수업일이 정규 요일이 아니어도,
--    특정 회차만 다른 날·시간이어도 그 목록 그대로 수업을 만듦 (변경권 사용 없음 — 등록 때 정하는 일정)
--  - 검사: 회차 수 = 등록 회차, 같은 날 2회 금지, 첫 날짜 = 수강 시작일, 모두 수강 기간 안,
--    충돌(다른 수업·휴식 10분·휴무·재등록 대기 자리)은 기존 lms_plan_conflicts 를 회차마다 그대로 호출
--  - admin_register_student·admin_propose_schedule 은 p.lessons 를 받음 (없으면 예전과 같음)
--  - 기존 표·데이터를 바꾸지 않고 열 하나만 추가. 다시 실행해도 같은 결과. 삭제·덮어쓰기 없음
-- =====================================================================

alter table schedule_plans add column if not exists lesson_dates jsonb;
do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'schedule_plans_lesson_dates_array') then
    alter table schedule_plans add constraint schedule_plans_lesson_dates_array
      check (lesson_dates is null or jsonb_typeof(lesson_dates) = 'array');
  end if;
end $$;

-- 회차 목록의 충돌: 회차마다 기존 충돌 검사를 한 번씩 그대로 부름 (이유 이름·재등록 대기 자리 포함 같은 결과)
create or replace function lms_lessons_conflicts(p_tutor uuid, p_lessons jsonb, p_dur smallint)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  x jsonb;
  d date;
  out jsonb := '[]'::jsonb;
begin
  for x in select * from jsonb_array_elements(p_lessons) loop
    d := (x ->> 'date')::date;
    out := out || lms_plan_conflicts(p_tutor,
      jsonb_build_array(jsonb_build_object('weekday', extract(dow from d)::int, 'time', x ->> 'time')), d, d, p_dur);
  end loop;
  return out;
end $$;
revoke all on function lms_lessons_conflicts(uuid, jsonb, smallint) from public, anon, authenticated;

-- 일정안 모양 검사. p_lessons 가 없으면 예전 검사 그대로, 있으면 '시작일 = 정규 요일' 대신 회차 목록을 검사
create or replace function lms_check_plan_shape_lessons(p_enrollment uuid, p_tutor uuid, p_slots jsonb, p_start date, p_lessons jsonb)
returns void
language plpgsql stable security definer set search_path = public as $$
declare
  e record;
  n integer;
  nd integer;
  first_d date;
  last_d date;
begin
  if p_lessons is null then
    perform lms_check_plan_shape(p_enrollment, p_tutor, p_slots, p_start);
    return;
  end if;
  select * into e from enrollments where id = p_enrollment;
  if not found then raise exception '수강등록이 없습니다.'; end if;
  if e.status = 'pending_payment' or not exists (select 1 from payments where enrollment_id = p_enrollment) then
    raise exception '결제 확인 전에는 강사·정규 일정을 제안·확정할 수 없습니다 (POL-OP-13).';
  end if;
  if p_start is distinct from e.start_date then
    raise exception '첫 수업일(%)이 수강 시작일(%)과 다릅니다.', p_start, e.start_date;
  end if;
  if jsonb_typeof(p_slots) <> 'array' or jsonb_array_length(p_slots) <> e.weekly_count then
    raise exception '정규 시간 수(%)가 주 횟수(%)와 다릅니다.', coalesce(jsonb_array_length(p_slots), 0), e.weekly_count;
  end if;
  if (select count(distinct (x ->> 'weekday')::int) from jsonb_array_elements(p_slots) x) <> jsonb_array_length(p_slots) then
    raise exception '같은 요일에 정규 수업을 2개 넣을 수 없습니다.';
  end if;
  if jsonb_typeof(p_lessons) <> 'array' then raise exception '수업 날짜 목록 모양이 맞지 않습니다.'; end if;
  select count(*), count(distinct (x ->> 'date')::date), min((x ->> 'date')::date), max((x ->> 'date')::date)
    into n, nd, first_d, last_d from jsonb_array_elements(p_lessons) x;
  if n <> e.lessons_purchased then raise exception '수업 날짜 수(%)가 등록 회차(%)와 다릅니다.', n, e.lessons_purchased; end if;
  if nd <> n then raise exception '같은 날에 수업이 둘 이상 있습니다.'; end if;
  if first_d is distinct from p_start then raise exception '첫 수업일(%)이 수업 날짜 목록의 첫 날짜(%)와 다릅니다.', p_start, first_d; end if;
  if last_d > e.base_end_date then raise exception '수강 기간(%까지) 밖의 수업 날짜가 있습니다: %', e.base_end_date, last_d; end if;
  if exists (select 1 from jsonb_array_elements(p_lessons) x where (x ->> 'time') !~ '^[0-2][0-9]:[0-5][0-9]$') then
    raise exception '수업 시각 형식이 맞지 않습니다 (HH:MM).';
  end if;
  if not exists (select 1 from tutors where id = p_tutor and active) then raise exception '활동 중인 강사가 아닙니다.'; end if;
end $$;
revoke all on function lms_check_plan_shape_lessons(uuid, uuid, jsonb, date, jsonb) from public, anon, authenticated;

create or replace function lms_new_plan_lessons(p_plan_id uuid, p_enrollment uuid, p_tutor uuid, p_slots jsonb, p_start date, p_me uuid, p_lessons jsonb)
returns integer
language plpgsql security definer set search_path = public as $$
declare
  e record;
  v integer;
  conflicts jsonb;
begin
  if exists (select 1 from schedule_plans where enrollment_id = p_enrollment and state = 'confirmed') then
    raise exception '이미 확정된 일정이 있습니다. 확정 후 변경은 일정 변경 기능으로 (아직 없음).';
  end if;
  -- 아직 수업이 하나도 없으면 (결제만 저장한 학생·강사가 거절한 뒤 다른 안) 첫 수업일에 맞춰 수강 기간을 옮김.
  -- 수강 기간은 첫 정규 수업일부터 (POL-PER-01~03)
  update enrollments set start_date = p_start, base_end_date = p_start + (weeks / 4 * 28 - 1)
  where id = p_enrollment and p_start is not null and start_date is distinct from p_start and weeks is not null
    and not exists (select 1 from lessons where enrollment_id = p_enrollment);
  perform lms_check_plan_shape_lessons(p_enrollment, p_tutor, p_slots, p_start, p_lessons);
  select * into e from enrollments where id = p_enrollment;
  if p_lessons is null then
    conflicts := lms_plan_conflicts(p_tutor, p_slots, e.start_date, e.base_end_date, e.duration_min);
  else
    conflicts := lms_lessons_conflicts(p_tutor, p_lessons, e.duration_min);
  end if;
  if jsonb_array_length(conflicts) > 0 then
    raise exception '일정 충돌 %건 — 저장하지 않았습니다.', jsonb_array_length(conflicts)
      using errcode = 'P0001', detail = conflicts::text, hint = 'schedule_conflict';
  end if;
  update schedule_plans set state = 'withdrawn', closed_at = now(), close_reason = '다른 안으로 바꿈'
  where enrollment_id = p_enrollment and state = 'proposed';
  select coalesce(max(version), 0) + 1 into v from schedule_plans where enrollment_id = p_enrollment;
  insert into schedule_plans (id, enrollment_id, version, tutor_id, slots, start_date, lesson_dates, created_by)
  values (p_plan_id, p_enrollment, v, p_tutor, p_slots, p_start, p_lessons, p_me);
  return v;
end $$;
revoke all on function lms_new_plan_lessons(uuid, uuid, uuid, jsonb, date, uuid, jsonb) from public, anon, authenticated;

-- 예전 이름·모양(6개 인자)은 그대로 두고 새 함수로 넘김
create or replace function lms_new_plan(p_plan_id uuid, p_enrollment uuid, p_tutor uuid, p_slots jsonb, p_start date, p_me uuid)
returns integer
language sql security definer set search_path = public as $$
  select lms_new_plan_lessons(p_plan_id, p_enrollment, p_tutor, p_slots, p_start, p_me, null::jsonb)
$$;
revoke all on function lms_new_plan(uuid, uuid, uuid, jsonb, date, uuid) from public, anon, authenticated;

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
revoke all on function lms_confirm_plan(uuid, uuid) from public, anon, authenticated;

-- 일정안 제안: p.lessons(선택)를 일정안에 함께 저장
create or replace function admin_propose_schedule(p_plan_id uuid, p_enrollment uuid, p jsonb)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  pl record;
  v integer;
begin
  if not is_admin() then raise exception '운영자(추가 인증 완료)만 일정을 제안할 수 있습니다.' using errcode = '42501'; end if;
  if p_plan_id is null then raise exception '요청 번호가 없습니다.'; end if;
  perform pg_advisory_xact_lock(hashtextextended(p_enrollment::text, 0));
  select * into pl from schedule_plans where id = p_plan_id;
  if found then
    if pl.enrollment_id <> p_enrollment then raise exception '요청 번호가 다른 등록에 쓰였습니다.'; end if;
    return jsonb_build_object('plan_id', pl.id, 'version', pl.version, 'state', pl.state, 'repeated', true);
  end if;
  perform set_config('app.actor_id', me::text, true);
  perform set_config('app.actor_via', 'admin_propose_schedule', true);
  v := lms_new_plan_lessons(p_plan_id, p_enrollment, nullif(p ->> 'tutor_id', '')::uuid, coalesce(p -> 'slots', '[]'::jsonb), (p ->> 'start_date')::date, me,
                            nullif(p -> 'lessons', 'null'::jsonb));
  if p ->> 'tutor_answer' = 'accepted' then return lms_confirm_plan(p_plan_id, me); end if;
  return jsonb_build_object('plan_id', p_plan_id, 'version', v, 'state', 'proposed');
end $$;

-- 신규 등록 저장: p.lessons(선택) 전달
create or replace function admin_register_student(p_request_id uuid, p jsonb)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  prev jsonb;
  st jsonb := p -> 'student';
  co jsonb := p -> 'course';
  pay jsonb := p -> 'payment';
  slots jsonb := coalesce(p -> 'slots', '[]'::jsonb);
  v_tutor uuid := nullif(p ->> 'tutor_id', '')::uuid;
  v_weeks smallint := (co ->> 'weeks')::smallint;
  v_weekly smallint := (co ->> 'weekly_count')::smallint;
  v_dur smallint := (co ->> 'duration_min')::smallint;
  v_start date := (co ->> 'start_date')::date;
  v_end date;
  v_paid boolean := jsonb_typeof(p -> 'payment') = 'object';
  sid uuid;
  scode text;
  eid uuid;
  plan_id uuid;
  conf jsonb;
  res jsonb;
begin
  if not is_admin() then
    raise exception '운영자(추가 인증 완료)만 학생을 등록할 수 있습니다.' using errcode = '42501';
  end if;
  if p_request_id is null then raise exception '요청 번호가 없습니다.'; end if;

  -- 같은 요청이 동시에 두 번 와도 하나씩 처리 → 두 번째는 첫 결과를 받음
  perform pg_advisory_xact_lock(hashtextextended(p_request_id::text, 0));
  select result into prev from registration_requests where id = p_request_id;
  if found then return prev || '{"repeated": true}'::jsonb; end if;

  perform set_config('app.actor_id', me::text, true);
  perform set_config('app.actor_via', 'admin_register_student', true);

  if v_weeks is null or v_weeks not in (4, 12, 24) then raise exception '수강 기간은 4·12·24주만 가능합니다.'; end if;
  if v_start is null then raise exception '첫 수업일(수강 시작일)이 없습니다.'; end if;
  v_end := v_start + (v_weeks / 4 * 28 - 1);

  if not v_paid and (v_tutor is not null or jsonb_array_length(slots) > 0) then
    raise exception '결제 확인 전에는 강사·정규 일정을 확정할 수 없습니다 (POL-OP-13).';
  end if;
  if v_tutor is null and jsonb_array_length(slots) > 0 then
    raise exception '정규 시간을 정하려면 강사도 정해야 합니다.';
  end if;

  -- 학생 (항상 새 학생 번호. 같은 이메일이 있어도 연결·병합하지 않음)
  insert into students (name_ko, name_en, email, phone, country, city, timezone, admin_memo)
  values (st ->> 'name_ko', st ->> 'name_en', nullif(lower(trim(st ->> 'email')), ''), nullif(st ->> 'phone', ''),
          nullif(st ->> 'country', ''), nullif(st ->> 'city', ''), st ->> 'timezone', nullif(st ->> 'admin_memo', ''))
  returning id, code into sid, scode;

  insert into enrollments (student_id, seq, weeks, weekly_count, duration_min, start_date, base_end_date,
                           lessons_purchased, amount_due, status, created_by)
  values (sid, 1, v_weeks, v_weekly, v_dur, v_start, v_end, v_weekly * v_weeks,
          nullif(co ->> 'amount_due', '')::integer, case when v_paid then 'confirmed' else 'pending_payment' end, me)
  returning id into eid;

  if v_paid then
    -- paid_at = 실제 입금·결제 완료 시각 (은행 거래내역·아임웹 주문 시각), external_ref = 아임웹 주문번호 등 (같은 결제 두 번 기록 방지)
    insert into payments (enrollment_id, method, payer_name, amount_received, paid_at, received_on, external_ref, confirmed_by)
    values (eid, pay ->> 'method', nullif(pay ->> 'payer_name', ''), (pay ->> 'amount')::integer, (pay ->> 'paid_at')::timestamptz,
            (((pay ->> 'paid_at')::timestamptz at time zone 'UTC') + interval '9 hours')::date, nullif(pay ->> 'external_ref', ''), me);
  end if;

  if v_tutor is not null then
    plan_id := gen_random_uuid();
    perform lms_new_plan_lessons(plan_id, eid, v_tutor, slots, v_start, me, nullif(p -> 'lessons', 'null'::jsonb));   -- 충돌이면 여기서 오류 → 아무것도 저장 안 됨
    if p ->> 'tutor_answer' = 'accepted' then conf := lms_confirm_plan(plan_id, me); end if;
  end if;

  res := jsonb_build_object('student_id', sid, 'student_code', scode, 'enrollment_id', eid,
                            'status', case when v_paid then 'confirmed' else 'pending_payment' end,
                            'plan_id', plan_id,
                            'plan_state', case when plan_id is null then null when conf is null then 'proposed' else 'confirmed' end,
                            'lessons', coalesce((conf ->> 'lessons')::int, 0), 'start_date', v_start, 'end_date', v_end,
                            'tutor_notice_id', conf ->> 'tutor_notice_id', 'student_notice_id', conf ->> 'student_notice_id');
  insert into registration_requests (id, created_by, student_id, enrollment_id, result)
  values (p_request_id, me, sid, eid, res);
  return res;
end $$;

revoke all on function admin_register_student(uuid, jsonb) from public, anon;
grant execute on function admin_register_student(uuid, jsonb) to authenticated;
