-- 자동 생성 파일 (직접 고치지 말 것): node scripts/lms-test-bundle.mjs
-- 시험용 Supabase 프로젝트에만 사용. 빈 프로젝트에 한 번 실행 (두 번 실행하면 "이미 있음" 오류)
begin;
-- >>> 20261016000000_lms_core.sql
-- =====================================================================
-- 엣지영어 LMS 핵심 스키마 v0.2 (2026-10-16)
-- 설계 설명: docs/lms/05-architecture.md, 재검토 기록: docs/lms/09-design-review.md
--
-- ⚠️ 초안입니다. 실제 Supabase 프로젝트에는 운영자 승인 전까지 적용하지 않습니다.
--    로컬 PostgreSQL 검증: npm run test:db
--
-- 단계별 파일 (필요한 단계에서만 적용)
--   20261016000000_lms_core.sql          1~3단계: 학생·강사·등록·회차·기록·변경·변경권·이력·권한
--   20261016000100_lms_selfservice.sql   4단계: 강사 가능 시간·보강 신청
--   20261016000200_lms_notify_calendar.sql 5단계: 알림·캘린더 반영
--   20261016000300_lms_payroll.sql       6단계: 강사 계약 조건·정산
--
-- 원칙
--  1. 데이터 원본은 이 DB 하나. Google 시트·캘린더는 복사본(보고·표시용)
--  2. 시각은 timestamptz(UTC)로 저장, 운영 규칙·기간은 한국 날짜(date) 기준
--  3. 수업·기록·장부는 지우지 않는다 (취소 = 상태 변경). 모든 변경은 audit_log 에 남음
--  4. 겹치는 수업·두 번 차감은 DB 제약으로 막는다 (화면·서버 검사가 뚫려도 마지막 방어선)
--  5. 학생·강사의 쓰기는 서버(검증된 로그인 + 규칙 검사)만. 앱 사용자에게는 본인 것 읽기만
--  6. 운영정책 값은 DB에 두지 않는다 (docs/lms/policy/register.md → src/lms/rules/). 미확정 값은 비워 둔다
--  7. 학생·강사가 받은 계약서·안내서 판본과 전달·동의 근거를 기록한다. 받지 않은 문서의 판본을 붙이지 않는다
-- =====================================================================

create extension if not exists btree_gist;

-- ---------------------------------------------------------------------
-- 공통 함수
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

create or replace function forbid_update() returns trigger
language plpgsql as $$
begin
  raise exception '% 은(는) 수정할 수 없습니다. 반대 기록을 추가하세요.', tg_table_name;
end $$;

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
create trigger audit_log_no_update before update on audit_log for each row execute function forbid_update();
create trigger audit_log_no_delete before delete on audit_log for each row execute function forbid_delete();

create or replace function write_audit() returns trigger
language plpgsql as $$
declare
  r jsonb := case when tg_op = 'DELETE' then to_jsonb(old) else to_jsonb(new) end;
begin
  insert into audit_log (actor, actor_via, table_name, row_id, action, old_row, new_row)
  values (
    nullif(current_setting('app.actor_id', true), '')::uuid,
    nullif(current_setting('app.actor_via', true), ''),
    tg_table_name,
    coalesce(r ->> 'id', r ->> 'lesson_id', r ->> 'code', r ->> 'key', r ->> 'day', r ->> 'auth_user_id', r ->> 'status'),
    tg_op,
    case when tg_op in ('UPDATE', 'DELETE') then to_jsonb(old) end,
    case when tg_op in ('INSERT', 'UPDATE') then to_jsonb(new) end);
  return null;
end $$;

-- 표 하나를 LMS 기본 보호 상태로: 변경 이력 + RLS(앱 사용자는 정책으로 허용된 읽기만) + 운영자 읽기
-- 다음 단계 파일에서도 새 표를 만들면 이 함수를 부른다
create or replace function lms_protect(t regclass) returns void
language plpgsql as $$
begin
  execute format('create trigger %I after insert or update or delete on %s for each row execute function write_audit()',
                 replace(t::text, '.', '_') || '_audit', t);
  execute format('alter table %s enable row level security', t);
  execute format('revoke all on %s from anon, authenticated', t);
  execute format('grant select on %s to authenticated', t);
  execute format('create policy admin_read on %s for select to authenticated using (is_admin())', t);
end $$;

-- ---------------------------------------------------------------------
-- 계약서·안내서 판본 (기존 학생·강사와 신규의 적용 조건이 다를 수 있음)
-- - contract: 수강계약서·강사계약서 (서명 또는 결제로 동의하는 문서)
-- - guide: 수업 전 필독안내서 등 안내 문서 (계약서와 법적 성격이 다를 수 있음 — 미확인)
-- 2026년 초 어느 시점부터 학생 계약서 발송을 중단하고 필독안내서만 보냄 (POL-OP-09)
-- → 계약서를 받지 않은 학생에게 계약서 판본을 붙이지 않는다. 받은 문서가 없으면 비워 둔다(미확인)
-- 판본별 규칙 값은 코드(src/lms/rules)와 정책 기준표에 있고, 여기는 "누가 어떤 문서를 받았는지"만
-- ---------------------------------------------------------------------

create table terms_versions (
  code text primary key check (code ~ '^[A-Z0-9_]+$'),
  -- class_terms: LMS에서 클릭으로 확인·동의하는 수업 안내·수강규정 / privacy_notice·marketing 은 수강규정과 따로 받음 (POL-OP-12)
  kind text not null check (kind in ('contract', 'guide', 'class_terms', 'privacy_notice', 'marketing')),
  audience text not null check (audience in ('student', 'tutor')),
  title text not null,
  first_seen date,                         -- 확인된 가장 이른 서명·작성일
  is_draft boolean not null default false, -- 초안(아직 누구에게도 적용 안 됨)
  source_ref text not null,                -- docs/lms/policy/sources.md 의 SRC-ID
  note text
);
insert into terms_versions (code, kind, audience, title, first_seen, is_draft, source_ref, note) values
  ('SC0A', 'contract', 'student', '학생 계약 2024-09 이전 판 (12시간 기준)', null, false, 'SRC-SC0A', '취소 12시간 전, 4주 2/3/5회, 보강 2주 안'),
  ('SC0B', 'contract', 'student', '학생 계약 2024-11 판 (30일, 효력 조항 없음)', '2024-11-16', false, 'SRC-SC0B', '재등록 시 효력 조항 없음'),
  ('SC0C', 'contract', 'student', '학생 계약 2025-05 판 (30일)', '2025-05-27', false, 'SRC-SC0C', null),
  ('SC1', 'contract', 'student', '수강계약서 1판 (30일 기준)', '2025-10-22', false, 'SRC-SC1', '변경권 4·6·10회/30일, 연기 30일'),
  ('SC2', 'contract', 'student', '수강계약서 2판 (28일 기준)', '2026-01-14', false, 'SRC-SC2', '변경권 1·2·3회/28일, 연기 28일'),
  ('SC3', 'contract', 'student', '수강계약서 3판 초안', '2026-10-02', true, 'SRC-SC3', '내부 메모 정리 전'),
  ('GV1', 'guide', 'student', '필독안내서 옛 판 1 (30일, 4·6·10회, 이월 없음, 1장)', null, false, 'SRC-GUIDE', '학생 시트에서 발견, 날짜 미상'),
  ('GV2', 'guide', 'student', '필독안내서 옛 판 2 (28일, 4·6·10회, 이월 없음, 1장)', null, false, 'SRC-GUIDE', '학생 시트에서 발견, 날짜 미상'),
  ('GV3', 'guide', 'student', '필독안내서 옛 판 3 (28일, 월 1·2·3회, 이월 없음, 1장)', null, false, 'SRC-GUIDE', '학생 시트에서 발견, 날짜 미상'),
  ('GV4', 'guide', 'student', '필독안내서 옛 판 4 (28일, 월 1·2·3회, 종료 후 이틀 이월, 1장)', null, false, 'SRC-GUIDE', '학생 시트에서 발견, 날짜 미상'),
  ('G20260709', 'guide', 'student', '수업 전 필독안내서 2026-07-09 판 (이미지 2장)', '2026-07-09', false, 'SRC-GUIDE', '현행. 일부 옛 시트는 이 판으로 교체됨'),
  ('TC0', 'contract', 'tutor', '국내 강사 계약 2024-08 (원화 시급)', '2024-08-10', false, 'SRC-TC0', '기간 고정, 만료 후 상호 협의 연장'),
  ('TC0B', 'contract', 'tutor', '강사 계약 2025-11-04 판 ($14 + 최대 $2, 자동 갱신)', '2025-11-04', false, 'SRC-TC0B', null),
  ('TC1', 'contract', 'tutor', '강사계약서 1판 (기본 $14 + 최대 $3)', '2025-11-27', false, 'SRC-TC1', '1년, 갱신은 서면 동의'),
  ('TC2', 'contract', 'tutor', '강사계약서 2판 (기본 $11)', '2026-01-09', false, 'SRC-TC2', null),
  ('TC3', 'contract', 'tutor', '강사계약서 3판 (기본 $11, 보강+보상)', '2026-08-24', false, 'SRC-TC3', null);

create or replace function terms_kind_is(p_code text, p_kind text, p_audience text) returns boolean
language sql stable as $$
  select p_code is null or exists (select 1 from terms_versions where code = p_code and kind = p_kind and audience = p_audience)
$$;

-- ---------------------------------------------------------------------
-- 사람: 학생 · 강사 · 로그인 연결
-- ---------------------------------------------------------------------

create sequence student_code_seq start 1;   -- 이관 후 setval 로 기존 최대 번호 다음부터

create table students (
  id uuid primary key default gen_random_uuid(),
  -- 영구 고유번호 (POL-OP-05). 재등록해도 그대로
  code text not null unique default ('STU-' || lpad(nextval('student_code_seq')::text, 4, '0'))
    check (code ~ '^STU-\d{4,}$'),
  name_ko text not null,
  name_en text not null,
  display_name text,                       -- 강사에게 보이는 이름 (영문 이름이 겹칠 때만)
  email text,
  phone text,                              -- 국내: 휴대폰, 해외: 카카오톡 ID 등
  country text,
  city text,
  timezone text not null default 'Asia/Seoul' check (is_valid_timezone(timezone)),
  gender_age text,
  self_intro_en text,
  level text,
  class_type text,
  correction_pref text,
  textbook text,
  class_note_url text,
  admin_memo text,                         -- 운영자만 봄
  legacy_row_ref text,                     -- 이관 시 원래 시트 위치 (검증용)
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
  -- '수강 중/종료' 상태 칸은 두지 않음: 수강등록에서 계산 (같은 사실을 두 번 저장하지 않음)
);
create trigger students_touch before update on students for each row execute function touch_updated_at();

