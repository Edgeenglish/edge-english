-- =====================================================================
-- 재등록·보강 이월·적립금 운영자 화면 (시안 5차 승인 + 대표 11/9 수정 4가지 — 시험 DB 먼저, 운영 미반영)
--  1. 결제: 실제 결제일(received_on)과 시스템 기록 시각(confirmed_at)을 구분. 결제 시각(paid_at)은 아는 경우에만 (모르면 비움)
--     - payments.paid_at not null → null 허용. 검사 payments_paid_on_matches 는 시각이 있을 때만 날짜와 맞는지 봄
--     - 결제 넣기 함수(신규 등록·재등록)는 payment.paid_on(결제일) 을 받음. 예전처럼 paid_at 만 와도 그 한국 날짜로 기록
--     - 기존 결제 기록은 그대로 (11/8 송O나 STU-0004 정오 기록 포함, 대표 11/9)
--     - 마감 판정(POL-RN-01 '종료일 23:59 KST 안 결제')은 결제일로: received_on <= 종료일 (시각이 있던 기록에서도 같은 뜻)
--  2. admin_renew: 재등록(수강권·변경권·결제) + 정규 일정 확정을 한 번에 (둘 중 하나라도 안 되면 아무것도 저장 안 함)
--  3. 읽기 함수: admin_renewal_context(재등록·이월 화면 바탕 정보) · admin_renewal_conflicts(정규 시간 겹침 미리 검사)
--     · admin_carry_check(이월 보강 시간 겹침 미리 검사) · admin_student_rewards(운영자용 적립금 내역)
--  지우는 것 없음. 다시 실행해도 같은 결과
-- =====================================================================

-- ---------- 1. 결제일 / 결제 시각 ----------
alter table payments alter column paid_at drop not null;
alter table payments drop constraint if exists payments_paid_on_matches;
alter table payments add constraint payments_paid_on_matches
  check (paid_at is null or (((paid_at at time zone 'UTC') + interval '9 hours')::date = received_on));
comment on column payments.paid_at is '실제 결제 시각 — 아는 경우에만 (모르면 비움, 임의 시각 만들지 않음)';
comment on column payments.received_on is '실제 결제일 (한국 날짜) — 마감 판정 기준';

-- 결제 입력(jsonb) → 결제일·결제 시각. paid_on 우선, 없으면 paid_at 의 한국 날짜
create or replace function lms_payment_dates(pay jsonb, out paid_at timestamptz, out received_on date)
language plpgsql stable set search_path = public as $$
begin
  paid_at := nullif(pay ->> 'paid_at', '')::timestamptz;
  received_on := nullif(pay ->> 'paid_on', '')::date;
  if received_on is null and paid_at is not null then
    received_on := ((paid_at at time zone 'UTC') + interval '9 hours')::date;
  end if;
  if received_on is null then raise exception '결제 날짜를 넣어 주세요.' using hint = 'paid_on'; end if;
  if paid_at is not null and ((paid_at at time zone 'UTC') + interval '9 hours')::date <> received_on then
    raise exception '결제 시각과 결제 날짜가 다릅니다.' using hint = 'paid_on';
  end if;
end $$;
revoke all on function lms_payment_dates(jsonb) from public, anon, authenticated;

-- 신규 등록 (20261106000000 과 같고 결제 넣는 부분만 결제일 기준으로)
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
  pd record;
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
  if v_paid then pd := lms_payment_dates(pay); end if;

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
    -- received_on = 실제 결제일, paid_at = 결제 시각(아는 경우만), confirmed_at = 기록 시각(기본값 now)
    insert into payments (enrollment_id, method, payer_name, amount_received, paid_at, received_on, external_ref, confirmed_by)
    values (eid, pay ->> 'method', nullif(pay ->> 'payer_name', ''), (pay ->> 'amount')::integer, pd.paid_at, pd.received_on,
            nullif(pay ->> 'external_ref', ''), me);
  end if;

  if v_tutor is not null then
    plan_id := gen_random_uuid();
    perform lms_new_plan_lessons(plan_id, eid, v_tutor, slots, v_start, me, nullif(p -> 'lessons', 'null'::jsonb));
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

