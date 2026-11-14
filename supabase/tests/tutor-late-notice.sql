-- 강사 '늦어요' 알림 시험 (대표 11/14 확정). 가짜 데이터만, 끝에 전부 되돌림(rollback) — 메일은 나가지 않음
begin;
create or replace function pg_temp.ok(c boolean, msg text) returns void language plpgsql as $$
begin if not coalesce(c, false) then raise exception '실패: %', msg; end if; raise notice '통과: %', msg; end $$;
create or replace function pg_temp.fails(sql text, msg text) returns void language plpgsql as $$
begin
  begin execute sql; exception when others then raise notice '통과: %', msg; return; end;
  raise exception '실패(막혀야 함): %', msg;
end $$;

insert into tutors (id, name, country, timezone, email) values
  ('aaaaaaaa-0000-4000-8000-0000000000c1', 'Emma', 'Philippines', 'Asia/Manila', 'emma@example.invalid'),
  ('aaaaaaaa-0000-4000-8000-0000000000c2', 'James', 'Philippines', 'Asia/Manila', 'james@example.invalid');
insert into students (id, code, name_ko, name_en, timezone, email) values
  ('bbbbbbbb-0000-4000-8000-0000000000c1', 'STU-9301', '김하준', 'Hajun', 'Asia/Seoul', 'a@example.invalid'),
  ('bbbbbbbb-0000-4000-8000-0000000000c2', 'STU-9302', '박서연', 'Seoyeon', 'Australia/Sydney', 'b@example.invalid');
insert into enrollments (id, student_id, seq, contract_version, weeks, weekly_count, duration_min, start_date, base_end_date, lessons_purchased, status) values
  ('cccccccc-0000-4000-8000-0000000000c1', 'bbbbbbbb-0000-4000-8000-0000000000c1', 1, 'SC2', 4, 3, 50, current_date - 7, current_date + 20, 12, 'active'),
  ('cccccccc-0000-4000-8000-0000000000c2', 'bbbbbbbb-0000-4000-8000-0000000000c2', 1, 'SC2', 4, 3, 50, current_date - 7, current_date + 20, 12, 'active');
-- Emma: ① 하준 1시간 뒤(보낼 수 있음) ② 하준 3시간 뒤(아직 이름) ③ 하준 진행 중(시작 지남) ④ 서연 115분 뒤 / James: ⑤ 서연 1시간 뒤
insert into lessons (id, enrollment_id, student_id, tutor_id, kind, seq, starts_at, ends_at, state) values
  ('dddddddd-0000-4000-8000-0000000000c1', 'cccccccc-0000-4000-8000-0000000000c1', 'bbbbbbbb-0000-4000-8000-0000000000c1', 'aaaaaaaa-0000-4000-8000-0000000000c1', 'regular', 1, now() + interval '1 hour', now() + interval '110 minutes', 'scheduled'),
  ('dddddddd-0000-4000-8000-0000000000c2', 'cccccccc-0000-4000-8000-0000000000c1', 'bbbbbbbb-0000-4000-8000-0000000000c1', 'aaaaaaaa-0000-4000-8000-0000000000c1', 'regular', 2, now() + interval '3 hours', now() + interval '230 minutes', 'scheduled'),
  ('dddddddd-0000-4000-8000-0000000000c3', 'cccccccc-0000-4000-8000-0000000000c1', 'bbbbbbbb-0000-4000-8000-0000000000c1', 'aaaaaaaa-0000-4000-8000-0000000000c1', 'regular', 3, now() - interval '5 minutes', now() + interval '45 minutes', 'scheduled'),
  ('dddddddd-0000-4000-8000-0000000000c4', 'cccccccc-0000-4000-8000-0000000000c2', 'bbbbbbbb-0000-4000-8000-0000000000c2', 'aaaaaaaa-0000-4000-8000-0000000000c1', 'regular', 1, now() + interval '115 minutes', now() + interval '165 minutes', 'scheduled'),
  ('dddddddd-0000-4000-8000-0000000000c5', 'cccccccc-0000-4000-8000-0000000000c2', 'bbbbbbbb-0000-4000-8000-0000000000c2', 'aaaaaaaa-0000-4000-8000-0000000000c2', 'regular', 2, now() + interval '1 hour', now() + interval '110 minutes', 'scheduled');
