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
insert into enrollments (id, student_id, seq, weeks, weekly_count, duration_min, start_date, base_end_date, lessons_purchased, status)
values ('55555555-5555-5555-5555-555555555555', '33333333-3333-3333-3333-333333333333', 1, 4, 2, 50,
        '2026-11-03', '2026-11-30', 8, 'active');
insert into enrollment_periods (id, enrollment_id, idx, start_date, end_date, credits_granted)
values ('66666666-6666-6666-6666-666666666666', '55555555-5555-5555-5555-555555555555', 1, '2026-11-03', '2026-11-30', 2);

select pg_temp.expect_error($$insert into enrollments (student_id, seq, weeks, weekly_count, duration_min, start_date, base_end_date, lessons_purchased)
  values ('33333333-3333-3333-3333-333333333333', 2, 4, 2, 50, '2026-11-03', '2026-11-29', 8)$$, 'check');
select pg_temp.ok(true, '종료일 = 시작일 + 27 이 아니면 거부');

select pg_temp.expect_error($$insert into enrollments (student_id, seq, weeks, weekly_count, duration_min, start_date, base_end_date, lessons_purchased)
  values ('33333333-3333-3333-3333-333333333333', 2, 4, 2, 50, '2026-11-20', '2026-12-17', 8)$$, 'exclusion|23P01');
select pg_temp.ok(true, '같은 학생 수강기간 겹침 거부');

-- ---------- 수업 겹침 방지 ----------
insert into lessons (id, enrollment_id, student_id, tutor_id, kind, seq, starts_at, ends_at)
values ('77777777-7777-7777-7777-777777777771', '55555555-5555-5555-5555-555555555555', '33333333-3333-3333-3333-333333333333',
        '11111111-1111-1111-1111-111111111111', 'regular', 1, '2026-11-03 08:00+00', '2026-11-03 08:50+00');

select pg_temp.ok((select kst_date from lessons where seq = 1) = '2026-11-03', 'kst_date = 한국 날짜');

-- 같은 강사, 겹치는 시간 → 거부 (다른 학생이라도)
insert into enrollments (id, student_id, seq, weeks, weekly_count, duration_min, start_date, base_end_date, lessons_purchased, status)
values ('55555555-5555-5555-5555-555555555556', '44444444-4444-4444-4444-444444444444', 1, 4, 1, 50,
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

-- ---------- 접근 권한 (RLS) ----------
insert into app_users (auth_user_id, role, student_id) values
  ('bbbbbbbb-0000-0000-0000-000000000001', 'student', '33333333-3333-3333-3333-333333333333'),
  ('bbbbbbbb-0000-0000-0000-000000000002', 'student', '44444444-4444-4444-4444-444444444444');
insert into app_users (auth_user_id, role, tutor_id) values
  ('bbbbbbbb-0000-0000-0000-000000000003', 'tutor', '22222222-2222-2222-2222-222222222222'),
  ('bbbbbbbb-0000-0000-0000-000000000004', 'tutor', '11111111-1111-1111-1111-111111111111');
insert into app_users (auth_user_id, role) values ('bbbbbbbb-0000-0000-0000-000000000009', 'admin');

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
select pg_temp.ok((select count(*) from students) = 2 and (select count(*) from audit_log) > 0, '운영자는 전체를 봄');

reset request.jwt.claim.sub;
select pg_temp.ok((select count(*) from students) = 0, '로그인 안 한 요청은 아무것도 못 봄');
reset role;

set role anon;
select pg_temp.expect_error($$select * from students$$, 'permission|42501');
select pg_temp.ok(true, '비로그인(anon) 역할은 표 접근 자체가 막힘');
reset role;