create table tutors (
  id uuid primary key default gen_random_uuid(),
  name text not null unique,
  name_ko_sound text,
  country text not null,
  timezone text not null check (is_valid_timezone(timezone)),   -- IANA (고정 시차 아님)
  email text,
  meet_url text,
  google_calendar_id text,
  active boolean not null default true,    -- 휴무 여부는 tutor_time_off 에서 계산
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

-- 권한 확인 함수 (RLS에서 사용)
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

-- ---------------------------------------------------------------------
-- 수강등록 · 기간 · 연장 · 결제 · 환불
-- ---------------------------------------------------------------------

create table enrollments (
  id uuid primary key default gen_random_uuid(),
  student_id uuid not null references students(id),
  seq integer not null check (seq >= 1),                         -- 몇 번째 등록
  previous_enrollment_id uuid unique references enrollments(id), -- 재등록이면 직전 등록
  -- 이 등록 때 학생이 받은 문서 (운영자가 근거 기록(terms_deliveries)을 보고 정함, 모르면 비워 둠 = 미확인)
  contract_version text references terms_versions(code)
    check (terms_kind_is(contract_version, 'contract', 'student')),
  guide_version text references terms_versions(code)
    check (terms_kind_is(guide_version, 'guide', 'student')),
  weeks smallint check (weeks in (4, 12, 24)),                   -- 현행 상품 (POL-PER-01)
  legacy_label text,                                             -- 옛 상품 (예: '1개월(30일)', '2개월')
  weekly_count smallint not null check (weekly_count in (1, 2, 3, 5)),
  duration_min smallint not null check (duration_min in (20, 40, 50)),
  start_date date not null,
  base_end_date date not null,
  extension_days integer not null default 0 check (extension_days >= 0),  -- enrollment_extensions 합계 (직접 수정 불가)
  final_end_date date generated always as (base_end_date + extension_days) stored,
  lessons_purchased integer not null check (lessons_purchased > 0),
  lessons_carried_in integer not null default 0 check (lessons_carried_in >= 0),
  amount_due integer check (amount_due >= 0),                   -- 등록 당시 결제할 금액 (원, 스냅샷)
  status text not null default 'pending_payment'
    check (status in ('pending_payment', 'confirmed', 'active', 'completed', 'canceled')),
  created_by uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (student_id, seq),
  check (base_end_date >= start_date),
  check ((weeks is not null) <> (legacy_label is not null)),     -- 현행 상품이거나 옛 상품 둘 중 하나
  -- 현행 상품은 28일 규칙 (POL-PER-02). 옛 상품은 시트의 실제 날짜를 그대로 이관
  check (weeks is null or base_end_date = start_date + (weeks / 4 * 28 - 1)),
  check (weeks is null or lessons_purchased = weekly_count * weeks),
  -- 같은 학생의 수강기간은 겹칠 수 없음
  exclude using gist (student_id with =, daterange(start_date, final_end_date, '[]') with &&)
    where (status <> 'canceled')
);
create trigger enrollments_touch before update on enrollments for each row execute function touch_updated_at();

-- 변경권 지급 단위 기간 (현행 28일, 1판 계약은 30일일 수 있어 길이는 코드가 판본별로 계산)
create table enrollment_periods (
  id uuid primary key default gen_random_uuid(),
  enrollment_id uuid not null references enrollments(id),
  idx smallint not null check (idx between 1 and 12),
  start_date date not null,
  end_date date not null,
  credits_granted smallint not null check (credits_granted between 0 and 10),
  unique (enrollment_id, idx),
  check (end_date >= start_date)
);

-- 기간 연장 장부 (장기 연기·강사 휴무·예외). 합계가 enrollments.extension_days 로 자동 반영
create table enrollment_extensions (
  id uuid primary key default gen_random_uuid(),
  enrollment_id uuid not null references enrollments(id),
  days integer not null check (days <> 0), -- 정정은 음수 행 추가
  reason text not null check (reason in ('student_long_term_leave', 'tutor_long_term_leave', 'admin_exception', 'correction')),
  change_request_id uuid,                  -- 근거가 된 요청 (아래 change_requests)
  note text,
  approved_by uuid not null,
  created_at timestamptz not null default now()
);
create trigger enrollment_extensions_no_update before update on enrollment_extensions for each row execute function forbid_update();
create trigger enrollment_extensions_no_delete before delete on enrollment_extensions for each row execute function forbid_delete();

create or replace function sync_extension_days() returns trigger
language plpgsql as $$
declare
  total integer;
begin
  select coalesce(sum(days), 0) into total from enrollment_extensions where enrollment_id = new.enrollment_id;
  if total < 0 then raise exception '연장 일수 합계가 0보다 작아질 수 없습니다.'; end if;
  perform set_config('lms.extension_sync', 'on', true);
  update enrollments set extension_days = total where id = new.enrollment_id;
  perform set_config('lms.extension_sync', 'off', true);
  return null;
end $$;
create trigger enrollment_extensions_sync after insert on enrollment_extensions
  for each row execute function sync_extension_days();

create or replace function guard_extension_days() returns trigger
language plpgsql as $$
begin
  if new.extension_days is distinct from old.extension_days
     and coalesce(current_setting('lms.extension_sync', true), 'off') <> 'on' then
    raise exception '연장 일수는 직접 고칠 수 없습니다. 연장 기록(enrollment_extensions)을 추가하세요.';
  end if;
  return new;
end $$;
create trigger enrollments_guard_extension before update on enrollments
  for each row execute function guard_extension_days();

-- 실제 입금 기록 (결제할 금액은 enrollments.amount_due 한 곳에만. 나눠 낸 경우 행이 여러 개)
create table payments (
  id uuid primary key default gen_random_uuid(),
  enrollment_id uuid not null references enrollments(id),
  method text not null check (method in ('bank_transfer', 'card_link')),
  payer_name text,
  amount_received integer not null check (amount_received > 0),
  received_on date not null,
  confirmed_by uuid not null,
  confirmed_at timestamptz not null default now(),
  note text
);

-- 환불: 금액은 운영자가 직접 입력·승인. 자동 계산하지 않음 (POL-PAY-04 보류)
create table refunds (
  id uuid primary key default gen_random_uuid(),
  enrollment_id uuid not null references enrollments(id),
  amount integer not null check (amount > 0),
  reason text not null,
  status text not null default 'requested' check (status in ('requested', 'approved', 'paid', 'rejected')),
  approved_by uuid,
  approved_at timestamptz,
  paid_at timestamptz,
  note text,
  created_at timestamptz not null default now(),
  check (status not in ('approved', 'paid') or approved_by is not null)
);

-- ---------------------------------------------------------------------
-- 고정 스케줄 · 수업
-- ---------------------------------------------------------------------

-- 매주 고정 요일·시각(KST). 학생에 붙어 있어 재등록해도 그대로 (POL-RN-03)
-- 바뀌면 기존 행 effective_to 를 닫고 새 행 추가 (이력 보존)
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

-- 상태매핑표 (POL-ST-01). 값은 src/lms/rules/status.ts 와 같아야 함 (자동 테스트로 확인)
-- DB에도 두는 이유: 보고·정산 SQL이 같은 표를 쓰게 하려고
create table class_status_rules (
  status class_status primary key,
  student_label text not null,
  consumes_lesson boolean not null,
  uses_credit boolean not null,
  tutor_paid boolean not null,
  incentive text not null check (incentive in ('none', 'late_cancel', 'no_show', 'late')),
  outcome text not null check (outcome in ('held', 'canceled', 'missed'))  -- 진행 / 시작 전 취소 / 시간에 못 함
);
insert into class_status_rules values
  ('Normal', '정상 진행', true, false, true, 'none', 'held'),
  ('Make-up completed', '보강 완료', true, false, true, 'none', 'held'),
  ('Student canceled in advance', '학생 정상 취소 👉 수강기간 내 보강 가능', false, true, false, 'none', 'canceled'),
  ('Student canceled in advance (public holiday)', '공휴일 취소 👉 수강기간 내 보강 가능', false, false, false, 'none', 'canceled'),
  ('Tutor canceled in advance', '강사 정상 취소 👉 수강기간 내 보강 가능', false, false, false, 'none', 'canceled'),
  ('Student canceled late', '학생 늦은 취소 👉 보강 불가', true, false, true, 'none', 'canceled'),
  ('Tutor canceled late', '강사 늦은 취소 👉 수강기간 내 보강 가능', false, false, false, 'late_cancel', 'canceled'),
  ('Student no-show', '학생 노쇼 👉 보강 불가', true, false, true, 'none', 'missed'),
  ('Tutor no-show', '강사 노쇼 👉 보강 1회 + 보상수업 1회(무료)', false, false, false, 'no_show', 'missed'),
  ('Tutor long-term leave', '강사 장기 휴식 👉 수강기간 연장', false, false, false, 'none', 'canceled'),
  ('Student long-term leave', '학생 장기 연기 👉 수강기간 최대 2주 연장(6개월(24주) 수강 학생만)', false, false, false, 'none', 'canceled'),
  ('No change credits left', '변경권 소진 👉 보강 불가', true, false, true, 'none', 'canceled'),
  ('Tutor Late - Student Present', '강사 지각(정상 진행)', true, false, true, 'late', 'held'),
  ('Covered by another tutor', '대타 강사 진행', true, false, true, 'none', 'held');

create table lessons (
  id uuid primary key default gen_random_uuid(),
  enrollment_id uuid not null references enrollments(id),
  student_id uuid not null references students(id),    -- 겹침 방지 제약용 (등록의 학생과 같아야 함 — 트리거로 확인)
  tutor_id uuid not null references tutors(id),        -- 실제 수업하는 강사
  original_tutor_id uuid references tutors(id),        -- 대체 강사 배정 시 원래 담당
  kind text not null check (kind in ('regular', 'makeup', 'compensation', 'carryover')),
  seq integer,                                         -- 정규 회차 번호
  starts_at timestamptz not null,
  ends_at timestamptz not null,
  -- 한국 날짜 (KST = UTC+9 고정, 서머타임 없음)
  kst_date date generated always as (((starts_at at time zone 'UTC') + interval '9 hours')::date) stored,
  state text not null default 'scheduled' check (state in ('scheduled', 'canceled', 'done')),
  class_status class_status,                            -- 결과 (원본은 여기 하나, POL-ST-02)
  makeup_of uuid references lessons(id),                -- 보강이면 원래 수업
  compensation_id uuid,                                 -- 보상 수업이면 보상권
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
  check ((state = 'scheduled') = (class_status is null)),   -- 예정이면 결과 없음, 끝났거나 취소면 결과 필수
  constraint lessons_no_tutor_overlap exclude using gist
    (tutor_id with =, tstzrange(starts_at, ends_at) with &&) where (state <> 'canceled'),
  constraint lessons_no_student_overlap exclude using gist
    (student_id with =, tstzrange(starts_at, ends_at) with &&) where (state <> 'canceled')
);
create trigger lessons_touch before update on lessons for each row execute function touch_updated_at();
create trigger lessons_no_delete before delete on lessons for each row execute function forbid_delete();
create index lessons_tutor_time on lessons (tutor_id, starts_at);
create index lessons_student_time on lessons (student_id, starts_at);
create unique index lessons_regular_seq on lessons (enrollment_id, seq) where kind = 'regular';
create unique index lessons_one_live_makeup on lessons (makeup_of) where state <> 'canceled';

-- 상태와 결과의 짝 확인 + 학생 일치 확인
create or replace function check_lesson_consistency() returns trigger
language plpgsql as $$
declare
  o text;
begin
  if new.student_id <> (select student_id from enrollments where id = new.enrollment_id) then
    raise exception '수업의 학생과 수강등록의 학생이 다릅니다.';
  end if;
  if new.class_status is not null then
    select outcome into o from class_status_rules where status = new.class_status;
    if new.state = 'canceled' and o <> 'canceled' then
      raise exception '취소된 수업에 진행 결과(%)를 넣을 수 없습니다.', new.class_status;
    end if;
    if new.state = 'done' and o = 'canceled' then
      raise exception '진행된 수업에 취소 결과(%)를 넣을 수 없습니다.', new.class_status;
    end if;
  end if;
  return new;
end $$;
create trigger lessons_consistency before insert or update on lessons
  for each row execute function check_lesson_consistency();

-- 강사 수업 기록 (Covered Topics · Remarks · 기록 시각). 결과 상태는 lessons.class_status
create table class_records (
  lesson_id uuid primary key references lessons(id),
  covered_topics text,
  remarks text,
  first_submitted_at timestamptz not null default now(),  -- 인센티브 '10분 안 기록' 기준 (POL-TU-06)
  submitted_by uuid,
  updated_at timestamptz not null default now()
);
create trigger class_records_touch before update on class_records for each row execute function touch_updated_at();
create trigger class_records_no_delete before delete on class_records for each row execute function forbid_delete();
create or replace function keep_first_submitted_at() returns trigger
language plpgsql as $$
begin
  new.first_submitted_at := old.first_submitted_at;
  return new;
end $$;
create trigger class_records_keep_first before update on class_records
  for each row execute function keep_first_submitted_at();

-- ---------------------------------------------------------------------
-- 변경 요청 · 변경권 · 보상 수업 · 노쇼 신고
-- ---------------------------------------------------------------------

-- 진행 상태(신청·승인·거절…)는 여기, 수업 결과(14개)는 lessons.class_status (POL-ST-02)
create table change_requests (
  id uuid primary key default gen_random_uuid(),
  lesson_id uuid references lessons(id),
  student_id uuid references students(id),
  tutor_id uuid references tutors(id),
  type text not null check (type in (
    'student_cancel', 'tutor_cancel', 'admin_cancel',
    'fixed_schedule_change', 'tutor_change', 'student_long_term_leave', 'tutor_leave')),
  status text not null check (status in ('applied', 'pending', 'approved', 'rejected', 'withdrawn', 'reverted')),
  via text not null check (via in ('student_app', 'tutor_app', 'admin_app', 'admin_on_behalf', 'system')),
  policy_refs text[] not null default '{}',  -- 판정에 쓴 정책 ID (예: {POL-CHG-01,POL-CHG-03})
  decision jsonb,                            -- 규칙 검사 결과 그대로 (나중에 왜 그렇게 됐는지 확인용)
  reason text,
  batch_id uuid,                             -- 일괄 처리 묶음 (한 번에 되돌리기)
  idempotency_key text unique,               -- 같은 요청 두 번 처리 방지
  requested_by uuid,
  decided_by uuid,
  created_at timestamptz not null default now(),
  decided_at timestamptz
);
create index change_requests_batch on change_requests (batch_id) where batch_id is not null;
alter table enrollment_extensions add constraint enrollment_extensions_request_fk
  foreign key (change_request_id) references change_requests(id);

-- 계약서·안내서 전달·동의 근거 기록 (과거 기록 이관 + 앞으로 LMS 온라인 동의)
-- 날짜·시점을 모르면 비워 두고 timing 'unknown' — 같은 시점에 받았다고 가정하지 않음
create table terms_deliveries (
  id uuid primary key default gen_random_uuid(),
  terms_code text not null references terms_versions(code),
  student_id uuid references students(id),
  tutor_id uuid references tutors(id),
  enrollment_id uuid references enrollments(id),   -- 어느 등록(신규·재등록) 때 받았는지
  delivered_on date,
  timing text not null check (timing in ('before_payment', 'after_payment', 'at_matching', 'at_signing', 'unknown')),
  channel text not null check (channel in ('kakao', 'student_sheet', 'email', 'esign', 'online_page', 'in_person', 'unknown')),  -- student_sheet: 학생 수강현황 시트에 이미지로 게시 (POL-OP-09)
  consent_kind text check (consent_kind in ('payment_after_delivery', 'signature', 'esign_completed', 'online_accept')),
  consent_on timestamptz,
  evidence_note text,                      -- 근거 위치 (예: '카톡 채널 대화 2026-02-03') — 이름·연락처는 적지 않음
  recorded_by uuid,
  created_at timestamptz not null default now(),
  check ((student_id is null) <> (tutor_id is null)),
  check ((consent_kind is null) = (consent_on is null)),
  check (enrollment_id is null or student_id is not null)
);
create trigger terms_deliveries_no_update before update on terms_deliveries for each row execute function forbid_update();
create trigger terms_deliveries_no_delete before delete on terms_deliveries for each row execute function forbid_delete();

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
create trigger credit_ledger_no_update before update on credit_ledger for each row execute function forbid_update();

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

-- 보상 수업권 (강사 노쇼 등). 사용 기한은 미확정(D-8) → expires_on 비워 둠
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

-- 강사 막은 날·장기 휴무 (휴무 일괄 처리의 기준, 3단계)
create table tutor_time_off (
  id uuid primary key default gen_random_uuid(),
  tutor_id uuid not null references tutors(id),
  starts_at timestamptz not null,
  ends_at timestamptz not null,
  kind text not null check (kind in ('block', 'leave')),
  reason text,
  notice_given_on date,                    -- 강사계약서 10조: 14일 전 서면 통보
  created_by uuid,
  created_at timestamptz not null default now(),
  check (ends_at > starts_at)
);

-- ---------------------------------------------------------------------
-- 공휴일 · 기능 스위치
-- ---------------------------------------------------------------------

-- 변경권 차감 없이 처리할 한국 공휴일 (POL-CHG-07: 어떤 날을 넣을지는 운영자 결정, 비어 있으면 면제 없음)
create table holidays (
  day date primary key,
  name text not null,
  created_by uuid,
  created_at timestamptz not null default now()
);

-- 기능 켜기/끄기만 (운영정책 값은 여기 두지 않음 — POL-OP-07)
create table feature_flags (
  key text primary key check (key ~ '^[a-z_]+$'),
  enabled boolean not null default false,
  note text,
  updated_by uuid,
  updated_at timestamptz not null default now()
);
insert into feature_flags (key, enabled, note) values
  ('student_view', false, '학생 화면 보기 (4-a)'),
  ('student_self_change', false, '학생 셀프 변경 (4-b)'),
  ('makeup_requests', false, '보강 신청 (4-c)'),
  ('send_emails', false, '실제 메일 발송 (꺼져 있으면 support@ 로만)'),
  ('calendar_write', false, 'Google 캘린더에 쓰기');

-- ---------------------------------------------------------------------
-- 보호 적용 (이력 + RLS + 운영자 읽기)
-- ---------------------------------------------------------------------

select lms_protect(t::regclass) from unnest(array[
  'terms_versions', 'students', 'tutors', 'app_users', 'enrollments', 'enrollment_periods', 'enrollment_extensions',
  'payments', 'refunds', 'regular_schedules', 'class_status_rules', 'lessons', 'class_records',
  'change_requests', 'credit_ledger', 'compensations', 'no_show_reports', 'tutor_time_off', 'holidays', 'feature_flags',
  'terms_deliveries'
]) as t;
alter table audit_log enable row level security;
revoke all on audit_log from anon, authenticated;
grant select on audit_log to authenticated;
create policy admin_read on audit_log for select to authenticated using (is_admin());

-- 학생: 본인 정보·수강·수업·변경 요청·변경권·보상권만
create policy student_self on students for select to authenticated using (id = my_student_id());
create policy student_own on enrollments for select to authenticated using (student_id = my_student_id());
create policy student_own on enrollment_periods for select to authenticated
  using (exists (select 1 from enrollments e where e.id = enrollment_id and e.student_id = my_student_id()));
create policy student_own on lessons for select to authenticated using (student_id = my_student_id());
create policy student_own on change_requests for select to authenticated using (student_id = my_student_id());
create policy student_own on compensations for select to authenticated using (student_id = my_student_id());
create policy student_own on credit_ledger for select to authenticated
  using (exists (select 1 from enrollment_periods p join enrollments e on e.id = p.enrollment_id
                 where p.id = period_id and e.student_id = my_student_id()));
create policy student_own on terms_deliveries for select to authenticated using (student_id = my_student_id());
create policy everyone_read on terms_versions for select to authenticated using (true);
create policy everyone_read on class_status_rules for select to authenticated using (true);
create policy everyone_read on holidays for select to authenticated using (true);

-- 강사: 본인 수업·본인 정보·본인 휴무만. 학생 정보는 아래 함수로 필요한 칸만
create policy tutor_self on tutors for select to authenticated using (id = my_tutor_id());
create policy tutor_own on lessons for select to authenticated using (tutor_id = my_tutor_id());
create policy tutor_own on class_records for select to authenticated
  using (exists (select 1 from lessons l where l.id = lesson_id and l.tutor_id = my_tutor_id()));
create policy tutor_own on tutor_time_off for select to authenticated using (tutor_id = my_tutor_id());
create policy tutor_self on terms_deliveries for select to authenticated using (tutor_id = my_tutor_id());

-- 강사가 볼 수 있는 학생 정보: 최근·예정 수업이 있는 담당 학생, 수업에 필요한 칸만 (휴대폰·한글 실명·운영 메모 제외, POL-OP-06)
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

-- >>> 20261016000100_lms_selfservice.sql
-- =====================================================================
-- LMS 4단계: 강사 가능 시간 · 학생 보강 신청 (초안 v0.2)
-- 4단계 시작 전에는 적용하지 않는다. 3단계까지는 운영자가 보강을 lessons 에 직접 넣는다.
-- =====================================================================

-- 주간 수업 가능 시간 (강사 현지 시각 + 시간대 → 서머타임이 바뀌어도 강사 기준 유지)
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

-- 보강 신청: 진행 상태만 (결과는 확정 시 만들어지는 lessons 행)
create table makeup_requests (
  id uuid primary key default gen_random_uuid(),
  source_lesson_id uuid not null references lessons(id),
  student_id uuid not null references students(id),
  tutor_id uuid not null references tutors(id),
  status text not null default 'requested'
    check (status in ('requested', 'countered', 'confirmed', 'declined', 'expired', 'withdrawn')),
  confirmed_lesson_id uuid unique references lessons(id),
  tutor_note text,
  remind_at timestamptz,                   -- 강사 무응답 재알림 시각 (기준 시간은 미확정 D-11)
  created_at timestamptz not null default now(),
  decided_at timestamptz,
  check ((status = 'confirmed') = (confirmed_lesson_id is not null))
);
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

select lms_protect(t::regclass) from unnest(array['tutor_availability', 'makeup_requests', 'makeup_candidates']) as t;

create policy tutor_own on tutor_availability for select to authenticated using (tutor_id = my_tutor_id());
create policy student_own on makeup_requests for select to authenticated using (student_id = my_student_id());
create policy tutor_own on makeup_requests for select to authenticated using (tutor_id = my_tutor_id());
create policy own on makeup_candidates for select to authenticated
  using (exists (select 1 from makeup_requests r where r.id = request_id
                 and (r.student_id = my_student_id() or r.tutor_id = my_tutor_id())));

-- >>> 20261016000200_lms_notify_calendar.sql
-- =====================================================================
-- LMS 5단계: 알림 · Google 캘린더 반영 (초안 v0.2)
-- 실제 발송·캘린더 쓰기는 feature_flags(send_emails, calendar_write)를 운영자가 켜야 동작
-- =====================================================================

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

-- 수업이 바뀌면 같은 트랜잭션에서 반영 대기열에 올림 (수업 변경과 함께 저장되거나 함께 취소)
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

select lms_protect(t::regclass) from unnest(array['notifications', 'calendar_sync']) as t;

-- >>> 20261016000300_lms_payroll.sql
-- =====================================================================
-- LMS 6단계: 강사 계약 조건 · 정산 (초안 v0.2)
-- 급여 기준이 확정(D-13~15, D-17)되기 전에는 적용하지 않는다.
-- =====================================================================

-- 강사별 계약 조건 (CF-08: 판본마다 기본 시급이 다름 — TC1 $14, TC2·TC3 $11)
create table tutor_contracts (
  id uuid primary key default gen_random_uuid(),
  tutor_id uuid not null references tutors(id),
  terms_version text not null references terms_versions(code)
    check (terms_kind_is(terms_version, 'contract', 'tutor')),  -- 서명한 계약서가 있는 강사만 행을 만듦
  signed_on date not null,
  base_rate_usd numeric(6, 2) not null check (base_rate_usd > 0),
  max_rate_usd numeric(6, 2) not null,
  valid_to date,
  note text,
  check (max_rate_usd >= base_rate_usd),
  exclude using gist (tutor_id with =, daterange(signed_on, valid_to, '[]') with &&)
);

-- 승인된 인센티브 규칙 (승인 전에는 행이 없어 계산 자체가 안 됨)
create table pay_policies (
  id uuid primary key default gen_random_uuid(),
  effective_from date not null unique,
  rules jsonb not null,                    -- 인센티브 조건·가산액 (register.md POL-WG-02 의 승인된 값)
  policy_refs text[] not null,
  approved_by uuid not null,
  approved_at timestamptz not null default now()
);

create table payroll_runs (
  id uuid primary key default gen_random_uuid(),
  tutor_id uuid not null references tutors(id),
  month date not null check (extract(day from month) = 1),
  contract_id uuid references tutor_contracts(id),
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
  payable boolean not null,                -- 상태매핑표 + 수업 종류(보상 수업은 미지급, POL-WG-08)
  note text
);

select lms_protect(t::regclass) from unnest(array['tutor_contracts', 'pay_policies', 'payroll_runs', 'payroll_items']) as t;

create policy tutor_own on payroll_runs for select to authenticated using (tutor_id = my_tutor_id() and status <> 'draft');
create policy tutor_own on tutor_contracts for select to authenticated using (tutor_id = my_tutor_id());

-- >>> 20261016000400_lms_terms_consent.sql
-- =====================================================================
-- LMS 수업 안내 확인·동의 (초안 v0.1) — POL-OP-12 변경 제안, docs/lms/10-terms-consent-design.md
-- 대표 승인(D-22~D-25) 전에는 어떤 Supabase에도 적용하지 않는다.
--
-- 원칙
-- - 문서 원본은 덮어쓰지 않는다. 고치면 새 판(terms_versions) 또는 새 revision.
-- - 동의는 학생 본인만, 서버 함수로만 기록한다. 운영자도 대신 동의할 수 없다.
-- - 동의 기록은 고치거나 지울 수 없다. 철회·재확인도 새 줄로 쌓는다.
-- - 동의하지 않았다고 수업·등록을 막지 않는다 (lessons·enrollments 에 연결된 제약 없음).
-- - 예전 계약·안내서 근거(terms_deliveries)는 그대로 두고, 이 표들은 LMS 온라인 동의만 기록한다.
-- =====================================================================

-- 학생에게 실제로 보여 준 문서 원본
create table terms_documents (
  id uuid primary key default gen_random_uuid(),
  terms_code text not null references terms_versions(code),
  revision smallint not null default 1 check (revision > 0),  -- 오탈자 수정도 새 revision (이전 것은 그대로 남음)
  format text not null check (format in ('text', 'image_set')),
  body_md text,                            -- 학생 화면에 보여 준 텍스트 원문
  assets jsonb not null default '[]',      -- 이미지 원본 [{page, path, sha256}] — 비공개 저장소 경로
  required_items jsonb not null default '[]',  -- 필수 체크 항목 [{key, text}]
  optional_items jsonb not null default '[]',  -- 선택 항목 (예: 마케팅 수신) — 수강규정과 섞지 않음
  content_sha256 text not null default '', -- 위 4개로 DB가 계산 (앱이 넣은 값은 무시)
  status text not null default 'draft' check (status in ('draft', 'published', 'retired')),
  published_at timestamptz,
  published_by uuid,
  created_at timestamptz not null default now(),
  unique (terms_code, revision),
  check (format <> 'text' or body_md is not null),
  check (format <> 'image_set' or jsonb_array_length(assets) > 0),
  check ((status = 'draft') = (published_at is null))
);

create or replace function terms_document_guard() returns trigger
language plpgsql as $$
begin
  if tg_op = 'UPDATE' and old.status <> 'draft' then
    -- 게시된 문서는 내용을 바꿀 수 없고, 게시 → 내림(retired)만 가능
    if (new.body_md, new.assets, new.required_items, new.optional_items, new.format, new.terms_code, new.revision)
       is distinct from (old.body_md, old.assets, old.required_items, old.optional_items, old.format, old.terms_code, old.revision)
       or not (new.status = 'retired' or new.status = old.status) then
      raise exception '게시된 안내 문서는 고칠 수 없습니다. 새 판을 만드세요.';
    end if;
  end if;
  new.content_sha256 := encode(sha256(convert_to(
    coalesce(new.body_md, '') || new.assets::text || new.required_items::text || new.optional_items::text, 'UTF8')), 'hex');
  return new;
end $$;
create trigger terms_document_guard before insert or update on terms_documents for each row execute function terms_document_guard();
create trigger terms_documents_no_delete before delete on terms_documents for each row execute function forbid_delete();

-- 운영자가 학생에게 보낸 확인 요청 (등록 1건 × 문서 1건)
create table consent_requests (
  id uuid primary key default gen_random_uuid(),
  student_id uuid not null references students(id),
  enrollment_id uuid not null references enrollments(id),
  document_id uuid not null references terms_documents(id),
  reason text not null check (reason in ('new', 'renewal', 'reconfirm', 'policy_change')),
  required boolean not null default true,  -- 마케팅 등 선택 문서는 false
  created_by uuid,
  created_at timestamptz not null default now(),
  canceled_at timestamptz,                 -- 잘못 보낸 요청 취소 (줄은 남김)
  cancel_note text,
  unique (enrollment_id, document_id),
  check ((canceled_at is null) = (cancel_note is null))
);

create or replace function consent_request_guard() returns trigger
language plpgsql as $$
begin
  if tg_op = 'INSERT' then
    if not exists (select 1 from enrollments where id = new.enrollment_id and student_id = new.student_id) then
      raise exception '학생과 수강등록의 학생이 다릅니다.';
    end if;
    if not exists (select 1 from terms_documents where id = new.document_id and status = 'published') then
      raise exception '게시된 문서만 요청할 수 있습니다.';
    end if;
  elsif (new.student_id, new.enrollment_id, new.document_id, new.reason, new.required, new.created_at)
        is distinct from (old.student_id, old.enrollment_id, old.document_id, old.reason, old.required, old.created_at)
        or old.canceled_at is not null then
    raise exception '확인 요청은 취소만 할 수 있습니다.';
  end if;
  return new;
end $$;
create trigger consent_request_guard before insert or update on consent_requests for each row execute function consent_request_guard();
create trigger consent_requests_no_delete before delete on consent_requests for each row execute function forbid_delete();

-- 열람·동의·철회 기록 (쌓기만 함)
create table consent_events (
  id uuid primary key default gen_random_uuid(),
  request_id uuid not null references consent_requests(id),
  action text not null check (action in ('viewed', 'accepted', 'withdrawn')),
  checked_items text[] not null default '{}',  -- 학생이 직접 체크한 항목 key
  document_sha256 text not null,           -- 그 순간 보여 준 문서 해시
  acted_at timestamptz not null default now(),  -- 서버 시각 (학생 기기 시각을 쓰지 않음)
  actor_auth_id uuid not null,
  actor_role text not null check (actor_role in ('student', 'admin')),
  note text,                               -- 철회 사유 등 (이름·연락처 적지 않음)
  check (action <> 'accepted' or actor_role = 'student'),   -- 동의는 학생 본인만
  check (action <> 'withdrawn' or actor_role = 'student' or note is not null)
);
create trigger consent_events_no_update before update on consent_events for each row execute function forbid_update();
create trigger consent_events_no_delete before delete on consent_events for each row execute function forbid_delete();

select lms_protect(t::regclass) from unnest(array['terms_documents', 'consent_requests', 'consent_events']) as t;

create policy everyone_read on terms_documents for select to authenticated using (status <> 'draft');
create policy student_own on consent_requests for select to authenticated using (student_id = my_student_id());
create policy student_own on consent_events for select to authenticated
  using (request_id in (select id from consent_requests where student_id = my_student_id()));

-- ---------------------------------------------------------------------
-- 학생 화면에서 부르는 함수 (로그인한 본인 확인은 DB가 직접 함)
-- ---------------------------------------------------------------------

create or replace function consent_record(p_request uuid, p_action text, p_items text[] default '{}', p_note text default null)
returns uuid
language plpgsql security definer set search_path = public as $$
declare
  r consent_requests;
  d terms_documents;
  me uuid := my_student_id();
  role text;
  required_keys text[];
  allowed_keys text[];
  last_action text;
  new_id uuid;
begin
  select * into r from consent_requests where id = p_request;
  if r.id is null or r.canceled_at is not null then raise exception '확인 요청을 찾을 수 없습니다.'; end if;

  if me is not null and r.student_id = me then
    role := 'student';
  elsif is_admin() and p_action = 'withdrawn' then
    role := 'admin';                       -- 학생이 카톡 등으로 철회를 요청했을 때 운영자가 대신 기록 (사유 필수)
  else
    raise exception '본인의 확인 요청이 아닙니다.';   -- 다른 학생·강사·운영자의 대신 동의 차단
  end if;

  select * into d from terms_documents where id = r.document_id;
  if d.status <> 'published' and p_action = 'accepted' then raise exception '내려간 문서에는 새로 동의할 수 없습니다.'; end if;

  select action into last_action from consent_events
   where request_id = r.id and action <> 'viewed' order by acted_at desc, id desc limit 1;

  if p_action = 'accepted' then
    select coalesce(array_agg(x->>'key'), '{}') into required_keys from jsonb_array_elements(d.required_items) x;
    select coalesce(array_agg(x->>'key'), '{}') into allowed_keys
      from jsonb_array_elements(d.required_items || d.optional_items) x;
    if not (required_keys <@ p_items) then raise exception '필수 항목을 모두 체크해야 합니다.'; end if;
    if not (p_items <@ allowed_keys) then raise exception '문서에 없는 항목입니다.'; end if;
    if last_action = 'accepted' then
      return (select id from consent_events where request_id = r.id and action = 'accepted' order by acted_at desc, id desc limit 1);
    end if;
  elsif p_action = 'withdrawn' then
    if last_action is distinct from 'accepted' then raise exception '동의한 상태가 아닙니다.'; end if;
    p_items := '{}';
  elsif p_action = 'viewed' then
    p_items := '{}';
  else
    raise exception '알 수 없는 동작입니다.';
  end if;

  insert into consent_events (request_id, action, checked_items, document_sha256, actor_auth_id, actor_role, note)
  values (r.id, p_action, p_items, d.content_sha256, auth.uid(), role, p_note)
  returning id into new_id;
  return new_id;
end $$;
revoke all on function consent_record(uuid, text, text[], text) from public, anon;
grant execute on function consent_record(uuid, text, text[], text) to authenticated;

-- 운영자 현황: 요청마다 마지막 상태 (RLS 를 그대로 따름 — 학생은 본인 것만)
create view consent_status with (security_invoker = true) as
select r.id as request_id, r.student_id, r.enrollment_id, r.document_id, d.terms_code, d.revision, r.reason, r.required,
       r.created_at as requested_at, r.canceled_at,
       (select e.action from consent_events e where e.request_id = r.id and e.action <> 'viewed'
         order by e.acted_at desc, e.id desc limit 1) as last_action,
       (select max(e.acted_at) from consent_events e where e.request_id = r.id and e.action = 'accepted') as accepted_at,
       (select min(e.acted_at) from consent_events e where e.request_id = r.id and e.action = 'viewed') as first_viewed_at
from consent_requests r join terms_documents d on d.id = r.document_id;
grant select on consent_status to authenticated;

-- >>> 20261016000500_lms_policy_v1.sql
-- =====================================================================
-- LMS 정책 원본 v1.0 반영 (2026-10-16 대표확정, docs/lms/policy/official-source.md)
-- 어떤 Supabase에도 적용하지 않은 초안. 실제 운영 DB 적용은 대표 승인 후.
--
-- 1. 등록별 자동 적용 규칙 (POL-OP-16 — 소급 금지)
-- 2. 실제 결제 완료 시각 (POL-RN-01 — 이월은 운영자 확인 시각이 아니라 실제 결제 시각 기준)
-- 3. 공휴일 종류 (POL-CHG-07 — 법정·대체·임시공휴일만)
-- 4. 강사 노쇼 보상 수업 7일 기한 (POL-TU-03)
-- 5. 보상 적립금 단일 원장 (POL-PAY-09)
-- 6. 운영 업무: 신규 매칭 3영업일·재등록 강사 통보 확인 (POL-OP-13·14)
-- 7. 학생 장기 연기 신청 (POL-LV-01)
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. 등록별 자동 적용 규칙
-- 'policy_v1' = 정책 원본 v1.0 조건을 안내·동의받은 등록(신규·갱신)만. 기존 등록을 일괄로 바꾸지 않는다.
-- 'legacy' = 예전 계약서·예전 안내서·미확인 → 판본마다 다를 수 있는 규칙은 운영자가 확인
-- ---------------------------------------------------------------------
alter table enrollments add column policy_basis text not null default 'legacy'
  check (policy_basis in ('policy_v1', 'legacy'));

-- ---------------------------------------------------------------------
-- 2. 실제 결제 완료 시각
-- ---------------------------------------------------------------------
alter table payments add column paid_at timestamptz not null;   -- 실제 입금·결제 완료 시각 (은행 거래내역·아임웹 주문 시각)
alter table payments add column external_ref text unique;       -- 아임웹 주문번호·은행 거래 식별값 (같은 결제 두 번 기록 방지)
alter table payments add constraint payments_paid_on_matches
  check (((paid_at at time zone 'UTC') + interval '9 hours')::date = received_on);

-- ---------------------------------------------------------------------
-- 3. 공휴일 종류 (운영자 임의 추가일 없음)
-- ---------------------------------------------------------------------
alter table holidays add column kind text not null default 'legal'
  check (kind in ('legal', 'substitute', 'temporary'));         -- 법정공휴일 · 대체공휴일 · 임시공휴일

-- ---------------------------------------------------------------------
-- 4. 강사 노쇼 보상 수업 기한: 지급일(KST)부터 7일째 날까지 수업 완료 (A14)
-- 'policy_v1' 등록은 비어 있으면 자동으로 채움. 기한이 지나도 자동 소멸시키지 않음 (예외 미확정 POL-TU-10)
-- ---------------------------------------------------------------------
create or replace function compensation_set_deadline() returns trigger
language plpgsql as $$
begin
  if new.expires_on is null and (select policy_basis from enrollments where id = new.enrollment_id) = 'policy_v1' then
    new.expires_on := ((new.created_at at time zone 'UTC') + interval '9 hours')::date + 7;
  end if;
  return new;
end $$;
create trigger compensations_deadline before insert on compensations
  for each row execute function compensation_set_deadline();

-- ---------------------------------------------------------------------
-- 5. 보상 적립금 단일 원장 (아임웹 회원 적립금 병행 안 함, 유효기간 없음)
-- 사용 흐름: 예약(held, 잔액에서 빠짐) → 실제 결제 확인 후 확정(confirmed) / 미결제·취소면 복구(released)
--           확정 후 결제가 취소·환불되면 운영자가 복구(restored)
-- ---------------------------------------------------------------------
create table reward_redemptions (
  id uuid primary key default gen_random_uuid(),
  student_id uuid not null references students(id),
  enrollment_id uuid not null references enrollments(id),     -- 적립금을 쓸 등록(재등록)
  amount integer not null check (amount > 0),
  method text not null check (method in ('bank_transfer', 'card_link')),
  coupon_code text,                                           -- 카드결제 연계 방식은 미확정 (POL-PAY-10)
  status text not null default 'held' check (status in ('held', 'confirmed', 'released', 'restored')),
  payment_id uuid unique references payments(id),             -- 확정 근거. 같은 결제에 두 번 적용 불가
  note text,
  created_by uuid,
  created_at timestamptz not null default now(),
  decided_by uuid,
  decided_at timestamptz,
  check ((status in ('confirmed', 'restored')) = (payment_id is not null)),
  check (status not in ('released', 'restored') or note is not null)   -- 되돌린 이유
);
create unique index reward_redemptions_one_live on reward_redemptions (enrollment_id) where status in ('held', 'confirmed');
create trigger reward_redemptions_no_delete before delete on reward_redemptions for each row execute function forbid_delete();

create table reward_ledger (
  id uuid primary key default gen_random_uuid(),
  student_id uuid not null references students(id),
  kind text not null check (kind in ('grant_tutor_late_cancel', 'grant_admin', 'hold', 'release', 'refund_restore', 'admin_adjust')),
  amount integer not null check (amount <> 0),                -- +적립 / −사용(예약)
  lesson_id uuid references lessons(id),                      -- 강사 늦은 취소 지급의 근거 수업
  redemption_id uuid references reward_redemptions(id),
  note text,
  created_by uuid,
  created_at timestamptz not null default now(),
  check (kind <> 'grant_tutor_late_cancel' or (lesson_id is not null and amount > 0)),
  check (kind not in ('hold', 'release', 'refund_restore') or redemption_id is not null),
  check (kind <> 'hold' or amount < 0),
  check (kind not in ('grant_admin', 'release', 'refund_restore') or amount > 0),
  check (kind not in ('grant_admin', 'admin_adjust') or note is not null)
);
create unique index reward_ledger_one_grant_per_lesson on reward_ledger (lesson_id) where kind = 'grant_tutor_late_cancel';  -- 중복 지급 방지
create unique index reward_ledger_once_per_redemption on reward_ledger (redemption_id, kind) where redemption_id is not null;
create trigger reward_ledger_no_update before update on reward_ledger for each row execute function forbid_update();
create trigger reward_ledger_no_delete before delete on reward_ledger for each row execute function forbid_delete();

create or replace function reward_balance(p_student uuid) returns integer
language sql stable as $$
  select coalesce(sum(amount), 0)::int from reward_ledger where student_id = p_student
$$;

-- 원장 한 줄을 넣기 전 검사: 학생 행을 잠가 동시에 눌러도 순서대로, 잔액 0 미만 금지, 근거 확인
create or replace function reward_ledger_guard() returns trigger
language plpgsql as $$
declare
  l record;
  r record;
begin
  perform 1 from students where id = new.student_id for update;
  if new.kind = 'grant_tutor_late_cancel' then
    select ls.student_id, ls.class_status into l from lessons ls where ls.id = new.lesson_id;
    if l.student_id is distinct from new.student_id then raise exception '다른 학생의 수업으로 적립할 수 없습니다.'; end if;
    if l.class_status is distinct from 'Tutor canceled late' then raise exception '강사 6시간 미만 취소 수업에만 자동 적립합니다.'; end if;
    -- 학생에게 유리한 규칙이라 기존 학생(legacy 등록)에도 적용 (POL-OP-17, 2026-10-16 대표 결정)
  end if;
  if new.redemption_id is not null then
    select * into r from reward_redemptions where id = new.redemption_id;
    if r.student_id <> new.student_id then raise exception '다른 학생의 사용 요청입니다.'; end if;
    if new.kind in ('hold', 'release', 'refund_restore') and abs(new.amount) <> r.amount then
      raise exception '사용 요청 금액과 다릅니다.';
    end if;
  end if;
  if reward_balance(new.student_id) + new.amount < 0 then raise exception '적립금 잔액이 부족합니다.'; end if;
  return new;
end $$;
create trigger reward_ledger_guard before insert on reward_ledger for each row execute function reward_ledger_guard();

-- 사용 요청 상태는 정해진 순서로만: held → confirmed / released, confirmed → restored
create or replace function reward_redemption_check() returns trigger
language plpgsql as $$
begin
  if tg_op = 'INSERT' then
    if new.status <> 'held' then raise exception '사용 요청은 예약(held)으로 시작합니다.'; end if;
    if (select student_id from enrollments where id = new.enrollment_id) <> new.student_id then
      raise exception '다른 학생의 등록에는 적립금을 쓸 수 없습니다.';
    end if;
    return new;
  end if;
  if (old.student_id, old.enrollment_id, old.amount, old.method, old.created_at)
     is distinct from (new.student_id, new.enrollment_id, new.amount, new.method, new.created_at) then
    raise exception '사용 요청의 학생·등록·금액은 바꿀 수 없습니다. 되돌린 뒤 새로 만드세요.';
  end if;
  if old.status in ('released', 'restored') then raise exception '끝난 사용 요청은 바꿀 수 없습니다.'; end if;
  if old.status = new.status then return new; end if;
  if not ((old.status = 'held' and new.status in ('confirmed', 'released')) or (old.status = 'confirmed' and new.status = 'restored')) then
    raise exception '사용 요청 상태를 % → % 로 바꿀 수 없습니다.', old.status, new.status;
  end if;
  if new.status = 'confirmed'
     and (select enrollment_id from payments where id = new.payment_id) is distinct from new.enrollment_id then
    raise exception '이 등록의 결제 기록으로만 확정할 수 있습니다.';
  end if;
  if new.decided_at is null then new.decided_at := now(); end if;
  return new;
end $$;
create trigger reward_redemptions_check before insert or update on reward_redemptions
  for each row execute function reward_redemption_check();

-- 원장 기록은 상태와 함께 자동 (예약 = −금액, 복구 = +금액, 확정은 원장 변화 없음)
create or replace function reward_redemption_ledger() returns trigger
language plpgsql as $$
begin
  if tg_op = 'INSERT' then
    insert into reward_ledger (student_id, kind, amount, redemption_id, created_by)
    values (new.student_id, 'hold', -new.amount, new.id, new.created_by);
  elsif new.status <> old.status and new.status in ('released', 'restored') then
    insert into reward_ledger (student_id, kind, amount, redemption_id, note, created_by)
    values (new.student_id, case new.status when 'released' then 'release' else 'refund_restore' end,
            new.amount, new.id, new.note, new.decided_by);
  end if;
  return null;
end $$;
create trigger reward_redemptions_ledger after insert or update on reward_redemptions
  for each row execute function reward_redemption_ledger();

-- ---------------------------------------------------------------------
-- 6. 운영 업무 (관리자 '처리할 일') — 결제 확인 즉시 자동 생성, 완료 조건을 채우기 전에는 닫을 수 없음
-- - new_student_matching: 신규 학생 강사 매칭 + 학생 안내 (3영업일, POL-OP-13)
-- - renewal_tutor_notice: 재등록 사실·기간·일정 강사 통보 + 강사 확인 + 일정 조치 (POL-OP-14)
-- ---------------------------------------------------------------------

-- 영업일 = 토·일·holidays 제외. 시작 날짜 다음 날부터 셈
create or replace function add_business_days(p_from date, p_n integer) returns date
language plpgsql stable as $$
declare
  d date := p_from;
  left_days integer := p_n;
begin
  if p_n is null or p_n < 1 then raise exception '영업일 수가 올바르지 않습니다: %', p_n; end if;
  while left_days > 0 loop
    d := d + 1;
    if extract(isodow from d) < 6 and not exists (select 1 from holidays where day = d) then
      left_days := left_days - 1;
    end if;
  end loop;
  return d;
end $$;

create table admin_tasks (
  id uuid primary key default gen_random_uuid(),
  kind text not null check (kind in ('new_student_matching', 'renewal_tutor_notice')),
  enrollment_id uuid not null references enrollments(id),
  payment_id uuid references payments(id),           -- 업무를 만든 결제 확인
  tutor_id uuid references tutors(id),               -- 매칭한 강사 / 통보할 담당 강사
  due_at timestamptz,                                -- 처리 기한 (매칭: 3영업일 23:59 KST, 재등록 통보: 기준 미정 → 비워 둠)
  tutor_assigned_at timestamptz,                     -- 매칭: 강사 배정
  student_notified_at timestamptz,                   -- 매칭: 학생에게 강사·일정 안내
  tutor_notified_at timestamptz,                     -- 재등록: 강사에게 연장·기간·일정 통보
  tutor_acknowledged_at timestamptz,                 -- 재등록: 강사가 [확인] (발송 성공만으로 끝내지 않음)
  schedule_checked_at timestamptz,                   -- 재등록: 필요한 일정 조치 완료
  tutor_change_planned boolean not null default false, -- 재등록 때 강사 변경 예정 → 별도 처리 표시
  status text not null default 'open' check (status in ('open', 'done', 'canceled')),
  done_at timestamptz,
  done_by uuid,
  cancel_reason text,
  created_at timestamptz not null default now(),
  unique (kind, enrollment_id),                      -- 같은 등록에 같은 업무는 하나 (중복·누락 방지)
  check (status <> 'done' or done_at is not null),
  check (status <> 'canceled' or cancel_reason is not null),
  check (status <> 'done' or kind <> 'new_student_matching'
         or (tutor_id is not null and tutor_assigned_at is not null and student_notified_at is not null)),
  check (status <> 'done' or kind <> 'renewal_tutor_notice'
         or (tutor_id is not null and tutor_notified_at is not null and tutor_acknowledged_at is not null and schedule_checked_at is not null))
);
create trigger admin_tasks_no_delete before delete on admin_tasks for each row execute function forbid_delete();

-- 결제 확인 기록이 들어오면 업무 자동 생성 (첫 결제만, 나눠 낸 두 번째 결제는 무시)
create or replace function create_task_on_payment() returns trigger
language plpgsql as $$
declare
  e record;
  t uuid;
  kst_day date := ((new.confirmed_at at time zone 'UTC') + interval '9 hours')::date;
begin
  select id, student_id, previous_enrollment_id into e from enrollments where id = new.enrollment_id;
  if e.previous_enrollment_id is null then
    insert into admin_tasks (kind, enrollment_id, payment_id, due_at)
    values ('new_student_matching', e.id, new.id,
            (add_business_days(kst_day, 3) + interval '1 day') at time zone 'Asia/Seoul' - interval '1 microsecond')
    on conflict (kind, enrollment_id) do nothing;
  else
    select tutor_id into t from regular_schedules
      where student_id = e.student_id and (effective_to is null or effective_to >= kst_day)
      order by effective_from desc limit 1;
    insert into admin_tasks (kind, enrollment_id, payment_id, tutor_id)
    values ('renewal_tutor_notice', e.id, new.id, t)
    on conflict (kind, enrollment_id) do nothing;
  end if;
  return null;
end $$;
create trigger payments_create_task after insert on payments for each row execute function create_task_on_payment();

-- 관리자 화면용: 열린 업무와 급한 정도 (overdue 기한 초과 · due_soon 24시간 안 · open)
create view admin_task_board with (security_invoker = true) as
select t.*,
       case when t.due_at is not null and now() > t.due_at then 'overdue'
            when t.due_at is not null and now() > t.due_at - interval '24 hours' then 'due_soon'
            else 'open' end as urgency,
       case t.kind
         when 'new_student_matching' then
           array_remove(array[case when t.tutor_assigned_at is null then 'assign_tutor' end,
                              case when t.student_notified_at is null then 'notify_student' end], null)
         else
           array_remove(array[case when t.tutor_id is null then 'set_tutor' end,
                              case when t.tutor_change_planned then 'tutor_change' end,
                              case when t.tutor_notified_at is null then 'notify_tutor' end,
                              case when t.tutor_acknowledged_at is null then 'tutor_ack' end,
                              case when t.schedule_checked_at is null then 'check_schedule' end], null)
       end as missing_steps
from admin_tasks t
where t.status = 'open';
revoke all on admin_task_board from anon, authenticated;
grant select on admin_task_board to authenticated;   -- security_invoker: 실제로 보이는 행은 admin_tasks 의 RLS 대로

-- ---------------------------------------------------------------------
-- 7. 학생 장기 연기 신청 (24주만, 총 14일, 7일 단위 최대 2회 — 'policy_v1' 등록)
-- 기한(시작 4일 전)·사유 검사는 서버 규칙(leave.ts evaluateLongLeaveRequest)이 하고, DB는 한도를 마지막으로 지킴.
-- 승인되면 서버가 enrollment_extensions(student_long_term_leave)를 함께 기록
-- ---------------------------------------------------------------------
create table long_leave_requests (
  id uuid primary key default gen_random_uuid(),
  enrollment_id uuid not null references enrollments(id),
  change_request_id uuid unique references change_requests(id),
  leave_start date not null,
  days integer not null check (days in (7, 14)),
  reason_kind text not null check (reason_kind in ('health', 'family_emergency', 'business_trip', 'other_special')),
  evidence_note text,                       -- 증빙 확인 메모 (진단서 등 파일 자체는 비공개 저장소, 이름·병명은 적지 않음)
  status text not null default 'pending' check (status in ('pending', 'approved', 'rejected', 'withdrawn')),
  extension_id uuid unique references enrollment_extensions(id),
  decided_by uuid,
  decided_at timestamptz,
  created_at timestamptz not null default now(),
  check ((status = 'approved') = (extension_id is not null)),
  check (status <> 'approved' or evidence_note is not null)
);
create trigger long_leave_requests_no_delete before delete on long_leave_requests for each row execute function forbid_delete();

create or replace function long_leave_guard() returns trigger
language plpgsql as $$
declare
  e record;
  used_days integer;
  used_count integer;
begin
  select * into e from enrollments where id = new.enrollment_id for update;
  if e.policy_basis <> 'policy_v1' then
    raise exception '정책 원본 적용 등록이 아니라 장기 연기를 자동 접수하지 않습니다. 계약 조건을 확인해 운영자가 처리하세요.';
  end if;
  if e.weeks is distinct from 24 then raise exception '장기 연기는 24주 수강권만 가능합니다.'; end if;
  if new.leave_start < e.start_date or new.leave_start > e.final_end_date then
    raise exception '연기 시작일은 수강기간 안이어야 합니다.';
  end if;
  if new.status in ('pending', 'approved') then
    select coalesce(sum(days), 0), count(*) into used_days, used_count from long_leave_requests
      where enrollment_id = new.enrollment_id and status in ('pending', 'approved') and id <> new.id;
    if used_count + 1 > 2 or used_days + new.days > 14 then
      raise exception '장기 연기는 수강기간 동안 최대 14일(2회)까지입니다.';
    end if;
  end if;
  return new;
end $$;
create trigger long_leave_requests_guard before insert or update on long_leave_requests
  for each row execute function long_leave_guard();

-- ---------------------------------------------------------------------
-- 보호 적용 · 읽기 권한
-- ---------------------------------------------------------------------
select lms_protect(t::regclass) from unnest(array['reward_redemptions', 'reward_ledger', 'admin_tasks', 'long_leave_requests']) as t;

create policy student_own on reward_ledger for select to authenticated using (student_id = my_student_id());
create policy student_own on reward_redemptions for select to authenticated using (student_id = my_student_id());
create policy student_own on long_leave_requests for select to authenticated
  using (exists (select 1 from enrollments e where e.id = enrollment_id and e.student_id = my_student_id()));
-- 강사는 본인에게 온 재등록 통보만 (매칭 업무·학생 결제 정보는 보이지 않음)
create policy tutor_own on admin_tasks for select to authenticated
  using (kind = 'renewal_tutor_notice' and tutor_id = my_tutor_id());

-- >>> 20261016000600_lms_supabase_hardening.sql
-- =====================================================================
-- Supabase 실제 프로젝트용 권한 정리 (시험용 프로젝트 적용 전 추가)
-- Supabase는 public 스키마의 새 표·함수·시퀀스에 anon(로그인 안 한 사용자)·authenticated 권한을
-- 기본으로 줌. 표는 lms_protect 가 이미 막았고, 여기서는 함수·시퀀스를 막는다.
-- - 로그인 안 한 사용자(anon): LMS 함수·시퀀스 사용 불가
-- - 로그인 사용자(authenticated): 권한 정책(RLS)이 쓰는 함수만 실행 가능, 학생 번호 시퀀스는 사용 불가
-- - 쓰기는 서버(service_role)만
-- =====================================================================
revoke all on sequence student_code_seq from public, anon, authenticated;

revoke execute on all functions in schema public from public, anon;
grant execute on all functions in schema public to authenticated;
do $$
begin
  if exists (select 1 from pg_roles where rolname = 'service_role') then
    execute 'grant execute on all functions in schema public to service_role';
    execute 'grant usage, select on sequence student_code_seq to service_role';
  end if;
end $$;

-- 앞으로 만드는 함수도 anon 에게 자동으로 열리지 않게
alter default privileges in schema public revoke execute on functions from public, anon;

-- >>> 20261016000700_lms_authz_hardening.sql
-- =====================================================================
-- 권한 정리 2차 (2026-10-17 로그인 사용자 권한 점검 authz-probe 결과)
-- Supabase 는 public 에 새로 만든 표·보기·시퀀스에 anon·authenticated 모든 권한을 자동으로 준다.
-- 표는 lms_protect 가 막았지만 아래 두 가지가 남아 있었다 (데이터가 새지는 않음, 미리 닫음):
--   - consent_status 보기: 추가·수정·삭제 권한이 남아 있음 (보기가 RLS를 따르고 원본 표가 막혀 실제 쓰기는 안 됨)
--   - audit_log_id_seq: 앱 사용자가 이력 번호를 건드릴 수 있음 (REST API로는 못 부르지만 닫음)
-- 그리고 표 보호용 내부 함수 lms_protect 를 로그인 사용자 실행 목록에서 뺀다 (불러도 소유자가 아니라 실패하지만 닫음).
-- 다시 실행해도 같은 결과 (권한 회수·부여만 함, 데이터 변경 없음)
-- =====================================================================

revoke all on consent_status from anon, authenticated;
grant select on consent_status to authenticated;   -- security_invoker: 실제로 보이는 행은 원본 표의 RLS 대로

revoke all on all sequences in schema public from anon, authenticated;

revoke execute on function lms_protect(regclass) from authenticated;

-- 앞으로 만드는 표·보기·시퀀스도 앱 사용자에게 자동으로 열리지 않게 (필요한 읽기 권한은 lms_protect·각 파일에서 직접 부여)
alter default privileges in schema public revoke all on tables from anon, authenticated;
alter default privileges in schema public revoke all on sequences from anon, authenticated;

-- >>> 20261016000710_lms_service_role_grants.sql
-- =====================================================================
-- 서버 키(service_role) 표 권한 명시 (2026-10-17 5-4 실물 점검에서 발견)
-- 시험용 프로젝트에서는 새 표가 service_role 에게 자동으로 열리지 않았다 → 서버 키로 app_users 연결이 403
-- (GET app_users·audit_log·students 모두 42501 permission denied 확인). 지금까지는 Supabase 기본 권한에 기대고 있었음.
-- - 서버 키: LMS 표 읽기·쓰기 (RLS는 service_role 의 bypassrls 로 통과 — 쓰기는 서버 기능만 하는 설계)
-- - 변경 이력(audit_log)은 서버 키도 고치거나 지울 수 없음 (추가·읽기만)
-- - 앱 사용자(anon·authenticated) 권한은 바꾸지 않음
-- 다시 실행해도 같은 결과 (권한 부여·회수만, 데이터 변경 없음)
-- =====================================================================
do $$
begin
  if exists (select 1 from pg_roles where rolname = 'service_role') then
    execute 'grant usage on schema public to service_role';
    execute 'grant select, insert, update, delete on all tables in schema public to service_role';
    execute 'revoke update, delete, truncate on audit_log from service_role';
    execute 'grant usage, select on all sequences in schema public to service_role';
    execute 'grant execute on all functions in schema public to service_role';
    -- 앞으로 만드는 표·시퀀스·함수도 서버 키에 같은 권한
    execute 'alter default privileges in schema public grant select, insert, update, delete on tables to service_role';
    execute 'alter default privileges in schema public grant usage, select on sequences to service_role';
    execute 'alter default privileges in schema public grant execute on functions to service_role';
  end if;
end $$;

-- >>> 20261016000800_lms_admin_mfa.sql
-- =====================================================================
-- 운영자 추가 인증(TOTP) 강제 + 운영자 역할 분리 (POL-AC-05·07, 정책 원본 A27·A34, D-29)
-- - 운영자 권한(is_admin)은 TOTP까지 마친 세션(Supabase JWT 의 aal = 'aal2')에서만 참
--   → 이메일 코드만 통과한 운영자 세션은 RLS상 학생·결제·수업 데이터를 한 줄도 못 봄 (화면이 아니라 DB가 막음)
-- - 운영자 역할: owner(대표) / staff(운영직원). 대표 전용 작업(환불 실행·승인, 적립금 지급·조정·취소,
--   금전 관련 중요 설정)은 서버 쓰기 기능이 is_owner() 로 확인한다. 쓰기 자체는 지금처럼 서버(service_role)만
-- - 직원의 읽기 범위는 아직 정하지 않음 → 지금은 운영자와 같음. 직원 계정을 실제로 만들기 전에 정한다 (07-decisions)
-- - 강사·학생은 TOTP 없음 (이메일 코드만)
-- 다시 실행해도 같은 결과
-- =====================================================================

alter table app_users add column if not exists admin_level text check (admin_level in ('owner', 'staff'));
-- 이미 있는 운영자 계정은 낮은 권한(staff)으로 둔다. 대표 계정은 서버·SQL Editor 에서 owner 로 따로 지정 (최소 권한)
update app_users set admin_level = 'staff' where role = 'admin' and admin_level is null;
update app_users set admin_level = null where role <> 'admin' and admin_level is not null;
do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'app_users_admin_level_role') then
    alter table app_users add constraint app_users_admin_level_role check ((role = 'admin') = (admin_level is not null));
  end if;