insert into app_users (auth_user_id, role, tutor_id) values
  ('eeeeeeee-0000-4000-8000-0000000000c1', 'tutor', 'aaaaaaaa-0000-4000-8000-0000000000c1');
insert into app_users (auth_user_id, role, student_id) values
  ('eeeeeeee-0000-4000-8000-0000000000c3', 'student', 'bbbbbbbb-0000-4000-8000-0000000000c1');
insert into app_users (auth_user_id, role, admin_level) values ('eeeeeeee-0000-4000-8000-0000000000c9', 'admin', 'owner');

-- 막혀야 하는 것 (Emma 로그인)
select set_config('request.jwt.claims', '{"sub":"eeeeeeee-0000-4000-8000-0000000000c1","aal":"aal1"}', true);
set local role authenticated;
select pg_temp.fails($$select tutor_late_notice('dddddddd-0000-4000-8000-0000000000c5', 10, null)$$, '다른 강사 수업은 못 보냄');
select pg_temp.fails($$select tutor_late_notice('dddddddd-0000-4000-8000-0000000000c2', 10, null)$$, '시작 2시간보다 더 전이면 못 보냄');
select pg_temp.fails($$select tutor_late_notice('dddddddd-0000-4000-8000-0000000000c3', 10, null)$$, '시작한 뒤에는 못 보냄');
select pg_temp.fails($$select tutor_late_notice('dddddddd-0000-4000-8000-0000000000c1', 7, null)$$, '5·10·15·20 말고 다른 분은 못 보냄');
select pg_temp.fails($$select tutor_late_notice('dddddddd-0000-4000-8000-0000000000c1', 10, 'traffic')$$, '정해진 이유 말고는 못 보냄');
select pg_temp.fails($$select tutor_late_notice('dddddddd-0000-4000-8000-0000000000c5', 10, null, 'aaaaaaaa-0000-4000-8000-0000000000c2')$$, '강사는 다른 강사 대신 못 보냄');
reset role;
select pg_temp.ok((select count(*) from tutor_late_notices) = 0 and (select count(*) from notifications where dedupe_key like 'tutor_late_%') = 0, '막힌 것은 아무것도 안 남김');

-- 이유 고르고 보내기 (한국 학생, 10분)
select set_config('request.jwt.claims', '{"sub":"eeeeeeee-0000-4000-8000-0000000000c1","aal":"aal1"}', true);
set local role authenticated;
select pg_temp.ok((tutor_late_notice('dddddddd-0000-4000-8000-0000000000c1', 10, 'internet') ->> 'repeated') = 'false', '보냄');
select pg_temp.ok((tutor_late_notice('dddddddd-0000-4000-8000-0000000000c1', 20, null) ->> 'repeated') = 'true', '같은 수업 다시 보내면 repeated (한 번만)');
reset role;
select pg_temp.ok((select count(*) from tutor_late_notices) = 1 and (select minutes from tutor_late_notices) = 10 and (select reason from tutor_late_notices) = 'internet', '처음 값 그대로 한 줄만');
select pg_temp.ok((select count(*) from notifications where dedupe_key = 'tutor_late_student:dddddddd-0000-4000-8000-0000000000c1') = 1, '학생 메일 1통');
select pg_temp.ok((select count(*) from notifications where dedupe_key = 'tutor_late_admin:dddddddd-0000-4000-8000-0000000000c1') = 1, '운영진 메일 1통');
select pg_temp.ok((select payload ->> 'subject' from notifications where dedupe_key = 'tutor_late_student:dddddddd-0000-4000-8000-0000000000c1')
  like '%[엣지영어] 강사님이 약 10분 늦을 예정이에요 · %월 %일(%) %[한국 시간]', '학생 메일 제목');
select pg_temp.ok((select payload ->> 'text' from notifications where dedupe_key = 'tutor_late_student:dddddddd-0000-4000-8000-0000000000c1')
  like E'김하준님, 강사님이 수업에 약 10분 늦을 예정이에요.\n\n수업: %[한국 시간] · 50분\n이유: 인터넷 연결에 문제가 생겼어요\n\n늦은 만큼 수업 시간을 연장해 드려요.\n연장 수업이 어려우시면 카카오톡 채널로 알려 주세요.\n\n불편을 드려 죄송합니다.\n\nLMS에서 일정 보기: %/student\n문의: 카카오톡 채널 엣지영어%', '학생 메일 본문 (확정 문구)');