-- 재등록 (20261108050000 과 같고 결제 넣는 부분만 결제일 기준으로)
create or replace function admin_register_renewal(p_request_id uuid, p jsonb)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  prev jsonb;
  co jsonb := p -> 'course';
  pay jsonb := p -> 'payment';
  v_weeks smallint := (co ->> 'weeks')::smallint;
  v_weekly smallint := (co ->> 'weekly_count')::smallint;
  v_dur smallint := (co ->> 'duration_min')::smallint;
  v_start date := (co ->> 'start_date')::date;
  v_amount integer := (pay ->> 'amount')::integer;
  pd record;
  s students;
  pe enrollments;
  eid uuid;
  v_credits smallint;
  i int;
  res jsonb;
begin
  if not is_admin() then
    raise exception '운영자(추가 인증 완료)만 재등록을 넣을 수 있습니다.' using errcode = '42501';
  end if;
  if p_request_id is null then raise exception '요청 번호가 없습니다.'; end if;
  perform pg_advisory_xact_lock(hashtextextended(p_request_id::text, 0));
  select result into prev from registration_requests where id = p_request_id;
  if found then return prev || '{"repeated": true}'::jsonb; end if;

  select * into s from students where code = p ->> 'student_code';
  if not found then raise exception '학생을 찾을 수 없습니다 (%).', p ->> 'student_code'; end if;
  select * into pe from enrollments where student_id = s.id and status <> 'canceled' order by seq desc limit 1;
  if not found then raise exception '이 학생은 수강권이 없습니다. 신규 등록으로 넣어 주세요.'; end if;
  if exists (select 1 from enrollments where previous_enrollment_id = pe.id) then
    raise exception '이미 다음 수강권이 있습니다.';
  end if;

  if v_weeks is null or v_weeks not in (4, 12, 24) then raise exception '수강 기간은 4·12·24주만 가능합니다.'; end if;
  if v_weekly is null or v_weekly not in (1, 2, 3, 5) then raise exception '주 수업 횟수는 1·2·3·5회만 가능합니다.'; end if;
  if v_dur is null or v_dur not in (20, 40, 50) then raise exception '수업 길이는 20·40·50분만 가능합니다.'; end if;
  if v_start is null then raise exception '새 수강권 시작일이 없습니다.'; end if;
  if v_start <= pe.final_end_date then
    raise exception '새 수강권 시작일(%)은 지난 수강권 종료일(%) 뒤여야 합니다.', v_start, pe.final_end_date;
  end if;
  if jsonb_typeof(pay) <> 'object' or v_amount is null or v_amount <= 0 then
    raise exception '재등록은 결제(방법·금액·결제 날짜)를 확인한 뒤에만 넣을 수 있습니다.';
  end if;
  pd := lms_payment_dates(pay);
  if pd.received_on > (now() at time zone 'Asia/Seoul')::date then
    raise exception '결제 날짜(%)가 아직 오지 않은 날짜입니다.', pd.received_on using hint = 'paid_on';
  end if;

  perform set_config('app.actor_id', me::text, true);
  perform set_config('app.actor_via', 'admin_register_renewal', true);

  insert into enrollments (student_id, seq, previous_enrollment_id, weeks, weekly_count, duration_min, start_date, base_end_date,
                           lessons_purchased, amount_due, status, policy_basis, created_by)
  values (s.id, pe.seq + 1, pe.id, v_weeks, v_weekly, v_dur, v_start, v_start + (v_weeks / 4 * 28 - 1),
          v_weekly * v_weeks, nullif(co ->> 'amount_due', '')::integer, 'confirmed', pe.policy_basis, me)
  returning id into eid;

  v_credits := case when v_weekly = 1 then 1 when v_weekly = 2 then 2 else 3 end;
  for i in 1..(v_weeks / 4) loop
    insert into enrollment_periods (enrollment_id, idx, start_date, end_date, credits_granted)
    values (eid, i, v_start + ((i - 1) * 28), v_start + (i * 28 - 1), v_credits)
    on conflict (enrollment_id, idx) do nothing;
  end loop;

  insert into payments (enrollment_id, method, payer_name, amount_received, paid_at, received_on, external_ref, note, confirmed_by)
  values (eid, pay ->> 'method', nullif(pay ->> 'payer_name', ''), v_amount, pd.paid_at, pd.received_on,
          nullif(pay ->> 'external_ref', ''), nullif(p ->> 'note', ''), me);

  res := jsonb_build_object('student_id', s.id, 'student_code', s.code, 'enrollment_id', eid, 'previous_enrollment_id', pe.id,
                            'seq', pe.seq + 1, 'status', 'confirmed', 'start_date', v_start,
                            'end_date', v_start + (v_weeks / 4 * 28 - 1), 'lessons_purchased', v_weekly * v_weeks);
  insert into registration_requests (id, created_by, student_id, enrollment_id, result)
  values (p_request_id, me, s.id, eid, res);
  return res;
