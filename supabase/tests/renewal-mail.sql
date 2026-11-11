-- 재등록 안내 자동 메일 3통 시험 (H26(117) ①). 가짜 데이터만, 끝에 전부 되돌림(rollback) — 메일은 나가지 않음
begin;
create or replace function pg_temp.ok(c boolean, msg text) returns void language plpgsql as $$
begin if not coalesce(c, false) then raise exception '실패: %', msg; end if; raise notice '통과: %', msg; end $$;

insert into tutors (id, name, country, timezone) values ('aaaaaaaa-0000-4000-8000-000000000001', 'RenewTutor', 'Korea', 'Asia/Seoul');
insert into students (id, name_ko, name_en, timezone, email) values
  ('bbbbbbbb-0000-4000-8000-000000000001', '김하준', 'Hajun', 'Asia/Seoul', 'a@example.invalid'),
  ('bbbbbbbb-0000-4000-8000-000000000002', '박서연', 'Seoyeon', 'Australia/Sydney', 'b@example.invalid');
-- 40분 주 3회 4주 (가격표에 있는 코스) / 40분 주 1회 (가격표에 없음)
insert into enrollments (id, student_id, seq, contract_version, weeks, weekly_count, duration_min, start_date, base_end_date, lessons_purchased, status) values
  ('cccccccc-0000-4000-8000-000000000001', 'bbbbbbbb-0000-4000-8000-000000000001', 1, 'SC2', 4, 3, 40, '2026-11-02', '2026-11-29', 12, 'active'),
  ('cccccccc-0000-4000-8000-000000000002', 'bbbbbbbb-0000-4000-8000-000000000002', 1, 'SC2', 4, 1, 40, '2026-11-02', '2026-11-29', 4, 'active');
-- 하준: 수업 4개 (11/16 11/18 11/20 11/23 오후 9시 KST = 12:00 UTC, 40분)
insert into lessons (enrollment_id, student_id, tutor_id, kind, seq, starts_at, ends_at)
select 'cccccccc-0000-4000-8000-000000000001', 'bbbbbbbb-0000-4000-8000-000000000001', 'aaaaaaaa-0000-4000-8000-000000000001', 'regular', row_number() over (order by d), d, d + interval '40 minutes'
from unnest(array['2026-11-16 12:00+00', '2026-11-18 12:00+00', '2026-11-20 12:00+00', '2026-11-23 12:00+00']::timestamptz[]) d;
-- 서연: 수업 2개 (11/16, 11/23)
insert into lessons (enrollment_id, student_id, tutor_id, kind, seq, starts_at, ends_at)
select 'cccccccc-0000-4000-8000-000000000002', 'bbbbbbbb-0000-4000-8000-000000000002', 'aaaaaaaa-0000-4000-8000-000000000001', 'regular', row_number() over (order by d), d, d + interval '40 minutes'
from unnest(array['2026-11-16 13:00+00', '2026-11-23 13:00+00']::timestamptz[]) d;

-- 가격표 (renewal-price.ts 와 같은 값)
select pg_temp.ok(lms_renewal_plans(40, 3) = '{"monthly":420000,"three":{"total":1197000,"per_month":399000,"save":63000},"six":{"total":2344000,"per_month":390667,"save":176000}}'::jsonb, '가격표 40분 주 3회');
select pg_temp.ok(lms_renewal_plans(40, 1) is null, '가격표에 없는 코스는 null');

-- 시작 스위치(renewal_mail_since)가 없으면 아무것도 안 보냄
select pg_temp.ok((lms_renewal_mail_run('2026-11-20 10:00+00') ->> 'sent')::int = 0, '스위치 없으면 0통');
insert into feature_flags (key, enabled, note) values ('renewal_mail_since', false, 'test') on conflict (key) do nothing;

-- 남은 수업 계산
select pg_temp.ok(lms_renewal_remaining('cccccccc-0000-4000-8000-000000000001', '2026-11-18 00:00+00') = 3, '11/18 0시: 하준 남은 3회');
select pg_temp.ok(lms_renewal_remaining('cccccccc-0000-4000-8000-000000000001', '2026-11-19 00:00+00') = 2, '11/19: 남은 2회');
select pg_temp.ok(lms_renewal_remaining('cccccccc-0000-4000-8000-000000000001', '2026-11-18 12:10+00') = 2, '수업 시작 뒤에는 그 수업을 안 셈 (대시보드와 같음)');