select pg_temp.ok((select payload ->> 'text' from notifications where dedupe_key = 'tutor_late_student:dddddddd-0000-4000-8000-0000000000c1') not like '%기다려%', '기다리라는 말 없음');
select pg_temp.ok((select payload ->> 'subject' from notifications where dedupe_key = 'tutor_late_admin:dddddddd-0000-4000-8000-0000000000c1')
  like '%[강사 지각 알림] Emma → 김하준 · 약 10분 · %/%(%) 오% %:__ 한국 시간', '운영진 메일 제목 순서');
select pg_temp.ok((select payload ->> 'text' from notifications where dedupe_key = 'tutor_late_admin:dddddddd-0000-4000-8000-0000000000c1')
  like E'강사: Emma\n학생: 김하준 (STU-9301)\n수업: % 한국 시간 · 50분\n예상 지각: 약 10분\n이유: Internet problem\n알린 시각: % 한국 시간', '운영진 메일 본문');

-- 20분 이상 + 이유 없음 (해외 학생: 거주지 시간)
select set_config('request.jwt.claims', '{"sub":"eeeeeeee-0000-4000-8000-0000000000c1","aal":"aal1"}', true);
set local role authenticated;
select tutor_late_notice('dddddddd-0000-4000-8000-0000000000c4', 20, null);
reset role;
select pg_temp.ok((select payload ->> 'subject' from notifications where dedupe_key = 'tutor_late_student:dddddddd-0000-4000-8000-0000000000c4') like '%강사님이 20분 이상 늦을 예정이에요 · %[시드니 시간]', '20분 이상 제목 + 거주지 시간');
select pg_temp.ok((select payload ->> 'text' from notifications where dedupe_key = 'tutor_late_student:dddddddd-0000-4000-8000-0000000000c4') not like '%이유:%', '이유 없으면 이유 줄 없음');
select pg_temp.ok((select payload ->> 'text' from notifications where dedupe_key = 'tutor_late_admin:dddddddd-0000-4000-8000-0000000000c4') like E'%예상 지각: 20분 이상\n알린 시각:%', '운영진 메일: 20분 이상, 이유 줄 없음');

-- 운영자 대신 보내기 (James 수업)
select set_config('request.jwt.claims', '{"sub":"eeeeeeee-0000-4000-8000-0000000000c9","aal":"aal2"}', true);
set local role authenticated;
select pg_temp.ok((tutor_late_notice('dddddddd-0000-4000-8000-0000000000c5', 15, 'previous', 'aaaaaaaa-0000-4000-8000-0000000000c2') ->> 'repeated') = 'false', '운영자 대신 보냄');
select pg_temp.ok(jsonb_array_length(tutor_late_notices('aaaaaaaa-0000-4000-8000-0000000000c2')) = 1, '운영자 보기: James 알림 1개');
reset role;

-- 읽기: 강사 본인 / 학생 본인
select set_config('request.jwt.claims', '{"sub":"eeeeeeee-0000-4000-8000-0000000000c1","aal":"aal1"}', true);
set local role authenticated;
select pg_temp.ok(jsonb_array_length(tutor_late_notices(null)) = 2, '강사 화면: 보낸 수업 2개');
select pg_temp.ok((select count(*) from tutor_late_notices) = 0, '표를 직접 읽으면 아무것도 안 보임 (함수로만)');
reset role;
select set_config('request.jwt.claims', '{"sub":"eeeeeeee-0000-4000-8000-0000000000c3","aal":"aal1"}', true);
set local role authenticated;
select pg_temp.ok(jsonb_array_length(student_tutor_late_notices(null)) = 1, '학생 화면: 본인 수업 알림 1개 (서연 것 제외)');
select pg_temp.ok((select (e ->> 'minutes')::int from jsonb_array_elements(student_tutor_late_notices(null)) e where e ->> 'lesson_id' = 'dddddddd-0000-4000-8000-0000000000c1') = 10, '학생 화면: 분 값');
select pg_temp.fails($$select tutor_late_notice('dddddddd-0000-4000-8000-0000000000c1', 10, null)$$, '학생은 못 보냄');
reset role;
-- 수업 상태·시간은 그대로
select pg_temp.ok((select count(*) from lessons where id::text like 'dddddddd-0000-4000-8000-0000000000c%' and state = 'scheduled' and voided_at is null and class_status is null) = 5, '수업 상태 그대로');
rollback;