end $$;
revoke all on function admin_register_renewal(uuid, jsonb) from public, anon;
grant execute on function admin_register_renewal(uuid, jsonb) to authenticated;

-- 보상권 사용 기한 연결 (20261102100000 과 같고 마감 판정만 결제일 기준)
create or replace function lms_comp_chain(p_enrollment uuid)
returns table (enrollment_id uuid, start_date date, final_end_date date)
language plpgsql stable security definer set search_path = public as $$
declare
  e enrollments;
  n enrollments;
  i int := 0;
begin
  select * into e from enrollments where id = p_enrollment;
  if not found then return; end if;
  loop
    enrollment_id := e.id; start_date := e.start_date; final_end_date := e.final_end_date;
    return next;
    select x.* into n from enrollments x
    where x.previous_enrollment_id = e.id and x.status in ('confirmed', 'active', 'completed')
      and (not exists (select 1 from payments p where p.enrollment_id = x.id)
           or exists (select 1 from payments p where p.enrollment_id = x.id and p.received_on <= e.final_end_date));
    exit when not found;
    i := i + 1;
    exit when i > 50;
    e := n;
  end loop;
end $$;
revoke all on function lms_comp_chain(uuid) from public, anon, authenticated;

-- 보강 이월 (20261108060000 과 같고 마감 판정만 결제일 기준)
create or replace function admin_carry_over_makeups(p_request_id uuid, p jsonb)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  prev jsonb;
  s students;
  en enrollments;
  pe enrollments;
  v_tutor uuid;
  it jsonb;
  d date;
  t timestamptz;
  m migrated_items;
  l lessons;
  lid uuid;
  why text;
  n int := 0;
  done jsonb := '[]'::jsonb;
  res jsonb;
