-- 강사 LMS 전자서명 시험 (H26(188), 대표 11/15). 가짜 데이터만, 끝에 전부 되돌림(rollback) — 메일은 나가지 않음
begin;
create or replace function pg_temp.ok(c boolean, msg text) returns void language plpgsql as $$
begin if not coalesce(c, false) then raise exception '실패: %', msg; end if; raise notice '통과: %', msg; end $$;
create or replace function pg_temp.fails(sql text, msg text) returns void language plpgsql as $$
begin
  begin execute sql; exception when others then raise notice '통과: %', msg; return; end;
  raise exception '실패(막혀야 함): %', msg;
end $$;
create temp table v (k text primary key, val text);
grant all on v to authenticated;

insert into tutors (id, name, country, timezone, email) values
  ('aaaaaaaa-0000-4000-8000-0000000000e1', 'Emma', 'Philippines', 'Asia/Manila', 'emma@example.invalid'),
  ('aaaaaaaa-0000-4000-8000-0000000000e2', 'James', 'Philippines', 'Asia/Manila', 'james@example.invalid');
insert into app_users (auth_user_id, role, tutor_id) values
  ('eeeeeeee-0000-4000-8000-0000000000e1', 'tutor', 'aaaaaaaa-0000-4000-8000-0000000000e1'),
  ('eeeeeeee-0000-4000-8000-0000000000e2', 'tutor', 'aaaaaaaa-0000-4000-8000-0000000000e2');
insert into app_users (auth_user_id, role, admin_level) values ('eeeeeeee-0000-4000-8000-0000000000e9', 'admin', 'owner');

-- 운영자: 초안 → 게시(회사 서명) → 요청
select set_config('request.jwt.claims', '{"sub":"eeeeeeee-0000-4000-8000-0000000000e9","aal":"aal2"}', true);
set local role authenticated;
insert into v values ('doc', admin_sign_doc_save(null, 'Student Data Protection Addendum',
  E'Addendum: Student Data Protection\n\nThis Addendum is part of the contract ("Party A") - test.\n\n1. Purpose and scope\nParty A entrusts Party B with student information.',
  'I have read and agree to this Addendum. By clicking ‘I agree and sign,’ I intend to sign it electronically.')::text);
select pg_temp.fails($$select tutor_sign_send_code((select r.id from tutor_sign_requests r limit 1))$$, '요청 없으면 코드 못 보냄');
select pg_temp.fails($$select admin_sign_request((select val::uuid from v where k = 'doc'), array['aaaaaaaa-0000-4000-8000-0000000000e1'::uuid])$$, '게시 전 판은 요청 못 함');
select admin_sign_doc_save((select val::uuid from v where k = 'doc'), null,
  E'Addendum: Student Data Protection\n\nThis Addendum is part of the contract ("Party A") - test.\n\n1. Purpose and scope\nParty A entrusts Party B with student information (name, English level).',
  'I have read and agree to this Addendum. By clicking ‘I agree and sign,’ I intend to sign it electronically.');
select pg_temp.ok((select body_md like '%English level%' from terms_documents where id = (select val::uuid from v where k = 'doc')), '초안은 고칠 수 있음');
select admin_sign_doc_publish((select val::uuid from v where k = 'doc'));
select pg_temp.ok((select status = 'published' and published_by = 'eeeeeeee-0000-4000-8000-0000000000e9' and published_at is not null
  from terms_documents where id = (select val::uuid from v where k = 'doc')), '게시 = 회사 서명(대표 계정·시각)');
select pg_temp.fails($$select admin_sign_doc_save((select val::uuid from v where k = 'doc'), null, 'x', 'y')$$, '게시한 판은 함수로 못 고침');
select pg_temp.ok(admin_sign_request((select val::uuid from v where k = 'doc'), array['aaaaaaaa-0000-4000-8000-0000000000e1'::uuid, 'aaaaaaaa-0000-4000-8000-0000000000e2'::uuid]) = 2, '강사 2명에게 요청');
select pg_temp.ok(admin_sign_request((select val::uuid from v where k = 'doc'), array['aaaaaaaa-0000-4000-8000-0000000000e1'::uuid]) = 0, '같은 강사 다시 요청해도 그대로(메일도 다시 안 감)');
select pg_temp.ok((select bool_and(abs(extract(epoch from due_at - created_at) - 7 * 86400) < 1) from tutor_sign_requests), '기한 = 요청 + 7일');
insert into v select 'req1', id::text from tutor_sign_requests where tutor_id = 'aaaaaaaa-0000-4000-8000-0000000000e1';
reset role;
select pg_temp.ok((select count(*) = 2 and bool_and(payload ->> 'subject' like '%[Edge English] Document ready for your signature')
  and bool_and(payload ->> 'text' like 'Hi %,' || E'\n\n' || 'Please log in to the LMS and sign the Student Data Protection Addendum within 7 days.' || E'\n' || 'You can find it under To do on your Home page.' || E'\n\n' || 'Thank you!' || E'\n' || 'Edge English Team%')
  from notifications where template = 'tutor_sign_request'), '요청 알림 메일: 새 요청 2명에게 1통씩·확정 문구');