end $$;

-- TOTP까지 마친 세션인지 (Supabase Auth 가 발급한 JWT 의 aal 값)
create or replace function auth_is_aal2() returns boolean
language sql stable set search_path = public as $$
  select coalesce(auth.jwt() ->> 'aal', '') = 'aal2'
$$;

create or replace function is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select auth_is_aal2()
     and coalesce((select role = 'admin' from app_users where auth_user_id = auth.uid()), false)
$$;

-- 대표 전용 권한 확인 (서버 쓰기 기능이 호출 운영자 확인에 사용, POL-AC-07)
create or replace function is_owner() returns boolean
language sql stable security definer set search_path = public as $$
  select auth_is_aal2()
     and coalesce((select role = 'admin' and admin_level = 'owner' from app_users where auth_user_id = auth.uid()), false)
$$;

revoke all on function auth_is_aal2() from public, anon;
revoke all on function is_owner() from public, anon;
grant execute on function auth_is_aal2(), is_admin(), is_owner() to authenticated;
do $$
begin
  if exists (select 1 from pg_roles where rolname = 'service_role') then
    execute 'grant execute on function auth_is_aal2(), is_admin(), is_owner() to service_role';
  end if;
end $$;

-- >>> 20261016000820_lms_my_role.sql
-- =====================================================================
-- 로그인 직후 본인 역할 확인 (로그인 화면용, POL-AC-04·05)
-- 메일 코드만 통과한(aal1) 운영자도 '인증 앱 코드를 물어야 하는 사람'인지 알아야 하므로, 본인 역할 하나만 돌려준다.
-- - 본인 것만: auth.uid() 의 app_users.role (student / tutor / admin), 연결 안 된 계정은 null
-- - 다른 사람 역할·학생 번호 등은 돌려주지 않음. 운영자 권한 자체는 여전히 is_admin()(aal2) 로만
-- 다시 실행해도 같은 결과
-- =====================================================================
create or replace function my_role() returns text
language sql stable security definer set search_path = public as $$
  select role from app_users where auth_user_id = auth.uid()
