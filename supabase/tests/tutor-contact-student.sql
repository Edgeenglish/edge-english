-- 강사 [학생에게 연락하기] 시험 (H26(197), 대표 11/16 시안 3판). 가짜 데이터만, 끝에 전부 되돌림(rollback) — 메일은 나가지 않음
begin;
create or replace function pg_temp.ok(c boolean, msg text) returns void language plpgsql as $$
begin if not coalesce(c, false) then raise exception '실패: %', msg; end if; raise notice '통과: %', msg; end $$;
create or replace function pg_temp.fails(sql text, msg text) returns void language plpgsql as $$
begin
  begin execute sql; exception when others then raise notice '통과: %', msg; return; end;
  raise exception '실패(막혀야 함): %', msg;
end $$;

insert into tutors (id, name, country, timezone, email, meet_url) values
  ('aaaaaaaa-0000-4000-8000-0000000000d1', 'Emma', 'Philippines', 'Asia/Manila', 'emma@example.invalid', 'https://meet.google.com/abc-defg-hij'),
  ('aaaaaaaa-0000-4000-8000-0000000000d2', 'James', 'Philippines', 'Asia/Manila', 'james@example.invalid', null),
  ('aaaaaaaa-0000-4000-8000-0000000000d3', 'Liam', 'Philippines', 'Asia/Manila', 'liam@example.invalid', 'https://meet.google.com/liam-room'),
  ('aaaaaaaa-0000-4000-8000-0000000000d4', 'Noah', 'Philippines', 'Asia/Manila', 'noah@example.invalid', null);
insert into students (id, code, name_ko, name_en, timezone, email) values
  ('bbbbbbbb-0000-4000-8000-0000000000d1', 'STU-9401', '김하준', 'Hajun', 'Asia/Seoul', 'a@example.invalid'),
  ('bbbbbbbb-0000-4000-8000-0000000000d2', 'STU-9402', '박서연', 'Seoyeon', 'Australia/Sydney', 'b@example.invalid'),
  ('bbbbbbbb-0000-4000-8000-0000000000d3', 'STU-9403', '이지우', 'Jiwoo', 'Asia/Seoul', 'c@example.invalid'),
  ('bbbbbbbb-0000-4000-8000-0000000000d4', 'STU-9404', '최도윤', 'Doyun', 'Asia/Seoul', 'd@example.invalid');
insert into enrollments (id, student_id, seq, contract_version, weeks, weekly_count, duration_min, start_date, base_end_date, lessons_purchased, status)
select ('cccccccc-0000-4000-8000-0000000000d' || i)::uuid, ('bbbbbbbb-0000-4000-8000-0000000000d' || i)::uuid, 1, 'SC2', 4, 3, 50, current_date - 7, current_date + 20, 12, 'active'
from generate_series(1, 4) i;
-- ① Liam·하준 10분 전 시작(1차 가능·2차 아직) ② Noah·지우 3분 전 시작(1차 아직) ③ Emma·서연 30분 전 시작(1·2차 가능)
-- ④ Emma·하준 끝남 ⑤ James·도윤 30분 전 시작(운영자 대신) ⑥ Emma·하준 1시간 뒤
insert into lessons (id, enrollment_id, student_id, tutor_id, kind, seq, starts_at, ends_at, state) values
  ('dddddddd-0000-4000-8000-0000000000d1', 'cccccccc-0000-4000-8000-0000000000d1', 'bbbbbbbb-0000-4000-8000-0000000000d1', 'aaaaaaaa-0000-4000-8000-0000000000d3', 'regular', 1, now() - interval '10 minutes', now() + interval '40 minutes', 'scheduled'),
  ('dddddddd-0000-4000-8000-0000000000d2', 'cccccccc-0000-4000-8000-0000000000d3', 'bbbbbbbb-0000-4000-8000-0000000000d3', 'aaaaaaaa-0000-4000-8000-0000000000d4', 'regular', 1, now() - interval '3 minutes', now() + interval '47 minutes', 'scheduled'),
  ('dddddddd-0000-4000-8000-0000000000d3', 'cccccccc-0000-4000-8000-0000000000d2', 'bbbbbbbb-0000-4000-8000-0000000000d2', 'aaaaaaaa-0000-4000-8000-0000000000d1', 'regular', 1, now() - interval '30 minutes', now() + interval '20 minutes', 'scheduled'),
  ('dddddddd-0000-4000-8000-0000000000d4', 'cccccccc-0000-4000-8000-0000000000d1', 'bbbbbbbb-0000-4000-8000-0000000000d1', 'aaaaaaaa-0000-4000-8000-0000000000d1', 'regular', 2, now() - interval '120 minutes', now() - interval '70 minutes', 'scheduled'),
  ('dddddddd-0000-4000-8000-0000000000d5', 'cccccccc-0000-4000-8000-0000000000d4', 'bbbbbbbb-0000-4000-8000-0000000000d4', 'aaaaaaaa-0000-4000-8000-0000000000d2', 'regular', 1, now() - interval '30 minutes', now() + interval '20 minutes', 'scheduled'),
  ('dddddddd-0000-4000-8000-0000000000d6', 'cccccccc-0000-4000-8000-0000000000d1', 'bbbbbbbb-0000-4000-8000-0000000000d1', 'aaaaaaaa-0000-4000-8000-0000000000d1', 'regular', 3, now() + interval '1 hour', now() + interval '110 minutes', 'scheduled');