insert into tutors (id, name, country, timezone, email) values ('aaaaaaaa-0000-4000-8000-0000000000e3', 'Olivia', 'Japan', 'Asia/Tokyo', 'olivia@example.invalid');
set local role authenticated;
select pg_temp.ok(admin_sign_request((select val::uuid from v where k = 'doc'), array['aaaaaaaa-0000-4000-8000-0000000000e3'::uuid], false) = 1, '메일 없이 요청만');
reset role;
select pg_temp.ok((select count(*) = 2 from notifications where template = 'tutor_sign_request'), '메일 없이 요청하면 메일 안 생김');
set local role authenticated;
select pg_temp.ok(admin_sign_request_mail((select id from tutor_sign_requests where tutor_id = 'aaaaaaaa-0000-4000-8000-0000000000e3')), '나중에 요청 메일 보내기');
select pg_temp.ok(not admin_sign_request_mail((select id from tutor_sign_requests where tutor_id = 'aaaaaaaa-0000-4000-8000-0000000000e3')), '요청 메일은 한 번만');
select pg_temp.ok((select (r ->> 'request_mail_status') = 'queued' from jsonb_array_elements(admin_sign_docs() -> 0 -> 'requests') r where r ->> 'tutor' = 'Olivia'), '운영자 현황: 요청 메일 상태');

insert into v select 'req2', id::text from tutor_sign_requests where tutor_id = 'aaaaaaaa-0000-4000-8000-0000000000e2';
-- 운영자 보기: 열람은 되고 서명·코드는 안 됨
select pg_temp.ok(jsonb_array_length(tutor_sign_list('aaaaaaaa-0000-4000-8000-0000000000e1') -> 'open') = 1, '운영자 보기: 서명할 문서 보임');
select pg_temp.ok((tutor_sign_doc((select val::uuid from v where k = 'req1'), 'aaaaaaaa-0000-4000-8000-0000000000e1') ->> 'statement') like 'I have read%', '운영자 보기: 전문·서명 문구 열람');
select pg_temp.fails($$select tutor_sign_send_code((select val::uuid from v where k = 'req1'))$$, '운영자는 코드 못 보냄');
select pg_temp.fails($$select tutor_sign((select val::uuid from v where k = 'req1'), '123456', 'Emma Cruz', 'Philippines')$$, '운영자는 서명 못 함');
select pg_temp.fails($$select * from tutor_sign_codes$$, '운영자도 코드 표 직접 못 읽음');

-- 강사 Emma
select set_config('request.jwt.claims', '{"sub":"eeeeeeee-0000-4000-8000-0000000000e1","aal":"aal1"}', true);
select pg_temp.ok((select (x -> 'open' -> 0 ->> 'title') = 'Student Data Protection Addendum' from tutor_sign_list() x), '강사 To do 목록에 문서');
select pg_temp.fails($$select tutor_sign_doc((select val::uuid from v where k = 'req2'))$$, '다른 강사 요청은 못 봄');
select pg_temp.fails($$select tutor_sign_send_code((select val::uuid from v where k = 'req2'))$$, '다른 강사 요청엔 코드 못 보냄');
select pg_temp.ok((select (x ->> 'ok')::boolean = false and x ->> 'error' = 'no_code' from tutor_sign((select val::uuid from v where k = 'req1'), '000000', 'Emma Cruz', 'Philippines') x), '코드 받기 전엔 서명 안 됨');
select pg_temp.ok((tutor_sign_send_code((select val::uuid from v where k = 'req1')) ->> 'sent_to') = 'emma@example.invalid', '코드는 강사 등록 이메일로');
select pg_temp.ok((tutor_sign_doc((select val::uuid from v where k = 'req1')) -> 'code' ->> 'sent_to') = 'emma@example.invalid', '화면에 코드 보낸 곳');
reset role;
select pg_temp.ok((select payload ->> 'subject' = '[시험 · Emma] Edge English – Your signing code' and email = 'support@edgeenglish.kr'
  and payload ->> 'text' ~ 'Your code to sign the Student Data Protection Addendum is [0-9]{6}\.' and payload ->> 'text' like '%It expires in 10 minutes.%'
  and payload ->> 'text' like '%Edge English Team%' and payload ->> 'subject' !~ '[0-9]{6}'
  from notifications where template = 'tutor_sign_code'), '코드 메일: 승인 문구·제목에 코드 없음·시험 발송은 support@');