$$;

revoke all on function my_role() from public, anon;
grant execute on function my_role() to authenticated;
do $$
begin
  if exists (select 1 from pg_roles where rolname = 'service_role') then
    execute 'grant execute on function my_role() to service_role';
  end if;
end $$;

-- >>> 20261018000900_lms_register_student.sql
-- =====================================================================
-- 신규 학생 등록 저장 (2026-10-18 대표 최종 시안: 신청서 불러오기 + 강사·스케줄 선택)
-- 화면이 한 번 부르면 학생 · 수강등록 · (결제 확인) · (고정 일정 · 정규 수업)을 한 트랜잭션으로 만든다.
-- - 권한: TOTP까지 마친 운영자(is_admin, aal2)만. 표에는 앱 쓰기 권한을 주지 않고 이 함수만 연다 (POL-AC-07: 쓰기는 서버 쪽에서만)
-- - 중복 방지: 화면이 만든 요청 번호(request_id)가 같으면 처음 결과를 그대로 돌려준다 (저장 버튼 여러 번 눌러도 1번)
-- - 결제 확인 전에는 강사·정규 일정을 확정하지 않는다 (POL-OP-13). 결제 확인 기록이 들어가면 '신규 매칭' 업무가 기존 트리거로 생긴다
-- - 강사 배정까지 하면 업무의 '강사 배정'만 채운다. '학생 안내'는 안내가 실제로 끝났을 때 따로 (업무는 그때 사라짐)
-- - 일정 충돌: 강사의 다른 수업과 겹침 + 수업 사이 휴식 10분 + 강사 휴무 (POL-OP-21). 하나라도 있으면 아무것도 저장하지 않고
--   충돌 날짜 목록을 오류 상세(JSON)로 돌려준다. 화면이 먼저 같은 검사를 하지만, 그 사이 다른 등록이 생길 수 있어 여기서 다시 확인
-- - 수강등록의 적용 규칙(policy_basis)은 기본값(legacy) 그대로. 정책 원본 조건 안내·동의를 확인한 뒤 운영자가 바꾼다 (자동으로 최신 판본을 고르지 않음)
-- - 이메일이 같아도 기존 학생·계정에 연결하지 않는다 (POL-AC-04). 항상 새 학생 번호
-- 다시 실행해도 같은 결과
-- =====================================================================