begin
  if not is_admin() then raise exception '운영자(추가 인증 완료)만 처리할 수 있습니다.' using errcode = '42501'; end if;
  if p_request_id is null then raise exception '요청 번호가 없습니다.'; end if;
  perform pg_advisory_xact_lock(hashtextextended(p_request_id::text, 0));
  select result into prev from registration_requests where id = p_request_id;
  if found then return prev || '{"repeated": true}'::jsonb; end if;

  select * into s from students where code = p ->> 'student_code';
  if not found then raise exception '학생을 찾을 수 없습니다 (%).', p ->> 'student_code'; end if;
  select * into en from enrollments where student_id = s.id and previous_enrollment_id is not null
    and status in ('confirmed', 'active') order by seq desc limit 1 for update;
  if not found then raise exception '재등록한 수강권이 없습니다. 재등록을 먼저 넣어 주세요.'; end if;
  select * into pe from enrollments where id = en.previous_enrollment_id;
  if not exists (select 1 from payments x where x.enrollment_id = en.id and x.received_on <= pe.final_end_date) then
    raise exception '지난 수강권 종료일(%) 23:59 KST 안에 결제한 재등록만 이월할 수 있습니다 (POL-RN-01).', pe.final_end_date;
  end if;
  if jsonb_typeof(p -> 'items') <> 'array' or jsonb_array_length(p -> 'items') = 0 then
    raise exception '이월할 보강을 넣어 주세요.';
  end if;
  select r.tutor_id into v_tutor from regular_schedules r
  where r.student_id = s.id and (r.effective_to is null or r.effective_to >= r.effective_from)
  order by r.effective_from desc limit 1;

  perform set_config('app.actor_id', me::text, true);
  perform set_config('app.actor_via', 'admin_carry_over_makeups', true);

  for it in select * from jsonb_array_elements(p -> 'items') loop
    d := (it ->> 'original_date')::date;
    t := nullif(it ->> 'starts_at', '')::timestamptz;
    if d is null then raise exception '원래 수업 날짜가 없습니다.'; end if;
    if t is not null then
      if v_tutor is null then raise exception '정규 수업 강사를 찾을 수 없습니다.'; end if;
      if t <= now() then raise exception '보강 날짜(%)가 이미 지났습니다.', t; end if;
      if (t at time zone 'Asia/Seoul')::date > en.final_end_date then
        raise exception '보강 날짜(%)가 새 수강권 종료일(%) 뒤입니다.', t, en.final_end_date;
      end if;
      why := lms_makeup_conflict(v_tutor, s.id, t, t + make_interval(mins => pe.duration_min), false);
      if why is not null then
        raise exception '% 보강 시간을 잡을 수 없습니다: %', to_char(t at time zone 'Asia/Seoul', 'MM/DD HH24:MI "KST"'), why using hint = 'schedule_conflict';
      end if;
    end if;

    select * into m from migrated_items x where x.enrollment_id = pe.id and x.kind = 'makeup_open' and x.original_date = d
      order by x.created_at limit 1 for update;
    if found then
      if t is null then
        update migrated_items set enrollment_id = en.id where id = m.id;
      else
        insert into lessons (enrollment_id, student_id, tutor_id, kind, starts_at, ends_at, created_by)
        values (en.id, s.id, v_tutor, 'migrated_makeup', t, t + make_interval(mins => pe.duration_min), me)
        returning id into lid;
        update migrated_items set enrollment_id = en.id, kind = 'makeup_booked', lesson_id = lid where id = m.id;
      end if;
      done := done || jsonb_build_object('original_date', d, 'from', 'sheet', 'starts_at', t, 'tutor_leave', m.tutor_leave);
    else
      select * into l from lessons x where x.enrollment_id = pe.id and x.kst_date = d and x.state = 'canceled' and x.voided_at is null
        and x.class_status::text in ('Student canceled in advance', 'Student canceled in advance (public holiday)',
                                     'Tutor canceled in advance', 'Tutor canceled late')
        and not exists (select 1 from lessons y where y.makeup_of = x.id and y.state <> 'canceled')
      order by x.starts_at limit 1 for update;
      if not found then raise exception '이월할 보강을 찾을 수 없습니다 (원래 수업 %).', d; end if;
      if t is null then raise exception '% 취소 수업의 보강은 날짜를 정해야 이월할 수 있습니다.', d; end if;
      insert into lessons (enrollment_id, student_id, tutor_id, kind, starts_at, ends_at, makeup_of, created_by)
      values (en.id, s.id, v_tutor, 'makeup', t, t + make_interval(mins => pe.duration_min), l.id, me)
      returning id into lid;
      done := done || jsonb_build_object('original_date', d, 'from', 'lms', 'starts_at', t);
    end if;
    n := n + 1;
  end loop;

  update enrollments set lessons_carried_in = lessons_carried_in + n where id = en.id;

  res := jsonb_build_object('student_code', s.code, 'enrollment_id', en.id, 'previous_enrollment_id', pe.id,
                            'carried', n, 'items', done);
  insert into registration_requests (id, created_by, student_id, enrollment_id, result)
  values (p_request_id, me, s.id, en.id, res);
  return res;
end $$;
revoke all on function admin_carry_over_makeups(uuid, jsonb) from public, anon;
grant execute on function admin_carry_over_makeups(uuid, jsonb) to authenticated;

-- ---------- 2. 재등록 + 정규 일정 확정 한 번에 ----------
-- p = admin_register_renewal 의 p + { plan_id, slots: [{weekday, time}], tutor_id? (없으면 지금 정규 일정 강사) }
create or replace function admin_renew(p_request_id uuid, p jsonb)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  r jsonb;
  c jsonb;
  v_tutor uuid := nullif(p ->> 'tutor_id', '')::uuid;
  v_plan uuid := nullif(p ->> 'plan_id', '')::uuid;
  v_hint text;
  sid uuid;