select pg_temp.ok((select extract(epoch from expires_at - created_at) between 599 and 601 from tutor_sign_codes), '코드 10분');
-- 시험용으로 코드를 아는 값으로 바꿈
update tutor_sign_codes set code_sha256 = encode(sha256(convert_to(request_id || ':123456', 'UTF8')), 'hex');
set local role authenticated;
select pg_temp.fails($$select tutor_sign((select val::uuid from v where k = 'req1'), '123456', ' ', 'Philippines')$$, '이름 없으면 못 함');
select pg_temp.fails($$select tutor_sign((select val::uuid from v where k = 'req1'), '123456', 'Emma Cruz', '')$$, '국가 없으면 못 함');
select pg_temp.ok((select x ->> 'error' = 'wrong' and (x ->> 'left')::int = 4 from tutor_sign((select val::uuid from v where k = 'req1'), '111111', 'Emma Cruz', 'Philippines') x), '틀린 코드: 남은 횟수 4');
select tutor_sign((select val::uuid from v where k = 'req1'), '111111', 'Emma Cruz', 'Philippines');
select tutor_sign((select val::uuid from v where k = 'req1'), '111111', 'Emma Cruz', 'Philippines');
select tutor_sign((select val::uuid from v where k = 'req1'), '111111', 'Emma Cruz', 'Philippines');
select pg_temp.ok((select x ->> 'error' = 'too_many' from tutor_sign((select val::uuid from v where k = 'req1'), '111111', 'Emma Cruz', 'Philippines') x), '5번째 틀리면 too_many');
select pg_temp.ok((select x ->> 'error' = 'too_many' from tutor_sign((select val::uuid from v where k = 'req1'), '123456', 'Emma Cruz', 'Philippines') x), '5번 틀린 뒤엔 맞는 코드도 안 됨');
-- 새 코드 → 만료 시험
select tutor_sign_send_code((select val::uuid from v where k = 'req1'));
reset role;
update tutor_sign_codes set code_sha256 = encode(sha256(convert_to(request_id || ':654321', 'UTF8')), 'hex'), expires_at = now() - interval '1 second'
 where id = (select id from tutor_sign_codes order by created_at desc limit 1);
set local role authenticated;
select pg_temp.ok((select x ->> 'error' = 'expired' from tutor_sign((select val::uuid from v where k = 'req1'), '654321', 'Emma Cruz', 'Philippines') x), '10분 지나면 expired');
select tutor_sign_send_code((select val::uuid from v where k = 'req1'));
reset role;
update tutor_sign_codes set code_sha256 = encode(sha256(convert_to(request_id || ':246810', 'UTF8')), 'hex')
 where id = (select id from tutor_sign_codes order by created_at desc limit 1);
set local role authenticated;
select pg_temp.ok((tutor_sign((select val::uuid from v where k = 'req1'), ' 246810 ', '  Emma   Cruz ', 'Philippines') ->> 'ok')::boolean, '맞는 코드로 서명');
select pg_temp.ok((tutor_sign((select val::uuid from v where k = 'req1'), '000000', 'X', 'Y') ->> 'repeated')::boolean, '다시 눌러도 같은 서명');
select pg_temp.ok(jsonb_array_length(tutor_sign_list() -> 'open') = 0 and jsonb_array_length(tutor_sign_list() -> 'signed') = 1, '서명 뒤 To do 에서 빠지고 My info 에 남음');
select pg_temp.ok((select (x -> 'signed' ->> 'name') = 'Emma Cruz' and x -> 'code' = 'null'::jsonb from tutor_sign_doc((select val::uuid from v where k = 'req1')) x), '서명 정보(이름 공백 정리)');
select pg_temp.ok((select left(convert_from(decode(x ->> 'base64', 'base64'), 'LATIN1'), 8) = '%PDF-1.4'
  from tutor_signed_pdf((select signature_id from (select (tutor_sign_list() -> 'signed' -> 0 ->> 'signature_id')::uuid as signature_id) q)) x), '강사 PDF 받기');
select pg_temp.fails($$select tutor_sign_send_code((select val::uuid from v where k = 'req1'))$$, '서명 뒤엔 코드 안 보냄');
reset role;
select pg_temp.ok((select s.document_sha256 = d.content_sha256 and s.code_sent_to = 'emma@example.invalid' and s.tutor_timezone = 'Asia/Manila'
  and s.statement like 'I have read%' and s.country = 'Philippines' and s.signer_auth_id = 'eeeeeeee-0000-4000-8000-0000000000e1'
  and s.pdf_sha256 = encode(sha256(s.pdf), 'hex')
  from tutor_signatures s join terms_documents d on d.id = s.document_id), '서명 기록: 해시·이메일·시간대·문구·계정');
