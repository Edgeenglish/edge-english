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
