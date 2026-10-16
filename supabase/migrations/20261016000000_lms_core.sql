-- =====================================================================
-- 엣지영어 LMS 핵심 스키마 (초안 v0.1, 2026-10-16)
-- 설계 설명: docs/lms/05-architecture.md
--
-- ⚠️ 초안입니다. 실제 Supabase 프로젝트에는 운영자 승인 전까지 적용하지 않습니다.
--    로컬 PostgreSQL 검증: supabase/tests/run.sh
--
-- 원칙
--  1. 데이터 원본은 이 DB 하나. Google 시트·캘린더는 복사본(보고·표시용)
--  2. 시각은 timestamptz(UTC)로 저장, 운영 규칙·기간은 한국 날짜(date) 기준
--  3. 수업·기록은 지우지 않는다 (취소 = 상태 변경). 모든 변경은 audit_log 에 남음
--  4. 겹치는 수업·두 번 차감은 DB 제약으로 막는다 (화면·서버 검사가 뚫려도 마지막 방어선)
--  5. 학생·강사의 쓰기는 서버(검증된 로그인 + 규칙 검사)만 함. 앱 사용자에게는 읽기 권한만, 그것도 본인 것만
--  6. 아직 정하지 않은 운영 규칙(급여 수치, 보상수업 기한, 환불 계산 등)은 값을 비워 둔다
-- =====================================================================

create extension if not exists btree_gist;

-- ---------------------------------------------------------------------
-- 공통
-- ---------------------------------------------------------------------

create or replace function is_valid_timezone(tz text) returns boolean
language plpgsql immutable as $$
begin
  perform now() at time zone tz;
  return true;
exception when others then
  return false;
end $$;

create or replace function touch_updated_at() returns trigger
language plpgsql as $$
begin
  new.updated_at := now();
  return new;
end $$;

-- 수업·기록·장부는 삭제 금지 (취소·정정으로만 처리)
create or replace function forbid_delete() returns trigger
language plpgsql as $$
begin
  raise exception '% 의 기록은 삭제할 수 없습니다. 취소·정정으로 처리하세요.', tg_table_name;
end $$;

-- ---------------------------------------------------------------------
-- 사람: 학생 · 강사 · 로그인 연결
-- ---------------------------------------------------------------------

create sequence student_code_seq start 1;