insert into app_users (auth_user_id, role, tutor_id) values
  ('eeeeeeee-0000-4000-8000-0000000000d1', 'tutor', 'aaaaaaaa-0000-4000-8000-0000000000d1'),
  ('eeeeeeee-0000-4000-8000-0000000000d4', 'tutor', 'aaaaaaaa-0000-4000-8000-0000000000d3'),
  ('eeeeeeee-0000-4000-8000-0000000000d5', 'tutor', 'aaaaaaaa-0000-4000-8000-0000000000d4');
insert into app_users (auth_user_id, role, student_id) values
  ('eeeeeeee-0000-4000-8000-0000000000d3', 'student', 'bbbbbbbb-0000-4000-8000-0000000000d1');
insert into app_users (auth_user_id, role, admin_level) values ('eeeeeeee-0000-4000-8000-0000000000d9', 'admin', 'owner');

-- 막혀야 하는 것 (Emma 로그인)
select set_config('request.jwt.claims', '{"sub":"eeeeeeee-0000-4000-8000-0000000000d1","aal":"aal1"}', true);
set local role authenticated;
select pg_temp.fails($$select tutor_contact_student('dddddddd-0000-4000-8000-0000000000d5', 1, null)$$, '다른 강사 수업은 못 보냄');
select pg_temp.fails($$select tutor_contact_student('dddddddd-0000-4000-8000-0000000000d6', 1, null)$$, '시작 전 수업은 못 보냄');
select pg_temp.fails($$select tutor_contact_student('dddddddd-0000-4000-8000-0000000000d4', 1, null)$$, '끝난 수업은 못 보냄');
select pg_temp.fails($$select tutor_contact_student('dddddddd-0000-4000-8000-0000000000d3', 2, null)$$, '1차 없이 2차 못 보냄');
select pg_temp.fails($$select tutor_contact_student('dddddddd-0000-4000-8000-0000000000d3', 3, null)$$, '1·2차 말고는 못 보냄');
select pg_temp.fails(format('select tutor_contact_student(%L, 1, %L)', 'dddddddd-0000-4000-8000-0000000000d3', repeat('a', 151)), '한마디 151자는 못 보냄');
select pg_temp.fails($$select tutor_contact_student('dddddddd-0000-4000-8000-0000000000d5', 1, null, 'aaaaaaaa-0000-4000-8000-0000000000d2')$$, '강사는 다른 강사 대신 못 보냄');
reset role;
select set_config('request.jwt.claims', '{"sub":"eeeeeeee-0000-4000-8000-0000000000d5","aal":"aal1"}', true);
set local role authenticated;
select pg_temp.fails($$select tutor_contact_student('dddddddd-0000-4000-8000-0000000000d2', 1, null)$$, '시작 5분 전에는 1차 못 보냄');
reset role;
select pg_temp.ok((select count(*) from tutor_contact_notices) = 0 and (select count(*) from notifications where dedupe_key like 'tutor_contact:%') = 0, '막힌 것은 아무것도 안 남김');

