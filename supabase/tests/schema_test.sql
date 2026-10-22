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
insert into credit_ledger (period_id, lesson_id, reason, delta)
values ('66666666-6666-6666-6666-666666666666', '77777777-7777-7777-7777-777777777771', 'student_change', -1);
select pg_temp.expect_error($$insert into credit_ledger (period_id, lesson_id, reason, delta)
  values ('66666666-6666-6666-6666-666666666666', '77777777-7777-7777-7777-777777777771', 'student_change', -1)$$, 'unique|23505');
select pg_temp.ok(credit_balance('66666666-6666-6666-6666-666666666666') = 1, '같은 수업 변경권 두 번 차감 거부, 남은 1개');

insert into lessons (id, enrollment_id, student_id, tutor_id, kind, seq, starts_at, ends_at, state, canceled_at, class_status)
values ('77777777-7777-7777-7777-777777777773', '55555555-5555-5555-5555-555555555555', '33333333-3333-3333-3333-333333333333',
        '11111111-1111-1111-1111-111111111111', 'regular', 2, '2026-11-05 08:00+00', '2026-11-05 08:50+00',
        'canceled', now(), 'Student canceled in advance');
insert into lessons (id, enrollment_id, student_id, tutor_id, kind, seq, starts_at, ends_at, state, canceled_at, class_status)
values ('77777777-7777-7777-7777-777777777774', '55555555-5555-5555-5555-555555555555', '33333333-3333-3333-3333-333333333333',
        '11111111-1111-1111-1111-111111111111', 'regular', 3, '2026-11-10 08:00+00', '2026-11-10 08:50+00',
        'canceled', now(), 'Student canceled in advance');
insert into credit_ledger (period_id, lesson_id, reason, delta)
values ('66666666-6666-6666-6666-666666666666', '77777777-7777-7777-7777-777777777773', 'student_change', -1);
select pg_temp.expect_error($$insert into credit_ledger (period_id, lesson_id, reason, delta)
  values ('66666666-6666-6666-6666-666666666666', '77777777-7777-7777-7777-777777777774', 'student_change', -1)$$, '남아 있지 않습니다');
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
insert into reward_ledger (student_id, kind, amount, lesson_id) values ('99999999-0000-0000-0000-000000000001', 'grant_tutor_late_cancel', 2000, '99999999-3000-0000-0000-000000000001');
select pg_temp.expect_error($$insert into reward_ledger (student_id, kind, amount, lesson_id) values ('99999999-0000-0000-0000-000000000001', 'grant_tutor_late_cancel', 2000, '99999999-3000-0000-0000-000000000001')$$, 'unique|23505');
select pg_temp.ok(true, '같은 강사 늦은 취소 수업에 적립금 중복 지급 불가');
select pg_temp.expect_error($$insert into reward_ledger (student_id, kind, amount, lesson_id) values ('99999999-0000-0000-0000-000000000001', 'grant_tutor_late_cancel', 2000, '99999999-3000-0000-0000-000000000002')$$, '6시간 미만');
select pg_temp.ok(true, '6시간 이상 전 강사 취소에는 적립금 없음 (보강만)');
insert into reward_ledger (student_id, kind, amount, lesson_id) values ('99999999-0000-0000-0000-000000000002', 'grant_tutor_late_cancel', 2000, '99999999-3000-0000-0000-000000000003');
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

-- 11/3 예시와 같은 상황: 4/6(화) 20:00 에만 보강이 있음
insert into lessons (enrollment_id, student_id, tutor_id, kind, makeup_of, starts_at, ends_at)
select l.enrollment_id, l.student_id, l.tutor_id, 'makeup', l.id, '2027-04-06 20:00+09', '2027-04-06 20:50+09'
from lessons l join students s on s.id = l.student_id where s.email = 'one@x.kr' and l.seq = 1;
insert into tutor_time_off (tutor_id, starts_at, ends_at, kind) values ('55555555-0000-0000-0000-000000000900', '2027-05-04 17:00+09', '2027-05-04 19:00+09', 'block');
set role authenticated;
select pg_temp.ok((select jsonb_agg(c ->> 'date' || ' ' || (c ->> 'reason')) from jsonb_array_elements(
  pg_temp.reg_conflicts('90000000-0000-0000-0000-000000000004',
    pg_temp.body('보강충돌', 'mk@x.kr', 4, 1, 50, '2027-04-06', '55555555-0000-0000-0000-000000000900', '[{"weekday":2,"time":"20:00"}]', true))) c)
  = '["2027-04-06 tutor_makeup"]'::jsonb,
  '첫 수업일이 보강 날(4/6)이면 그날 하나만 충돌로 알려 줌');
reset role;
select pg_temp.ok(not exists (select 1 from students where email = 'mk@x.kr') and not exists (select 1 from registration_requests where id = '90000000-0000-0000-0000-000000000004'),
  '충돌이 있으면 학생·수강권·결제·수업 아무것도 저장 안 됨');
set role authenticated;
select pg_temp.ok((pg_temp.reg('90000000-0000-0000-0000-000000000005',
  pg_temp.body('보강다음주', 'mk2@x.kr', 4, 1, 50, '2027-04-13', '55555555-0000-0000-0000-000000000900', '[{"weekday":2,"time":"20:00"}]', true)) ->> 'lessons')::int = 4,
  '같은 화 20:00 이라도 보강 다음 주(4/13)부터는 등록 가능 — 보강이 정규 시간을 영구히 막지 않음');
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
    'from_date', '2027-08-02', 'end_date', '2027-08-29', 'makeups', makeups)
$$;

set role authenticated;
set request.jwt.claim.sub = 'bbbbbbbb-0000-0000-0000-000000000009';   -- 대표 (aal2)
-- 먼저 들어간 기존 학생 A: 화 19:00 (+ 8/12(목) 21:00 이관 보강, 같은 강사)
select pg_temp.ok((select (r ->> 'lessons')::int = 4 and (r ->> 'makeups')::int = 1
                   from pg_temp.imp('90000000-0000-0000-0000-000000001301',
                     pg_temp.ibody('이관A', '[{"weekday":2,"time":"19:00"}]', '[{"date":"2027-08-12","time":"21:00","duration_min":50,"tutor_id":"55555555-0000-0000-0000-000000001300"}]')) r),
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
                     '[{"date":"2027-08-18","time":"15:00","duration_min":20,"tutor_id":"55555555-0000-0000-0000-000000001300"}]'))) x),
  '강사 휴무 날의 정규·보강 모두 휴무 충돌로 거절');

-- 이번 입력끼리: 보강을 자기 정규 수업 시간에 넣으면 거절 (다른 강사여도 학생 시간이 겹치면)
select pg_temp.ok((select bool_or(x ->> 'reason' = 'self') from jsonb_array_elements(pg_temp.imp_conflicts(pg_temp.ibody('자기', '[{"weekday":1,"time":"10:00"}]',
                     '[{"date":"2027-08-09","time":"10:20","duration_min":20,"tutor_id":"55555555-0000-0000-0000-000000001301"}]'))) x),
  '보강이 이 학생 정규 수업과 겹치면 거절');

-- 입력 확인
select pg_temp.expect_error($$select pg_temp.imp(gen_random_uuid()::text, pg_temp.ibody('지난보강', '[{"weekday":1,"time":"08:00"}]',
  '[{"date":"2027-07-30","time":"15:00","duration_min":20,"tutor_id":"55555555-0000-0000-0000-000000001300"}]'))$$, '지난 보강');
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