begin
  if not is_admin() then raise exception '운영자(추가 인증 완료)만 재등록을 넣을 수 있습니다.' using errcode = '42501'; end if;
  if v_plan is null then raise exception '요청 번호가 없습니다.'; end if;
  if jsonb_typeof(p -> 'slots') <> 'array' or jsonb_array_length(p -> 'slots') = 0 then raise exception '정규 수업 요일·시간을 넣어 주세요.'; end if;
  select id into sid from students where code = p ->> 'student_code';
  if v_tutor is null then
    select rs.tutor_id into v_tutor from regular_schedules rs
    where rs.student_id = sid and (rs.effective_to is null or rs.effective_to >= rs.effective_from)
    order by rs.effective_from desc limit 1;
  end if;
  if v_tutor is null then raise exception '정규 수업 강사를 찾을 수 없습니다.'; end if;
  r := admin_register_renewal(p_request_id, p);
  begin
    c := admin_propose_schedule(v_plan, (r ->> 'enrollment_id')::uuid,
           jsonb_build_object('tutor_id', v_tutor, 'slots', p -> 'slots', 'start_date', r ->> 'start_date', 'tutor_answer', 'accepted'));
  exception when others then
    get stacked diagnostics v_hint = pg_exception_hint;
    if v_hint is distinct from 'leave_postponed_open' then raise; end if;
    -- 지난 수강권에 날짜 안 잡은 휴무 보강이 있으면(규칙 2750) 일정안만 저장 → 보강 이월 뒤 확정 (admin_confirm_schedule)
    c := admin_propose_schedule(v_plan, (r ->> 'enrollment_id')::uuid,
           jsonb_build_object('tutor_id', v_tutor, 'slots', p -> 'slots', 'start_date', r ->> 'start_date'));
  end;
  return r || jsonb_build_object('plan_id', v_plan, 'plan_state', c ->> 'state', 'lessons', c -> 'lessons',
                                 'wait', case when c ->> 'state' = 'proposed' then 'leave_postponed' end);
end $$;
revoke all on function admin_renew(uuid, jsonb) from public, anon;
grant execute on function admin_renew(uuid, jsonb) to authenticated;

-- ---------- 3. 읽기 ----------
-- 이월할 수 있는 보강 (지난 수강권): 시트 이관 보강권 + LMS 에서 취소한 수업 중 보강이 아직 없는 것 (admin_carry_over_makeups 와 같은 기준)
create or replace function lms_carry_candidates(p_prev uuid)
returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(x order by x ->> 'original_date'), '[]'::jsonb) from (
    select jsonb_build_object('original_date', m.original_date, 'from', 'sheet', 'tutor_leave', m.tutor_leave) x
    from migrated_items m where m.enrollment_id = p_prev and m.kind = 'makeup_open' and m.original_date is not null
    union all
    select jsonb_build_object('original_date', l.kst_date, 'from', 'lms', 'tutor_leave', false)
    from lessons l where l.enrollment_id = p_prev and l.state = 'canceled' and l.voided_at is null
      and l.class_status::text in ('Student canceled in advance', 'Student canceled in advance (public holiday)',
                                   'Tutor canceled in advance', 'Tutor canceled late')
      and not exists (select 1 from lessons y where y.makeup_of = l.id and y.state <> 'canceled')
  ) q
$$;
revoke all on function lms_carry_candidates(uuid) from public, anon, authenticated;

-- 재등록·이월 화면 바탕: 지난 수강권(이번 재등록 기준) · 다음 수강권(있으면) · 강사 · 정규 시간 · 마지막 결제 · 이월 가능 보강
create or replace function admin_renewal_context(p_student uuid)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  last enrollments;
  pe enrollments;
  nx enrollments;
  v_tutor uuid;
  pay payments;
  nxpay payments;
