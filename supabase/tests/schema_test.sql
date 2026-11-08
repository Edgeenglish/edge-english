-- LMS 스키마 제약·권한 테스트 (가짜 데이터만)
-- 실패하면 오류로 멈추고, 모두 통과하면 run.sh 가 ✅ 를 출력

create or replace function pg_temp.expect_error(stmt text, pattern text) returns void
language plpgsql as $$
begin
  begin
    execute stmt;
  exception when others then
    if sqlerrm !~ pattern and sqlstate !~ pattern then
      raise exception '실패: 다른 오류 [%] % (기대: %)', sqlstate, sqlerrm, pattern;
    end if;
    return;
  end;
  raise exception '실패: 오류가 나야 하는데 성공함 → %', stmt;
end $$;

create or replace function pg_temp.ok(cond boolean, label text) returns void
language plpgsql as $$
begin
  if not coalesce(cond, false) then raise exception '실패: %', label; end if;
  raise notice '통과: %', label;
end $$;

set app.actor_id = 'aaaaaaaa-0000-0000-0000-000000000001';
set app.actor_via = 'test';
-- 강사 귀책 자동 연장(20261108020000)은 맨 아래 시험에서만 켬 — 그 위 예전 규칙(A20) 시험은 시행 전으로 둠
update feature_flags set updated_at = '2099-01-01' where key = 'tutor_fault_extension_since';

-- ---------- 가짜 기본 데이터 ----------
insert into tutors (id, name, country, timezone, google_calendar_id) values
  ('11111111-1111-1111-1111-111111111111', 'TestTutorA', 'Australia', 'Australia/Sydney', 'cal-a@group'),
  ('22222222-2222-2222-2222-222222222222', 'TestTutorB', 'Canada', 'America/Toronto', null);

insert into students (id, name_ko, name_en, timezone) values
  ('33333333-3333-3333-3333-333333333333', '테스트일', 'Test One', 'Asia/Seoul'),
  ('44444444-4444-4444-4444-444444444444', '테스트이', 'Test Two', 'Australia/Brisbane');

select pg_temp.ok((select code from students where name_en = 'Test One') = 'STU-0001', '학생 고유번호 자동 부여 STU-0001');
select pg_temp.expect_error($$insert into students (name_ko, name_en, timezone) values ('가', 'A', 'Mars/Base')$$, 'check');

-- 4주 · 주 2회 · 50분, 2026-11-03(화) 시작
insert into enrollments (id, student_id, seq, contract_version, weeks, weekly_count, duration_min, start_date, base_end_date, lessons_purchased, status)
values ('55555555-5555-5555-5555-555555555555', '33333333-3333-3333-3333-333333333333', 1, 'SC2', 4, 2, 50,
        '2026-11-03', '2026-11-30', 8, 'active');
insert into enrollment_periods (id, enrollment_id, idx, start_date, end_date, credits_granted)
values ('66666666-6666-6666-6666-666666666666', '55555555-5555-5555-5555-555555555555', 1, '2026-11-03', '2026-11-30', 2);

select pg_temp.expect_error($$insert into enrollments (student_id, seq, contract_version, weeks, weekly_count, duration_min, start_date, base_end_date, lessons_purchased)
  values ('33333333-3333-3333-3333-333333333333', 2, 'SC2', 4, 2, 50, '2026-11-03', '2026-11-29', 8)$$, 'check');
select pg_temp.ok(true, '종료일 = 시작일 + 27 이 아니면 거부');

select pg_temp.expect_error($$insert into enrollments (student_id, seq, contract_version, weeks, weekly_count, duration_min, start_date, base_end_date, lessons_purchased)
  values ('33333333-3333-3333-3333-333333333333', 2, 'SC2', 4, 2, 50, '2026-11-20', '2026-12-17', 8)$$, 'exclusion|23P01');
select pg_temp.ok(true, '같은 학생 수강기간 겹침 거부');

-- ---------- 수업 겹침 방지 ----------
insert into lessons (id, enrollment_id, student_id, tutor_id, kind, seq, starts_at, ends_at)
values ('77777777-7777-7777-7777-777777777771', '55555555-5555-5555-5555-555555555555', '33333333-3333-3333-3333-333333333333',
        '11111111-1111-1111-1111-111111111111', 'regular', 1, '2026-11-03 08:00+00', '2026-11-03 08:50+00');

select pg_temp.ok((select kst_date from lessons where seq = 1) = '2026-11-03', 'kst_date = 한국 날짜');

-- 같은 강사, 겹치는 시간 → 거부 (다른 학생이라도)
insert into enrollments (id, student_id, seq, contract_version, weeks, weekly_count, duration_min, start_date, base_end_date, lessons_purchased, status)
values ('55555555-5555-5555-5555-555555555556', '44444444-4444-4444-4444-444444444444', 1, 'SC2', 4, 1, 50,
        '2026-11-03', '2026-11-30', 4, 'active');
select pg_temp.expect_error($$insert into lessons (enrollment_id, student_id, tutor_id, kind, seq, starts_at, ends_at)
  values ('55555555-5555-5555-5555-555555555556', '44444444-4444-4444-4444-444444444444', '11111111-1111-1111-1111-111111111111',
          'regular', 1, '2026-11-03 08:30+00', '2026-11-03 09:20+00')$$, 'lessons_no_tutor_overlap');
select pg_temp.ok(true, '같은 강사 시간 겹침 거부');

-- 끝나는 시각 = 다음 시작 시각은 허용 (08:50 종료, 08:50 시작)
insert into lessons (enrollment_id, student_id, tutor_id, kind, seq, starts_at, ends_at)
values ('55555555-5555-5555-5555-555555555556', '44444444-4444-4444-4444-444444444444', '11111111-1111-1111-1111-111111111111',
        'regular', 1, '2026-11-03 08:50+00', '2026-11-03 09:40+00');
select pg_temp.ok(true, '바로 이어지는 수업은 허용');

-- 같은 학생, 다른 강사, 겹치는 시간 → 거부
select pg_temp.expect_error($$insert into lessons (enrollment_id, student_id, tutor_id, kind, seq, starts_at, ends_at)
  values ('55555555-5555-5555-5555-555555555555', '33333333-3333-3333-3333-333333333333', '22222222-2222-2222-2222-222222222222',
          'regular', 2, '2026-11-03 08:10+00', '2026-11-03 08:30+00')$$, 'lessons_no_student_overlap');
select pg_temp.ok(true, '같은 학생 시간 겹침 거부');

-- 취소하면 그 시간은 다시 비어서 다른 수업을 넣을 수 있음
update lessons set state = 'canceled', canceled_at = now(), class_status = 'Student canceled in advance'
where id = '77777777-7777-7777-7777-777777777771';
insert into lessons (id, enrollment_id, student_id, tutor_id, kind, makeup_of, starts_at, ends_at)
values ('77777777-7777-7777-7777-777777777772', '55555555-5555-5555-5555-555555555555', '33333333-3333-3333-3333-333333333333',
        '11111111-1111-1111-1111-111111111111', 'makeup', '77777777-7777-7777-7777-777777777771',
        '2026-11-03 08:00+00', '2026-11-03 08:50+00');
select pg_temp.ok(true, '취소된 시간에 보강 넣기 가능');

-- 한 수업의 살아 있는 보강은 1개만
select pg_temp.expect_error($$insert into lessons (enrollment_id, student_id, tutor_id, kind, makeup_of, starts_at, ends_at)
  values ('55555555-5555-5555-5555-555555555555', '33333333-3333-3333-3333-333333333333', '11111111-1111-1111-1111-111111111111',
          'makeup', '77777777-7777-7777-7777-777777777771', '2026-11-05 08:00+00', '2026-11-05 08:50+00')$$, 'lessons_one_live_makeup');
select pg_temp.ok(true, '같은 수업 보강 중복 확정 거부');

-- 수업은 삭제 불가
select pg_temp.expect_error($$delete from lessons where id = '77777777-7777-7777-7777-777777777772'$$, '삭제할 수 없습니다');
select pg_temp.ok(true, '수업 삭제 금지');

-- ---------- 변경권 ----------
-- 차감은 변경 요청 1건당 1번 (migration 1700: 수업당 → 요청당, 되돌린 뒤 다시 변경 가능)
insert into change_requests (id, lesson_id, type, status, via) values
  ('cccccccc-0000-0000-0000-000000000771', '77777777-7777-7777-7777-777777777771', 'student_cancel', 'applied', 'admin_app');
insert into credit_ledger (period_id, lesson_id, change_request_id, reason, delta)
values ('66666666-6666-6666-6666-666666666666', '77777777-7777-7777-7777-777777777771', 'cccccccc-0000-0000-0000-000000000771', 'student_change', -1);
select pg_temp.expect_error($$insert into credit_ledger (period_id, lesson_id, change_request_id, reason, delta)
  values ('66666666-6666-6666-6666-666666666666', '77777777-7777-7777-7777-777777777771', 'cccccccc-0000-0000-0000-000000000771', 'student_change', -1)$$, 'unique|23505');
select pg_temp.expect_error($$insert into credit_ledger (period_id, lesson_id, reason, delta)
  values ('66666666-6666-6666-6666-666666666666', '77777777-7777-7777-7777-777777777771', 'student_change', -1)$$, 'credit_ledger_request_required');
select pg_temp.ok(credit_balance('66666666-6666-6666-6666-666666666666') = 1, '같은 요청 변경권 두 번 차감 거부, 요청 없는 차감 거부, 남은 1개');

insert into lessons (id, enrollment_id, student_id, tutor_id, kind, seq, starts_at, ends_at, state, canceled_at, class_status)
values ('77777777-7777-7777-7777-777777777773', '55555555-5555-5555-5555-555555555555', '33333333-3333-3333-3333-333333333333',
        '11111111-1111-1111-1111-111111111111', 'regular', 2, '2026-11-05 08:00+00', '2026-11-05 08:50+00',
        'canceled', now(), 'Student canceled in advance');
insert into lessons (id, enrollment_id, student_id, tutor_id, kind, seq, starts_at, ends_at, state, canceled_at, class_status)
values ('77777777-7777-7777-7777-777777777774', '55555555-5555-5555-5555-555555555555', '33333333-3333-3333-3333-333333333333',
        '11111111-1111-1111-1111-111111111111', 'regular', 3, '2026-11-10 08:00+00', '2026-11-10 08:50+00',
        'canceled', now(), 'Student canceled in advance');
insert into change_requests (id, lesson_id, type, status, via) values
  ('cccccccc-0000-0000-0000-000000000773', '77777777-7777-7777-7777-777777777773', 'student_cancel', 'applied', 'admin_app'),
  ('cccccccc-0000-0000-0000-000000000774', '77777777-7777-7777-7777-777777777774', 'student_cancel', 'applied', 'admin_app');
insert into credit_ledger (period_id, lesson_id, change_request_id, reason, delta)
values ('66666666-6666-6666-6666-666666666666', '77777777-7777-7777-7777-777777777773', 'cccccccc-0000-0000-0000-000000000773', 'student_change', -1);
select pg_temp.expect_error($$insert into credit_ledger (period_id, lesson_id, change_request_id, reason, delta)
  values ('66666666-6666-6666-6666-666666666666', '77777777-7777-7777-7777-777777777774', 'cccccccc-0000-0000-0000-000000000774', 'student_change', -1)$$, '남아 있지 않습니다');
select pg_temp.ok(credit_balance('66666666-6666-6666-6666-666666666666') = 0, '변경권 0개 밑으로 내려가지 않음');
select pg_temp.expect_error($$update credit_ledger set delta = 1$$, '수정할 수 없습니다');
select pg_temp.ok(true, '변경권 장부 수정 금지 (반대 기록으로만 정정)');

-- ---------- 수업 기록 ----------
insert into lessons (id, enrollment_id, student_id, tutor_id, kind, seq, starts_at, ends_at, state, class_status)
values ('77777777-7777-7777-7777-777777777775', '55555555-5555-5555-5555-555555555555', '33333333-3333-3333-3333-333333333333',
        '11111111-1111-1111-1111-111111111111', 'regular', 4, '2026-11-12 08:00+00', '2026-11-12 08:50+00', 'done', 'Normal');
insert into class_records (lesson_id, covered_topics, first_submitted_at)
values ('77777777-7777-7777-7777-777777777775', 'Unit 3', '2026-11-12 08:55+00');
update class_records set covered_topics = 'Unit 3, phrasal verbs', first_submitted_at = '2026-11-12 08:51+00'
where lesson_id = '77777777-7777-7777-7777-777777777775';
select pg_temp.ok((select first_submitted_at from class_records where lesson_id = '77777777-7777-7777-7777-777777777775')
                  = '2026-11-12 08:55+00', '최초 기록 시각은 나중에 고쳐지지 않음 (인센티브 기준 보호)');

-- ---------- 이력 ----------
select pg_temp.ok((select count(*) from audit_log where table_name = 'lessons' and row_id = '77777777-7777-7777-7777-777777777771') = 2,
                  '수업 생성·취소가 이력에 남음');
select pg_temp.ok((select actor from audit_log order by id desc limit 1) = 'aaaaaaaa-0000-0000-0000-000000000001', '이력에 누가 했는지 남음');
select pg_temp.expect_error($$delete from audit_log$$, '삭제할 수 없습니다');
select pg_temp.expect_error($$update audit_log set actor = null$$, '수정할 수 없습니다');
select pg_temp.ok(true, '이력 수정·삭제 금지');

-- ---------- 캘린더 동기화 대기열 ----------
select pg_temp.ok((select desired_version > synced_version from calendar_sync where lesson_id = '77777777-7777-7777-7777-777777777771'),
                  '수업이 바뀌면 캘린더 반영 대기열에 올라감');

-- ---------- 정산 ----------
select pg_temp.expect_error($$insert into payroll_runs (tutor_id, month, status) values ('11111111-1111-1111-1111-111111111111', '2026-11-01', 'approved')$$, 'check');
select pg_temp.ok(true, '운영자 최종 금액·승인 없이 정산 확정 불가');

-- ---------- 계약 판본 · 옛 상품 이관 (v0.2) ----------
insert into students (id, name_ko, name_en) values ('88888888-8888-8888-8888-888888888888', '테스트삼', 'Test Three');
insert into enrollments (id, student_id, seq, contract_version, legacy_label, weekly_count, duration_min, start_date, base_end_date, lessons_purchased, status)
values ('55555555-5555-5555-5555-555555555557', '88888888-8888-8888-8888-888888888888', 1, 'SC1', '1개월(30일)', 2, 40,
        '2025-12-01', '2025-12-30', 8, 'completed');
select pg_temp.ok(true, '1판 계약(30일) 옛 등록은 실제 날짜 그대로 이관 가능');
select pg_temp.expect_error($$insert into enrollments (student_id, seq, contract_version, weekly_count, duration_min, start_date, base_end_date, lessons_purchased)
  values ('88888888-8888-8888-8888-888888888888', 2, 'SC2', 2, 40, '2026-01-01', '2026-01-28', 8)$$, 'check');
select pg_temp.ok(true, '현행 상품(주)도 옛 상품 이름도 없는 등록은 거부');
select pg_temp.expect_error($$insert into enrollments (student_id, seq, contract_version, weeks, weekly_count, duration_min, start_date, base_end_date, lessons_purchased)
  values ('88888888-8888-8888-8888-888888888888', 2, 'TC1', 4, 2, 40, '2026-01-01', '2026-01-28', 8)$$, 'check');
select pg_temp.ok(true, '학생 등록에 강사 계약 판본을 넣으면 거부');
-- 계약서 없이 안내서만 받은 등록: 계약서 판본을 비워 둠 (임의 판본 금지)
insert into enrollments (student_id, seq, contract_version, guide_version, weeks, weekly_count, duration_min, start_date, base_end_date, lessons_purchased, status)
values ('88888888-8888-8888-8888-888888888888', 2, null, 'G20260709', 4, 2, 40, '2026-08-03', '2026-08-30', 8, 'completed');
select pg_temp.ok((select contract_version is null and guide_version = 'G20260709' from enrollments where student_id = '88888888-8888-8888-8888-888888888888' and seq = 2),
                  '계약서 없이 안내서만 받은 등록은 계약 판본 없이 저장');
select pg_temp.expect_error($$insert into enrollments (student_id, seq, contract_version, weeks, weekly_count, duration_min, start_date, base_end_date, lessons_purchased)
  values ('88888888-8888-8888-8888-888888888888', 3, 'G20260709', 4, 2, 40, '2026-09-07', '2026-10-04', 8)$$, 'check');
select pg_temp.ok(true, '안내서를 계약서 칸에 넣으면 거부');
-- 전달·동의 근거 기록
insert into terms_deliveries (terms_code, student_id, timing, channel) values ('G20260709', '88888888-8888-8888-8888-888888888888', 'unknown', 'kakao');
select pg_temp.expect_error($$update terms_deliveries set timing = 'before_payment'$$, '수정할 수 없습니다');
select pg_temp.expect_error($$insert into terms_deliveries (terms_code, student_id, timing, channel, consent_kind) values ('SC2', '88888888-8888-8888-8888-888888888888', 'unknown', 'kakao', 'online_accept')$$, 'check');
select pg_temp.ok(true, '전달 기록은 고칠 수 없고, 동의 종류에는 동의 시각이 필요');

-- ---------- 기간 연장 장부 ----------
insert into enrollment_extensions (enrollment_id, days, reason, approved_by)
values ('55555555-5555-5555-5555-555555555556', 7, 'tutor_long_term_leave', 'aaaaaaaa-0000-0000-0000-000000000001');
select pg_temp.ok((select final_end_date from enrollments where id = '55555555-5555-5555-5555-555555555556') = '2026-12-07',
                  '연장 기록 7일 → 최종 종료일 자동 7일 연장');
select pg_temp.expect_error($$update enrollments set extension_days = 30 where id = '55555555-5555-5555-5555-555555555556'$$, '직접 고칠 수 없습니다');
select pg_temp.ok(true, '연장 일수 직접 수정 금지 (장부로만)');
insert into enrollment_extensions (enrollment_id, days, reason, approved_by)
values ('55555555-5555-5555-5555-555555555556', -7, 'correction', 'aaaaaaaa-0000-0000-0000-000000000001');
select pg_temp.ok((select final_end_date from enrollments where id = '55555555-5555-5555-5555-555555555556') = '2026-11-30',
                  '정정 기록(-7일)으로 되돌리기');

-- ---------- 수업 결과와 상태의 짝 ----------
select pg_temp.expect_error($$insert into lessons (enrollment_id, student_id, tutor_id, kind, seq, starts_at, ends_at, class_status)
  values ('55555555-5555-5555-5555-555555555555', '33333333-3333-3333-3333-333333333333', '22222222-2222-2222-2222-222222222222',
          'regular', 5, '2026-11-17 08:00+00', '2026-11-17 08:50+00', 'Normal')$$, 'check');
select pg_temp.expect_error($$insert into lessons (enrollment_id, student_id, tutor_id, kind, seq, starts_at, ends_at, state, canceled_at, class_status)
  values ('55555555-5555-5555-5555-555555555555', '33333333-3333-3333-3333-333333333333', '22222222-2222-2222-2222-222222222222',
          'regular', 5, '2026-11-17 08:00+00', '2026-11-17 08:50+00', 'canceled', now(), 'Normal')$$, '진행 결과');
select pg_temp.expect_error($$insert into lessons (enrollment_id, student_id, tutor_id, kind, seq, starts_at, ends_at, state, class_status)
  values ('55555555-5555-5555-5555-555555555555', '33333333-3333-3333-3333-333333333333', '22222222-2222-2222-2222-222222222222',
          'regular', 5, '2026-11-17 08:00+00', '2026-11-17 08:50+00', 'done', 'Student canceled late')$$, '취소 결과');
select pg_temp.ok(true, '예정 수업에 결과 넣기·취소 수업에 진행 결과·진행 수업에 취소 결과 모두 거부');
select pg_temp.expect_error($$insert into lessons (enrollment_id, student_id, tutor_id, kind, seq, starts_at, ends_at)
  values ('55555555-5555-5555-5555-555555555555', '44444444-4444-4444-4444-444444444444', '22222222-2222-2222-2222-222222222222',
          'regular', 6, '2026-11-19 08:00+00', '2026-11-19 08:50+00')$$, '학생과 수강등록의 학생이 다릅니다');
select pg_temp.ok(true, '다른 학생의 수강등록에 수업을 붙이면 거부');

-- ---------- 기준값 ----------
select pg_temp.ok((select count(*) from class_status_rules) = 14, '상태매핑표 14개');
select pg_temp.ok((select bool_and(not enabled) from feature_flags), '모든 기능 스위치는 꺼진 상태로 시작 (발송·캘린더 쓰기 포함)');

-- ---------- 강사 계약 판본 (정산 단계) ----------
insert into tutor_contracts (tutor_id, terms_version, signed_on, base_rate_usd, max_rate_usd) values
  ('11111111-1111-1111-1111-111111111111', 'TC1', '2025-11-27', 14, 17),
  ('22222222-2222-2222-2222-222222222222', 'TC3', '2026-08-24', 11, 17);
select pg_temp.ok((select count(distinct base_rate_usd) from tutor_contracts) = 2, '강사마다 계약 판본별 기본 시급을 따로 기록');
select pg_temp.expect_error($$insert into tutor_contracts (tutor_id, terms_version, signed_on, base_rate_usd, max_rate_usd)
  values ('22222222-2222-2222-2222-222222222222', 'SC2', '2026-09-01', 11, 17)$$, 'check');
select pg_temp.ok(true, '강사 계약에 학생 계약 판본을 넣으면 거부');

-- ---------- 접근 권한 (RLS) ----------
insert into app_users (auth_user_id, role, student_id) values
  ('bbbbbbbb-0000-0000-0000-000000000001', 'student', '33333333-3333-3333-3333-333333333333'),
  ('bbbbbbbb-0000-0000-0000-000000000002', 'student', '44444444-4444-4444-4444-444444444444');
insert into app_users (auth_user_id, role, tutor_id) values
  ('bbbbbbbb-0000-0000-0000-000000000003', 'tutor', '22222222-2222-2222-2222-222222222222'),
  ('bbbbbbbb-0000-0000-0000-000000000004', 'tutor', '11111111-1111-1111-1111-111111111111');
insert into app_users (auth_user_id, role, admin_level) values ('bbbbbbbb-0000-0000-0000-000000000009', 'admin', 'owner');

-- 아래 권한 시험은 TOTP까지 마친 세션(aal2)으로 진행. TOTP 전 세션은 맨 아래 'migration 800' 에서 따로 확인
set request.jwt.claims = '{"aal":"aal2"}';
set role authenticated;

set request.jwt.claim.sub = 'bbbbbbbb-0000-0000-0000-000000000001';
select pg_temp.ok((select count(*) from students) = 1, '학생 A는 본인 정보 1명만 보임');
select pg_temp.ok((select count(*) from lessons where student_id <> '33333333-3333-3333-3333-333333333333') = 0, '학생 A는 학생 B의 수업을 못 봄');
select pg_temp.ok((select count(*) from tutors) = 0, '학생은 강사 원본 표를 직접 못 봄');
select pg_temp.ok((select count(*) from student_my_tutors()) = 1, '학생은 담당 강사의 이름·강의실 링크만 봄');
select pg_temp.ok((select count(*) from audit_log) = 0, '학생은 이력을 못 봄');
select pg_temp.expect_error($$update lessons set state = 'canceled'$$, 'permission|42501');
select pg_temp.expect_error($$insert into credit_ledger (period_id, reason, delta) values ('66666666-6666-6666-6666-666666666666', 'admin_adjust', 1)$$, 'permission|42501');
select pg_temp.ok(true, '학생은 직접 고치거나 변경권을 만들 수 없음');

set request.jwt.claim.sub = 'bbbbbbbb-0000-0000-0000-000000000003';
select pg_temp.ok((select count(*) from lessons) = 0, '다른 강사(B)는 강사 A의 수업을 못 봄');
select pg_temp.ok((select count(*) from tutor_my_students()) = 0, '강사 B에게는 담당 아닌 학생 정보가 안 보임');
select pg_temp.ok((select count(*) from students) = 0, '강사는 학생 원본 표(휴대폰·실명)를 직접 못 봄');

set request.jwt.claim.sub = 'bbbbbbbb-0000-0000-0000-000000000004';
select pg_temp.ok((select count(*) from tutor_my_students()) = 2, '강사 A는 담당 학생 2명의 필요한 정보만 봄');

set request.jwt.claim.sub = 'bbbbbbbb-0000-0000-0000-000000000009';
select pg_temp.ok((select count(*) from students) = 3 and (select count(*) from audit_log) > 0, '운영자는 전체를 봄');

reset request.jwt.claim.sub;
select pg_temp.ok((select count(*) from students) = 0, '로그인 안 한 요청은 아무것도 못 봄');
reset role;

set role anon;
select pg_temp.expect_error($$select * from students$$, 'permission|42501');
select pg_temp.ok(true, '비로그인(anon) 역할은 표 접근 자체가 막힘');
reset role;

-- ---------- 수업 안내 확인·동의 (v0.1 초안, POL-OP-12) ----------
insert into terms_versions (code, kind, audience, title, source_ref) values ('TESTCT1', 'class_terms', 'student', '테스트 수업 안내 1판', 'TEST');
insert into terms_documents (id, terms_code, format, body_md, required_items, optional_items, content_sha256, status, published_at)
values ('cccccccc-0000-0000-0000-000000000001', 'TESTCT1', 'text', '6시간 전까지 변경 (가짜 문구)',
        '[{"key":"cancel6h","text":"6시간 규정 확인"},{"key":"period","text":"수강 기간 확인"}]',
        '[{"key":"marketing","text":"소식 받기(선택)"}]', 'fake', 'published', now());
select pg_temp.ok((select content_sha256 <> 'fake' and length(content_sha256) = 64 from terms_documents where terms_code = 'TESTCT1'),
                  '문서 해시는 앱이 넣은 값이 아니라 DB가 계산');
select pg_temp.expect_error($$update terms_documents set body_md = '바꾼 문구' where terms_code = 'TESTCT1'$$, '고칠 수 없습니다');
select pg_temp.expect_error($$delete from terms_documents where terms_code = 'TESTCT1'$$, '삭제할 수 없습니다');
select pg_temp.ok(true, '게시된 안내 문서는 고치거나 지울 수 없음 (새 판으로만)');
select pg_temp.expect_error($$insert into consent_requests (student_id, enrollment_id, document_id, reason)
  values ('44444444-4444-4444-4444-444444444444', '55555555-5555-5555-5555-555555555555', 'cccccccc-0000-0000-0000-000000000001', 'new')$$, '학생과 수강등록의 학생이 다릅니다');
select pg_temp.ok(true, '다른 학생의 등록으로 확인 요청을 만들 수 없음');
insert into consent_requests (id, student_id, enrollment_id, document_id, reason)
values ('cccccccc-0000-0000-0000-0000000000a1', '33333333-3333-3333-3333-333333333333', '55555555-5555-5555-5555-555555555555',
        'cccccccc-0000-0000-0000-000000000001', 'new');

set role authenticated;
set request.jwt.claim.sub = 'bbbbbbbb-0000-0000-0000-000000000002';   -- 학생 B
select pg_temp.ok((select count(*) from consent_requests) = 0, '학생 B는 학생 A의 확인 요청을 못 봄 (링크를 알아도)');
select pg_temp.expect_error($$select consent_record('cccccccc-0000-0000-0000-0000000000a1', 'accepted', array['cancel6h','period'])$$, '본인의 확인 요청이 아닙니다');
select pg_temp.ok(true, '학생 B는 학생 A 대신 동의할 수 없음');
set request.jwt.claim.sub = 'bbbbbbbb-0000-0000-0000-000000000003';   -- 강사
select pg_temp.expect_error($$select consent_record('cccccccc-0000-0000-0000-0000000000a1', 'accepted', array['cancel6h','period'])$$, '본인의 확인 요청이 아닙니다');
set request.jwt.claim.sub = 'bbbbbbbb-0000-0000-0000-000000000009';   -- 운영자
select pg_temp.expect_error($$select consent_record('cccccccc-0000-0000-0000-0000000000a1', 'accepted', array['cancel6h','period'])$$, '본인의 확인 요청이 아닙니다');
select pg_temp.ok(true, '강사·운영자도 학생 대신 동의할 수 없음');
select pg_temp.expect_error($$insert into consent_events (request_id, action, document_sha256, actor_auth_id, actor_role)
  values ('cccccccc-0000-0000-0000-0000000000a1', 'accepted', 'x', 'bbbbbbbb-0000-0000-0000-000000000009', 'student')$$, 'permission|42501');
select pg_temp.ok(true, '동의 기록 표에 직접 쓰기 불가 (함수로만)');

set request.jwt.claim.sub = 'bbbbbbbb-0000-0000-0000-000000000001';   -- 학생 A
select consent_record('cccccccc-0000-0000-0000-0000000000a1', 'viewed');
select pg_temp.expect_error($$select consent_record('cccccccc-0000-0000-0000-0000000000a1', 'accepted', array['cancel6h'])$$, '필수 항목');
select pg_temp.ok(true, '필수 항목을 다 체크하지 않으면 동의 안 됨');
select pg_temp.expect_error($$select consent_record('cccccccc-0000-0000-0000-0000000000a1', 'accepted', array['cancel6h','period','refund'])$$, '문서에 없는 항목');
select pg_temp.ok(consent_record('cccccccc-0000-0000-0000-0000000000a1', 'accepted', array['cancel6h','period'])
                  = consent_record('cccccccc-0000-0000-0000-0000000000a1', 'accepted', array['cancel6h','period']),
                  '본인 동의 성공, 두 번 눌러도 동의 기록은 1건');
select pg_temp.ok((select last_action = 'accepted' and accepted_at is not null and first_viewed_at is not null from consent_status),
                  '학생 A는 본인 동의 상태(열람·동의 시각)를 봄');
select pg_temp.ok((select not ('marketing' = any(checked_items)) from consent_events where action = 'accepted'),
                  '선택 항목(마케팅)은 체크하지 않아도 수강 안내 동의와 따로 기록');
select consent_record('cccccccc-0000-0000-0000-0000000000a1', 'withdrawn', '{}', '학생 요청');
select consent_record('cccccccc-0000-0000-0000-0000000000a1', 'accepted', array['cancel6h','period']);
select pg_temp.ok((select count(*) from consent_events where action <> 'viewed') = 3 and (select last_action from consent_status) = 'accepted',
                  '철회·재동의는 새 줄로 쌓이고 마지막 상태가 보임');

set request.jwt.claim.sub = 'bbbbbbbb-0000-0000-0000-000000000009';
select pg_temp.ok((select count(*) from consent_status) = 1 and (select count(*) from consent_events) = 4, '운영자는 학생별 동의 현황·이력을 봄');
select pg_temp.expect_error($$select consent_record('cccccccc-0000-0000-0000-0000000000a1', 'withdrawn')$$, 'check');
select pg_temp.ok(true, '운영자가 철회를 대신 기록할 때는 사유가 필요');
reset request.jwt.claim.sub;
reset role;

select pg_temp.expect_error($$update consent_events set action = 'viewed'$$, '수정할 수 없습니다');
select pg_temp.expect_error($$delete from consent_events$$, '삭제할 수 없습니다');
select pg_temp.ok(true, '동의 기록은 고치거나 지울 수 없음');
select pg_temp.ok(not exists (
  select 1 from pg_constraint c
  where c.contype = 'f' and c.conrelid in ('lessons'::regclass, 'enrollments'::regclass, 'change_requests'::regclass)
    and c.confrelid in ('consent_requests'::regclass, 'consent_events'::regclass, 'terms_documents'::regclass)
), '동의 여부가 수업·등록·변경 신청을 막는 연결이 없음');

-- =====================================================================
-- 정책 원본 v1.0 (migration 500): 적용 기준·결제 시각·적립금·운영 업무·장기 연기
-- =====================================================================
insert into students (id, name_ko, name_en, timezone) values
  ('99999999-0000-0000-0000-000000000001', '테스트사', 'Test Four', 'Asia/Seoul'),
  ('99999999-0000-0000-0000-000000000002', '테스트오', 'Test Five', 'Asia/Seoul'),
  ('99999999-0000-0000-0000-000000000003', '테스트육', 'Test Six', 'Asia/Seoul');
select pg_temp.ok((select policy_basis from enrollments where id = '55555555-5555-5555-5555-555555555555') = 'legacy',
                  '기존 등록은 기본 legacy — 새 정책을 자동 적용하지 않음');

-- 신규 24주 등록 (정책 원본 적용) · 4주 legacy 등록
insert into enrollments (id, student_id, seq, weeks, weekly_count, duration_min, start_date, base_end_date, lessons_purchased, status, policy_basis)
values ('99999999-1000-0000-0000-000000000001', '99999999-0000-0000-0000-000000000001', 1, 24, 2, 50, '2026-11-02', '2027-04-18', 48, 'confirmed', 'policy_v1'),
       ('99999999-1000-0000-0000-000000000002', '99999999-0000-0000-0000-000000000002', 1, 4, 2, 50, '2026-11-02', '2026-11-29', 8, 'confirmed', 'legacy');

-- ---------- 결제 시각 ----------
select pg_temp.expect_error($$insert into payments (enrollment_id, method, amount_received, received_on, confirmed_by)
  values ('99999999-1000-0000-0000-000000000001', 'bank_transfer', 100000, '2026-10-20', 'aaaaaaaa-0000-0000-0000-000000000001')$$, 'not-null|23502');
select pg_temp.ok(true, '실제 결제 완료 시각(paid_at) 없이 결제 기록 불가');
select pg_temp.expect_error($$insert into payments (enrollment_id, method, amount_received, received_on, paid_at, confirmed_by)
  values ('99999999-1000-0000-0000-000000000001', 'bank_transfer', 100000, '2026-10-21', '2026-10-20 14:59:00+00', 'aaaaaaaa-0000-0000-0000-000000000001')$$, 'check');
select pg_temp.ok(true, '입금일(received_on)은 실제 결제 시각의 한국 날짜와 같아야 함 (UTC 14:59 = KST 23:59 → 10/20)');

-- ---------- 신규 매칭 업무: 결제 확인 즉시 생성, 3영업일 ----------
insert into holidays (day, name, kind) values ('2026-10-22', '테스트 임시공휴일', 'temporary');
select pg_temp.expect_error($$insert into holidays (day, name, kind) values ('2026-10-23', '회사 행사', 'company')$$, 'check');
select pg_temp.ok(true, '공휴일은 법정·대체·임시만 (운영자 임의 휴일 종류 없음)');
select pg_temp.ok(add_business_days('2026-10-16', 3) = '2026-10-21', '영업일: 금 → 다음 주 수 (주말 제외)');
select pg_temp.ok(add_business_days('2026-10-20', 3) = '2026-10-26', '영업일: 공휴일(10/22) 제외');

insert into payments (id, enrollment_id, method, amount_received, received_on, paid_at, confirmed_by, confirmed_at, external_ref)
values ('99999999-2000-0000-0000-000000000001', '99999999-1000-0000-0000-000000000001', 'card_link', 1000000, '2026-10-16',
        '2026-10-16 03:00+00', 'aaaaaaaa-0000-0000-0000-000000000001', '2026-10-16 05:00+00', 'IMWEB-TEST-1');
select pg_temp.ok((select count(*) from admin_tasks where enrollment_id = '99999999-1000-0000-0000-000000000001' and kind = 'new_student_matching') = 1,
                  '신규 학생 결제 확인 → 매칭 대기 업무 자동 생성');
select pg_temp.ok((select due_at from admin_tasks where kind = 'new_student_matching' and enrollment_id = '99999999-1000-0000-0000-000000000001')
                  = '2026-10-21 23:59:59.999999+09', '매칭 기한 = 3영업일째 23:59 KST (10/16 금 확인 → 10/21 수)');
select pg_temp.expect_error($$insert into payments (enrollment_id, method, amount_received, received_on, paid_at, confirmed_by, external_ref)
  values ('99999999-1000-0000-0000-000000000001', 'card_link', 1000000, '2026-10-16', '2026-10-16 03:00+00', 'aaaaaaaa-0000-0000-0000-000000000001', 'IMWEB-TEST-1')$$, 'unique|23505');
select pg_temp.ok(true, '같은 주문번호 결제를 두 번 기록할 수 없음');
insert into payments (enrollment_id, method, amount_received, received_on, paid_at, confirmed_by)
values ('99999999-1000-0000-0000-000000000001', 'bank_transfer', 10000, '2026-10-17', '2026-10-17 01:00+00', 'aaaaaaaa-0000-0000-0000-000000000001');
select pg_temp.ok((select count(*) from admin_tasks where enrollment_id = '99999999-1000-0000-0000-000000000001') = 1, '나눠 낸 두 번째 결제로 업무가 중복 생성되지 않음');

select pg_temp.expect_error($$update admin_tasks set status = 'done', done_at = now() where kind = 'new_student_matching' and enrollment_id = '99999999-1000-0000-0000-000000000001'$$, 'check');
update admin_tasks set tutor_id = '11111111-1111-1111-1111-111111111111', tutor_assigned_at = now()
  where kind = 'new_student_matching' and enrollment_id = '99999999-1000-0000-0000-000000000001';
select pg_temp.expect_error($$update admin_tasks set status = 'done', done_at = now() where kind = 'new_student_matching' and enrollment_id = '99999999-1000-0000-0000-000000000001'$$, 'check');
select pg_temp.ok((select missing_steps = array['notify_tutor', 'notify_student'] from admin_task_board where enrollment_id = '99999999-1000-0000-0000-000000000001'),
                  '강사만 배정하고 양쪽 최종 안내 전이면 업무가 남아 있고 남은 단계가 보임');
select pg_temp.expect_error($$update admin_tasks set student_notified_at = now(), status = 'done', done_at = now()
  where kind = 'new_student_matching' and enrollment_id = '99999999-1000-0000-0000-000000000001'$$, 'check');
update admin_tasks set student_notified_at = now(), tutor_notified_at = now(), status = 'done', done_at = now()
  where kind = 'new_student_matching' and enrollment_id = '99999999-1000-0000-0000-000000000001';
select pg_temp.ok(not exists (select 1 from admin_task_board where enrollment_id = '99999999-1000-0000-0000-000000000001'),
                  '강사 배정 + 학생·강사 양쪽 최종 안내를 모두 마쳐야 매칭 업무 완료 (H22)');
select pg_temp.expect_error($$delete from admin_tasks$$, '삭제할 수 없습니다');
select pg_temp.ok(true, '운영 업무는 지울 수 없음 (취소는 사유와 함께)');

-- 기한 표시
insert into enrollments (id, student_id, seq, weeks, weekly_count, duration_min, start_date, base_end_date, lessons_purchased, status)
values ('99999999-1000-0000-0000-000000000003', '99999999-0000-0000-0000-000000000003', 1, 4, 2, 50, '2026-01-05', '2026-02-01', 8, 'completed');
insert into payments (enrollment_id, method, amount_received, received_on, paid_at, confirmed_by, confirmed_at)
values ('99999999-1000-0000-0000-000000000003', 'bank_transfer', 100000, '2026-01-02', '2026-01-02 01:00+00', 'aaaaaaaa-0000-0000-0000-000000000001', '2026-01-02 01:00+00');
select pg_temp.ok((select urgency from admin_task_board where enrollment_id = '99999999-1000-0000-0000-000000000003') = 'overdue', '기한이 지난 매칭 업무는 기한 초과로 표시');

-- ---------- 재등록 강사 통보: 강사 확인 + 일정 조치까지 ----------
insert into regular_schedules (student_id, tutor_id, weekday, start_time_kst, duration_min, effective_from)
values ('99999999-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 1, '20:00', 50, '2026-11-02');
insert into enrollments (id, student_id, seq, previous_enrollment_id, weeks, weekly_count, duration_min, start_date, base_end_date, lessons_purchased, status, policy_basis)
values ('99999999-1000-0000-0000-000000000004', '99999999-0000-0000-0000-000000000001', 2, '99999999-1000-0000-0000-000000000001',
        4, 2, 50, '2027-04-19', '2027-05-16', 8, 'confirmed', 'policy_v1');
insert into payments (id, enrollment_id, method, amount_received, received_on, paid_at, confirmed_by)
values ('99999999-2000-0000-0000-000000000004', '99999999-1000-0000-0000-000000000004', 'bank_transfer', 100000, '2027-04-10', '2027-04-10 01:00+00', 'aaaaaaaa-0000-0000-0000-000000000001');
select pg_temp.ok((select tutor_id = '11111111-1111-1111-1111-111111111111' from admin_tasks where kind = 'renewal_tutor_notice' and enrollment_id = '99999999-1000-0000-0000-000000000004'),
                  '재등록 결제 확인 → 담당 강사 통보 업무 자동 생성 (현재 고정 스케줄의 강사)');
update admin_tasks set tutor_notified_at = now() where kind = 'renewal_tutor_notice' and enrollment_id = '99999999-1000-0000-0000-000000000004';
select pg_temp.expect_error($$update admin_tasks set status = 'done', done_at = now() where kind = 'renewal_tutor_notice' and enrollment_id = '99999999-1000-0000-0000-000000000004'$$, 'check');
select pg_temp.ok(true, '통보 발송만으로는 완료 불가 — 강사 확인·일정 조치 필요');

-- ---------- 보상 적립금 ----------
insert into lessons (id, enrollment_id, student_id, tutor_id, kind, seq, starts_at, ends_at, state, canceled_at, class_status)
values ('99999999-3000-0000-0000-000000000001', '99999999-1000-0000-0000-000000000001', '99999999-0000-0000-0000-000000000001',
        '22222222-2222-2222-2222-222222222222', 'regular', 1, '2026-11-02 11:00+00', '2026-11-02 11:50+00', 'canceled', '2026-11-02 08:00+00', 'Tutor canceled late'),
       ('99999999-3000-0000-0000-000000000002', '99999999-1000-0000-0000-000000000001', '99999999-0000-0000-0000-000000000001',
        '22222222-2222-2222-2222-222222222222', 'regular', 2, '2026-11-04 11:00+00', '2026-11-04 11:50+00', 'canceled', '2026-11-03 08:00+00', 'Tutor canceled in advance'),
       ('99999999-3000-0000-0000-000000000003', '99999999-1000-0000-0000-000000000002', '99999999-0000-0000-0000-000000000002',
        '22222222-2222-2222-2222-222222222222', 'regular', 1, '2026-11-02 13:00+00', '2026-11-02 13:50+00', 'canceled', '2026-11-02 10:00+00', 'Tutor canceled late');
insert into change_requests (id, lesson_id, type, status, via) values
  ('cccccccc-3000-0000-0000-000000000001', '99999999-3000-0000-0000-000000000001', 'tutor_cancel', 'applied', 'admin_app'),
  ('cccccccc-3000-0000-0000-000000000002', '99999999-3000-0000-0000-000000000002', 'tutor_cancel', 'applied', 'admin_app'),
  ('cccccccc-3000-0000-0000-000000000003', '99999999-3000-0000-0000-000000000003', 'tutor_cancel', 'applied', 'admin_app');
insert into reward_ledger (student_id, kind, amount, lesson_id, change_request_id) values ('99999999-0000-0000-0000-000000000001', 'grant_tutor_late_cancel', 2000, '99999999-3000-0000-0000-000000000001', 'cccccccc-3000-0000-0000-000000000001');
select pg_temp.expect_error($$insert into reward_ledger (student_id, kind, amount, lesson_id, change_request_id) values ('99999999-0000-0000-0000-000000000001', 'grant_tutor_late_cancel', 2000, '99999999-3000-0000-0000-000000000001', 'cccccccc-3000-0000-0000-000000000001')$$, 'unique|23505');
select pg_temp.expect_error($$insert into reward_ledger (student_id, kind, amount, lesson_id) values ('99999999-0000-0000-0000-000000000001', 'grant_tutor_late_cancel', 2000, '99999999-3000-0000-0000-000000000001')$$, 'reward_ledger_request_required');
select pg_temp.ok(true, '같은 강사 늦은 취소(요청 1건)에 적립금 중복 지급 불가');
select pg_temp.expect_error($$insert into reward_ledger (student_id, kind, amount, lesson_id, change_request_id) values ('99999999-0000-0000-0000-000000000001', 'grant_tutor_late_cancel', 2000, '99999999-3000-0000-0000-000000000002', 'cccccccc-3000-0000-0000-000000000002')$$, '6시간 미만');
select pg_temp.ok(true, '6시간 이상 전 강사 취소에는 적립금 없음 (보강만)');
insert into reward_ledger (student_id, kind, amount, lesson_id, change_request_id) values ('99999999-0000-0000-0000-000000000002', 'grant_tutor_late_cancel', 2000, '99999999-3000-0000-0000-000000000003', 'cccccccc-3000-0000-0000-000000000003');
select pg_temp.ok(reward_balance('99999999-0000-0000-0000-000000000002') = 2000, '기존(legacy) 등록 학생도 강사 늦은 취소 적립금 받음 (유리한 규칙, POL-OP-17)');
select pg_temp.expect_error($$insert into reward_ledger (student_id, kind, amount) values ('99999999-0000-0000-0000-000000000002', 'grant_admin', 2000)$$, 'check');
select pg_temp.ok(true, '운영자 수동 지급은 사유 필수');
select pg_temp.ok(reward_balance('99999999-0000-0000-0000-000000000001') = 2000, '적립금 잔액 2,000원');

-- 사용: 예약 → 확정 / 복구
select pg_temp.expect_error($$insert into reward_redemptions (student_id, enrollment_id, amount, method) values ('99999999-0000-0000-0000-000000000001', '99999999-1000-0000-0000-000000000004', 3000, 'bank_transfer')$$, '잔액이 부족');
select pg_temp.ok(true, '잔액보다 많이 쓸 수 없음');
insert into reward_redemptions (id, student_id, enrollment_id, amount, method)
values ('99999999-4000-0000-0000-000000000001', '99999999-0000-0000-0000-000000000001', '99999999-1000-0000-0000-000000000004', 2000, 'bank_transfer');
select pg_temp.ok(reward_balance('99999999-0000-0000-0000-000000000001') = 0, '사용 예약하면 잔액에서 바로 빠짐 (이중 사용 방지)');
select pg_temp.expect_error($$insert into reward_redemptions (student_id, enrollment_id, amount, method) values ('99999999-0000-0000-0000-000000000001', '99999999-1000-0000-0000-000000000004', 1, 'bank_transfer')$$, 'unique|23505|잔액');
select pg_temp.ok(true, '한 등록에 진행 중인 적립금 사용은 하나만');
select pg_temp.expect_error($$update reward_redemptions set status = 'confirmed', payment_id = '99999999-2000-0000-0000-000000000001' where id = '99999999-4000-0000-0000-000000000001'$$, '이 등록의 결제');
select pg_temp.ok(true, '다른 등록의 결제로는 확정 불가');
update reward_redemptions set status = 'confirmed', payment_id = '99999999-2000-0000-0000-000000000004' where id = '99999999-4000-0000-0000-000000000001';
select pg_temp.expect_error($$update reward_redemptions set status = 'released', note = '실수' where id = '99999999-4000-0000-0000-000000000001'$$, '바꿀 수 없습니다');
select pg_temp.ok(true, '확정된 사용은 예약 취소로 되돌릴 수 없음 (환불 복구만)');
update reward_redemptions set status = 'restored', note = '결제 환불' where id = '99999999-4000-0000-0000-000000000001';
select pg_temp.ok(reward_balance('99999999-0000-0000-0000-000000000001') = 2000, '확정 후 결제 환불 → 적립금 복구');
select pg_temp.expect_error($$update reward_redemptions set status = 'restored', note = '두 번' where id = '99999999-4000-0000-0000-000000000001'$$, '바꿀 수 없습니다');
select pg_temp.ok(reward_balance('99999999-0000-0000-0000-000000000001') = 2000, '복구는 한 번만');
select pg_temp.expect_error($$delete from reward_ledger$$, '삭제할 수 없습니다');
select pg_temp.ok(true, '적립금 원장은 지울 수 없음');

-- ---------- 보상 수업 기한 (4100: 7일 폐지) ----------
insert into lessons (id, enrollment_id, student_id, tutor_id, kind, seq, starts_at, ends_at, state, class_status)
values ('99999999-3000-0000-0000-000000000004', '99999999-1000-0000-0000-000000000001', '99999999-0000-0000-0000-000000000001',
        '22222222-2222-2222-2222-222222222222', 'regular', 3, '2026-11-09 11:00+00', '2026-11-09 11:50+00', 'done', 'Tutor no-show');
insert into compensations (student_id, enrollment_id, source_lesson_id, reason, confirmed_by, created_at)
values ('99999999-0000-0000-0000-000000000001', '99999999-1000-0000-0000-000000000001', '99999999-3000-0000-0000-000000000004',
        'tutor_no_show', 'aaaaaaaa-0000-0000-0000-000000000001', '2026-11-09 15:30+00');
select pg_temp.ok((select expires_on is null from compensations where source_lesson_id = '99999999-3000-0000-0000-000000000004'),
                  '보상 수업 7일 기한 없음 — 일반 보강과 같이 수강기간 안 (4100, 2026-11-02 대표)');

-- ---------- 장기 연기 (24주만, 총 14일·2회) ----------
select pg_temp.expect_error($$insert into long_leave_requests (enrollment_id, leave_start, days, reason_kind) values ('99999999-1000-0000-0000-000000000001', '2027-03-01', 10, 'health')$$, 'check');
select pg_temp.ok(true, '연기 기간은 7일 또는 14일만');
insert into long_leave_requests (enrollment_id, leave_start, days, reason_kind) values ('99999999-1000-0000-0000-000000000001', '2026-12-01', 7, 'health');
insert into long_leave_requests (enrollment_id, leave_start, days, reason_kind) values ('99999999-1000-0000-0000-000000000001', '2027-01-04', 7, 'business_trip');
select pg_temp.expect_error($$insert into long_leave_requests (enrollment_id, leave_start, days, reason_kind) values ('99999999-1000-0000-0000-000000000001', '2027-02-01', 7, 'health')$$, '최대 14일');
select pg_temp.ok(true, '장기 연기 3번째·14일 초과 신청은 거부');
select pg_temp.expect_error($$insert into long_leave_requests (enrollment_id, leave_start, days, reason_kind) values ('99999999-1000-0000-0000-000000000002', '2026-11-10', 7, 'health')$$, '정책 원본 적용 등록이 아니');
select pg_temp.ok(true, '기존(legacy) 등록은 자동 접수하지 않음 — 계약 조건 확인 후 운영자 처리');
select pg_temp.expect_error($$insert into long_leave_requests (enrollment_id, leave_start, days, reason_kind) values ('99999999-1000-0000-0000-000000000004', '2027-04-25', 7, 'health')$$, '24주');
select pg_temp.ok(true, '24주가 아닌 등록은 장기 연기 불가');
select pg_temp.expect_error($$update long_leave_requests set status = 'approved' where leave_start = '2026-12-01'$$, 'check');
select pg_temp.ok(true, '승인은 증빙 확인 메모와 연장 기록이 있어야 함');

-- ---------- 권한 ----------
insert into app_users (auth_user_id, role, student_id) values ('bbbbbbbb-0000-0000-0000-000000000011', 'student', '99999999-0000-0000-0000-000000000001');
set role authenticated;
set request.jwt.claim.sub = 'bbbbbbbb-0000-0000-0000-000000000011';
select pg_temp.ok((select count(*) from reward_ledger) > 0 and not exists (select 1 from reward_ledger where student_id <> '99999999-0000-0000-0000-000000000001'),
                  '학생은 본인 적립금 기록만 봄');
select pg_temp.ok((select count(*) from admin_tasks) = 0, '학생은 운영 업무를 볼 수 없음');
select pg_temp.expect_error($$insert into reward_ledger (student_id, kind, amount, note) values ('99999999-0000-0000-0000-000000000001', 'grant_admin', 100000, 'x')$$, 'permission|42501');
select pg_temp.ok(true, '학생이 적립금을 직접 넣을 수 없음');
set request.jwt.claim.sub = 'bbbbbbbb-0000-0000-0000-000000000004';   -- 강사 TestTutorA
select pg_temp.ok((select count(*) from admin_tasks) = 1 and (select kind from admin_tasks limit 1) = 'renewal_tutor_notice',
                  '강사는 본인에게 온 재등록 통보만 봄 (매칭 업무는 안 보임)');
set request.jwt.claim.sub = 'bbbbbbbb-0000-0000-0000-000000000009';
select pg_temp.ok((select count(*) from admin_task_board) >= 2, '운영자는 열린 업무 전체를 봄');
reset request.jwt.claim.sub;
reset role;

-- ---------- Supabase 권한 정리 (migration 600) ----------
set role anon;
select pg_temp.expect_error($$select add_business_days('2026-10-16', 3)$$, 'permission|42501');
select pg_temp.expect_error($$select nextval('student_code_seq')$$, 'permission|42501');
reset role;
select pg_temp.ok(true, '로그인 안 한 사용자는 LMS 함수·학생 번호 시퀀스를 쓸 수 없음');
set role authenticated;
select pg_temp.expect_error($$select nextval('student_code_seq')$$, 'permission|42501');
reset role;
select pg_temp.ok(true, '로그인 사용자도 학생 번호를 직접 만들 수 없음 (서버만)');

-- ---------- 서버 키(service_role) 표 권한 (migration 710, 2026-10-17 5-4 실물 실패 재현) ----------
set role service_role;
insert into app_users (auth_user_id, role, admin_level) values ('cccccccc-0000-0000-0000-000000000710', 'admin', 'staff');
select pg_temp.ok((select count(*) from app_users where auth_user_id = 'cccccccc-0000-0000-0000-000000000710') = 1, '서버 키는 app_users 를 추가·읽기 가능');
delete from app_users where auth_user_id = 'cccccccc-0000-0000-0000-000000000710';
select pg_temp.ok((select count(*) from audit_log where table_name = 'app_users' and row_id = 'cccccccc-0000-0000-0000-000000000710') = 2, '서버 키 쓰기도 변경 이력에 남음 (추가·삭제 2줄)');
select pg_temp.ok((select count(*) from students) >= 2, '서버 키는 학생 표를 읽을 수 있음');
select pg_temp.expect_error($$update audit_log set action = 'INSERT'$$, 'permission|42501');
select pg_temp.expect_error($$delete from audit_log$$, 'permission|42501');
reset role;
select pg_temp.ok(true, '서버 키도 변경 이력을 고치거나 지울 수 없음');

-- ---------- 운영자 TOTP 강제·역할 분리 (migration 800, POL-AC-05·07) ----------
insert into app_users (auth_user_id, role, admin_level) values ('bbbbbbbb-0000-0000-0000-000000000008', 'admin', 'staff');
select pg_temp.expect_error($$insert into app_users (auth_user_id, role) values ('bbbbbbbb-0000-0000-0000-0000000000a8', 'admin')$$, 'check');
select pg_temp.expect_error($$insert into app_users (auth_user_id, role, student_id, admin_level) values ('bbbbbbbb-0000-0000-0000-0000000000a9', 'student', '33333333-3333-3333-3333-333333333333', 'owner')$$, 'check|unique|duplicate');
select pg_temp.ok(true, '운영자는 대표/직원 구분이 반드시 있고, 학생·강사에게는 운영자 등급을 줄 수 없음');
set role authenticated;
set request.jwt.claim.sub = 'bbbbbbbb-0000-0000-0000-000000000009';   -- 대표
set request.jwt.claims = '{"aal":"aal1"}';
select pg_temp.ok(not is_admin() and not is_owner(), 'TOTP 전(aal1) 대표 세션은 운영자가 아님');
select pg_temp.ok(my_role() = 'admin', 'TOTP 전에도 본인 역할(admin)은 알 수 있음 → 로그인 화면이 인증 앱 코드를 물음 (migration 820)');
select pg_temp.ok((select count(*) from students) = 0 and (select count(*) from payments) = 0 and (select count(*) from audit_log) = 0,
                  'TOTP 전 운영자 세션은 학생·결제·변경 이력을 한 줄도 못 봄');
set request.jwt.claims = '{}';
select pg_temp.ok(not is_admin() and (select count(*) from students) = 0, 'aal 정보가 없는 세션도 운영자가 아님');
set request.jwt.claims = '{"aal":"aal2"}';
select pg_temp.ok(is_admin() and is_owner() and (select count(*) from students) >= 2, 'TOTP 완료(aal2) 대표 세션은 운영자·대표 권한');
set request.jwt.claim.sub = 'bbbbbbbb-0000-0000-0000-000000000008';   -- 운영직원
select pg_temp.ok(is_admin() and not is_owner(), 'TOTP 완료 직원은 운영자지만 대표 전용 권한은 없음');
set request.jwt.claim.sub = 'bbbbbbbb-0000-0000-0000-000000000001';   -- 학생 (aal2여도)
select pg_temp.ok(not is_admin() and not is_owner(), '학생은 aal2 여도 운영자가 아님');
select pg_temp.expect_error($$update app_users set admin_level = 'owner' where auth_user_id = 'bbbbbbbb-0000-0000-0000-000000000008'$$, 'permission|42501');
reset request.jwt.claim.sub;
reset role;
select pg_temp.ok(true, '앱 사용자는 운영자 등급을 바꿀 수 없음 (서버만)');

set role authenticated;
set request.jwt.claim.sub = 'bbbbbbbb-0000-0000-0000-000000000001';
select pg_temp.ok(my_role() = 'student', '학생 본인 역할 = student');
set request.jwt.claim.sub = 'bbbbbbbb-0000-0000-0000-0000000000ff';
select pg_temp.ok(my_role() is null, '연결 안 된 계정의 역할은 없음');
reset request.jwt.claim.sub;
reset role;
set role anon;
select pg_temp.expect_error($$select my_role()$$, 'permission|42501');
reset role;
select pg_temp.ok(true, '로그인 안 한 요청은 my_role 을 부를 수 없음');

-- ---------- 신규 학생 등록 저장 함수 (migration 900, POL-OP-13·21, POL-AC-04·07) ----------
insert into tutors (id, name, country, timezone) values ('55555555-0000-0000-0000-000000000900', 'TestTutorReg', 'Korea', 'Asia/Seoul');
create or replace function pg_temp.reg(rid text, body jsonb) returns jsonb
language sql as $$ select admin_register_student(rid::uuid, body) $$;
-- 충돌 오류의 상세(JSON) 꺼내기
create or replace function pg_temp.reg_conflicts(rid text, body jsonb) returns jsonb
language plpgsql as $$
declare det text; h text;
begin
  perform admin_register_student(rid::uuid, body);
  raise exception '실패: 충돌이 나야 하는데 저장됨';
exception when sqlstate 'P0001' then
  get stacked diagnostics det = pg_exception_detail, h = pg_exception_hint;
  if h is distinct from 'schedule_conflict' then raise; end if;
  return det::jsonb;
end $$;
create or replace function pg_temp.body(name text, email text, weeks int, weekly int, dur int, start date, tutor uuid, slots jsonb, paid boolean) returns jsonb
language sql as $$
  select jsonb_build_object(
    'student', jsonb_build_object('name_ko', name, 'name_en', 'Reg ' || name, 'email', email, 'timezone', 'Asia/Seoul'),
    'course', jsonb_build_object('weeks', weeks, 'weekly_count', weekly, 'duration_min', dur, 'start_date', start, 'amount_due', 100000),
    'tutor_id', tutor, 'slots', slots, 'tutor_answer', 'accepted',   -- 강사가 이미 가능하다고 답함 → 저장과 확정을 한 번에 (migration 1000)
    'payment', case when paid then jsonb_build_object('method', 'bank_transfer', 'amount', 100000, 'paid_at', ((start - 7) + time '14:22') at time zone 'Asia/Seoul', 'payer_name', name) end)
$$;

set role anon;
select pg_temp.expect_error($$select admin_register_student(gen_random_uuid(), '{}'::jsonb)$$, 'permission|42501');
reset role;
set role authenticated;
set request.jwt.claims = '{"aal":"aal2"}';
set request.jwt.claim.sub = 'bbbbbbbb-0000-0000-0000-000000000001';   -- 학생
select pg_temp.expect_error($$select admin_register_student(gen_random_uuid(), '{}'::jsonb)$$, '42501');
set request.jwt.claim.sub = 'bbbbbbbb-0000-0000-0000-000000000009';   -- 대표
set request.jwt.claims = '{"aal":"aal1"}';
select pg_temp.expect_error($$select admin_register_student(gen_random_uuid(), '{}'::jsonb)$$, '42501');
set request.jwt.claims = '{"aal":"aal2"}';
select pg_temp.ok(true, '등록 함수: 로그인 안 함·학생·TOTP 전 운영자는 부를 수 없음');
select pg_temp.expect_error($$insert into students (name_ko, name_en) values ('직접', 'Direct')$$, 'permission|42501');
select pg_temp.ok(true, '운영자도 학생 표에 직접 쓰지 못함 — 등록 함수로만');

select pg_temp.expect_error($$select pg_temp.reg('90000000-0000-0000-0000-000000000001',
  pg_temp.body('미결제강사', 'a@x.kr', 4, 1, 50, '2027-03-02', '55555555-0000-0000-0000-000000000900', '[{"weekday":2,"time":"20:00"}]', false))$$, 'POL-OP-13');
select pg_temp.ok(true, '결제 확인 전에는 강사·정규 일정 확정 불가');

select pg_temp.ok((pg_temp.reg('90000000-0000-0000-0000-000000000002',
  pg_temp.body('결제대기', 'wait@x.kr', 4, 2, 50, '2027-03-01', null, '[]', false)) ->> 'status') = 'pending_payment',
  '결제 확인 전 등록 = 학생·수강권(결제 대기)만');

select pg_temp.ok((pg_temp.reg('90000000-0000-0000-0000-000000000003',
  pg_temp.body('정규일', 'one@x.kr', 4, 2, 50, '2027-03-02', '55555555-0000-0000-0000-000000000900', '[{"weekday":2,"time":"20:00"},{"weekday":4,"time":"20:00"}]', true)) ->> 'lessons')::int = 8,
  '결제 확인 + 강사 + 화·목 20:00 → 정규 8회 생성');
select pg_temp.ok((pg_temp.reg('90000000-0000-0000-0000-000000000003',
  pg_temp.body('정규일', 'one@x.kr', 4, 2, 50, '2027-03-02', '55555555-0000-0000-0000-000000000900', '[{"weekday":2,"time":"20:00"},{"weekday":4,"time":"20:00"}]', true)) ->> 'repeated')::boolean,
  '같은 요청 번호로 다시 저장 → 처음 결과를 돌려줌 (새로 만들지 않음)');
reset role;
select pg_temp.ok((select count(*) from students where email = 'one@x.kr') = 1
              and (select count(*) from lessons l join students s on s.id = l.student_id where s.email = 'one@x.kr') = 8
              and (select count(*) from regular_schedules r join students s on s.id = r.student_id where s.email = 'one@x.kr') = 2,
  '저장 버튼을 두 번 눌러도 학생·정규 일정·수업은 한 벌');
select pg_temp.ok((select t.tutor_assigned_at is not null and t.student_notified_at is null and t.status = 'open'
                   from admin_tasks t join enrollments e on e.id = t.enrollment_id join students s on s.id = e.student_id where s.email = 'one@x.kr'),
  '결제 확인 → 신규 매칭 업무 생성, 강사 배정만 채워지고 학생 안내 전이라 업무는 열려 있음');
select pg_temp.ok((select count(*) from students where email = 'wait@x.kr') = 1
              and not exists (select 1 from admin_tasks t join enrollments e on e.id = t.enrollment_id join students s on s.id = e.student_id where s.email = 'wait@x.kr'),
  '결제 대기 학생은 매칭 업무가 아직 없음');
select pg_temp.ok((select count(*) from audit_log where table_name = 'students' and actor = 'bbbbbbbb-0000-0000-0000-000000000009' and actor_via = 'admin_register_student') >= 2,
  '등록 함수로 만든 행은 변경 이력에 운영자 이름으로 남음');

-- 11/3 예시와 같은 상황: 4/6(화) 21:00 에만 보강이 있음 (20:00 은 one@x.kr 의 정규 → 3/29 종료 뒤엔 재등록 대기로 막히므로 21:00 으로)
insert into lessons (enrollment_id, student_id, tutor_id, kind, makeup_of, starts_at, ends_at)
select l.enrollment_id, l.student_id, l.tutor_id, 'makeup', l.id, '2027-04-06 21:00+09', '2027-04-06 21:50+09'
from lessons l join students s on s.id = l.student_id where s.email = 'one@x.kr' and l.seq = 1;
insert into tutor_time_off (tutor_id, starts_at, ends_at, kind) values ('55555555-0000-0000-0000-000000000900', '2027-05-04 17:00+09', '2027-05-04 19:00+09', 'block');
set role authenticated;
select pg_temp.ok((select jsonb_agg(c ->> 'date' || ' ' || (c ->> 'reason')) from jsonb_array_elements(
  pg_temp.reg_conflicts('90000000-0000-0000-0000-000000000004',
    pg_temp.body('보강충돌', 'mk@x.kr', 4, 1, 50, '2027-04-06', '55555555-0000-0000-0000-000000000900', '[{"weekday":2,"time":"21:00"}]', true))) c)
  = '["2027-04-06 tutor_makeup"]'::jsonb,
  '첫 수업일이 보강 날(4/6)이면 그날 하나만 충돌로 알려 줌');
reset role;
select pg_temp.ok(not exists (select 1 from students where email = 'mk@x.kr') and not exists (select 1 from registration_requests where id = '90000000-0000-0000-0000-000000000004'),
  '충돌이 있으면 학생·수강권·결제·수업 아무것도 저장 안 됨');
set role authenticated;
select pg_temp.ok((pg_temp.reg('90000000-0000-0000-0000-000000000005',
  pg_temp.body('보강다음주', 'mk2@x.kr', 4, 1, 50, '2027-04-13', '55555555-0000-0000-0000-000000000900', '[{"weekday":2,"time":"21:00"}]', true)) ->> 'lessons')::int = 4,
  '같은 화 21:00 이라도 보강 다음 주(4/13)부터는 등록 가능 — 보강이 정규 시간을 영구히 막지 않음');
select pg_temp.ok((select jsonb_agg(c ->> 'reason') from jsonb_array_elements(
  pg_temp.reg_conflicts('90000000-0000-0000-0000-000000000006',
    pg_temp.body('휴식부족', 'br@x.kr', 4, 1, 20, '2027-03-04', '55555555-0000-0000-0000-000000000900', '[{"weekday":4,"time":"20:55"}]', true))) c)
  = '["break","break","break","break"]'::jsonb,
  '50분 수업(20:00) 뒤 20:55 시작은 휴식 10분 부족 — 기간 4회 모두 표시');
select pg_temp.ok((pg_temp.reg('90000000-0000-0000-0000-000000000007',
  pg_temp.body('휴식딱', 'br2@x.kr', 4, 1, 40, '2027-03-04', '55555555-0000-0000-0000-000000000900', '[{"weekday":4,"time":"21:00"}]', true)) ->> 'lessons')::int = 4,
  '20:50 에 끝나는 수업 뒤 21:00 시작은 가능 (휴식 정확히 10분)');
select pg_temp.ok((select jsonb_agg(c ->> 'date' || ' ' || (c ->> 'reason')) from jsonb_array_elements(
  pg_temp.reg_conflicts('90000000-0000-0000-0000-000000000008',
    pg_temp.body('휴무충돌', 'off@x.kr', 4, 1, 50, '2027-04-27', '55555555-0000-0000-0000-000000000900', '[{"weekday":2,"time":"18:00"}]', true))) c)
  = '["2027-05-04 tutor_time_off"]'::jsonb,
  '기간 중 강사 휴무 날짜(5/4)를 찾아 알려 줌');
select pg_temp.expect_error($$select pg_temp.reg('90000000-0000-0000-0000-000000000009',
  pg_temp.body('시작요일', 's@x.kr', 4, 1, 50, '2027-03-03', '55555555-0000-0000-0000-000000000900', '[{"weekday":2,"time":"18:00"}]', true))$$, '첫 정규 수업일');
select pg_temp.ok(true, '수강 시작일 요일이 정규 요일에 없으면 거절');
select pg_temp.ok((select count(*) from admin_students_with_email('ONE@x.kr')) = 1, '같은 이메일 학생이 있으면 알려 줌 (연결·병합은 하지 않음)');
set request.jwt.claim.sub = 'bbbbbbbb-0000-0000-0000-000000000001';
select pg_temp.ok((select count(*) from admin_students_with_email('one@x.kr')) = 0, '운영자가 아니면 이메일 확인 결과 0건');
reset request.jwt.claim.sub;
reset role;

-- ---------- 회차별 수업 날짜 (migration 20261106000000, 정책 원본 H26(60)·(61)) ----------
insert into tutors (id, name, country, timezone) values ('55555555-0000-0000-0000-000000000901', 'TestTutorLessons', 'Korea', 'Asia/Seoul');
create or replace function pg_temp.ldates(mail text) returns text
language sql as $$
  select string_agg(l.seq || '=' || to_char(l.starts_at at time zone 'Asia/Seoul', 'MM-DD HH24:MI'), ' ' order by l.seq)
  from lessons l join students s on s.id = l.student_id where s.email = mail and l.kind = 'regular' $$;
create or replace function pg_temp.eid(mail text) returns uuid
language sql as $$ select e.id from enrollments e join students s on s.id = e.student_id where s.email = mail $$;
create or replace function pg_temp.lbody(name text, email text, weekly int, start date, slots jsonb, lessons jsonb) returns jsonb
language sql as $$
  select pg_temp.body(name, email, 4, weekly, 50, start, '55555555-0000-0000-0000-000000000901', slots, true) || jsonb_build_object('lessons', lessons) $$;

set role authenticated;
set request.jwt.claim.sub = 'bbbbbbbb-0000-0000-0000-000000000009';   -- 대표 (aal2)
-- 화·목 19:00 주 2회·4주인데 첫 수업은 금요일(3/5), 3회차만 목 3/11 → 금 3/12 로 바꿈 (변경권 없이 등록 때 정함)
select pg_temp.ok((pg_temp.reg('90000000-0000-0000-0000-000000002001',
  pg_temp.lbody('목록일', 'ld1@x.kr', 2, '2027-03-05', '[{"weekday":2,"time":"19:00"},{"weekday":4,"time":"19:00"}]',
    '[{"date":"2027-03-05","time":"19:00"},{"date":"2027-03-09","time":"19:00"},{"date":"2027-03-12","time":"19:00"},{"date":"2027-03-16","time":"19:00"},
      {"date":"2027-03-18","time":"19:00"},{"date":"2027-03-23","time":"19:00"},{"date":"2027-03-25","time":"19:00"},{"date":"2027-03-30","time":"19:00"}]')) ->> 'lessons')::int = 8,
  '회차 목록으로 등록 = 정규 요일이 아닌 첫 수업일·바꾼 회차를 그대로 8회 생성');
select pg_temp.ok(pg_temp.ldates('ld1@x.kr') = '1=03-05 19:00 2=03-09 19:00 3=03-12 19:00 4=03-16 19:00 5=03-18 19:00 6=03-23 19:00 7=03-25 19:00 8=03-30 19:00',
  '생성된 수업 날짜·시각이 목록과 같고 회차 번호는 날짜순');
reset role;
select pg_temp.ok((select e.start_date = '2027-03-05' and e.base_end_date = '2027-04-01' and e.lessons_purchased = 8
                   from enrollments e where e.id = pg_temp.eid('ld1@x.kr')),
  '수강 기간은 실제 첫 수업일(3/5)부터 28일 (~4/1)');
select pg_temp.ok((select count(*) from regular_schedules r join students s on s.id = r.student_id where s.email = 'ld1@x.kr') = 2
              and (select lesson_dates is not null from schedule_plans where enrollment_id = pg_temp.eid('ld1@x.kr') and state = 'confirmed'),
  '정규 요일(화·목)은 그대로 기록되고, 일정안에는 회차 목록이 남음');
set role authenticated;
select pg_temp.ok((pg_temp.reg('90000000-0000-0000-0000-000000002001',
  pg_temp.lbody('목록일', 'ld1@x.kr', 2, '2027-03-05', '[{"weekday":2,"time":"19:00"},{"weekday":4,"time":"19:00"}]', '[]')) ->> 'repeated')::boolean,
  '같은 요청 번호로 다시 저장 → 처음 결과 (새로 만들지 않음)');
select pg_temp.expect_error($$select pg_temp.reg('90000000-0000-0000-0000-000000002002',
  pg_temp.lbody('개수', 'ld2@x.kr', 2, '2027-03-05', '[{"weekday":2,"time":"19:00"},{"weekday":4,"time":"19:00"}]',
    '[{"date":"2027-03-05","time":"19:00"},{"date":"2027-03-09","time":"19:00"}]'))$$, '수업 날짜 수');
select pg_temp.ok(true, '회차 수가 등록 회차(8)와 다르면 거절');
select pg_temp.expect_error($$select pg_temp.reg('90000000-0000-0000-0000-000000002003',
  pg_temp.lbody('같은날', 'ld3@x.kr', 1, '2027-03-02', '[{"weekday":2,"time":"21:00"}]',
    '[{"date":"2027-03-02","time":"21:00"},{"date":"2027-03-02","time":"21:00"},{"date":"2027-03-16","time":"21:00"},{"date":"2027-03-23","time":"21:00"}]'))$$, '같은 날');
select pg_temp.ok(true, '같은 날 수업 둘이면 거절');
select pg_temp.expect_error($$select pg_temp.reg('90000000-0000-0000-0000-000000002004',
  pg_temp.lbody('첫날다름', 'ld4@x.kr', 1, '2027-03-02', '[{"weekday":2,"time":"21:00"}]',
    '[{"date":"2027-03-03","time":"21:00"},{"date":"2027-03-09","time":"21:00"},{"date":"2027-03-16","time":"21:00"},{"date":"2027-03-23","time":"21:00"}]'))$$, '첫 수업일');
select pg_temp.ok(true, '첫 수업일과 목록의 첫 날짜가 다르면 거절');
select pg_temp.expect_error($$select pg_temp.reg('90000000-0000-0000-0000-000000002005',
  pg_temp.lbody('기간밖', 'ld5@x.kr', 1, '2027-03-02', '[{"weekday":2,"time":"21:00"}]',
    '[{"date":"2027-03-02","time":"21:00"},{"date":"2027-03-09","time":"21:00"},{"date":"2027-03-16","time":"21:00"},{"date":"2027-03-30","time":"21:00"}]'))$$, '수강 기간');
select pg_temp.ok(true, '수강 기간(3/2~3/29) 밖 날짜(3/30)가 있으면 거절');
-- 바꾼 회차도 다른 학생 수업과의 충돌을 그대로 검사: ld1 의 3회차(금 3/12 19:00)와 겹침
select pg_temp.ok((select jsonb_agg(c ->> 'date' || ' ' || (c ->> 'reason')) from jsonb_array_elements(
  pg_temp.reg_conflicts('90000000-0000-0000-0000-000000002006',
    pg_temp.lbody('겹침', 'ld6@x.kr', 1, '2027-03-12', '[{"weekday":5,"time":"19:00"}]',
      '[{"date":"2027-03-12","time":"19:00"},{"date":"2027-03-19","time":"19:00"},{"date":"2027-03-26","time":"19:00"},{"date":"2027-04-02","time":"19:00"}]'))) c)
  = '["2027-03-12 tutor_regular"]'::jsonb,
  '바꾼 회차(3/12)가 다른 학생 수업과 겹치면 그 날짜만 충돌로 알려 줌');
reset role;
select pg_temp.ok(not exists (select 1 from students where email in ('ld2@x.kr', 'ld3@x.kr', 'ld4@x.kr', 'ld5@x.kr', 'ld6@x.kr')),
  '거절·충돌이면 학생·수강권·수업 아무것도 저장 안 됨');
-- 강사 답 전(제안) → 확정: 목록이 일정안에 저장되고 확정 때 그 목록 그대로 수업이 만들어짐
set role authenticated;
select pg_temp.ok((select r ->> 'plan_state' = 'proposed' and (r ->> 'lessons')::int = 0
                   from pg_temp.reg('90000000-0000-0000-0000-000000002007',
                     pg_temp.lbody('제안목록', 'ld7@x.kr', 1, '2027-03-01', '[{"weekday":1,"time":"21:00"}]',
                       '[{"date":"2027-03-01","time":"21:00"},{"date":"2027-03-08","time":"21:00"},{"date":"2027-03-16","time":"21:00"},{"date":"2027-03-22","time":"21:00"}]') - 'tutor_answer') r),
  '강사 답 전 = 제안만 저장 (목록 포함), 수업 0회');
select admin_confirm_schedule((select id from schedule_plans where enrollment_id = pg_temp.eid('ld7@x.kr')));
select pg_temp.ok(pg_temp.ldates('ld7@x.kr') = '1=03-01 21:00 2=03-08 21:00 3=03-16 21:00 4=03-22 21:00',
  '확정하면 일정안의 회차 목록 그대로 수업 생성 (3회차는 화 3/16)');
reset role;

-- ---------- 첫 수업 시작 전 개별 수업 날짜 변경 — 변경권 차감 없음 (migration 20261106010000, H26(62)) ----------
insert into tutor_availability (tutor_id, weekday, start_local, end_local, timezone, effective_from)
select '55555555-0000-0000-0000-000000000901', wd, '06:00', '22:30', 'Asia/Seoul', '2026-01-01' from generate_series(0, 6) wd;
insert into tutor_time_off (tutor_id, starts_at, ends_at, kind) values ('55555555-0000-0000-0000-000000000901', '2027-03-29 00:00+09', '2027-03-30 00:00+09', 'leave');
create or replace function pg_temp.lid(mail text, d text) returns uuid
language sql as $$ select l.id from lessons l join students s on s.id = l.student_id
                   where s.email = mail and to_char(l.starts_at at time zone 'Asia/Seoul', 'YYYY-MM-DD') = d $$;
create or replace function pg_temp.pmove(mail text, d text, to_at text, dry boolean default false) returns jsonb
language sql as $$ select admin_prestart_move(pg_temp.lid(mail, d), to_at::timestamptz, dry) $$;

set role authenticated;
set request.jwt.claim.sub = 'bbbbbbbb-0000-0000-0000-000000000009';   -- 대표 (aal2)
select pg_temp.ok((pg_temp.pmove('ld1@x.kr', '2027-03-09', '2027-03-10 19:00+09', true) ->> 'ok')::boolean
              and pg_temp.ldates('ld1@x.kr') like '%2=03-09 19:00%',
  '시작 전 날짜 변경: 미리 검사만 하면 바뀌지 않음');
select pg_temp.ok((pg_temp.pmove('ld1@x.kr', '2027-03-09', '2027-03-31 19:00+09') ->> 'ok')::boolean,
  '시작 전 날짜 변경: 2회 3/9 → 3/31 저장');
select pg_temp.ok(pg_temp.ldates('ld1@x.kr') = '1=03-05 19:00 2=03-12 19:00 3=03-16 19:00 4=03-18 19:00 5=03-23 19:00 6=03-25 19:00 7=03-30 19:00 8=03-31 19:00',
  '옮긴 뒤 회차 번호는 날짜순으로 다시 매김');
select pg_temp.expect_error($$select pg_temp.pmove('ld1@x.kr', '2027-03-12', '2027-04-02 19:00+09')$$, '수강 기간');
select pg_temp.ok(true, '수강 기간(~4/1) 밖으로는 못 옮김');
select pg_temp.expect_error($$select pg_temp.pmove('ld1@x.kr', '2027-03-12', '2027-03-16 10:00+09')$$, '이 학생 수업');
select pg_temp.ok(true, '그날 이 학생 수업이 이미 있으면 못 옮김');
select pg_temp.expect_error($$select pg_temp.pmove('ld1@x.kr', '2027-03-12', '2027-03-08 20:30+09')$$, '다른 수업');
select pg_temp.ok(true, '강사 다른 수업(ld7 21:00)과 휴식 10분 안이면 못 옮김');
select pg_temp.expect_error($$select pg_temp.pmove('ld1@x.kr', '2027-03-12', '2027-03-29 19:00+09')$$, '휴무');
select pg_temp.expect_error($$select pg_temp.pmove('ld1@x.kr', '2027-03-12', '2027-03-11 23:00+09')$$, '06:00~22:30');
select pg_temp.ok(true, '강사 휴무·현지 06:00~22:30 밖도 못 옮김');
select pg_temp.ok((pg_temp.pmove('ld1@x.kr', '2027-03-12', '2027-03-12 19:30+09') ->> 'ok')::boolean,
  '같은 날 시간만 바꾸기 (자기 원래 시각과는 겹침 검사 안 함)');
-- 첫 수업이 이미 지난 수강권 (지난 날짜로 등록)
select pg_temp.ok((pg_temp.reg('90000000-0000-0000-0000-000000002008',
  pg_temp.body('시작함', 'ld8@x.kr', 4, 1, 50, '2026-10-06', '55555555-0000-0000-0000-000000000901', '[{"weekday":2,"time":"19:00"}]', true)) ->> 'lessons')::int = 4,
  '(준비) 첫 수업이 지난 수강권');
select pg_temp.expect_error($$select pg_temp.pmove('ld8@x.kr', '2026-10-27', '2026-10-28 19:00+09')$$, '이미 시작');
select pg_temp.ok(true, '첫 수업이 이미 시작된 수강권은 이 기능으로 못 바꿈 (변경권 절차로)');
set request.jwt.claim.sub = 'bbbbbbbb-0000-0000-0000-000000000001';   -- 학생
select pg_temp.expect_error($$select pg_temp.pmove('ld1@x.kr', '2027-03-16', '2027-03-17 19:00+09')$$, '42501');
select pg_temp.ok(true, '운영자가 아니면 부를 수 없음');
reset request.jwt.claim.sub;
reset role;
select pg_temp.ok((select count(*) from prestart_moves pm join students s on s.id = pm.student_id where s.email = 'ld1@x.kr') = 2
              and not exists (select 1 from makeup_requests mr join lessons l on l.id = mr.source_lesson_id join students s on s.id = l.student_id where s.email = 'ld1@x.kr')
              and (select count(*) from audit_log where table_name = 'lessons' and actor_via = 'admin_prestart_move') >= 2,
  '기록은 시작 전 변경 2건 + 수업 변경 이력, 보강·변경권 기록 없음');

-- ---------- 신규 배정 확정 관리 (migration 1000, 정책 원본 H22 6번 필수 검증) ----------
insert into tutors (id, name, country, timezone) values ('55555555-0000-0000-0000-000000001000', 'TestTutorConf', 'Korea', 'Asia/Seoul');
create or replace function pg_temp.eid(mail text) returns uuid
language sql as $$ select e.id from enrollments e join students s on s.id = e.student_id where s.email = mail $$;
create or replace function pg_temp.task(mail text) returns admin_tasks
language sql as $$ select t.* from admin_tasks t where t.kind = 'new_student_matching' and t.enrollment_id = pg_temp.eid(mail) $$;
create or replace function pg_temp.notice(mail text, who text) returns schedule_notices
language sql as $$ select n.* from schedule_notices n join schedule_plans p on p.id = n.plan_id
                   where p.enrollment_id = pg_temp.eid(mail) and p.state = 'confirmed' and n.recipient_kind = who $$;
-- 강사 답을 아직 못 받은 등록 = tutor_answer 없음
create or replace function pg_temp.body_wait(name text, email text, start date, slots jsonb) returns jsonb
language sql as $$ select pg_temp.body(name, email, 4, jsonb_array_length(slots), 50, start, '55555555-0000-0000-0000-000000001000', slots, true) - 'tutor_answer' $$;

set role authenticated;
set request.jwt.claim.sub = 'bbbbbbbb-0000-0000-0000-000000000009';   -- 대표 (aal2)

-- 1) 강사 '가능' 답 전: 제안만 저장, 수업·안내 없음
select pg_temp.ok((select r ->> 'plan_state' = 'proposed' and (r ->> 'lessons')::int = 0
                   from pg_temp.reg('90000000-0000-0000-0000-000000001001',
                     pg_temp.body_wait('확정일', 'c1@x.kr', '2027-06-01', '[{"weekday":2,"time":"19:00"},{"weekday":4,"time":"19:00"}]')) r),
  '강사 답 전 등록 = 일정안(제안)만, 수업 0회');
select pg_temp.ok(not exists (select 1 from lessons where enrollment_id = pg_temp.eid('c1@x.kr'))
              and not exists (select 1 from regular_schedules r join students s on s.id = r.student_id where s.email = 'c1@x.kr')
              and not exists (select 1 from schedule_notices n join schedule_plans p on p.id = n.plan_id where p.enrollment_id = pg_temp.eid('c1@x.kr'))
              and (pg_temp.task('c1@x.kr')).tutor_assigned_at is null,
  '강사 가능 답변만으로는 확정되지 않음 — 정규 일정·수업·안내·강사 배정 모두 없음');
select pg_temp.ok((select state = 'proposed' and proposal_sent_at is null from schedule_plan_board where student_code = (select code from students where email = 'c1@x.kr')),
  '답 대기 일정안은 운영자 화면 목록에 보임');

-- 제안 문구 복사 = 제안 보냄 (처음 시각만)
select admin_mark_proposal_sent((select id from schedule_plans where enrollment_id = pg_temp.eid('c1@x.kr')));
select pg_temp.ok(admin_mark_proposal_sent((select id from schedule_plans where enrollment_id = pg_temp.eid('c1@x.kr')))
                  = (select proposal_sent_at from schedule_plans where enrollment_id = pg_temp.eid('c1@x.kr')),
  '제안 문구를 다시 복사해도 처음 보낸 시각 유지');

-- 2) 한 번 확정 → 양쪽 일정과 안내 2건이 함께 생김
select pg_temp.ok((admin_confirm_schedule((select id from schedule_plans where enrollment_id = pg_temp.eid('c1@x.kr'))) ->> 'lessons')::int = 8,
  '운영자가 한 번 확정 → 정규 수업 8회 생성');
select pg_temp.ok((select count(*) from schedule_notices n join schedule_plans p on p.id = n.plan_id where p.enrollment_id = pg_temp.eid('c1@x.kr')) = 2
              and (pg_temp.notice('c1@x.kr', 'student')).status = 'pending' and (pg_temp.notice('c1@x.kr', 'tutor')).status = 'pending'
              and (pg_temp.notice('c1@x.kr', 'tutor')).channel = 'whatsapp_manual' and (pg_temp.notice('c1@x.kr', 'student')).channel = 'kakao_manual'
              and (pg_temp.task('c1@x.kr')).tutor_assigned_at is not null,
  '확정과 동시에 학생·강사 최종 안내 2건(대기) + 강사 배정 기록');
create temp table t_conf as select admin_confirm_schedule((select id from schedule_plans where enrollment_id = pg_temp.eid('c1@x.kr'))) as r;
select pg_temp.ok((select (r ->> 'repeated')::boolean from t_conf)
              and (select count(*) from lessons where enrollment_id = pg_temp.eid('c1@x.kr')) = 8
              and (select count(*) from schedule_notices n join schedule_plans p on p.id = n.plan_id where p.enrollment_id = pg_temp.eid('c1@x.kr')) = 2,
  '확정을 두 번 눌러도 수업·안내는 한 벌');

-- 3) 학생 쪽만 보낸 경우: 완료 아님
select admin_mark_notice_sent((pg_temp.notice('c1@x.kr', 'student')).id);
select pg_temp.ok((pg_temp.task('c1@x.kr')).status = 'open'
              and (select missing_steps = array['notify_tutor'] from admin_task_board where enrollment_id = pg_temp.eid('c1@x.kr'))
              and (select tutor_notice_status = 'pending' and student_notice_status = 'sent' from schedule_plan_board where enrollment_id = pg_temp.eid('c1@x.kr')),
  '학생에게만 안내하면 매칭 업무는 열린 채 "강사에게 최종 안내"만 남음 (사고 상황)');
select pg_temp.ok((pg_temp.notice('c1@x.kr', 'student')).sent_via = 'manual',
  '[보냈어요]로 기록한 안내는 sent_via = manual (복사만으로는 기록되지 않음, migration 1200)');
select pg_temp.ok((admin_mark_notice_sent((pg_temp.notice('c1@x.kr', 'student')).id) ->> 'repeated')::boolean
              and (select count(*) from audit_log where table_name = 'schedule_notices' and row_id = (pg_temp.notice('c1@x.kr', 'student')).id::text and action = 'UPDATE') = 1,
  '이미 보낸 안내를 다시 복사해도 기록이 바뀌지 않음 (보낸 시각 그대로)');
reset role;
select pg_temp.expect_error($$update admin_tasks set student_notified_at = now(), status = 'done', done_at = now()
  where kind = 'new_student_matching' and enrollment_id = pg_temp.eid('c1@x.kr')$$, 'admin_tasks_matching_tutor_notified');
select pg_temp.ok(true, '강사 안내 기록 없이는 DB가 매칭 업무 완료를 거부');
set role authenticated;

-- 강사 쪽도 보냄 → 업무 자동 완료, 화면 목록에서 빠짐
create temp table t_sent as select admin_mark_notice_sent((pg_temp.notice('c1@x.kr', 'tutor')).id) as r;
select pg_temp.ok((select (r ->> 'all_sent')::boolean from t_sent)
              and (pg_temp.task('c1@x.kr')).status = 'done'
              and (pg_temp.task('c1@x.kr')).tutor_notified_at is not null and (pg_temp.task('c1@x.kr')).student_notified_at is not null
              and not exists (select 1 from schedule_plan_board where enrollment_id = pg_temp.eid('c1@x.kr')),
  '양쪽 안내가 끝나면 매칭 업무가 사람이 닫지 않아도 완료되고 목록에서 빠짐');

-- 4) 강사가 안 된다고 함 → 다른 안 (버전 2). 닫힌 안은 확정 불가, 같은 요청 번호는 한 번만
select pg_temp.reg('90000000-0000-0000-0000-000000001002',
  pg_temp.body_wait('거절', 'c2@x.kr', '2027-06-07', '[{"weekday":1,"time":"19:00"}]'));
select admin_close_plan((select id from schedule_plans where enrollment_id = pg_temp.eid('c2@x.kr') and version = 1), 'declined', '그 시간 다른 학교 수업');
select pg_temp.expect_error($$select admin_confirm_schedule((select id from schedule_plans where enrollment_id = pg_temp.eid('c2@x.kr') and version = 1))$$, '닫힌 일정안');
select pg_temp.ok(true, '강사가 거절한 안은 확정할 수 없음');
create temp table t_prop as select admin_propose_schedule('90000000-0000-0000-0000-000000001003', pg_temp.eid('c2@x.kr'),
  '{"tutor_id":"55555555-0000-0000-0000-000000001000","slots":[{"weekday":1,"time":"18:00"}],"start_date":"2027-06-07"}') as r;
insert into t_prop select admin_propose_schedule('90000000-0000-0000-0000-000000001003', pg_temp.eid('c2@x.kr'),
  '{"tutor_id":"55555555-0000-0000-0000-000000001000","slots":[{"weekday":1,"time":"18:00"}],"start_date":"2027-06-07"}');
select pg_temp.ok((select array_agg((r ->> 'version') || coalesce(r ->> 'repeated', '')) from t_prop) = array['2', '2true']
              and (select count(*) from schedule_plans where enrollment_id = pg_temp.eid('c2@x.kr')) = 2,
  '다른 시간으로 다시 제안 = 버전 2, 같은 요청을 두 번 보내도 1건');
select admin_propose_schedule('90000000-0000-0000-0000-000000001004', pg_temp.eid('c2@x.kr'),
  '{"tutor_id":"55555555-0000-0000-0000-000000001000","slots":[{"weekday":1,"time":"17:00"}],"start_date":"2027-06-07"}');
select pg_temp.ok((select state from schedule_plans where id = '90000000-0000-0000-0000-000000001003') = 'withdrawn'
              and (select count(*) from schedule_plans where enrollment_id = pg_temp.eid('c2@x.kr') and state = 'proposed') = 1,
  '답 대기 중 새 안을 제안하면 이전 안은 "다른 안으로 바꿈"으로 닫힘 (답 대기는 항상 1건)');

-- 제안 뒤 강사 일정이 생기면 확정 때 다시 검사 → 아무것도 바뀌지 않음
reset role;
insert into tutor_time_off (tutor_id, starts_at, ends_at, kind)
values ('55555555-0000-0000-0000-000000001000', '2027-06-14 16:30+09', '2027-06-14 18:30+09', 'block');
set role authenticated;
select pg_temp.expect_error($$select admin_confirm_schedule('90000000-0000-0000-0000-000000001004')$$, '일정 충돌');
select pg_temp.ok((select state from schedule_plans where id = '90000000-0000-0000-0000-000000001004') = 'proposed'
              and not exists (select 1 from lessons where enrollment_id = pg_temp.eid('c2@x.kr')),
  '제안 뒤 생긴 강사 휴무와 겹치면 확정 거절 — 수업·안내 아무것도 안 생김');

-- 수업이 없는 등록은 다른 첫 수업일로 제안하면 수강 기간이 따라 옮겨짐 (강사가 거절한 뒤 다른 요일)
select admin_propose_schedule('90000000-0000-0000-0000-000000001006', pg_temp.eid('c2@x.kr'),
  '{"tutor_id":"55555555-0000-0000-0000-000000001000","slots":[{"weekday":3,"time":"17:00"}],"start_date":"2027-06-09"}');
select pg_temp.ok((select start_date = '2027-06-09' and base_end_date = '2027-07-06' from enrollments where id = pg_temp.eid('c2@x.kr'))
              and (select state from schedule_plans where id = '90000000-0000-0000-0000-000000001004') = 'withdrawn',
  '수업 없는 등록: 첫 수업일을 6/9(수)로 바꾸면 수강 기간도 6/9~7/6 으로');
select pg_temp.expect_error($$select admin_propose_schedule(gen_random_uuid(), pg_temp.eid('c1@x.kr'),
  '{"tutor_id":"55555555-0000-0000-0000-000000001000","slots":[{"weekday":2,"time":"10:00"},{"weekday":4,"time":"10:00"}],"start_date":"2027-06-08"}')$$, '이미 확정된 일정');
select pg_temp.ok((select start_date from enrollments where id = pg_temp.eid('c1@x.kr')) = '2027-06-01', '확정된 등록은 다른 안을 받지 않고 기간도 그대로');

-- 결제 대기 등록에는 제안 불가
select pg_temp.expect_error($$select admin_propose_schedule(gen_random_uuid(), pg_temp.eid('wait@x.kr'),
  '{"tutor_id":"55555555-0000-0000-0000-000000001000","slots":[{"weekday":1,"time":"19:00"},{"weekday":3,"time":"19:00"}],"start_date":"2027-03-01"}')$$, 'POL-OP-13');
select pg_temp.ok(true, '결제 확인 전 등록에는 강사 제안도 불가');

-- 5) 자동 발송기(나중): 실패한 쪽만 다시, 성공은 덮지 않음, 결과 불명확은 자동 재시도 안 함
create temp table t_c3 as select pg_temp.reg('90000000-0000-0000-0000-000000001005',
  pg_temp.body('자동', 'c3@x.kr', 4, 1, 50, '2027-06-08', '55555555-0000-0000-0000-000000001000', '[{"weekday":2,"time":"07:00"}]', true)) as r;
select pg_temp.ok((select r ->> 'plan_state' = 'confirmed'
                          and (r ->> 'tutor_notice_id')::uuid = (pg_temp.notice('c3@x.kr', 'tutor')).id
                          and (r ->> 'student_notice_id')::uuid = (pg_temp.notice('c3@x.kr', 'student')).id from t_c3),
  '강사가 이미 가능하다고 답했으면 등록 저장 한 번으로 확정까지, 결과에 안내 2건 번호');
select pg_temp.expect_error($$select lms_notice_result((pg_temp.notice('c3@x.kr', 'tutor')).id, 'sent', null)$$, 'permission|42501');
select pg_temp.ok(true, '앱 사용자는 발송 결과를 직접 기록할 수 없음 (서버만)');
reset role;
select lms_notice_result((pg_temp.notice('c3@x.kr', 'tutor')).id, 'failed', 'test: 발송 실패');
select lms_notice_result((pg_temp.notice('c3@x.kr', 'student')).id, 'sent', null);
select pg_temp.ok((select array_agg(recipient_kind) from schedule_notice_outbox o join schedule_plans p on p.id = o.plan_id where p.enrollment_id = pg_temp.eid('c3@x.kr')) = array['tutor']
              and (pg_temp.task('c3@x.kr')).status = 'open',
  '강사 쪽 실패 → 다시 보낼 대상은 강사 1건뿐, 학생 안내는 다시 안 보냄, 업무는 열림');
select lms_notice_result((pg_temp.notice('c3@x.kr', 'student')).id, 'failed', 'test: 늦게 온 실패');
select pg_temp.ok((pg_temp.notice('c3@x.kr', 'student')).status = 'sent', '이미 보낸 안내는 나중 결과로 덮이지 않음');
select lms_notice_result((pg_temp.notice('c3@x.kr', 'tutor')).id, 'unknown', 'test: 응답 없음');
select pg_temp.ok(not exists (select 1 from schedule_notice_outbox o join schedule_plans p on p.id = o.plan_id where p.enrollment_id = pg_temp.eid('c3@x.kr'))
              and (select tutor_notice_status = 'unknown' from schedule_plan_board where enrollment_id = pg_temp.eid('c3@x.kr')),
  '결과가 불명확하면 자동 재시도 대상에서 빠지고 운영자 화면에 "확인 필요"로 남음');
select lms_notice_result((pg_temp.notice('c3@x.kr', 'tutor')).id, 'sent', null);
select pg_temp.ok((pg_temp.task('c3@x.kr')).status = 'done', '강사 쪽까지 보내지면 업무 완료');

-- 권한
set role authenticated;
set request.jwt.claim.sub = 'bbbbbbbb-0000-0000-0000-000000000001';   -- 학생
select pg_temp.expect_error($$select admin_confirm_schedule('90000000-0000-0000-0000-000000001004')$$, '42501');
select pg_temp.expect_error($$select admin_mark_notice_sent((select id from schedule_notices limit 1))$$, '42501');
select pg_temp.ok((select count(*) from schedule_plans) = 0 and (select count(*) from schedule_notices) = 0, '학생은 일정안·안내 기록을 볼 수도, 확정·기록할 수도 없음');
reset request.jwt.claim.sub;
reset role;
set role anon;
select pg_temp.expect_error($$select admin_confirm_schedule('90000000-0000-0000-0000-000000001004')$$, 'permission|42501');
reset role;
select pg_temp.ok(true, '로그인 안 한 요청은 확정 함수를 부를 수 없음');

-- ---------- 기존 학생 간단 입력 (migration 1300, D-52 · H23(3)) ----------
insert into tutors (id, name, country, timezone) values ('55555555-0000-0000-0000-000000001300', 'TestTutorImport', 'Korea', 'Asia/Seoul'),
                                                       ('55555555-0000-0000-0000-000000001301', 'TestTutorImport2', 'Korea', 'Asia/Seoul');
create or replace function pg_temp.imp(rid text, body jsonb) returns jsonb
language sql as $$ select admin_import_existing_student(rid::uuid, body) $$;
create or replace function pg_temp.imp_conflicts(body jsonb) returns jsonb
language plpgsql as $$
declare det text; h text;
begin
  perform admin_import_existing_student(gen_random_uuid(), body);
  raise exception '실패: 충돌이 나야 하는데 저장됨';
exception when sqlstate 'P0001' then
  get stacked diagnostics det = pg_exception_detail, h = pg_exception_hint;
  if h is distinct from 'schedule_conflict' then raise; end if;
  return det::jsonb;
end $$;
-- 2027-08-02(월) ~ 2027-08-29(일), 강사 Import, 50분
create or replace function pg_temp.ibody(name text, slots jsonb, makeups jsonb) returns jsonb
language sql as $$
  select jsonb_build_object('student', jsonb_build_object('name_ko', name, 'name_en', 'Imp ' || name, 'timezone', 'Asia/Seoul'),
    'tutor_id', '55555555-0000-0000-0000-000000001300', 'slots', slots, 'duration_min', 50,
    'from_date', '2027-08-02', 'end_date', '2027-08-29', 'makeups', makeups,
    'course', jsonb_build_object('weeks', 4, 'period_idx', 1, 'period_start', '2027-08-02', 'credits_left', 1),
    'sheet', jsonb_build_object('total', 4, 'used', 0))
$$;

set role authenticated;
set request.jwt.claim.sub = 'bbbbbbbb-0000-0000-0000-000000000009';   -- 대표 (aal2)
-- 먼저 들어간 기존 학생 A: 화 19:00 (+ 8/12(목) 21:00 이관 보강, 같은 강사)
select pg_temp.ok((select (r ->> 'lessons')::int = 4 and (r ->> 'makeups')::int = 1
                   from pg_temp.imp('90000000-0000-0000-0000-000000001301',
                     pg_temp.ibody('이관A', '[{"weekday":2,"time":"19:00"}]', '[{"status":"booked","origin_unknown":true,"date":"2027-08-12","time":"21:00","duration_min":50,"tutor_id":"55555555-0000-0000-0000-000000001300"}]')) r),
  '기존 학생 입력: 시작일~종료일 정규 4회 + 확정된 미래 보강 1회');
select pg_temp.ok((select count(*) from lessons l join students s on s.id = l.student_id where s.name_ko = '이관A' and l.kind = 'migrated_makeup' and l.makeup_of is null) = 1
              and (select count(*) from regular_schedules r join students s on s.id = r.student_id where s.name_ko = '이관A') = 1
              and (select status = 'active' and legacy_label is not null and weeks is null from enrollments e join students s on s.id = e.student_id where s.name_ko = '이관A')
              and not exists (select 1 from admin_tasks t join enrollments e on e.id = t.enrollment_id join students s on s.id = e.student_id where s.name_ko = '이관A')
              and not exists (select 1 from payments p join enrollments e on e.id = p.enrollment_id join students s on s.id = e.student_id where s.name_ko = '이관A'),
  '보강은 그날 수업 하나만(정규 시간표에 안 들어감), 수강 중(active)·결제·매칭 업무 없음');
select pg_temp.ok((pg_temp.imp('90000000-0000-0000-0000-000000001301', pg_temp.ibody('이관A', '[{"weekday":2,"time":"19:00"}]', '[]')) ->> 'repeated')::boolean
              and (select count(*) from students where name_ko = '이관A') = 1,
  '같은 요청 번호로 다시 저장해도 1명');

-- 기존 학생 시간표와 충돌: 같은 강사 화 19:00 → 4주 모두, 화 19:55 → 휴식 10분 부족, 화 20:00 → 가능
select pg_temp.ok((select count(*) = 4 and bool_and(x ->> 'reason' = 'tutor_regular' and x ->> 'other' = '이관A')
                   from jsonb_array_elements(pg_temp.imp_conflicts(pg_temp.ibody('충돌', '[{"weekday":2,"time":"19:00"}]', '[]'))) x)
              and not exists (select 1 from students where name_ko = '충돌'),
  '기존 학생 정규 수업과 겹치면 날짜마다 알려 주고 아무것도 저장 안 함 (상대 학생 이름 포함)');
select pg_temp.ok((select bool_and(x ->> 'reason' = 'break') from jsonb_array_elements(pg_temp.imp_conflicts(pg_temp.ibody('휴식', '[{"weekday":2,"time":"19:55"}]', '[]'))) x),
  '앞 수업이 끝나고 10분 안에 시작하면 휴식 부족으로 거절 (A38)');

-- 보강은 그날만 막음: 목 21:00 정규는 8/12 하루만 충돌, 다른 목요일은 가능
select pg_temp.ok((select count(*) = 1 and bool_and(x ->> 'reason' = 'tutor_makeup' and x ->> 'date' = '2027-08-12')
                   from jsonb_array_elements(pg_temp.imp_conflicts(pg_temp.ibody('목요일', '[{"weekday":4,"time":"21:00"}]', '[]'))) x),
  '일회성 보강은 그 날짜만 충돌 — 같은 요일·시각의 다른 주는 막지 않음');

-- 강사 휴무와 충돌 (정규·보강 모두)
reset role;
insert into tutor_time_off (tutor_id, starts_at, ends_at, kind, reason)
values ('55555555-0000-0000-0000-000000001300', '2027-08-18 00:00+09', '2027-08-19 00:00+09', 'leave', '휴가');
set role authenticated;
select pg_temp.ok((select count(*) = 2 and bool_and(x ->> 'reason' = 'tutor_time_off' and x ->> 'date' = '2027-08-18')
                   from jsonb_array_elements(pg_temp.imp_conflicts(pg_temp.ibody('휴무', '[{"weekday":3,"time":"10:00"}]',
                     '[{"status":"booked","origin_unknown":true,"date":"2027-08-18","time":"15:00","duration_min":20,"tutor_id":"55555555-0000-0000-0000-000000001300"}]'))) x),
  '강사 휴무 날의 정규·보강 모두 휴무 충돌로 거절');

-- 이번 입력끼리: 보강을 자기 정규 수업 시간에 넣으면 거절 (다른 강사여도 학생 시간이 겹치면)
select pg_temp.ok((select bool_or(x ->> 'reason' = 'self') from jsonb_array_elements(pg_temp.imp_conflicts(pg_temp.ibody('자기', '[{"weekday":1,"time":"10:00"}]',
                     '[{"status":"booked","origin_unknown":true,"date":"2027-08-09","time":"10:20","duration_min":20,"tutor_id":"55555555-0000-0000-0000-000000001301"}]'))) x),
  '보강이 이 학생 정규 수업과 겹치면 거절');

-- 입력 확인
select pg_temp.expect_error($$select pg_temp.imp(gen_random_uuid()::text, pg_temp.ibody('지난보강', '[{"weekday":1,"time":"08:00"}]',
  '[{"status":"booked","origin_unknown":true,"date":"2027-07-30","time":"15:00","duration_min":20,"tutor_id":"55555555-0000-0000-0000-000000001300"}]'))$$, '지난 보강');
select pg_temp.expect_error($$select pg_temp.imp(gen_random_uuid()::text, pg_temp.ibody('네번', '[{"weekday":1,"time":"08:00"},{"weekday":2,"time":"08:00"},{"weekday":3,"time":"08:00"},{"weekday":4,"time":"08:00"}]', '[]'))$$, '1·2·3·5회');
select pg_temp.ok(true, '시작일 전 보강·주 4회 같은 잘못된 입력 거절');

set request.jwt.claim.sub = 'bbbbbbbb-0000-0000-0000-000000000001';   -- 학생
select pg_temp.expect_error($$select pg_temp.imp(gen_random_uuid()::text, pg_temp.ibody('학생이', '[{"weekday":1,"time":"08:00"}]', '[]'))$$, '42501');
reset request.jwt.claim.sub;
reset role;
set role anon;
select pg_temp.expect_error($$select admin_import_existing_student(gen_random_uuid(), '{}'::jsonb)$$, 'permission|42501');
reset role;
select pg_temp.ok(true, '학생·로그인 안 한 요청은 기존 학생 입력 불가');

-- ---------- 기존 학생 입력 확대 (migration 1500, D-52 확대판 · H26, 2026-10-24 대표 결정) ----------
insert into tutors (id, name, country, timezone) values ('55555555-0000-0000-0000-000000001500', 'TestTutorExpand', 'Korea', 'Asia/Seoul');
-- 화·목 19:00, 2027-11-01(월)~11-28(일) → 정규 후보 8회 (11/2·4·9·11·16·18·23·25)
create or replace function pg_temp.xbody(name text, makeups jsonb, extras jsonb, skips jsonb) returns jsonb
language sql as $$
  select jsonb_build_object('student', jsonb_build_object('name_ko', name, 'name_en', 'X ' || name, 'timezone', 'Asia/Seoul'),
    'tutor_id', '55555555-0000-0000-0000-000000001500', 'slots', '[{"weekday":2,"time":"19:00"},{"weekday":4,"time":"19:00"}]'::jsonb,
    'duration_min', 50, 'from_date', '2027-11-01', 'end_date', '2027-11-28', 'makeups', makeups, 'extras', extras, 'skip_dates', skips,
    'course', jsonb_build_object('weeks', 12, 'period_idx', 2, 'period_start', '2027-10-12', 'credits_left', 1),
    'sheet', jsonb_build_object('total', 24, 'used', 14))
$$;
set role authenticated;
set request.jwt.claim.sub = 'bbbbbbbb-0000-0000-0000-000000000009';   -- 대표 (aal2)
select pg_temp.ok((select (r ->> 'lessons')::int = 6 and (r ->> 'makeups')::int = 1 and (r ->> 'open_makeups')::int = 2
                          and (r ->> 'extras')::int = 1 and (r ->> 'lms_left')::int = 10 and (r ->> 'sheet_left')::int = 10
                   from pg_temp.imp('90000000-0000-0000-0000-000000001501', pg_temp.xbody('확대A',
                     '[{"status":"booked","original_date":"2027-10-28","date":"2027-11-05","time":"19:00","duration_min":50,"tutor_id":"55555555-0000-0000-0000-000000001500"},
                       {"status":"open","original_date":"2027-11-11"},
                       {"status":"open","origin_unknown":true}]',
                     '[{"date":"2027-11-26","time":"19:00","reason":"시트 이월 1회"}]', '["2027-11-25"]')) r),
  '남은 수업 = 정규 6 + 예약 보강 1 + 미예약 보강 2 + 추가 1 = 10 (시트 24 − 14와 같음)');
select pg_temp.ok(not exists (select 1 from lessons l join students s on s.id = l.student_id where s.name_ko = '확대A' and l.kind = 'regular' and l.kst_date in ('2027-11-11', '2027-11-25'))
              and (select count(*) from lessons l join students s on s.id = l.student_id where s.name_ko = '확대A' and l.kind = 'migrated_extra') = 1,
  '보강의 원래 수업 날짜(11/11)와 운영진이 뺀 날짜(11/25)는 정규 수업을 만들지 않음 (두 번 세지 않음)');
select pg_temp.ok((select count(*) filter (where i.kind = 'makeup_booked' and i.lesson_id is not null and i.original_date = '2027-10-28') = 1
                      and count(*) filter (where i.kind = 'makeup_open' and i.lesson_id is null) = 2
                      and count(*) filter (where i.origin_unknown) = 1
                      and count(*) filter (where i.kind = 'extra' and i.reason = '시트 이월 1회') = 1
                   from migrated_items i join enrollments e on e.id = i.enrollment_id join students s on s.id = e.student_id where s.name_ko = '확대A'),
  '보강 예약됨·미예약·날짜 확인 필요, 추가 수업 근거가 따로 기록됨');
select pg_temp.ok((select array_agg(credit_balance(p.id) order by p.idx) = '{2,1,2}' and array_agg(p.start_date order by p.idx) = '{2027-09-14,2027-10-12,2027-11-09}'
                          and min(e.start_date) = '2027-09-14'
                   from enrollment_periods p join enrollments e on e.id = p.enrollment_id join students s on s.id = e.student_id where s.name_ko = '확대A'),
  '수강 시작일(1기간)부터 모든 28일 기간 기록, 지금 2기간만 남은 변경권 1, 다음 3기간은 2개 새로 (1600)');
select pg_temp.ok((select c.checked_at is null and c.lms_left = 10 and st.lms_since is null
                   from import_checks c join enrollments e on e.id = c.enrollment_id join students st on st.id = e.student_id where st.name_ko = '확대A'),
  '입력해도 시트 대조 전·LMS 전환 전 (시트로 관리)');

select pg_temp.expect_error($$select pg_temp.imp(gen_random_uuid()::text, pg_temp.xbody('중복보강',
  '[{"status":"open","original_date":"2027-10-28"},{"status":"open","original_date":"2027-10-28"}]', '[]', '[]'))$$, '두 개');
select pg_temp.expect_error($$select pg_temp.imp(gen_random_uuid()::text, pg_temp.xbody('날짜없음', '[{"status":"open"}]', '[]', '[]'))$$, '날짜 확인 필요');
select pg_temp.expect_error($$select pg_temp.imp(gen_random_uuid()::text, pg_temp.xbody('근거없음', '[]', '[{"date":"2027-11-26","time":"19:00","reason":" "}]', '[]'))$$, '근거');
select pg_temp.ok(true, '같은 원래 수업의 보강 두 개 · 원래 날짜도 확인 필요도 없는 보강 · 근거 없는 추가 수업은 저장 안 함');

-- 숫자가 달라도 저장 (시트 남은 11 ≠ LMS 8)
select pg_temp.ok((select (r ->> 'lms_left')::int = 8 and (r ->> 'sheet_left')::int = 10
                   from pg_temp.imp('90000000-0000-0000-0000-000000001502',
                     pg_temp.xbody('확대B', '[]', '[]', '[]') || jsonb_build_object('tutor_id', '55555555-0000-0000-0000-000000001301', 'slots', '[{"weekday":3,"time":"07:00"},{"weekday":5,"time":"07:00"}]'::jsonb)) r),
  '시트와 숫자가 달라도 저장됨 (차이는 처리할 일로)');

-- 시트 대조 완료 기록: 한 번만 (다시 눌러도 처음 시각 그대로)
create temp table imp_chk as select admin_import_mark_checked(e.id) as r1, e.id as eid from enrollments e join students s on s.id = e.student_id where s.name_ko = '확대A';
select pg_temp.ok((select r1 ->> 'checked_by' = 'bbbbbbbb-0000-0000-0000-000000000009' and admin_import_mark_checked(eid) ->> 'checked_at' = r1 ->> 'checked_at' from imp_chk),
  '시트 대조 완료는 확인 시각·담당자로 기록되고, 다시 눌러도 처음 기록 그대로');

-- 원래 날짜 확인 필요 정리: 시작일 이후 날짜 거절, 그 전 날짜는 넣음
select pg_temp.expect_error($$select admin_import_set_origin((select i.id from migrated_items i join enrollments e on e.id = i.enrollment_id join students s on s.id = e.student_id
  where s.name_ko = '확대A' and i.origin_unknown), '2027-11-02')$$, '입력 시작일');
select admin_import_set_origin((select i.id from migrated_items i join enrollments e on e.id = i.enrollment_id join students s on s.id = e.student_id
  where s.name_ko = '확대A' and i.origin_unknown), '2027-10-21');
select pg_temp.ok((select count(*) = 0 from migrated_items i join enrollments e on e.id = i.enrollment_id join students s on s.id = e.student_id where s.name_ko = '확대A' and i.origin_unknown)
              and exists (select 1 from migrated_items where original_date = '2027-10-21' and origin_checked_at is not null),
  '날짜 확인 필요 보강은 나중에 입력 시작일 전 날짜로만 채움 (정규와 두 번 세지 않게)');

set request.jwt.claim.sub = 'bbbbbbbb-0000-0000-0000-000000000001';   -- 학생
select pg_temp.expect_error($$select admin_import_mark_checked((select enrollment_id from registration_requests where id = '90000000-0000-0000-0000-000000001501'))$$, '42501');
select pg_temp.ok((select count(*) from migrated_items) = 0 and (select count(*) from import_checks) = 0, '학생은 이관 기록·대조 기록을 볼 수도 기록할 수도 없음');
reset request.jwt.claim.sub;
reset role;

-- ---------- 시안 2: 연장된 날에는 정규 수업을 만들지 않음 (migration 1600, A41 ④) ----------
-- 4주 · 1기간 2027-12-06(월) 시작 → 계산 끝 2028-01-02(일). 시트 종료일 2028-01-09(일, 강사 휴무 연장 7일)
create or replace function pg_temp.ebody(name text, reason text, ext_end date, makeups jsonb) returns jsonb
language sql as $$
  select jsonb_build_object('student', jsonb_build_object('name_ko', name, 'name_en', 'E ' || name, 'timezone', 'Asia/Seoul'),
    'tutor_id', '55555555-0000-0000-0000-000000001500', 'slots', '[{"weekday":1,"time":"07:00"},{"weekday":3,"time":"07:00"}]'::jsonb,
    'duration_min', 50, 'from_date', '2027-12-06', 'end_date', ext_end, 'makeups', makeups,
    'course', jsonb_build_object('weeks', 4, 'period_idx', 1, 'period_start', '2027-12-06', 'credits_left', 2),
    'extension', jsonb_build_object('reason', reason), 'sheet', jsonb_build_object('total', 8, 'used', 0))
$$;
set role authenticated;
set request.jwt.claim.sub = 'bbbbbbbb-0000-0000-0000-000000000009';   -- 대표 (aal2)
select pg_temp.ok((select (r ->> 'lessons')::int = 6 and (r ->> 'lms_left')::int = 8 and r ->> 'regular_end' = '2028-01-02' and r ->> 'end_date' = '2028-01-09'
                   from pg_temp.imp('90000000-0000-0000-0000-000000001601', pg_temp.ebody('연장A', 'tutor_long_term_leave', '2028-01-09',
                     '[{"status":"open","original_date":"2027-12-27"},{"status":"booked","original_date":"2027-12-29","date":"2028-01-05","time":"07:00","duration_min":50,"tutor_id":"55555555-0000-0000-0000-000000001500"}]')) r)
              and not exists (select 1 from lessons l join students s on s.id = l.student_id where s.name_ko = '연장A' and l.kind = 'regular' and l.kst_date > '2028-01-02'),
  '종료일을 7일 연장해도 정규 수업은 계산 끝(1/2)까지만 — 늘어난 날의 월·수는 만들지 않음 (보강 1/5만 늘어난 날에)');
select pg_temp.ok((select e.base_end_date = '2028-01-02' and e.final_end_date = '2028-01-09' and x.reason = 'tutor_long_term_leave' and x.days = 7
                   from enrollments e join students s on s.id = e.student_id join enrollment_extensions x on x.enrollment_id = e.id where s.name_ko = '연장A')
              and (select lms_left = 8 + 0 and end_reason = 'tutor_long_term_leave' from import_checks c join enrollments e on e.id = c.enrollment_id join students s on s.id = e.student_id where s.name_ko = '연장A'),
  '늘어난 날은 연장 기록(강사 장기 휴무 7일)으로, 남은 수업은 늘지 않음 (정규 6 + 예약 보강 1 + 미예약 1 = 8)');
select pg_temp.expect_error($$select pg_temp.imp(gen_random_uuid()::text, pg_temp.ebody('보강늦음', 'tutor_long_term_leave', '2028-01-02',
  '[{"status":"booked","original_date":"2027-12-29","date":"2028-01-05","time":"07:00","duration_min":50,"tutor_id":"55555555-0000-0000-0000-000000001500"}]'))$$, '종료일');
select pg_temp.expect_error($$select pg_temp.imp(gen_random_uuid()::text, pg_temp.ebody('장기연기4주', 'student_long_term_leave', '2028-01-09', '[]'))$$, '24주');
select pg_temp.ok(true, '보강이 종료일 뒤면 저장 안 함(연장 먼저) · 학생 장기 연기는 24주만');
select pg_temp.imp('90000000-0000-0000-0000-000000001602', pg_temp.ebody('이유없음', '', '2028-01-04', '[]') || jsonb_build_object('slots', '[{"weekday":1,"time":"09:00"},{"weekday":3,"time":"09:00"}]'::jsonb));
select pg_temp.ok((select x.reason = 'admin_exception' and x.note like '이유 확인 필요%' and c.end_reason is null and c.end_days = 2 and c.end_checked_at is null
                   from enrollments e join students s on s.id = e.student_id join enrollment_extensions x on x.enrollment_id = e.id
                   join import_checks c on c.enrollment_id = e.id where s.name_ko = '이유없음'),
  '이유를 안 골라도 저장은 됨 — 대신 종료일 이유가 비어 있는 미해결 항목으로 남음 (대표 2026-10-26)');
select admin_import_mark_checked(e.id) from enrollments e join students s on s.id = e.student_id where s.name_ko = '이유없음';
select pg_temp.ok((select c.checked_at is not null and c.end_reason is null from import_checks c join enrollments e on e.id = c.enrollment_id join students s on s.id = e.student_id where s.name_ko = '이유없음'),
  '시트 대조 완료를 눌러도 종료일 이유 미해결은 따로 남음');
select pg_temp.expect_error($$select admin_import_set_end_reason((select e.id from enrollments e join students s on s.id = e.student_id where s.name_ko = '이유없음'), 'student_long_term_leave', null)$$, '24주');
select pg_temp.expect_error($$select admin_import_set_end_reason((select e.id from enrollments e join students s on s.id = e.student_id where s.name_ko = '이유없음'), 'admin_exception', ' ')$$, '메모');
select admin_import_set_end_reason(e.id, 'tutor_long_term_leave', null) from enrollments e join students s on s.id = e.student_id where s.name_ko = '이유없음';
select pg_temp.ok((select c.end_reason = 'tutor_long_term_leave' and c.end_checked_by = 'bbbbbbbb-0000-0000-0000-000000000009' and e.extension_days = 2
                          and (select count(*) from enrollment_extensions x where x.enrollment_id = e.id) = 3
                          and (select sum(days) filter (where reason = 'tutor_long_term_leave') from enrollment_extensions x where x.enrollment_id = e.id) = 2
                   from import_checks c join enrollments e on e.id = c.enrollment_id join students s on s.id = e.student_id where s.name_ko = '이유없음'),
  '이유를 정하면 해결(시각·담당자 기록), 연장 일수는 그대로이고 이력은 정정 줄로 남음');

-- 강사 휴가 보강 권리: 날짜 미정인 채로 수강 종료일이 지나도 그대로 남음 (A41)
select pg_temp.imp('90000000-0000-0000-0000-000000001603',
  pg_temp.ebody('휴가지남', 'tutor_long_term_leave', '2026-10-04', '[{"status":"open","original_date":"2026-09-30","tutor_leave":true}]')
  || jsonb_build_object('from_date', '2026-09-07', 'course', jsonb_build_object('weeks', 4, 'period_idx', 1, 'period_start', '2026-09-07', 'credits_left', 2),
                        'slots', '[{"weekday":1,"time":"10:00"},{"weekday":3,"time":"10:00"}]'::jsonb));
select pg_temp.ok((select i.kind = 'makeup_open' and i.tutor_leave and i.lesson_id is null and e.final_end_date < current_date
                   from migrated_items i join enrollments e on e.id = i.enrollment_id join students s on s.id = e.student_id where s.name_ko = '휴가지남'),
  '강사 휴가로 생긴 미예약 보강은 종료일이 지나도 지워지거나 소멸 처리되지 않음 (강사 휴가 표시 보존)');
reset request.jwt.claim.sub;
reset role;

-- ---------- 재등록 대기 자리 맡아 두기 (migration 1400, A22 · POL-RN-02) ----------
set role authenticated;
set request.jwt.claim.sub = 'bbbbbbbb-0000-0000-0000-000000000009';   -- 대표 (aal2)
-- 이관A: 화 19:00, 2027-08-29 종료 (마감 아직 안 지남) → 종료 뒤 화요일 19:00 은 다른 학생에게 못 줌
create or replace function pg_temp.ibody2(name text, slots jsonb, tutor text, f date, e date) returns jsonb
language sql as $$ select pg_temp.ibody(name, slots, '[]') || jsonb_build_object('tutor_id', tutor, 'from_date', f, 'end_date', e,
  'course', jsonb_build_object('weeks', 4, 'period_idx', 1, 'period_start', f, 'credits_left', 1)) $$;
select pg_temp.ok((select count(*) = 4 and bool_and(x ->> 'reason' = 'tutor_hold' and x ->> 'other' like '이관A%23:59까지')
                   from jsonb_array_elements(pg_temp.imp_conflicts(pg_temp.ibody2('대기충돌', '[{"weekday":2,"time":"19:30"}]',
                     '55555555-0000-0000-0000-000000001300', '2027-08-30', '2027-09-26'))) x),
  '수업 중인 학생의 고정 시간은 종료일 23:59까지 종료 뒤 날짜도 막힘 (재등록 대기, 상대 이름·마감 표시)');
select pg_temp.ok(jsonb_array_length(pg_temp.imp_conflicts(pg_temp.ibody2('대기휴식', '[{"weekday":2,"time":"19:55"}]',
                     '55555555-0000-0000-0000-000000001300', '2027-08-30', '2027-09-26'))) = 4,
  '재등록 대기 시간 앞뒤 휴식 10분도 지킴');
select pg_temp.ok((pg_temp.imp('90000000-0000-0000-0000-000000001401', pg_temp.ibody2('대기옆', '[{"weekday":2,"time":"20:00"}]',
                     '55555555-0000-0000-0000-000000001300', '2027-08-30', '2027-09-26')) ->> 'lessons')::int = 4,
  '10분 뒤 시간은 그대로 가능');
-- 신규 등록(일정안)도 같은 검사
select pg_temp.ok((select bool_and(x ->> 'reason' = 'tutor_hold') and count(*) = 4
                   from jsonb_array_elements(pg_temp.reg_conflicts('90000000-0000-0000-0000-000000001402',
                     pg_temp.body('대기신규', 'hold@x.kr', 4, 1, 50, '2027-08-31', '55555555-0000-0000-0000-000000001300', '[{"weekday":2,"time":"19:00"}]', true))) x),
  '신규 등록·확정도 재등록 대기 시간을 막음');
-- 마감(종료일 23:59)이 지난 학생의 시간은 풀림
select pg_temp.imp('90000000-0000-0000-0000-000000001403', pg_temp.ibody2('지난학생', '[{"weekday":1,"time":"10:00"}]',
  '55555555-0000-0000-0000-000000001301', '2026-01-05', '2026-01-31'));
select pg_temp.ok(jsonb_array_length(pg_temp.imp_conflicts(pg_temp.ibody2('자리받음', '[{"weekday":1,"time":"10:00"},{"weekday":2,"time":"10:00"}]',
                     '55555555-0000-0000-0000-000000001301', '2027-08-02', '2027-08-29')
                   || jsonb_build_object('makeups', '[{"status":"booked","origin_unknown":true,"date":"2027-08-03","time":"10:00","duration_min":50,"tutor_id":"55555555-0000-0000-0000-000000001301"}]'::jsonb))) = 2,
  '종료일 23:59가 지난 학생의 고정 시간은 다른 학생이 쓸 수 있음 (충돌 2건은 이번 입력끼리의 보강·정규뿐)');
reset request.jwt.claim.sub;
reset role;

-- ---------- 1순위 취소·변경·보강 공통 처리 (migration 1700, 17번 문서 3절 ①·5절) ----------
-- 지금 시각 기준으로 잡은 가상 학생 '변경A' (4주·주2회, 기간 1개 변경권 2개). 강사 TestTutorChange
reset role;
-- 시험 시각이 '지금' 기준이라, 강사 현지 06:00~22:30 시작 검사(4200)에 시험 시각이 걸리지 않게 지금이 현지 정오쯤인 시간대로
-- 4200: 강사가 연 시간만 가능 → 가능 시간 판정이 주제가 아닌 시험 강사는 매일 하루 종일 열어 둠 (현지 06:00~22:30 검사는 따로 걸림)
create or replace function pg_temp.open_all(p uuid) returns void language sql as $$
  insert into tutor_availability (tutor_id, weekday, start_local, end_local, timezone, effective_from)
  select p, d, '00:00', '23:30', (select timezone from tutors where id = p), current_date - 60 from generate_series(0, 6) d $$;
create or replace function pg_temp.noon_tz() returns text language sql as $$
  select case when o > 0 then 'Etc/GMT-' || o when o < 0 then 'Etc/GMT+' || (-o) else 'UTC' end
  from (select ((12 - extract(hour from now() at time zone 'UTC')::int + 36) % 24) - 12 as o) x $$;
insert into tutors (id, name, country, timezone) values ('55555555-0000-0000-0000-000000001700', 'TestTutorChange', 'Korea', pg_temp.noon_tz());
select pg_temp.open_all('55555555-0000-0000-0000-000000001700');
insert into students (id, name_ko, name_en) values ('99999999-0000-0000-0000-000000001700', '변경A', 'Change A');
insert into app_users (auth_user_id, role, student_id) values ('bbbbbbbb-0000-0000-0000-000000001700', 'student', '99999999-0000-0000-0000-000000001700');
insert into enrollments (id, student_id, seq, weeks, weekly_count, duration_min, start_date, base_end_date, lessons_purchased, status)
values ('99999999-1000-0000-0000-000000001700', '99999999-0000-0000-0000-000000001700', 1, 4, 2, 50,
        current_date - 3, current_date - 3 + 27, 8, 'active');
insert into enrollment_periods (id, enrollment_id, idx, start_date, end_date, credits_granted)
values ('99999999-2000-0000-0000-000000001700', '99999999-1000-0000-0000-000000001700', 1, current_date - 3, current_date - 3 + 27, 2);
create temp table cx (k text primary key, t timestamptz);
insert into cx values ('base', date_trunc('hour', now()));
grant select on cx to authenticated;
-- 수업: L2 = 3시간 뒤, L1·L3·L4·L5 = 3·4·5·6일 뒤 같은 시각
insert into lessons (id, enrollment_id, student_id, tutor_id, kind, seq, starts_at, ends_at)
select ('77777777-1700-0000-0000-00000000000' || n)::uuid, '99999999-1000-0000-0000-000000001700', '99999999-0000-0000-0000-000000001700',
       '55555555-0000-0000-0000-000000001700', 'regular', n, t + o, t + o + interval '50 minutes'
from cx, (values (1, interval '3 days'), (2, interval '3 hours'), (3, interval '4 days'), (4, interval '5 days'), (5, interval '6 days')) v(n, o)
where k = 'base';
create or replace function pg_temp.chg(rid text, lesson int, who text, req timestamptz, dry boolean) returns jsonb
language sql as $$ select admin_change_lesson(rid::uuid, ('77777777-1700-0000-0000-00000000000' || lesson)::uuid, who, req, dry) $$;
create or replace function pg_temp.bal() returns int language sql as $$ select credit_balance('99999999-2000-0000-0000-000000001700') $$;
create or replace function pg_temp.st(lesson int) returns text language sql as $$
  select state || ':' || coalesce(class_status::text, '-') from lessons where id = ('77777777-1700-0000-0000-00000000000' || lesson)::uuid $$;

set role authenticated;
set request.jwt.claim.sub = 'bbbbbbbb-0000-0000-0000-000000000009';   -- 대표 (aal2)
-- 1) 미리 보기는 아무것도 바꾸지 않음
select pg_temp.ok((select r ->> 'status' = 'Student canceled in advance' and (r ->> 'uses_credit')::boolean and (r ->> 'credits_after')::int = 1
                          and (r ->> 'makeup_allowed')::boolean and (r ->> 'dry_run')::boolean
                   from pg_temp.chg('c0000000-0000-0000-0000-000000000001', 1, 'student', now(), true) r)
              and pg_temp.st(1) = 'scheduled:-' and pg_temp.bal() = 2 and (select count(*) from change_requests where lesson_id = '77777777-1700-0000-0000-000000000001') = 0,
  '미리 보기: 정상 변경·변경권 2→1·보강 가능으로 보이지만 저장은 안 함');
-- 2) 확정: 수업 취소·변경권 1개·안내 2건(학생·강사)·요청 시각 기록
select pg_temp.chg('c0000000-0000-0000-0000-000000000001', 1, 'student', now() - interval '1 hour', false);
select pg_temp.ok(pg_temp.st(1) = 'canceled:Student canceled in advance' and pg_temp.bal() = 1
              and (select count(*) from lesson_notices n join change_requests c on c.id = n.change_request_id
                   where c.lesson_id = '77777777-1700-0000-0000-000000000001' and n.status = 'pending') = 2
              and (select requested_at < created_at and via = 'admin_on_behalf' and decided_by = 'bbbbbbbb-0000-0000-0000-000000000009'
                   from change_requests where lesson_id = '77777777-1700-0000-0000-000000000001'),
  '확정: 수업 취소 + 변경권 1개 차감 + 학생·강사 안내 각각 + 카톡 받은 시각·처리자 기록');
-- 3) 두 번 누름 → 한 번만 / 다른 요청으로 같은 수업 → 거절
select pg_temp.ok((pg_temp.chg('c0000000-0000-0000-0000-000000000001', 1, 'student', now(), false) ->> 'repeated')::boolean and pg_temp.bal() = 1,
  '같은 요청 두 번 → 한 번만 처리 (변경권 한 번만 차감)');
select pg_temp.expect_error($$select pg_temp.chg(gen_random_uuid()::text, 1, 'student', now(), false)$$, '이미 처리된 수업');
select pg_temp.ok(true, '이미 변경된 수업에 다른 요청 → 거절 (학생·운영진 동시 처리도 하나만)');
-- 4) 6시간 판정은 실제 요청 시각으로: L2(3시간 뒤) — 지금 받은 요청은 늦은 변경, 5시간 전 카톡은 정상 변경
select pg_temp.ok((pg_temp.chg(gen_random_uuid()::text, 2, 'student', now(), true) ->> 'status') = 'Student canceled late'
              and (pg_temp.chg(gen_random_uuid()::text, 2, 'student', now() - interval '5 hours', true) ->> 'status') = 'Student canceled in advance',
  '같은 수업도 카톡 받은 시각(8시간 전)이면 정상 변경, 지금(3시간 전)이면 늦은 변경');
select pg_temp.expect_error($$select pg_temp.chg(gen_random_uuid()::text, 2, 'student', now() + interval '1 hour', true)$$, '지금보다 늦');
select pg_temp.ok((pg_temp.chg(gen_random_uuid()::text, 2, 'student', null, true) ->> 'status') = 'Student canceled late',
  'A-01: 요청 시각을 비우면 서버 시각(지금)으로 판정 — 학생 화면 운영자 보기 (20261107)');
select pg_temp.ok(true, '요청 시각이 미래면 거절');
-- 5) 늦은 변경: 변경권 그대로, 보강 없음
select pg_temp.chg('c0000000-0000-0000-0000-000000000002', 2, 'student', now(), false);
select pg_temp.ok(pg_temp.st(2) = 'canceled:Student canceled late' and pg_temp.bal() = 1, '늦은 변경: 수업 1회 소진, 변경권 차감 없음');
-- 6) 공휴일: 변경권 차감 없이 보강 가능
reset role;
insert into holidays (day, name) select kst_date, '시험 공휴일' from lessons where id = '77777777-1700-0000-0000-000000000005';
set role authenticated;
select pg_temp.chg('c0000000-0000-0000-0000-000000000005', 5, 'student', now(), false);
select pg_temp.ok(pg_temp.st(5) = 'canceled:Student canceled in advance (public holiday)' and pg_temp.bal() = 1, '공휴일 정상 변경: 변경권 그대로, 보강 가능');
reset role;
delete from holidays where name = '시험 공휴일';
set role authenticated;
-- 7) 되돌리기 → 다시 변경 → 되돌리기 → 다시 변경: 매번 정확히 (17번 5절)
select admin_revert_change((select id from change_requests where idempotency_key = 'c0000000-0000-0000-0000-000000000001'), '다른 날짜였음');
select pg_temp.ok(pg_temp.st(1) = 'scheduled:-' and pg_temp.bal() = 2
              and (select status = 'reverted' and reverted_by is not null and revert_note = '다른 날짜였음' from change_requests where idempotency_key = 'c0000000-0000-0000-0000-000000000001'),
  '되돌리기: 수업 다시 예정, 변경권 복구(+1 줄 추가), 기록은 reverted로 남음');
select pg_temp.ok((select count(*) filter (where n.status = 'not_needed') = 2 and count(*) filter (where n.event = 'revert') = 0
                   from lesson_notices n join change_requests c on c.id = n.change_request_id where c.idempotency_key = 'c0000000-0000-0000-0000-000000000001'),
  '안내를 보내기 전에 되돌리면 안내 2건은 보낼 필요 없음, 되돌림 안내도 안 만듦');
select pg_temp.chg('c0000000-0000-0000-0000-000000000011', 1, 'student', now(), false);
select pg_temp.ok(pg_temp.st(1) = 'canceled:Student canceled in advance' and pg_temp.bal() = 1, '되돌린 수업도 다시 정상 변경 가능 (새 요청 = 새 차감)');
-- 보낸 안내가 있으면 그쪽에만 되돌림 안내
select admin_mark_lesson_notice_sent(n.id) from lesson_notices n join change_requests c on c.id = n.change_request_id
where c.idempotency_key = 'c0000000-0000-0000-0000-000000000011' and n.recipient_kind = 'student';
select admin_revert_change((select id from change_requests where idempotency_key = 'c0000000-0000-0000-0000-000000000011'), null);
select pg_temp.ok((select array_agg(n.event || ':' || n.recipient_kind || ':' || n.status order by n.event, n.recipient_kind)
                   from lesson_notices n join change_requests c on c.id = n.change_request_id where c.idempotency_key = 'c0000000-0000-0000-0000-000000000011')
                  = '{change:student:sent,change:tutor:not_needed,revert:student:pending}',
  '학생에게만 보낸 뒤 되돌리면 학생에게만 되돌림 안내 (강사 안내는 보낼 필요 없음)');
select pg_temp.chg('c0000000-0000-0000-0000-000000000021', 1, 'student', now(), false);
select pg_temp.ok(pg_temp.bal() = 1 and (select count(*) from credit_ledger where lesson_id = '77777777-1700-0000-0000-000000000001') = 5,
  '차감 → 복구 → 차감 → 복구 → 차감 모두 기록 (덮어쓰기 없음)');
-- 8) 변경권 0개: 정상 변경이어도 보강 없음
select pg_temp.chg('c0000000-0000-0000-0000-000000000003', 3, 'student', now(), false);
select pg_temp.ok(pg_temp.bal() = 0, '변경권 마지막 1개 사용');
select pg_temp.chg('c0000000-0000-0000-0000-000000000004', 4, 'student', now(), false);
select pg_temp.ok(pg_temp.st(4) = 'canceled:No change credits left' and pg_temp.bal() = 0, '변경권 0개: 변경 처리되지만 보강 없음, 수업 1회 소진');
select admin_revert_change((select id from change_requests where idempotency_key = 'c0000000-0000-0000-0000-000000000004'), null);
-- 9) 강사 사유: 늦은 취소 = 적립금, 되돌리면 회수 줄, 다시 늦은 취소면 다시 지급
reset role;
update lessons set starts_at = starts_at - interval '5 days' + interval '2 hours', ends_at = ends_at - interval '5 days' + interval '2 hours'
where id = '77777777-1700-0000-0000-000000000004';   -- L4를 2시간 뒤로
set role authenticated;
select pg_temp.chg('c0000000-0000-0000-0000-000000000041', 4, 'tutor', now(), false);
select pg_temp.ok(pg_temp.st(4) = 'canceled:Tutor canceled late' and pg_temp.bal() = 0 and reward_balance('99999999-0000-0000-0000-000000001700') = 2000,
  '강사 늦은 취소: 학생 변경권 차감 없음, 적립금 2,000원, 보강 권리');
select admin_revert_change((select id from change_requests where idempotency_key = 'c0000000-0000-0000-0000-000000000041'), null);
select pg_temp.ok(reward_balance('99999999-0000-0000-0000-000000001700') = 0
              and (select count(*) from reward_ledger where student_id = '99999999-0000-0000-0000-000000001700') = 2,
  '강사 늦은 취소를 되돌리면 적립금 회수 줄 추가 (지우지 않음)');
select pg_temp.chg('c0000000-0000-0000-0000-000000000042', 4, 'tutor', now(), false);
select pg_temp.ok(reward_balance('99999999-0000-0000-0000-000000001700') = 2000, '다시 강사 늦은 취소면 새 취소 1건으로 다시 지급');

-- 10) 보강: 신청 → 강사 확인 → 확정 (학생 선택만으로는 확정 안 됨, D-43)
select pg_temp.expect_error($$select admin_makeup_request('77777777-1700-0000-0000-000000000002', null, jsonb_build_array(jsonb_build_object('starts_at', now() + interval '7 days')), now())$$, '보강을 받을 수 있는 수업이 아닙니다');
select pg_temp.expect_error($$select admin_makeup_request('77777777-1700-0000-0000-000000000004', null, jsonb_build_array(jsonb_build_object('starts_at', now() + interval '40 days')), now())$$, '종료일');
select pg_temp.ok(true, '늦은 변경 수업은 보강 신청 불가 · 수강 종료일 뒤 시간 거절');
create temp table mk as select (admin_makeup_request('77777777-1700-0000-0000-000000000004', null,
  jsonb_build_array(jsonb_build_object('starts_at', (select t from cx) + interval '4 days'),
                    jsonb_build_object('starts_at', (select t from cx) + interval '7 days 2 hours')), now()) ->> 'makeup_request_id')::uuid as id;
select pg_temp.ok((select r.status = 'requested' and r.confirmed_lesson_id is null from makeup_requests r join mk on mk.id = r.id)
              and not exists (select 1 from lessons where makeup_of = '77777777-1700-0000-0000-000000000004')
              and (select count(*) from lesson_notices n join mk on mk.id = n.makeup_request_id where n.event = 'makeup_ask' and n.recipient_kind = 'tutor') = 1,
  '보강 신청: 수업은 아직 안 생김, 강사 확인 요청 안내만');
select pg_temp.ok((admin_makeup_request('77777777-1700-0000-0000-000000000004', null, jsonb_build_array(jsonb_build_object('starts_at', now() + interval '8 days')), now()) ->> 'repeated')::boolean,
  '같은 수업에 진행 중 보강 신청은 1건');
reset role;
insert into tutor_time_off (tutor_id, starts_at, ends_at, kind, reason)
select '55555555-0000-0000-0000-000000001700', t + interval '4 days', t + interval '4 days 3 hours', 'block', '변경 시험' from cx;
set role authenticated;
set request.jwt.claim.sub = 'bbbbbbbb-0000-0000-0000-000000000009';
select pg_temp.expect_error($$select admin_makeup_confirm((select id from mk), (select t from cx) + interval '4 days')$$, '열어 둔 시간이 아닙니다');
select pg_temp.ok(true, '강사가 막은 시간(block)과 겹치는 보강 시간은 확정 거절 — 사유는 열지 않은 시간 (4540)');
select admin_makeup_confirm((select id from mk), (select t from cx) + interval '7 days 2 hours');
select pg_temp.ok((select bool_or(r ->> 'status' = 'confirmed') from jsonb_array_elements(student_screen((select student_id from makeup_requests where id = (select id from mk))) -> 'makeup_requests') r),
  '보강 확정 뒤에도 학생 화면이 열리고 신청 내역에 확정으로 보임 (3600)');
select pg_temp.ok((select l.kind = 'makeup' and l.state = 'scheduled' and l.starts_at = (select t from cx) + interval '7 days 2 hours'
                   from lessons l where l.makeup_of = '77777777-1700-0000-0000-000000000004')
              and (select array_agg(n.event || ':' || n.status order by n.event, n.recipient_kind) from lesson_notices n join mk on mk.id = n.makeup_request_id)
                  = '{makeup_ask:not_needed,makeup_confirmed:pending,makeup_confirmed:pending}',
  '강사 가능 → 확정: 보강 수업 생김(원래 수업과 연결), 학생·강사 확정 안내');
-- 11) 확정 보강도 정규와 같이 변경 가능 (A03) → 새 보강 권리
select admin_change_lesson('c0000000-0000-0000-0000-000000000051', (select id from lessons where makeup_of = '77777777-1700-0000-0000-000000000004'), 'tutor', now(), false);
select pg_temp.ok((select class_status = 'Tutor canceled in advance' from lessons where makeup_of = '77777777-1700-0000-0000-000000000004'),
  '확정 보강도 변경 가능, 그 보강이 다시 보강 권리가 됨');
select pg_temp.expect_error($$select admin_revert_change((select id from change_requests where idempotency_key = 'c0000000-0000-0000-0000-000000000042'), null)$$, '다시 변경됐습니다');
select pg_temp.ok(true, '보강이 다시 변경된 수업은 그 변경부터 되돌려야 함');
select admin_revert_change((select id from change_requests where idempotency_key = 'c0000000-0000-0000-0000-000000000051'), null);
select admin_revert_change((select id from change_requests where idempotency_key = 'c0000000-0000-0000-0000-000000000042'), null);
select pg_temp.ok(pg_temp.st(4) = 'scheduled:-' and reward_balance('99999999-0000-0000-0000-000000001700') = 0
              and (select state = 'canceled' and voided_at is not null and class_status is null from lessons where makeup_of = '77777777-1700-0000-0000-000000000004')
              and (select status = 'voided' from makeup_requests r join mk on mk.id = r.id),
  '원래 수업 되돌리기: 그 취소로 잡은 보강은 없앰(voided, 결과 상태 없음), 적립금 회수');
-- 12) [보냈어요]: 보낼 필요 없어진 안내는 기록 불가, 두 번 눌러도 처음 시각
select pg_temp.expect_error($$select admin_mark_lesson_notice_sent((select n.id from lesson_notices n join mk on mk.id = n.makeup_request_id where n.event = 'makeup_ask'))$$, '보낼 필요');
select pg_temp.ok(true, '보낼 필요 없어진 안내에는 [보냈어요] 불가');

-- 13) 이관한 미예약 보강도 같은 흐름 (예약되면 예약됨, 잘못 넣은 보강을 없애면 다시 미예약)
reset role;
insert into migrated_items (id, enrollment_id, kind, original_date) values ('99999999-4000-0000-0000-000000001700', '99999999-1000-0000-0000-000000001700', 'makeup_open', current_date - 2);
set role authenticated;
create temp table mk2 as select (admin_makeup_request(null, '99999999-4000-0000-0000-000000001700',
  jsonb_build_array(jsonb_build_object('starts_at', (select t from cx) + interval '8 days')), now()) ->> 'makeup_request_id')::uuid as id;
select pg_temp.expect_error($$select admin_makeup_confirm((select id from mk2), (select t from cx) + interval '2 hours 55 minutes')$$, '휴식 10분');
select pg_temp.ok(true, '강사 다른 수업 뒤 휴식 10분이 안 되는 보강 시간은 확정 거절');
select admin_makeup_confirm((select id from mk2), (select t from cx) + interval '8 days');
select pg_temp.ok((select i.kind = 'makeup_booked' and l.kind = 'migrated_makeup' from migrated_items i join lessons l on l.id = i.lesson_id where i.id = '99999999-4000-0000-0000-000000001700'),
  '이관 미예약 보강 → 확정되면 예약됨 + 수업');
select admin_void_makeup((select lesson_id from migrated_items where id = '99999999-4000-0000-0000-000000001700'), '날짜 잘못 넣음');
select pg_temp.ok((select kind = 'makeup_open' and lesson_id is null from migrated_items where id = '99999999-4000-0000-0000-000000001700'),
  '잘못 넣은 보강을 없애면 다시 미예약 보강 (권리 유지)');

-- 14) 권한: 학생은 본인 수업만, 운영 함수는 운영자만
set request.jwt.claim.sub = 'bbbbbbbb-0000-0000-0000-000000000001';   -- 다른 학생
select pg_temp.expect_error($$select student_change_lesson(gen_random_uuid(), '77777777-1700-0000-0000-000000000003', true)$$, '42501');
select pg_temp.expect_error($$select pg_temp.chg(gen_random_uuid()::text, 3, 'student', now(), true)$$, '42501');
select pg_temp.expect_error($$select admin_revert_change(gen_random_uuid(), null)$$, '42501');
select pg_temp.ok((select count(*) from lesson_notices) = 0, '다른 학생 수업 변경 불가, 운영 함수 불가, 안내 기록도 못 봄');
set request.jwt.claim.sub = 'bbbbbbbb-0000-0000-0000-000000001700';   -- 변경A 본인
select pg_temp.ok((select (student_change_lesson(gen_random_uuid(), '77777777-1700-0000-0000-000000000004', true) ->> 'status') = 'Student canceled late'),
  '학생 본인도 같은 함수로 판정 (지금 시각 기준)');
reset request.jwt.claim.sub;
reset role;

-- ---------- 2순위 강사 휴무·대체강사 (migration 1800, A41·A20, 2026-10-27 시안 Q1·Q2 = A) ----------
-- 가상 강사 휴무A(휴무)·휴무B(대체 가능)·휴무C(한 날짜 다른 수업), 학생 '휴무학생' 4주·주2회·40분
-- 휴무 기간 d0~d0+6: 정규 수업 d0+1·d0+3·d0+5 20:00 + 시트 휴가 보강 d0+2(고정 요일 20:00)
reset role;
create temp table lv (d0 date);
insert into lv values (current_date + 10);
grant select on lv to authenticated;
create or replace function pg_temp.kst(days int, hhmm text) returns timestamptz language sql as $$
  select ((select d0 from lv) + days + hhmm::time) at time zone 'Asia/Seoul' $$;
insert into tutors (id, name, country, timezone, meet_url) values   -- 대체강사 확정에는 Meet 회의실 링크가 필요 (R-05, 4520)
  ('55555555-0000-0000-0000-00000000180a', '휴무A', 'Korea', 'Asia/Seoul', 'https://meet.google.com/aaa-bbbb-ccc'),
  ('55555555-0000-0000-0000-00000000180b', '휴무B', 'Korea', 'Asia/Seoul', 'https://meet.google.com/bbb-cccc-ddd'),
  ('55555555-0000-0000-0000-00000000180c', '휴무C', 'Korea', 'Asia/Seoul', 'https://meet.google.com/ccc-dddd-eee');
select pg_temp.open_all('55555555-0000-0000-0000-00000000180a');
select pg_temp.open_all('55555555-0000-0000-0000-00000000180b');
select pg_temp.open_all('55555555-0000-0000-0000-00000000180c');
insert into students (id, name_ko, name_en) values ('99999999-0000-0000-0000-000000001800', '휴무학생', 'Leave S'),
                                                   ('99999999-0000-0000-0000-000000001801', '휴무다른', 'Leave O');
insert into enrollments (id, student_id, seq, weeks, weekly_count, duration_min, start_date, base_end_date, lessons_purchased, status)
select '99999999-1000-0000-0000-000000001800'::uuid, '99999999-0000-0000-0000-000000001800'::uuid, 1, 4, 2, 40, d0 - 7, d0 - 7 + 27, 8, 'active' from lv
union all
select '99999999-1000-0000-0000-000000001801', '99999999-0000-0000-0000-000000001801', 1, 4, 2, 40, d0 - 7, d0 - 7 + 27, 8, 'active' from lv;
insert into lessons (id, enrollment_id, student_id, tutor_id, kind, seq, starts_at, ends_at)
select ('77777777-1800-0000-0000-00000000000' || n)::uuid, '99999999-1000-0000-0000-000000001800', '99999999-0000-0000-0000-000000001800',
       '55555555-0000-0000-0000-00000000180a', 'regular', n, pg_temp.kst(n, '20:00'), pg_temp.kst(n, '20:40')
from (values (1), (3), (5)) v(n);
-- 휴무C는 d0+3 20:00에 다른 학생 수업
insert into lessons (enrollment_id, student_id, tutor_id, kind, seq, starts_at, ends_at)
values ('99999999-1000-0000-0000-000000001801', '99999999-0000-0000-0000-000000001801', '55555555-0000-0000-0000-00000000180c', 'regular', 1,
        pg_temp.kst(3, '20:00'), pg_temp.kst(3, '20:40'));
insert into regular_schedules (student_id, tutor_id, weekday, start_time_kst, duration_min, effective_from)
select '99999999-0000-0000-0000-000000001800', '55555555-0000-0000-0000-00000000180a', extract(dow from d0 + 2), '20:00', 40, d0 - 7 from lv;
insert into migrated_items (id, enrollment_id, kind, original_date, tutor_leave)
select '99999999-4000-0000-0000-000000001800', '99999999-1000-0000-0000-000000001800', 'makeup_open', d0 + 2, true from lv;
create or replace function pg_temp.li(days int) returns uuid language sql as $$
  select i.id from leave_items i where i.student_id = '99999999-0000-0000-0000-000000001800' and i.starts_at = pg_temp.kst(days, '20:00') $$;
create or replace function pg_temp.lst(days int) returns text language sql as $$
  select i.choice || ':' || coalesce(i.sub_stage, '-') || ':' || l.state || ':' || coalesce(l.class_status::text, '-') || ':' || t.name
  from leave_items i join lessons l on l.id = coalesce(i.lesson_id, i.sub_lesson_id) join tutors t on t.id = l.tutor_id
  where i.id = pg_temp.li(days) $$;
set role authenticated;
set request.jwt.claim.sub = 'bbbbbbbb-0000-0000-0000-000000000009';   -- 대표 (aal2)

-- 1) 미리 보기: 수업 3 + 시트 휴가 보강 1, 학생 1명. 아무것도 안 바뀜
select pg_temp.ok((select (r ->> 'lessons')::int = 3 and (r ->> 'items')::int = 4 and (r ->> 'students')::int = 1
                   from admin_leave_create('55555555-0000-0000-0000-00000000180a', (select d0 from lv), (select d0 + 6 from lv), '개인 휴가', true) r)
              and (select count(*) from leave_items) = 0
              and (select count(*) from tutor_time_off where tutor_id = '55555555-0000-0000-0000-00000000180a') = 0,
  '휴무 미리 보기: 걸리는 수업 3 + 시트 휴가 보강 1 · 학생 1명, 저장은 안 함');
-- 2) 넣기: 휴무 기록 + 목록 (수업·시트 휴가 보강 모두 '학생 선택 미확인') + 학생에게 두 가지 선택 안내, 다시 실행해도 그대로
select admin_leave_create('55555555-0000-0000-0000-00000000180a', (select d0 from lv), (select d0 + 6 from lv), '개인 휴가', false);
select admin_leave_create('55555555-0000-0000-0000-00000000180a', (select d0 from lv), (select d0 + 6 from lv), '개인 휴가', false);
select pg_temp.ok((select count(*) from tutor_time_off where tutor_id = '55555555-0000-0000-0000-00000000180a' and kind = 'leave') = 1
              and (select array_agg(choice order by starts_at) from leave_items) = '{undecided,undecided,undecided,undecided}'
              and (select starts_at = pg_temp.kst(2, '20:00') and ends_at = pg_temp.kst(2, '20:40') from leave_items where migrated_item_id is not null)
              and (select count(*) from lesson_notices where event = 'leave_options' and status = 'pending' and recipient_kind = 'student') = 4,
  '휴무 넣기: 휴무 1건 + 목록 4줄(시트 휴가 보강도 불러오기만으로 기존 강사 보강을 고른 것으로 보지 않음) + 두 가지 선택 안내, 두 번 눌러도 한 번');
-- 3) 대체강사 목록: 휴무B 4회 모두 가능, 휴무C 3회(d0+3 겹침), 휴무인 강사는 목록에 없음
select pg_temp.ok((select free = 4 and busy_dates = '{}' from admin_leave_sub_options(array(select id from leave_items)) where name = '휴무B')
              and (select free = 3 and cardinality(busy_dates) = 1 from admin_leave_sub_options(array(select id from leave_items)) where name = '휴무C')
              and not exists (select 1 from admin_leave_sub_options(array(select id from leave_items)) where name = '휴무A'),
  '대체강사 목록: 비어 있는 횟수와 겹치는 날짜, 휴무 강사는 빠짐');
-- 4) 겹치는 강사로 한 번에 고르면 전체 거절 (일부만 바뀌지 않음)
select pg_temp.expect_error($$select admin_leave_choose(array(select id from leave_items), 'substitute', '55555555-0000-0000-0000-00000000180c')$$, '겹칩니다');
select pg_temp.ok((select count(*) from leave_items where choice = 'substitute') = 0, '대체강사 시간이 하나라도 겹치면 아무것도 안 바뀜');
-- 5) 일부 날짜만 대체강사(Q1 A): 가능 확인 안내만, 수업 강사는 아직 그대로
select admin_leave_choose(array[pg_temp.li(1), pg_temp.li(2)], 'substitute', '55555555-0000-0000-0000-00000000180b');
select pg_temp.ok(pg_temp.lst(1) = 'substitute:asked:scheduled:-:휴무A'
              and (select count(*) from lesson_notices where leave_item_id is not null and event = 'sub_ask' and status = 'pending'
                   and recipient_id = '55555555-0000-0000-0000-00000000180b') = 2,
  '대체강사 고름: 대체강사에게 가능 확인 안내 2건, 수업 강사는 아직 원래 강사');
-- 6) 학생 OK 전에는 확정 안 됨 (Q2 A): 강사 가능 → 학생 안내 → 학생 OK → 확정
select pg_temp.expect_error($$select admin_leave_student_ok(array[pg_temp.li(1)])$$, '가능하다고 한 뒤');
select admin_leave_sub_ok(array[pg_temp.li(1), pg_temp.li(2)]);
select pg_temp.ok(pg_temp.lst(1) = 'substitute:tutor_ok:scheduled:-:휴무A'
              and (select array_agg(event || ':' || status order by event) from lesson_notices where leave_item_id = pg_temp.li(1)) = '{leave_options:pending,sub_ask:sent,sub_student:pending}',
  '대체강사 가능: 가능 확인 안내는 보냄, 학생 안내 생김(휴무 안내와 함께 2단계 글), 아직 확정 아님 (2500: 운영진이 고른 건 학생 답이 아님)');
select admin_leave_student_ok(array[pg_temp.li(1), pg_temp.li(2)]);
select admin_leave_student_ok(array[pg_temp.li(1), pg_temp.li(2)]);
select pg_temp.ok(pg_temp.lst(1) = 'substitute:confirmed:scheduled:-:휴무B'
              and (select original_tutor_id = '55555555-0000-0000-0000-00000000180a' from lessons where id = '77777777-1800-0000-0000-000000000001')
              and pg_temp.lst(2) = 'substitute:confirmed:scheduled:-:휴무B'
              and (select kind = 'makeup_booked' from migrated_items where id = '99999999-4000-0000-0000-000000001800')
              and (select count(*) from lessons where student_id = '99999999-0000-0000-0000-000000001800' and state = 'scheduled') = 4
              and (select array_agg(event || ':' || status order by event) from lesson_notices where leave_item_id = pg_temp.li(1))
                  = '{leave_options:sent,sub_ask:sent,sub_confirmed:pending,sub_confirmed:pending,sub_student:sent}',
  '학생 OK → 확정: 그 수업 강사가 대체강사(원래 강사 기록), 시트 휴가 보강은 원래 시각 대체 수업으로 예약됨, 최종 확정 안내는 학생·강사 둘, 두 번 눌러도 한 번');
-- 7) 기다림: 수업 결과 '강사 장기 휴식', 변경권 차감 없음, 보강은 종료일 뒤도 가능 → 마지막 보강일까지만 연장
select admin_leave_choose(array[pg_temp.li(3), pg_temp.li(5)], 'wait', null);
select pg_temp.ok(pg_temp.lst(5) = 'wait:-:canceled:Tutor long-term leave:휴무A'
              and not exists (select 1 from credit_ledger where lesson_id = '77777777-1800-0000-0000-000000000005'),
  '기다림: 수업은 강사 장기 휴식으로 취소, 변경권 그대로');
select pg_temp.ok((select status = 'pending' from lesson_notices where leave_item_id = pg_temp.li(5) and event = 'leave_options'),
  '운영진이 대체 강사 없음 → 보강으로 골라도 휴무 안내는 아직 안 보냄 (2단계 글로 보냄, 2500)');
select admin_leave_choose(array[pg_temp.li(3)], 'substitute', '55555555-0000-0000-0000-00000000180b');
select admin_leave_choose(array[pg_temp.li(3)], 'wait', null);
select pg_temp.ok((select array_agg(event || ':' || status order by event) from lesson_notices where leave_item_id = pg_temp.li(3)) = '{leave_options:pending,sub_ask:not_needed}',
  '1단계에서 대체강사 → 보강으로 바꿔도 휴무 안내(2단계 글)는 남음, 대체강사 묻기만 보낼 필요 없음 (2500)');
-- 강사 화면 대체 요청 답 (2600): 불가 → 다시 고르기 필요 + 그 강사는 목록에서 불가 / 가능 → 학생에게 제안할 수 있게
select admin_leave_choose(array[pg_temp.li(3)], 'substitute', '55555555-0000-0000-0000-00000000180b');
select pg_temp.ok((select jsonb_array_length(tutor_screen('55555555-0000-0000-0000-00000000180b', current_date, current_date) -> 'covers') = 1),
  '대체강사 화면에 대체 수업 요청 1건 (2600)');
select tutor_sub_answer(array[pg_temp.li(3)], '{}');
select pg_temp.ok((select choice = 'undecided' and sub_tutor_id is null and '55555555-0000-0000-0000-00000000180b' = any(sub_declined) from leave_items where id = pg_temp.li(3))
              and (select free = 0 from admin_leave_sub_options(array[pg_temp.li(3)]) where name = '휴무B')
              and (select status = 'not_needed' from lesson_notices where leave_item_id = pg_temp.li(3) and event = 'sub_ask' order by created_at desc limit 1),
  '강사가 불가: 다시 대체 강사 고르기 필요, 그 강사는 목록에서 불가, WhatsApp으로 물어볼 글은 보낼 필요 없음 (2600)');
select admin_leave_choose(array[pg_temp.li(3)], 'substitute', '55555555-0000-0000-0000-00000000180b');
select tutor_sub_answer(array[pg_temp.li(3)], array[pg_temp.li(3)]);
select pg_temp.ok((select sub_stage = 'tutor_ok' from leave_items where id = pg_temp.li(3))
              and exists (select 1 from lesson_notices where leave_item_id = pg_temp.li(3) and event = 'sub_student' and status = 'pending'),
  '강사가 가능: 강사 가능 상태 + 학생에게 제안할 글 생김 (2600)');
select pg_temp.expect_error($$select tutor_sub_answer(array[pg_temp.li(3)], '{}')$$, 'closed');
select admin_leave_choose(array[pg_temp.li(3)], 'wait', null);
create temp table lmk as select (admin_makeup_request('77777777-1800-0000-0000-000000000005', null,
  jsonb_build_array(jsonb_build_object('starts_at', pg_temp.kst(23, '20:00'))), now()) ->> 'makeup_request_id')::uuid as id;
select admin_makeup_confirm((select id from lmk), pg_temp.kst(23, '20:00'));
select pg_temp.ok((select final_end_date = (select d0 + 23 from lv) from enrollments where id = '99999999-1000-0000-0000-000000001800'),
  '기다린 보강이 종료일 3일 뒤로 확정 → 종료일이 그 보강일까지만 늘어남 (A20)');
reset role;
select pg_temp.ok(lms_is_leave_postponed((select r.confirmed_lesson_id from makeup_requests r join lmk on lmk.id = r.id))
              and (select lms_next_regular_from('99999999-1000-0000-0000-000000001800') is null),
  '휴무로 미뤄진 수업 (2750): 휴무 보강으로 잡은 수업은 휴무로 미뤄진 수업, 날짜 안 잡은 것이 남으면 다음 정규 시작일 미정');
set role authenticated;
set request.jwt.claim.sub = 'bbbbbbbb-0000-0000-0000-000000000009';
select admin_void_makeup((select r.confirmed_lesson_id from makeup_requests r join lmk on lmk.id = r.id), '날짜 다시');
select pg_temp.ok((select final_end_date = (select d0 + 23 from lv) from enrollments where id = '99999999-1000-0000-0000-000000001800')
              and (select array_agg(days order by created_at, days) from enrollment_extensions where enrollment_id = '99999999-1000-0000-0000-000000001800') = '{3}',
  '그 보강을 없애도 늘어난 종료일은 줄이지 않음 (H26(94) 자동 단축 없음, 20261108030000)');
-- 아래 시험이 원래 종료일(d0+20) 기준이라 운영진 정정 줄로 되돌림 (화면의 '종료일 연장 · 정정'과 같은 기록)
reset role;
insert into enrollment_extensions (enrollment_id, days, reason, note, approved_by)
values ('99999999-1000-0000-0000-000000001800', -3, 'correction', '시험: 아래 시험을 위해 원래 종료일로', 'aaaaaaaa-0000-0000-0000-000000000001');
set role authenticated;
set request.jwt.claim.sub = 'bbbbbbbb-0000-0000-0000-000000000009';
-- 7-2) 기존 강사 보강 후보: 강사 복귀 뒤 ~ 종료일 사이 평소 시각(정규 요일 빼고) 먼저, 종료일 뒤 평소 요일·시간은 필요한 수만큼
select pg_temp.ok((select count(*) from admin_leave_makeup_options(array[pg_temp.li(5)]) where section = 'in_period') = 12
              and (select count(*) from admin_leave_makeup_options(array[pg_temp.li(5)]) where section = 'after_end') = 1
              and (select (starts_at at time zone 'Asia/Seoul')::date > (select d0 + 20 from lv)
                          and extract(dow from starts_at at time zone 'Asia/Seoul') = extract(dow from (select d0 + 2 from lv))
                          and to_char(starts_at at time zone 'Asia/Seoul', 'HH24:MI') = '20:00'
                   from admin_leave_makeup_options(array[pg_temp.li(5)]) where section = 'after_end'),
  '보강 후보: 수강기간 안 12개(휴무 끝난 뒤, 평소 시각, 정규 요일 제외) + 종료일 뒤 평소 요일·시간 1개(필요한 수)');
-- 8) 대체강사 확정 → 기다림으로 바꾸기: 원래 강사로 되돌린 뒤 취소, 안 보낸 안내는 보낼 필요 없음
select admin_leave_choose(array[pg_temp.li(1)], 'wait', null);
select pg_temp.ok(pg_temp.lst(1) = 'wait:-:canceled:Tutor long-term leave:휴무A'
              and (select original_tutor_id is null from lessons where id = '77777777-1800-0000-0000-000000000001')
              and (select array_agg(event || ':' || status order by event) from lesson_notices where leave_item_id = pg_temp.li(1))
                  = '{leave_options:sent,sub_ask:sent,sub_confirmed:not_needed,sub_confirmed:not_needed,sub_student:sent}',
  '대체 확정 뒤 기다림으로: 원래 강사 수업으로 되돌려 휴식 처리, 안 보낸 확정 안내는 보낼 필요 없음');
-- 9) 기다림 → 대체강사: 수업 다시 예정으로 + 가능 확인. 보강 신청이 있으면 거절
select admin_leave_choose(array[pg_temp.li(3)], 'substitute', '55555555-0000-0000-0000-00000000180b');
select pg_temp.ok(pg_temp.lst(3) = 'substitute:asked:scheduled:-:휴무A', '기다림에서 대체강사로: 수업 다시 예정, 가능 확인부터');
select admin_makeup_request('77777777-1800-0000-0000-000000000001', null, jsonb_build_array(jsonb_build_object('starts_at', pg_temp.kst(12, '20:00'))), now());
select pg_temp.expect_error($$select admin_leave_choose(array[pg_temp.li(1)], 'substitute', '55555555-0000-0000-0000-00000000180b')$$, '보강부터 정리');
select pg_temp.ok(true, '보강 신청이 있는 기다림 수업은 대체강사로 못 바꿈');
-- 9-2) 이전 단계로 되돌리기 (2026-10-27 대표): 확정 전 → 강사 답 전 → 학생 답 전, 다시 해도 같은 안내 중복 없음
select admin_leave_sub_ok(array[pg_temp.li(3)]);
select admin_leave_student_ok(array[pg_temp.li(3)]);
select admin_leave_back(array[pg_temp.li(3)], 'tutor_ok');
select pg_temp.ok(pg_temp.lst(3) = 'substitute:tutor_ok:scheduled:-:휴무A'
              and (select original_tutor_id is null from lessons where id = '77777777-1800-0000-0000-000000000003'),
  '확정 전으로: 수업 강사가 원래 강사로, 학생 OK 대기');
select admin_leave_student_ok(array[pg_temp.li(3)]);
select admin_leave_back(array[pg_temp.li(3)], 'asked');
select admin_leave_sub_ok(array[pg_temp.li(3)]);
select pg_temp.ok(pg_temp.lst(3) = 'substitute:tutor_ok:scheduled:-:휴무A'
              and (select count(*) from lesson_notices where leave_item_id = pg_temp.li(3) and event = 'sub_student' and status <> 'not_needed') = 1,
  '확정 → 강사 답 전 → 다시 가능: 학생 안내는 하나만');
select admin_leave_back(array[pg_temp.li(3)], 'undecided');
select pg_temp.ok((select choice = 'undecided' and sub_tutor_id is null from leave_items where id = pg_temp.li(3))
              and (select state = 'scheduled' and tutor_id = '55555555-0000-0000-0000-00000000180a' from lessons where id = '77777777-1800-0000-0000-000000000003')
              and not exists (select 1 from lesson_notices where leave_item_id = pg_temp.li(3) and status = 'pending'),
  '학생 답 전으로: 미확인, 수업은 원래 강사 그대로, 안 보낸 안내 없음');
select admin_leave_choose(array[pg_temp.li(3)], 'substitute', '55555555-0000-0000-0000-00000000180b');
select pg_temp.ok((select count(*) from lesson_notices where leave_item_id = pg_temp.li(3) and event = 'sub_ask' and status <> 'not_needed') = 1,
  '같은 대체강사를 다시 골라도 가능 확인 안내는 하나');
select admin_mark_lesson_notice_sent((select id from lesson_notices where leave_item_id = pg_temp.li(3) and event = 'sub_ask' and status = 'pending'));
select admin_leave_notice_unsend(array(select id from lesson_notices where leave_item_id = pg_temp.li(3) and event = 'sub_ask' and status = 'sent'));
select pg_temp.ok((select status = 'pending' and sent_at is null from lesson_notices where leave_item_id = pg_temp.li(3) and event = 'sub_ask' and status <> 'not_needed'),
  '보냄 되돌리기: 안 보냄으로');
select pg_temp.expect_error($$select admin_leave_notice_unsend(array(select id from lesson_notices where leave_item_id = pg_temp.li(1) and event = 'leave_options'))$$, '다음 단계');
select pg_temp.expect_error($$select admin_leave_back(array[pg_temp.li(1)], 'undecided')$$, '보강부터 정리');
select pg_temp.ok(true, '보강 신청이 있는 수업의 2단계 글(휴무 안내)은 못 되돌림 · 보강 신청이 있는 기다림 수업은 학생 답 전으로 못 돌림');
-- 9-2b) 휴무 처리 밖에서 수업이 취소되면 휴무 줄에 표시, 되살리면 지움 (3200, R5). 휴무 처리 자체의 취소('Tutor long-term leave')는 아님
reset role;
update lessons set state = 'canceled', class_status = 'Student canceled in advance', canceled_at = now() where id = '77777777-1800-0000-0000-000000000003';
select pg_temp.ok((select lesson_gone_at is not null from leave_items where id = pg_temp.li(3)), '학생 취소: 휴무 줄에 취소 표시');
update lessons set state = 'scheduled', class_status = null, canceled_at = null where id = '77777777-1800-0000-0000-000000000003';
select pg_temp.ok((select lesson_gone_at is null from leave_items where id = pg_temp.li(3)), '취소 되돌리기: 표시 지움');
update lessons set state = 'canceled', class_status = 'Tutor long-term leave', canceled_at = now() where id = '77777777-1800-0000-0000-000000000003';
select pg_temp.ok((select lesson_gone_at is null from leave_items where id = pg_temp.li(3)), '휴무 처리 취소(기존 강사와 보강)는 밖에서 취소 아님');
update lessons set state = 'scheduled', class_status = null, canceled_at = null where id = '77777777-1800-0000-0000-000000000003';
set role authenticated;
set request.jwt.claim.sub = 'bbbbbbbb-0000-0000-0000-000000000009';
-- 9-2c) 여러 안내를 한 번에 보냄 → 보낸 시각이 같음 (3300, 대표 10/30: 보낸 문의 원문·번호 고정) · 학생 화면 '일정 조율 중' 표시
select admin_mark_lesson_notices_sent(array(select id from lesson_notices where leave_item_id in (pg_temp.li(3), pg_temp.li(5)) and status = 'pending'));
select pg_temp.ok((select count(distinct sent_at) = 1 and count(*) >= 1 from lesson_notices where leave_item_id in (pg_temp.li(3), pg_temp.li(5)) and status = 'sent' and sent_by is not null
                   and sent_at = (select max(sent_at) from lesson_notices)),
  '한 번에 보낸 안내는 보낸 시각이 같음');
select pg_temp.ok((select bool_or((l ->> 'leave_open')::boolean) from jsonb_array_elements(student_screen('99999999-0000-0000-0000-000000001800') -> 'lessons') l
                   where l ->> 'id' = '77777777-1800-0000-0000-000000000003'),
  '대체강사 확정 전 수업은 학생 화면에 일정 조율 중 (leave_open)');
select pg_temp.ok((select bool_or((l ->> 'leave_open')::boolean) from jsonb_array_elements(tutor_screen((select tutor_id from lessons where id = '77777777-1800-0000-0000-000000000003'), current_date - 30, current_date + 60) -> 'lessons') l
                   where l ->> 'id' = '77777777-1800-0000-0000-000000000003'),
  '같은 수업이 휴무 강사 화면에도 휴무 처리 중 (leave_open, 3500)');
select pg_temp.ok((select jsonb_typeof(student_screen('99999999-0000-0000-0000-000000001800') -> 'leave_pending') = 'array'),
  '학생 화면에 수업 줄 없는 휴무 처리 수업 목록 (leave_pending, 3700)');
-- 9-2d) 보낸 안내가 '보낼 필요 없음'이 돼도 보낸 시각을 남김, 보냄 되돌리기는 남기지 않음 (3400)
select pg_temp.ok((select count(*) = 1 from lesson_notices where leave_item_id = pg_temp.li(3) and event = 'sub_ask' and status = 'sent'), '(준비) 보낸 문의 1건');
select admin_leave_back(array[pg_temp.li(3)], 'undecided');
select pg_temp.ok((select count(*) >= 1 from lesson_notices where leave_item_id = pg_temp.li(3) and event = 'sub_ask' and status = 'not_needed' and was_sent_at is not null),
  '다시 고르기 뒤에도 보낸 문의의 보낸 시각이 남음');
select admin_leave_choose(array[pg_temp.li(3)], 'substitute', '55555555-0000-0000-0000-00000000180b');
-- 9-3) 재등록 대기 학생: 고정 시간을 맡아 두는 동안(종료일 23:59까지)만, 종료일 뒤 ~ 휴무 끝 사이 평소 요일·시간
reset role;
insert into students (id, name_ko, name_en) values ('99999999-0000-0000-0000-000000001802', '휴무재등록', 'Leave R');
insert into enrollments (id, student_id, seq, weeks, weekly_count, duration_min, start_date, base_end_date, lessons_purchased, status)
select '99999999-1000-0000-0000-000000001802', '99999999-0000-0000-0000-000000001802', 1, 4, 1, 40, d0 - 25, d0 + 2, 4, 'active' from lv;
insert into regular_schedules (student_id, tutor_id, weekday, start_time_kst, duration_min, effective_from)
select '99999999-0000-0000-0000-000000001802', '55555555-0000-0000-0000-00000000180a', extract(dow from d0 + 4), '18:00', 40, d0 - 25 from lv;
set role authenticated;
set request.jwt.claim.sub = 'bbbbbbbb-0000-0000-0000-000000000009';
select pg_temp.ok((select array_agg((starts_at at time zone 'Asia/Seoul')::date) from admin_leave_renewal_pending(
                     (select id from tutor_time_off where tutor_id = '55555555-0000-0000-0000-00000000180a' and kind = 'leave' order by starts_at limit 1))
                   where student_name = '휴무재등록') = array[(select d0 + 4 from lv)],
  '재등록 대기: 종료일(휴무 3일째) 뒤 휴무 기간의 평소 요일 하루만');
-- 10) 휴무인 강사로는 보강 확정 안 됨 (기존 확인 그대로)
select pg_temp.expect_error($$select admin_makeup_confirm((select id from makeup_requests where source_lesson_id = '77777777-1800-0000-0000-000000000001' and status = 'requested'), pg_temp.kst(4, '21:00'))$$, '강사 휴무');
select pg_temp.ok(true, '휴무 기간에는 원래 강사로 보강 확정 거절');
-- 10-2) 미확인 시트 휴가 보강에 보강 신청이 들어오면 = 학생이 기존 강사 보강을 고름
reset role;
insert into migrated_items (id, enrollment_id, kind, original_date, tutor_leave)
select '99999999-4000-0000-0000-000000001801', '99999999-1000-0000-0000-000000001800', 'makeup_open', d0 + 9, true from lv;
set role authenticated;
set request.jwt.claim.sub = 'bbbbbbbb-0000-0000-0000-000000000009';
select admin_leave_create('55555555-0000-0000-0000-00000000180a', (select d0 + 9 from lv), (select d0 + 9 from lv), null, false);
select pg_temp.ok((select choice = 'undecided' from leave_items where migrated_item_id = '99999999-4000-0000-0000-000000001801'),
  '두 번째 휴무의 시트 휴가 보강도 학생 선택 미확인');
select admin_makeup_request(null, '99999999-4000-0000-0000-000000001801', jsonb_build_array(jsonb_build_object('starts_at', pg_temp.kst(15, '20:00'))), now());
select pg_temp.ok((select i.choice = 'wait' and n.status = 'sent' from leave_items i join lesson_notices n on n.leave_item_id = i.id and n.event = 'leave_options'
                   where i.migrated_item_id = '99999999-4000-0000-0000-000000001801'),
  '미확인 시트 휴가 보강에 보강 신청 → 기존 강사 보강을 고른 것으로 기록, 선택 안내는 보낸 것');
-- 10-3) ③ 학생 LMS (2800): 학생이 휴무 안내에 직접 답하기 · 보강 날짜 고르기 · 본인 화면만
reset role;
insert into lessons (id, enrollment_id, student_id, tutor_id, kind, seq, starts_at, ends_at)
values ('77777777-1800-0000-0000-000000000004', '99999999-1000-0000-0000-000000001800', '99999999-0000-0000-0000-000000001800',
        '55555555-0000-0000-0000-00000000180a', 'regular', 4, pg_temp.kst(4, '20:00'), pg_temp.kst(4, '20:40'));
set role authenticated;
set request.jwt.claim.sub = 'bbbbbbbb-0000-0000-0000-000000000009';
select admin_leave_create('55555555-0000-0000-0000-00000000180a', (select d0 from lv), (select d0 + 6 from lv), '개인 휴가', false);
select admin_leave_choose(array[pg_temp.li(4)], 'substitute', '55555555-0000-0000-0000-00000000180b');
create temp table sli as select pg_temp.li(4) as id;
reset role;
insert into app_users (auth_user_id, role, student_id) values ('bbbbbbbb-0000-0000-0000-000000001800', 'student', '99999999-0000-0000-0000-000000001800');
set role authenticated;
set request.jwt.claim.sub = 'bbbbbbbb-0000-0000-0000-000000001800';
select pg_temp.ok(not exists (select 1 from jsonb_array_elements(student_screen(null) -> 'leave') x where (x ->> 'id')::uuid = (select id from sli)),
  '학생 화면: 대체강사에게 묻는 중인 수업은 아직 안 보임');
select pg_temp.expect_error($$select student_leave_answer(array[(select id from sli)], 'ok')$$, '이미 정해졌거나');
set request.jwt.claim.sub = 'bbbbbbbb-0000-0000-0000-000000000009';
select admin_leave_sub_ok(array[(select id from sli)]);
set request.jwt.claim.sub = 'bbbbbbbb-0000-0000-0000-000000001800';
select pg_temp.ok((select x ->> 'stage' = 'tutor_ok' and x ->> 'sub_tutor' = '휴무B' from jsonb_array_elements(student_screen(null) -> 'leave') x where (x ->> 'id')::uuid = (select id from sli)),
  '학생 화면: 대체강사가 가능하다고 한 수업은 대체강사 이름과 함께 보임');
select pg_temp.expect_error($$select student_screen('99999999-0000-0000-0000-000000001802')$$, '42501');
select pg_temp.expect_error($$select admin_leave_choose(array[(select id from sli)], 'wait', null)$$, '42501');
select student_leave_answer(array[(select id from sli)], 'makeup');
select pg_temp.ok(exists (select 1 from jsonb_array_elements(student_screen(null) -> 'makeup_rights') x where x ->> 'lesson_id' = '77777777-1800-0000-0000-000000000004'),
  '학생이 기존 강사님과 보강: 운영진 화면과 같은 처리(강사 장기 휴식), 보강할 수업에 들어감');
select pg_temp.expect_error($$select student_leave_answer(array[(select id from sli)], 'ok')$$, '이미 정해졌거나');
reset role;
select pg_temp.ok(not exists (select 1 from lesson_notices where leave_item_id = (select id from sli) and status = 'pending' and recipient_kind = 'student'),
  '학생이 LMS에서 답하면 학생에게 보낼 카톡(휴무 안내·확정 안내)은 남지 않음');
set role authenticated;
set request.jwt.claim.sub = 'bbbbbbbb-0000-0000-0000-000000001800';
select pg_temp.ok((select count(*) from student_makeup_options(null, '77777777-1800-0000-0000-000000000004', null)) > 0, '학생 보강 가능한 날짜가 나옴');
select pg_temp.expect_error($$select student_makeup_request('77777777-1800-0000-0000-000000000004', null, jsonb_build_array(jsonb_build_object('starts_at', pg_temp.kst(4, '03:00'))))$$, '보강 가능한 날짜가 아닙니다');
select pg_temp.expect_error($$select student_makeup_request('77777777-1800-0000-0000-000000000004', null, (select jsonb_agg(jsonb_build_object('starts_at', o.starts_at)) from (select starts_at from student_makeup_options(null, '77777777-1800-0000-0000-000000000004', null) limit 3) o))$$, '1~2개');
select student_makeup_request('77777777-1800-0000-0000-000000000004', null, (select jsonb_agg(jsonb_build_object('starts_at', o.starts_at)) from (select starts_at from student_makeup_options(null, '77777777-1800-0000-0000-000000000004', null) order by starts_at limit 2) o));
select pg_temp.ok((select x ->> 'status' = 'requested' and jsonb_array_length(x -> 'candidates') = 2 from jsonb_array_elements(student_screen(null) -> 'makeup_requests') x where x ->> 'lesson_id' = '77777777-1800-0000-0000-000000000004'),
  '학생 보강 신청: 고른 날짜 2개로 신청됨(강사 확인 → 운영진 확정, 학생 신청만으로 확정 안 됨)');
reset role;
select pg_temp.ok(pg_temp.lst(4) = 'wait:-:canceled:Tutor long-term leave:휴무A', '학생 답 처리 결과는 운영진 기다림과 같음');
select pg_temp.expect_error($$select * from lms_makeup_source((select id from lessons where state = 'scheduled' and class_status is null limit 1), null)$$, '보강을 받을 수 있는 수업이 아닙니다');
select pg_temp.ok(true, '아직 안 한 수업(결과 없음)으로는 보강 신청 안 됨 (2800 고침)');
select pg_temp.ok((select via = 'student_app' from makeup_requests where source_lesson_id = '77777777-1800-0000-0000-000000000004' and status = 'requested')
              and exists (select 1 from lesson_notices n join makeup_requests r on r.id = n.makeup_request_id where r.source_lesson_id = '77777777-1800-0000-0000-000000000004' and n.event = 'makeup_ask'),
  '학생 신청은 학생 앱 신청으로 기록, 강사 보강 요청 생김');
set role authenticated;
set request.jwt.claim.sub = 'bbbbbbbb-0000-0000-0000-000000000009';
select pg_temp.ok((student_screen('99999999-0000-0000-0000-000000001800') -> 'student' ->> 'id') = '99999999-0000-0000-0000-000000001800', '운영자는 학생 화면을 그대로 봄');
-- 11) 권한: 운영자만
set request.jwt.claim.sub = 'bbbbbbbb-0000-0000-0000-000000000001';
select pg_temp.expect_error($$select admin_leave_create('55555555-0000-0000-0000-00000000180a', current_date, current_date, null, true)$$, '42501');
select pg_temp.expect_error($$select admin_leave_choose(array[]::uuid[], 'wait', null)$$, '42501');
select pg_temp.ok((select count(*) from leave_items) = 0, '학생은 휴무 처리 함수를 못 쓰고 목록도 못 봄');
reset request.jwt.claim.sub;
reset role;

-- ---------- 종료 임박 재등록 안내 [보냄] 기록 (migration 1900) ----------
set role authenticated;
set request.jwt.claim.sub = 'bbbbbbbb-0000-0000-0000-000000000009';
create temp table rn_chk as select admin_renewal_notice_sent(e.id) as r1, e.id as eid from enrollments e join students s on s.id = e.student_id where s.name_ko = '확대A';
select pg_temp.expect_error($$select admin_enrollment_close((select eid from rn_chk))$$, '아직 끝나지');
select pg_temp.ok(true, '수강 종료: 수강기간이 안 끝났으면 거절 (3800)');
select pg_temp.ok((select jsonb_typeof(admin_task_history()) = 'array'), '처리 내역: 운영자는 읽을 수 있음 (3900)');
select pg_temp.ok((select admin_renewal_notice_sent(eid) ->> 'sent_at' = r1 ->> 'sent_at' from rn_chk)
                  and (select count(*) = 1 from renewal_notices r join rn_chk c on c.eid = r.enrollment_id and r.sent_by = 'bbbbbbbb-0000-0000-0000-000000000009'),
  '재등록 안내 보냄은 수강권마다 한 번 기록되고, 다시 눌러도 처음 시각 그대로');
select pg_temp.expect_error($$delete from renewal_notices$$, '');
set request.jwt.claim.sub = 'bbbbbbbb-0000-0000-0000-000000000001';
select pg_temp.expect_error($$select admin_renewal_notice_sent((select eid from rn_chk))$$, '42501');
select pg_temp.ok((select count(*) from renewal_notices) = 0, '학생은 재등록 안내 기록을 볼 수도 기록할 수도 없음');
reset request.jwt.claim.sub;
reset role;

-- ---------- ② 강사 LMS: 수업 일정 · Class Record 입력 · 보강 가능 여부 답 (migration 2000) ----------
-- 강사 기록A(본인)·기록B(다른 강사), 학생 '기록학생' 4주·주2회·40분
-- 수업: 1 지난 정규 · 2 내일 정규 · 3 지난 보강(원래 0 강사 정상 취소) · 4 지난 정규(대체 진행) · 5 학생 정상 취소(보강 신청용) · 6 지난 정규(정산 들어감)
reset role;
insert into tutors (id, name, country, timezone) values
  ('55555555-0000-0000-0000-00000000200a', '기록A', 'Australia', 'Australia/Sydney'),
  ('55555555-0000-0000-0000-00000000200b', '기록B', 'Korea', 'Asia/Seoul');
insert into app_users (auth_user_id, role, tutor_id) values
  ('bbbbbbbb-0000-0000-0000-00000000200a', 'tutor', '55555555-0000-0000-0000-00000000200a'),
  ('bbbbbbbb-0000-0000-0000-00000000200b', 'tutor', '55555555-0000-0000-0000-00000000200b');
select pg_temp.open_all('55555555-0000-0000-0000-00000000200a');   -- 4500: 보강 답·확정은 강사가 연 시간만
insert into students (id, name_ko, name_en, class_note_url) values ('99999999-0000-0000-0000-000000002000', '기록학생', 'Record S', 'https://docs.google.com/x');
insert into enrollments (id, student_id, seq, weeks, weekly_count, duration_min, start_date, base_end_date, lessons_purchased, status)
values ('99999999-1000-0000-0000-000000002000', '99999999-0000-0000-0000-000000002000', 1, 4, 2, 40, current_date - 10, current_date - 10 + 27, 8, 'active');
create temp table rc (t timestamptz);
insert into rc values (date_trunc('hour', now()));
grant select on rc to authenticated;
insert into lessons (id, enrollment_id, student_id, tutor_id, original_tutor_id, kind, seq, starts_at, ends_at, state, class_status, canceled_at, makeup_of)
select v.id::uuid, '99999999-1000-0000-0000-000000002000', '99999999-0000-0000-0000-000000002000', '55555555-0000-0000-0000-00000000200a',
       v.orig::uuid, v.kind, v.seq, t + v.off, t + v.off + interval '40 minutes', v.state, v.st::class_status,
       case when v.state = 'canceled' then now() end, v.mo::uuid
from rc, (values
  ('77777777-2000-0000-0000-000000000000', null, 'regular', 1, interval '-5 days', 'canceled', 'Tutor canceled in advance', null),
  ('77777777-2000-0000-0000-000000000001', null, 'regular', 2, interval '-3 hours', 'scheduled', null, null),
  ('77777777-2000-0000-0000-000000000002', null, 'regular', 3, interval '1 day', 'scheduled', null, null),
  ('77777777-2000-0000-0000-000000000004', '55555555-0000-0000-0000-00000000200b', 'regular', 4, interval '-2 days', 'scheduled', null, null),
  ('77777777-2000-0000-0000-000000000005', null, 'regular', 5, interval '-4 days', 'canceled', 'Student canceled in advance', null),
  ('77777777-2000-0000-0000-000000000006', null, 'regular', 6, interval '-6 days', 'scheduled', null, null)
) v(id, orig, kind, seq, off, state, st, mo);
insert into lessons (id, enrollment_id, student_id, tutor_id, kind, starts_at, ends_at, makeup_of)
select '77777777-2000-0000-0000-000000000003', '99999999-1000-0000-0000-000000002000', '99999999-0000-0000-0000-000000002000',
       '55555555-0000-0000-0000-00000000200a', 'makeup', t - interval '1 day', t - interval '1 day' + interval '40 minutes', '77777777-2000-0000-0000-000000000000' from rc;
insert into payroll_runs (id, tutor_id, month) values ('99999999-5000-0000-0000-000000002000', '55555555-0000-0000-0000-00000000200a', date_trunc('month', current_date)::date);
insert into payroll_items (run_id, lesson_id, minutes, payable) values ('99999999-5000-0000-0000-000000002000', '77777777-2000-0000-0000-000000000006', 40, true);

set role authenticated;
-- 1) 일정: 본인 수업만, 학생 연락처 없이 이름·노트 링크, 회차 n/총
set request.jwt.claim.sub = 'bbbbbbbb-0000-0000-0000-00000000200a';
create temp table scr as select tutor_screen(null, current_date - 7, current_date + 7) as j;
select pg_temp.ok((select jsonb_array_length(j -> 'lessons') = 7 and j #>> '{tutor,timezone}' = 'Australia/Sydney' from scr)
              and (select bool_and(not (x ? 'phone') and not (x ? 'email') and x ->> 'student' = 'Record S') from scr, jsonb_array_elements(j -> 'lessons') x)
              and (select (x #>> '{count,n}', x #>> '{count,total}') = ('4', '8') from scr, jsonb_array_elements(j -> 'lessons') x where x ->> 'id' = '77777777-2000-0000-0000-000000000001')
              and (select x -> 'count' = 'null'::jsonb from scr, jsonb_array_elements(j -> 'lessons') x where x ->> 'id' = '77777777-2000-0000-0000-000000000005'),
  '강사 일정: 본인 수업 7개, 학생은 이름만(연락처 없음), 회차는 소진되는 수업만 n/총');
select pg_temp.expect_error($$select tutor_screen('55555555-0000-0000-0000-00000000200b', current_date, current_date)$$, '42501');
set request.jwt.claim.sub = 'bbbbbbbb-0000-0000-0000-00000000200b';
select pg_temp.ok((select jsonb_array_length(tutor_screen(null, current_date - 7, current_date + 7) -> 'lessons') = 0),
  '다른 강사 화면은 못 열고, 다른 강사에게는 이 수업이 안 보임');
select pg_temp.expect_error($$select tutor_record_class('77777777-2000-0000-0000-000000000001', 'held', 'x', null)$$, '42501');
select pg_temp.ok(true, '다른 강사는 이 수업을 기록 못 함');
set request.jwt.claim.sub = 'bbbbbbbb-0000-0000-0000-000000000001';   -- 학생
select pg_temp.expect_error($$select tutor_screen(null, current_date, current_date)$$, '42501');
select pg_temp.expect_error($$select tutor_record_class('77777777-2000-0000-0000-000000000001', 'held', 'x', null)$$, '42501');
select pg_temp.ok(true, '학생은 강사 화면·기록 함수를 못 씀');

-- 2) Class Record 입력 → 결과 하나(lessons.class_status), 정확한 상태 이름은 DB가 정함
set request.jwt.claim.sub = 'bbbbbbbb-0000-0000-0000-00000000200a';
select pg_temp.expect_error($$select tutor_record_class('77777777-2000-0000-0000-000000000002', 'held', 'x', null)$$, 'after it starts');
select pg_temp.expect_error($$select tutor_record_class('77777777-2000-0000-0000-000000000001', 'held', '  ', null)$$, 'covered topics');
select pg_temp.expect_error($$select tutor_record_class('77777777-2000-0000-0000-000000000005', 'held', 'x', null)$$, 'canceled');
select pg_temp.expect_error($$select tutor_record_class('77777777-2000-0000-0000-000000000004', 'late', 'x', null)$$, 'why you were late');
select pg_temp.expect_error($$select tutor_record_class('77777777-2000-0000-0000-000000000006', 'held', 'x', null)$$, 'payroll');
select pg_temp.ok(true, '시작 전·다룬 내용 없음·취소된 수업·지각 사유 없음·정산 들어간 수업은 기록 거절');
select tutor_record_class('77777777-2000-0000-0000-000000000001', 'held', 'Free talk, hobbies', null);
select tutor_record_class('77777777-2000-0000-0000-000000000003', 'held', 'Unit 5', null);
select tutor_record_class('77777777-2000-0000-0000-000000000004', 'held', 'Airports', null);
select pg_temp.ok((select array_agg(class_status::text order by id) from lessons where id in
                   ('77777777-2000-0000-0000-000000000001', '77777777-2000-0000-0000-000000000003', '77777777-2000-0000-0000-000000000004'))
                  = '{Normal,"Make-up completed","Covered by another tutor"}'
              and (select bool_and(state = 'done') from lessons where id in ('77777777-2000-0000-0000-000000000001', '77777777-2000-0000-0000-000000000003'))
              and (select covered_topics = 'Free talk, hobbies' and submitted_by = 'bbbbbbbb-0000-0000-0000-00000000200a' from class_records where lesson_id = '77777777-2000-0000-0000-000000000001'),
  '진행 → 정규 Normal · 보강 Make-up completed · 대체 진행 Covered by another tutor, 수업 진행 완료 + 다룬 내용 저장');
select pg_temp.ok((select (tutor_record_class('77777777-2000-0000-0000-000000000001', 'held', 'Free talk, hobbies', null) ->> 'repeated')::boolean),
  '같은 기록을 다시 저장하면 바뀌는 것 없음');
-- 3000 학생 지각: 정상 수업 그대로 + 표시만. Held 아니면 저장 안 함
select tutor_record_class('77777777-2000-0000-0000-000000000003', 'held', 'Unit 5', null, true);
select pg_temp.ok((select student_late from class_records where lesson_id = '77777777-2000-0000-0000-000000000003')
              and (select class_status = 'Make-up completed' from lessons where id = '77777777-2000-0000-0000-000000000003')
              and (select bool_or((x ->> 'student_late')::boolean) from jsonb_array_elements(tutor_screen(null, '2000-01-01', '2100-12-31') -> 'lessons') x
                   where x ->> 'id' = '77777777-2000-0000-0000-000000000003'),
  '학생 지각 체크 → 상태는 그대로(Make-up completed), 강사 화면에 student_late');
-- 4000 강사 노쇼: 강사는 못 함, 운영자만 → 수업 취소(Tutor no-show) + 보상 수업 1회, 다른 결과로 고치면 보상 되돌림
-- (4401 대표 지시로 강사 본인도 Tutor no-show 를 고를 수 있게 바뀜 — 예전 '강사는 못 함' 시험은 뺌)
select tutor_record_class('77777777-2000-0000-0000-000000000003', 'student_no_show', null, null, true);
select pg_temp.ok((select not student_late from class_records where lesson_id = '77777777-2000-0000-0000-000000000003'), 'Held가 아니면 학생 지각 표시 안 함');
select tutor_record_class('77777777-2000-0000-0000-000000000003', 'held', 'Unit 5', null);
reset role;
create temp table rc_first as select first_submitted_at as f from class_records where lesson_id = '77777777-2000-0000-0000-000000000001';
grant select on rc_first to authenticated;
set role authenticated;
select tutor_record_class('77777777-2000-0000-0000-000000000001', 'student_no_show', null, 'Waited until the end');
select pg_temp.ok((select l.class_status = 'Student no-show' and r.covered_topics is null and r.remarks = 'Waited until the end' and r.first_submitted_at = (select f from rc_first)
                   from lessons l join class_records r on r.lesson_id = l.id where l.id = '77777777-2000-0000-0000-000000000001'),
  '다시 저장하면 고침(학생 노쇼), 첫 기록 시각은 그대로 (10분 기준)');
select tutor_record_class('77777777-2000-0000-0000-000000000004', 'late', 'Airports', 'Internet down, 5 min late, extended');
select pg_temp.ok((select class_status = 'Tutor Late - Student Present' from lessons where id = '77777777-2000-0000-0000-000000000004'),
  '강사 지각(사유 있음) → Tutor Late - Student Present');
select pg_temp.ok((select (x #>> '{count,n}')::int = 4 and x ->> 'topics' is null and x ->> 'remarks' = 'Waited until the end'
                   from jsonb_array_elements(tutor_screen(null, current_date - 7, current_date + 7) -> 'lessons') x where x ->> 'id' = '77777777-2000-0000-0000-000000000001')
              and (select (x ->> 'locked')::boolean from jsonb_array_elements(tutor_screen(null, current_date - 7, current_date + 7) -> 'lessons') x where x ->> 'id' = '77777777-2000-0000-0000-000000000006'),
  '일정에 기록 내용·회차가 그대로 보이고, 정산 들어간 수업은 잠김 표시');

-- 3) 보강 가능 여부: 시간마다 가능/불가, 확정은 운영진
set request.jwt.claim.sub = 'bbbbbbbb-0000-0000-0000-000000000009';
create temp table mk20 as select (admin_makeup_request('77777777-2000-0000-0000-000000000005', null,
  jsonb_build_array(jsonb_build_object('starts_at', ((current_date + 2) + time '12:00') at time zone 'Australia/Sydney'), jsonb_build_object('starts_at', ((current_date + 3) + time '12:00') at time zone 'Australia/Sydney')), now())
  ->> 'makeup_request_id')::uuid as id;
set request.jwt.claim.sub = 'bbbbbbbb-0000-0000-0000-00000000200a';
select pg_temp.ok((select jsonb_array_length(m -> 'slots') = 2 and m ->> 'answered_at' is null
                   from jsonb_array_elements(tutor_screen(null, current_date, current_date) -> 'makeups') m),
  '강사 화면에 답할 보강 신청 1건, 학생이 원한 시간 2개');
select pg_temp.expect_error($$select tutor_makeup_answer((select id from mk20), '{}', ' ')$$, 'other times');
select pg_temp.expect_error($$select tutor_makeup_answer((select id from mk20), array[gen_random_uuid()], null)$$, 'Unknown time');
select pg_temp.ok(true, '모두 불가면 다른 가능 시간 메모 필수, 다른 신청의 시간은 거절');
select tutor_makeup_answer((select id from mk20), array[(select c.id from makeup_candidates c join mk20 on mk20.id = c.request_id order by c.starts_at limit 1)], 'Also free on Friday');
set request.jwt.claim.sub = 'bbbbbbbb-0000-0000-0000-000000000009';   -- 안내 기록은 운영자만 봄
select pg_temp.ok((select array_agg(c.tutor_answer order by c.starts_at) = '{yes,no}' from makeup_candidates c join mk20 on mk20.id = c.request_id)
              and (select r.status = 'requested' and r.tutor_note = 'Also free on Friday' and r.tutor_answered_at is not null and r.confirmed_lesson_id is null
                   from makeup_requests r join mk20 on mk20.id = r.id)
              and (select n.status = 'not_needed' from lesson_notices n join mk20 on mk20.id = n.makeup_request_id where n.event = 'makeup_ask'),
  '강사 답: 시간마다 가능/불가 기록, 확정은 아님(수업 안 생김), WhatsApp으로 물어볼 안내는 보낼 필요 없음');
set request.jwt.claim.sub = 'bbbbbbbb-0000-0000-0000-00000000200b';
select pg_temp.expect_error($$select tutor_makeup_answer((select id from mk20), '{}', 'x')$$, '42501');
select pg_temp.ok(true, '다른 강사는 답할 수 없음');
set request.jwt.claim.sub = 'bbbbbbbb-0000-0000-0000-000000000009';
select pg_temp.expect_error($$select admin_makeup_confirm((select id from mk20), ((current_date + 3) + time '12:00') at time zone 'Australia/Sydney')$$, '불가라고 답한');
select pg_temp.ok((select status = 'requested' from makeup_requests where id = (select id from mk20)), '강사가 불가라고 답한 시간은 운영진도 확정 못 함 (QA-01 D, 4500)');
select admin_makeup_confirm((select id from mk20), ((current_date + 2) + time '12:00') at time zone 'Australia/Sydney');
select pg_temp.ok((select jsonb_array_length(tutor_screen('55555555-0000-0000-0000-00000000200a', current_date, current_date + 7) -> 'makeups') = 0)
              and (select count(*) = 1 from jsonb_array_elements(tutor_screen('55555555-0000-0000-0000-00000000200a', current_date, current_date + 7) -> 'lessons') x
                   where x ->> 'kind' = 'makeup' and x ->> 'makeup_of' is not null and x ->> 'state' = 'scheduled')
              and (select count(*) = 2 from admin_tutor_accounts() a where a.has_login and a.name like '기록%'),
  '운영진 확정 뒤: 답할 보강에서 빠지고 일정에 보강 수업(원래 날짜 표시)으로 보임, 운영자는 강사 화면을 그대로 열 수 있음');
set request.jwt.claim.sub = 'bbbbbbbb-0000-0000-0000-00000000200a';
select pg_temp.expect_error($$select tutor_makeup_answer((select id from mk20), '{}', 'x')$$, 'closed');
select pg_temp.expect_error($$select admin_tutor_accounts()$$, '42501');
select pg_temp.ok(true, '닫힌 보강 신청에는 답 못 함, 강사는 운영 목록 못 봄');
reset request.jwt.claim.sub;
reset role;
-- 4) 기록할 수업 = 강사 LMS 계정이 생긴 뒤 시작했는데 결과 없는 수업 (그 전 수업은 시트), 운영자 대시보드 미기록도 같은 기준
set role authenticated;
set request.jwt.claim.sub = 'bbbbbbbb-0000-0000-0000-00000000200a';
select pg_temp.ok((select tutor_screen(null, current_date, current_date) -> 'to_record' = '[]'::jsonb),
  '계정 연결 전에 시작한 수업은 기록할 수업에 안 나옴');
reset role;
update app_users set created_at = now() - interval '7 days' where auth_user_id = 'bbbbbbbb-0000-0000-0000-00000000200a';
set role authenticated;
select pg_temp.ok((select j -> 'to_record' = '["77777777-2000-0000-0000-000000000006"]'::jsonb
                          and exists (select 1 from jsonb_array_elements(j -> 'lessons') x where x ->> 'id' = '77777777-2000-0000-0000-000000000006')
                   from (select tutor_screen(null, current_date + 1, current_date + 1) as j) q),
  '계정 연결 뒤 시작한 미기록 수업은 보던 주와 상관없이 기록할 수업에 나옴');
set request.jwt.claim.sub = 'bbbbbbbb-0000-0000-0000-000000000009';
select pg_temp.ok((select array_agg(lesson_id::text) from admin_class_record_missing() where tutor_name = '기록A') = '{77777777-2000-0000-0000-000000000006}',
  '운영자 대시보드 미기록: 같은 수업 1건');
set request.jwt.claim.sub = 'bbbbbbbb-0000-0000-0000-00000000200a';
select pg_temp.expect_error($$select admin_class_record_missing()$$, '42501');
select pg_temp.ok(true, '강사는 운영자 미기록 목록 못 봄');
reset request.jwt.claim.sub;
reset role;

-- ---------- 보강 back to back (migration 2300, 정책 원본 H26(30)+보완, POL-OP-21 예외) ----------
-- 강사 붙임T. 학생 붙임A(20분)·붙임B(20분, 다른 학생)·붙임C(40분). 기준 시각 bb = 10일 뒤 정시
reset role;
insert into tutors (id, name, country, timezone) values ('55555555-0000-0000-0000-000000002300', '붙임T', 'Korea', pg_temp.noon_tz());
select pg_temp.open_all('55555555-0000-0000-0000-000000002300');
insert into students (id, name_ko, name_en) values
  ('99999999-0000-0000-0000-00000000230a', '붙임A', 'BtB A'), ('99999999-0000-0000-0000-00000000230b', '붙임B', 'BtB B'),
  ('99999999-0000-0000-0000-00000000230c', '붙임C', 'BtB C');
insert into enrollments (id, student_id, seq, weeks, weekly_count, duration_min, start_date, base_end_date, lessons_purchased, status)
select ('99999999-1000-0000-0000-00000000230' || k)::uuid, ('99999999-0000-0000-0000-00000000230' || k)::uuid, 1, 4, 2, d,
       current_date - 3, current_date - 3 + 27, 8, 'active'
from (values ('a', 20), ('b', 20), ('c', 40)) v(k, d);
create temp table bb as select date_trunc('hour', now()) + interval '10 days' as t;
grant select on bb to authenticated;
-- A: 10일 뒤 2시 20분 수업 하나 / 11일 뒤 2시·2시 20분 쉬지 않고 2개 / B: 13일 뒤 2시 / C: 14일 뒤 2시 40분 / A: 15일 뒤 2시
insert into lessons (id, enrollment_id, student_id, tutor_id, kind, seq, starts_at, ends_at)
select ('77777777-2300-0000-0000-00000000000' || n)::uuid, ('99999999-1000-0000-0000-00000000230' || k)::uuid, ('99999999-0000-0000-0000-00000000230' || k)::uuid,
       '55555555-0000-0000-0000-000000002300', 'regular', n, bb.t + o, bb.t + o + make_interval(mins => d)
from bb, (values (1, 'a', interval '2 hours', 20), (2, 'a', interval '1 day 2 hours', 20), (3, 'a', interval '1 day 2 hours 20 minutes', 20),
                 (4, 'b', interval '3 days 2 hours', 20), (5, 'c', interval '4 days 2 hours', 40), (6, 'a', interval '5 days 2 hours', 20)) v(n, k, o, d);
-- 날짜 미정 보강(이관) — 학생마다 보강 신청 1건씩 쓰려고 여러 개
insert into migrated_items (id, enrollment_id, kind, original_date)
select ('99999999-4000-0000-0000-00000000230' || n)::uuid, ('99999999-1000-0000-0000-00000000230' || k)::uuid, 'makeup_open', current_date - 1 - n
from (values (1, 'a'), (2, 'a'), (3, 'a'), (4, 'a'), (5, 'c'), (6, 'c')) v(n, k);
create or replace function pg_temp.mreq(item int, slot interval) returns uuid language sql as $$
  select (admin_makeup_request(null, ('99999999-4000-0000-0000-00000000230' || item)::uuid,
          jsonb_build_array(jsonb_build_object('starts_at', (select t from bb) + slot)), now()) ->> 'makeup_request_id')::uuid $$;
create or replace function pg_temp.busy(req uuid) returns boolean language sql as $$
  select (s ->> 'busy')::boolean from jsonb_array_elements(tutor_screen('55555555-0000-0000-0000-000000002300', current_date, current_date) -> 'makeups') m,
         jsonb_array_elements(m -> 'slots') s where (m ->> 'id')::uuid = req $$;
set role authenticated;
set request.jwt.claim.sub = 'bbbbbbbb-0000-0000-0000-000000000009';
select tutor_record_class('77777777-2000-0000-0000-000000000004', 'tutor_no_show', null, 'Tutor did not join');
select pg_temp.ok((select state = 'done' and class_status = 'Tutor no-show' from lessons where id = '77777777-2000-0000-0000-000000000004')
              and (select status = 'available' and reason = 'tutor_no_show' from compensations where source_lesson_id = '77777777-2000-0000-0000-000000000004'),
  '운영자 강사 노쇼 → Tutor no-show + 보상 수업 1회 (4000)');
select tutor_record_class('77777777-2000-0000-0000-000000000004', 'held', 'Airports', null);
select pg_temp.ok((select state = 'done' from lessons where id = '77777777-2000-0000-0000-000000000004')
              and (select status = 'voided' from compensations where source_lesson_id = '77777777-2000-0000-0000-000000000004'),
  '강사 노쇼를 진행으로 고치면 보상 수업은 되돌림(기록 남김) (4000)');
create temp table bq as select 1 as n, pg_temp.mreq(1, interval '2 hours 20 minutes') as id   -- A 수업 바로 뒤 (휴식 0분)
union all select 2, pg_temp.mreq(2, interval '1 day 2 hours 40 minutes')                        -- 이미 쉬지 않고 2개인 A 수업 바로 뒤
union all select 3, pg_temp.mreq(3, interval '3 days 2 hours 20 minutes')                        -- 다른 학생 B 수업 바로 뒤
union all select 4, pg_temp.mreq(4, interval '6 days')                                            -- 강사가 다른 시간을 말하는 경우
union all select 5, pg_temp.mreq(5, interval '4 days 2 hours 40 minutes')                        -- 40분 C 수업 바로 뒤
union all select 6, pg_temp.mreq(6, interval '4 days 2 hours 50 minutes');                       -- 40분 C 수업 뒤 10분 쉬고
select pg_temp.ok((select array_agg(pg_temp.busy(id) order by n) from bq) = '{f,t,t,f,t,f}',
  'back to back 강사 화면: 같은 학생 20분 바로 뒤는 가능 표시, 쉬지 않고 3개·다른 학생 바로 뒤·40분 바로 뒤는 이미 수업 있음');
select pg_temp.expect_error($$select tutor_makeup_answer((select id from bq where n = 3), array[(select c.id from makeup_candidates c where c.request_id = (select id from bq where n = 3))], null)$$, 'another class at this time');
select pg_temp.ok(true, '강사 보강 답: 다른 수업과 겹치는 시간은 가능으로 못 보냄 (4100, 11/3 점검 ①)');
select admin_makeup_confirm((select id from bq where n = 1), (select t from bb) + interval '2 hours 20 minutes');
select pg_temp.ok((select ends_at - starts_at = interval '20 minutes' from lessons where id = (select confirmed_lesson_id from makeup_requests where id = (select id from bq where n = 1))),
  '같은 학생 20분 수업 바로 뒤(휴식 없이) 보강 확정 — 학생이 원한 시간');
select pg_temp.expect_error($$select admin_makeup_confirm((select id from bq where n = 2), (select t from bb) + interval '1 day 2 hours 40 minutes')$$, '쉬지 않고 이어 붙이는 수업\(20분 2개까지\)');
select pg_temp.ok(true, '쉬지 않고 붙이는 건 2개까지: 이미 이어진 2개 바로 뒤는 거절');
select pg_temp.expect_error($$select admin_makeup_confirm((select id from bq where n = 3), (select t from bb) + interval '3 days 2 hours 20 minutes')$$, '휴식 10분');
select pg_temp.ok(true, '다른 학생 수업 바로 뒤는 휴식 10분 그대로');
select pg_temp.expect_error($$select admin_makeup_confirm((select id from bq where n = 4), (select t from bb) + interval '5 days 2 hours 20 minutes')$$, '휴식 10분');
select pg_temp.ok(true, '학생이 원한 시간이 아니면(강사가 말한 시간) 같은 학생 20분이어도 휴식 10분');
select pg_temp.expect_error($$select admin_makeup_confirm((select id from bq where n = 5), (select t from bb) + interval '4 days 2 hours 40 minutes')$$, '휴식 10분');
select admin_makeup_confirm((select id from bq where n = 6), (select t from bb) + interval '4 days 2 hours 50 minutes');
select pg_temp.ok((select status = 'confirmed' from makeup_requests where id = (select id from bq where n = 6)),
  '40분 수업은 같은 학생이어도 휴식 10분: 바로 뒤 거절, 10분 쉬고 이어서(back to back) 확정');
reset request.jwt.claim.sub;
reset role;

-- ---------- 대체강사 판정 = 강사 수업 가능 시간 (migration 2400) ----------
reset role;
insert into tutors (id, name, country, timezone) values ('55555555-0000-0000-0000-000000002400', '가능T', 'Australia', 'Australia/Melbourne');
insert into tutor_availability (tutor_id, weekday, start_local, end_local, timezone, effective_from)
select '55555555-0000-0000-0000-000000002400'::uuid, d, time '09:00', time '18:00', 'Asia/Seoul', current_date - 1 from generate_series(1, 5) d
union all select '55555555-0000-0000-0000-000000002400', 6, '10:00', '11:00', 'Australia/Melbourne', current_date - 1;
create temp table av as select ((d::date + time '20:00') at time zone 'Asia/Seoul') as t20, ((d::date + time '18:00') at time zone 'Asia/Seoul') as t18
from generate_series(current_date + 7, current_date + 13, interval '1 day') d where extract(dow from d) = 1;
select pg_temp.ok(not lms_tutor_available('55555555-0000-0000-0000-000000002400', (select t20 from av))
              and lms_tutor_available('55555555-0000-0000-0000-000000002400', (select t18 from av))
              and not lms_tutor_available('55555555-0000-0000-0000-000000002400', (select t18 from av) - interval '10 hours')
              and lms_sub_conflict('55555555-0000-0000-0000-000000002400', (select t20 from av), (select t20 from av) + interval '40 minutes', null) is null,
  '보통 수업 시간: 평일 한국 9~18시 시작 강사는 20시·8시 밖 · 18시 정각 안 — 밖이어도 대체강사로 고를 수는 있음 (2700)');
select pg_temp.ok(lms_tutor_available('55555555-0000-0000-0000-000000001700', now() + interval '30 days'),
  '보통 수업 시간을 안 넣은 강사는 언제나 안');

-- ---------- 학생 수업 알림 메일 (migration 2900) ----------
reset role;
reset request.jwt.claim.sub;
insert into tutors (id, name, country, timezone, meet_url) values
  ('55555555-0000-0000-0000-000000002900', '알림T', 'Australia', 'Australia/Sydney', 'https://meet.google.com/aaa-bbbb-ccc'),
  ('55555555-0000-0000-0000-000000002901', '대체T', 'Australia', 'Australia/Sydney', 'https://meet.google.com/sub-link-xyz');
insert into students (id, name_ko, name_en, email) values ('99999999-0000-0000-0000-000000002900', '알림학생', 'Remind S', 'remind-s@example.com');
insert into enrollments (id, student_id, seq, weeks, weekly_count, duration_min, start_date, base_end_date, lessons_purchased, status)
values ('99999999-1000-0000-0000-000000002900', '99999999-0000-0000-0000-000000002900', 1, 4, 2, 50, '2031-02-20', '2031-03-19', 8, 'active');
-- T0 = 2031-03-03(월) 20:00 KST 정규, T0+3시간 보강
insert into lessons (id, enrollment_id, student_id, tutor_id, kind, seq, makeup_of, starts_at, ends_at) values
  ('77777777-2900-0000-0000-000000000001', '99999999-1000-0000-0000-000000002900', '99999999-0000-0000-0000-000000002900',
   '55555555-0000-0000-0000-000000002900', 'regular', 1, null, '2031-03-03 11:00Z', '2031-03-03 11:50Z'),
  ('77777777-2900-0000-0000-000000000002', '99999999-1000-0000-0000-000000002900', '99999999-0000-0000-0000-000000002900',
   '55555555-0000-0000-0000-000000002900', 'makeup', null, '77777777-2900-0000-0000-000000000001', '2031-03-03 14:00Z', '2031-03-03 14:50Z');
create temp table rm_due as select * from lms_lesson_reminders_due('2031-03-02 12:00Z') where student_id = '99999999-0000-0000-0000-000000002900';
select pg_temp.ok(lms_ko_when('2031-03-03 11:00Z', 'Asia/Seoul') = '3/3(월) 오후 8:00' and lms_ko_when('2031-03-03 00:05Z', 'Asia/Seoul') = '3/3(월) 오전 9:05'
              and lms_ko_when('2031-03-03 03:00Z', 'Asia/Seoul') = '3/3(월) 오후 12:00',
  '알림 시간 표기: 3/3(월) 오후 8:00 · 오전 9:05 · 오후 12:00');
select pg_temp.ok((select count(*) = 1 and bool_and(which = '24h' and to_email = 'support@edgeenglish.kr' and intended_email = 'remind-s@example.com'
                          and subject = '[시험 · ' || (select code from students where id = '99999999-0000-0000-0000-000000002900') || '] [엣지영어] 3/3(월) 오후 8:00 수업'
                          and html like '%알림학생님, 수업 안내드려요.%' and html like '%(50분)%' and html like '%meet.google.com/aaa-bbbb-ccc%'
                          and html not like '%대체강사%') from rm_due),
  '알림: 23시간 전 = 정규 24시간 전 알림 1개 (보강은 아직 24시간 밖), 메일 꺼져 있으면 support@로만 + 제목에 [시험 · 학생 번호]');
select pg_temp.ok((select array_agg(which || ':' || (lesson_id = '77777777-2900-0000-0000-000000000002') order by lesson_id)
                   from lms_lesson_reminders_due('2031-03-03 09:30Z') where student_id = '99999999-0000-0000-0000-000000002900') = '{2h:false,24h:true}'
              and (select subject like '%3/3(월) 오후 11:00 보강 수업' from lms_lesson_reminders_due('2031-03-03 09:30Z') where lesson_id = '77777777-2900-0000-0000-000000000002'),
  '알림: 1시간 30분 전 = 정규는 2시간 전 알림, 보강은 24시간 전 알림 (제목 ''보강 수업'')');
insert into notifications (recipient_kind, recipient_id, email, locale, template, dedupe_key)
select 'student', student_id, to_email, 'ko', 'lesson_reminder_24h', dedupe_key from rm_due;
select pg_temp.ok(not exists (select 1 from lms_lesson_reminders_due('2031-03-02 13:00Z') where student_id = '99999999-0000-0000-0000-000000002900'),
  '알림: 이미 보낸 알림은 다시 안 보냄');
update lessons set starts_at = '2031-03-03 11:30Z', ends_at = '2031-03-03 12:20Z', time_set_at = '2031-01-01Z' where id = '77777777-2900-0000-0000-000000000001';
select pg_temp.ok((select count(*) = 1 from lms_lesson_reminders_due('2031-03-02 13:00Z') where student_id = '99999999-0000-0000-0000-000000002900'),
  '알림: 시간이 바뀌면 새 시간으로 다시 보냄');
update lessons set starts_at = '2031-03-03 11:00Z', ends_at = '2031-03-03 11:50Z' where id = '77777777-2900-0000-0000-000000000001';
select pg_temp.ok((select time_set_at > now() - interval '1 minute' from lessons where id = '77777777-2900-0000-0000-000000000001'), '시작 시각을 바꾸면 정한 때 기록');
update lessons set time_set_at = '2031-03-03 01:00Z' where id = '77777777-2900-0000-0000-000000000001';
select pg_temp.ok(not exists (select 1 from lms_lesson_reminders_due('2031-03-03 02:00Z') where lesson_id = '77777777-2900-0000-0000-000000000001')
              and exists (select 1 from lms_lesson_reminders_due('2031-03-03 09:30Z') where lesson_id = '77777777-2900-0000-0000-000000000001' and which = '2h'),
  '알림: 24시간 안에 시간을 정한 수업은 24시간 전 알림 건너뛰고 2시간 전 알림만');
update lessons set original_tutor_id = tutor_id, tutor_id = '55555555-0000-0000-0000-000000002901' where id = '77777777-2900-0000-0000-000000000001';
select pg_temp.ok((select subject like '% 수업 · 대체강사' and html like '%대체강사 수업이에요. 수업 링크가 달라요.%' and html like '%meet.google.com/sub-link-xyz%'
                          and html like '%대체T 강사님 수업 들어가기%' and html not like '%aaa-bbbb-ccc%'
                   from lms_lesson_reminders_due('2031-03-03 09:30Z') where lesson_id = '77777777-2900-0000-0000-000000000001'),
  '알림: 대체강사 수업 = 제목 ''· 대체강사'' + ''수업 링크가 달라요'' + 대체강사 링크만');
update students set timezone = 'America/Los_Angeles', city = 'Los Angeles' where id = '99999999-0000-0000-0000-000000002900';
select pg_temp.ok((select html like '%3/3(월) 오후 11:00 (50분) 한국 시간<br>3/3(월) 오전 6:00 Los Angeles%'
                   from lms_lesson_reminders_due('2031-03-03 09:30Z') where lesson_id = '77777777-2900-0000-0000-000000000002'),
  '알림: 해외 학생은 한국 시간 + 현지 시각');
update students set remind_regular = false where id = '99999999-0000-0000-0000-000000002900';
select pg_temp.ok((select array_agg(lesson_id) from lms_lesson_reminders_due('2031-03-03 09:30Z') where student_id = '99999999-0000-0000-0000-000000002900')
                  = '{77777777-2900-0000-0000-000000000002}',
  '알림: 정규 끔 → 보강만');
update feature_flags set enabled = true where key = 'send_emails';
select pg_temp.ok((select to_email = 'remind-s@example.com' and subject not like '[시험%' from lms_lesson_reminders_due('2031-03-03 09:30Z') where lesson_id = '77777777-2900-0000-0000-000000000002'),
  '알림: 메일 켜면 학생 이메일로');
update feature_flags set enabled = false where key = 'send_emails';
update lessons set state = 'canceled', canceled_at = now(), class_status = 'Student canceled in advance' where id = '77777777-2900-0000-0000-000000000002';
select pg_temp.ok(not exists (select 1 from lms_lesson_reminders_due('2031-03-03 09:30Z') where student_id = '99999999-0000-0000-0000-000000002900'),
  '알림: 취소된 수업은 안 보냄');

-- 보내기: pg_net·Vault 흉내 (실제 Supabase 에는 있음)
create schema if not exists net;
create table net._http_response (id bigint primary key, status_code int, content text, error_msg text, created timestamptz default now());
create sequence net.req_seq;
create table net.sent (id bigint, url text, body jsonb, headers jsonb);
create function net.http_post(url text, body jsonb, params jsonb default '{}', headers jsonb default '{}', timeout_milliseconds int default 5000)
returns bigint language plpgsql as $$
declare i bigint := nextval('net.req_seq');
begin insert into net.sent values (i, url, body, headers); return i; end $$;
create schema if not exists vault;
create table vault.decrypted_secrets (name text, decrypted_secret text);
update students set remind_regular = true, timezone = 'Asia/Seoul' where id = '99999999-0000-0000-0000-000000002900';
insert into lessons (id, enrollment_id, student_id, tutor_id, kind, seq, starts_at, ends_at)
values ('77777777-2900-0000-0000-000000000003', '99999999-1000-0000-0000-000000002900', '99999999-0000-0000-0000-000000002900',
        '55555555-0000-0000-0000-000000002900', 'regular', 3, date_trunc('minute', now()) + interval '90 minutes 7 seconds', date_trunc('minute', now()) + interval '140 minutes 7 seconds');
update lessons set time_set_at = now() - interval '3 days' where id = '77777777-2900-0000-0000-000000000003';
select pg_temp.ok(lms_send_lesson_reminders() = 0 and not exists (select 1 from net.sent), '보내기: Resend 키가 없으면 아무것도 안 보냄');
insert into vault.decrypted_secrets values ('resend_api_key', 're_test_key');
create temp table rm_sent as select lms_send_lesson_reminders() as n;
select pg_temp.ok((select n >= 1 from rm_sent)
              and (select s.url = 'https://api.resend.com/emails' and s.body -> 'to' = '["support@edgeenglish.kr"]' and s.headers ->> 'Authorization' = 'Bearer re_test_key'
                          and s.headers ->> 'Idempotency-Key' = n.dedupe_key and n.status = 'queued' and n.template = 'lesson_reminder_2h'
                   from notifications n join net.sent s on s.id = n.net_request_id where n.payload ->> 'lesson_id' = '77777777-2900-0000-0000-000000000003'),
  '보내기: 2시간 전 알림을 Resend 로 (support@, 같은 알림 키로 중복 방지)');
insert into net._http_response (id, status_code, content) select net_request_id, 200, '{"id":"x"}' from notifications where payload ->> 'lesson_id' = '77777777-2900-0000-0000-000000000003';
create temp table rm_sent2 as select lms_send_lesson_reminders() as n;
select pg_temp.ok((select n = 0 from rm_sent2)
              and (select status = 'sent' and sent_at is not null from notifications where payload ->> 'lesson_id' = '77777777-2900-0000-0000-000000000003')
              and (select count(*) = 1 from net.sent s join notifications n on n.net_request_id = s.id where n.payload ->> 'lesson_id' = '77777777-2900-0000-0000-000000000003'),
  '보내기: 다음 실행 때 결과 기록(보냄), 같은 알림은 다시 안 보냄');

-- 학생 알림 설정: 본인 · 운영자 · 다른 학생 거절
insert into app_users (auth_user_id, role, student_id) values ('bbbbbbbb-0000-0000-0000-000000002900', 'student', '99999999-0000-0000-0000-000000002900');
set role authenticated;
set request.jwt.claim.sub = 'bbbbbbbb-0000-0000-0000-000000002900';
select pg_temp.ok(student_reminders(null) = '{"regular": true, "makeup": true, "has_email": true}', '알림 설정: 기본 정규·보강 모두 켬');
select pg_temp.ok(student_reminders(null, false, null) = '{"regular": false, "makeup": true, "has_email": true}', '알림 설정: 학생이 정규만 끔');
select pg_temp.expect_error($$select student_reminders('99999999-0000-0000-0000-000000001800', false, false)$$, '42501');
select pg_temp.ok(true, '알림 설정: 다른 학생 것은 못 바꿈');
set request.jwt.claim.sub = 'bbbbbbbb-0000-0000-0000-000000000009';
select pg_temp.ok(student_reminders('99999999-0000-0000-0000-000000002900', true, false) = '{"regular": true, "makeup": false, "has_email": true}',
  '알림 설정: 운영자가 대신 바꿈');
select pg_temp.expect_error($$select lms_send_lesson_reminders()$$, 'permission denied');
select pg_temp.ok(true, '보내기 함수는 로그인 사용자가 못 부름');
reset request.jwt.claim.sub;
reset role;

-- ---------- 강사 본인 가능 시간 고치기 My hours (migration 3100) ----------
-- 강사 '시간H'(호찌민, 한국보다 2시간 늦음). 가능 시간은 Maria처럼 한국 시간대 줄(월~금 10:00~17:00 KST = 현지 08:00~15:00)
reset role;
insert into tutors (id, name, country, timezone) values ('55555555-0000-0000-0000-000000003100', '시간H', 'Vietnam', 'Asia/Ho_Chi_Minh');
insert into app_users (auth_user_id, role, tutor_id) values ('bbbbbbbb-0000-0000-0000-000000003100', 'tutor', '55555555-0000-0000-0000-000000003100');
insert into tutor_availability (tutor_id, weekday, start_local, end_local, timezone, effective_from)
select '55555555-0000-0000-0000-000000003100', d, '10:00', '17:00', 'Asia/Seoul', current_date - 14 from generate_series(1, 5) d;
insert into students (id, name_ko, name_en) values ('99999999-0000-0000-0000-000000003100', '시간학생', 'Hours S');
insert into enrollments (id, student_id, seq, weeks, weekly_count, duration_min, start_date, base_end_date, lessons_purchased, status)
values ('99999999-1000-0000-0000-000000003100', '99999999-0000-0000-0000-000000003100', 1, 4, 1, 40, current_date, current_date + 27, 4, 'active');
-- 고정 수업: 다음 주 다음 월요일 현지 09:00 (40분) · 3주째 화요일 현지 10:00 보강
insert into lessons (id, enrollment_id, student_id, tutor_id, kind, seq, starts_at, ends_at)
select '77777777-3100-0000-0000-000000000001', '99999999-1000-0000-0000-000000003100', '99999999-0000-0000-0000-000000003100', '55555555-0000-0000-0000-000000003100',
       'regular', 1, ((lms_next_monday() + 7) + time '09:00') at time zone 'Asia/Ho_Chi_Minh', ((lms_next_monday() + 7) + time '09:40') at time zone 'Asia/Ho_Chi_Minh';
insert into lessons (id, enrollment_id, student_id, tutor_id, kind, starts_at, ends_at, makeup_of)
select '77777777-3100-0000-0000-000000000002', '99999999-1000-0000-0000-000000003100', '99999999-0000-0000-0000-000000003100', '55555555-0000-0000-0000-000000003100',
       'makeup', ((lms_local_monday('Asia/Ho_Chi_Minh') + 15) + time '10:00') at time zone 'Asia/Ho_Chi_Minh',
       ((lms_local_monday('Asia/Ho_Chi_Minh') + 15) + time '10:40') at time zone 'Asia/Ho_Chi_Minh', '77777777-3100-0000-0000-000000000001';
create temp table hm (mon date, nxt date);
insert into hm select lms_local_monday('Asia/Ho_Chi_Minh'), lms_next_monday();
grant select on hm to authenticated;

set role authenticated;
set request.jwt.claim.sub = 'bbbbbbbb-0000-0000-0000-000000003100';
create temp table hr as select tutor_hours(null) as j;
select pg_temp.ok((select j -> 'times' ->> 0 = '06:00' and j -> 'times' ->> -1 = '22:30' and j ->> 'from' = (select nxt::text from hm) from hr),
  'My hours: 강사 현지 06:00~22:30 시작, 한국 시간대와 무관, 매주 변경은 다음 주 월요일부터');
select pg_temp.ok((select j -> 'weekly_open' ? '1:08:00' and j -> 'weekly_open' ? '5:15:00' and not j -> 'weekly_open' ? '1:15:30' and not j -> 'weekly_open' ? '0:08:00' from hr),
  'My hours: 한국 시간대로 넣은 가능 시간을 강사 현지 칸으로 (월 08:00~15:00)');
select pg_temp.ok((select j -> 'weekly_classes' @> '[{"d": 1, "time": "09:00", "min": 40}]' and j -> 'history' = 'null'::jsonb from hr),
  'My hours: 고정 수업 칸 표시, 강사 본인에게는 바뀐 기록 없음');
select pg_temp.ok((select j -> 'cells' ->> ((mon + 15)::text || 'T10:00') = 'c' and j -> 'cells' ->> ((mon + 15)::text || 'T10:30') = 'c'
                          and j -> 'cells' ->> ((mon + 15)::text || 'T16:00') = 's' and not j -> 'cells' ? ((mon + 15)::text || 'T08:00') from hr, hm),
  'My hours: 그 주만 칸 — 보강 걸친 칸 잠김, 매주 닫힌 칸, 빈 칸은 열림');
select pg_temp.expect_error($$select tutor_hours_save(null, array(select x from jsonb_array_elements_text((select j -> 'weekly_open' from hr)) x where x <> '1:09:30'), null, null)$$, 'weekly class');
select pg_temp.ok(true, 'My hours: 고정 수업이 걸친 칸은 매주 닫기 불가');
select tutor_hours_save(null, array(select x from jsonb_array_elements_text((select j -> 'weekly_open' from hr)) x where x <> '1:08:00') || '{6:10:00}', null, null);
select tutor_hours_save(null, array(select x from jsonb_array_elements_text((select j -> 'weekly_open' from hr)) x where x not in ('1:08:00', '1:08:30')) || '{6:10:00}', null, null);
reset role;
select pg_temp.ok((select count(*) = 5 and bool_and(effective_to = nxt - 1) from tutor_availability, hm where tutor_id = '55555555-0000-0000-0000-000000003100' and timezone = 'Asia/Seoul')
              and (select count(*) = 6 and bool_and(effective_from = nxt and effective_to is null and timezone = 'Asia/Ho_Chi_Minh')
                   from tutor_availability, hm where tutor_id = '55555555-0000-0000-0000-000000003100' and timezone <> 'Asia/Seoul')
              and exists (select 1 from tutor_availability where tutor_id = '55555555-0000-0000-0000-000000003100' and weekday = 1 and start_local = '09:00' and end_local = '15:00')
              and exists (select 1 from tutor_availability where tutor_id = '55555555-0000-0000-0000-000000003100' and weekday = 6 and start_local = '10:00' and end_local = '10:00')
              and (select count(*) = 2 from tutor_hours_changes where tutor_id = '55555555-0000-0000-0000-000000003100' and not by_admin),
  'My hours 매주: 기존 줄은 전날로 끝냄, 새 줄은 다음 주 월요일부터 이어진 칸 한 줄(한 칸 줄도 됨), 두 번 저장해도 겹치지 않음, 바뀐 기록 2건');
select pg_temp.ok(lms_tutor_available('55555555-0000-0000-0000-000000003100', ((select nxt + 5 from hm) + time '10:00') at time zone 'Asia/Ho_Chi_Minh')
              and not lms_tutor_available('55555555-0000-0000-0000-000000003100', ((select nxt from hm) + time '08:00') at time zone 'Asia/Ho_Chi_Minh')
              and lms_tutor_available('55555555-0000-0000-0000-000000003100', ((select nxt - 7 from hm) + time '08:00') at time zone 'Asia/Ho_Chi_Minh'),
  'My hours 매주: 보강 날짜·대체강사 판정에 다음 주부터 반영, 이번 주는 그대로');

set role authenticated;
set request.jwt.claim.sub = 'bbbbbbbb-0000-0000-0000-000000003100';
select tutor_hours_save(null, null, array[(select (mon + 15)::text from hm) || 'T08:00', (select (mon + 15)::text from hm) || 'T08:30', (select (mon + 15)::text from hm) || 'T09:00'], null);
select tutor_hours_save(null, null, null, array[(select (mon + 15)::text from hm) || 'T08:00']);
reset role;
select pg_temp.ok((select count(*) = 1 and min(starts_at) = (select ((mon + 15) + time '08:30') at time zone 'Asia/Ho_Chi_Minh' from hm)
                          and max(ends_at) = (select ((mon + 15) + time '09:30') at time zone 'Asia/Ho_Chi_Minh' from hm)
                   from tutor_time_off where tutor_id = '55555555-0000-0000-0000-000000003100' and kind = 'block'),
  'My hours 그 주만: 붙은 칸은 한 줄로 합침, 다시 연 칸만 잘라 냄');
select pg_temp.ok(lms_tutor_busy('55555555-0000-0000-0000-000000003100', ((select mon + 15 from hm) + time '09:00') at time zone 'Asia/Ho_Chi_Minh', ((select mon + 15 from hm) + time '09:40') at time zone 'Asia/Ho_Chi_Minh')
              and not lms_tutor_busy('55555555-0000-0000-0000-000000003100', ((select mon + 15 from hm) + time '08:00') at time zone 'Asia/Ho_Chi_Minh', ((select mon + 15 from hm) + time '08:20') at time zone 'Asia/Ho_Chi_Minh'),
  'My hours 그 주만: 닫은 칸은 보강·대체 판정에서 막힘, 다시 연 칸은 열림');
set role authenticated;
set request.jwt.claim.sub = 'bbbbbbbb-0000-0000-0000-000000003100';
select pg_temp.expect_error($$select tutor_hours_save(null, null, array[(select (mon + 15)::text from hm) || 'T10:30'], null)$$, 'can''t be closed');
select pg_temp.expect_error($$select tutor_hours_save(null, null, array[(select (mon + 15)::text from hm) || 'T16:00'], null)$$, 'can''t be closed');
select pg_temp.expect_error($$select tutor_hours_save(null, null, array[(select (mon + 28)::text from hm) || 'T08:00'], null)$$, 'Invalid time');
select pg_temp.expect_error($$select tutor_hours_save(null, null, null, array[(select (mon + 16)::text from hm) || 'T08:00'])$$, 'can''t be opened');
select pg_temp.ok(true, 'My hours 그 주만: 수업 칸·매주 닫힌 칸·4주 밖은 닫기 불가, 닫지 않은 칸은 다시 열기 불가');
set request.jwt.claim.sub = 'bbbbbbbb-0000-0000-0000-00000000200a';
select pg_temp.expect_error($$select tutor_hours('55555555-0000-0000-0000-000000003100')$$, '42501');
select pg_temp.expect_error($$select tutor_hours_save('55555555-0000-0000-0000-000000003100', null, null, null)$$, '42501');
select pg_temp.ok(true, 'My hours: 다른 강사는 못 보고 못 고침');
set request.jwt.claim.sub = 'bbbbbbbb-0000-0000-0000-000000000009';
select tutor_hours_save('55555555-0000-0000-0000-000000003100', null, array[(select (mon + 16)::text from hm) || 'T08:00'], null);
select pg_temp.ok((select jsonb_array_length(tutor_hours('55555555-0000-0000-0000-000000003100') -> 'history') = 5),
  'My hours: 운영자가 대신 고치고, 운영자 보기에 바뀐 기록');
reset request.jwt.claim.sub;
reset role;
select pg_temp.ok((select count(*) = 1 from tutor_hours_changes where tutor_id = '55555555-0000-0000-0000-000000003100' and by_admin), 'My hours: 운영자 대신 고친 것은 운영자 표시');
select pg_temp.expect_error($$delete from tutor_hours_changes$$, '삭제할 수 없습니다');
select pg_temp.ok(true, 'My hours: 바뀐 기록은 지울 수 없음');

-- ---------- 4403 강사 Schedule 날짜별 막기·열기 (H26(49)+(50)) ----------
-- 강사 3100 (Ho Chi Minh): 다음 주부터 매주 월 09:00~15:00 시작 가능, 다다음 주 월요일 = nxt + 7 에 정규 수업 09:00 (40분)
create temp table sd (d date, far date);
insert into sd select nxt + 14, (now() at time zone 'Asia/Ho_Chi_Minh')::date + 85 from hm;
grant select on sd to authenticated;
set role authenticated;
set request.jwt.claim.sub = 'bbbbbbbb-0000-0000-0000-000000003100';
select tutor_schedule_save(null, 'block', array[(select d::text from sd) || 'T10:00', (select d::text from sd) || 'T10:30'], '  Dentist  ');
select tutor_schedule_save(null, 'open', array[(select d::text from sd) || 'T16:00', (select d::text from sd) || 'T16:30'], null);
create temp table sj as select tutor_schedule(null, (select d from sd), (select d from sd), true) as j;
select pg_temp.ok((select j -> 'cells' ->> ((select d::text from sd) || 'T10:00') = 'b' and j -> 'cells' ->> ((select d::text from sd) || 'T16:00') = 'x'
                          and j -> 'cells' ->> ((select d::text from sd) || 'T17:00') = 's' and not j -> 'cells' ? ((select d::text from sd) || 'T11:00')
                          and j -> 'blocks' -> 0 ->> 'note' = 'Dentist' and j -> 'blocks' -> 0 ->> 'end' = (select d::text from sd) || 'T11:00'
                          and j -> 'opens' -> 0 ->> 'start' = (select d::text from sd) || 'T16:00' and j -> 'opens' -> 0 ->> 'end' = (select d::text from sd) || 'T17:00'
                          and (j ->> 'last')::date = (j ->> 'today')::date + 84 from sj),
  'Schedule: 막기(메모 앞뒤 공백 정리)·그날만 열기 칸이 보이고, 기간은 오늘부터 12주(84일) 후까지');
reset role;
select pg_temp.ok(lms_tutor_available('55555555-0000-0000-0000-000000003100', ((select d from sd) + time '16:30') at time zone 'Asia/Ho_Chi_Minh')
              and not lms_tutor_available('55555555-0000-0000-0000-000000003100', ((select d from sd) + time '17:00') at time zone 'Asia/Ho_Chi_Minh')
              and lms_tutor_busy('55555555-0000-0000-0000-000000003100', ((select d from sd) + time '10:00') at time zone 'Asia/Ho_Chi_Minh', ((select d from sd) + time '10:40') at time zone 'Asia/Ho_Chi_Minh'),
  'Schedule: 그날만 연 시간은 보강·대체 판정에 가능, 막은 시간은 막힘');
set role authenticated;
set request.jwt.claim.sub = 'bbbbbbbb-0000-0000-0000-000000003100';
select tutor_schedule_save(null, 'block', array[(select d::text from sd) || 'T16:30'], 'ignored');
select pg_temp.ok((select j -> 'cells' ->> ((select d::text from sd) || 'T16:30') = 's' and j -> 'cells' ->> ((select d::text from sd) || 'T16:00') = 'x'
                   from (select tutor_schedule(null, (select d from sd), (select d from sd), true) j) z),
  'Schedule: 그날만 연 칸을 막으면 그 칸만 다시 닫힘(매주 닫힌 시간)');
select pg_temp.expect_error($$select tutor_schedule_save(null, 'block', array[(select (nxt + 7)::text from hm) || 'T09:00'], null)$$, 'You have a class at 09:00 Ho Chi Minh Time. Classes can''t be blocked.');
select pg_temp.expect_error($$select tutor_schedule_save(null, 'block', array[(select d::text from sd) || 'T12:00'], repeat('a', 101))$$, '100 characters');
select pg_temp.expect_error($$select tutor_schedule_save(null, 'block', array[(select far::text from sd) || 'T10:00'], null)$$, '12 weeks');
select pg_temp.expect_error($$select tutor_schedule_save(null, 'block', array[(select d::text from sd) || 'T10:00'], null)$$, 'already blocked');
select pg_temp.expect_error($$select tutor_schedule_save(null, 'open', array[(select d::text from sd) || 'T11:00'], null)$$, 'already available');
select pg_temp.expect_error($$select tutor_schedule_save(null, 'block', array[(select d::text from sd) || 'T05:30'], null)$$, 'Invalid time');
select pg_temp.ok(true, 'Schedule: 수업 칸·100자 넘는 메모·12주 밖·이미 막은 칸·이미 열린 칸·06:00 전은 거절');
select tutor_schedule_save(null, 'note', null, 'Kid''s school event', (select (j -> 'blocks' -> 0 ->> 'id')::uuid from sj));
reset role;
select pg_temp.ok((select reason = 'Kid''s school event' from tutor_time_off where id = (select (j -> 'blocks' -> 0 ->> 'id')::uuid from sj)), 'Schedule: 메모 고치기');
-- 6시간 안에 걸친 막기 풀기 → 6시간 안 부분은 남음 · 예전 고정 글은 메모 없음 · 휴무 사유는 강사에게 안 보임
insert into tutor_time_off (id, tutor_id, starts_at, ends_at, kind, reason)
values ('66666666-4403-0000-0000-000000000001', '55555555-0000-0000-0000-000000003100', now() + interval '1 hour', now() + interval '20 hours', 'block', 'Unavailable this week (My hours)'),
       ('66666666-4403-0000-0000-000000000002', '55555555-0000-0000-0000-000000003100', now() + interval '30 days', now() + interval '31 days', 'leave', 'internal reason');
set role authenticated;
set request.jwt.claim.sub = 'bbbbbbbb-0000-0000-0000-000000003100';
select pg_temp.ok((select bool_and(case b ->> 'kind' when 'leave' then b -> 'note' = 'null'::jsonb else true end)
                          and exists (select 1 from jsonb_array_elements(j -> 'blocks') x where x ->> 'id' = '66666666-4403-0000-0000-000000000001' and x -> 'note' = 'null'::jsonb)
                   from (select tutor_schedule(null, (now() at time zone 'Asia/Ho_Chi_Minh')::date, (now() at time zone 'Asia/Ho_Chi_Minh')::date + 31) j) z,
                        jsonb_array_elements(j -> 'blocks') b group by j),
  'Schedule: 예전 One week only 고정 글은 메모 없음, 휴무 사유는 강사 화면에 안 보냄');
select tutor_schedule_save(null, 'unblock', null, null, '66666666-4403-0000-0000-000000000001');
reset role;
select pg_temp.ok((select count(*) = 1 and min(starts_at) between now() + interval '59 minutes' and now() + interval '61 minutes'
                          and max(ends_at) between now() + interval '6 hours' and now() + interval '6 hours 30 minutes'
                   from tutor_time_off where tutor_id = '55555555-0000-0000-0000-000000003100' and kind = 'block' and starts_at < now() + interval '2 hours'),
  'Schedule: 막기 풀기 — 6시간 안 부분은 그대로, 그 뒤만 풂');
select pg_temp.ok((select count(*) >= 5 from tutor_hours_changes where tutor_id = '55555555-0000-0000-0000-000000003100' and changes ? 'day_open'), 'Schedule: 바뀐 기록 남음');
set role authenticated;
set request.jwt.claim.sub = 'bbbbbbbb-0000-0000-0000-00000000200a';
select pg_temp.expect_error($$select tutor_schedule('55555555-0000-0000-0000-000000003100', current_date, current_date)$$, '42501');
select pg_temp.expect_error($$select tutor_schedule_save('55555555-0000-0000-0000-000000003100', 'note', null, 'x', '66666666-4403-0000-0000-000000000002')$$, '42501');
select pg_temp.expect_error($$select tutor_schedule_save(null, 'unblock', null, null, (select (j -> 'blocks' -> 0 ->> 'id')::uuid from sj))$$, 'gone');
select pg_temp.ok(true, 'Schedule: 다른 강사는 못 보고 못 고침(남의 막기 id 도 못 건드림)');
select pg_temp.ok((select count(*) = 0 from tutor_open_once), 'Schedule: 다른 강사의 그날만 연 시간은 표에서도 안 보임');
reset request.jwt.claim.sub;
reset role;
delete from tutor_time_off where id = '66666666-4403-0000-0000-000000000002' or (tutor_id = '55555555-0000-0000-0000-000000003100' and starts_at < now() + interval '2 hours');

-- ---------- 4100 강사 노쇼 무료 보상수업 = 기존 보강 기능 재사용 ----------
reset request.jwt.claim.sub;
reset role;
insert into tutors (id, name, country, timezone) values ('55555555-0000-0000-0000-000000004100', 'CompTutor', 'Korea', 'Asia/Seoul');
select pg_temp.open_all('55555555-0000-0000-0000-000000004100');
insert into students (id, name_ko, name_en) values ('99999999-0000-0000-0000-000000004100', '보상학생', 'Comp S');
insert into app_users (auth_user_id, role, student_id) values ('bbbbbbbb-0000-0000-0000-000000004100', 'student', '99999999-0000-0000-0000-000000004100');
insert into enrollments (id, student_id, seq, weeks, weekly_count, duration_min, start_date, base_end_date, lessons_purchased, status)
values ('99999999-1000-0000-0000-000000004100', '99999999-0000-0000-0000-000000004100', 1, 4, 2, 50, current_date - 20, current_date - 20 + 27, 8, 'active');
insert into lessons (id, enrollment_id, student_id, tutor_id, kind, seq, starts_at, ends_at)
select ('77777777-4100-0000-0000-00000000000' || n)::uuid, '99999999-1000-0000-0000-000000004100', '99999999-0000-0000-0000-000000004100',
       '55555555-0000-0000-0000-000000004100', 'regular', n, date_trunc('hour', now()) - make_interval(days => 3 - n), date_trunc('hour', now()) - make_interval(days => 3 - n) + interval '50 minutes'
from generate_series(1, 2) n;
set role authenticated;
set request.jwt.claim.sub = 'bbbbbbbb-0000-0000-0000-000000000009';
select tutor_record_class('77777777-4100-0000-0000-000000000001', 'tutor_no_show', null, null);
select tutor_record_class('77777777-4100-0000-0000-000000000001', 'tutor_no_show', null, null);
reset role;
create temp table cp as select id from compensations where source_lesson_id = '77777777-4100-0000-0000-000000000001';
grant select on cp to authenticated;
select pg_temp.ok((select count(*) = 1 and bool_and(expires_on is null and status = 'available') from compensations where source_lesson_id = '77777777-4100-0000-0000-000000000001'),
  '강사 노쇼 → 보상권 1개(다시 저장해도 1개), 7일 기한 없음 (4100)');
set role authenticated;
set request.jwt.claim.sub = 'bbbbbbbb-0000-0000-0000-000000004100';
select pg_temp.ok((select count(*) filter (where x ->> 'lesson_id' = '77777777-4100-0000-0000-000000000001') = 1
                      and count(*) filter (where x ->> 'comp_id' = (select id::text from cp)) = 1
                      and bool_and(x ->> 'use_until' = (current_date - 20 + 27)::text) filter (where x ? 'comp_id')
                   from jsonb_array_elements(student_screen(null) -> 'makeup_rights') x),
  '학생 화면: 원래 수업 보강과 무료 보상수업이 따로 보임, 보상 사용 기한 = 수강 종료일 (4100)');
select pg_temp.ok((select count(*) > 0 and bool_and(starts_at < ((current_date - 20 + 28)::timestamp at time zone 'Asia/Seoul')) and bool_and(section = 'in_period')
                   from student_makeup_options(null, null, null, (select id from cp))),
  '보상수업 보강 가능한 날짜: 일반 보강과 같은 계산, 사용 기한 안만 (4100)');
select student_makeup_request('77777777-4100-0000-0000-000000000001', null, (select jsonb_agg(jsonb_build_object('starts_at', o.starts_at)) from (select starts_at from student_makeup_options(null, '77777777-4100-0000-0000-000000000001', null) order by starts_at limit 1) o));
select student_makeup_request(null, null, (select jsonb_agg(jsonb_build_object('starts_at', o.starts_at)) from (select starts_at from student_makeup_options(null, null, null, (select id from cp)) order by starts_at offset 1 limit 2) o), (select id from cp));
select pg_temp.ok((student_makeup_request(null, null, (select jsonb_agg(jsonb_build_object('starts_at', o.starts_at)) from (select starts_at from student_makeup_options(null, null, null, (select id from cp)) order by starts_at offset 1 limit 1) o), (select id from cp)) ->> 'repeated')::boolean
              and (student_makeup_request('77777777-4100-0000-0000-000000000001', null, (select jsonb_agg(jsonb_build_object('starts_at', o.starts_at)) from (select starts_at from student_makeup_options(null, '77777777-4100-0000-0000-000000000001', null) order by starts_at limit 1) o)) ->> 'repeated')::boolean,
  '같은 노쇼 수업: 보강 신청 1개 + 보상 신청 1개가 따로 열리고, 다시 눌러도 더 안 생김 (4100)');
reset role;
select pg_temp.ok((select count(*) = 2 and count(*) filter (where compensation_id is not null) = 1 from makeup_requests
                   where source_lesson_id = '77777777-4100-0000-0000-000000000001' and status = 'requested'),
  '열린 신청: 원래 수업 보강 1 · 보상 1 (4100)');
set role authenticated;
set request.jwt.claim.sub = 'bbbbbbbb-0000-0000-0000-000000004100';
select pg_temp.expect_error($$select student_makeup_request(null, null, '[]'::jsonb, (select id from cp))$$, '1~2개');
set request.jwt.claim.sub = 'bbbbbbbb-0000-0000-0000-000000000009';
select pg_temp.ok((select bool_or((m ->> 'compensation')::boolean) and bool_or(not (m ->> 'compensation')::boolean)
                   from jsonb_array_elements(tutor_screen('55555555-0000-0000-0000-000000004100', current_date, current_date) -> 'makeups') m),
  '강사 화면 Make-up requests: 보상 신청은 Compensation 으로 구분 (4100)');
select admin_makeup_confirm((select id from makeup_requests where compensation_id = (select id from cp) and status = 'requested'),
                            (select min(c.starts_at) from makeup_candidates c join makeup_requests r on r.id = c.request_id where r.compensation_id = (select id from cp)));
reset role;
create temp table cl as select confirmed_lesson_id as id from makeup_requests where compensation_id = (select id from cp) and status = 'confirmed';
grant select on cl to authenticated;
select pg_temp.ok((select l.kind = 'compensation' and l.compensation_id = (select id from cp) and l.makeup_of is null and l.state = 'scheduled'
                          and lms_lesson_count(l.id) is null from lessons l where l.id = (select id from cl))
              and (select status = 'used' and used_lesson_id = (select id from cl) from compensations where id = (select id from cp))
              and (select count(*) = 1 from makeup_requests where source_lesson_id = '77777777-4100-0000-0000-000000000001' and status = 'requested' and compensation_id is null),
  '운영 확정 → 보상 수업(kind compensation, 회차·차감 없음) + 보상권 used, 원래 수업 보강 신청은 그대로 (4100)');
set role authenticated;
set request.jwt.claim.sub = 'bbbbbbbb-0000-0000-0000-000000004100';
select pg_temp.ok(not exists (select 1 from jsonb_array_elements(student_screen(null) -> 'makeup_rights') x where x ? 'comp_id' and x ->> 'comp_id' is not null)
              and (select x ->> 'original_at' is not null and x ->> 'original_tutor' = 'CompTutor' and x ->> 'tutor' = 'CompTutor' and x ->> 'confirmed_at' is not null
                   from jsonb_array_elements(student_screen(null) -> 'makeup_requests') x where x ->> 'comp_id' = (select id::text from cp)),
  '확정 뒤 학생 화면: 보상 권리 빠짐, 신청 내역에 원래 수업·담당 강사·확정 날짜 (4100)');
select pg_temp.expect_error($$select student_makeup_request(null, null, '[{"starts_at":"2100-01-01T00:00:00Z"}]'::jsonb, (select id from cp))$$, '이미 날짜를 잡은');
select pg_temp.ok(true, '쓴 보상수업은 다시 신청 못 함 (중복 생성 막기, 4100)');
set request.jwt.claim.sub = 'bbbbbbbb-0000-0000-0000-000000000009';
select pg_temp.expect_error($$select admin_makeup_request(null, null, jsonb_build_array(jsonb_build_object('starts_at', ((current_date + 60)::timestamp + time '10:00') at time zone 'Asia/Seoul')), now(), (select id from cp))$$, '이미 날짜를 잡은');
select admin_void_makeup((select id from cl), '날짜 다시');
select pg_temp.ok((select status = 'available' and used_lesson_id is null from compensations where id = (select id from cp)), '운영진이 보상 수업을 없애면 보상권 다시 사용 가능 (4100)');
select pg_temp.expect_error($$select admin_makeup_request(null, null, jsonb_build_array(jsonb_build_object('starts_at', ((current_date + 60)::timestamp + time '10:00') at time zone 'Asia/Seoul')), now(), (select id from cp))$$, '사용 기한');
select pg_temp.ok(true, '사용 기한(수강 종료일) 뒤 시간은 보상 신청 거절 (4100)');
reset role;
-- 이월: 종료일 23:59 KST까지 결제한 재등록이면 그 수강권 종료일까지, 늦은 결제면 이월 안 함, 결제 기록 없는 재등록(시트)은 이월
insert into enrollments (id, student_id, seq, previous_enrollment_id, weeks, weekly_count, duration_min, start_date, base_end_date, lessons_purchased, status)
values ('99999999-1000-0000-0000-000000004101', '99999999-0000-0000-0000-000000004100', 2, '99999999-1000-0000-0000-000000004100', 4, 2, 50,
        current_date - 20 + 28, current_date - 20 + 28 + 27, 8, 'confirmed');
select pg_temp.ok(lms_comp_use_until('99999999-1000-0000-0000-000000004100') = current_date - 20 + 28 + 27, '결제 기록 없는 재등록(시트 관리)은 이월 (4100)');
insert into payments (enrollment_id, method, amount_received, paid_at, received_on, confirmed_by)
values ('99999999-1000-0000-0000-000000004101', 'bank_transfer', 100000, ((current_date - 20 + 28)::timestamp + time '00:30') at time zone 'Asia/Seoul', current_date - 20 + 28, 'aaaaaaaa-0000-0000-0000-000000000001');
select pg_temp.ok(lms_comp_use_until('99999999-1000-0000-0000-000000004100') = current_date - 20 + 27, '종료일 다음 날 결제한 재등록은 이월 안 함 (POL-RN-01, 4100)');
insert into payments (enrollment_id, method, amount_received, paid_at, received_on, confirmed_by)
values ('99999999-1000-0000-0000-000000004101', 'bank_transfer', 1000, ((current_date - 20 + 27)::timestamp + time '23:59') at time zone 'Asia/Seoul', current_date - 20 + 27, 'aaaaaaaa-0000-0000-0000-000000000001');
select pg_temp.ok(lms_comp_use_until('99999999-1000-0000-0000-000000004100') = current_date - 20 + 28 + 27
              and lms_comp_lesson_enrollment((select id from cp), current_date - 20 + 30) = '99999999-1000-0000-0000-000000004101'
              and lms_comp_lesson_enrollment((select id from cp), current_date) = '99999999-1000-0000-0000-000000004100',
  '종료일 23:59까지 결제한 재등록 → 다음 수강권 종료일까지 이월, 이월된 날짜의 보상 수업은 재등록 수강권에 붙음 (4100)');
-- 강사 노쇼를 다른 결과로 고치면: 쓰지 않은 보상권 voided + 열린 보상 신청 닫힘
set role authenticated;
set request.jwt.claim.sub = 'bbbbbbbb-0000-0000-0000-000000000009';
select admin_makeup_request(null, null, (select jsonb_agg(jsonb_build_object('starts_at', o.starts_at)) from (select starts_at from student_makeup_options('99999999-0000-0000-0000-000000004100', null, null, (select id from cp)) order by starts_at limit 1) o), now(), (select id from cp));
select tutor_record_class('77777777-4100-0000-0000-000000000001', 'student_no_show', null, null);
reset role;
select pg_temp.ok((select status = 'voided' from compensations where id = (select id from cp))
              and not exists (select 1 from makeup_requests where compensation_id = (select id from cp) and status in ('requested', 'countered')),
  '강사 노쇼를 고치면 보상권 voided + 열린 보상 신청 닫힘 (기록은 남김, 4100)');

-- ---------- 4200 강사 현지 06:00~22:30 시작 (DB에서 막기) ----------
reset request.jwt.claim.sub;
reset role;
insert into tutors (id, name, country, timezone) values ('55555555-0000-0000-0000-000000004200', 'EarlyTutor', 'Australia', 'Australia/Melbourne');
select pg_temp.ok(not lms_tutor_available('55555555-0000-0000-0000-000000004200', timestamptz '2026-11-09 10:00 Australia/Melbourne'),
  '가능 시간을 안 넣은 강사는 어느 시간도 예약 가능 아님 (4200)');
insert into tutor_availability (tutor_id, weekday, start_local, end_local, timezone, effective_from)
values ('55555555-0000-0000-0000-000000004200', 1, '00:00', '23:30', 'Australia/Melbourne', '2026-01-01'),
       ('55555555-0000-0000-0000-000000004200', 2, '00:00', '23:30', 'Australia/Melbourne', '2026-01-01');
select pg_temp.ok(not lms_tutor_available('55555555-0000-0000-0000-000000004200', timestamptz '2026-11-09 05:30 Australia/Melbourne')
              and lms_tutor_available('55555555-0000-0000-0000-000000004200', timestamptz '2026-11-09 06:00 Australia/Melbourne')
              and lms_tutor_available('55555555-0000-0000-0000-000000004200', timestamptz '2026-11-09 22:30 Australia/Melbourne')
              and not lms_tutor_available('55555555-0000-0000-0000-000000004200', timestamptz '2026-11-09 23:00 Australia/Melbourne'),
  '강사가 하루 종일 열어 둬도 현지 06:00 전·22:30 뒤 시작은 불가, 06:00·22:30은 가능 (4200)');
select pg_temp.ok(lms_makeup_conflict('55555555-0000-0000-0000-000000004200', '99999999-0000-0000-0000-000000004100',
                    timestamptz '2026-11-10 05:00 Australia/Melbourne', timestamptz '2026-11-10 05:50 Australia/Melbourne', true) like '%06:00~22:30%'
              and lms_makeup_conflict('55555555-0000-0000-0000-000000004200', '99999999-0000-0000-0000-000000004100',
                    timestamptz '2026-11-10 04:00 Asia/Seoul', timestamptz '2026-11-10 04:50 Asia/Seoul', true) is null,
  '보강 확정·강사 답 검사: 현지 05:00은 거절, 한국 04:00(멜버른 06:00)은 한국시간 제한 없이 가능 (4200)');

-- ---------- 4300 학생 관리 ①~⑥ (H26(44)) ----------
reset request.jwt.claim.sub;
reset role;
-- 가짜: 한국 거주 강사 R(월~금 06:00~22:30 가능)·대체강사 S, 학생 P 주 2회(월·화 20:00 KST) 40분 4주, 3주 전 화요일 시작 → 마지막 정규 = 다음 주 월요일 = 최종 종료일
create temp table t4300 as select (date_trunc('week', current_date))::date as mon;
grant select on t4300 to authenticated;
insert into tutors (id, name, country, timezone) values
  ('55555555-0000-0000-0000-000000004300', 'RegTutor', 'Korea', 'Asia/Seoul'),
  ('55555555-0000-0000-0000-000000004301', 'SubTutor', 'Canada', 'America/Toronto');
insert into tutor_availability (tutor_id, weekday, start_local, end_local, timezone, effective_from)
select '55555555-0000-0000-0000-000000004300', w, '06:00', '22:30', 'Asia/Seoul', '2026-01-01' from generate_series(1, 5) w;
insert into students (id, name_ko, name_en, display_name, timezone, email) values
  ('99999999-0000-0000-0000-000000004300', '김서연', 'Kim Seoyeon', 'Sarah', 'Asia/Seoul', 'p4300@example.com'),
  ('99999999-0000-0000-0000-000000004301', '박다른', 'Park Dareun', null, 'Asia/Seoul', null);
insert into enrollments (id, student_id, seq, weeks, weekly_count, duration_min, start_date, base_end_date, lessons_purchased, status)
select '99999999-1000-0000-0000-000000004300', '99999999-0000-0000-0000-000000004300', 1, 4, 2, 40, mon - 20, mon + 7, 8, 'active' from t4300;
insert into enrollments (id, student_id, seq, weeks, weekly_count, duration_min, start_date, base_end_date, lessons_purchased, status)
select '99999999-1000-0000-0000-000000004301', '99999999-0000-0000-0000-000000004301', 1, 4, 1, 40, mon - 20, mon + 7, 4, 'active' from t4300;
insert into regular_schedules (student_id, tutor_id, weekday, start_time_kst, duration_min, effective_from)
select '99999999-0000-0000-0000-000000004300', '55555555-0000-0000-0000-000000004300', w, '20:00', 40, mon - 20 from t4300, (values (1), (2)) v(w);
insert into lessons (enrollment_id, student_id, tutor_id, kind, seq, starts_at, ends_at)
select '99999999-1000-0000-0000-000000004300', '99999999-0000-0000-0000-000000004300', '55555555-0000-0000-0000-000000004300', 'regular',
       row_number() over (order by d), (d::date + time '20:00') at time zone 'Asia/Seoul', (d::date + time '20:40') at time zone 'Asia/Seoul'
from t4300, generate_series(mon - 20, mon + 7, interval '1 day') g(d)
where extract(dow from d::date) in (1, 2);
select pg_temp.ok((select count(*) from lessons where enrollment_id = '99999999-1000-0000-0000-000000004300') = 8
              and (select max(kst_date) from lessons where enrollment_id = '99999999-1000-0000-0000-000000004300') = (select mon + 7 from t4300),
  '4300 가짜 데이터: 정규 8회, 마지막 수업 = 최종 종료일');
-- 다른 학생 수업: 다음 주 월 20:50~21:25 (강사 R) — P 의 20:00~20:40 뒤 10분 쉬고
insert into lessons (enrollment_id, student_id, tutor_id, kind, seq, starts_at, ends_at)
select '99999999-1000-0000-0000-000000004301', '99999999-0000-0000-0000-000000004301', '55555555-0000-0000-0000-000000004300', 'regular', 1,
       (mon + 7 + time '20:50') at time zone 'Asia/Seoul', (mon + 7 + time '21:25') at time zone 'Asia/Seoul' from t4300;
insert into app_users (auth_user_id, role, tutor_id) values
  ('bbbbbbbb-0000-0000-0000-000000004300', 'tutor', '55555555-0000-0000-0000-000000004300'),
  ('bbbbbbbb-0000-0000-0000-000000004301', 'tutor', '55555555-0000-0000-0000-000000004301');

select pg_temp.ok(lms_tutor_student_label('Kim Seoyeon', 'Sarah') = 'Kim Seoyeon (Sarah)' and lms_tutor_student_label('Kim Seoyeon', null) = 'Kim Seoyeon'
              and lms_tutor_student_label('Kim Seoyeon', ' kim seoyeon ') = 'Kim Seoyeon',
  '④ 강사 화면 이름: 영문 이름 (Preferred Name), 없거나 같으면 괄호 없이 (4300)');

set request.jwt.claims = '{"aal":"aal2"}';
set role authenticated;
set request.jwt.claim.sub = 'bbbbbbbb-0000-0000-0000-000000000009';   -- 운영자
-- ① 미리 보기: 다음 주 월요일부터 월 22:00 · 화 20:00 → 옮길 수업 1회(다음 주 월), 문제 없음
create temp view p4300 as select mon + 7 as from_day from t4300;
grant select on p4300 to authenticated;
select pg_temp.ok((select (r ->> 'ok')::boolean and jsonb_array_length(r -> 'moved') = 1 and jsonb_array_length(r -> 'problems') = 0
                          and (r -> 'moved' -> 0 ->> 'to')::timestamptz = ((select from_day from p4300) + time '22:00') at time zone 'Asia/Seoul'
                          and (select count(*) from jsonb_array_elements(r -> 'kept') k where k ->> 'why' = 'before_from') >= 0
                   from admin_regular_change('99999999-0000-0000-0000-000000004300', '[{"weekday":1,"time":"22:00"},{"weekday":2,"time":"20:00"}]', (select from_day from p4300), null, true) r),
  '① 미리 보기: 적용 시작일 이후 정규 수업만 새 시각으로, 지난 수업·적용 전 수업은 그대로 (4300)');
select pg_temp.ok((select not (r ->> 'ok')::boolean and r -> 'problems' -> 0 ->> 'why' = 'tutor_busy' and r -> 'problems' -> 0 ->> 'other' like '박다른%'
                   from admin_regular_change('99999999-0000-0000-0000-000000004300', '[{"weekday":1,"time":"20:30"},{"weekday":2,"time":"20:00"}]', (select from_day from p4300), null, true) r),
  '① 검사: 강사의 다른 학생 수업과 겹치면 문제 표시(누구 수업인지) (4300)');
select pg_temp.ok((select not (r ->> 'ok')::boolean and r -> 'problems' -> 0 ->> 'why' = 'tutor_busy'
                   from admin_regular_change('99999999-0000-0000-0000-000000004300', '[{"weekday":1,"time":"21:30"},{"weekday":2,"time":"20:00"}]', (select from_day from p4300), null, true) r),
  '① 검사: 앞 수업 끝나고 10분 안 쉬면 문제 (21:25 끝 → 21:30 시작 불가) (4300)');
select pg_temp.ok((select not (r ->> 'ok')::boolean and r -> 'problems' -> 0 ->> 'why' = 'tutor_hours_range'
                   from admin_regular_change('99999999-0000-0000-0000-000000004300', '[{"weekday":1,"time":"23:00"},{"weekday":2,"time":"20:00"}]', (select from_day from p4300), null, true) r),
  '① 검사: 강사 현지 06:00~22:30 밖 시작은 문제 (4300)');
select pg_temp.ok((select not (r ->> 'ok')::boolean and r -> 'problems' -> 0 ->> 'why' = 'after_end'
                   from admin_regular_change('99999999-0000-0000-0000-000000004300', '[{"weekday":3,"time":"20:00"},{"weekday":4,"time":"20:00"}]', (select from_day from p4300), null, true) r),
  '② 마지막 수업이 최종 종료일을 넘으면 문제(after_end) — 종료일 연장 안 함 (4300)');
select pg_temp.ok((select not (r ->> 'ok')::boolean and r -> 'problems' -> 0 ->> 'why' = 'tutor_unavailable'
                   from admin_regular_change('99999999-0000-0000-0000-000000004300', '[{"weekday":6,"time":"20:00"},{"weekday":0,"time":"20:00"}]', (select from_day from p4300), null, true) r),
  '① 검사: 강사가 열어 두지 않은 요일(토)은 문제 (4300)');
select pg_temp.expect_error($$select admin_regular_change('99999999-0000-0000-0000-000000004300', '[{"weekday":1,"time":"21:30"}]', (select from_day from p4300), null, true)$$, '주 2회');
select pg_temp.expect_error($$select admin_regular_change('99999999-0000-0000-0000-000000004300', '[{"weekday":1,"time":"21:15"},{"weekday":2,"time":"20:00"}]', (select from_day from p4300), null, true)$$, '30분 단위');
select pg_temp.expect_error($$select admin_regular_change('99999999-0000-0000-0000-000000004300', '[{"weekday":1,"time":"20:00"},{"weekday":2,"time":"20:00"}]', (select from_day from p4300), null, true)$$, '같습니다');
select pg_temp.expect_error($$select admin_regular_change('99999999-0000-0000-0000-000000004300', '[{"weekday":1,"time":"22:00"},{"weekday":2,"time":"20:00"}]', (select from_day from p4300), null, false)$$, '사유');
select pg_temp.expect_error($$select admin_regular_change('99999999-0000-0000-0000-000000004300', '[{"weekday":3,"time":"20:00"},{"weekday":4,"time":"20:00"}]', (select from_day from p4300), '사유', false)$$, '문제가 1건');
select pg_temp.ok(true, '① 주 횟수 변경·30분 단위 아님·같은 일정·사유 없음·문제 있는 저장은 거절 (4300)');
-- 저장
select pg_temp.ok((select (r ->> 'ok')::boolean and (r ->> 'moved')::int = 1
                   from admin_regular_change('99999999-0000-0000-0000-000000004300', '[{"weekday":1,"time":"22:00"},{"weekday":2,"time":"20:00"}]', (select from_day from p4300), '학생 요청 (카톡)', false) r),
  '① 저장 성공 (4300)');
reset role;
select pg_temp.ok((select starts_at = ((select from_day from p4300) + time '22:00') at time zone 'Asia/Seoul' and ends_at - starts_at = interval '40 minutes'
                   from lessons where enrollment_id = '99999999-1000-0000-0000-000000004300' and seq = 8)
              and (select count(*) from lessons where enrollment_id = '99999999-1000-0000-0000-000000004300' and kind = 'regular') = 8
              and (select starts_at = ((select from_day from p4300) - 7 + time '20:00') at time zone 'Asia/Seoul' from lessons where enrollment_id = '99999999-1000-0000-0000-000000004300' and seq = 6),
  '① 저장 뒤: 다음 주 월 수업만 22:00 으로, 회차·지난 수업 그대로 (4300)');
select pg_temp.ok((select count(*) = 2 and bool_and(effective_to = (select from_day from p4300) - 1) from regular_schedules where student_id = '99999999-0000-0000-0000-000000004300' and effective_from < (select from_day from p4300))
              and (select count(*) = 2 and bool_and(effective_from = (select from_day from p4300)) from regular_schedules where student_id = '99999999-0000-0000-0000-000000004300' and effective_to is null)
              and (select count(*) = 1 and bool_and(student_sent_at is null and tutor_sent_at is null and reason = '학생 요청 (카톡)' and jsonb_array_length(moved) = 1) from regular_changes where student_id = '99999999-0000-0000-0000-000000004300'),
  '① 정규 일정 표: 예전 줄은 전날까지, 새 줄 2개 · 변경 기록(사유·옮긴 수업)과 안내 미발송 (4300)');
set role authenticated;
set request.jwt.claim.sub = 'bbbbbbbb-0000-0000-0000-000000000009';
select pg_temp.ok((select (r ->> 'ok')::boolean from admin_regular_change('99999999-0000-0000-0000-000000004300', '[{"weekday":1,"time":"22:00"},{"weekday":2,"time":"20:30"}]', (select from_day from p4300), '한 번 더', false) r)
              and (select (r ->> 'ok')::boolean from admin_regular_change('99999999-0000-0000-0000-000000004300', '[{"weekday":1,"time":"22:00"},{"weekday":2,"time":"20:00"}]', (select from_day from p4300), '다시 원래대로', false) r),
  '① 같은 적용일로 두 번 더 바꿔도 저장됨 (예정 일정 줄은 효력 없는 날짜로 치움, 지우지 않음) (4300)');
-- A-03) 예정 변경 취소 (20261107): 지금 일정(월·화 20:00)과 같은 시간을 오늘부터 → 전에는 '같습니다' 거절, 이제는 예정 줄 취소 + 옮겨 둔 수업 원복
create temp view a03 as select (now() at time zone 'Asia/Seoul')::date as today;
grant select on a03 to authenticated;
select pg_temp.ok((select (r ->> 'ok')::boolean and (r ->> 'cancels_pending')::boolean and jsonb_array_length(r -> 'moved') = 1 and jsonb_array_length(r -> 'problems') = 0
                          and (r -> 'moved' -> 0 ->> 'to')::timestamptz = ((select from_day from p4300) + time '20:00') at time zone 'Asia/Seoul'
                   from admin_regular_change('99999999-0000-0000-0000-000000004300', '[{"weekday":1,"time":"20:00"},{"weekday":2,"time":"20:00"}]', (select today from a03), null, true) r),
  'A-03 미리 보기: 적용 전 변경이 있으면 원래 시간으로 되돌리는 저장 허용(cancels_pending), 옮겨 둔 다음 주 월 수업이 20:00 으로 돌아옴 (4300)');
select pg_temp.ok((select (r ->> 'ok')::boolean and (r ->> 'moved')::int = 1
                   from admin_regular_change('99999999-0000-0000-0000-000000004300', '[{"weekday":1,"time":"20:00"},{"weekday":2,"time":"20:00"}]', (select today from a03), '예정 변경 취소', false) r),
  'A-03 저장 성공 (4300)');
reset role;
select pg_temp.ok((select starts_at = ((select from_day from p4300) + time '20:00') at time zone 'Asia/Seoul' from lessons where enrollment_id = '99999999-1000-0000-0000-000000004300' and seq = 8)
              and (select count(*) from lessons where enrollment_id = '99999999-1000-0000-0000-000000004300' and kind = 'regular' and state = 'scheduled') = 8
              and (select count(*) = 2 and bool_and(start_time_kst = '20:00' and effective_from = (select mon - 20 from t4300) and change_reason like '%다시 이어 감: 예정 변경 취소%') from regular_schedules where student_id = '99999999-0000-0000-0000-000000004300' and effective_to is null)
              and (select count(*) from regular_schedules where student_id = '99999999-0000-0000-0000-000000004300' and effective_from > date '1950-01-01') = 2
              and not exists (select 1 from regular_schedules where student_id = '99999999-0000-0000-0000-000000004300' and effective_from > (select today from a03) and effective_from > date '1950-01-01')
              and (select count(*) from regular_changes where student_id = '99999999-0000-0000-0000-000000004300') = 4
              and (select count(*) from credit_ledger cl join enrollment_periods ep on ep.id = cl.period_id join enrollments en on en.id = ep.enrollment_id where en.student_id = '99999999-0000-0000-0000-000000004300') = 0,
  'A-03 저장 뒤: 다음 주 월 수업 20:00 원복, 수업 8회 그대로, 원래 줄 그대로 이어 감(쪼개지 않음)·예정 줄은 치워 둠, 변경 기록 +1, 변경권 변화 없음 (4300)');
set role authenticated;
set request.jwt.claim.sub = 'bbbbbbbb-0000-0000-0000-000000000009';
select pg_temp.expect_error($$select admin_regular_change('99999999-0000-0000-0000-000000004300', '[{"weekday":1,"time":"20:00"},{"weekday":2,"time":"20:00"}]', (select today from a03), null, true)$$, '같습니다');
select pg_temp.ok(true, 'A-03: 예정 변경이 없으면 같은 일정은 전처럼 거절 (4300)');
select pg_temp.ok((select (x ->> 'notice_pending')::boolean and x ->> 'status' = 'active' and x ->> 'tutor' = 'RegTutor'
                   from jsonb_array_elements(admin_students()) x where x ->> 'code' = (select code from students where id = '99999999-0000-0000-0000-000000004300')),
  '운영진 학생 목록: 수강 상태·강사·안내 안 보냄 표시 (4300)');
select admin_regular_change_sent(id, 'student') from regular_changes where student_id = '99999999-0000-0000-0000-000000004300';
select pg_temp.ok((select bool_and(student_sent_at is not null and tutor_sent_at is null) from regular_changes where student_id = '99999999-0000-0000-0000-000000004300'),
  '③ 학생 [발송 완료]만 기록, 강사 안내는 따로 (4300)');
select admin_regular_change_sent(id, 'tutor') from regular_changes where student_id = '99999999-0000-0000-0000-000000004300';
select pg_temp.ok((select not (x ->> 'notice_pending')::boolean from jsonb_array_elements(admin_students()) x where x ->> 'name_ko' = '김서연'), '③ 둘 다 보내면 안내 완료 (4300)');
-- 강사는 정규 일정 변경·종료일 연장 불가
set request.jwt.claim.sub = 'bbbbbbbb-0000-0000-0000-000000004300';
select pg_temp.expect_error($$select admin_regular_change('99999999-0000-0000-0000-000000004300', '[{"weekday":1,"time":"21:00"},{"weekday":2,"time":"20:00"}]', (select from_day from p4300), 'x', true)$$, '운영자|42501');
select pg_temp.expect_error($$select admin_extend_enrollment('99999999-1000-0000-0000-000000004300', (select from_day from p4300) + 7, 'admin_exception', 'x')$$, '운영자|42501');
select pg_temp.expect_error($$select admin_student_update('99999999-0000-0000-0000-000000004300', '{"level":"Advanced"}')$$, '운영자|42501');
select pg_temp.expect_error($$select admin_student_detail('99999999-0000-0000-0000-000000004300')$$, '운영자|42501');
select pg_temp.ok(admin_students() is null, '강사는 운영진 학생 목록·상세·정보 수정 함수 사용 불가 (4300)');

-- ⑥ 강사 접근: 정규 담당 R = 전체(이메일 포함)·수정 가능 / 미배정 S = 차단 / 대체수업 확정 뒤 S = 열람만, 이메일 없음, 끝나고 24시간 뒤 차단
select pg_temp.ok((select p ->> 'access' = 'regular' and p -> 'student' ->> 'email' = 'p4300@example.com' and p -> 'student' ->> 'label' = 'Kim Seoyeon (Sarah)'
                          and p -> 'student' ->> 'name_ko' is null and jsonb_array_length(p -> 'slots') = 2 and p -> 'enrollment' ->> 'final_end_date' is not null
                   from tutor_student_profile('99999999-0000-0000-0000-000000004300') p),
  '⑥ 정규 담당 강사: 프로필·이메일·정규 일정·수강 정보 보임, 한국 이름은 안 보임 (4300)');
select tutor_student_update('99999999-0000-0000-0000-000000004300', '{"level":"Intermediate","job":"Software engineer","interests":"  ","correction_style":"major_only"}');
select pg_temp.expect_error($$select tutor_student_update('99999999-0000-0000-0000-000000004300', '{"level":"B2"}')$$, 'rubric');
select pg_temp.expect_error($$select tutor_student_update('99999999-0000-0000-0000-000000004300', '{"email":"x@y.z"}')$$, 'cannot be changed|42501');
reset role;
select pg_temp.ok((select level = 'Intermediate' and level_by = 'bbbbbbbb-0000-0000-0000-000000004300' and level_at is not null and job = 'Software engineer' and interests is null
                          and correction_style = 'major_only' and answers_at is not null from students where id = '99999999-0000-0000-0000-000000004300')
              and (select count(*) from student_profile_edits where student_id = '99999999-0000-0000-0000-000000004300' and edited_role = 'tutor') = 3,
  '⑥ 정규 강사 수정: 4단계 레벨만, 빈 답은 미응답(null), 이메일 수정 불가, 칸마다 누가 언제 기록 (4300)');
set role authenticated;
set request.jwt.claim.sub = 'bbbbbbbb-0000-0000-0000-000000004301';   -- 대체강사 S (아직 배정 전)
select pg_temp.expect_error($$select tutor_student_profile('99999999-0000-0000-0000-000000004300')$$, 'not assigned|42501');
select pg_temp.ok(true, '⑥ 맡지 않은 학생은 URL·API 로도 차단 (4300)');
reset role;
update lessons set tutor_id = '55555555-0000-0000-0000-000000004301', original_tutor_id = '55555555-0000-0000-0000-000000004300'
where enrollment_id = '99999999-1000-0000-0000-000000004300' and seq = 8;   -- 다음 주 월 수업을 대체강사 S 가 맡음
set role authenticated;
set request.jwt.claim.sub = 'bbbbbbbb-0000-0000-0000-000000004301';
select pg_temp.ok((select p ->> 'access' = 'substitute' and p -> 'student' ->> 'email' is null and p -> 'student' ->> 'level' = 'Intermediate'
                          and p -> 'student' ->> 'label' = 'Kim Seoyeon (Sarah)' and jsonb_array_length(p -> 'upcoming') = 1
                          and p -> 'enrollment' ? 'duration_min' and not (p -> 'enrollment' ? 'extensions')
                   from tutor_student_profile('99999999-0000-0000-0000-000000004300') p),
  '⑥ 대체강사: 대체수업 확정 뒤 프로필·레벨·선호 열람, 이메일·연장 기록은 안 보임, 자기 대체수업만 (4300)');
select pg_temp.expect_error($$select tutor_student_update('99999999-0000-0000-0000-000000004300', '{"level":"Advanced"}')$$, 'regular tutor|42501');
select pg_temp.ok((select count(*) from tutor_my_students() where email is null) = 1, '⑥ 대체강사는 수정 불가, 목록에도 이메일 없이 (4300)');
set request.jwt.claim.sub = 'bbbbbbbb-0000-0000-0000-000000004300';   -- 정규 강사 R 은 대체 뒤에도 그대로
select pg_temp.ok((select p ->> 'access' = 'regular' from tutor_student_profile('99999999-0000-0000-0000-000000004300') p), '⑥ 정규 담당 강사 권한은 대체수업과 무관하게 유지 (4300)');
reset role;
-- 대체수업이 끝나고 24시간 지나면 차단 (시각을 과거로 옮겨 흉내)
update lessons set starts_at = now() - interval '26 hours', ends_at = now() - interval '25 hours' where enrollment_id = '99999999-1000-0000-0000-000000004300' and seq = 8;
set role authenticated;
set request.jwt.claim.sub = 'bbbbbbbb-0000-0000-0000-000000004301';
select pg_temp.expect_error($$select tutor_student_profile('99999999-0000-0000-0000-000000004300')$$, 'not assigned|42501');
select pg_temp.ok(true, '⑥ 대체수업 종료 24시간 뒤 자동 차단 (4300)');
reset role;
update lessons set tutor_id = '55555555-0000-0000-0000-000000004300', original_tutor_id = null,
  starts_at = ((select from_day from p4300) + time '22:00') at time zone 'Asia/Seoul', ends_at = ((select from_day from p4300) + time '22:40') at time zone 'Asia/Seoul'
where enrollment_id = '99999999-1000-0000-0000-000000004300' and seq = 8;

-- 운영진 종료일 연장: 한 줄 추가, 회차 그대로, 예정 수업보다 앞으로 못 줄임, 다음 수강권과 겹치면 거절
set role authenticated;
set request.jwt.claim.sub = 'bbbbbbbb-0000-0000-0000-000000000009';
select pg_temp.expect_error($$select admin_extend_enrollment('99999999-1000-0000-0000-000000004300', (select from_day from p4300) + 7, 'admin_exception', '  ')$$, '사유');
select pg_temp.expect_error($$select admin_extend_enrollment('99999999-1000-0000-0000-000000004300', (select from_day from p4300) - 1, 'correction', '정정')$$, '줄일 수 없습니다');
select pg_temp.ok((select (r ->> 'days')::int = 7 and (r ->> 'final_end_date')::date = (select from_day from p4300) + 7
                   from admin_extend_enrollment('99999999-1000-0000-0000-000000004300', (select from_day from p4300) + 7, 'student_long_term_leave', '학생 입원 2주 — 대표 승인') r),
  '운영진 종료일 연장: 새 최종 종료일 → +7일 한 줄 (4300)');
reset role;
select pg_temp.ok((select final_end_date = (select from_day from p4300) + 7 and extension_days = 7 from enrollments where id = '99999999-1000-0000-0000-000000004300')
              and (select count(*) from lessons where enrollment_id = '99999999-1000-0000-0000-000000004300') = 8
              and (select count(*) = 1 and bool_and(auto_source is null and note like '학생 입원%') from enrollment_extensions where enrollment_id = '99999999-1000-0000-0000-000000004300'),
  '연장 뒤: 최종 종료일만 바뀌고 수업 회차 그대로, 휴무 자동 연장 줄과 구분 (4300)');
insert into enrollments (id, student_id, seq, previous_enrollment_id, weeks, weekly_count, duration_min, start_date, base_end_date, lessons_purchased, status)
select '99999999-1000-0000-0000-000000004302', '99999999-0000-0000-0000-000000004300', 2, '99999999-1000-0000-0000-000000004300', 4, 2, 40, mon + 15, mon + 42, 8, 'confirmed' from t4300;
set role authenticated;
set request.jwt.claim.sub = 'bbbbbbbb-0000-0000-0000-000000000009';
select pg_temp.expect_error($$select admin_extend_enrollment('99999999-1000-0000-0000-000000004300', (select from_day from p4300) + 10, 'admin_exception', '더')$$, '다음 수강권');
select pg_temp.ok(true, '연장이 다음 수강권 기간과 겹치면 거절 (4300)');
-- 운영진 정보 수정 + 상세
select admin_student_update('99999999-0000-0000-0000-000000004300', '{"display_name":"Sarah","city":"Toronto","country":"Canada","timezone":"America/Toronto","level_note":"A2/B1 (시트)","class_note_url":"https://docs.google.com/document/d/x"}');
select pg_temp.expect_error($$select admin_student_update('99999999-0000-0000-0000-000000004300', '{"timezone":"Mars/Base"}')$$, 'time zone');
select pg_temp.expect_error($$select admin_student_update('99999999-0000-0000-0000-000000004300', '{"email":"nope"}')$$, 'email');
select pg_temp.ok((select d -> 'student' ->> 'name_ko' = '김서연' and d -> 'student' ->> 'timezone' = 'America/Toronto' and d -> 'student' ->> 'level_note' = 'A2/B1 (시트)'
                          and jsonb_array_length(d -> 'changes') = 4 and jsonb_array_length(d -> 'enrollments') = 2 and (d -> 'edits' -> 0 ->> 'role') = 'admin'
                          and (d -> 'enrollment' ->> 'seq')::int = 2 and (d -> 'enrollments' -> 1 ->> 'seq')::int = 1
                   from admin_student_detail('99999999-0000-0000-0000-000000004300') d),
  '운영진 상세: 한국 이름·바뀐 시간대·예전 레벨 참고·정규 변경 기록·수강권·수정 기록·연장 기록 (4300)');
reset request.jwt.claim.sub;
reset role;

-- ---------- 4310 ⑤ 시트 Student Info 비교·승인 ----------
reset request.jwt.claim.sub;
reset role;
insert into sheet_student_info (sheet_name, row_no, enrollment_status, student_name, preferred_name, residence, self_intro, gender_age, email, level, class_type, docs_link)
values ('RegTutor_Class record', 2, 'Active', '김서연', 'Sarah', 'Melbourne, Australia', '✅Job: Nurse', 'F / 30s', 'p4300@example.com', 'A2/B1', 'free convo', '김서연_RegTutor'),
       ('RegTutor_Class record', 3, 'Completed', 'Park Dareun', null, 'Korea', null, null, 'x@example.com', 'B1', null, null),
       ('RegTutor_Class record', 4, 'Completed', '아무개', null, 'Korea', null, null, null, null, null, null);
set request.jwt.claims = '{"aal":"aal2"}';
set role authenticated;
set request.jwt.claim.sub = 'bbbbbbbb-0000-0000-0000-000000004300';   -- 강사
select pg_temp.ok(admin_sheet_rows() is null, '⑤ 강사는 시트 비교 표를 못 봄 (4310)');
select pg_temp.expect_error($$select admin_sheet_row_match((select id from sheet_student_info where row_no = 2), '99999999-0000-0000-0000-000000004300')$$, '운영자|42501');
set request.jwt.claim.sub = 'bbbbbbbb-0000-0000-0000-000000000009';   -- 운영자
select pg_temp.ok((select (x -> 'suggest' ->> 'student_id') = '99999999-0000-0000-0000-000000004300' and x -> 'suggest' ->> 'how' = 'name_ko' from jsonb_array_elements(admin_sheet_rows()) x where (x ->> 'row_no')::int = 2)
              and (select (x -> 'suggest' ->> 'student_id') = '99999999-0000-0000-0000-000000004301' and x -> 'suggest' ->> 'how' = 'name_en' from jsonb_array_elements(admin_sheet_rows()) x where (x ->> 'row_no')::int = 3)
              and (select x -> 'suggest' is null or x -> 'suggest' = 'null'::jsonb from jsonb_array_elements(admin_sheet_rows()) x where (x ->> 'row_no')::int = 4),
  '⑤ LMS 학생 자동 제안: 한국 이름 같음 / 영문 이름 같음 / 없으면 제안 없음 (4310)');
select admin_sheet_row_match((select id from sheet_student_info where row_no = 2), '99999999-0000-0000-0000-000000004300');
select admin_student_update('99999999-0000-0000-0000-000000004300', '{"level_note":"A2/B1","gender_age":"F / 30s"}');
select admin_sheet_row_done((select id from sheet_student_info where row_no = 2), '2칸 반영');
select pg_temp.ok((select student_id = '99999999-0000-0000-0000-000000004300' and done_at is not null and done_note = '2칸 반영' from sheet_student_info where row_no = 2)
              and (select level_note = 'A2/B1' and gender_age = 'F / 30s' and level = 'Intermediate' from students where id = '99999999-0000-0000-0000-000000004300'),
  '⑤ 짝 정하기 → 체크한 칸만 반영(레벨 4단계 값은 그대로) → 끝 표시 (4310)');
select admin_sheet_row_done((select id from sheet_student_info where row_no = 2), null, true);
select pg_temp.ok((select done_at is null from sheet_student_info where row_no = 2), '⑤ 다시 열기 (4310)');
reset request.jwt.claim.sub;
reset role;

-- ---------- 4500 Work QA(11/4) 수정: 예약 확정 검사 · 권리 정합성 · 변경권 수동 조정 ----------
-- 강사 QA(정오 시간대, 매일 열어 둠) · 학생 QA(4주·주2회·20분, 변경권 2개). 기준 시각 q0 = 지금 정시
reset request.jwt.claim.sub;
reset role;
insert into tutors (id, name, country, timezone) values ('55555555-0000-0000-0000-000000004500', 'QaTutor', 'Korea', pg_temp.noon_tz());
select pg_temp.open_all('55555555-0000-0000-0000-000000004500');
insert into app_users (auth_user_id, role, tutor_id) values ('bbbbbbbb-0000-0000-0000-000000004500', 'tutor', '55555555-0000-0000-0000-000000004500');
insert into students (id, name_ko, name_en) values ('99999999-0000-0000-0000-000000004500', '큐에이', 'QA S');
insert into app_users (auth_user_id, role, student_id) values ('bbbbbbbb-0000-0000-0000-000000004501', 'student', '99999999-0000-0000-0000-000000004500');
insert into enrollments (id, student_id, seq, weeks, weekly_count, duration_min, start_date, base_end_date, lessons_purchased, status)
values ('99999999-1000-0000-0000-000000004500', '99999999-0000-0000-0000-000000004500', 1, 4, 2, 20, current_date - 3, current_date - 3 + 27, 8, 'active');
insert into enrollment_periods (id, enrollment_id, idx, start_date, end_date, credits_granted)
values ('99999999-2000-0000-0000-000000004500', '99999999-1000-0000-0000-000000004500', 1, current_date - 3, current_date - 3 + 27, 2);
create temp table q0 as select date_trunc('hour', now()) as t;
grant select on q0 to authenticated;
-- 수업: 1 = 2일 뒤 +2h (보강 신청용) · 2 = 3일 뒤 +2h · 3 = 4일 뒤 +2h · 4 = 어제 (노쇼용) · 5 = 5일 뒤 +2h
insert into lessons (id, enrollment_id, student_id, tutor_id, kind, seq, starts_at, ends_at)
select ('77777777-4500-0000-0000-00000000000' || n)::uuid, '99999999-1000-0000-0000-000000004500', '99999999-0000-0000-0000-000000004500',
       '55555555-0000-0000-0000-000000004500', 'regular', n, t + o, t + o + interval '20 minutes'
from q0, (values (1, interval '2 days 2 hours'), (2, interval '3 days 2 hours'), (3, interval '4 days 2 hours'), (4, interval '-1 day'), (5, interval '5 days 2 hours')) v(n, o);
create or replace function pg_temp.qbal() returns int language sql as $$ select credit_balance('99999999-2000-0000-0000-000000004500') $$;
create or replace function pg_temp.qrights() returns int language sql as $$
  select jsonb_array_length(student_screen('99999999-0000-0000-0000-000000004500') -> 'makeup_rights') $$;
create or replace function pg_temp.qcand(req uuid) returns uuid language sql as $$
  select id from makeup_candidates where request_id = req and proposed_by = 'student' order by starts_at limit 1 $$;

-- QA-01 C: 대체강사 판정에도 현지 06:00~22:30 시작 규칙 (내부 함수라 superuser 로 확인)
select pg_temp.ok(lms_sub_conflict('55555555-0000-0000-0000-000000004500', (select t from q0) + interval '2 days 17 hours', (select t from q0) + interval '2 days 17 hours 20 minutes', null) like '%06:00~22:30%'
              and lms_sub_conflict('55555555-0000-0000-0000-000000004500', (select t from q0) + interval '2 days 2 hours 30 minutes', (select t from q0) + interval '2 days 2 hours 50 minutes', null) is null,
  'QA-01 C: 대체강사 현지 05:00 시작은 거절, 14:30 은 가능 (4500)');
set role authenticated;
set request.jwt.claim.sub = 'bbbbbbbb-0000-0000-0000-000000000009';   -- 운영자
-- 수업 1 정상 취소(변경권 2→1) → 보강 신청 후보 2개 (2일 뒤 14:30 · 3일 뒤 14:30)
select admin_change_lesson('c4500000-0000-0000-0000-000000000001', '77777777-4500-0000-0000-000000000001', 'student', now(), false);
select pg_temp.ok(pg_temp.qbal() = 1 and pg_temp.qrights() = 1, '4500 준비: 정상 취소 → 변경권 1, 보강권 1');
create temp table q1 as select (admin_makeup_request('77777777-4500-0000-0000-000000000001', null,
  jsonb_build_array(jsonb_build_object('starts_at', (select t from q0) + interval '2 days 2 hours 30 minutes'), jsonb_build_object('starts_at', (select t from q0) + interval '3 days 2 hours 30 minutes')), now())
  ->> 'makeup_request_id')::uuid as id;
grant select on q1 to authenticated;
-- QA-01 A: 후보가 생긴 뒤 강사가 그 요일을 닫음 → 강사 '가능' 답·운영진 확정 모두 거절, 강사 화면 busy. 그날만 다시 열면 확정됨
reset role;
update tutor_availability set end_local = '13:00' where tutor_id = '55555555-0000-0000-0000-000000004500'
  and weekday = extract(dow from ((select t from q0) + interval '2 days 2 hours 30 minutes') at time zone (select timezone from tutors where id = '55555555-0000-0000-0000-000000004500'));
set role authenticated;
set request.jwt.claim.sub = 'bbbbbbbb-0000-0000-0000-000000004500';   -- 강사
select pg_temp.ok((select (s ->> 'busy')::boolean from jsonb_array_elements(tutor_screen(null, current_date, current_date) -> 'makeups') m,
                          jsonb_array_elements(m -> 'slots') s where (m ->> 'id')::uuid = (select id from q1) and (s ->> 'id')::uuid = pg_temp.qcand((select id from q1))),
  'QA-01 A: 닫은 시간의 후보는 강사 화면에 busy (4500)');
select pg_temp.expect_error($$select tutor_makeup_answer((select id from q1), array[pg_temp.qcand((select id from q1))], null)$$, 'not in your open hours');
set request.jwt.claim.sub = 'bbbbbbbb-0000-0000-0000-000000000009';
select pg_temp.expect_error($$select admin_makeup_confirm((select id from q1), (select t from q0) + interval '2 days 2 hours 30 minutes')$$, '열어 둔 시간이 아님|열어 둔 시간이 아닙니다');
select pg_temp.ok((select status = 'requested' from makeup_requests where id = (select id from q1)), 'QA-01 A: 닫은 시간은 강사 가능 답·운영진 확정 모두 거절 (4500)');
-- 강사가 Schedule 에서 그날만 열면(기록된 날짜별 개방) 확정됨
set request.jwt.claim.sub = 'bbbbbbbb-0000-0000-0000-000000004500';
select tutor_schedule_save(null, 'open', array[to_char(((select t from q0) + interval '2 days 2 hours 30 minutes') at time zone (select timezone from tutors where id = '55555555-0000-0000-0000-000000004500'), 'YYYY-MM-DD"T"HH24:MI')], null);
select tutor_makeup_answer((select id from q1), array[pg_temp.qcand((select id from q1))], null);
set request.jwt.claim.sub = 'bbbbbbbb-0000-0000-0000-000000000009';
-- QA-01 D: 불가라고 답한 다른 후보(3일 뒤)는 확정 못 함, 강사가 말한 다른 시간(답 없는 시간)은 확정 가능
select pg_temp.expect_error($$select admin_makeup_confirm((select id from q1), (select t from q0) + interval '3 days 2 hours 30 minutes')$$, '불가라고 답한');
select admin_makeup_confirm((select id from q1), (select t from q0) + interval '2 days 2 hours 30 minutes');
select pg_temp.ok((select status = 'confirmed' from makeup_requests where id = (select id from q1)) and pg_temp.qrights() = 0,
  'QA-01: 그날만 열어 둔 뒤 강사 가능 답 → 운영진 확정, 불가 답 후보는 거절 (4500)');
-- QA-13: 변경권 1개 남음 → 보강 수업 정상 취소(변경권 1→0, 보강 수업 자체가 새 보강권) → 수업 2 취소(변경권 0 → 보강 없음)
create temp table q1l as select confirmed_lesson_id as id from makeup_requests where id = (select id from q1);
grant select on q1l to authenticated;
select admin_change_lesson('c4500000-0000-0000-0000-000000000002', (select id from q1l), 'student', now(), false);
select pg_temp.ok(pg_temp.qbal() = 0 and pg_temp.qrights() = 1
              and (select (r ->> 'lesson_id')::uuid = (select id from q1l) from jsonb_array_elements(student_screen('99999999-0000-0000-0000-000000004500') -> 'makeup_rights') r),
  'QA-13: 보강 수업을 정상 취소하면 새 보강권은 그 보강 수업 하나 (원래 수업 1은 다시 안 생김) (4500)');
select pg_temp.expect_error($$select admin_makeup_request('77777777-4500-0000-0000-000000000001', null, jsonb_build_array(jsonb_build_object('starts_at', (select t from q0) + interval '9 days 2 hours 30 minutes')), now())$$, '이미 한 번 잡혔다가');
select pg_temp.ok((select q ->> 'confirmed_state' = 'canceled' from jsonb_array_elements(student_screen('99999999-0000-0000-0000-000000004500') -> 'makeup_requests') q where (q ->> 'id')::uuid = (select id from q1)),
  'QA-13: 원래 수업으로는 다시 보강 신청 불가, 신청 내역은 확정 수업이 취소됐다고 알림 (4500)');
-- 변경권 0개: 보강권(취소된 보강 수업)으로 보강 확정 → 그 보강을 다시 취소 → 'No change credits left', 권리 되살아나지 않음, 남은 권리 0
create temp table q2 as select (admin_makeup_request((select id from q1l), null,
  jsonb_build_array(jsonb_build_object('starts_at', (select t from q0) + interval '6 days 2 hours 30 minutes')), now()) ->> 'makeup_request_id')::uuid as id;
grant select on q2 to authenticated;
select admin_makeup_confirm((select id from q2), (select t from q0) + interval '6 days 2 hours 30 minutes');
create temp table q2l as select confirmed_lesson_id as id from makeup_requests where id = (select id from q2);
grant select on q2l to authenticated;
select pg_temp.ok(pg_temp.qrights() = 0, 'QA-13: 보강 확정 뒤 권리 0 (4500)');
select admin_change_lesson('c4500000-0000-0000-0000-000000000003', (select id from q2l), 'student', now(), false);
select pg_temp.ok((select class_status = 'No change credits left' from lessons where id = (select id from q2l)) and pg_temp.qrights() = 0 and pg_temp.qbal() = 0,
  'QA-13: 변경권 0개 보강 취소 → 보강 없음·권리 되살아나지 않음 (4500)');
select admin_revert_change((select id from change_requests where idempotency_key = 'c4500000-0000-0000-0000-000000000003'), 'QA 복구');
select pg_temp.ok((select state = 'scheduled' from lessons where id = (select id from q2l)) and pg_temp.qrights() = 0,
  'QA-13: 운영진 되돌리기 → 보강 수업 다시 예정, 권리 그대로 0 (4500)');
-- QA-08: 강사가 모든 후보에 불가 → 학생 화면 tutor_declined_all
select admin_change_lesson('c4500000-0000-0000-0000-000000000005', '77777777-4500-0000-0000-000000000005', 'tutor', now(), false);   -- 강사 사정 취소 → 변경권 그대로 보강권
create temp table q5 as select (admin_makeup_request('77777777-4500-0000-0000-000000000005', null,
  jsonb_build_array(jsonb_build_object('starts_at', (select t from q0) + interval '7 days 2 hours 30 minutes')), now()) ->> 'makeup_request_id')::uuid as id;
grant select on q5 to authenticated;
set request.jwt.claim.sub = 'bbbbbbbb-0000-0000-0000-000000004500';
select tutor_makeup_answer((select id from q5), '{}', 'Not that week, sorry. Any day after.');
set request.jwt.claim.sub = 'bbbbbbbb-0000-0000-0000-000000004501';   -- 학생
select pg_temp.ok((select (q ->> 'tutor_declined_all')::boolean from jsonb_array_elements(student_screen(null) -> 'makeup_requests') q where (q ->> 'id')::uuid = (select id from q5))
              and (select not (q ->> 'tutor_declined_all')::boolean from jsonb_array_elements(student_screen(null) -> 'makeup_requests') q where (q ->> 'id')::uuid = (select id from q1)),
  'QA-08: 모든 후보 불가 → 학생 화면에 재조율 표시 신호, 가능 답이 있던 신청은 아님 (4500)');
-- QA-12: 강사 노쇼 → 보상권 → 보상수업 확정 → Held 로 못 고침 → 보상수업 없애면 고칠 수 있음
set request.jwt.claim.sub = 'bbbbbbbb-0000-0000-0000-000000000009';
select tutor_record_class('77777777-4500-0000-0000-000000000004', 'tutor_no_show', null, 'QA no-show', false, null, false, null);
create temp table q4c as select id from compensations where source_lesson_id = '77777777-4500-0000-0000-000000000004';
grant select on q4c to authenticated;
create temp table q4 as select (admin_makeup_request(null, null,
  jsonb_build_array(jsonb_build_object('starts_at', (select t from q0) + interval '8 days 2 hours 30 minutes')), now(), (select id from q4c)) ->> 'makeup_request_id')::uuid as id;
grant select on q4 to authenticated;
select admin_makeup_confirm((select id from q4), (select t from q0) + interval '8 days 2 hours 30 minutes');
select pg_temp.expect_error($$select tutor_record_class('77777777-4500-0000-0000-000000000004', 'held', 'Fixed', null, false, null, false, null)$$, 'already has compensation class');
select pg_temp.ok((select class_status = 'Tutor no-show' from lessons where id = '77777777-4500-0000-0000-000000000004')
              and (select status = 'used' from compensations where id = (select id from q4c)),
  'QA-12: 보상수업이 잡힌 강사 노쇼는 Held 로 못 바꿈, 보상권·보상수업 그대로 (4500)');
select admin_void_makeup((select confirmed_lesson_id from makeup_requests where id = (select id from q4)), 'QA 정리');
select tutor_record_class('77777777-4500-0000-0000-000000000004', 'held', 'Fixed', null, false, null, false, null);
select pg_temp.ok((select class_status = 'Normal' from lessons where id = '77777777-4500-0000-0000-000000000004')
              and (select status = 'voided' from compensations where id = (select id from q4c)),
  'QA-12: 운영진이 보상수업을 없앤 뒤에는 고칠 수 있고 보상권은 voided (4500)');
-- 추가 요청 3: 운영진 변경권 수동 조정 (사유 필수 · ±1 · 한도 · 이력 · 학생 화면 반영)
select pg_temp.expect_error($$select admin_credit_adjust('99999999-0000-0000-0000-000000004500', 1, '  ')$$, '사유');
select pg_temp.expect_error($$select admin_credit_adjust('99999999-0000-0000-0000-000000004500', 2, 'x')$$, '1개씩');
select pg_temp.expect_error($$select admin_credit_adjust('99999999-0000-0000-0000-000000004500', -1, '더 빼기')$$, '남은 변경권이 없어');
create temp table qadj as select admin_credit_adjust('99999999-0000-0000-0000-000000004500', 1, '운영진 사전 안내: 2회 변경에 1개만 차감') as r;
select pg_temp.ok((select (r ->> 'before')::int = 0 and (r ->> 'after')::int = 1 from qadj) and pg_temp.qbal() = 1,
  '변경권 수동 조정: 사유 필수, 한 번에 1개, 0 아래로 못 뺌, +1 복구 → 잔여 1 (4500)');
select admin_credit_adjust('99999999-0000-0000-0000-000000004500', 1, '한 번 더');
select pg_temp.expect_error($$select admin_credit_adjust('99999999-0000-0000-0000-000000004500', 1, '지급 수량 초과')$$, '지급된 변경권');
select pg_temp.ok((select (j ->> 'left')::int = 2 and (j ->> 'granted')::int = 2 and j -> 'uses' -> 0 ->> 'reason' = 'admin_adjust' and j -> 'uses' -> 0 ->> 'note' = '한 번 더'
                          and (j -> 'uses' -> 0 ->> 'by')::uuid = 'bbbbbbbb-0000-0000-0000-000000000009'
                   from admin_credits('99999999-0000-0000-0000-000000004500') j),
  '변경권 수동 조정: 지급 수량(2)보다 많이 못 더함, 이력에 사유·조정자·시각 (4500)');
set request.jwt.claim.sub = 'bbbbbbbb-0000-0000-0000-000000004501';
select pg_temp.ok((select (e ->> 'credits_left')::int = 2 from (select student_screen(null) -> 'enrollment' e) x)
              and (select count(*) filter (where u ->> 'reason' = 'admin_adjust' and u ->> 'note' is not null) = 2 from jsonb_array_elements(student_screen(null) -> 'credit_uses') u),
  '변경권 수동 조정: 학생 화면 잔여·기록(사유)에 바로 반영 (4500)');
select pg_temp.expect_error($$select admin_credit_adjust('99999999-0000-0000-0000-000000004500', -1, '학생이 시도')$$, '운영자|42501');
set request.jwt.claim.sub = 'bbbbbbbb-0000-0000-0000-000000004500';
select pg_temp.expect_error($$select admin_credit_adjust('99999999-0000-0000-0000-000000004500', -1, '강사가 시도')$$, '운영자|42501');
select pg_temp.expect_error($$select admin_credits('99999999-0000-0000-0000-000000004500')$$, '운영자|42501');
select pg_temp.ok(true, '변경권 수동 조정은 운영진만 (4500)');
reset request.jwt.claim.sub;
reset role;

-- ---------- 4510 휴무 철회 (QA-17) ----------
-- 강사 철회A(휴무)·철회B(대체), 학생 철회학생. 수업 w1 = 12일 뒤 20:00(대체 확정) · w2 = 14일 뒤 20:00(기존 강사 보강 기다림) · w3 = 16일 뒤 20:00(미정)
reset request.jwt.claim.sub;
reset role;
create temp table wd (d0 date);
insert into wd values (current_date + 12);
grant select on wd to authenticated;
insert into tutors (id, name, country, timezone, meet_url) values
  ('55555555-0000-0000-0000-00000000451a', '철회A', 'Korea', 'Asia/Seoul', 'https://meet.google.com/waa-aaaa-aaa'), ('55555555-0000-0000-0000-00000000451b', '철회B', 'Korea', 'Asia/Seoul', 'https://meet.google.com/wbb-bbbb-bbb');
select pg_temp.open_all('55555555-0000-0000-0000-00000000451a');
select pg_temp.open_all('55555555-0000-0000-0000-00000000451b');
insert into students (id, name_ko, name_en) values ('99999999-0000-0000-0000-000000004510', '철회학생', 'Withdraw S');
insert into enrollments (id, student_id, seq, weeks, weekly_count, duration_min, start_date, base_end_date, lessons_purchased, status)
select '99999999-1000-0000-0000-000000004510', '99999999-0000-0000-0000-000000004510', 1, 4, 2, 40, d0 - 7, d0 - 7 + 27, 8, 'active' from wd;
insert into lessons (id, enrollment_id, student_id, tutor_id, kind, seq, starts_at, ends_at)
select ('77777777-4510-0000-0000-00000000000' || n)::uuid, '99999999-1000-0000-0000-000000004510', '99999999-0000-0000-0000-000000004510',
       '55555555-0000-0000-0000-00000000451a', 'regular', n, ((d0 + k) + time '20:00') at time zone 'Asia/Seoul', ((d0 + k) + time '20:40') at time zone 'Asia/Seoul'
from wd, (values (1, 0), (2, 2), (3, 4)) v(n, k);
create or replace function pg_temp.wi(n int) returns uuid language sql as $$
  select id from leave_items where lesson_id = ('77777777-4510-0000-0000-00000000000' || n)::uuid and withdrawn_at is null $$;
set role authenticated;
set request.jwt.claim.sub = 'bbbbbbbb-0000-0000-0000-000000000009';
create temp table woff as select (admin_leave_create('55555555-0000-0000-0000-00000000451a', (select d0 from wd), (select d0 + 5 from wd), 'QA 잘못 넣은 휴무', false) ->> 'time_off_id')::uuid as id;
grant select on woff to authenticated;
select admin_leave_choose(array[pg_temp.wi(1)], 'substitute', '55555555-0000-0000-0000-00000000451b');
select admin_leave_sub_ok(array[pg_temp.wi(1)]);
select admin_leave_student_ok(array[pg_temp.wi(1)]);
select admin_leave_choose(array[pg_temp.wi(2)], 'wait', null);
select pg_temp.ok((select tutor_id = '55555555-0000-0000-0000-00000000451b' from lessons where id = '77777777-4510-0000-0000-000000000001')
              and (select state = 'canceled' and class_status = 'Tutor long-term leave' from lessons where id = '77777777-4510-0000-0000-000000000002'),
  '4510 준비: w1 대체 확정(철회B), w2 기존 강사 보강 기다림(취소), w3 미정');
-- 미리 보기: 아무것도 안 바뀜
create temp table wdry as select admin_leave_withdraw((select id from woff), null, true) as r;
select pg_temp.ok((select (r ->> 'dry_run')::boolean and (r ->> 'items')::int = 3 and (r ->> 'sub_back')::int = 1 and (r ->> 'wait_back')::int = 1 and (r ->> 'untouched')::int = 1
                          and jsonb_array_length(r -> 'blockers') = 0 from wdry)
              and (select tutor_id = '55555555-0000-0000-0000-00000000451b' from lessons where id = '77777777-4510-0000-0000-000000000001'),
  'QA-17 미리 보기: 대체 1 되돌림·보강 기다림 1 복구·미정 1, 막는 것 없음, 바뀐 것 없음 (4510)');
-- 보강 신청이 있는 수업이 있으면 철회 거절 (보강부터 정리)
create temp table wreq as select (admin_makeup_request('77777777-4510-0000-0000-000000000002', null,
  jsonb_build_array(jsonb_build_object('starts_at', ((select d0 + 9 from wd) + time '20:00') at time zone 'Asia/Seoul')), now()) ->> 'makeup_request_id')::uuid as id;
grant select on wreq to authenticated;
select pg_temp.ok((select jsonb_array_length(r -> 'blockers') = 1 and r -> 'blockers' ->> 0 like '%보강 신청·확정%' from admin_leave_withdraw((select id from woff), null, true) r),
  'QA-17: 보강 신청이 걸린 수업은 미리 보기에 막는 이유로 보임 (4510)');
select pg_temp.expect_error($$select admin_leave_withdraw((select id from woff), 'x', false)$$, '철회할 수 없어요');
select admin_makeup_withdraw((select id from wreq));
select pg_temp.expect_error($$select admin_leave_withdraw((select id from woff), '  ', false)$$, '사유');
-- 철회
select admin_leave_withdraw((select id from woff), '날짜를 잘못 넣음 (QA)', false);
reset role;
select pg_temp.ok((select tutor_id = '55555555-0000-0000-0000-00000000451a' and original_tutor_id is null and state = 'scheduled' from lessons where id = '77777777-4510-0000-0000-000000000001')
              and (select state = 'scheduled' and class_status is null from lessons where id = '77777777-4510-0000-0000-000000000002')
              and (select count(*) = 3 and bool_and(withdrawn_at is not null and lesson_gone_at is not null and choice = 'undecided' and sub_tutor_id is null) from leave_items where time_off_id = (select id from woff))
              and (select withdrawn_at is not null and withdraw_note = '날짜를 잘못 넣음 (QA)' and lower(withdrawn_range) = ((select d0 from wd)::timestamp at time zone 'Asia/Seoul') and starts_at < timestamptz '1901-01-01' from tutor_time_off where id = (select id from woff))
              and (select count(*) = 0 from lesson_notices where leave_item_id in (select id from leave_items where time_off_id = (select id from woff)) and status in ('pending', 'sent')),
  'QA-17 철회: 대체 수업 원래 강사로·취소 수업 다시 예정·줄은 닫힘+철회 표시·휴무는 효력 없는 날짜+원래 기간·사유, 안내는 보낼 필요 없음 (4510)');
select pg_temp.ok(lms_sub_conflict('55555555-0000-0000-0000-00000000451a', ((select d0 + 1 from wd) + time '10:00') at time zone 'Asia/Seoul', ((select d0 + 1 from wd) + time '10:40') at time zone 'Asia/Seoul', null) is null
              and (select (admin_leave_withdraw((select id from woff), 'again', false) ->> 'repeated')::boolean),
  'QA-17 철회 뒤: 그 기간은 휴무가 아님(충돌 없음), 두 번 눌러도 한 번 (4510)');
-- 같은 기간을 다시 휴무로 넣으면 철회된 줄이 되살아남 (수업당 한 줄 규칙 그대로)
set role authenticated;
set request.jwt.claim.sub = 'bbbbbbbb-0000-0000-0000-000000000009';
select pg_temp.ok((select (r ->> 'items')::int = 3 and (r ->> 'existing')::int = 0 from admin_leave_create('55555555-0000-0000-0000-00000000451a', (select d0 from wd), (select d0 + 5 from wd), '다시', true) r),
  'QA-17: 철회 뒤 같은 기간 미리 보기 = 수업 3회 다시 걸림, 이미 목록 0 (4510)');
create temp table woff2 as select (admin_leave_create('55555555-0000-0000-0000-00000000451a', (select d0 from wd), (select d0 + 5 from wd), '다시 넣음', false) ->> 'time_off_id')::uuid as id;
grant select on woff2 to authenticated;
reset role;
select pg_temp.ok((select id from woff2) <> (select id from woff)
              and (select count(*) = 3 and bool_and(withdrawn_at is null and lesson_gone_at is null and choice = 'undecided') from leave_items where time_off_id = (select id from woff2))
              and (select count(*) = 3 from leave_items where lesson_id in ('77777777-4510-0000-0000-000000000001', '77777777-4510-0000-0000-000000000002', '77777777-4510-0000-0000-000000000003'))
              and (select count(*) = 3 from lesson_notices n join leave_items i on i.id = n.leave_item_id where i.time_off_id = (select id from woff2) and n.event = 'leave_options' and n.status = 'pending'),
  'QA-17: 새 휴무에 철회된 줄 3개가 되살아나고(새 줄 없음) 학생 안내도 다시 생김 (4510)');
-- 지난 수업이 걸린 휴무는 철회 못 함
update lessons set starts_at = now() - interval '2 hours', ends_at = now() - interval '80 minutes' where id = '77777777-4510-0000-0000-000000000003';
set role authenticated;
set request.jwt.claim.sub = 'bbbbbbbb-0000-0000-0000-000000000009';
select pg_temp.ok((select r -> 'blockers' ->> 0 like '%이미 시작%' from admin_leave_withdraw((select id from woff2), null, true) r), 'QA-17: 이미 시작한 수업이 걸려 있으면 철회 못 함 (4510)');
set request.jwt.claim.sub = 'bbbbbbbb-0000-0000-0000-000000004500';   -- 강사
select pg_temp.expect_error($$select admin_leave_withdraw((select id from woff2), 'x', true)$$, '운영자|42501');
select pg_temp.ok(true, 'QA-17: 휴무 철회는 운영진만 (4510)');
reset request.jwt.claim.sub;
reset role;

-- ---------- 4520 Work 최종 재검증(11/5) R-01~21 DB 수정 ----------
-- 강사 재검A(452a, 서울)·재검B(452b, 대체, Meet 링크 없음), 학생 재검1(4520: 이관 휴무 보강·보강 답)·재검2(4521: 정규 변경·기존 배정 컨펌)
-- d0 = 2주 뒤 이후 첫 월요일 (한국 날짜)
reset request.jwt.claim.sub;
reset role;
create temp table rd (d0 date);
insert into rd select (current_date + 14) + ((8 - extract(dow from current_date + 14)::int) % 7);
grant select on rd to authenticated;
create or replace function pg_temp.rk(days int, hhmm text) returns timestamptz language sql as $$
  select ((select d0 from rd) + days + hhmm::time) at time zone 'Asia/Seoul' $$;
insert into tutors (id, name, country, timezone) values
  ('55555555-0000-0000-0000-00000000452a', '재검A', 'Korea', 'Asia/Seoul'), ('55555555-0000-0000-0000-00000000452b', '재검B', 'Korea', 'Asia/Seoul');
select pg_temp.open_all('55555555-0000-0000-0000-00000000452a');
select pg_temp.open_all('55555555-0000-0000-0000-00000000452b');
insert into app_users (auth_user_id, role, tutor_id) values ('bbbbbbbb-0000-0000-0000-000000004520', 'tutor', '55555555-0000-0000-0000-00000000452a');
insert into students (id, name_ko, name_en) values ('99999999-0000-0000-0000-000000004520', '재검일', 'Reval One'), ('99999999-0000-0000-0000-000000004521', '재검이', 'Reval Two');
-- 재검1: 4주 수강권 d0-21 ~ d0+6, 변경권 2, 정규 수업 d0+1 20:00, 시트에서 넘어온 휴가 보강(날짜 미정, tutor_leave)
insert into enrollments (id, student_id, seq, weeks, weekly_count, duration_min, start_date, base_end_date, lessons_purchased, status)
select '99999999-1000-0000-0000-000000004520', '99999999-0000-0000-0000-000000004520', 1, 4, 2, 40, d0 - 21, d0 + 6, 8, 'active' from rd;
insert into enrollment_periods (id, enrollment_id, idx, start_date, end_date, credits_granted)
select '99999999-2000-0000-0000-000000004520', '99999999-1000-0000-0000-000000004520', 1, d0 - 21, d0 + 6, 2 from rd;
insert into lessons (id, enrollment_id, student_id, tutor_id, kind, seq, starts_at, ends_at)
values ('77777777-4520-0000-0000-000000000001', '99999999-1000-0000-0000-000000004520', '99999999-0000-0000-0000-000000004520', '55555555-0000-0000-0000-00000000452a', 'regular', 1, pg_temp.rk(1, '20:00'), pg_temp.rk(1, '20:40'));
insert into migrated_items (id, enrollment_id, kind, original_date, tutor_leave)
select '99999999-4000-0000-0000-000000004520', '99999999-1000-0000-0000-000000004520', 'makeup_open', d0 - 3, true from rd;
-- 재검2: 4주 수강권 d0-7 ~ d0+20, 정규 월·수 20:00 (d0, d0+2, d0+7, d0+9), 신규 매칭 업무(강사 배정됨, 일정안 없음)
insert into enrollments (id, student_id, seq, weeks, weekly_count, duration_min, start_date, base_end_date, lessons_purchased, status)
select '99999999-1000-0000-0000-000000004521', '99999999-0000-0000-0000-000000004521', 1, 4, 2, 40, d0 - 7, d0 + 20, 8, 'active' from rd;
insert into regular_schedules (student_id, tutor_id, weekday, start_time_kst, duration_min, effective_from)
select '99999999-0000-0000-0000-000000004521', '55555555-0000-0000-0000-00000000452a', w, '20:00', 40, d0 - 7 from rd, (values (1), (3)) v(w);
insert into lessons (id, enrollment_id, student_id, tutor_id, kind, seq, starts_at, ends_at)
select ('77777777-4521-0000-0000-00000000000' || n)::uuid, '99999999-1000-0000-0000-000000004521', '99999999-0000-0000-0000-000000004521',
       '55555555-0000-0000-0000-00000000452a', 'regular', n, pg_temp.rk(k, '20:00'), pg_temp.rk(k, '20:40')
from (values (1, 0), (2, 2), (3, 7), (4, 9)) v(n, k);
insert into admin_tasks (id, kind, enrollment_id, tutor_id, tutor_assigned_at)
values ('99999999-7000-0000-0000-000000004521', 'new_student_matching', '99999999-1000-0000-0000-000000004521', '55555555-0000-0000-0000-00000000452a', now() - interval '1 day');
create or replace function pg_temp.rend() returns date language sql as $$ select final_end_date from enrollments where id = '99999999-1000-0000-0000-000000004520' $$;
create or replace function pg_temp.rext() returns int[] language sql as $$
  select coalesce(array_agg(days order by created_at, days), '{}') from enrollment_extensions where enrollment_id = '99999999-1000-0000-0000-000000004520' and auto_source = 'leave_makeup' $$;

set role authenticated;
set request.jwt.claim.sub = 'bbbbbbbb-0000-0000-0000-000000000009';   -- 운영자
-- R-18) 이관 휴무 보강 확정 → 종료일이 보강 날짜까지 자동 연장 (전에는 트리거가 이관권을 못 찾아 연장 누락)
select pg_temp.ok(pg_temp.rend() = (select d0 + 6 from rd) and pg_temp.rext() = '{}', 'R-18 준비: 종료일 d0+6, 자동 연장 없음 (4520)');
create temp table r18a as select (admin_makeup_request(null, '99999999-4000-0000-0000-000000004520',
  jsonb_build_array(jsonb_build_object('starts_at', pg_temp.rk(13, '20:00'))), now()) ->> 'makeup_request_id')::uuid as id;
grant select on r18a to authenticated;
create temp table r18l as select (admin_makeup_confirm((select id from r18a), pg_temp.rk(13, '20:00')) ->> 'lesson_id')::uuid as id;
grant select on r18l to authenticated;
select pg_temp.ok(pg_temp.rend() = (select d0 + 13 from rd) and pg_temp.rext() = '{7}'
              and (select kind = 'makeup_booked' and lesson_id = (select id from r18l) from migrated_items where id = '99999999-4000-0000-0000-000000004520'),
  'R-18: 이관 휴무 보강 d0+13 확정 → 이관권 연결 + 종료일 d0+13 (자동 연장 7일, 같은 트랜잭션) (4520)');
-- 없애도 늘어난 종료일은 그대로 (H26(94) 자동 단축 없음, 20261108030000). 이관권은 다시 열림
select admin_void_makeup((select id from r18l), 'QA 되돌림');
select pg_temp.ok(pg_temp.rend() = (select d0 + 13 from rd) and pg_temp.rext() = '{7}'
              and (select kind = 'makeup_open' and lesson_id is null from migrated_items where id = '99999999-4000-0000-0000-000000004520'),
  'R-18: 보강 없애기 → 이관권 다시 열림, 종료일은 줄이지 않음 d0+13 (4520 · 20261108030000)');
create temp table r18b as select (admin_makeup_request(null, '99999999-4000-0000-0000-000000004520',
  jsonb_build_array(jsonb_build_object('starts_at', pg_temp.rk(10, '20:00'))), now()) ->> 'makeup_request_id')::uuid as id;
grant select on r18b to authenticated;
create temp table r18m as select (admin_makeup_confirm((select id from r18b), pg_temp.rk(10, '20:00')) ->> 'lesson_id')::uuid as id;
grant select on r18m to authenticated;
select pg_temp.ok(pg_temp.rend() = (select d0 + 13 from rd) and pg_temp.rext() = '{7}', 'R-18: 더 이른 날짜(d0+10)로 재확정 → 종료일 그대로 d0+13 (4520 · 20261108030000)');
-- 다음 수강권(d0+14 시작)과 겹치는 날짜로는 확정 못 함 (연장이 다음 기간을 침범)
reset role;
insert into enrollments (id, student_id, seq, previous_enrollment_id, weeks, weekly_count, duration_min, start_date, base_end_date, lessons_purchased, status)
select '99999999-1000-0000-0000-000000004522', '99999999-0000-0000-0000-000000004520', 2, '99999999-1000-0000-0000-000000004520', 4, 2, 40, d0 + 14, d0 + 41, 8, 'confirmed' from rd;
set role authenticated;
set request.jwt.claim.sub = 'bbbbbbbb-0000-0000-0000-000000000009';
select admin_void_makeup((select id from r18m), 'QA 다시');
create temp table r18c as select (admin_makeup_request(null, '99999999-4000-0000-0000-000000004520',
  jsonb_build_array(jsonb_build_object('starts_at', pg_temp.rk(16, '20:00'))), now()) ->> 'makeup_request_id')::uuid as id;
grant select on r18c to authenticated;
select pg_temp.expect_error($$select admin_makeup_confirm((select id from r18c), pg_temp.rk(16, '20:00'))$$, '다음 수강권');
select pg_temp.ok(pg_temp.rend() = (select d0 + 13 from rd) and (select status = 'requested' from makeup_requests where id = (select id from r18c))
              and (select kind = 'makeup_open' from migrated_items where id = '99999999-4000-0000-0000-000000004520'),
  'R-18: 다음 수강권 기간을 침범하는 날짜는 확정 거절, 아무것도 안 바뀜 (4520)');
select admin_makeup_withdraw((select id from r18c));
-- 다음 수강권은 시험용이라 취소 (학생 화면은 수강 중·예정 수강권 중 최신을 보므로, 아래 시험은 1번 수강권으로)
reset role;
update enrollments set status = 'canceled' where id = '99999999-1000-0000-0000-000000004522';
set role authenticated;
set request.jwt.claim.sub = 'bbbbbbbb-0000-0000-0000-000000000009';

-- R-12) 학생 화면에 수강권의 모든 기간 변경권 (수업 날짜가 속한 기간으로 미리 보기)
select pg_temp.ok((select jsonb_array_length(j -> 'credit_periods') = 1 and (j -> 'credit_periods' -> 0 ->> 'left')::int = 2 and (j -> 'credit_periods' -> 0 ->> 'granted')::int = 2
                          and (j -> 'credit_periods' -> 0 ->> 'start')::date = (select d0 - 21 from rd) and (j -> 'credit_periods' -> 0 ->> 'end')::date = (select d0 + 6 from rd)
                   from student_screen('99999999-0000-0000-0000-000000004520') j),
  'R-12: student_screen.credit_periods = 기간마다 시작·끝·지급·잔여 (4520)');

-- R-16) 보강 답 대기 칸: 답 전 r → 가능 답 뒤 a (운영진 확정 대기), 불가 답한 시간은 풀림
select admin_change_lesson('c4520000-0000-0000-0000-000000000001', '77777777-4520-0000-0000-000000000001', 'student', now(), false);
select pg_temp.ok((select (j -> 'credit_periods' -> 0 ->> 'left')::int = 1 from student_screen('99999999-0000-0000-0000-000000004520') j),
  'R-12: 취소 뒤 그 기간 잔여 1 (4520)');
create temp table r16 as select (admin_makeup_request('77777777-4520-0000-0000-000000000001', null,
  jsonb_build_array(jsonb_build_object('starts_at', pg_temp.rk(3, '20:00')), jsonb_build_object('starts_at', pg_temp.rk(4, '20:00'))), now()) ->> 'makeup_request_id')::uuid as id;
grant select on r16 to authenticated;
reset role;
select pg_temp.ok(lms_hours_cell('55555555-0000-0000-0000-00000000452a', pg_temp.rk(3, '20:00')) = 'r' and lms_hours_cell('55555555-0000-0000-0000-00000000452a', pg_temp.rk(4, '20:00')) = 'r',
  'R-16: 답 전 후보 시간은 r (답 대기) (4520)');
set role authenticated;
set request.jwt.claim.sub = 'bbbbbbbb-0000-0000-0000-000000004520';   -- 강사 재검A
select tutor_makeup_answer((select id from r16), array[(select c.id from makeup_candidates c where c.request_id = (select id from r16) and c.starts_at = pg_temp.rk(3, '20:00'))], null);
reset role;
select pg_temp.ok(lms_hours_cell('55555555-0000-0000-0000-00000000452a', pg_temp.rk(3, '20:00')) = 'a' and lms_hours_cell('55555555-0000-0000-0000-00000000452a', pg_temp.rk(4, '20:00')) = 'o',
  'R-16: 가능 답한 시간은 a (운영진 확정 대기), 불가 답한 시간은 다시 열림 (4520)');
set role authenticated;
set request.jwt.claim.sub = 'bbbbbbbb-0000-0000-0000-000000004520';
select pg_temp.expect_error($$select tutor_schedule_save(null, 'block', array[(select d0 + 3 from rd)::text || 'T20:00'], null, null)$$, 'Waiting for Edge English');
select pg_temp.ok((select j -> 'cells' ->> ((select d0 + 3 from rd)::text || 'T20:00') = 'a' from tutor_schedule(null, (select d0 + 3 from rd), (select d0 + 3 from rd), true) j),
  'R-16: 답 보낸 칸은 못 막고(확정 대기 안내) Schedule 칸 코드 a (4520)');

-- R-10) 기존 배정이 있는 신규 매칭: 지금 배정 읽기 → 학생 안내 완료 기록 → 업무 완료
set request.jwt.claim.sub = 'bbbbbbbb-0000-0000-0000-000000000009';
select pg_temp.ok((select j -> 'task' ->> 'status' = 'open' and jsonb_typeof(j -> 'plan') = 'null' and j -> 'tutor' ->> 'name' = '재검A' and jsonb_array_length(j -> 'slots') = 2
                          and (j ->> 'scheduled')::int = 4 and (j ->> 'upcoming')::int = 4 and (j ->> 'past_unrecorded')::int = 0 and (j ->> 'next_at')::timestamptz = pg_temp.rk(0, '20:00') and (j ->> 'first_at')::timestamptz = pg_temp.rk(0, '20:00')
                   from admin_matching_current('99999999-1000-0000-0000-000000004521') j),
  'R-10·R-22: 지금 배정 읽기 — 강사·정규 요일 2개·앞으로 4회(지난 미기록 0)·다음 수업, 일정안 없음 (4520·4530)');
select pg_temp.expect_error($$select admin_matching_notified('99999999-1000-0000-0000-000000004520')$$, '신규 매칭 업무가 없습니다');
create temp table r10a as select admin_matching_notified('99999999-1000-0000-0000-000000004521') as r;   -- 같은 문장 안에서는 함수가 바꾼 값이 안 보여 따로 호출
grant select on r10a to authenticated;
create temp table r10b as select admin_matching_notified('99999999-1000-0000-0000-000000004521') as r;
grant select on r10b to authenticated;
select pg_temp.ok((select not (r ->> 'repeated')::boolean from r10a)
              and (select status = 'done' and student_notified_at is not null and tutor_notified_at is not null and done_by = 'bbbbbbbb-0000-0000-0000-000000000009' from admin_tasks where id = '99999999-7000-0000-0000-000000004521')
              and (select (r ->> 'repeated')::boolean from r10b),
  'R-10: 수업 컨펌 완료 기록 → 학생·강사 안내 시각 + 업무 완료, 두 번 눌러도 한 번 (4520)');
set request.jwt.claim.sub = 'bbbbbbbb-0000-0000-0000-000000004520';
select pg_temp.expect_error($$select admin_matching_current('99999999-1000-0000-0000-000000004521')$$, '42501');
select pg_temp.expect_error($$select admin_matching_notified('99999999-1000-0000-0000-000000004521')$$, '42501');
select pg_temp.ok(true, 'R-10: 운영자만 (4520)');

-- R-15) 정규 변경: 월 20:00→21:00, 수 그대로 → 바뀌는 수업 2(월), 그대로 2(수, same)
set request.jwt.claim.sub = 'bbbbbbbb-0000-0000-0000-000000000009';
create temp table r15 as select admin_regular_change('99999999-0000-0000-0000-000000004521',
  '[{"weekday":1,"time":"21:00"},{"weekday":3,"time":"20:00"}]'::jsonb, (select d0 from rd), null, true) as r;
select pg_temp.ok((select (r ->> 'ok')::boolean and jsonb_array_length(r -> 'moved') = 2 and jsonb_array_length(r -> 'kept') = 2
                          and (select bool_and(x ->> 'why' = 'same') from jsonb_array_elements(r -> 'kept') x)
                          and (select bool_and((x ->> 'to')::timestamptz = (x ->> 'from')::timestamptz + interval '1 hour') from jsonb_array_elements(r -> 'moved') x)
                   from r15),
  'R-15 미리 보기: 월 2회만 바뀜, 수 2회는 그대로(same) (4520)');
create temp table r15s as select admin_regular_change('99999999-0000-0000-0000-000000004521',
  '[{"weekday":1,"time":"21:00"},{"weekday":3,"time":"20:00"}]'::jsonb, (select d0 from rd), '월요일만 한 시간 뒤로', false) as r;
grant select on r15s to authenticated;
select pg_temp.ok((select (r ->> 'moved')::int = 2 from r15s)
              and (select array_agg(to_char(starts_at at time zone 'Asia/Seoul', 'DyHH24:MI') order by starts_at) from lessons where enrollment_id = '99999999-1000-0000-0000-000000004521')
                  = '{Mon21:00,Wed20:00,Mon21:00,Wed20:00}'
              and (select jsonb_array_length(moved) = 2 and jsonb_array_length(kept) = 2 from regular_changes where student_id = '99999999-0000-0000-0000-000000004521'),
  'R-15 저장: 월 수업만 21:00, 수 수업 20:00 그대로, 기록도 바뀐 2·그대로 2 (4520)');

-- R-09) 겹치는 휴무: 4510 의 철회A 휴무(d0~d0+5, wd) 안에 들어가는 날짜 → 미리 보기에 겹침, 저장 거절. 겹치지 않는 날짜는 그대로
select pg_temp.ok((select jsonb_array_length(r -> 'overlap') = 1 and (r -> 'overlap' -> 0 ->> 'from')::date = (select d0 from wd) and (r -> 'overlap' -> 0 ->> 'to')::date = (select d0 + 5 from wd)
                   from admin_leave_create('55555555-0000-0000-0000-00000000451a', (select d0 + 2 from wd), (select d0 + 3 from wd), '중복', true) r)
              and (select jsonb_array_length(r -> 'overlap') = 0 from admin_leave_create('55555555-0000-0000-0000-00000000451a', (select d0 + 6 from wd), (select d0 + 7 from wd), '다음', true) r),
  'R-09 미리 보기: 기존 휴무 기간 안의 날짜는 겹침 1건(기존 기간 표시), 바로 뒤 날짜는 겹침 없음 (4520)');
select pg_temp.expect_error($$select admin_leave_create('55555555-0000-0000-0000-00000000451a', (select d0 + 2 from wd), (select d0 + 3 from wd), '중복', false)$$, '겹칩니다');
select pg_temp.ok((select count(*) = 1 from tutor_time_off where tutor_id = '55555555-0000-0000-0000-00000000451a' and kind = 'leave' and withdrawn_at is null),
  'R-09 저장: 겹치는 휴무는 저장 안 됨 (같은 기간 재입력은 전처럼 한 줄) (4520)');

-- R-06) 처리 내역에 시트 대조 완료(④) + 다시 열기
create temp table r06 as select e.id as eid from enrollments e join students s on s.id = e.student_id where s.name_ko = '확대A';
grant select on r06 to authenticated;
select pg_temp.ok((select count(*) >= 1 from jsonb_array_elements(admin_task_history()) x where x ->> 'source' = 'checked' and x ->> 'kind' = 'import_check' and x ->> 'name' = '확대A' and x ->> 'by' = '운영자'),
  'R-06: 대조 완료 기록이 처리 내역에 보임 (처리자·시각) (4520)');
select admin_import_unmark_checked((select eid from r06));
select pg_temp.ok((select checked_at is null and checked_by is null from import_checks where enrollment_id = (select eid from r06))
              and not exists (select 1 from jsonb_array_elements(admin_task_history()) x where x ->> 'source' = 'checked' and x ->> 'name' = '확대A'),
  'R-06: 다시 열기 → 대조 전으로, 처리 내역에서 빠짐 (4520)');
select admin_import_mark_checked((select eid from r06));
set request.jwt.claim.sub = 'bbbbbbbb-0000-0000-0000-000000004520';
select pg_temp.expect_error($$select admin_import_unmark_checked((select eid from r06))$$, '42501');
select pg_temp.ok(true, 'R-06: 다시 열기는 운영자만 (4520)');

-- R-05) Meet 회의실 주소 검사 + 대체강사 확정은 회의실 링크가 있어야
reset role;
select pg_temp.ok(lms_meet_url_ok('https://meet.google.com/abc-defg-hij') and lms_meet_url_ok('https://meet.google.com/lookup/abc123')
              and not lms_meet_url_ok('https://meet.google.com/') and not lms_meet_url_ok('https://meet.google.com') and not lms_meet_url_ok(null) and not lms_meet_url_ok('')
              and not lms_meet_url_ok('https://workspace.google.com/products/meet/') and not lms_meet_url_ok('https://meet.google.com/abc'),
  'R-05: 회의실 주소(xxx-xxxx-xxx·lookup)만 유효, 홈페이지 주소·빈 값은 아님 (4520)');
set role authenticated;
set request.jwt.claim.sub = 'bbbbbbbb-0000-0000-0000-000000000009';
select admin_leave_create('55555555-0000-0000-0000-00000000452a', (select d0 + 9 from rd), (select d0 + 9 from rd), '재검 휴무', false);
create temp table r05 as select id from leave_items where lesson_id = '77777777-4521-0000-0000-000000000004';
grant select on r05 to authenticated;
select admin_leave_choose(array[(select id from r05)], 'substitute', '55555555-0000-0000-0000-00000000452b');
select admin_leave_sub_ok(array[(select id from r05)]);
select pg_temp.expect_error($$select admin_leave_student_ok(array[(select id from r05)])$$, 'Meet');
select pg_temp.ok((select sub_stage = 'tutor_ok' from leave_items where id = (select id from r05))
              and (select tutor_id = '55555555-0000-0000-0000-00000000452a' from lessons where id = '77777777-4521-0000-0000-000000000004'),
  'R-05: 대체강사 Meet 링크 없으면 확정 거절, 수업 강사 그대로 (4520)');
reset role;
update tutors set meet_url = 'https://meet.google.com/' where id = '55555555-0000-0000-0000-00000000452b';
set role authenticated;
set request.jwt.claim.sub = 'bbbbbbbb-0000-0000-0000-000000000009';
select pg_temp.expect_error($$select admin_leave_student_ok(array[(select id from r05)])$$, 'Meet');
reset role;
update tutors set meet_url = 'https://meet.google.com/rrr-eval-two' where id = '55555555-0000-0000-0000-00000000452b';
set role authenticated;
set request.jwt.claim.sub = 'bbbbbbbb-0000-0000-0000-000000000009';
select admin_leave_student_ok(array[(select id from r05)]);
select pg_temp.ok((select sub_stage = 'confirmed' from leave_items where id = (select id from r05))
              and (select tutor_id = '55555555-0000-0000-0000-00000000452b' from lessons where id = '77777777-4521-0000-0000-000000000004'),
  'R-05: 홈페이지 주소(meet.google.com/)도 거절, 회의실 링크를 넣으면 확정 (4520)');
reset request.jwt.claim.sub;
reset role;

-- ---------- 4530 Work 2차 재검증(67fbba0) R-22·R-25 ----------
reset request.jwt.claim.sub;
reset role;
select pg_temp.ok(lms_conflict_code('강사가 열어 둔 시간이 아님(Availability·Schedule)') = 'closed' and lms_conflict_code('강사 휴무') = 'leave'
              and lms_conflict_code('강사 다른 수업(휴식 10분 포함)') = 'busy' and lms_conflict_code('강사 현지 06:00~22:30 밖의 시작 시각') = 'hours'
              and lms_conflict_code('쉬지 않고 이어 붙이는 수업(20분 2개까지)') = 'b2b' and lms_conflict_code(null) is null
              and lms_conflict_message('강사가 열어 둔 시간이 아님(Availability·Schedule)') like '강사가 열어 둔 시간이 아닙니다.%'
              and lms_conflict_message('강사 휴무') = '그 시간은 강사 휴무입니다.'
              and lms_conflict_message('강사 다른 수업(휴식 10분 포함)') not like '%와 겹칩니다 (%' ,
  'R-25: 예약 불가 사유 코드·문구 (4530)');
-- 재검2 학생(4521)의 수업이 있는 시간에 재검1 보강 확정 → '다른 수업' 사유 문장, 강사가 닫은 시간 → '열어 둔 시간이 아닙니다'
set role authenticated;
set request.jwt.claim.sub = 'bbbbbbbb-0000-0000-0000-000000000009';
select admin_makeup_withdraw((select id from r16));   -- 같은 수업의 열린 신청(R-16 시험)을 닫아야 새 신청이 생김
create temp table r25 as select (admin_makeup_request('77777777-4520-0000-0000-000000000001', null,
  jsonb_build_array(jsonb_build_object('starts_at', pg_temp.rk(2, '19:00'))), now()) ->> 'makeup_request_id')::uuid as id;
grant select on r25 to authenticated;
select pg_temp.expect_error($$select admin_makeup_confirm((select id from r25), pg_temp.rk(2, '20:00'))$$, '다른 수업과 겹칩니다 \(앞뒤 휴식 10분 포함\)');
select pg_temp.expect_error($$select admin_makeup_confirm((select id from r25), pg_temp.rk(2, '04:00'))$$, '06:00~22:30');
select pg_temp.ok(true, 'R-25: 운영진 확정 거절 문구가 실제 원인(다른 수업 / 시작 가능 시간 밖)으로 나옴, ''○○와 겹칩니다'' 연결 없음 (4530)');
reset role;
update tutor_availability set end_local = '18:00' where tutor_id = '55555555-0000-0000-0000-00000000452a' and weekday = extract(dow from (select d0 + 2 from rd));
set role authenticated;
set request.jwt.claim.sub = 'bbbbbbbb-0000-0000-0000-000000000009';
select pg_temp.expect_error($$select admin_makeup_confirm((select id from r25), pg_temp.rk(2, '19:00'))$$, '열어 둔 시간이 아닙니다');
set request.jwt.claim.sub = 'bbbbbbbb-0000-0000-0000-000000004520';   -- 강사 재검A 화면: 후보 why = closed
select pg_temp.ok((select m -> 'slots' -> 0 ->> 'why' = 'closed' and (m -> 'slots' -> 0 ->> 'busy')::boolean
                   from jsonb_array_elements(tutor_screen(null, (select d0 + 2 from rd), (select d0 + 2 from rd)) -> 'makeups') m
                   where m ->> 'id' = (select id::text from r25)),
  'R-25: 강사 화면 보강 후보에 why=closed (열지 않은 시간) (4530)');
set request.jwt.claim.sub = 'bbbbbbbb-0000-0000-0000-000000000009';
select admin_makeup_withdraw((select id from r25));
reset role;
update tutor_availability set end_local = '23:30' where tutor_id = '55555555-0000-0000-0000-00000000452a' and weekday = extract(dow from (select d0 + 2 from rd));
reset request.jwt.claim.sub;
reset role;

-- ---------- 4540 Work 3차 재검증(b16c683) R-25 사유 우선순위 ----------
reset request.jwt.claim.sub;
reset role;
-- 재검A: d0+4 19:00 닫힘(가능 시간 18:00 까지) + 같은 날 휴무 → 사유는 '강사 휴무' (열라고 하지 않음)
update tutor_availability set end_local = '18:00' where tutor_id = '55555555-0000-0000-0000-00000000452a' and weekday = extract(dow from (select d0 + 4 from rd));
insert into tutor_time_off (tutor_id, starts_at, ends_at, kind, reason) select '55555555-0000-0000-0000-00000000452a', pg_temp.rk(4, '00:00'), pg_temp.rk(5, '00:00'), 'leave', 'R-25 시험 휴무' from rd;
select pg_temp.ok(lms_makeup_conflict('55555555-0000-0000-0000-00000000452a', '99999999-0000-0000-0000-000000004520', pg_temp.rk(4, '19:00'), pg_temp.rk(4, '19:40'), false) = '강사 휴무'
              and lms_conflict_code(lms_makeup_conflict('55555555-0000-0000-0000-00000000452a', '99999999-0000-0000-0000-000000004520', pg_temp.rk(4, '19:00'), pg_temp.rk(4, '19:40'), false)) = 'leave',
  'R-25: 휴무 + 닫힌 시간 → 휴무가 먼저 (4540)');
-- 재검2 학생 수업(d0+2 20:00, 재검A)이 있는 시간 + 닫힘 → '다른 수업' 이 먼저
update tutor_availability set end_local = '18:00' where tutor_id = '55555555-0000-0000-0000-00000000452a' and weekday = extract(dow from (select d0 + 2 from rd));
select pg_temp.ok(lms_makeup_conflict('55555555-0000-0000-0000-00000000452a', '99999999-0000-0000-0000-000000004520', pg_temp.rk(2, '20:00'), pg_temp.rk(2, '20:40'), false) like '강사 다른 수업%'
              and lms_makeup_conflict('55555555-0000-0000-0000-00000000452a', '99999999-0000-0000-0000-000000004520', pg_temp.rk(2, '21:30'), pg_temp.rk(2, '22:10'), false) like '강사가 열어 둔 시간이 아님%'
              and lms_makeup_conflict('55555555-0000-0000-0000-00000000452a', '99999999-0000-0000-0000-000000004520', pg_temp.rk(2, '04:00'), pg_temp.rk(2, '04:40'), false) like '%06:00~22:30%',
  'R-25: 다른 수업 + 닫힌 시간 → 다른 수업 먼저, 닫힌 시간만이면 열지 않음, 새벽은 시작 가능 시간 (4540)');
select pg_temp.ok(lms_conflict_message_en('강사 휴무') = 'You are on leave at this time.' and lms_conflict_message_en('강사가 열어 둔 시간이 아님(Availability·Schedule)') like 'This time is not in your open hours%',
  'R-25: 강사용 영어 사유 문구 (4540)');
-- 강사 '가능' 답: 휴무 날 후보 → 'on leave' 문구 (열라고 하지 않음)
set role authenticated;
set request.jwt.claim.sub = 'bbbbbbbb-0000-0000-0000-000000000009';
create temp table r25b as select (admin_makeup_request('77777777-4520-0000-0000-000000000001', null,
  jsonb_build_array(jsonb_build_object('starts_at', pg_temp.rk(4, '19:00'))), now()) ->> 'makeup_request_id')::uuid as id;
grant select on r25b to authenticated;
set request.jwt.claim.sub = 'bbbbbbbb-0000-0000-0000-000000004520';
select pg_temp.expect_error($$select tutor_makeup_answer((select id from r25b), array[(select c.id from makeup_candidates c where c.request_id = (select id from r25b))], null)$$, 'on leave at this time');
select pg_temp.ok((select m -> 'slots' -> 0 ->> 'why' = 'leave' from jsonb_array_elements(tutor_screen(null, (select d0 + 4 from rd), (select d0 + 4 from rd)) -> 'makeups') m where m ->> 'id' = (select id::text from r25b)),
  'R-25: 강사 화면 후보 why=leave, 가능 답은 휴무 사유로 거절 (4540)');
set request.jwt.claim.sub = 'bbbbbbbb-0000-0000-0000-000000000009';
select pg_temp.expect_error($$select admin_makeup_confirm((select id from r25b), pg_temp.rk(4, '19:00'))$$, '강사 휴무입니다');
select admin_makeup_withdraw((select id from r25b));
reset request.jwt.claim.sub;
reset role;
update tutor_availability set end_local = '23:30' where tutor_id = '55555555-0000-0000-0000-00000000452a';
update tutor_time_off set starts_at = timestamptz '1900-01-01', ends_at = timestamptz '1900-01-02' where tutor_id = '55555555-0000-0000-0000-00000000452a' and reason = 'R-25 시험 휴무';

-- ---------- 4600 첫 수업 후 강사 To-do · 실제 Class Style (20261107010000, H26(67)·(68)·(71)) ----------
reset request.jwt.claim.sub;
reset role;
insert into tutors (id, name, country, timezone) values
  ('55555555-0000-0000-0000-000000004600', 'FollowTutor', 'Canada', 'America/Toronto'),
  ('55555555-0000-0000-0000-000000004601', 'FollowSub', 'Canada', 'America/Toronto');
insert into students (id, name_ko, name_en, display_name, timezone, email, class_style, class_style_note, improve, textbook)
values ('99999999-0000-0000-0000-000000004600', '이첫수', 'Lee Cheotsu', null, 'Asia/Seoul', 'f4600@example.com', 'free_talking', 'wants to talk a lot', 'operator wrote this first', null);
insert into enrollments (id, student_id, seq, weeks, weekly_count, duration_min, start_date, base_end_date, lessons_purchased, status)
values ('99999999-1000-0000-0000-000000004600', '99999999-0000-0000-0000-000000004600', 1, 4, 1, 40, (now() at time zone 'Asia/Seoul')::date, (now() at time zone 'Asia/Seoul')::date + 27, 4, 'active');
insert into regular_schedules (student_id, tutor_id, weekday, start_time_kst, duration_min, effective_from)
values ('99999999-0000-0000-0000-000000004600', '55555555-0000-0000-0000-000000004600', 3, '20:00', 40, (now() at time zone 'Asia/Seoul')::date);
-- 수업 2회: 1회(조금 전, 아직 기록 전) · 2회(앞으로). 4601: 기준일(기능 시작일 = 오늘) 이후 시작한 새 학생
insert into lessons (id, enrollment_id, student_id, tutor_id, kind, seq, starts_at, ends_at) values
  ('77777777-4600-0000-0000-000000000001', '99999999-1000-0000-0000-000000004600', '99999999-0000-0000-0000-000000004600', '55555555-0000-0000-0000-000000004600', 'regular', 1, now() - interval '2 hours', now() - interval '2 hours' + interval '40 minutes'),
  ('77777777-4600-0000-0000-000000000002', '99999999-1000-0000-0000-000000004600', '99999999-0000-0000-0000-000000004600', '55555555-0000-0000-0000-000000004600', 'regular', 2, now() + interval '4 days', now() + interval '4 days' + interval '40 minutes');
insert into app_users (auth_user_id, role, tutor_id) values
  ('bbbbbbbb-0000-0000-0000-000000004600', 'tutor', '55555555-0000-0000-0000-000000004600'),
  ('bbbbbbbb-0000-0000-0000-000000004601', 'tutor', '55555555-0000-0000-0000-000000004601');
-- 시험용 읽기 도우미 (RLS 우회, 시험 안에서만)
create function pg_temp.s4600() returns students language sql security definer as $$ select * from students where id = '99999999-0000-0000-0000-000000004600' $$;
create function pg_temp.e4600(f text) returns bigint language sql security definer as $$ select count(*) from student_profile_edits where student_id = '99999999-0000-0000-0000-000000004600' and field = f $$;
create function pg_temp.lastrole4600() returns text language sql security definer as $$ select edited_role from student_profile_edits where student_id = '99999999-0000-0000-0000-000000004600' and field = 'level' order by created_at desc limit 1 $$;
set request.jwt.claims = '{"aal":"aal2"}';
set role authenticated;
set request.jwt.claim.sub = 'bbbbbbbb-0000-0000-0000-000000004600';
select pg_temp.ok(tutor_first_lesson_todos(null) = '[]'::jsonb
              and (select p -> 'followup' = 'null'::jsonb or p -> 'followup' is null from tutor_student_profile('99999999-0000-0000-0000-000000004600', null) p),
  '첫 수업이 Held 로 기록되기 전에는 To-do 없음 (4600)');
-- 1회를 Held 로 기록 (출결 함수 그대로)
select tutor_record_class('77777777-4600-0000-0000-000000000001', 'held', 'First class: intro', '', false, null, false, null);
select pg_temp.ok((select count(*) = 1 and (jsonb_agg(x) -> 0 ->> 'pending')::int = 3 and (jsonb_agg(x) -> 0 ->> 'student') = 'Lee Cheotsu'
                   from jsonb_array_elements(tutor_first_lesson_todos(null)) x),
  '첫 수업 Held 기록 → To-do 1명, 덜 한 항목 3 (Level · Wants to improve · Class Style) (4600)');
select pg_temp.ok((select p -> 'followup' -> 'done' = '{"level": false, "improve": false, "style": false, "record": true}'::jsonb
                   and p -> 'followup' -> 'first_lesson' ->> 'topics' = 'First class: intro'
                   from tutor_student_profile('99999999-0000-0000-0000-000000004600', null) p),
  'Student profile 의 followup: Class Record 는 첫 수업 기록으로 자동 완료, 나머지 셋은 미완료 (4600)');
-- 운영진이 미리 적어 둔 improve 는 강사가 확인해 적기 전까지 완료 아님 / 1 레벨 저장
select pg_temp.expect_error($$select tutor_first_lesson_save('99999999-0000-0000-0000-000000004600', '{"level":"Expert"}')$$, 'rubric');
create temp table f4600 as select tutor_first_lesson_save('99999999-0000-0000-0000-000000004600', '{"level":"Intermediate"}') as r;
grant select on f4600 to authenticated;
select pg_temp.ok((select (r -> 'done' ->> 'level')::boolean and (r ->> 'pending')::int = 2 from f4600)
              and (select (x).level = 'Intermediate' and (x).level_by = 'bbbbbbbb-0000-0000-0000-000000004600' and (x).level_at is not null from pg_temp.s4600() x),
  '1 English Level 저장 → 완료, 평가자·시각 기록 (4600)');
-- 같은 레벨을 다시 골라도 '확인함' (평가 시각 갱신) — 변경 기록은 안 늘어남
delete from f4600; insert into f4600 select tutor_first_lesson_save('99999999-0000-0000-0000-000000004600', '{"level":"Intermediate"}');
select pg_temp.ok((select (r -> 'done' ->> 'level')::boolean from f4600)
              and pg_temp.e4600('level') = 1,
  '같은 레벨 다시 저장: 완료 유지, 바뀐 게 없으면 변경 기록 없음 (4600)');
-- 2 Wants to improve
select pg_temp.expect_error($$select tutor_first_lesson_save('99999999-0000-0000-0000-000000004600', '{"improve":"  "}')$$, 'wants to improve');
delete from f4600; insert into f4600 select tutor_first_lesson_save('99999999-0000-0000-0000-000000004600', '{"improve":"Speaking confidence at work"}');
select pg_temp.ok((select (r -> 'done' ->> 'improve')::boolean and (r ->> 'pending')::int = 1 from f4600)
              and (select (x).improve = 'Speaking confidence at work' and (x).improve_tutor_at is not null from pg_temp.s4600() x),
  '2 Wants to improve: 강사가 적으면 완료 (4600)');
-- 3 Class Style: 교재 방식인데 교재 없음 → 거절 / Mixed 구성 없음 → 거절 / 모르는 구성 → 거절
select pg_temp.expect_error($$select tutor_first_lesson_save('99999999-0000-0000-0000-000000004600', '{"class_style":"textbook"}')$$, 'textbook');
select pg_temp.expect_error($$select tutor_first_lesson_save('99999999-0000-0000-0000-000000004600', '{"class_style":"mixed","class_style_mix":[]}')$$, 'mixed class includes');
select pg_temp.expect_error($$select tutor_first_lesson_save('99999999-0000-0000-0000-000000004600', '{"class_style":"mixed","class_style_mix":["video"]}')$$, 'Unknown mix');
select pg_temp.expect_error($$select tutor_first_lesson_save('99999999-0000-0000-0000-000000004600', '{"class_style":"mixed","class_style_mix":["conversation","textbook"]}')$$, 'textbook');
select pg_temp.ok(true, '3 Class Style: 교재 없는 Textbook/Mixed+Textbook · 구성 없는 Mixed · 모르는 구성은 거절 (4600)');
delete from f4600; insert into f4600 select tutor_first_lesson_save('99999999-0000-0000-0000-000000004600', '{"class_style":"mixed","class_style_mix":["textbook","conversation","student_materials"],"textbook":"Speak now 2","materials_note":"work emails"}');
select pg_temp.ok((select (r -> 'done' ->> 'style')::boolean and (r ->> 'pending')::int = 0 from f4600)
              and (select (x).tutor_class_style = 'mixed' and (x).tutor_class_style_mix = '{conversation,student_materials,textbook}' and (x).textbook = 'Speak now 2'
                          and (x).tutor_materials_note = 'work emails' and (x).tutor_class_style_at is not null
                          and (x).class_style = 'free_talking' and (x).class_style_note = 'wants to talk a lot'
                   from pg_temp.s4600() x),
  '3 Mixed + 교재 + 학생 자료 저장 → 완료. 학생의 원래 답(class_style·note)은 그대로 (4600)');
select pg_temp.ok(tutor_first_lesson_todos(null) = '[]'::jsonb
              and (select (p -> 'followup' ->> 'pending')::int = 0 and p -> 'student' ->> 'tutor_class_style' = 'mixed' and p -> 'student' ->> 'tutor_class_style_by' = 'FollowTutor'
                   from tutor_student_profile('99999999-0000-0000-0000-000000004600', null) p),
  '넷 다 끝나면 Home To-do 에서 사라짐, 프로필에 강사 확인 값·확인한 강사 이름 (4600)');
-- Conversation 으로 바꿔도 교재 칸은 지우지 않음 (나중에 다시 쓸 수 있음)
select tutor_first_lesson_save('99999999-0000-0000-0000-000000004600', '{"class_style":"conversation"}');
select pg_temp.ok((select (x).tutor_class_style = 'conversation' and (x).tutor_class_style_mix is null and (x).textbook = 'Speak now 2' from pg_temp.s4600() x),
  'Conversation 으로 바꾸면 구성은 비우고 교재 칸은 그대로 (4600)');
-- 4601: 기존 학생(기준일 전에 진행한 수업이 있음)은 첫 Held 수업이 있어도 To-do 없음
reset role;
insert into students (id, name_ko, name_en, timezone) values ('99999999-0000-0000-0000-000000004601', '박오래', 'Park Orae', 'Asia/Seoul');
insert into enrollments (id, student_id, seq, weeks, weekly_count, duration_min, start_date, base_end_date, lessons_purchased, status)
values ('99999999-1000-0000-0000-000000004601', '99999999-0000-0000-0000-000000004601', 2, 4, 1, 40, (now() at time zone 'Asia/Seoul')::date, (now() at time zone 'Asia/Seoul')::date + 27, 4, 'active');
insert into regular_schedules (student_id, tutor_id, weekday, start_time_kst, duration_min, effective_from)
values ('99999999-0000-0000-0000-000000004601', '55555555-0000-0000-0000-000000004600', 4, '20:00', 40, (now() at time zone 'Asia/Seoul')::date);
insert into lessons (id, enrollment_id, student_id, tutor_id, kind, seq, starts_at, ends_at, state, class_status) values
  ('77777777-4601-0000-0000-000000000001', '99999999-1000-0000-0000-000000004601', '99999999-0000-0000-0000-000000004601', '55555555-0000-0000-0000-000000004600', 'regular', 1, now() - interval '40 days', now() - interval '40 days' + interval '40 minutes', 'done', 'Normal'),
  ('77777777-4601-0000-0000-000000000002', '99999999-1000-0000-0000-000000004601', '99999999-0000-0000-0000-000000004601', '55555555-0000-0000-0000-000000004600', 'regular', 2, now() - interval '1 hour', now() - interval '1 hour' + interval '40 minutes', 'done', 'Normal');
set role authenticated;
set request.jwt.claim.sub = 'bbbbbbbb-0000-0000-0000-000000004600';
select pg_temp.ok(tutor_first_lesson_todos(null) = '[]'::jsonb
              and (select p -> 'followup' = 'null'::jsonb or p -> 'followup' is null from tutor_student_profile('99999999-0000-0000-0000-000000004601', null) p),
  '4601: 기준일 전에 수업한 기존 학생은 새 수강권을 시작해도 To-do 가 생기지 않음');
-- 권한: 담당 아닌 강사(대체 아님) 거절 · 모르는 칸 거절
set request.jwt.claim.sub = 'bbbbbbbb-0000-0000-0000-000000004601';
select pg_temp.expect_error($$select tutor_first_lesson_save('99999999-0000-0000-0000-000000004600', '{"level":"Beginner"}')$$, 'regular tutor|42501');
select pg_temp.ok(tutor_first_lesson_todos(null) = '[]'::jsonb, '담당 아닌 강사: 저장 거절, To-do 없음 (4600)');
set request.jwt.claim.sub = 'bbbbbbbb-0000-0000-0000-000000004600';
select pg_temp.expect_error($$select tutor_first_lesson_save('99999999-0000-0000-0000-000000004600', '{"hobbies":"x"}')$$, 'cannot be changed');
select pg_temp.ok(true, '학생 원래 답 칸(hobbies 등)은 이 함수로 못 바꿈 (4600)');
-- 운영자(TOTP)가 강사 문맥(?tutor=)으로 대신: 같은 결과, 역할은 admin 으로 기록
set request.jwt.claim.sub = 'bbbbbbbb-0000-0000-0000-000000000009';
delete from f4600; insert into f4600 select tutor_first_lesson_save('99999999-0000-0000-0000-000000004600', '{"level":"Advanced"}', '55555555-0000-0000-0000-000000004600');
select pg_temp.ok((select count(*) = 0 from jsonb_array_elements(tutor_first_lesson_todos('55555555-0000-0000-0000-000000004600')) x)
              and (select (r -> 'done' ->> 'level')::boolean from f4600)
              and pg_temp.lastrole4600() = 'admin'
              and (select p -> 'student' ->> 'tutor_class_style' = 'conversation' from admin_student_detail('99999999-0000-0000-0000-000000004600') p),
  '운영자: 강사 고른 문맥으로 To-do 조회·저장 가능(역할 admin 기록), 운영진 상세에도 강사 확인 값 (4600)');
reset request.jwt.claim.sub;
reset role;

-- ---------------------------------------------------------------------
-- QA C-04 (2026-11-07): student_textbook — 학생 본인·운영자만, 수업 방식에 교재가 있을 때만
-- ---------------------------------------------------------------------
update students set textbook = 'Smart Choice 2', tutor_class_style = null, tutor_class_style_mix = null where id = '33333333-3333-3333-3333-333333333333';
set role authenticated;
set request.jwt.claim.sub = 'bbbbbbbb-0000-0000-0000-000000000001';
select pg_temp.ok(student_textbook(null) ->> 'textbook' = 'Smart Choice 2', 'C-04: 학생 본인 교재 보임 (강사 확인 수업 방식 없음 = 예전 학생)');
select pg_temp.expect_error($$select student_textbook('44444444-4444-4444-4444-444444444444')$$, '학생 계정으로 로그인|42501');
select pg_temp.ok(true, 'C-04: 다른 학생 교재 요청 거절');
reset role;
update students set tutor_class_style = 'conversation' where id = '33333333-3333-3333-3333-333333333333';
set role authenticated;
select pg_temp.ok(student_textbook(null) ->> 'textbook' is null, 'C-04: Conversation 이면 교재 칸이 남아 있어도 학생에게 안 보임');
reset role;
update students set tutor_class_style = 'mixed', tutor_class_style_mix = '{conversation,textbook}' where id = '33333333-3333-3333-3333-333333333333';
set role authenticated;
select pg_temp.ok(student_textbook(null) ->> 'textbook' = 'Smart Choice 2', 'C-04: Mixed 에 Textbook 포함이면 보임');
set request.jwt.claim.sub = 'bbbbbbbb-0000-0000-0000-000000000009';
select pg_temp.ok(student_textbook('33333333-3333-3333-3333-333333333333') ->> 'textbook' = 'Smart Choice 2', 'C-04: 운영자 보기(학생 고름)도 같은 값');
reset request.jwt.claim.sub;
reset role;
update students set textbook = null, tutor_class_style = null, tutor_class_style_mix = null where id = '33333333-3333-3333-3333-333333333333';

-- ---------------------------------------------------------------------
-- 강사 자율 운영 1단계 (20261108000000, H26(82)): 강사가 학생 시간 하나를 골라 확정 → 바로 보강 수업
-- ---------------------------------------------------------------------
insert into lessons (id, enrollment_id, student_id, tutor_id, kind, seq, starts_at, ends_at, state, class_status, canceled_at)
select v.id::uuid, '99999999-1000-0000-0000-000000002000', '99999999-0000-0000-0000-000000002000', '55555555-0000-0000-0000-00000000200a',
       'regular', v.seq, t + v.off, t + v.off + interval '40 minutes', 'canceled', 'Student canceled in advance', now()
from rc, (values ('77777777-2000-0000-0000-0000000000a1', 7, interval '-2 days'), ('77777777-2000-0000-0000-0000000000a2', 8, interval '-1 days')) v(id, seq, off);
set role authenticated;
set request.jwt.claim.sub = 'bbbbbbbb-0000-0000-0000-000000000009';
create temp table mk82 as select (admin_makeup_request('77777777-2000-0000-0000-0000000000a1', null,
  jsonb_build_array(jsonb_build_object('starts_at', ((current_date + 4) + time '12:00') at time zone 'Australia/Sydney'), jsonb_build_object('starts_at', ((current_date + 5) + time '12:00') at time zone 'Australia/Sydney')), now())
  ->> 'makeup_request_id')::uuid as id;
create temp table mk82b as select (admin_makeup_request('77777777-2000-0000-0000-0000000000a2', null,
  jsonb_build_array(jsonb_build_object('starts_at', ((current_date + 5) + time '12:00') at time zone 'Australia/Sydney'), jsonb_build_object('starts_at', ((current_date + 6) + time '12:00') at time zone 'Australia/Sydney')), now())
  ->> 'makeup_request_id')::uuid as id;
create or replace function pg_temp.mkc(p uuid, n int) returns uuid language sql as $$ select c.id from makeup_candidates c where c.request_id = p and c.proposed_by = 'student' order by c.starts_at offset n - 1 limit 1 $$;
select pg_temp.ok((select confirmed_in_tutor_screen = false from makeup_requests where id = (select id from mk20))
              and (select count(*) = 1 from lesson_notices n where n.makeup_request_id = (select id from mk20) and n.event = 'makeup_confirmed' and n.recipient_kind = 'tutor'),
  '운영진 확정은 그대로: 강사 화면 확정 아님, 강사 확정 안내도 만듦');
set request.jwt.claim.sub = 'bbbbbbbb-0000-0000-0000-00000000200b';
select pg_temp.expect_error($$select tutor_makeup_confirm((select id from mk82), pg_temp.mkc((select id from mk82), 1))$$, '42501');
set request.jwt.claim.sub = 'bbbbbbbb-0000-0000-0000-00000000200a';
select pg_temp.expect_error($$select tutor_makeup_confirm((select id from mk82), pg_temp.mkc((select id from mk82b), 1))$$, 'Unknown time');
select pg_temp.ok(true, '강사 확정: 다른 강사 신청 거절, 다른 신청의 시간 거절');
select tutor_makeup_confirm((select id from mk82), pg_temp.mkc((select id from mk82), 2));
select pg_temp.ok((tutor_makeup_confirm((select id from mk82), pg_temp.mkc((select id from mk82), 2)) ->> 'repeated')::boolean, '같은 시간 다시 누르면 같은 결과(repeated)');
select pg_temp.expect_error($$select tutor_makeup_confirm((select id from mk82), pg_temp.mkc((select id from mk82), 1))$$, 'already closed');
select pg_temp.ok(true, '확정 뒤 다른 시간은 거절');
select pg_temp.expect_error($$select tutor_makeup_confirm((select id from mk82b), pg_temp.mkc((select id from mk82b), 1))$$, 'can''t confirm this time: You have another class');
select pg_temp.ok((select status = 'requested' and tutor_answered_at is null from makeup_requests where id = (select id from mk82b)),
  '방금 확정한 보강과 겹치는 시간은 영어 사유로 거절, 신청은 그대로');
set request.jwt.claim.sub = 'bbbbbbbb-0000-0000-0000-000000000009';
select pg_temp.ok((select r.status = 'confirmed' and r.confirmed_in_tutor_screen and r.decided_by = 'bbbbbbbb-0000-0000-0000-00000000200a'
                          and l.starts_at = ((current_date + 5) + time '12:00') at time zone 'Australia/Sydney' and l.kind = 'makeup'
                          and l.makeup_of = '77777777-2000-0000-0000-0000000000a1' and l.tutor_id = '55555555-0000-0000-0000-00000000200a' and l.state = 'scheduled'
                   from makeup_requests r join lessons l on l.id = r.confirmed_lesson_id where r.id = (select id from mk82))
              and (select count(*) = 1 from lesson_notices n where n.makeup_request_id = (select id from mk82) and n.event = 'makeup_confirmed' and n.recipient_kind = 'student' and n.status = 'pending')
              -- 2단계(20261108010000): 강사가 직접 확정해도 강사 안내 줄은 생김(자동 메일용) — WhatsApp 복사는 필요 없음(not_needed)
              and (select count(*) = 1 from lesson_notices n where n.makeup_request_id = (select id from mk82) and n.event = 'makeup_confirmed' and n.recipient_kind = 'tutor' and n.status = 'not_needed')
              and (select count(*) = 0 from lesson_notices n where n.makeup_request_id = (select id from mk82) and n.event = 'makeup_ask' and n.status = 'pending')
              and (select tutor_answer = 'yes' from makeup_candidates where id = pg_temp.mkc((select id from mk82), 2)),
  '강사 확정: 고른 시간에 보강 수업 생성, 확정자 = 강사, 학생 안내만 운영진 차례(강사 WhatsApp 복사 없음, 메일용 줄만), 묻기 안내 닫힘');
select tutor_makeup_confirm((select id from mk82b), pg_temp.mkc((select id from mk82b), 2));
select pg_temp.ok((select status = 'confirmed' and confirmed_in_tutor_screen and decided_by = 'bbbbbbbb-0000-0000-0000-000000000009' from makeup_requests where id = (select id from mk82b)),
  '운영자 보기에서 대신 확정 = 같은 함수, 확정자 = 운영자');
reset request.jwt.claim.sub;
reset role;

-- ---------------------------------------------------------------------
-- 2026-11-07 admin_makeup_record_past: 이미 진행한 보강 기록 (운영진만, 지난 시각만, 사유 필수, 권리 한 번만)
-- ---------------------------------------------------------------------
insert into students (id, name_ko, name_en, timezone) values ('99999999-0000-0000-0000-000000005000', '도과거', 'Past Do', 'Asia/Seoul');
insert into enrollments (id, student_id, seq, weeks, weekly_count, duration_min, start_date, base_end_date, lessons_purchased, status)
values ('99999999-1000-0000-0000-000000005000', '99999999-0000-0000-0000-000000005000', 1, 4, 2, 20, (now() at time zone 'Asia/Seoul')::date - 10, (now() at time zone 'Asia/Seoul')::date + 17, 8, 'active');
insert into lessons (id, enrollment_id, student_id, tutor_id, kind, seq, starts_at, ends_at, state, class_status, canceled_at) values
  ('77777777-5000-0000-0000-000000000001', '99999999-1000-0000-0000-000000005000', '99999999-0000-0000-0000-000000005000', '55555555-0000-0000-0000-000000004600', 'regular', 1,
   date_trunc('hour', now()) - interval '2 days', date_trunc('hour', now()) - interval '2 days' + interval '20 minutes', 'canceled', 'Student canceled in advance', now() - interval '3 days');
set role authenticated;
set request.jwt.claim.sub = 'bbbbbbbb-0000-0000-0000-000000000001';
select pg_temp.expect_error($$select admin_makeup_record_past('77777777-5000-0000-0000-000000000001', null, now() - interval '1 day', '더블 수업')$$, '운영자');
select pg_temp.ok(true, '지난 보강 기록: 운영자가 아니면 거절');
set request.jwt.claim.sub = 'bbbbbbbb-0000-0000-0000-000000000009';
select pg_temp.expect_error($$select admin_makeup_record_past('77777777-5000-0000-0000-000000000001', null, now() + interval '1 day', '더블 수업')$$, '이미 지난 시각만');
select pg_temp.expect_error($$select admin_makeup_record_past('77777777-5000-0000-0000-000000000001', null, now() - interval '1 day', '  ')$$, '사유');
select pg_temp.ok(true, '지난 보강 기록: 앞으로의 시각·사유 없음 거절');
select admin_makeup_record_past('77777777-5000-0000-0000-000000000001', null, date_trunc('hour', now()) - interval '1 day', '더블 수업 (시트 기록)');
select pg_temp.ok(
  (select count(*) = 1 from lessons where makeup_of = '77777777-5000-0000-0000-000000000001' and state = 'scheduled' and kind = 'makeup'
     and starts_at = date_trunc('hour', now()) - interval '1 day' and ends_at = starts_at + interval '20 minutes')
  and (select status = 'confirmed' and confirmed_lesson_id is not null from makeup_requests where source_lesson_id = '77777777-5000-0000-0000-000000000001')
  and not exists (select 1 from lesson_notices n join makeup_requests r on r.id = n.makeup_request_id where r.source_lesson_id = '77777777-5000-0000-0000-000000000001' and n.status = 'pending')
  and exists (select 1 from audit_log where actor_via like 'admin_makeup_record_past: 더블 수업%'),
  '지난 보강 기록: 보강 수업(예정·지난 시각) + 신청 확정 + 안내 할 일 없음 + 변경 기록에 사유');
select pg_temp.expect_error($$select admin_makeup_record_past('77777777-5000-0000-0000-000000000001', null, now() - interval '3 hours', '또')$$, '이미 보강');
select pg_temp.ok(not exists (select 1 from jsonb_array_elements(student_screen('99999999-0000-0000-0000-000000005000') -> 'makeup_rights') x),
  '지난 보강 기록: 같은 권리로 두 번 못 넣음 + 학생 화면 보강 날짜 고르기 사라짐');
reset request.jwt.claim.sub;
reset role;

-- ---------------------------------------------------------------------
-- 강사 자율 운영 2단계 (20261108010000, H26(86)): 보강 확정 → 학생·강사 자동 메일 (큐·중복 방지·실패 기록·다시 보내기)
-- pg_net·Vault 가짜(2900 시험에서 만든 net.sent·vault.decrypted_secrets, 키 re_test_key)를 그대로 써서 보내기 경로를 확인
-- ---------------------------------------------------------------------
reset role;
-- 가짜 전: 이메일도 pg_net 도 없던 때 만들어진 안내(mk82 학생) = 주소 없음으로 기록
select pg_temp.ok((select email_status = 'no_address' and email_error like '학생 이메일%' from lesson_notices where makeup_request_id = (select id from mk82) and recipient_kind = 'student'),
  '메일: 학생 이메일이 없으면 no_address + 사유 (보내지 않음)');
select pg_temp.ok((select email_notification_id is null from lesson_notices where makeup_request_id = (select id from mk82) and recipient_kind = 'student'), '메일: 주소 없는 안내는 큐에 넣지 않음');
create temp table sent_before as select count(*) as n from net.sent;
grant select on sent_before to authenticated;
update students set email = 'Mail-S@Example.com', timezone = 'America/Toronto' where id = '99999999-0000-0000-0000-000000002000';   -- 해외 학생: 현지 + 한국
update tutors set email = null where id = '55555555-0000-0000-0000-00000000200a';   -- 강사 이메일 없음 → no_address 뒤 다시 보내기 확인

insert into lessons (id, enrollment_id, student_id, tutor_id, kind, seq, starts_at, ends_at, state, class_status, canceled_at)
select v.id::uuid, '99999999-1000-0000-0000-000000002000', '99999999-0000-0000-0000-000000002000', '55555555-0000-0000-0000-00000000200a',
       'regular', v.seq, t + v.off, t + v.off + interval '40 minutes', 'canceled', 'Student canceled in advance', now()
from rc, (values ('77777777-2000-0000-0000-0000000000a3', 9, interval '-5 days'), ('77777777-2000-0000-0000-0000000000a4', 10, interval '-4 days')) v(id, seq, off);
set role authenticated;
set request.jwt.claim.sub = 'bbbbbbbb-0000-0000-0000-000000000009';
create temp table mk85 as select (admin_makeup_request('77777777-2000-0000-0000-0000000000a3', null,
  jsonb_build_array(jsonb_build_object('starts_at', ((current_date + 7) + time '12:00') at time zone 'Australia/Sydney')), now()) ->> 'makeup_request_id')::uuid as id;
grant select on mk85 to authenticated;
create temp table mk85b as select (admin_makeup_request('77777777-2000-0000-0000-0000000000a4', null,
  jsonb_build_array(jsonb_build_object('starts_at', ((current_date + 8) + time '12:00') at time zone 'Australia/Sydney')), now()) ->> 'makeup_request_id')::uuid as id;
grant select on mk85b to authenticated;
set request.jwt.claim.sub = 'bbbbbbbb-0000-0000-0000-00000000200b';
select pg_temp.expect_error($$select admin_mail_sync()$$, '42501');
select pg_temp.expect_error($$select admin_resend_notice_email(gen_random_uuid())$$, '42501');
select pg_temp.ok(true, '메일: 운영자가 아니면 상태 맞추기·다시 보내기 거절');
-- 강사가 직접 확정 → 학생 메일(한국어, 현지+한국) + 강사 메일(영어, 주소 없음)
set request.jwt.claim.sub = 'bbbbbbbb-0000-0000-0000-00000000200a';
select tutor_makeup_confirm((select id from mk85), pg_temp.mkc((select id from mk85), 1));
reset request.jwt.claim.sub;
reset role;
create temp table m85s as select n.*, q.url, q.body as req, q.headers as hdr
  from lesson_notices n join notifications x on x.id = n.email_notification_id join net.sent q on q.id = x.net_request_id
  where n.makeup_request_id = (select id from mk85) and n.event = 'makeup_confirmed' and n.recipient_kind = 'student';
grant select on m85s to authenticated;
select pg_temp.ok((select count(*) = 1 from m85s)
              and (select email_status = 'queued' and status = 'pending' and email_to = 'support@edgeenglish.kr' and email_intended = 'mail-s@example.com' and email_attempts = 1 from m85s)
              and (select url = 'https://api.resend.com/emails' and req -> 'to' = '["support@edgeenglish.kr"]'::jsonb from m85s)
              and (select req ->> 'subject' like '[시험 · STU-%] [엣지영어] 보강이 확정됐어요 · %' from m85s)
              and (select req ->> 'html' like '%보강 수업: % 시간) = % (한국 시간) · %분%' and req ->> 'html' like '%강사: 기록A%' and req ->> 'html' like '%/lms/student%' and req ->> 'html' like '%카카오톡 채널%' and req ->> 'html' like '%원래 수업: %' and req ->> 'html' like '%원래 받는 사람: mail-s@example.com%' from m85s)
              and (select hdr ->> 'Authorization' = 'Bearer re_test_key' and hdr ->> 'Idempotency-Key' = 'lesson_notice_email:' || id from m85s),
  '메일: 강사 확정 → 학생 메일 큐·Resend 요청(시험이라 support@, [시험 · 번호], 현지+한국 시각·강사·LMS 링크·문의 줄), 카톡 카드는 그대로(pending)');
select pg_temp.ok((select email_status = 'no_address' and status = 'not_needed' and email_error like '강사 이메일%' from lesson_notices where makeup_request_id = (select id from mk85) and event = 'makeup_confirmed' and recipient_kind = 'tutor'),
  '메일: 강사 직접 확정 → 강사 안내 줄(WhatsApp 복사 불필요) + 이메일 없으면 no_address');
select pg_temp.ok(lms_mail_ko_at('2026-11-11 02:00Z', 'Asia/Seoul') = '11월 11일(수) 오전 11시 (한국 시간)'
              and lms_mail_ko_at('2026-11-13 00:00Z', 'America/Toronto') = '11월 12일(목) 오후 7시 (토론토 시간) = 11월 13일(금) 오전 9시 (한국 시간)'
              and (select req ->> 'subject' like '% (' || lms_mail_ko_zone((select timezone from students where id = m85s.recipient_id)) || ')' from m85s),
  '메일 시각: 한국 거주 (한국 시간), 해외 (도시 시간) = (한국 시간), 도시 한국어, 제목에도 시간대 이름 (대표 2026-11-08)');
-- 중복 방지: 같은 안내를 다시 큐에 넣어도 메일 1통
select lms_mail_enqueue_notice((select id from m85s));
select pg_temp.ok((select count(*) = 1 from notifications where dedupe_key = 'lesson_notice_email:' || (select id from m85s)) and (select count(*) = (select n from sent_before) + 1 from net.sent),
  '메일: 같은 안내는 한 번만 (dedupe_key, 요청 1건)');
-- 응답 처리: 200 → 보냄 (운영진 화면이 부름)
insert into net._http_response (id, status_code, content) values ((select net_request_id from notifications where dedupe_key = 'lesson_notice_email:' || (select id from m85s)), 200, '{"id":"re_1"}');
set role authenticated;
set request.jwt.claim.sub = 'bbbbbbbb-0000-0000-0000-000000000009';
create temp table dbg85 as select admin_mail_sync() as r;
select pg_temp.ok((select (r ->> 'sent')::int from dbg85) >= 1
              and (select email_status = 'sent' and email_sent_at is not null and email_error is null and status = 'pending' from lesson_notices where id = (select id from m85s))
              and (select status = 'sent' from notifications where dedupe_key = 'lesson_notice_email:' || (select id from m85s)),
  '메일: 응답 200 → 학생 메일 보냄 기록, 카톡 카드는 여전히 운영진 차례');
select pg_temp.ok((admin_resend_notice_email((select id from m85s)) ->> 'repeated')::boolean, '메일: 이미 보낸 안내 다시 보내기 → 그대로(두 번 안 보냄)');
-- 강사 이메일을 채운 뒤 다시 보내기 → 주소 다시 찾아 큐·요청
reset role;
update tutors set email = 'tutor-a@example.com' where id = '55555555-0000-0000-0000-00000000200a';
set role authenticated;
select admin_resend_notice_email((select id from lesson_notices where makeup_request_id = (select id from mk85) and event = 'makeup_confirmed' and recipient_kind = 'tutor'));
reset role;
create temp table m85t as select n.*, q.body as req, q.headers as hdr
  from lesson_notices n join notifications x on x.id = n.email_notification_id join net.sent q on q.id = x.net_request_id
  where n.makeup_request_id = (select id from mk85) and n.event = 'makeup_confirmed' and n.recipient_kind = 'tutor';
grant select on m85t to authenticated;
select pg_temp.ok((select email_status = 'queued' and email_intended = 'tutor-a@example.com' and email_to = 'support@edgeenglish.kr' from m85t)
              and (select req ->> 'subject' like '[시험 · STU-%] CONFIRMED make-up - Record S · % Sydney Time' from m85t)
              and (select req ->> 'html' like '%Make-up: % Sydney Time (% KST)%' and req ->> 'html' like '%Original class: %' and req ->> 'html' like '%/lms/tutor%' and req ->> 'html' like '%WhatsApp%' from m85t)
              and (select (req ->> 'from') like 'Edge English <%' from m85t),
  '메일: 강사 이메일 채운 뒤 다시 보내기 → 영어 메일(현지 Sydney Time + KST, 강사 LMS 링크)');
-- 실패 기록 → 다시 보내기 → 새 요청(Idempotency-Key 에 시도 번호)
reset role;
insert into net._http_response (id, status_code, content) values ((select net_request_id from notifications where id = (select email_notification_id from m85t)), 422, '{"message":"bad address"}');
set role authenticated;
select admin_mail_sync();
reset role;
select pg_temp.ok((select email_status = 'failed' and email_error like '422%bad address%' from lesson_notices where id = (select id from m85t))
              and (select status = 'failed' from notifications where id = (select email_notification_id from m85t)),
  '메일: 응답 422 → 실패 + 사유 기록 (자동 재시도 없음)');
set role authenticated;
set request.jwt.claim.sub = 'bbbbbbbb-0000-0000-0000-000000000009';
select admin_resend_notice_email((select id from m85t));
reset role;
select pg_temp.ok((select email_status = 'queued' and email_attempts = 2 and email_error is null from lesson_notices where id = (select id from m85t))
              and (select count(*) = 2 from net.sent q where q.body ->> 'subject' like '%CONFIRMED make-up - Record S%')
              and (select q.headers ->> 'Idempotency-Key' = 'lesson_notice_email:' || (select id from m85t) || ':1'
                   from net.sent q where q.id = (select net_request_id from notifications where id = (select email_notification_id from m85t))),
  '메일: 실패한 안내 다시 보내기 → 새 요청(시도 번호 붙은 Idempotency-Key), 시도 2회');
-- 운영진 확정도 양쪽 메일 + 양쪽 카드(pending)
set role authenticated;
set request.jwt.claim.sub = 'bbbbbbbb-0000-0000-0000-000000000009';
select admin_makeup_confirm((select id from mk85b), ((current_date + 8) + time '12:00') at time zone 'Australia/Sydney');
select pg_temp.ok((select count(*) = 2 from lesson_notices where makeup_request_id = (select id from mk85b) and event = 'makeup_confirmed' and status = 'pending' and email_status = 'queued' and email_attempts = 1),
  '메일: 운영진 확정 → 학생·강사 안내 줄 모두 카드(pending) + 메일 큐');
-- 실제 발송 스위치를 켜면 원래 주소로, 제목에 [시험] 없음 (내용만 확인, 스위치는 다시 끔)
reset role;
update feature_flags set enabled = true where key = 'send_emails';
select pg_temp.ok((select to_email = 'mail-s@example.com' and subject like '[엣지영어] 보강이 확정됐어요 · %' and html not like '%원래 받는 사람%' from lms_notice_mail((select id from m85s))),
  '메일: send_emails 켜면 학생 주소로, [시험] 표시 없음');
update feature_flags set enabled = false where key = 'send_emails';
-- 운영진 숨은참조 (대표 2026-11-08): 실제 주소로 갈 때만 bcc support@, 스위치 끄면 없음, 시험 발송(support@)엔 없음
insert into notifications (recipient_kind, recipient_id, email, locale, template, payload, dedupe_key)
values ('student', (select recipient_id from m85s), 'live-s@example.com', 'ko', 'lesson_notice_bcc_test', '{"subject":"s","html":"h","text":"t"}', 'bcc_test:1'),
       ('student', (select recipient_id from m85s), 'live-s@example.com', 'ko', 'lesson_notice_bcc_test', '{"subject":"s","html":"h","text":"t"}', 'bcc_test:2');
select lms_mail_dispatch((select id from notifications where dedupe_key = 'bcc_test:1'));
update feature_flags set enabled = true where key = 'email_bcc_ops_stop';
select lms_mail_dispatch((select id from notifications where dedupe_key = 'bcc_test:2'));
update feature_flags set enabled = false where key = 'email_bcc_ops_stop';
select pg_temp.ok((select q.body -> 'bcc' = '["support@edgeenglish.kr"]'::jsonb from net.sent q where q.id = (select net_request_id from notifications where dedupe_key = 'bcc_test:1'))
              and (select not (q.body ? 'bcc') from net.sent q where q.id = (select net_request_id from notifications where dedupe_key = 'bcc_test:2'))
              and (select not (req ? 'bcc') from m85s)
              and (select not enabled from feature_flags where key = 'email_bcc_ops_stop'),
  '메일 숨은참조: 실제 주소면 bcc support@ (기본), email_bcc_ops_stop 켜면 없음, 시험 발송엔 없음');
-- 키가 없으면 큐에 남고 사유 기록, 키를 넣은 뒤 상태 맞추기가 보냄
delete from vault.decrypted_secrets;
insert into lessons (id, enrollment_id, student_id, tutor_id, kind, seq, starts_at, ends_at, state, class_status, canceled_at)
select '77777777-2000-0000-0000-0000000000a5', '99999999-1000-0000-0000-000000002000', '99999999-0000-0000-0000-000000002000', '55555555-0000-0000-0000-00000000200a',
       'regular', 11, t - interval '3 days', t - interval '3 days' + interval '40 minutes', 'canceled', 'Student canceled in advance', now() from rc;
set role authenticated;
create temp table mk85c as select (admin_makeup_request('77777777-2000-0000-0000-0000000000a5', null,
  jsonb_build_array(jsonb_build_object('starts_at', ((current_date + 9) + time '12:00') at time zone 'Australia/Sydney')), now()) ->> 'makeup_request_id')::uuid as id;
grant select on mk85c to authenticated;
select admin_makeup_confirm((select id from mk85c), ((current_date + 9) + time '12:00') at time zone 'Australia/Sydney');
select pg_temp.ok((select count(*) = 2 from lesson_notices n join notifications x on x.id = n.email_notification_id
                   where n.makeup_request_id = (select id from mk85c) and n.email_status = 'queued' and x.net_request_id is null and n.email_error like '메일 키%'),
  '메일: Resend 키가 없으면 큐에 남고 사유 기록 (오류로 확정이 막히지 않음)');
reset role;
insert into vault.decrypted_secrets values ('resend_api_key', 're_test_key');
set role authenticated;
create temp table dbg85c as select admin_mail_sync() as r;
select pg_temp.ok((select (r ->> 'tried')::int from dbg85c) = 2
              and (select count(*) = 2 from lesson_notices n join notifications x on x.id = n.email_notification_id where n.makeup_request_id = (select id from mk85c) and x.net_request_id is not null and n.email_error is null),
  '메일: 키를 넣은 뒤 상태 맞추기가 남은 큐를 보냄');
reset request.jwt.claim.sub;
reset role;

-- ---------- 강사 귀책 자동 연장 (migration 20261108020000, H26(90)·(92)·(93)) ----------
-- 가상 학생 '귀책학생' 월·수·금 20:00 4주, 강사 '귀책강사'. 시행일 = 어제
reset role;
update feature_flags set updated_at = now() - interval '1 day' where key = 'tutor_fault_extension_since';
create temp table fx (f0 date);
insert into fx select current_date + 30 + ((8 - extract(dow from current_date + 30)::int) % 7);   -- 월요일
grant select on fx to authenticated;
create or replace function pg_temp.fk(days int) returns timestamptz language sql as $$
  select ((select f0 from fx) + days + time '20:00') at time zone 'Asia/Seoul' $$;
create or replace function pg_temp.fend() returns date language sql as $$
  select final_end_date from enrollments where id = '99999999-1000-0000-0000-000000009200' $$;
create or replace function pg_temp.fd(days int) returns date language sql as $$ select (select f0 from fx) + days $$;
insert into tutors (id, name, country, timezone, meet_url) values ('55555555-0000-0000-0000-000000009200', '귀책강사', 'Korea', 'Asia/Seoul', 'https://meet.google.com/fff-gggg-hhh');
select pg_temp.open_all('55555555-0000-0000-0000-000000009200');
insert into students (id, name_ko, name_en) values ('99999999-0000-0000-0000-000000009200', '귀책학생', 'Fault S');
insert into enrollments (id, student_id, seq, weeks, weekly_count, duration_min, start_date, base_end_date, lessons_purchased, status)
select '99999999-1000-0000-0000-000000009200', '99999999-0000-0000-0000-000000009200', 1, 4, 3, 40, f0, f0 + 27, 12, 'active' from fx;
insert into regular_schedules (student_id, tutor_id, weekday, start_time_kst, duration_min, effective_from)
select '99999999-0000-0000-0000-000000009200', '55555555-0000-0000-0000-000000009200', w, '20:00', 40, f0 - 7 from fx, (values (1), (3), (5)) v(w);
insert into lessons (id, enrollment_id, student_id, tutor_id, kind, seq, starts_at, ends_at)
select ('77777777-9200-0000-0000-0000000000' || lpad(n::text, 2, '0'))::uuid, '99999999-1000-0000-0000-000000009200', '99999999-0000-0000-0000-000000009200',
       '55555555-0000-0000-0000-000000009200', 'regular', n, pg_temp.fk(n), pg_temp.fk(n) + interval '40 minutes'
from (values (0), (2), (4), (23), (25)) v(n);

select pg_temp.ok(pg_temp.fend() = pg_temp.fd(27), '귀책 연장: 사건 없으면 종료일 그대로 (수강권 기간)');
update lessons set state = 'done', class_status = 'Tutor no-show' where id = '77777777-9200-0000-0000-000000000000';
select pg_temp.ok(pg_temp.fend() = pg_temp.fd(28)
              and (select note like '%휴무 0 · 노쇼 1' from enrollment_extensions where enrollment_id = '99999999-1000-0000-0000-000000009200' and auto_source = 'fault'),
  '귀책 연장: 노쇼 1회 → 종료일 다음 정규 요일(월)까지 자동 연장, 사유 기록');
update lessons set state = 'canceled', canceled_at = now(), class_status = 'Tutor long-term leave' where id = '77777777-9200-0000-0000-000000000002';
select pg_temp.ok(pg_temp.fend() = pg_temp.fd(30), '귀책 연장: 휴무 1회 더 → 정규 요일 2번째(수)까지');
select pg_temp.ok((select lms_comp_use_until('99999999-1000-0000-0000-000000009200')) = pg_temp.fd(30), '귀책 연장: 무료 보상수업 기한도 같은 종료일 (H26(93))');
insert into lessons (id, enrollment_id, student_id, tutor_id, kind, starts_at, ends_at, makeup_of)
values ('77777777-9200-0000-0000-000000000100', '99999999-1000-0000-0000-000000009200', '99999999-0000-0000-0000-000000009200', '55555555-0000-0000-0000-000000009200',
        'makeup', pg_temp.fk(9), pg_temp.fk(9) + interval '40 minutes', '77777777-9200-0000-0000-000000000000');
select pg_temp.ok(pg_temp.fend() = pg_temp.fd(30), '귀책 연장: 노쇼 보강을 기간 안에 잡아도 종료일 그대로');
insert into lessons (id, enrollment_id, student_id, tutor_id, kind, starts_at, ends_at, makeup_of)
values ('77777777-9200-0000-0000-000000000101', '99999999-1000-0000-0000-000000009200', '99999999-0000-0000-0000-000000009200', '55555555-0000-0000-0000-000000009200',
        'makeup', pg_temp.fk(16), pg_temp.fk(16) + interval '40 minutes', '77777777-9200-0000-0000-000000000002');
update lessons set state = 'canceled', canceled_at = now(), voided_at = now(), voided_by = 'aaaaaaaa-0000-0000-0000-000000000001' where id = '77777777-9200-0000-0000-000000000101';
select pg_temp.ok(pg_temp.fend() = pg_temp.fd(30)
              and (select array_agg(days order by created_at) from enrollment_extensions where enrollment_id = '99999999-1000-0000-0000-000000009200') = '{1,2}',
  '귀책 연장: 보강을 일찍 끝내거나 없애도 종료일을 줄이지 않음 (자동 단축 없음)');
-- 다음 수강권(재등록)이 있으면 그 시작일 전날을 넘지 않음: 재등록 뒤 노쇼 1회 더
insert into enrollments (id, student_id, seq, weeks, weekly_count, duration_min, start_date, base_end_date, lessons_purchased, status, previous_enrollment_id)
select '99999999-1000-0000-0000-000000009201', '99999999-0000-0000-0000-000000009200', 2, 4, 3, 40, f0 + 31, f0 + 58, 12, 'confirmed', '99999999-1000-0000-0000-000000009200' from fx;
update lessons set state = 'done', class_status = 'Tutor no-show' where id = '77777777-9200-0000-0000-000000000023';
select pg_temp.ok(pg_temp.fend() = pg_temp.fd(30), '귀책 연장: 다음 수강권 시작일 전날까지만 (재등록 일정 그대로, 오류 없음)');
-- 시행 전 사건은 세지 않음
update feature_flags set updated_at = now() + interval '400 days' where key = 'tutor_fault_extension_since';
select pg_temp.ok(lms_fault_event('77777777-9200-0000-0000-000000000000') is null, '귀책 연장: 시행일 전 노쇼는 자동 연장 대상 아님 (기존 그대로)');
update feature_flags set updated_at = now() - interval '1 day' where key = 'tutor_fault_extension_since';

-- 종료 5일 이내 강사 취소 → [맞는 시간이 없어요] (H26(92) ⑤): 알린 날 = 종료일 3일 전 / 7일 전
update lessons set state = 'canceled', canceled_at = now(), class_status = 'Tutor canceled late' where id = '77777777-9200-0000-0000-000000000025';
insert into change_requests (lesson_id, student_id, tutor_id, type, status, via, requested_at, requested_by)
select '77777777-9200-0000-0000-000000000025', '99999999-0000-0000-0000-000000009200', '55555555-0000-0000-0000-000000009200', 'tutor_cancel', 'applied', 'admin_app',
       ((pg_temp.fend() - 3) + time '10:00') at time zone 'Asia/Seoul', 'aaaaaaaa-0000-0000-0000-000000000001';
update lessons set state = 'canceled', canceled_at = now(), class_status = 'Tutor canceled in advance' where id = '77777777-9200-0000-0000-000000000004';
insert into change_requests (lesson_id, student_id, tutor_id, type, status, via, requested_at, requested_by)
select '77777777-9200-0000-0000-000000000004', '99999999-0000-0000-0000-000000009200', '55555555-0000-0000-0000-000000009200', 'tutor_cancel', 'applied', 'admin_app',
       ((pg_temp.fend() - 7) + time '10:00') at time zone 'Asia/Seoul', 'aaaaaaaa-0000-0000-0000-000000000001';
set role authenticated;
set request.jwt.claim.sub = 'bbbbbbbb-0000-0000-0000-000000000009';   -- 대표 (aal2, 학생 화면 운영자 보기)
select pg_temp.ok((select jsonb_agg(x ->> 'lesson_id') from jsonb_array_elements(student_no_time_rights('99999999-0000-0000-0000-000000009200')) x)
                  = '["77777777-9200-0000-0000-000000000025"]'::jsonb,
  '맞는 시간이 없어요: 종료 5일 이내 강사 취소만 (7일 전 알린 취소는 안 보임)');
select pg_temp.expect_error($$select student_no_time_request('99999999-0000-0000-0000-000000009200', '77777777-9200-0000-0000-000000000004')$$, 'not_eligible|요청할 수 있는');
select student_no_time_request('99999999-0000-0000-0000-000000009200', '77777777-9200-0000-0000-000000000025');
select pg_temp.ok((student_no_time_request('99999999-0000-0000-0000-000000009200', '77777777-9200-0000-0000-000000000025') ->> 'repeated')::boolean
              and (select count(*) = 1 from jsonb_array_elements(admin_extension_reviews()) x where x ->> 'lesson_id' = '77777777-9200-0000-0000-000000000025'),
  '맞는 시간이 없어요: 누르면 운영진 예외 연장 검토 카드 1건 (다시 눌러도 1건)');
reset request.jwt.claim.sub;
reset role;
