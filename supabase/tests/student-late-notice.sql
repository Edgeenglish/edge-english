-- 학생 지각 알림 시험 (2026-11-13 대표 확정). 가짜 데이터만, 끝에 전부 되돌림(rollback) — 메일은 나가지 않음
begin;
create or replace function pg_temp.ok(c boolean, msg text) returns void language plpgsql as $$
begin if not coalesce(c, false) then raise exception '실패: %', msg; end if; raise notice '통과: %', msg; end $$;
create or replace function pg_temp.fails(sql text, msg text) returns void language plpgsql as $$
begin
  begin execute sql; exception when others then raise notice '통과: %', msg; return; end;
  raise exception '실패(막혀야 함): %', msg;
end $$;

insert into tutors (id, name, country, timezone, email) values
  ('aaaaaaaa-0000-4000-8000-0000000000a1', 'Emma', 'Philippines', 'Asia/Manila', 'emma@example.invalid');
insert into students (id, name_ko, name_en, timezone, email) values
  ('bbbbbbbb-0000-4000-8000-0000000000a1', '김하준', 'Hajun', 'Asia/Seoul', 'a@example.invalid'),
  ('bbbbbbbb-0000-4000-8000-0000000000a2', '박서연', 'Seoyeon', 'Asia/Seoul', 'b@example.invalid');
insert into enrollments (id, student_id, seq, contract_version, weeks, weekly_count, duration_min, start_date, base_end_date, lessons_purchased, status) values
  ('cccccccc-0000-4000-8000-0000000000a1', 'bbbbbbbb-0000-4000-8000-0000000000a1', 1, 'SC2', 4, 3, 40, current_date - 7, current_date + 20, 12, 'active'),
  ('cccccccc-0000-4000-8000-0000000000a2', 'bbbbbbbb-0000-4000-8000-0000000000a2', 1, 'SC2', 4, 3, 40, current_date - 7, current_date + 20, 12, 'active');
-- 하준: ① 1시간 뒤(보낼 수 있음) ② 3시간 뒤(아직 이름) ③ 진행 중 ④ 이미 끝남 ⑤ 취소된 수업 / 서연: ⑥ 1시간 뒤
insert into lessons (id, enrollment_id, student_id, tutor_id, kind, seq, starts_at, ends_at, state) values
  ('dddddddd-0000-4000-8000-0000000000a1', 'cccccccc-0000-4000-8000-0000000000a1', 'bbbbbbbb-0000-4000-8000-0000000000a1', 'aaaaaaaa-0000-4000-8000-0000000000a1', 'regular', 1, now() + interval '1 hour', now() + interval '1 hour 40 minutes', 'scheduled'),
  ('dddddddd-0000-4000-8000-0000000000a2', 'cccccccc-0000-4000-8000-0000000000a1', 'bbbbbbbb-0000-4000-8000-0000000000a1', 'aaaaaaaa-0000-4000-8000-0000000000a1', 'regular', 2, now() + interval '3 hours', now() + interval '3 hours 40 minutes', 'scheduled'),
  ('dddddddd-0000-4000-8000-0000000000a3', 'cccccccc-0000-4000-8000-0000000000a1', 'bbbbbbbb-0000-4000-8000-0000000000a1', 'aaaaaaaa-0000-4000-8000-0000000000a1', 'regular', 3, now() - interval '10 minutes', now() + interval '30 minutes', 'scheduled'),
  ('dddddddd-0000-4000-8000-0000000000a4', 'cccccccc-0000-4000-8000-0000000000a1', 'bbbbbbbb-0000-4000-8000-0000000000a1', 'aaaaaaaa-0000-4000-8000-0000000000a1', 'regular', 4, now() - interval '2 hours', now() - interval '80 minutes', 'scheduled'),
  ('dddddddd-0000-4000-8000-0000000000a6', 'cccccccc-0000-4000-8000-0000000000a2', 'bbbbbbbb-0000-4000-8000-0000000000a2', 'aaaaaaaa-0000-4000-8000-0000000000a1', 'regular', 1, now() + interval '105 minutes', now() + interval '145 minutes', 'scheduled');
insert into app_users (auth_user_id, role, student_id) values
  ('eeeeeeee-0000-4000-8000-0000000000a1', 'student', 'bbbbbbbb-0000-4000-8000-0000000000a1');
insert into app_users (auth_user_id, role, tutor_id) values
  ('eeeeeeee-0000-4000-8000-0000000000b1', 'tutor', 'aaaaaaaa-0000-4000-8000-0000000000a1');

select set_config('request.jwt.claims', '{"sub":"eeeeeeee-0000-4000-8000-0000000000a1","aal":"aal1"}', true);
set local role authenticated;

-- 막혀야 하는 것
select pg_temp.fails($$select student_late_notice(null, 'dddddddd-0000-4000-8000-0000000000a6', 10, null)$$, '다른 학생 수업은 못 알림');
select pg_temp.fails($$select student_late_notice(null, 'dddddddd-0000-4000-8000-0000000000a2', 10, null)$$, '시작 2시간보다 더 전이면 못 알림');
select pg_temp.fails($$select student_late_notice(null, 'dddddddd-0000-4000-8000-0000000000a4', 10, null)$$, '이미 끝난 수업은 못 알림');
select pg_temp.fails($$select student_late_notice(null, 'dddddddd-0000-4000-8000-0000000000a1', 7, null)$$, '5·10·15·20 말고 다른 분은 못 보냄');
select pg_temp.fails($$select student_late_notice(null, 'dddddddd-0000-4000-8000-0000000000a1', 10, 'boss')$$, '정해진 이유 말고는 못 보냄');
reset role;
select pg_temp.ok((select count(*) from student_late_notices) = 0 and (select count(*) from tutor_updates where tutor_id = 'aaaaaaaa-0000-4000-8000-0000000000a1') = 0, '막힌 것은 아무것도 안 남김');

