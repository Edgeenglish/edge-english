-- =====================================================================
-- 기존 학생 재등록 (2026-11-08, 대표 지시: 송O나 STU-0004 재등록 결제를 LMS 에 반영 — LMS 에 재등록 넣는 함수가 없었음)
--  admin_register_renewal(요청 번호, p) : 이미 있는 학생에게 새 수강권 + 결제 기록만 넣는다
--   p = { student_code, course: {weeks, weekly_count, duration_min, start_date, amount_due},
--         payment: {method, amount, paid_at, payer_name?, external_ref?}, note? }
--  - 직전 수강권 = 그 학생의 가장 최근 수강권 (이미 다음 수강권이 있으면 거절)
--  - 새 수강권 시작일은 직전 수강권 종료일 뒤여야 함
--  - 기간(28일)마다 변경권: 주1회 1·주2회 2·주3회 이상 3 (admin_register_student 의 기간 트리거와 같은 계산)
--  - 결제 기록 → 기존 트리거가 '재등록 강사 안내' 할 일을 만듦 (previous_enrollment_id 있음)
--  - 수업(정규 일정)은 만들지 않음: 기존 일정 제안·확정 화면 함수로 (휴무로 미뤄진 수업 규칙 그대로 적용됨)
--  - 같은 요청 번호로 다시 실행하면 처음 결과를 그대로 돌려줌. 기존 표·데이터는 바꾸지 않음
-- =====================================================================
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
  v_paid_at timestamptz := (pay ->> 'paid_at')::timestamptz;
  v_amount integer := (pay ->> 'amount')::integer;
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
  if jsonb_typeof(pay) <> 'object' or v_paid_at is null or v_amount is null or v_amount <= 0 then
    raise exception '재등록은 결제(방법·금액·입금 시각)를 확인한 뒤에만 넣을 수 있습니다.';
  end if;
  if v_paid_at > now() then raise exception '입금 시각이 아직 오지 않은 시각입니다.'; end if;

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
  values (eid, pay ->> 'method', nullif(pay ->> 'payer_name', ''), v_amount, v_paid_at,
          ((v_paid_at at time zone 'UTC') + interval '9 hours')::date, nullif(pay ->> 'external_ref', ''),
          nullif(p ->> 'note', ''), me);

  res := jsonb_build_object('student_id', s.id, 'student_code', s.code, 'enrollment_id', eid, 'previous_enrollment_id', pe.id,
                            'seq', pe.seq + 1, 'status', 'confirmed', 'start_date', v_start,
                            'end_date', v_start + (v_weeks / 4 * 28 - 1), 'lessons_purchased', v_weekly * v_weeks);
  insert into registration_requests (id, created_by, student_id, enrollment_id, result)
  values (p_request_id, me, s.id, eid, res);
  return res;
end $$;

revoke all on function admin_register_renewal(uuid, jsonb) from public, anon;
grant execute on function admin_register_renewal(uuid, jsonb) to authenticated;

-- 재등록을 미리 넣어도 새 수강권이 시작하기 전까지는 지금 수강권을 '현재 수강권'으로 본다
-- (학생 화면·운영진 학생 목록·변경권 화면이 쓰는 함수. 예전: 진행 중/확정 중 seq 가 가장 큰 것 → 결제만 된 다음 수강권이 바로 보였음)
create or replace function lms_student_enrollment(p_student uuid)
returns uuid
language sql stable security definer set search_path = public as $$
  select e.id from enrollments e where e.student_id = p_student
  order by (e.status in ('active', 'confirmed')) desc,
           (e.start_date <= (now() at time zone 'Asia/Seoul')::date) desc,
           e.seq desc
  limit 1
$$;