create table if not exists registration_requests (
  id uuid primary key,                    -- 화면이 만든 요청 번호 (변경 이력이 id 로 행을 찾음)
  created_by uuid not null,
  student_id uuid not null references students(id),
  enrollment_id uuid not null references enrollments(id),
  result jsonb not null,
  created_at timestamptz not null default now()
);
do $$
begin
  if not exists (select 1 from pg_trigger where tgname = 'registration_requests_audit') then
    perform lms_protect('registration_requests'::regclass);
  end if;
end $$;

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
  v_break interval := interval '10 minutes';   -- POL-OP-21 (코드 CONFIRMED.minBreakMin 과 같아야 함)
  sid uuid;
  scode text;
  eid uuid;
  d date;
  s jsonb;
  n integer := 0;
  t0 timestamptz;
  t1 timestamptz;
  conflicts jsonb := '[]'::jsonb;
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
  if v_tutor is not null then
    if jsonb_array_length(slots) <> v_weekly then
      raise exception '정규 시간 수(%)가 주 횟수(%)와 다릅니다.', jsonb_array_length(slots), v_weekly;
    end if;
    if (select count(distinct (x ->> 'weekday')::int) from jsonb_array_elements(slots) x) <> jsonb_array_length(slots) then
      raise exception '같은 요일에 정규 수업을 2개 넣을 수 없습니다.';
    end if;
    if not exists (select 1 from jsonb_array_elements(slots) x where (x ->> 'weekday')::int = extract(dow from v_start)) then
      raise exception '수강 시작일은 첫 정규 수업일이어야 합니다 (시작일 요일이 수업 요일에 없음).';
    end if;
    if not exists (select 1 from tutors where id = v_tutor and active) then raise exception '활동 중인 강사가 아닙니다.'; end if;
  elsif jsonb_array_length(slots) > 0 then
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
    for s in select * from jsonb_array_elements(slots) loop
      insert into regular_schedules (student_id, tutor_id, weekday, start_time_kst, duration_min, effective_from)
      values (sid, v_tutor, (s ->> 'weekday')::smallint, (s ->> 'time')::time, v_dur, v_start);
    end loop;

    d := v_start;
    while d <= v_end loop
      select x into s from jsonb_array_elements(slots) x where (x ->> 'weekday')::int = extract(dow from d);
      if found then
        n := n + 1;
        t0 := (d + (s ->> 'time')::time) at time zone 'Asia/Seoul';
        t1 := t0 + make_interval(mins => v_dur);
        conflicts := conflicts || coalesce((
          select jsonb_agg(jsonb_build_object('date', d, 'time', s ->> 'time', 'reason',
                   case when l.starts_at < t1 and t0 < l.ends_at then (case when l.kind = 'regular' then 'tutor_regular' else 'tutor_makeup' end) else 'break' end,
                   'other_starts_at', l.starts_at, 'other_ends_at', l.ends_at))
          from lessons l
          where l.tutor_id = v_tutor and l.state <> 'canceled'
            and l.starts_at < t1 + v_break and t0 - v_break < l.ends_at), '[]'::jsonb);
        conflicts := conflicts || coalesce((
          select jsonb_agg(jsonb_build_object('date', d, 'time', s ->> 'time', 'reason', 'tutor_time_off',
                   'other_starts_at', o.starts_at, 'other_ends_at', o.ends_at))
          from tutor_time_off o where o.tutor_id = v_tutor and o.starts_at < t1 and t0 < o.ends_at), '[]'::jsonb);
        -- 충돌이 하나라도 나오면 더 넣지 않고 끝까지 검사만 (겹침 제약 오류 대신 충돌 날짜 전체를 돌려주려고)
        if jsonb_array_length(conflicts) = 0 then
          insert into lessons (enrollment_id, student_id, tutor_id, kind, seq, starts_at, ends_at, created_by)
          values (eid, sid, v_tutor, 'regular', n, t0, t1, me);
        end if;
      end if;
      d := d + 1;
    end loop;

    if jsonb_array_length(conflicts) > 0 then
      raise exception '일정 충돌 %건 — 저장하지 않았습니다.', jsonb_array_length(conflicts)
        using errcode = 'P0001', detail = conflicts::text, hint = 'schedule_conflict';
    end if;
    if n <> v_weekly * v_weeks then
      raise exception '만들어진 정규 수업 수(%)가 등록 회차(%)와 다릅니다.', n, v_weekly * v_weeks;
    end if;

    update admin_tasks set tutor_id = v_tutor, tutor_assigned_at = now()
    where kind = 'new_student_matching' and enrollment_id = eid;
  end if;

  res := jsonb_build_object('student_id', sid, 'student_code', scode, 'enrollment_id', eid,
                            'status', case when v_paid then 'confirmed' else 'pending_payment' end,
                            'lessons', n, 'start_date', v_start, 'end_date', v_end);
  insert into registration_requests (id, created_by, student_id, enrollment_id, result)
  values (p_request_id, me, sid, eid, res);
  return res;