-- 1차 (한국 학생, Liam, 한마디 앞뒤 공백)
select set_config('request.jwt.claims', '{"sub":"eeeeeeee-0000-4000-8000-0000000000d4","aal":"aal1"}', true);
set local role authenticated;
select pg_temp.ok((tutor_contact_student('dddddddd-0000-4000-8000-0000000000d1', 1, '  Hi Hajun! I''m in our Meet room.  ') ->> 'repeated') = 'false', '1차 보냄');
select pg_temp.ok((tutor_contact_student('dddddddd-0000-4000-8000-0000000000d1', 1, 'again') ->> 'repeated') = 'true', '같은 1차 다시 누르면 repeated (한 번만)');
select pg_temp.fails($$select tutor_contact_student('dddddddd-0000-4000-8000-0000000000d1', 2, null)$$, '수업 절반 전에는 2차 못 보냄');
reset role;
select set_config('request.jwt.claims', '{"sub":"eeeeeeee-0000-4000-8000-0000000000d1","aal":"aal1"}', true);
set local role authenticated;
select pg_temp.ok((tutor_contact_student('dddddddd-0000-4000-8000-0000000000d3', 1, repeat('b', 150)) ->> 'repeated') = 'false', '한마디 150자는 보냄');
reset role;
select pg_temp.ok((select note from tutor_contact_notices where lesson_id = 'dddddddd-0000-4000-8000-0000000000d1') = 'Hi Hajun! I''m in our Meet room.' and (select by_admin from tutor_contact_notices where lesson_id = 'dddddddd-0000-4000-8000-0000000000d1') = false, '처음 값 그대로·앞뒤 공백 없앰·강사가 보냄');
select pg_temp.ok((select count(*) from notifications where dedupe_key = 'tutor_contact:dddddddd-0000-4000-8000-0000000000d1:1') = 1, '학생 메일 1통');
select pg_temp.ok((select count(*) from notifications where dedupe_key like 'tutor_contact%' and recipient_kind = 'admin') = 0, '운영진 메일은 따로 없음 (숨은참조로 받음)');
select pg_temp.ok((select payload ->> 'subject' from notifications where dedupe_key = 'tutor_contact:dddddddd-0000-4000-8000-0000000000d1:1') like '%[엣지영어] Liam 강사님이 수업방에서 기다리고 있어요', '1차 제목');
select pg_temp.ok((select payload ->> 'text' from notifications where dedupe_key = 'tutor_contact:dddddddd-0000-4000-8000-0000000000d1:1')
  like E'김하준님, 안녕하세요! 엣지영어입니다. ☺️\n오늘 수업 시간이 시작되었는데 아직 입장하지 않으셔서 연락드려요.\nLiam 강사님이 수업방에서 기다리고 계세요. 지금이라도 참여하실 수 있으니 아래 버튼을 눌러 입장해 주세요!\n\n수업 안내\n• 수업 시간: %[한국 시간]\n\n수업 들어가기: https://meet.google.com/liam-room\n\n💬 Liam 강사님의 메시지\nHi Hajun! I''m in our Meet room.\n\n늦게 입장하시더라도 기존 수업 종료 시간은 연장되지 않는 점 참고 부탁드려요.\n오늘 수업 참여가 어려우시다면 엣지영어 카카오톡 채널로 알려 주세요.\n\n감사합니다.\n엣지영어 드림%', '1차 본문 (확정 문구 순서)');
select pg_temp.ok((select payload ->> 'html' from notifications where dedupe_key = 'tutor_contact:dddddddd-0000-4000-8000-0000000000d1:1') like '%수업 안내%href="https://meet.google.com/liam-room"%💬 Liam 강사님의 메시지%늦게 입장%', '메일 버튼 = 강사 Meet, 한마디 칸');