begin
  if not is_admin() then raise exception '운영자(추가 인증 완료)만 볼 수 있습니다.' using errcode = '42501'; end if;
  select * into last from enrollments where student_id = p_student and status <> 'canceled' order by seq desc limit 1;
  if not found then return jsonb_build_object('prev', null); end if;
  if last.previous_enrollment_id is not null and last.status in ('confirmed', 'active')
     and last.start_date > (now() at time zone 'Asia/Seoul')::date then
    nx := last;
    select * into pe from enrollments where id = last.previous_enrollment_id;
  else
    pe := last;
  end if;
  select rs.tutor_id into v_tutor from regular_schedules rs
  where rs.student_id = p_student and (rs.effective_to is null or rs.effective_to >= rs.effective_from)
  order by rs.effective_from desc limit 1;
  select * into pay from payments where enrollment_id = pe.id order by received_on desc, confirmed_at desc limit 1;
  if nx.id is not null then
    select * into nxpay from payments where enrollment_id = nx.id order by received_on desc, confirmed_at desc limit 1;
  end if;
  return jsonb_build_object(
    'prev', jsonb_build_object('id', pe.id, 'seq', pe.seq, 'weeks', pe.weeks, 'legacy_label', pe.legacy_label, 'weekly_count', pe.weekly_count,
                               'duration_min', pe.duration_min, 'final_end_date', pe.final_end_date,
                               'left_regular', (select count(*) from lessons l where l.enrollment_id = pe.id and l.kind = 'regular'
                                                and l.state = 'scheduled' and l.starts_at > now()),
                               'last_amount', pay.amount_received, 'last_method', pay.method),
    'next', case when nx.id is null then null else jsonb_build_object(
               'id', nx.id, 'seq', nx.seq, 'weeks', nx.weeks, 'weekly_count', nx.weekly_count, 'duration_min', nx.duration_min,
               'start_date', nx.start_date, 'final_end_date', nx.final_end_date, 'carried_in', nx.lessons_carried_in,
               'paid_on', nxpay.received_on, 'method', nxpay.method,
               'plan_confirmed', exists (select 1 from schedule_plans sp where sp.enrollment_id = nx.id and sp.state = 'confirmed'),
               'plan_proposed', (select sp.id from schedule_plans sp where sp.enrollment_id = nx.id and sp.state = 'proposed' order by sp.version desc limit 1)) end,
    'tutor', (select jsonb_build_object('id', t.id, 'name', t.name, 'timezone', t.timezone) from tutors t where t.id = v_tutor),
    'slots', coalesce((select jsonb_agg(jsonb_build_object('weekday', rs.weekday, 'time', to_char(rs.start_time_kst, 'HH24:MI')) order by rs.weekday)
                       from regular_schedules rs where rs.student_id = p_student and rs.tutor_id = v_tutor
                         and rs.effective_from <= greatest(pe.final_end_date, coalesce(nx.start_date, pe.final_end_date))
                         and (rs.effective_to is null or rs.effective_to >= pe.final_end_date)), '[]'::jsonb),
    'carry_ok', nx.id is not null and exists (select 1 from payments x where x.enrollment_id = nx.id and x.received_on <= pe.final_end_date),
    'carry', lms_carry_candidates(pe.id));
end $$;
revoke all on function admin_renewal_context(uuid) from public, anon;
grant execute on function admin_renewal_context(uuid) to authenticated;

-- 재등록 정규 시간 미리 검사: 새 수강권 기간 전체에서 강사 겹침 (일정 확정 lms_plan_conflicts 와 같은 검사,
-- 단 이 학생 자신의 '재등록 대기 자리'는 빼고 봄 — 저장할 때는 새 수강권이 생겨 자기 자리에 걸리지 않음)
create or replace function admin_renewal_conflicts(p_student uuid, p_slots jsonb, p_start date, p_weeks smallint, p_dur smallint, p_tutor uuid default null)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_break interval := interval '10 minutes';   -- POL-OP-21
  v_tutor uuid := p_tutor;
  v_end date := p_start + (p_weeks / 4 * 28 - 1);
  d date := p_start;
  s jsonb;
  t0 timestamptz;
  t1 timestamptz;
  out jsonb := '[]'::jsonb;