end $$;

revoke all on function admin_register_student(uuid, jsonb) from public, anon;
grant execute on function admin_register_student(uuid, jsonb) to authenticated;

-- 같은 이메일 학생이 이미 있는지 (연결하지 않고 알려 주기만 — POL-AC-04). 운영자만
create or replace function admin_students_with_email(p_email text)
returns table (code text, name_ko text)
language sql stable security definer set search_path = public as $$
  select code, name_ko from students
  where is_admin() and email is not null and lower(email) = lower(trim(p_email))
  order by code
$$;
revoke all on function admin_students_with_email(text) from public, anon;
grant execute on function admin_students_with_email(text) to authenticated;

-- >>> 20261021001000_lms_schedule_confirm.sql
-- =====================================================================
-- 신규 배정 확정 관리 (2026-10-21, 정책 원본 H22 · B01 · D-50 4번 절차)
-- 사고: 강사가 '그 일정 가능'이라고만 답했고, 운영자가 학생에게만 최종 확정을 보내고 강사에게는 안 보냄 → 학생만 기다림
--
-- 구조
--  1. 일정안(schedule_plans): 등록 하나에 버전 1, 2, … 강사·요일·시각·첫 수업일 한 벌
--     - proposed  강사에게 제안함, 답 대기. 수업은 아직 만들지 않음 (강사 '가능' 답 ≠ 확정)
--     - confirmed 운영자가 '강사 가능 → 확정'을 한 번 누름 → 같은 트랜잭션에서 정규 일정·수업 생성 + 양쪽 최종 안내 2건 생성
--     - declined / withdrawn 강사가 안 됨 / 운영자가 다른 안으로 바꿈 (지우지 않고 남김)
--  2. 최종 안내(schedule_notices): 확정된 일정안 × 받는 사람(학생·강사) = 정확히 1건씩 (unique = 중복 방지 키)
--     - 일정 확정 상태와 안내 상태는 따로. 둘 다 '보냄'이 되어야 신규 매칭 업무가 끝남 (한쪽만이면 열려 있음)
--     - 지금은 자동 발송 연결이 없음 → 운영자가 [문구 복사]를 누른 시각을 '보냄'으로 기록 (sent_via = 'copy').
--       복사 = 보냄이지 '받음·읽음'이 아님. 받음·읽음 확인 칸은 채널이 정해지면 추가 (H22 3번)
--     - 나중에 자동 발송기(이메일·캘린더·WhatsApp API 등, 채널 미결정)가 붙으면 lms_notice_result 로 결과를 기록.
--       재시도는 '보냄'이 아닌 건만 (pending·failed). 결과가 불명확(unknown)하면 자동 재시도하지 않고 운영자 확인
--  3. 확정 후 일정 변경(강사·시각·시작일)은 아직 없음 → 새 버전을 만들고 새 안내 2건을 받아야 함 (예전 안내는 새 일정의 근거가 아님).
--     그 기능을 만들 때 'superseded' 상태를 추가한다. 지금은 확정된 안이 있으면 새 확정을 거절
--
-- 미결정 (대표 질문, 코드에 기본값 넣지 않음): 발송 채널·자동화, 강사 확인 회신 의무, 경고 시각(첫 수업 몇 시간 전 등), 답 대기 경고 시각
-- 권한: 운영자(is_admin, TOTP)만. 표에는 앱 쓰기 권한 없음 — 함수로만 (POL-AC-07)
-- 다시 실행해도 같은 결과
-- =====================================================================

