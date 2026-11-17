-- 재등록 누락 확인 메일(운영진만, 대표 11/16 2번 설계) 시험. 가짜 데이터만, 끝에 전부 되돌림 — 메일은 나가지 않음
begin;
create or replace function pg_temp.ok(c boolean, msg text) returns void language plpgsql as $$
begin if not coalesce(c, false) then raise exception '실패: %', msg; end if; raise notice '통과: %', msg; end $$;

insert into tutors (id, name, country, timezone) values ('aaaaaaaa-0000-4000-8000-0000000000a1', 'MissTutor', 'Korea', 'Asia/Seoul');
insert into students (id, name_ko, name_en, timezone, email) values
  ('bbbbbbbb-0000-4000-8000-0000000000a1', '김하준', 'Hajun', 'Asia/Seoul', 'a@example.invalid'),
  ('bbbbbbbb-0000-4000-8000-0000000000a2', '박서연', 'Seoyeon', 'Asia/Seoul', 'b@example.invalid');
-- 하준: 종료 11/12(목) · 서연: 종료 11/15(일). 둘 다 정규 월·목 17:00 KST 40분
insert into enrollments (id, student_id, seq, contract_version, weeks, weekly_count, duration_min, start_date, base_end_date, lessons_purchased, status) values
  ('cccccccc-0000-4000-8000-0000000000a1', 'bbbbbbbb-0000-4000-8000-0000000000a1', 1, 'SC2', 4, 2, 40, '2026-10-16', '2026-11-12', 8, 'active'),
  ('cccccccc-0000-4000-8000-0000000000a2', 'bbbbbbbb-0000-4000-8000-0000000000a2', 1, 'SC2', 4, 2, 40, '2026-10-19', '2026-11-15', 8, 'active');
insert into regular_schedules (student_id, tutor_id, weekday, start_time_kst, duration_min, effective_from)
select s, 'aaaaaaaa-0000-4000-8000-0000000000a1', w, '17:00', 40, '2026-10-01'
from unnest(array['bbbbbbbb-0000-4000-8000-0000000000a1', 'bbbbbbbb-0000-4000-8000-0000000000a2']::uuid[]) s, unnest(array[1, 4]) w;
-- 첫 정규 수업 = 11/16(월) 17:00 KST = 08:00 UTC
select pg_temp.ok(not exists (select 1 from lms_renewal_missing_due('2026-11-15 07:00+00')), '수업 25시간 전: 안 보냄');
select pg_temp.ok((select count(*) from lms_renewal_missing_due('2026-11-15 09:00+00') where stage = 'h24') = 2, '23시간 전: 24시간 전 메일 대상 2명');
select pg_temp.ok(exists (select 1 from lms_renewal_missing_due('2026-11-15 09:00+00') where enrollment_id = 'cccccccc-0000-4000-8000-0000000000a2'), '종료일(11/15) 안 지났어도 첫 정규 수업이 종료일 뒤면 대상');
select pg_temp.ok((select starts_at from lms_renewal_missing_due('2026-11-15 09:00+00') where enrollment_id = 'cccccccc-0000-4000-8000-0000000000a1') = '2026-11-16 08:00+00', '첫 정규 수업 시각 11/16 17:00 KST');
select lms_renewal_missing_run('2026-11-15 09:00+00');
select pg_temp.ok((select count(*) from notifications where dedupe_key like 'renewal_missing:cccccccc-%') = 2, '메일 2통 만들어짐');
select lms_renewal_missing_run('2026-11-15 09:10+00');
select pg_temp.ok((select count(*) from notifications where dedupe_key like 'renewal_missing:cccccccc-%') = 2, '10분 뒤 다시 돌려도 중복 없음');
select pg_temp.ok((select recipient_kind = 'admin' and email = 'support@edgeenglish.kr' from notifications where dedupe_key = 'renewal_missing:cccccccc-0000-4000-8000-0000000000a1:h24'), '받는 사람 support@ (운영진)');
select pg_temp.ok((select payload ->> 'subject' from notifications where dedupe_key = 'renewal_missing:cccccccc-0000-4000-8000-0000000000a1:h24')
  = '[시험 · ' || (select code from students where id = 'bbbbbbbb-0000-4000-8000-0000000000a1') || '] [재등록 누락 확인] 김하준 (' || (select code from students where id = 'bbbbbbbb-0000-4000-8000-0000000000a1') || ') · 11/16(월) 오후 5:00 한국 시간 정규 수업', '24시간 전 제목');