-- 2차 (해외 학생: 거주지 시간 · 한마디 없음)
select set_config('request.jwt.claims', '{"sub":"eeeeeeee-0000-4000-8000-0000000000d1","aal":"aal1"}', true);
set local role authenticated;
select pg_temp.ok((tutor_contact_student('dddddddd-0000-4000-8000-0000000000d3', 2, '   ') ->> 'repeated') = 'false', '2차 보냄 (빈 한마디)');
reset role;
select pg_temp.ok((select note from tutor_contact_notices where lesson_id = 'dddddddd-0000-4000-8000-0000000000d3' and stage = 2) is null, '빈 한마디는 저장 안 함');
select pg_temp.ok((select payload ->> 'subject' from notifications where dedupe_key = 'tutor_contact:dddddddd-0000-4000-8000-0000000000d3:2') like '%[엣지영어] 아직 수업에 참여하실 수 있어요', '2차 제목');
select pg_temp.ok((select payload ->> 'text' from notifications where dedupe_key = 'tutor_contact:dddddddd-0000-4000-8000-0000000000d3:2')
  like E'박서연님, 안녕하세요! 엣지영어입니다. ☺️\n아직 수업에 입장하지 않으셔서 한 번 더 연락드려요.\nEmma 강사님은 수업이 끝날 때까지 기다리고 계십니다.\n남은 시간이라도 수업에 참여하실 수 있으니 아래 버튼을 눌러 주세요!\n\n수업 안내\n• 수업 시작: %[시드니 시간] / %[한국 시간]\n• 수업 종료: 오%[시드니 시간] / %[한국 시간]\n\n수업 들어가기: https://meet.google.com/abc-defg-hij\n\n늦게 입장하시더라도 수업 종료 시간은 동일하며, 별도로 연장되지 않습니다.\n\n감사합니다.\n엣지영어 드림%', '2차 본문 (메시지 칸 없음·거주지 시간)');
select pg_temp.ok((select payload ->> 'html' from notifications where dedupe_key = 'tutor_contact:dddddddd-0000-4000-8000-0000000000d3:2') not like '%강사님의 메시지%', '한마디 없으면 메시지 칸 없음');

-- 운영자 대신 (James 수업, Meet 주소 없음 → LMS)
select set_config('request.jwt.claims', '{"sub":"eeeeeeee-0000-4000-8000-0000000000d9","aal":"aal2"}', true);
set local role authenticated;
select pg_temp.ok((tutor_contact_student('dddddddd-0000-4000-8000-0000000000d5', 1, null, 'aaaaaaaa-0000-4000-8000-0000000000d2') ->> 'repeated') = 'false', '운영자 대신 보냄');
select pg_temp.ok((select (e ->> 'by_admin')::boolean from jsonb_array_elements(tutor_contact_notices('aaaaaaaa-0000-4000-8000-0000000000d2')) e) = true, '운영자 보기: 운영자 대신 표시');
reset role;
select pg_temp.ok((select payload ->> 'text' from notifications where dedupe_key = 'tutor_contact:dddddddd-0000-4000-8000-0000000000d5:1') like E'%수업 들어가기: %/student\n%', 'Meet 주소 없으면 LMS 학생 홈');

-- 읽기: 강사 본인 / 학생은 못 읽음
select set_config('request.jwt.claims', '{"sub":"eeeeeeee-0000-4000-8000-0000000000d1","aal":"aal1"}', true);
set local role authenticated;
select pg_temp.ok(jsonb_array_length(tutor_contact_notices(null)) = 2, '강사 화면: 보낸 연락 2개 (다른 강사 것 제외)');
select pg_temp.ok((select count(*) from tutor_contact_notices) = 0, '표를 직접 읽으면 아무것도 안 보임 (함수로만)');
reset role;
select set_config('request.jwt.claims', '{"sub":"eeeeeeee-0000-4000-8000-0000000000d3","aal":"aal1"}', true);
set local role authenticated;
select pg_temp.fails($$select tutor_contact_notices(null)$$, '학생은 못 읽음');
select pg_temp.fails($$select tutor_contact_student('dddddddd-0000-4000-8000-0000000000d1', 1, null)$$, '학생은 못 보냄');
reset role;
select pg_temp.fails($$delete from tutor_contact_notices$$, '기록은 못 지움');
select pg_temp.ok((select count(*) from lessons where id::text like 'dddddddd-0000-4000-8000-0000000000d%' and state = 'scheduled' and voided_at is null and class_status is null) = 6, '수업 상태 그대로');
rollback;