create table if not exists schedule_plans (
  id uuid primary key,                         -- 화면이 만든 요청 번호 (같은 제안 두 번 눌러도 1건)
  enrollment_id uuid not null references enrollments(id),
  version integer not null check (version >= 1),
  tutor_id uuid not null references tutors(id),
  slots jsonb not null,                        -- [{"weekday":2,"time":"20:00"}] 한국 시각
  start_date date not null,                    -- 첫 정규 수업일
  state text not null default 'proposed' check (state in ('proposed', 'confirmed', 'declined', 'withdrawn')),
  proposal_sent_at timestamptz,                -- 강사에게 보낼 제안 문구를 복사한 시각 (= 제안 보냄)
  confirmed_at timestamptz,                    -- 운영자가 '강사 가능 → 확정'을 누른 시각
  confirmed_by uuid,
  closed_at timestamptz,
  close_reason text,
  created_by uuid,
  created_at timestamptz not null default now(),
  unique (enrollment_id, version),
  check ((state = 'confirmed') = (confirmed_at is not null and confirmed_by is not null)),
  check ((state in ('declined', 'withdrawn')) = (closed_at is not null))
);
create unique index if not exists schedule_plans_one_open on schedule_plans (enrollment_id) where state = 'proposed';
create unique index if not exists schedule_plans_one_confirmed on schedule_plans (enrollment_id) where state = 'confirmed';

create table if not exists schedule_notices (
  id uuid primary key default gen_random_uuid(),
  plan_id uuid not null references schedule_plans(id),
  recipient_kind text not null check (recipient_kind in ('student', 'tutor')),
  recipient_id uuid not null,
  -- 지금: 학생 카카오톡 채널(수동), 강사 WhatsApp(수동). 자동 채널은 대표 결정 후 사용
  channel text not null check (channel in ('kakao_manual', 'whatsapp_manual', 'email', 'google_calendar', 'whatsapp_api')),
  status text not null default 'pending' check (status in ('pending', 'sent', 'failed', 'unknown')),
  sent_at timestamptz,
  sent_by uuid,                                -- 복사한 운영자 (자동 발송이면 비움)
  sent_via text check (sent_via in ('copy', 'system')),
  attempts integer not null default 0,
  last_error text,
  last_attempt_at timestamptz,
  created_at timestamptz not null default now(),
  unique (plan_id, recipient_kind),            -- 일정 버전 × 받는 사람 = 1건 (중복 안내 방지)
  check ((status = 'sent') = (sent_at is not null and sent_via is not null))
);

do $$
begin
  if not exists (select 1 from pg_trigger where tgname = 'schedule_plans_audit') then
    perform lms_protect('schedule_plans'::regclass);
    perform lms_protect('schedule_notices'::regclass);
    create trigger schedule_plans_no_delete before delete on schedule_plans for each row execute function forbid_delete();
    create trigger schedule_notices_no_delete before delete on schedule_notices for each row execute function forbid_delete();
  end if;
end $$;

-- 신규 매칭 업무는 강사 안내까지 끝나야 완료 (기존: 강사 배정 + 학생 안내만 보던 것에 추가)
do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'admin_tasks_matching_tutor_notified') then
    alter table admin_tasks add constraint admin_tasks_matching_tutor_notified
      check (status <> 'done' or kind <> 'new_student_matching' or tutor_notified_at is not null);
  end if;
end $$;

-- 일정안의 등록기간 전체 충돌 (강사 다른 수업 겹침·휴식 10분·휴무, POL-OP-21). 저장은 하지 않고 목록만
create or replace function lms_plan_conflicts(p_tutor uuid, p_slots jsonb, p_start date, p_end date, p_dur smallint)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_break interval := interval '10 minutes';   -- POL-OP-21 (코드 CONFIRMED.minBreakMin 과 같아야 함)
  d date := p_start;
  s jsonb;
  t0 timestamptz;
  t1 timestamptz;
  out jsonb := '[]'::jsonb;
begin
  while d <= p_end loop
    select x into s from jsonb_array_elements(p_slots) x where (x ->> 'weekday')::int = extract(dow from d);
    if found then
      t0 := (d + (s ->> 'time')::time) at time zone 'Asia/Seoul';
      t1 := t0 + make_interval(mins => p_dur);
      out := out || coalesce((
        select jsonb_agg(jsonb_build_object('date', d, 'time', s ->> 'time', 'reason',
                 case when l.starts_at < t1 and t0 < l.ends_at then (case when l.kind = 'regular' then 'tutor_regular' else 'tutor_makeup' end) else 'break' end,
                 'other_starts_at', l.starts_at, 'other_ends_at', l.ends_at))
        from lessons l
        where l.tutor_id = p_tutor and l.state <> 'canceled'
          and l.starts_at < t1 + v_break and t0 - v_break < l.ends_at), '[]'::jsonb);
      out := out || coalesce((
        select jsonb_agg(jsonb_build_object('date', d, 'time', s ->> 'time', 'reason', 'tutor_time_off',
                 'other_starts_at', o.starts_at, 'other_ends_at', o.ends_at))
        from tutor_time_off o where o.tutor_id = p_tutor and o.starts_at < t1 and t0 < o.ends_at), '[]'::jsonb);
    end if;
    d := d + 1;
  end loop;
  return out;
end $$;
revoke all on function lms_plan_conflicts(uuid, jsonb, date, date, smallint) from public, anon, authenticated;

-- 일정안 모양 검사 (주 횟수·요일·첫 수업일). 오류면 예외
create or replace function lms_check_plan_shape(p_enrollment uuid, p_tutor uuid, p_slots jsonb, p_start date)
returns void
language plpgsql stable security definer set search_path = public as $$
declare
  e record;
begin
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
  if not exists (select 1 from jsonb_array_elements(p_slots) x where (x ->> 'weekday')::int = extract(dow from p_start)) then
    raise exception '수강 시작일은 첫 정규 수업일이어야 합니다 (시작일 요일이 수업 요일에 없음).';
  end if;
  if not exists (select 1 from tutors where id = p_tutor and active) then raise exception '활동 중인 강사가 아닙니다.'; end if;
end $$;
revoke all on function lms_check_plan_shape(uuid, uuid, jsonb, date) from public, anon, authenticated;

-- 일정안 만들기 (proposed). 같은 등록에 답 대기 중인 안이 있으면 '다른 안으로 바꿈'으로 닫음. 충돌이 있으면 저장하지 않음
create or replace function lms_new_plan(p_plan_id uuid, p_enrollment uuid, p_tutor uuid, p_slots jsonb, p_start date, p_me uuid)
returns integer
language plpgsql security definer set search_path = public as $$
declare
  e record;
  v integer;
  conflicts jsonb;
begin
  perform lms_check_plan_shape(p_enrollment, p_tutor, p_slots, p_start);
  if exists (select 1 from schedule_plans where enrollment_id = p_enrollment and state = 'confirmed') then
    raise exception '이미 확정된 일정이 있습니다. 확정 후 변경은 일정 변경 기능으로 (아직 없음).';
  end if;
  select * into e from enrollments where id = p_enrollment;
  conflicts := lms_plan_conflicts(p_tutor, p_slots, e.start_date, e.base_end_date, e.duration_min);
  if jsonb_array_length(conflicts) > 0 then
    raise exception '일정 충돌 %건 — 저장하지 않았습니다.', jsonb_array_length(conflicts)
      using errcode = 'P0001', detail = conflicts::text, hint = 'schedule_conflict';
  end if;
  update schedule_plans set state = 'withdrawn', closed_at = now(), close_reason = '다른 안으로 바꿈'
  where enrollment_id = p_enrollment and state = 'proposed';
  select coalesce(max(version), 0) + 1 into v from schedule_plans where enrollment_id = p_enrollment;
  insert into schedule_plans (id, enrollment_id, version, tutor_id, slots, start_date, created_by)
  values (p_plan_id, p_enrollment, v, p_tutor, p_slots, p_start, p_me);
  return v;
end $$;
revoke all on function lms_new_plan(uuid, uuid, uuid, jsonb, date, uuid) from public, anon, authenticated;

-- 확정 결과에 안내 2건의 번호를 붙여 화면이 바로 [복사]를 기록할 수 있게
create or replace function lms_plan_notice_ids(p_plan_id uuid)
returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'tutor_notice_id', (select id from schedule_notices where plan_id = p_plan_id and recipient_kind = 'tutor'),
    'student_notice_id', (select id from schedule_notices where plan_id = p_plan_id and recipient_kind = 'student'))
$$;
revoke all on function lms_plan_notice_ids(uuid) from public, anon, authenticated;