-- 11/18 0시: 3회 남음 → 대상 없음
select pg_temp.ok(not exists (select 1 from lms_renewal_mail_due('2026-11-18 00:00+00') where enrollment_id = 'cccccccc-0000-4000-8000-000000000001'), '3회 남음: 안 보냄');
-- 11/19: 2회 → ① (서연은 11/16 수업 뒤 1회 남음 → ②)
select pg_temp.ok((select stage from lms_renewal_mail_due('2026-11-19 00:00+00') where enrollment_id = 'cccccccc-0000-4000-8000-000000000001') = 'two', '2회 남음: ① two');
select pg_temp.ok((select stage from lms_renewal_mail_due('2026-11-19 00:00+00') where enrollment_id = 'cccccccc-0000-4000-8000-000000000002') = 'one', '1회 남음: ② one');
select lms_renewal_mail_run('2026-11-19 00:00+00');
select pg_temp.ok((select count(*) from notifications where dedupe_key like 'renewal_mail:cccccccc-%') = 2, '메일 2통 만들어짐');
select lms_renewal_mail_run('2026-11-19 00:10+00');
select pg_temp.ok((select count(*) from notifications where dedupe_key like 'renewal_mail:cccccccc-%') = 2, '10분 뒤 다시 돌려도 중복 없음');

-- 문구
select pg_temp.ok((select payload ->> 'subject' from notifications where dedupe_key = 'renewal_mail:cccccccc-0000-4000-8000-000000000001:two') = '[시험 · ' || (select code from students where id = 'bbbbbbbb-0000-4000-8000-000000000001') || '] [엣지영어] 수업이 2회 남았어요', '① 제목 (스위치 꺼짐 = 시험 발송)');
select pg_temp.ok((select email from notifications where dedupe_key = 'renewal_mail:cccccccc-0000-4000-8000-000000000001:two') = 'support@edgeenglish.kr', '스위치 꺼짐: support@ 로만');
select pg_temp.ok((select payload ->> 'text' from notifications where dedupe_key = 'renewal_mail:cccccccc-0000-4000-8000-000000000001:two') like '안녕하세요 김하준님☺️' || E'\n' || '엣지영어 수업이 2회 남았어요! (종료일: 11월 29일(일))%', '① 첫 줄·종료일(한국)');
select pg_temp.ok((select payload ->> 'text' from notifications where dedupe_key = 'renewal_mail:cccccccc-0000-4000-8000-000000000001:two') like '%현재 수강 코스: 40분 주 3회 (월 12회)%1,197,000원 (월 399,000원)%63,000원 절약!%2,344,000원 (월 약 390,667원)%176,000원 절약 + Ebook 패키지 무료!%카카오뱅크 3333-27-7626253%', '① 가격표 자동 입력');
select pg_temp.ok((select payload ->> 'text' from notifications where dedupe_key = 'renewal_mail:cccccccc-0000-4000-8000-000000000002:one') like '%수업이 1회 남았어요! (종료일: 11월 30일(월) 오전 1:59까지)%' and (select payload ->> 'text' from notifications where dedupe_key = 'renewal_mail:cccccccc-0000-4000-8000-000000000002:one') like '%모든 시간은 시드니 시간대 기준이에요.%', '② 첫 줄·해외 학생은 거주지 시간');
select pg_temp.ok((select payload ->> 'text' from notifications where dedupe_key = 'renewal_mail:cccccccc-0000-4000-8000-000000000002:one') not like '%현재 수강 코스%', '가격표에 없는 코스는 코스·가격 줄 없음');