-- 이유 없이 보내기 (수업 시작 1시간 전) → Updates 1줄 + 메일 1통
select set_config('request.jwt.claims', '{"sub":"eeeeeeee-0000-4000-8000-0000000000a1","aal":"aal1"}', true);
set local role authenticated;
select pg_temp.ok((student_late_notice(null, 'dddddddd-0000-4000-8000-0000000000a1', 20, null) ->> 'repeated') = 'false', '이유 없이 보냄');
select pg_temp.ok((student_late_notice(null, 'dddddddd-0000-4000-8000-0000000000a1', 5, 'traffic') ->> 'repeated') = 'true', '같은 수업 다시 보내면 repeated');
reset role;
select pg_temp.ok((select count(*) from student_late_notices) = 1 and (select minutes from student_late_notices) = 20 and (select reason from student_late_notices) is null, '처음 값 그대로 한 줄만');
select pg_temp.ok((select count(*) from tutor_updates where kind = 'student_late' and tutor_id = 'aaaaaaaa-0000-4000-8000-0000000000a1') = 1, 'Updates 1줄');
select pg_temp.ok((select visible_until from tutor_updates where kind = 'student_late' and tutor_id = 'aaaaaaaa-0000-4000-8000-0000000000a1') = (select ends_at from lessons where id = 'dddddddd-0000-4000-8000-0000000000a1'), 'Updates는 그 수업이 끝날 때까지');
select pg_temp.ok((select count(*) from notifications where dedupe_key = 'tutor_update:student_late:dddddddd-0000-4000-8000-0000000000a1') = 1, '강사 메일 1통');
select pg_temp.ok((select payload ->> 'subject' from notifications where dedupe_key like 'tutor_update:student_late:%') like '%Student Running Late – Hajun', '제목');
select pg_temp.ok((select payload ->> 'text' from notifications where dedupe_key like 'tutor_update:student_late:%') like
  E'Student Running Late – Hajun\n\nHajun has reported that they may be approximately 20 or more minutes late.\n\nPlease join the class on time and stay until the scheduled end time, as the student may arrive earlier than expected.%', '본문 (이유 없으면 Reason 줄 없음, 마지막 문장은 한 줄 띄움)');
select pg_temp.ok((select payload ->> 'html' from notifications where dedupe_key = 'tutor_update:student_late:dddddddd-0000-4000-8000-0000000000a1') like '%approximately <b>20 or more</b> minutes late.</p><p><b>Please join the class on time and stay until the scheduled end time, as the student may arrive earlier than expected.</b></p>%', 'HTML: 분은 굵게, 마지막 문장은 따로 문단 + 통째로 굵게');
select pg_temp.ok((select payload ->> 'text' from notifications where dedupe_key like 'tutor_update:student_late:%') not like '%remaining%' and (select payload ->> 'text' from notifications where dedupe_key like 'tutor_update:student_late:%') not like '%extend%', '남은 시간·연장 말 없음');

-- 이유 고르고 보내기 (진행 중인 수업 ③ — 끝나기 전까지 가능)
select set_config('request.jwt.claims', '{"sub":"eeeeeeee-0000-4000-8000-0000000000a1","aal":"aal1"}', true);
set local role authenticated;
select student_late_notice(null, 'dddddddd-0000-4000-8000-0000000000a3', 10, 'transit');
reset role;
select pg_temp.ok((select payload ->> 'text' from notifications where dedupe_key = 'tutor_update:student_late:dddddddd-0000-4000-8000-0000000000a3') like
  E'%approximately 10 minutes late.\nReason: Public transportation is delayed.\n\nPlease join the class on time%', '본문 (이유 줄, 마지막 문장과 한 줄 띄움)');

-- 읽기: 본인이 알린 것만
select set_config('request.jwt.claims', '{"sub":"eeeeeeee-0000-4000-8000-0000000000a1","aal":"aal1"}', true);
set local role authenticated;
select pg_temp.ok(jsonb_array_length(student_late_notices(null)) = 2, '학생 화면: 알린 수업 2개');
select pg_temp.ok((select (e ->> 'minutes')::int from jsonb_array_elements(student_late_notices(null)) e where e ->> 'lesson_id' = 'dddddddd-0000-4000-8000-0000000000a3') = 10, '학생 화면: 분 값');
reset role;

-- 강사 Updates 에 지각 줄 2개 (수업 시각 · 분 · 이유 그대로)
select set_config('request.jwt.claims', '{"sub":"eeeeeeee-0000-4000-8000-0000000000b1","aal":"aal1"}', true);
set local role authenticated;
select pg_temp.ok((select count(*) from jsonb_array_elements(tutor_updates_feed(null)) e where e ->> 'kind' = 'student_late') = 2, '강사 Updates: 지각 줄 2개');
select pg_temp.ok((select e -> 'info' ->> 'reason' from jsonb_array_elements(tutor_updates_feed(null)) e where e ->> 'kind' = 'student_late' and (e -> 'info' ->> 'minutes')::int = 10) = 'transit', '강사 Updates: 이유 값');
reset role;

-- 서연(다른 학생)은 아직 아무것도 안 알림
select pg_temp.ok((select count(*) from student_late_notices where student_id = 'bbbbbbbb-0000-4000-8000-0000000000a2') = 0, '다른 학생 기록 없음');
-- 수업 상태·시간·수강권은 그대로
select pg_temp.ok((select count(*) from lessons where enrollment_id::text like 'cccccccc-0000-4000-8000-0000000000a%' and state = 'scheduled' and voided_at is null) = 5, '수업 상태 그대로');
rollback;