-- 확정 (내부): 정규 일정·수업 + 양쪽 최종 안내 2건을 한 트랜잭션으로. 이미 확정이면 그대로 돌려줌
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
  perform lms_check_plan_shape(pl.enrollment_id, pl.tutor_id, pl.slots, pl.start_date);
  select * into e from enrollments where id = pl.enrollment_id;

  -- 제안 뒤에 다른 수업·휴무가 생겼을 수 있어 다시 검사
  conflicts := lms_plan_conflicts(pl.tutor_id, pl.slots, e.start_date, e.base_end_date, e.duration_min);
  if jsonb_array_length(conflicts) > 0 then
    raise exception '일정 충돌 %건 — 확정하지 않았습니다.', jsonb_array_length(conflicts)
      using errcode = 'P0001', detail = conflicts::text, hint = 'schedule_conflict';
  end if;

  for s in select * from jsonb_array_elements(pl.slots) loop
    insert into regular_schedules (student_id, tutor_id, weekday, start_time_kst, duration_min, effective_from)
    values (e.student_id, pl.tutor_id, (s ->> 'weekday')::smallint, (s ->> 'time')::time, e.duration_min, e.start_date);
  end loop;
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

-- 안내 '보냄'을 신규 매칭 업무에 옮김. 양쪽 모두 '보냄'이면 업무 완료 (사람이 따로 닫지 않음)
create or replace function lms_finish_matching(p_plan_id uuid, p_me uuid)
returns boolean
language plpgsql security definer set search_path = public as $$
declare
  pl record;
  st timestamptz;
  tt timestamptz;
begin
  select * into pl from schedule_plans where id = p_plan_id;
  if pl.state is distinct from 'confirmed' then return false; end if;
  select sent_at into st from schedule_notices where plan_id = p_plan_id and recipient_kind = 'student' and status = 'sent';
  select sent_at into tt from schedule_notices where plan_id = p_plan_id and recipient_kind = 'tutor' and status = 'sent';
  -- 보낸 쪽은 바로 기록 (화면에 남은 쪽만 보이게), 둘 다 보냈을 때만 완료
  update admin_tasks set student_notified_at = st, tutor_notified_at = tt,
         status = case when st is not null and tt is not null then 'done' else status end,
         done_at = case when st is not null and tt is not null then now() end,
         done_by = case when st is not null and tt is not null then p_me end
  where kind = 'new_student_matching' and enrollment_id = pl.enrollment_id and status = 'open';
  return st is not null and tt is not null;
end $$;
revoke all on function lms_finish_matching(uuid, uuid) from public, anon, authenticated;

-- ---------- 화면에서 부르는 함수 (운영자 TOTP 세션만) ----------

-- 이미 저장된 등록(결제 확인)에 일정안 제안. p = {tutor_id, slots, start_date, tutor_answer}
-- tutor_answer = 'accepted' 이면 (강사가 이미 가능하다고 답한 경우) 제안과 확정을 한 번에
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
  v := lms_new_plan(p_plan_id, p_enrollment, nullif(p ->> 'tutor_id', '')::uuid, coalesce(p -> 'slots', '[]'::jsonb), (p ->> 'start_date')::date, me);
  if p ->> 'tutor_answer' = 'accepted' then return lms_confirm_plan(p_plan_id, me); end if;
  return jsonb_build_object('plan_id', p_plan_id, 'version', v, 'state', 'proposed');
end $$;

-- 강사가 가능하다고 답함 → 운영자가 한 번 누름 = 확정 (정규 일정·수업 + 양쪽 안내 2건). 두 번 눌러도 한 번
create or replace function admin_confirm_schedule(p_plan_id uuid)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  eid uuid;
begin
  if not is_admin() then raise exception '운영자(추가 인증 완료)만 일정을 확정할 수 있습니다.' using errcode = '42501'; end if;
  select enrollment_id into eid from schedule_plans where id = p_plan_id;
  if eid is null then raise exception '일정안이 없습니다.'; end if;
  perform pg_advisory_xact_lock(hashtextextended(eid::text, 0));
  perform set_config('app.actor_id', me::text, true);
  perform set_config('app.actor_via', 'admin_confirm_schedule', true);
  return lms_confirm_plan(p_plan_id, me);
end $$;

-- 강사가 안 된다고 함(declined) / 운영자가 이 안을 접음(withdrawn). 확정된 안은 여기서 닫지 않음
create or replace function admin_close_plan(p_plan_id uuid, p_state text, p_reason text)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  pl record;
begin
  if not is_admin() then raise exception '운영자(추가 인증 완료)만 바꿀 수 있습니다.' using errcode = '42501'; end if;
  if p_state not in ('declined', 'withdrawn') then raise exception '닫는 이유는 declined·withdrawn 만 가능합니다.'; end if;
  select * into pl from schedule_plans where id = p_plan_id for update;
  if not found then raise exception '일정안이 없습니다.'; end if;
  if pl.state = p_state then return jsonb_build_object('plan_id', pl.id, 'state', pl.state, 'repeated', true); end if;
  if pl.state <> 'proposed' then raise exception '답 대기 중인 안만 닫을 수 있습니다 (지금: %).', pl.state; end if;
  perform set_config('app.actor_id', me::text, true);
  perform set_config('app.actor_via', 'admin_close_plan', true);
  update schedule_plans set state = p_state, closed_at = now(), close_reason = nullif(trim(p_reason), '') where id = p_plan_id;
  return jsonb_build_object('plan_id', pl.id, 'state', p_state);
end $$;

-- 강사 제안 문구 복사 = 제안 보냄 (처음 복사한 시각만 남김)
create or replace function admin_mark_proposal_sent(p_plan_id uuid)
returns timestamptz
language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  t timestamptz;
begin
  if not is_admin() then raise exception '운영자(추가 인증 완료)만 기록할 수 있습니다.' using errcode = '42501'; end if;
  perform set_config('app.actor_id', me::text, true);
  perform set_config('app.actor_via', 'admin_mark_proposal_sent', true);
  update schedule_plans set proposal_sent_at = coalesce(proposal_sent_at, now())
  where id = p_plan_id and state = 'proposed'
  returning proposal_sent_at into t;
  if t is null then raise exception '답 대기 중인 일정안이 아닙니다.'; end if;
  return t;
end $$;

-- 최종 안내 문구 복사 = 그쪽 안내 보냄. 이미 보낸 건은 그대로(시각 안 바뀜). 양쪽 다 보내면 매칭 업무 완료
create or replace function admin_mark_notice_sent(p_notice_id uuid)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  nt record;
  done boolean;
begin
  if not is_admin() then raise exception '운영자(추가 인증 완료)만 기록할 수 있습니다.' using errcode = '42501'; end if;
  select n.*, p.state as plan_state into nt from schedule_notices n join schedule_plans p on p.id = n.plan_id where n.id = p_notice_id for update of n;
  if not found then raise exception '안내가 없습니다.'; end if;
  if nt.plan_state <> 'confirmed' then raise exception '확정된 일정의 안내가 아닙니다.'; end if;
  perform set_config('app.actor_id', me::text, true);
  perform set_config('app.actor_via', 'admin_mark_notice_sent', true);
  if nt.status <> 'sent' then
    update schedule_notices set status = 'sent', sent_at = now(), sent_by = me, sent_via = 'copy',
                                attempts = attempts + 1, last_attempt_at = now()
    where id = p_notice_id;
  end if;
  done := lms_finish_matching(nt.plan_id, me);
  return jsonb_build_object('notice_id', p_notice_id, 'status', 'sent', 'repeated', nt.status = 'sent', 'all_sent', done);
end $$;

-- 자동 발송기(서버) 결과 기록 — 채널이 정해지면 사용. 앱 사용자는 못 부름
-- 이미 'sent'인 건은 바꾸지 않음 (성공한 안내를 다시 보내거나 실패로 덮지 않음)
create or replace function lms_notice_result(p_notice_id uuid, p_status text, p_error text)
returns void
language plpgsql security definer set search_path = public as $$
declare
  nt record;
begin
  if p_status not in ('sent', 'failed', 'unknown') then raise exception '결과는 sent·failed·unknown 만 가능합니다.'; end if;
  select * into nt from schedule_notices where id = p_notice_id for update;
  if not found or nt.status = 'sent' then return; end if;
  perform set_config('app.actor_via', 'lms_notice_result', true);
  update schedule_notices
  set status = p_status, attempts = attempts + 1, last_attempt_at = now(), last_error = nullif(p_error, ''),
      sent_at = case when p_status = 'sent' then now() end, sent_via = case when p_status = 'sent' then 'system' end
  where id = p_notice_id;
  if p_status = 'sent' then perform lms_finish_matching(nt.plan_id, null); end if;
end $$;
revoke all on function lms_notice_result(uuid, text, text) from public, anon, authenticated;

revoke all on function admin_propose_schedule(uuid, uuid, jsonb), admin_confirm_schedule(uuid), admin_close_plan(uuid, text, text),
                       admin_mark_proposal_sent(uuid), admin_mark_notice_sent(uuid) from public, anon;
grant execute on function admin_propose_schedule(uuid, uuid, jsonb), admin_confirm_schedule(uuid), admin_close_plan(uuid, text, text),
                          admin_mark_proposal_sent(uuid), admin_mark_notice_sent(uuid) to authenticated;
do $$
begin
  if exists (select 1 from pg_roles where rolname = 'service_role') then
    execute 'grant execute on function lms_notice_result(uuid, text, text) to service_role';
  end if;
end $$;

-- 자동 발송기가 다시 보낼 대상: 확정된 일정의 '보냄 아님' 중 pending·failed 만 (unknown 은 운영자 확인 후)
create or replace view schedule_notice_outbox with (security_invoker = true) as
select n.* from schedule_notices n join schedule_plans p on p.id = n.plan_id
where p.state = 'confirmed' and n.status in ('pending', 'failed');
revoke all on schedule_notice_outbox from anon, authenticated;

-- 운영자 화면: 손이 필요한 일정안만 — 강사 답 대기 / 확정했지만 한쪽이라도 안내 안 됨.
-- 경고 시각(첫 수업 몇 시간 전 등)은 미결정 → 숫자(hours_to_first_lesson)만 주고 화면 규칙이 판단
create or replace view schedule_plan_board with (security_invoker = true) as
select p.id as plan_id, p.enrollment_id, p.version, p.state, p.tutor_id, t.name as tutor_name,
       e.student_id, s.name_ko as student_name, s.code as student_code,
       p.slots, p.start_date, p.proposal_sent_at, p.confirmed_at, p.created_at,
       coalesce(
         (select min(l.starts_at) from lessons l where l.enrollment_id = p.enrollment_id and l.kind = 'regular' and l.state <> 'canceled'),
         (select (p.start_date + (x ->> 'time')::time) at time zone 'Asia/Seoul' from jsonb_array_elements(p.slots) x
           where (x ->> 'weekday')::int = extract(dow from p.start_date) limit 1)) as first_lesson_at,
       sn.id as student_notice_id, sn.status as student_notice_status, sn.sent_at as student_notice_sent_at,
       tn.id as tutor_notice_id, tn.status as tutor_notice_status, tn.sent_at as tutor_notice_sent_at
from schedule_plans p
join enrollments e on e.id = p.enrollment_id
join students s on s.id = e.student_id
join tutors t on t.id = p.tutor_id
left join schedule_notices sn on sn.plan_id = p.id and sn.recipient_kind = 'student'
left join schedule_notices tn on tn.plan_id = p.id and tn.recipient_kind = 'tutor'
where p.state = 'proposed'
   or (p.state = 'confirmed' and (sn.status is distinct from 'sent' or tn.status is distinct from 'sent'));
revoke all on schedule_plan_board from anon, authenticated;
grant select on schedule_plan_board to authenticated;   -- security_invoker: 보이는 행은 각 표의 RLS 대로 (운영자만)

-- 신규 매칭 업무의 남은 단계에 '강사에게 최종 안내' 추가 (열은 그대로)
create or replace view admin_task_board with (security_invoker = true) as
select t.*,
       case when t.due_at is not null and now() > t.due_at then 'overdue'
            when t.due_at is not null and now() > t.due_at - interval '24 hours' then 'due_soon'
            else 'open' end as urgency,
       case t.kind
         when 'new_student_matching' then
           array_remove(array[case when t.tutor_assigned_at is null then 'assign_tutor' end,
                              case when t.tutor_notified_at is null then 'notify_tutor' end,
                              case when t.student_notified_at is null then 'notify_student' end], null)
         else
           array_remove(array[case when t.tutor_id is null then 'set_tutor' end,
                              case when t.tutor_change_planned then 'tutor_change' end,
                              case when t.tutor_notified_at is null then 'notify_tutor' end,
                              case when t.tutor_acknowledged_at is null then 'tutor_ack' end,
                              case when t.schedule_checked_at is null then 'check_schedule' end], null)
       end as missing_steps
from admin_tasks t
where t.status = 'open';

-- ---------- 신규 학생 등록 함수 갱신: 강사·시간을 고르면 '일정안'으로 저장 ----------
-- 강사가 이미 가능하다고 답했으면 p.tutor_answer = 'accepted' → 같은 저장에서 확정까지 (운영자 동작 1번)
-- 그렇지 않으면 학생·수강권·결제 + 제안(답 대기)만. 수업은 확정 때 생김 (강사 '가능' 답 전 확정 금지, D-50·H22)
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
    perform lms_new_plan(plan_id, eid, v_tutor, slots, v_start, me);   -- 충돌이면 여기서 오류 → 아무것도 저장 안 됨
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

commit;