select pg_temp.ok((select payload ->> 'text' from notifications where dedupe_key = 'renewal_missing:cccccccc-0000-4000-8000-0000000000a1:h24')
  = '학생: 김하준 (' || (select code from students where id = 'bbbbbbbb-0000-4000-8000-0000000000a1') || ')' || E'\n' || '수강 종료일: 11/12(목)' || E'\n' || '다음 수강권: 없음' || E'\n'
    || '다음 정규 수업: 11/16(월) 오후 5:00 한국 시간 · 40분 · MissTutor' || E'\n' || '재등록 등록 또는 수강 종료 처리를 해 주세요.', '본문');
select pg_temp.ok(not exists (select 1 from notifications where dedupe_key like 'renewal_missing:%' and recipient_kind <> 'admin'), '학생·강사 메일 없음');
-- 12시간 전
select pg_temp.ok((select count(*) from lms_renewal_missing_due('2026-11-15 21:00+00') where stage = 'h12') = 2, '11시간 전: 12시간 전 메일 대상');
select lms_renewal_missing_run('2026-11-15 21:00+00');
select pg_temp.ok((select payload ->> 'subject' from notifications where dedupe_key = 'renewal_missing:cccccccc-0000-4000-8000-0000000000a1:h12') like '%[재등록 누락 확인 · 2번째] 김하준%', '12시간 전 제목 2번째');
select pg_temp.ok((select count(*) from notifications where dedupe_key like 'renewal_missing:cccccccc-%') = 4, '모두 4통 (2명 × 2통)');
-- 첫 정규 수업이 지나면 다음 수업(11/19 목)에는 안 보냄
select pg_temp.ok(not exists (select 1 from lms_renewal_missing_due('2026-11-18 09:00+00')), '첫 수업 지난 뒤 다음 정규 수업: 안 보냄');
-- 제외 조건 (메일 지우고 다시 확인)
delete from notifications where dedupe_key like 'renewal_missing:cccccccc-%';
select pg_temp.ok(exists (select 1 from lms_renewal_missing_due('2026-11-15 09:00+00') where enrollment_id = 'cccccccc-0000-4000-8000-0000000000a1'), '제외 전: 대상');
update students set is_trial_account = true where id = 'bbbbbbbb-0000-4000-8000-0000000000a1';
select pg_temp.ok(not exists (select 1 from lms_renewal_missing_due('2026-11-15 09:00+00') where student_id = 'bbbbbbbb-0000-4000-8000-0000000000a1'), '체험용 계정 제외');
update students set is_trial_account = false where id = 'bbbbbbbb-0000-4000-8000-0000000000a1';
update enrollments set status = 'completed' where id = 'cccccccc-0000-4000-8000-0000000000a1';
select pg_temp.ok(not exists (select 1 from lms_renewal_missing_due('2026-11-15 09:00+00') where student_id = 'bbbbbbbb-0000-4000-8000-0000000000a1'), '수강 종료 처리 제외');
update enrollments set status = 'active' where id = 'cccccccc-0000-4000-8000-0000000000a1';
insert into enrollments (student_id, seq, contract_version, weeks, weekly_count, duration_min, start_date, base_end_date, lessons_purchased, status, previous_enrollment_id)
values ('bbbbbbbb-0000-4000-8000-0000000000a1', 2, 'SC2', 4, 2, 40, '2026-11-16', '2026-12-13', 8, 'confirmed', 'cccccccc-0000-4000-8000-0000000000a1');
select pg_temp.ok(not exists (select 1 from lms_renewal_missing_due('2026-11-15 09:00+00') where student_id = 'bbbbbbbb-0000-4000-8000-0000000000a1'), '다음 수강권 있으면 제외');
insert into lessons (enrollment_id, student_id, tutor_id, kind, seq, starts_at, ends_at)
values ('cccccccc-0000-4000-8000-0000000000a2', 'bbbbbbbb-0000-4000-8000-0000000000a2', 'aaaaaaaa-0000-4000-8000-0000000000a1', 'regular', 9, '2026-11-16 08:00+00', '2026-11-16 08:40+00');
select pg_temp.ok(not exists (select 1 from lms_renewal_missing_due('2026-11-15 09:00+00') where student_id = 'bbbbbbbb-0000-4000-8000-0000000000a2'), '그 시각에 예정 수업 있으면 제외');
rollback;