create table students (
  id uuid primary key default gen_random_uuid(),
  -- 영구 고유번호. 재등록해도 그대로. 기존 시트의 STU-0001 형식을 이어 씀
  code text not null unique default ('STU-' || lpad(nextval('student_code_seq')::text, 4, '0'))
    check (code ~ '^STU-\d{4,}$'),
  name_ko text not null,
  name_en text not null,
  display_name text,                      -- 강사에게 보이는 이름 (영문 이름 겹칠 때 구분용)
  email text,
  phone text,                              -- 국내: 휴대폰, 해외: 카카오톡 ID 등
  country text,
  city text,
  timezone text not null default 'Asia/Seoul' check (is_valid_timezone(timezone)),
  gender_age text,                         -- 예: 여성/30대 (신청서 항목)
  self_intro_en text,
  level text,
  class_type text,                         -- textbook / free talk
  correction_pref text,
  textbook text,
  class_note_url text,                     -- 수업 노트(구글 문서) 링크
  status text not null default 'active' check (status in ('active', 'paused', 'ended')),
  admin_memo text,                         -- 운영자만 봄
  legacy_row_ref text,                     -- 이관 시 원래 시트 위치 (검증용)
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create trigger students_touch before update on students for each row execute function touch_updated_at();

create table tutors (
  id uuid primary key default gen_random_uuid(),
  name text not null unique,               -- 영문 이름 (Cindy)
  name_ko_sound text,                      -- 한글 소리 이름 (신디)
  country text not null,
  timezone text not null check (is_valid_timezone(timezone)),   -- IANA (Australia/Sydney)
  email text,
  meet_url text,
  google_calendar_id text,                 -- 엣지영어 계정 소유 강사별 보조 캘린더
  status text not null default 'active' check (status in ('active', 'on_leave', 'inactive')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create trigger tutors_touch before update on tutors for each row execute function touch_updated_at();

create table app_users (
  auth_user_id uuid primary key,           -- Supabase auth.users.id
  role text not null check (role in ('admin', 'tutor', 'student')),
  student_id uuid unique references students(id),
  tutor_id uuid unique references tutors(id),
  created_at timestamptz not null default now(),
  check ((role = 'student') = (student_id is not null)),
  check ((role = 'tutor') = (tutor_id is not null))
);

-- ---------------------------------------------------------------------
-- 가격 · 수강등록 · 기간 · 결제
-- ---------------------------------------------------------------------

-- 1개월(4주) 정가표. 가격이 바뀌면 새 행 추가 (과거 등록 금액은 enrollments 에 그대로 남음)
create table price_list (
  id uuid primary key default gen_random_uuid(),
  duration_min smallint not null check (duration_min in (20, 40, 50)),
  weekly_count smallint not null check (weekly_count in (1, 2, 3, 5)),
  price_4w integer not null check (price_4w > 0),   -- 원
  effective_from date not null,
  effective_to date,
  exclude using gist (duration_min with =, weekly_count with =,
                      daterange(effective_from, effective_to, '[]') with &&)
);

create table enrollments (
  id uuid primary key default gen_random_uuid(),
  student_id uuid not null references students(id),
  seq integer not null check (seq >= 1),                         -- 몇 번째 등록
  previous_enrollment_id uuid unique references enrollments(id), -- 재등록이면 직전 등록
  weeks smallint not null check (weeks in (4, 12, 24)),
  weekly_count smallint not null check (weekly_count in (1, 2, 3, 5)),
  duration_min smallint not null check (duration_min in (20, 40, 50)),
  start_date date not null,                -- 최초: 첫 정규 수업일 / 재등록: 이전 최종 종료일 다음 날
  base_end_date date not null,             -- 시작일 + 28일 × 기간 수 - 1
  extension_days integer not null default 0 check (extension_days >= 0),  -- 장기 연기·강사 휴무 등 (사유는 extensions)
  final_end_date date generated always as (base_end_date + extension_days) stored,
  lessons_purchased integer not null check (lessons_purchased > 0),
  lessons_carried_in integer not null default 0 check (lessons_carried_in >= 0),  -- 이월 받은 수업 수
  amount_due integer check (amount_due >= 0),                   -- 등록 당시 결제할 금액 (원, 스냅샷)
  status text not null default 'pending_payment'
    check (status in ('pending_payment', 'confirmed', 'active', 'completed', 'canceled')),
  created_by uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (student_id, seq),
  check (base_end_date = start_date + (weeks / 4 * 28 - 1)),
  check (lessons_purchased = weekly_count * weeks),
  -- 같은 학생의 수강기간은 겹칠 수 없음
  exclude using gist (student_id with =, daterange(start_date, final_end_date, '[]') with &&)
    where (status <> 'canceled')
);
create trigger enrollments_touch before update on enrollments for each row execute function touch_updated_at();

-- 4주(28일) 단위 기간. 변경권은 기간마다 새로 지급
create table enrollment_periods (
  id uuid primary key default gen_random_uuid(),
  enrollment_id uuid not null references enrollments(id),
  idx smallint not null check (idx between 1 and 6),
  start_date date not null,
  end_date date not null,
  credits_granted smallint not null check (credits_granted between 0 and 3),
  unique (enrollment_id, idx),
  check (end_date = start_date + 27)
);

-- 기간 연장 사유 (장기 연기·강사 휴무 등). 합계가 enrollments.extension_days
create table enrollment_extensions (
  id uuid primary key default gen_random_uuid(),
  enrollment_id uuid not null references enrollments(id),
  days integer not null check (days > 0),
  reason text not null check (reason in ('student_long_term_leave', 'tutor_long_term_leave', 'admin_exception')),
  note text,
  approved_by uuid,
  created_at timestamptz not null default now()
);

create table payments (
  id uuid primary key default gen_random_uuid(),
  enrollment_id uuid not null references enrollments(id),
  method text not null check (method in ('bank_transfer', 'card_link')),
  payer_name text,
  amount_due integer not null check (amount_due >= 0),
  amount_received integer check (amount_received >= 0),
  received_on date,
  status text not null default 'awaiting' check (status in ('awaiting', 'confirmed', 'mismatch')),
  confirmed_by uuid,
  confirmed_at timestamptz,
  note text,
  created_at timestamptz not null default now()
);

-- 환불: 금액은 운영자가 직접 입력·승인. 자동 계산하지 않음 (환불 규정 미확정)
create table refunds (
  id uuid primary key default gen_random_uuid(),
  payment_id uuid not null references payments(id),
  amount integer not null check (amount > 0),
  reason text not null,
  status text not null default 'requested' check (status in ('requested', 'approved', 'paid', 'rejected')),
  approved_by uuid,
  approved_at timestamptz,
  paid_at timestamptz,
  note text,
  created_at timestamptz not null default now()
);

-- ---------------------------------------------------------------------
-- 고정 스케줄 · 수업
-- ---------------------------------------------------------------------

-- 매주 고정 요일·시각(KST). 바뀌면 기존 행 effective_to 를 닫고 새 행 추가 (이력 보존)
create table regular_schedules (
  id uuid primary key default gen_random_uuid(),
  student_id uuid not null references students(id),
  tutor_id uuid not null references tutors(id),
  weekday smallint not null check (weekday between 0 and 6),   -- 0=일 … 6=토 (한국 날짜 기준)
  start_time_kst time not null,
  duration_min smallint not null check (duration_min in (20, 40, 50)),
  effective_from date not null,
  effective_to date,
  change_reason text,
  created_at timestamptz not null default now(),
  -- 한 학생은 같은 요일에 정규 수업 1개
  exclude using gist (student_id with =, weekday with =,
                      daterange(effective_from, effective_to, '[]') with &&)
);

create type class_status as enum (
  'Normal',
  'Make-up completed',
  'Student canceled in advance',
  'Student canceled in advance (public holiday)',
  'Tutor canceled in advance',
  'Student canceled late',
  'Tutor canceled late',
  'Student no-show',
  'Tutor no-show',
  'Tutor long-term leave',
  'Student long-term leave',
  'No change credits left',
  'Tutor Late - Student Present',
  'Covered by another tutor'
);

-- 상태매핑표 (Master Sheet 2026-10-16 값 그대로. 바뀌면 이 표만 고침)
create table class_status_rules (
  status class_status primary key,
  student_label text not null,
  consumes_lesson boolean not null,
  uses_credit boolean not null,
  tutor_paid boolean not null,
  incentive text not null check (incentive in ('none', 'late_cancel', 'no_show', 'late'))
);
insert into class_status_rules values
  ('Normal', '정상 진행', true, false, true, 'none'),
  ('Make-up completed', '보강 완료', true, false, true, 'none'),
  ('Student canceled in advance', '학생 정상 취소 👉 수강기간 내 보강 가능', false, true, false, 'none'),
  ('Student canceled in advance (public holiday)', '공휴일 취소 👉 수강기간 내 보강 가능', false, false, false, 'none'),
  ('Tutor canceled in advance', '강사 정상 취소 👉 수강기간 내 보강 가능', false, false, false, 'none'),
  ('Student canceled late', '학생 늦은 취소 👉 보강 불가', true, false, true, 'none'),
  ('Tutor canceled late', '강사 늦은 취소 👉 수강기간 내 보강 가능', false, false, false, 'late_cancel'),
  ('Student no-show', '학생 노쇼 👉 보강 불가', true, false, true, 'none'),
  ('Tutor no-show', '강사 노쇼 👉 보강 1회 + 보상수업 1회(무료)', false, false, false, 'no_show'),
  ('Tutor long-term leave', '강사 장기 휴식 👉 수강기간 연장', false, false, false, 'none'),
  ('Student long-term leave', '학생 장기 연기 👉 수강기간 최대 2주 연장(6개월(24주) 수강 학생만)', false, false, false, 'none'),
  ('No change credits left', '변경권 소진 👉 보강 불가', true, false, true, 'none'),
  ('Tutor Late - Student Present', '강사 지각(정상 진행)', true, false, true, 'late'),
  ('Covered by another tutor', '대타 강사 진행', true, false, true, 'none');

create table lessons (
  id uuid primary key default gen_random_uuid(),
  enrollment_id uuid not null references enrollments(id),
  student_id uuid not null references students(id),
  tutor_id uuid not null references tutors(id),          -- 실제 수업하는 강사
  original_tutor_id uuid references tutors(id),          -- 대체 강사 배정 시 원래 담당
  kind text not null check (kind in ('regular', 'makeup', 'compensation')),
  seq integer,                                           -- 정규 회차 번호
  starts_at timestamptz not null,
  ends_at timestamptz not null,
  -- 한국 날짜 (KST = UTC+9 고정, 서머타임 없음)
  kst_date date generated always as (((starts_at at time zone 'UTC') + interval '9 hours')::date) stored,
  state text not null default 'scheduled' check (state in ('scheduled', 'canceled', 'done')),
  class_status class_status,                              -- 결과 (원본은 여기 하나)
  makeup_of uuid references lessons(id),                  -- 보강이면 원래 수업
  compensation_id uuid,                                   -- 보상 수업이면 보상권
  canceled_at timestamptz,
  cancel_reason text,
  created_by uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (ends_at > starts_at),
  check ((kind = 'makeup') = (makeup_of is not null)),
  check ((kind = 'compensation') = (compensation_id is not null)),
  check ((kind = 'regular') = (seq is not null)),
  check (state <> 'canceled' or canceled_at is not null),
  -- 같은 강사에게 겹치는 수업 금지 (취소된 수업은 제외)
  constraint lessons_no_tutor_overlap exclude using gist
    (tutor_id with =, tstzrange(starts_at, ends_at) with &&) where (state <> 'canceled'),
  -- 같은 학생에게 겹치는 수업 금지
  constraint lessons_no_student_overlap exclude using gist
    (student_id with =, tstzrange(starts_at, ends_at) with &&) where (state <> 'canceled')
);
create trigger lessons_touch before update on lessons for each row execute function touch_updated_at();
create trigger lessons_no_delete before delete on lessons for each row execute function forbid_delete();
create index lessons_tutor_time on lessons (tutor_id, starts_at);
create index lessons_student_time on lessons (student_id, starts_at);
create unique index lessons_regular_seq on lessons (enrollment_id, seq) where kind = 'regular';
-- 한 수업의 보강은 살아 있는 것 1개만
create unique index lessons_one_live_makeup on lessons (makeup_of) where state <> 'canceled';

-- 강사 수업 기록 (Covered Topics · Remarks · 기록 시각). 결과 상태는 lessons.class_status
create table class_records (
  lesson_id uuid primary key references lessons(id),
  covered_topics text,
  remarks text,
  first_submitted_at timestamptz not null default now(),  -- 인센티브 '10분 안 기록' 기준 (서버 시각)
  submitted_by uuid,
  updated_at timestamptz not null default now()
);
create trigger class_records_touch before update on class_records for each row execute function touch_updated_at();
create trigger class_records_no_delete before delete on class_records for each row execute function forbid_delete();
-- 최초 기록 시각은 고칠 수 없음
create or replace function keep_first_submitted_at() returns trigger
language plpgsql as $$
begin
  new.first_submitted_at := old.first_submitted_at;
  return new;
end $$;
create trigger class_records_keep_first before update on class_records
  for each row execute function keep_first_submitted_at();

-- ---------------------------------------------------------------------
-- 변경 · 보강 · 변경권 · 보상 수업
-- ---------------------------------------------------------------------

-- 모든 변경 요청·처리 (학생 취소, 강사 취소, 고정 시간 변경 요청, 강사 휴무 일괄 처리 …)
create table change_requests (
  id uuid primary key default gen_random_uuid(),
  lesson_id uuid references lessons(id),
  student_id uuid references students(id),
  type text not null check (type in (
    'student_cancel', 'tutor_cancel', 'admin_cancel',
    'fixed_schedule_change', 'tutor_change', 'student_long_term_leave', 'tutor_leave')),
  status text not null check (status in ('applied', 'pending', 'approved', 'rejected', 'withdrawn', 'reverted')),
  via text not null check (via in ('student_app', 'tutor_app', 'admin_app', 'admin_on_behalf', 'system')),
  decision jsonb,                          -- 규칙 검사 결과 그대로 (나중에 왜 그렇게 됐는지 확인용)
  reason text,
  batch_id uuid,                           -- 일괄 처리 묶음 (한 번에 되돌리기)
  idempotency_key text unique,             -- 같은 요청 두 번 처리 방지
  requested_by uuid,
  decided_by uuid,
  created_at timestamptz not null default now(),
  decided_at timestamptz
);
create index change_requests_batch on change_requests (batch_id) where batch_id is not null;

create table makeup_requests (
  id uuid primary key default gen_random_uuid(),
  source_lesson_id uuid not null references lessons(id),
  student_id uuid not null references students(id),
  tutor_id uuid not null references tutors(id),
  status text not null default 'requested'
    check (status in ('requested', 'countered', 'confirmed', 'declined', 'expired', 'withdrawn')),
  confirmed_lesson_id uuid unique references lessons(id),
  tutor_note text,
  remind_at timestamptz,                   -- 강사 무응답 재알림 시각 (기준 시간은 미확정)
  created_at timestamptz not null default now(),
  decided_at timestamptz,
  check ((status = 'confirmed') = (confirmed_lesson_id is not null))
);
-- 한 수업에 진행 중인 보강 신청은 1개
create unique index makeup_requests_one_open on makeup_requests (source_lesson_id)
  where status in ('requested', 'countered');

create table makeup_candidates (
  id uuid primary key default gen_random_uuid(),
  request_id uuid not null references makeup_requests(id),
  starts_at timestamptz not null,
  ends_at timestamptz not null,
  proposed_by text not null check (proposed_by in ('student', 'tutor')),
  check (ends_at > starts_at)
);

-- 변경권 장부: 지급은 enrollment_periods.credits_granted, 사용·복구는 여기에 한 줄씩
create table credit_ledger (
  id uuid primary key default gen_random_uuid(),
  period_id uuid not null references enrollment_periods(id),
  lesson_id uuid references lessons(id),
  reason text not null check (reason in ('student_change', 'admin_restore', 'admin_adjust')),
  delta smallint not null check (delta in (-1, 1)),
  note text,
  created_by uuid,
  created_at timestamptz not null default now(),
  unique (lesson_id, reason)               -- 같은 수업 두 번 차감 방지
);
create trigger credit_ledger_no_delete before delete on credit_ledger for each row execute function forbid_delete();

create or replace function credit_balance(p_period uuid) returns integer
language sql stable as $$
  select p.credits_granted + coalesce((select sum(delta) from credit_ledger where period_id = p.id), 0)::int
  from enrollment_periods p where p.id = p_period
$$;

-- 0개 미만·지급량 초과 방지. 기간 행을 잠가서 동시에 두 번 눌러도 순서대로 처리
create or replace function credit_ledger_guard() returns trigger
language plpgsql as $$
declare
  granted integer;
  bal integer;
begin
  select credits_granted into granted from enrollment_periods where id = new.period_id for update;
  bal := credit_balance(new.period_id) + new.delta;
  if bal < 0 then raise exception '변경권이 남아 있지 않습니다.'; end if;
  if bal > granted then raise exception '지급된 변경권보다 많이 복구할 수 없습니다.'; end if;
  return new;
end $$;
create trigger credit_ledger_guard before insert on credit_ledger for each row execute function credit_ledger_guard();
create or replace function forbid_update() returns trigger
language plpgsql as $$
begin
  raise exception '% 은(는) 수정할 수 없습니다. 반대 기록을 추가하세요.', tg_table_name;
end $$;
create trigger credit_ledger_no_update before update on credit_ledger for each row execute function forbid_update();

-- 보상 수업권 (강사 노쇼 등). 사용 기한은 미확정 → expires_on 비워 둠
create table compensations (
  id uuid primary key default gen_random_uuid(),
  student_id uuid not null references students(id),
  enrollment_id uuid not null references enrollments(id),
  source_lesson_id uuid not null unique references lessons(id),
  reason text not null check (reason in ('tutor_no_show', 'admin_exception')),
  status text not null default 'available' check (status in ('available', 'used', 'expired', 'voided')),
  expires_on date,
  used_lesson_id uuid unique references lessons(id),
  confirmed_by uuid not null,              -- 운영자 확정 필수
  created_at timestamptz not null default now(),
  check ((status = 'used') = (used_lesson_id is not null))
);
alter table lessons add constraint lessons_compensation_fk foreign key (compensation_id) references compensations(id);

-- 학생 '[강사가 안 들어왔어요]' 신고. 노쇼 확정은 운영자
create table no_show_reports (
  id uuid primary key default gen_random_uuid(),
  lesson_id uuid not null unique references lessons(id),
  reported_at timestamptz not null default now(),
  status text not null default 'open' check (status in ('open', 'tutor_arrived', 'confirmed_no_show', 'dismissed')),
  resolved_by uuid,
  resolved_at timestamptz,
  note text
);

-- ---------------------------------------------------------------------
-- 강사 가능 시간 · 휴무
-- ---------------------------------------------------------------------

-- 주간 수업 가능 시간 (강사 현지 시각 + 시간대로 저장 → 서머타임이 바뀌어도 강사 기준 유지)
create table tutor_availability (
  id uuid primary key default gen_random_uuid(),
  tutor_id uuid not null references tutors(id),
  weekday smallint not null check (weekday between 0 and 6),
  start_local time not null,
  end_local time not null,
  timezone text not null check (is_valid_timezone(timezone)),
  effective_from date not null default current_date,
  effective_to date,
  check (end_local > start_local)
);

-- 특정 날 막기·장기 휴무
create table tutor_time_off (
  id uuid primary key default gen_random_uuid(),
  tutor_id uuid not null references tutors(id),
  starts_at timestamptz not null,
  ends_at timestamptz not null,
  kind text not null check (kind in ('block', 'leave')),
  reason text,
  notice_given_on date,                    -- 계약서 10조: 14일 전 서면 통보
  created_by uuid,
  created_at timestamptz not null default now(),
  check (ends_at > starts_at)
);

-- ---------------------------------------------------------------------
-- 공휴일 · 설정
-- ---------------------------------------------------------------------

-- 변경권 차감 없이 처리할 한국 공휴일 (운영자가 관리. 어떤 날을 넣을지는 운영자 결정)
create table holidays (
  day date primary key,
  name text not null,
  waives_credit boolean not null default true,
  created_by uuid,
  created_at timestamptz not null default now()
);

create table settings (
  key text primary key,
  value jsonb not null,
  note text,
  updated_by uuid,
  updated_at timestamptz not null default now()
);

-- ---------------------------------------------------------------------
-- 강사 정산 (수치 미확정 → 정책 행이 승인되기 전에는 계산하지 않음)
-- ---------------------------------------------------------------------

create table pay_policies (
  id uuid primary key default gen_random_uuid(),
  effective_from date not null unique,
  base_rate_usd numeric(6, 2) not null,
  max_rate_usd numeric(6, 2) not null,
  rules jsonb not null,                    -- 인센티브 조건·가산액 (승인된 값만)
  approved_by uuid not null,
  approved_at timestamptz not null default now(),
  check (max_rate_usd >= base_rate_usd)
);

create table payroll_runs (
  id uuid primary key default gen_random_uuid(),
  tutor_id uuid not null references tutors(id),
  month date not null check (extract(day from month) = 1),
  policy_id uuid references pay_policies(id),
  status text not null default 'draft' check (status in ('draft', 'approved', 'paid')),
  computed jsonb,                          -- 자동 계산 결과 (참고용)
  final_amount_usd numeric(8, 2),          -- 운영자가 확인·승인한 최종 금액
  approved_by uuid,
  approved_at timestamptz,
  paid_at timestamptz,
  unique (tutor_id, month),
  check (status = 'draft' or (final_amount_usd is not null and approved_by is not null))
);

create table payroll_items (
  id uuid primary key default gen_random_uuid(),
  run_id uuid not null references payroll_runs(id),
  lesson_id uuid not null unique references lessons(id),   -- 같은 수업 두 번 정산 방지
  minutes integer not null check (minutes > 0),
  payable boolean not null,
  note text
);

-- ---------------------------------------------------------------------
-- 알림 · 캘린더 동기화 (보내는 일은 별도 작업자가 함. 실패해도 수업 변경은 유지)
-- ---------------------------------------------------------------------

create table notifications (
  id uuid primary key default gen_random_uuid(),
  recipient_kind text not null check (recipient_kind in ('student', 'tutor', 'admin')),
  recipient_id uuid,
  email text not null,
  locale text not null check (locale in ('ko', 'en')),
  template text not null,
  payload jsonb not null default '{}',
  dedupe_key text not null unique,         -- 같은 알림 두 번 안 보냄
  send_after timestamptz not null default now(),
  status text not null default 'queued' check (status in ('queued', 'sent', 'failed', 'canceled')),
  attempts integer not null default 0,
  last_error text,
  sent_at timestamptz,
  created_at timestamptz not null default now()
);
create index notifications_due on notifications (send_after) where status = 'queued';

-- DB 수업 → 강사 Google 캘린더 반영 상태 (DB가 원본, 캘린더는 복사본)
create table calendar_sync (
  lesson_id uuid primary key references lessons(id),
  calendar_id text not null,
  google_event_id text,                    -- 수업 id로 만든 고정 id → 재시도해도 중복 일정 안 생김
  desired_version integer not null default 1,
  synced_version integer not null default 0,
  attempts integer not null default 0,
  last_error text,
  last_synced_at timestamptz
);
create index calendar_sync_pending on calendar_sync (lesson_id) where synced_version < desired_version;

-- 수업이 바뀌면 캘린더 반영 대기열에 올림 (같은 트랜잭션 → 수업 변경과 함께 저장되거나 함께 취소)
create or replace function enqueue_calendar_sync() returns trigger
language plpgsql as $$
declare
  cal text;
begin
  select google_calendar_id into cal from tutors where id = new.tutor_id;
  if cal is null then return new; end if;
  insert into calendar_sync (lesson_id, calendar_id) values (new.id, cal)
  on conflict (lesson_id) do update
    set desired_version = calendar_sync.desired_version + 1, calendar_id = excluded.calendar_id;
  return new;
end $$;
create trigger lessons_calendar_sync after insert or update of starts_at, ends_at, state, tutor_id on lessons
  for each row execute function enqueue_calendar_sync();

-- ---------------------------------------------------------------------
-- 변경 이력 (누가, 언제, 무엇을 → 이전 상태로 복구 가능)
-- ---------------------------------------------------------------------

create table audit_log (
  id bigint generated always as identity primary key,
  at timestamptz not null default now(),
  actor uuid,                              -- 서버가 트랜잭션마다 set local app.actor_id = '...'
  actor_via text,
  table_name text not null,
  row_id text not null,
  action text not null check (action in ('INSERT', 'UPDATE', 'DELETE')),
  old_row jsonb,
  new_row jsonb
);
create index audit_log_row on audit_log (table_name, row_id, at);

create or replace function write_audit() returns trigger
language plpgsql as $$
declare
  rid text;
begin
  rid := coalesce(
    (case when tg_op = 'DELETE' then to_jsonb(old) else to_jsonb(new) end) ->> 'id',
    (case when tg_op = 'DELETE' then to_jsonb(old) else to_jsonb(new) end) ->> 'lesson_id',
    (case when tg_op = 'DELETE' then to_jsonb(old) else to_jsonb(new) end) ->> 'key',
    (case when tg_op = 'DELETE' then to_jsonb(old) else to_jsonb(new) end) ->> 'day',
    (case when tg_op = 'DELETE' then to_jsonb(old) else to_jsonb(new) end) ->> 'auth_user_id',
    (case when tg_op = 'DELETE' then to_jsonb(old) else to_jsonb(new) end) ->> 'status');
  insert into audit_log (actor, actor_via, table_name, row_id, action, old_row, new_row)
  values (
    nullif(current_setting('app.actor_id', true), '')::uuid,
    nullif(current_setting('app.actor_via', true), ''),
    tg_table_name, rid, tg_op,
    case when tg_op in ('UPDATE', 'DELETE') then to_jsonb(old) end,
    case when tg_op in ('INSERT', 'UPDATE') then to_jsonb(new) end);
  return null;
end $$;

-- 이력은 고치거나 지울 수 없음
create trigger audit_log_no_update before update on audit_log for each row execute function forbid_update();
create trigger audit_log_no_delete before delete on audit_log for each row execute function forbid_delete();

do $$
declare
  t text;
begin
  foreach t in array array[
    'students', 'tutors', 'app_users', 'price_list', 'enrollments', 'enrollment_periods', 'enrollment_extensions',
    'payments', 'refunds', 'regular_schedules', 'lessons', 'class_records', 'change_requests',
    'makeup_requests', 'credit_ledger', 'compensations', 'no_show_reports', 'tutor_availability',
    'tutor_time_off', 'holidays', 'settings', 'pay_policies', 'payroll_runs', 'payroll_items',
    'class_status_rules']
  loop
    execute format('create trigger %I after insert or update or delete on %I for each row execute function write_audit()',
                   t || '_audit', t);
  end loop;
end $$;

-- ---------------------------------------------------------------------
-- 접근 권한 (RLS): 앱 사용자는 본인 것만 '읽기'. 쓰기는 서버만
-- ---------------------------------------------------------------------

create or replace function my_role() returns text
language sql stable security definer set search_path = public as $$
  select role from app_users where auth_user_id = auth.uid()
$$;
create or replace function my_student_id() returns uuid
language sql stable security definer set search_path = public as $$
  select student_id from app_users where auth_user_id = auth.uid()
$$;
create or replace function my_tutor_id() returns uuid
language sql stable security definer set search_path = public as $$
  select tutor_id from app_users where auth_user_id = auth.uid()
$$;
create or replace function is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select role = 'admin' from app_users where auth_user_id = auth.uid()), false)
$$;

do $$
declare
  t text;
begin
  for t in select tablename from pg_tables where schemaname = 'public' loop
    execute format('alter table %I enable row level security', t);
    execute format('revoke all on %I from anon, authenticated', t);
  end loop;
end $$;

-- 운영자: 모든 표 읽기
do $$
declare
  t text;
begin
  for t in select tablename from pg_tables where schemaname = 'public' loop
    execute format('grant select on %I to authenticated', t);
    execute format('create policy admin_read on %I for select to authenticated using (is_admin())', t);
  end loop;
end $$;

-- 학생: 본인 정보·수강·수업·보강·변경권만
create policy student_self on students for select to authenticated using (id = my_student_id());
create policy student_own on enrollments for select to authenticated using (student_id = my_student_id());
create policy student_own on enrollment_periods for select to authenticated
  using (exists (select 1 from enrollments e where e.id = enrollment_id and e.student_id = my_student_id()));
create policy student_own on lessons for select to authenticated using (student_id = my_student_id());
create policy student_own on makeup_requests for select to authenticated using (student_id = my_student_id());
create policy student_own on change_requests for select to authenticated using (student_id = my_student_id());
create policy student_own on compensations for select to authenticated using (student_id = my_student_id());
create policy student_own on credit_ledger for select to authenticated
  using (exists (select 1 from enrollment_periods p join enrollments e on e.id = p.enrollment_id
                 where p.id = period_id and e.student_id = my_student_id()));
create policy everyone_read on class_status_rules for select to authenticated using (true);
create policy everyone_read on holidays for select to authenticated using (true);

-- 강사: 본인 수업·본인 정보·본인 가능 시간·본인 정산만. 학생 정보는 아래 함수로 필요한 칸만
create policy tutor_self on tutors for select to authenticated using (id = my_tutor_id());
create policy tutor_own on lessons for select to authenticated using (tutor_id = my_tutor_id());
create policy tutor_own on class_records for select to authenticated
  using (exists (select 1 from lessons l where l.id = lesson_id and l.tutor_id = my_tutor_id()));
create policy tutor_own on makeup_requests for select to authenticated using (tutor_id = my_tutor_id());
create policy tutor_own on tutor_availability for select to authenticated using (tutor_id = my_tutor_id());
create policy tutor_own on tutor_time_off for select to authenticated using (tutor_id = my_tutor_id());
create policy tutor_own on payroll_runs for select to authenticated using (tutor_id = my_tutor_id() and status <> 'draft');

-- 강사가 볼 수 있는 학생 정보: 최근·예정 수업이 있는 담당 학생, 수업에 필요한 칸만 (휴대폰·한글 실명·운영 메모 제외)
create or replace function tutor_my_students()
returns table (student_id uuid, display_name text, country text, timezone text, gender_age text,
               self_intro_en text, level text, class_type text, correction_pref text, textbook text,
               email text, class_note_url text)
language sql stable security definer set search_path = public as $$
  select s.id, coalesce(s.display_name, s.name_en), s.country, s.timezone, s.gender_age, s.self_intro_en,
         s.level, s.class_type, s.correction_pref, s.textbook, s.email, s.class_note_url
  from students s
  where my_tutor_id() is not null
    and exists (select 1 from lessons l
                where l.student_id = s.id and l.tutor_id = my_tutor_id()
                  and l.starts_at > now() - interval '60 days')
$$;
revoke all on function tutor_my_students() from public, anon;
grant execute on function tutor_my_students() to authenticated;

-- 학생이 볼 수 있는 담당 강사 정보: 이름·국가·강의실 링크만
create or replace function student_my_tutors()
returns table (tutor_id uuid, name text, name_ko_sound text, country text, meet_url text)
language sql stable security definer set search_path = public as $$
  select t.id, t.name, t.name_ko_sound, t.country, t.meet_url
  from tutors t
  where my_student_id() is not null
    and exists (select 1 from lessons l where l.tutor_id = t.id and l.student_id = my_student_id()
                  and l.starts_at > now() - interval '60 days')
$$;
revoke all on function student_my_tutors() from public, anon;
grant execute on function student_my_tutors() to authenticated;