-- 11/23 (마지막 수업 중): 하준 아직 안 끝남 → 보내지 않음
select pg_temp.ok(not exists (select 1 from lms_renewal_mail_due('2026-11-23 12:20+00') where stage = 'ended' and enrollment_id::text like 'cccccccc-%'), '마지막 수업 진행 중: ③ 안 보냄');
-- 마지막 수업이 끝난 직후, Class Record 기록 없이도 ③ (하준의 ②는 건너뜀: 11/20 수업 뒤 1회 남았던 때 안 돌렸으므로 지금은 ended 만)
select pg_temp.ok((select stage from lms_renewal_mail_due('2026-11-23 12:41+00') where enrollment_id = 'cccccccc-0000-4000-8000-000000000001') = 'ended', '마지막 수업 종료 뒤: ③ ended (기록 없어도)');
select lms_renewal_mail_run('2026-11-23 12:41+00');
select pg_temp.ok(exists (select 1 from notifications where dedupe_key = 'renewal_mail:cccccccc-0000-4000-8000-000000000001:ended'), '③ 만들어짐');
select pg_temp.ok((select payload ->> 'text' from notifications where dedupe_key = 'renewal_mail:cccccccc-0000-4000-8000-000000000001:ended') like '%엣지영어 수강기간 수업이 모두 끝났어요! (종료일: 11월 29일(일))%종료일까지 재등록 결제를 마치시면%', '③ 문구');
-- 뒤 단계가 나갔으면 앞 단계는 안 나감 (보강이 생겨 다시 2회가 돼도 ①을 또 보내지 않음)
select pg_temp.ok(not exists (select 1 from lms_renewal_mail_due('2026-11-23 13:00+00') where enrollment_id = 'cccccccc-0000-4000-8000-000000000001'), '③ 뒤에는 같은 수강권 더 안 보냄');

-- 날짜 미정 보강이 남으면 ③ 안 보냄 (서연: 11/23 수업을 '노쇼'로 → 보강 권리 1)
select set_config('app.actor_id', gen_random_uuid()::text, true), set_config('app.actor_via', 'renewal_mail_test', true);
update lessons set class_status = 'Tutor no-show', state = 'done' where enrollment_id = 'cccccccc-0000-4000-8000-000000000002' and seq = 2;
select pg_temp.ok(lms_renewal_remaining('cccccccc-0000-4000-8000-000000000002', '2026-11-24 00:00+00') = 1, '날짜 미정 보강(노쇼) 1회를 남은 수업으로 셈');
select pg_temp.ok(not exists (select 1 from lms_renewal_mail_due('2026-11-24 00:00+00') where enrollment_id = 'cccccccc-0000-4000-8000-000000000002' and stage = 'ended'), '날짜 미정 보강이 남으면 ③ 안 보냄');

-- 제외 대상: 문자 [보냄] · 재등록 결제 · 체험용 · 종료일 +3일 뒤
delete from notifications where dedupe_key like 'renewal_mail:cccccccc-%';
select pg_temp.ok(exists (select 1 from lms_renewal_mail_due('2026-11-19 00:00+00') where enrollment_id = 'cccccccc-0000-4000-8000-000000000001'), '제외 전: 대상');
insert into renewal_notices (enrollment_id) values ('cccccccc-0000-4000-8000-000000000001');
select pg_temp.ok(not exists (select 1 from lms_renewal_mail_due('2026-11-19 00:00+00') where enrollment_id = 'cccccccc-0000-4000-8000-000000000001'), '문자 [보냄] 한 수강권 제외');
update students set is_trial_account = true where id = 'bbbbbbbb-0000-4000-8000-000000000002';
select pg_temp.ok(not exists (select 1 from lms_renewal_mail_due('2026-11-19 00:00+00') where enrollment_id = 'cccccccc-0000-4000-8000-000000000002'), '체험용 계정 제외');
update students set is_trial_account = false where id = 'bbbbbbbb-0000-4000-8000-000000000002';
select pg_temp.ok(exists (select 1 from lms_renewal_mail_due('2026-11-19 00:00+00') where enrollment_id = 'cccccccc-0000-4000-8000-000000000002'), '체험용 해제 뒤 다시 대상');
insert into enrollments (student_id, seq, contract_version, weeks, weekly_count, duration_min, start_date, base_end_date, lessons_purchased, status, previous_enrollment_id)
values ('bbbbbbbb-0000-4000-8000-000000000002', 2, 'SC2', 4, 1, 40, '2026-12-02', '2026-12-29', 4, 'confirmed', 'cccccccc-0000-4000-8000-000000000002');
select pg_temp.ok(not exists (select 1 from lms_renewal_mail_due('2026-11-19 00:00+00') where enrollment_id = 'cccccccc-0000-4000-8000-000000000002'), '재등록 결제된 수강권 제외');
select pg_temp.ok(not exists (select 1 from lms_renewal_mail_due('2026-12-02 00:00+00') where enrollment_id::text like 'cccccccc-%'), '종료일 +3일 뒤 제외');
rollback;