begin
  if not is_admin() then raise exception '운영자(추가 인증 완료)만 볼 수 있습니다.' using errcode = '42501'; end if;
  if v_tutor is null then
    select rs.tutor_id into v_tutor from regular_schedules rs
    where rs.student_id = p_student and (rs.effective_to is null or rs.effective_to >= rs.effective_from)
    order by rs.effective_from desc limit 1;
  end if;
  if v_tutor is null or p_start is null or p_weeks is null or p_dur is null then return '[]'::jsonb; end if;
  while d <= v_end loop
    select x into s from jsonb_array_elements(p_slots) x where (x ->> 'weekday')::int = extract(dow from d);
    if found then
      t0 := (d + (s ->> 'time')::time) at time zone 'Asia/Seoul';
      t1 := t0 + make_interval(mins => p_dur);
      out := out || coalesce((
        select jsonb_agg(jsonb_build_object('date', d, 'weekday', s -> 'weekday', 'time', s ->> 'time',
                 'reason', case when l.starts_at < t1 and t0 < l.ends_at then 'lesson' else 'break' end))
        from lessons l
        where l.tutor_id = v_tutor and l.state <> 'canceled' and l.student_id <> p_student
          and l.starts_at < t1 + v_break and t0 - v_break < l.ends_at), '[]'::jsonb);
      out := out || coalesce((
        select jsonb_agg(jsonb_build_object('date', d, 'weekday', s -> 'weekday', 'time', s ->> 'time', 'reason', 'time_off'))
        from tutor_time_off o where o.tutor_id = v_tutor and o.starts_at < t1 and t0 < o.ends_at), '[]'::jsonb);
      out := out || coalesce((
        select jsonb_agg(jsonb_build_object('date', d, 'weekday', s -> 'weekday', 'time', s ->> 'time', 'reason', 'hold'))
        from lms_slot_hold_hits(v_tutor, t0, t1) h where h.student_id <> p_student), '[]'::jsonb);
    end if;
    d := d + 1;
  end loop;
  return out;
end $$;
revoke all on function admin_renewal_conflicts(uuid, jsonb, date, smallint, smallint, uuid) from public, anon;
grant execute on function admin_renewal_conflicts(uuid, jsonb, date, smallint, smallint, uuid) to authenticated;

-- 보강 이월 시간 미리 검사 (저장 때 admin_carry_over_makeups 가 하는 것과 같은 lms_makeup_conflict)
-- p_items = [{original_date, starts_at}] → [{original_date, reason}] (문제 있는 줄만)
create or replace function admin_carry_check(p_student uuid, p_items jsonb)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_tutor uuid;
  v_dur smallint;
  v_end date;
  it jsonb;
  t timestamptz;
  why text;
  out jsonb := '[]'::jsonb;
begin
  if not is_admin() then raise exception '운영자(추가 인증 완료)만 볼 수 있습니다.' using errcode = '42501'; end if;
  select rs.tutor_id into v_tutor from regular_schedules rs
  where rs.student_id = p_student and (rs.effective_to is null or rs.effective_to >= rs.effective_from)
  order by rs.effective_from desc limit 1;
  select pe.duration_min, en.final_end_date into v_dur, v_end
  from enrollments en join enrollments pe on pe.id = en.previous_enrollment_id
  where en.student_id = p_student and en.status in ('confirmed', 'active') order by en.seq desc limit 1;
  for it in select * from jsonb_array_elements(coalesce(p_items, '[]'::jsonb)) loop
    t := nullif(it ->> 'starts_at', '')::timestamptz;
    if t is null then continue; end if;
    why := case when v_tutor is null or v_dur is null then '재등록 수강권·강사를 찾을 수 없어요'
                when t <= now() then '이미 지난 시간이에요'
                when (t at time zone 'Asia/Seoul')::date > v_end then '새 수강권 종료일 뒤예요'
                else lms_makeup_conflict(v_tutor, p_student, t, t + make_interval(mins => v_dur), false) end;
    if why is not null then out := out || jsonb_build_object('original_date', it ->> 'original_date', 'reason', why); end if;
  end loop;
  return out;
end $$;
revoke all on function admin_carry_check(uuid, jsonb) from public, anon;
grant execute on function admin_carry_check(uuid, jsonb) to authenticated;

-- 운영자용 적립금: 잔액 + 내역 (최신 순)
create or replace function admin_student_rewards(p_student uuid)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not is_admin() then raise exception '운영자(추가 인증 완료)만 볼 수 있습니다.' using errcode = '42501'; end if;
  return jsonb_build_object(
    'balance', reward_balance(p_student),
    'rows', coalesce((select jsonb_agg(jsonb_build_object('id', r.id, 'at', r.created_at, 'kind', r.kind, 'amount', r.amount, 'note', r.note)
                                       order by r.created_at desc)
                      from reward_ledger r where r.student_id = p_student), '[]'::jsonb));
end $$;
revoke all on function admin_student_rewards(uuid) from public, anon;
grant execute on function admin_student_rewards(uuid) to authenticated;
