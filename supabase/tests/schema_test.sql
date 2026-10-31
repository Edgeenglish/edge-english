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

-- ---------- 보상 수업 7일 기한 ----------
insert into lessons (id, enrollment_id, student_id, tutor_id, kind, seq, starts_at, ends_at, state, class_status)
values ('99999999-3000-0000-0000-000000000004', '99999999-1000-0000-0000-000000000001', '99999999-0000-0000-0000-000000000001',
        '22222222-2222-2222-2222-222222222222', 'regular', 3, '2026-11-09 11:00+00', '2026-11-09 11:50+00', 'done', 'Tutor no-show');
insert into compensations (student_id, enrollment_id, source_lesson_id, reason, confirmed_by, created_at)
values ('99999999-0000-0000-0000-000000000001', '99999999-1000-0000-0000-000000000001', '99999999-3000-0000-0000-000000000004',
        'tutor_no_show', 'aaaaaaaa-0000-0000-0000-000000000001', '2026-11-09 15:30+00');
select pg_temp.ok((select expires_on from compensations where source_lesson_id = '99999999-3000-0000-0000-000000000004') = '2026-11-17',
                  '보상 수업 기한 = 지급일(KST 11/10) + 7일 (정책 원본 적용 등록)');

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
insert into tutors (id, name, country, timezone) values ('55555555-0000-0000-0000-000000001700', 'TestTutorChange', 'Korea', 'Asia/Seoul');
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
select pg_temp.expect_error($$select pg_temp.chg(gen_random_uuid()::text, 2, 'student', null, true)$$, '요청 받은 시각');
select pg_temp.ok(true, '요청 시각이 없거나 미래면 거절');
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
select pg_temp.expect_error($$select admin_makeup_confirm((select id from mk), (select t from cx) + interval '4 days')$$, '강사 휴무');
select pg_temp.ok(true, '강사 휴무와 겹치는 보강 시간은 확정 거절');
select admin_makeup_confirm((select id from mk), (select t from cx) + interval '7 days 2 hours');
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
insert into tutors (id, name, country, timezone) values
  ('55555555-0000-0000-0000-00000000180a', '휴무A', 'Korea', 'Asia/Seoul'),
  ('55555555-0000-0000-0000-00000000180b', '휴무B', 'Korea', 'Asia/Seoul'),
  ('55555555-0000-0000-0000-00000000180c', '휴무C', 'Korea', 'Asia/Seoul');
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
select pg_temp.ok((select final_end_date = (select d0 + 20 from lv) from enrollments where id = '99999999-1000-0000-0000-000000001800')
              and (select array_agg(days order by created_at, days) from enrollment_extensions where enrollment_id = '99999999-1000-0000-0000-000000001800') = '{3,-3}',
  '그 보강을 없애면 연장도 원래대로 (지우지 않고 -3 줄 추가)');
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
select pg_temp.expect_error($$select tutor_record_class('77777777-2000-0000-0000-000000000004', 'late', 'x', null)$$, 'reason for being late');
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
  jsonb_build_array(jsonb_build_object('starts_at', (select t from rc) + interval '2 days'), jsonb_build_object('starts_at', (select t from rc) + interval '3 days')), now())
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
select admin_makeup_confirm((select id from mk20), (select t from rc) + interval '2 days');
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
insert into tutors (id, name, country, timezone) values ('55555555-0000-0000-0000-000000002300', '붙임T', 'Korea', 'Asia/Seoul');
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
create temp table bq as select 1 as n, pg_temp.mreq(1, interval '2 hours 20 minutes') as id   -- A 수업 바로 뒤 (휴식 0분)
union all select 2, pg_temp.mreq(2, interval '1 day 2 hours 40 minutes')                        -- 이미 쉬지 않고 2개인 A 수업 바로 뒤
union all select 3, pg_temp.mreq(3, interval '3 days 2 hours 20 minutes')                        -- 다른 학생 B 수업 바로 뒤
union all select 4, pg_temp.mreq(4, interval '6 days')                                            -- 강사가 다른 시간을 말하는 경우
union all select 5, pg_temp.mreq(5, interval '4 days 2 hours 40 minutes')                        -- 40분 C 수업 바로 뒤
union all select 6, pg_temp.mreq(6, interval '4 days 2 hours 50 minutes');                       -- 40분 C 수업 뒤 10분 쉬고
select pg_temp.ok((select array_agg(pg_temp.busy(id) order by n) from bq) = '{f,t,t,f,t,f}',
  'back to back 강사 화면: 같은 학생 20분 바로 뒤는 가능 표시, 쉬지 않고 3개·다른 학생 바로 뒤·40분 바로 뒤는 이미 수업 있음');
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
select pg_temp.ok((select j -> 'times' ->> 0 = '04:00' and j -> 'times' ->> -1 = '20:30' and j ->> 'from' = (select nxt::text from hm) from hr),
  'My hours: 칸은 강사 현지 시각, 한국 06:00~22:30 시작 = 호찌민 04:00~20:30, 매주 변경은 다음 주 월요일부터');
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