select pg_temp.ok((select convert_from(pdf, 'LATIN1') like '%Party B: Emma Cruz%' and convert_from(pdf, 'LATIN1') like '%Party A: Tangerine English \\(Edge English\\)%'
  and convert_from(pdf, 'LATIN1') like '%Manila Time%KST%' and convert_from(pdf, 'LATIN1') like '%Document SHA-256: ' || left(document_sha256, 20) || '%'
  and convert_from(pdf, 'LATIN1') like '%\\("Party A"\\) - test%' and right(convert_from(pdf, 'LATIN1'), 6) = E'%%EOF\n'
  from tutor_signatures), 'PDF: 양측 서명·현지/한국 시간·해시·따옴표 바꿈·끝 표시');
select pg_temp.ok((select payload ->> 'subject' = '[시험 · Emma] Edge English – Your signed copy: Student Data Protection Addendum'
  and payload ->> 'text' like 'Hi Emma,%Thank you for signing the Student Data Protection Addendum.%Your signed copy is attached. You can also find it anytime in the LMS under My info › Documents.%Signed: %Manila Time / %KST' || E'\n\n' || 'Edge English Team%' and payload ->> 'html' like '%<p>Edge English Team</p></div>'
  and payload -> 'attachments' -> 0 ->> 'filename' = 'Student-Data-Protection-Addendum-v1-signed.pdf'
  and decode(payload -> 'attachments' -> 0 ->> 'content', 'base64') = (select pdf from tutor_signatures)
  from notifications where template = 'tutor_signed_copy'), '서명본 메일: 승인 문구·PDF 첨부');
select pg_temp.ok(case when current_setting('server_encoding') = 'UTF8' then lms_pdf_safe('“A” – ‘b’ 한') = '"A" - ''b'' ?' else true end, 'PDF 글자: 둥근 따옴표·대시 바꿈, 라틴 밖은 ?');
select pg_temp.fails($$update tutor_signatures set country = 'Japan'$$, '서명 기록은 못 고침');
select pg_temp.fails($$delete from tutor_signatures$$, '서명 기록은 못 지움');
select pg_temp.fails($$update terms_documents set body_md = 'changed' where status = 'published'$$, '게시한 전문은 못 고침');

-- James 는 Emma 서명본을 못 받음 / 운영자는 받음
select set_config('request.jwt.claims', '{"sub":"eeeeeeee-0000-4000-8000-0000000000e2","aal":"aal1"}', true);
set local role authenticated;
select pg_temp.fails($$select tutor_signed_pdf((select id from tutor_signatures limit 1))$$, '다른 강사 서명본은 못 받음');
select pg_temp.ok((select count(*) from tutor_signatures) = 0, '강사는 서명 표 직접 못 읽음(0줄)');
select set_config('request.jwt.claims', '{"sub":"eeeeeeee-0000-4000-8000-0000000000e9","aal":"aal2"}', true);
select pg_temp.ok((select (r ->> 'signed_at') is not null and r ->> 'country' = 'Philippines' and r ->> 'mail_status' = 'queued'
  from jsonb_array_elements(admin_sign_docs() -> 0 -> 'requests') r where r ->> 'tutor' = 'Emma'), '운영자 현황: 서명 시각·국가·메일 상태');
select pg_temp.ok((tutor_signed_pdf((select (r ->> 'signature_id')::uuid from jsonb_array_elements(admin_sign_docs() -> 0 -> 'requests') r where r ->> 'tutor' = 'Emma'),
  'aaaaaaaa-0000-4000-8000-0000000000e1') ->> 'base64') is not null, '운영자 PDF 받기');
-- 새 판 게시 → 이전 판 retired, 서명 안 한 James 요청은 To do 에서 빠짐
insert into v values ('doc2', admin_sign_doc_save(null, 'Student Data Protection Addendum', E'Addendum v2\n\nText.', 'I agree.')::text);
select pg_temp.ok((select revision = 2 from terms_documents where id = (select val::uuid from v where k = 'doc2')), '같은 이름 = 다음 판');
select admin_sign_doc_publish((select val::uuid from v where k = 'doc2'));
select pg_temp.ok((select status = 'retired' from terms_documents where id = (select val::uuid from v where k = 'doc')), '새 판 게시하면 이전 판 retired');
select pg_temp.ok(jsonb_array_length(tutor_sign_list('aaaaaaaa-0000-4000-8000-0000000000e2') -> 'open') = 0, '이전 판 요청은 To do 에서 빠짐');
select pg_temp.ok(jsonb_array_length(tutor_sign_list('aaaaaaaa-0000-4000-8000-0000000000e1') -> 'signed') = 1, '이전 판 서명 기록은 남음');
reset role;
rollback;
