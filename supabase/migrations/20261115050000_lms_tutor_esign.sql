-- =====================================================================
-- 강사 LMS 전자서명 (정책 원본 H26(188), 대표 11/15 확정 — 시안 docs/lms/previews/tutor-esign-drafts.html)
--  - 문서 원본·판: 기존 terms_versions + terms_documents 재사용 (게시 뒤 수정 불가, DB 가 SHA-256 계산)
--    · 서명 의사 문구는 required_items[0].text 에 넣어 원본·해시에 같이 묶음
--    · 회사 서명 = 대표가 판을 게시(published_by·published_at). 새 판을 게시하면 이전 판은 retired
--  - 강사 서명 요청(tutor_sign_requests) → 강사 To do 'Sign: …' · 기한 = 요청 시각 + 7일 (대표 11/15)
--  - 서명 직전 이메일 6자리 코드 (대표 11/15): 유효 10분 · 5번 틀리면 새 코드 (tutor_sign_codes, 해시만 저장)
--  - 서명 기록(tutor_signatures, 쌓기만): 계정·입력 이름·거주 국가·판·전문 해시·서명 의사 문구·서버 시각·코드 받은 이메일·PDF. IP 저장 안 함
--  - 서명하면 양측 서명 정보가 든 PDF 를 강사 등록 이메일로 자동 발송 (첨부) · 같은 PDF 를 회사가 보관
--  - 서명은 강사 본인만 (운영자 보기는 열람·PDF 받기만, 대표 11/15)
--  - consent_requests·consent_events 는 학생·수강등록 필수 + '동의는 학생만' 제약이라 쓰지 않음
-- 기존 데이터를 바꾸지 않음. lms_mail_dispatch 는 첨부(payload.attachments)만 더함 (없으면 예전과 같음)
-- 되돌리기: drop function tutor_sign_list(uuid), tutor_sign_doc(uuid, uuid), tutor_sign_send_code(uuid), tutor_sign(uuid, text, text, text),
--   tutor_signed_pdf(uuid, uuid), admin_sign_docs(), admin_sign_doc_save(uuid, text, text, text), admin_sign_doc_publish(uuid),
--   admin_sign_request(uuid, uuid[]), lms_sign_pdf(uuid), lms_pdf_text(jsonb), lms_pdf_wrap(text, numeric, numeric, boolean),
--   lms_pdf_width(text, boolean), lms_pdf_safe(text), lms_sign_doc_title(uuid);
--   drop table tutor_signatures, tutor_sign_codes, tutor_sign_requests; lms_mail_dispatch 는 20261108110000 판으로 다시 실행
-- =====================================================================

-- 1. 표 -----------------------------------------------------------------
create table if not exists tutor_sign_requests (
  id uuid primary key default gen_random_uuid(),
  tutor_id uuid not null references tutors(id),
  document_id uuid not null references terms_documents(id),
  due_at timestamptz not null,              -- 요청 시각 + 7일 (대표 11/15)
  created_by uuid,
  created_at timestamptz not null default now(),
  unique (tutor_id, document_id)
);

create table if not exists tutor_sign_codes (
  id uuid primary key default gen_random_uuid(),
  request_id uuid not null references tutor_sign_requests(id),
  code_sha256 text not null,                -- 코드 자체는 저장하지 않음
  sent_to text not null,                    -- 코드를 보낸 강사 등록 이메일 (시험 발송이어도 원래 받는 사람)
  expires_at timestamptz not null,
  wrong_tries integer not null default 0 check (wrong_tries between 0 and 5),
  used_at timestamptz,
  created_at timestamptz not null default clock_timestamp()   -- 같은 트랜잭션에서도 '가장 최근 코드'가 갈리게
);
create index if not exists tutor_sign_codes_request on tutor_sign_codes (request_id, created_at desc);

create table if not exists tutor_signatures (
  id uuid primary key default gen_random_uuid(),
  request_id uuid not null unique references tutor_sign_requests(id),
  tutor_id uuid not null references tutors(id),
  document_id uuid not null references terms_documents(id),
  document_sha256 text not null,            -- 서명한 순간의 전문 해시
  statement text not null,                  -- 보여 준 서명 의사 문구
  signed_name text not null,
  country text not null,                    -- 강사가 직접 넣은 거주 국가
  signed_at timestamptz not null default now(),  -- 서버 시각
  signer_auth_id uuid not null,
  code_id uuid not null references tutor_sign_codes(id),
  code_sent_to text not null,
  tutor_timezone text not null,
  pdf bytea not null,
  pdf_sha256 text not null
);

do $$ begin
  if not exists (select 1 from pg_trigger where tgname = 'tutor_sign_requests_no_delete') then
    perform lms_protect('public.tutor_sign_requests');
    create trigger tutor_sign_requests_no_delete before delete on tutor_sign_requests for each row execute function forbid_delete();
    create trigger tutor_sign_requests_no_update before update on tutor_sign_requests for each row execute function forbid_update();
    -- 코드 표: 아무도 직접 못 읽음 (함수만)
    alter table tutor_sign_codes enable row level security;
    revoke all on tutor_sign_codes from anon, authenticated;
    perform lms_protect('public.tutor_signatures');
    create trigger tutor_signatures_no_delete before delete on tutor_signatures for each row execute function forbid_delete();
    create trigger tutor_signatures_no_update before update on tutor_signatures for each row execute function forbid_update();
  end if;
end $$;

-- 2. 메일 첨부: payload.attachments 가 있으면 Resend 에 그대로 붙임 (나머지는 20261108110000 판과 같음) --------
create or replace function lms_mail_dispatch(p_notification uuid) returns boolean
language plpgsql security definer set search_path = public as $$
declare
  x notifications;
  v_key text;
  v_req bigint;
  v_has_net boolean := exists (select 1 from pg_proc p join pg_namespace s on s.oid = p.pronamespace where s.nspname = 'net' and p.proname = 'http_post');
  v_note text;
  v_bcc boolean := not coalesce((select f.enabled from feature_flags f where f.key = 'email_bcc_ops_stop'), false);
begin
  select * into x from notifications where id = p_notification for update;
  if not found or x.status <> 'queued' or x.net_request_id is not null then return false; end if;
  if to_regclass('vault.decrypted_secrets') is not null then
    execute $q$select decrypted_secret from vault.decrypted_secrets where name = 'resend_api_key'$q$ into v_key;
  end if;
  if nullif(trim(v_key), '') is null then v_note := '메일 키(resend_api_key)가 없어 보내지 못함 · 운영진 화면 [다시 보내기]';
  elsif not v_has_net then v_note := 'pg_net 확장이 없어 보내지 못함'; end if;
  if v_note is not null then
    update notifications set last_error = v_note where id = x.id;
    update lesson_notices set email_error = v_note where email_notification_id = x.id;
    return false;
  end if;
  execute $q$select net.http_post(url := 'https://api.resend.com/emails', body := $1, headers := $2)$q$ into v_req
    using jsonb_build_object('from', case when x.locale = 'ko' then '엣지영어 <support@edgeenglish.kr>' else 'Edge English <support@edgeenglish.kr>' end,
                             'to', jsonb_build_array(x.email), 'subject', x.payload ->> 'subject',
                             'html', x.payload ->> 'html', 'text', x.payload ->> 'text')
          -- 실제 학생·강사에게 갈 때만 운영진 숨은참조 (시험 발송은 이미 support@ 로 감)
          || case when v_bcc and lower(x.email) <> 'support@edgeenglish.kr' then jsonb_build_object('bcc', jsonb_build_array('support@edgeenglish.kr')) else '{}'::jsonb end
          -- 첨부 (강사 서명본 PDF 등): [{filename, content(base64)}]
          || case when jsonb_typeof(x.payload -> 'attachments') = 'array' then jsonb_build_object('attachments', x.payload -> 'attachments') else '{}'::jsonb end,
          jsonb_build_object('Authorization', 'Bearer ' || trim(v_key), 'Content-Type', 'application/json',
                             -- 같은 메일을 두 번 보내지 않음. [다시 보내기]는 시도 번호가 붙어 새 요청으로
                             'Idempotency-Key', x.dedupe_key || case when x.attempts > 0 then ':' || x.attempts else '' end);
  update notifications set net_request_id = v_req, attempts = attempts + 1, last_error = null where id = x.id;
  update lesson_notices set email_attempts = email_attempts + 1, email_error = null where email_notification_id = x.id;
  return true;
end $$;
revoke all on function lms_mail_dispatch(uuid) from public, anon, authenticated;

-- 3. PDF (글자만, Helvetica · WinAnsi) ----------------------------------------
-- 라틴 문자 밖은 '?', 둥근 따옴표·대시는 곧은 글자로
create or replace function lms_pdf_safe(p text) returns text
language sql immutable as $$
  select regexp_replace(translate(coalesce(p, ''), '‘’“”–—›‹•…' || chr(160), '''''""--><*.' || ' '), '[^\u0001-ÿ]', '?', 'g')
$$;

-- 글자 폭 (Helvetica AFM, 1000 단위). 굵은 글씨는 넉넉히 1.1배
create or replace function lms_pdf_width(p text, p_bold boolean) returns numeric
language plpgsql immutable as $$
declare
  w int[] := array[278,278,355,556,556,889,667,191,333,333,389,584,278,333,278,278,
                   556,556,556,556,556,556,556,556,556,556,278,278,584,584,584,556,
                   1015,667,667,722,722,667,611,778,722,278,500,667,556,833,722,778,
                   667,778,722,667,611,722,667,944,667,667,611,278,278,278,469,556,
                   333,556,556,500,556,556,278,556,556,222,222,500,222,833,556,556,
                   556,556,333,500,278,556,500,722,500,500,500,334,260,334,584];
  s numeric := 0;
  c int;
begin
  for i in 1 .. length(p) loop
    c := ascii(substr(p, i, 1));
    s := s + case when c between 32 and 126 then w[c - 31] else 600 end;
  end loop;
  return s * case when p_bold then 1.1 else 1 end;
end $$;

-- 한 줄을 폭에 맞게 나눔 (단어 단위, 너무 긴 단어는 글자 단위)
create or replace function lms_pdf_wrap(p text, p_size numeric, p_width numeric, p_bold boolean) returns text[]
language plpgsql immutable as $$
declare
  v_lines text[] := '{}';
  v_cur text := '';
  v_max numeric := p_width * 1000 / p_size;
  wd text;
begin
  foreach wd in array regexp_split_to_array(trim(p), '\s+') loop
    if wd = '' then continue; end if;
    while lms_pdf_width(wd, p_bold) > v_max loop          -- 아주 긴 단어(해시 등)
      if v_cur <> '' then v_lines := v_lines || v_cur; v_cur := ''; end if;
      for k in reverse length(wd) .. 1 loop
        if lms_pdf_width(left(wd, k), p_bold) <= v_max then v_lines := v_lines || left(wd, k); wd := substr(wd, k + 1); exit; end if;
      end loop;
    end loop;
    if wd = '' then continue; end if;
    if v_cur = '' then v_cur := wd;
    elsif lms_pdf_width(v_cur || ' ' || wd, p_bold) <= v_max then v_cur := v_cur || ' ' || wd;
    else v_lines := v_lines || v_cur; v_cur := wd; end if;
  end loop;
  if v_cur <> '' or cardinality(v_lines) = 0 then v_lines := v_lines || v_cur; end if;
  return v_lines;
end $$;

-- 문단 목록 [{t, b(굵게), s(크기), g(위 간격)}] → A4 PDF bytea. 쪽이 넘치면 다음 쪽
create or replace function lms_pdf_text(p_paras jsonb) returns bytea
language plpgsql immutable as $$
declare
  c_left numeric := 56; c_top numeric := 786; c_bottom numeric := 56; c_width numeric := 483;
  v_pages text[] := '{}';
  v_stream text := '';
  v_y numeric := c_top;
  p jsonb;
  v_size numeric;
  v_bold boolean;
  ln text;
  v_pdf bytea;
  v_off int[] := '{}';
  v_n int;
  v_kids text := '';
  v_obj text;
  v_len int;
begin
  for p in select * from jsonb_array_elements(p_paras) loop
    v_size := coalesce((p ->> 's')::numeric, 10);
    v_bold := coalesce((p ->> 'b')::boolean, false);
    v_y := v_y - coalesce((p ->> 'g')::numeric, 0);
    foreach ln in array lms_pdf_wrap(lms_pdf_safe(p ->> 't'), v_size, c_width, v_bold) loop
      if v_y - v_size * 1.35 < c_bottom then v_pages := v_pages || v_stream; v_stream := ''; v_y := c_top; end if;
      v_y := v_y - v_size * 1.35;
      v_stream := v_stream || format(E'BT /%s %s Tf 1 0 0 1 %s %s Tm (%s) Tj ET\n', case when v_bold then 'F2' else 'F1' end,
        v_size, c_left, round(v_y, 2), replace(replace(replace(ln, '\', '\\'), '(', '\('), ')', '\)'));
    end loop;
  end loop;
  v_pages := v_pages || v_stream;
  v_n := cardinality(v_pages);
  -- 1 Catalog · 2 Pages · 3 Helvetica · 4 Helvetica-Bold · 그다음 쪽마다 (Page, Contents)
  for i in 1 .. v_n loop v_kids := v_kids || (4 + 2 * i - 1) || ' 0 R '; end loop;
  v_pdf := convert_to(E'%PDF-1.4\n', 'LATIN1');
  v_off := v_off || octet_length(v_pdf);
  v_pdf := v_pdf || convert_to(E'1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n', 'LATIN1');
  v_off := v_off || octet_length(v_pdf);
  v_pdf := v_pdf || convert_to(format(E'2 0 obj\n<< /Type /Pages /Kids [%s] /Count %s >>\nendobj\n', trim(v_kids), v_n), 'LATIN1');
  v_off := v_off || octet_length(v_pdf);
  v_pdf := v_pdf || convert_to(E'3 0 obj\n<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>\nendobj\n', 'LATIN1');
  v_off := v_off || octet_length(v_pdf);
  v_pdf := v_pdf || convert_to(E'4 0 obj\n<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica-Bold /Encoding /WinAnsiEncoding >>\nendobj\n', 'LATIN1');
  for i in 1 .. v_n loop
    v_off := v_off || octet_length(v_pdf);
    v_pdf := v_pdf || convert_to(format(E'%s 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] /Resources << /Font << /F1 3 0 R /F2 4 0 R >> >> /Contents %s 0 R >>\nendobj\n',
      4 + 2 * i - 1, 4 + 2 * i), 'LATIN1');
    v_len := octet_length(convert_to(v_pages[i], 'LATIN1'));
    v_off := v_off || octet_length(v_pdf);
    v_pdf := v_pdf || convert_to(format(E'%s 0 obj\n<< /Length %s >>\nstream\n', 4 + 2 * i, v_len), 'LATIN1')
                   || convert_to(v_pages[i], 'LATIN1') || convert_to(E'\nendstream\nendobj\n', 'LATIN1');
  end loop;
  v_obj := format(E'xref\n0 %s\n0000000000 65535 f \n', 4 + 2 * v_n + 1);
  for i in 1 .. cardinality(v_off) loop v_obj := v_obj || lpad(v_off[i]::text, 10, '0') || E' 00000 n \n'; end loop;
  v_obj := v_obj || format(E'trailer\n<< /Size %s /Root 1 0 R >>\nstartxref\n%s\n%%%%EOF\n', 4 + 2 * v_n + 1, octet_length(v_pdf));
  return v_pdf || convert_to(v_obj, 'LATIN1');
end $$;

create or replace function lms_sign_doc_title(p_document uuid) returns text
language sql stable security definer set search_path = public as $$
  select v.title from terms_documents d join terms_versions v on v.code = d.terms_code where d.id = p_document
$$;
revoke all on function lms_sign_doc_title(uuid) from public, anon, authenticated;

-- 서명 1건의 PDF 내용: 전문(첫 줄·'1. …' 줄은 굵게) + 양측 서명 정보
create or replace function lms_sign_pdf_paras(p_document uuid, p_name text, p_country text, p_signed_at timestamptz, p_tz text,
  p_sent_to text, p_signature uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  d terms_documents;
  v jsonb := '[]'::jsonb;
  para text;
  ln text;
  i int := 0;
  j int;
begin
  select * into d from terms_documents where id = p_document;
  foreach para in array regexp_split_to_array(trim(d.body_md), E'\n\\s*\n') loop
    i := i + 1;
    j := 0;
    foreach ln in array string_to_array(para, E'\n') loop
      j := j + 1;
      v := v || jsonb_build_array(jsonb_build_object('t', ln,
        'b', (i = 1) or (j = 1 and ln ~ '^\d+\.\s'),
        's', case when i = 1 then 14 else 10 end,
        'g', case when j = 1 and i > 1 then 7 else 0 end));
    end loop;
  end loop;
  v := v || jsonb_build_array(
    jsonb_build_object('t', 'Signatures', 'b', true, 's', 12, 'g', 22),
    jsonb_build_object('t', 'Party A: Tangerine English (Edge English)', 'b', true, 'g', 8),
    jsonb_build_object('t', 'Signed electronically by the Representative: ' || lms_mail_en_when(d.published_at, 'Asia/Seoul') || ' KST'),
    jsonb_build_object('t', 'Party B: ' || p_name, 'b', true, 'g', 8),
    jsonb_build_object('t', 'Country of residence: ' || p_country),
    jsonb_build_object('t', 'Signed electronically: ' || lms_strip_bold(lms_mail_en_at(p_signed_at, p_tz))),
    jsonb_build_object('t', 'Statement: ' || (d.required_items -> 0 ->> 'text')),
    jsonb_build_object('t', 'Identity check: a 6-digit code was sent to ' || p_sent_to || ' and entered before signing.'),
    jsonb_build_object('t', 'Record', 'b', true, 'g', 8),
    jsonb_build_object('t', 'Document: ' || lms_sign_doc_title(d.id) || ' (Version ' || d.revision || ')', 's', 8.5),
    jsonb_build_object('t', 'Document SHA-256: ' || d.content_sha256, 's', 8.5),
    jsonb_build_object('t', 'Signature ID: ' || p_signature, 's', 8.5));
  return v;
end $$;
revoke all on function lms_sign_pdf_paras(uuid, text, text, timestamptz, text, text, uuid) from public, anon, authenticated;

-- 4. 강사 화면 --------------------------------------------------------------
-- 목록: 서명할 문서(게시 중인 판) + 서명한 문서. To do·My info 가 씀
create or replace function tutor_sign_list(p_tutor uuid default null) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_tutor uuid := lms_screen_tutor(p_tutor);
begin
  return jsonb_build_object(
    'open', coalesce((select jsonb_agg(jsonb_build_object('request_id', r.id, 'title', lms_sign_doc_title(d.id), 'revision', d.revision, 'due_at', r.due_at) order by r.created_at)
                      from tutor_sign_requests r join terms_documents d on d.id = r.document_id
                      where r.tutor_id = v_tutor and d.status = 'published'
                        and not exists (select 1 from tutor_signatures s where s.request_id = r.id)), '[]'::jsonb),
    'signed', coalesce((select jsonb_agg(jsonb_build_object('signature_id', s.id, 'request_id', s.request_id, 'title', lms_sign_doc_title(s.document_id),
                                                          'revision', d.revision, 'signed_at', s.signed_at, 'tz', s.tutor_timezone) order by s.signed_at desc)
                        from tutor_signatures s join terms_documents d on d.id = s.document_id
                        where s.tutor_id = v_tutor), '[]'::jsonb));
end $$;
revoke all on function tutor_sign_list(uuid) from public, anon;
grant execute on function tutor_sign_list(uuid) to authenticated;

-- 문서 1건: 전문·판·회사 서명 시각·서명 의사 문구·(서명했으면) 서명 정보·(유효한 코드가 있으면) 보낸 곳
create or replace function tutor_sign_doc(p_request uuid, p_tutor uuid default null) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_tutor uuid := lms_screen_tutor(p_tutor);
  r tutor_sign_requests;
  d terms_documents;
  s tutor_signatures;
  c tutor_sign_codes;
begin
  select * into r from tutor_sign_requests where id = p_request and tutor_id = v_tutor;
  if not found then raise exception 'This document is not available.' using errcode = '42501'; end if;
  select * into d from terms_documents where id = r.document_id;
  select * into s from tutor_signatures where request_id = r.id;
  select * into c from tutor_sign_codes where request_id = r.id order by created_at desc limit 1;
  return jsonb_build_object('request_id', r.id, 'title', lms_sign_doc_title(d.id), 'revision', d.revision, 'body', d.body_md,
    'statement', d.required_items -> 0 ->> 'text', 'company_signed_at', d.published_at, 'document_sha256', d.content_sha256,
    'status', d.status, 'due_at', r.due_at,
    'signed', case when s.id is null then null else jsonb_build_object('signature_id', s.id, 'name', s.signed_name, 'country', s.country,
                'signed_at', s.signed_at, 'tz', s.tutor_timezone, 'document_sha256', s.document_sha256) end,
    'code', case when c.id is not null and c.used_at is null and c.expires_at > now() and c.wrong_tries < 5 and s.id is null
                 then jsonb_build_object('sent_to', c.sent_to, 'expires_at', c.expires_at) end);
end $$;
revoke all on function tutor_sign_doc(uuid, uuid) from public, anon;
grant execute on function tutor_sign_doc(uuid, uuid) to authenticated;

-- 서명 코드 보내기: 강사 본인만. 새 코드를 보내면 이전 코드는 못 씀 (가장 최근 코드만 확인)
create or replace function tutor_sign_send_code(p_request uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_tutor uuid := my_tutor_id();
  v_live boolean := coalesce((select f.enabled from feature_flags f where f.key = 'send_emails'), false);
  r tutor_sign_requests;
  d terms_documents;
  tu tutors;
  v_code text;
  v_intended text;
  v_to text;
  v_title text;
  v_subject text;
  v_text text;
  v_html text;
  v_id uuid;
  v_nid uuid;
  v_exp timestamptz := now() + interval '10 minutes';   -- 대표 11/15: 10분
begin
  if v_tutor is null then raise exception 'Only the tutor can sign.' using errcode = '42501'; end if;
  select * into r from tutor_sign_requests where id = p_request and tutor_id = v_tutor for update;
  if not found then raise exception 'This document is not available.' using errcode = '42501'; end if;
  select * into d from terms_documents where id = r.document_id;
  if d.status <> 'published' then raise exception 'This document is no longer available.'; end if;
  if exists (select 1 from tutor_signatures where request_id = r.id) then raise exception 'You have already signed this document.'; end if;
  select * into tu from tutors where id = v_tutor;
  v_intended := lms_notice_recipient_email('tutor', v_tutor);
  if v_intended is null then raise exception 'Your email is missing. Please contact Edge English.'; end if;
  -- 6자리 (강한 난수: gen_random_uuid 의 바이트)
  v_code := lpad(((('x' || substr(replace(gen_random_uuid()::text, '-', ''), 1, 8))::bit(32)::bigint & 2147483647) % 1000000)::text, 6, '0');
  insert into tutor_sign_codes (request_id, code_sha256, sent_to, expires_at)
  values (r.id, encode(sha256(convert_to(r.id || ':' || v_code, 'UTF8')), 'hex'), v_intended, v_exp)
  returning id into v_id;

  -- 메일 (대표 11/15 승인 문구, 제목에 코드 없음)
  v_title := lms_sign_doc_title(d.id);
  v_to := case when v_live then v_intended else 'support@edgeenglish.kr' end;
  v_subject := case when v_live then '' else '[시험 · ' || tu.name || '] ' end || 'Edge English – Your signing code';
  v_text := 'Hi ' || tu.name || ',' || E'\n\n' || 'Your code to sign the ' || v_title || ' is ' || v_code || '.' || E'\n\n'
    || 'It expires in 10 minutes.' || E'\n\n' || 'Edge English Team'
    || case when v_live then '' else E'\n\n(시험 발송 · 원래 받는 사람: ' || v_intended || ')' end;
  v_html := '<div style="font-family:sans-serif;font-size:15px;line-height:1.6;color:#1d1b2a;max-width:480px">'
    || case when v_live then '' else '<p style="background:#fff4d6;color:#5c3b00;border-radius:8px;padding:8px 10px;font-size:13px;font-weight:600">시험 발송 · 원래 받는 사람: ' || lms_html(v_intended) || '</p>' end
    || '<p>Hi ' || lms_html(tu.name) || ',</p>'
    || '<p>Your code to sign the ' || lms_html(v_title) || ' is <b style="font-size:18px;letter-spacing:2px">' || v_code || '</b>.</p>'
    || '<p>It expires in 10 minutes.</p><p>Edge English Team</p></div>';
  insert into notifications (recipient_kind, recipient_id, email, locale, template, payload, dedupe_key)
  values ('tutor', v_tutor, v_to, 'en', 'tutor_sign_code',
          jsonb_build_object('intended_email', v_intended, 'subject', v_subject, 'html', v_html, 'text', v_text, 'request_id', r.id),
          'tutor_sign_code:' || v_id)
  returning id into v_nid;
  perform lms_mail_dispatch(v_nid);
  return jsonb_build_object('sent_to', v_intended, 'expires_at', v_exp);
end $$;
revoke all on function tutor_sign_send_code(uuid) from public, anon;
grant execute on function tutor_sign_send_code(uuid) to authenticated;

-- 서명: 강사 본인만. 코드가 틀리면 오류 대신 {ok:false} (틀린 횟수를 남기기 위해). 이미 서명했으면 그 서명을 돌려줌
create or replace function tutor_sign(p_request uuid, p_code text, p_name text, p_country text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_tutor uuid := my_tutor_id();
  v_live boolean := coalesce((select f.enabled from feature_flags f where f.key = 'send_emails'), false);
  r tutor_sign_requests;
  d terms_documents;
  tu tutors;
  c tutor_sign_codes;
  s tutor_signatures;
  v_name text := regexp_replace(trim(coalesce(p_name, '')), '\s+', ' ', 'g');
  v_country text := regexp_replace(trim(coalesce(p_country, '')), '\s+', ' ', 'g');
  v_sig uuid := gen_random_uuid();
  v_at timestamptz := now();
  v_tz text;
  v_pdf bytea;
  v_title text;
  v_file text;
  v_intended text;
  v_to text;
  v_subject text;
  v_when text;
  v_text text;
  v_html text;
  v_nid uuid;
begin
  if v_tutor is null then raise exception 'Only the tutor can sign.' using errcode = '42501'; end if;
  select * into r from tutor_sign_requests where id = p_request and tutor_id = v_tutor for update;
  if not found then raise exception 'This document is not available.' using errcode = '42501'; end if;
  select * into s from tutor_signatures where request_id = r.id;
  if found then return jsonb_build_object('ok', true, 'signature_id', s.id, 'signed_at', s.signed_at, 'repeated', true); end if;
  select * into d from terms_documents where id = r.document_id;
  if d.status <> 'published' then raise exception 'This document is no longer available.'; end if;
  if length(v_name) < 2 or length(v_name) > 100 then raise exception 'Enter your full name.'; end if;
  if length(v_country) < 2 or length(v_country) > 80 then raise exception 'Enter your country of residence.'; end if;

  select * into c from tutor_sign_codes where request_id = r.id order by created_at desc limit 1 for update;
  if not found or c.used_at is not null then return jsonb_build_object('ok', false, 'error', 'no_code'); end if;
  if c.wrong_tries >= 5 then return jsonb_build_object('ok', false, 'error', 'too_many'); end if;   -- 대표 11/15: 5회
  if c.expires_at <= now() then return jsonb_build_object('ok', false, 'error', 'expired'); end if;
  if encode(sha256(convert_to(r.id || ':' || coalesce(trim(p_code), ''), 'UTF8')), 'hex') <> c.code_sha256 then
    update tutor_sign_codes set wrong_tries = wrong_tries + 1 where id = c.id;
    return jsonb_build_object('ok', false, 'error', case when c.wrong_tries + 1 >= 5 then 'too_many' else 'wrong' end, 'left', 5 - (c.wrong_tries + 1));
  end if;

  select * into tu from tutors where id = v_tutor;
  v_tz := lms_tutor_tz_at(v_tutor, v_at);
  v_pdf := lms_pdf_text(lms_sign_pdf_paras(d.id, v_name, v_country, v_at, v_tz, c.sent_to, v_sig));
  perform set_config('app.actor_id', coalesce(auth.uid()::text, ''), true);
  perform set_config('app.actor_via', 'tutor_sign', true);
  update tutor_sign_codes set used_at = v_at where id = c.id;
  insert into tutor_signatures (id, request_id, tutor_id, document_id, document_sha256, statement, signed_name, country, signed_at,
                                signer_auth_id, code_id, code_sent_to, tutor_timezone, pdf, pdf_sha256)
  values (v_sig, r.id, v_tutor, d.id, d.content_sha256, d.required_items -> 0 ->> 'text', v_name, v_country, v_at,
          auth.uid(), c.id, c.sent_to, v_tz, v_pdf, encode(sha256(v_pdf), 'hex'));

  -- 서명본 메일 (대표 11/15 승인 문구) + PDF 첨부. 운영진은 숨은참조로 같은 메일을 받음
  v_title := lms_sign_doc_title(d.id);
  v_file := regexp_replace(v_title, '[^A-Za-z0-9]+', '-', 'g') || '-v' || d.revision || '-signed.pdf';
  v_intended := lms_notice_recipient_email('tutor', v_tutor);
  if v_intended is not null then
    v_to := case when v_live then v_intended else 'support@edgeenglish.kr' end;
    v_when := lms_mail_en_at(v_at, v_tz);
    v_subject := case when v_live then '' else '[시험 · ' || tu.name || '] ' end || 'Edge English – Your signed copy: ' || v_title;
    v_text := 'Hi ' || tu.name || ',' || E'\n\n' || 'Thank you for signing the ' || v_title || '.' || E'\n'
      || 'Your signed copy is attached. You can also find it anytime in the LMS under My info › Documents.' || E'\n\n'
      || 'Signed: ' || lms_strip_bold(v_when) || E'\n\n' || 'Edge English'
      || case when v_live then '' else E'\n\n(시험 발송 · 원래 받는 사람: ' || v_intended || ')' end;
    v_html := '<div style="font-family:sans-serif;font-size:15px;line-height:1.6;color:#1d1b2a;max-width:480px">'
      || case when v_live then '' else '<p style="background:#fff4d6;color:#5c3b00;border-radius:8px;padding:8px 10px;font-size:13px;font-weight:600">시험 발송 · 원래 받는 사람: ' || lms_html(v_intended) || '</p>' end
      || '<p>Hi ' || lms_html(tu.name) || ',</p>'
      || '<p>Thank you for signing the ' || lms_html(v_title) || '.<br>Your signed copy is attached. You can also find it anytime in the LMS under My info › Documents.</p>'
      || '<p>Signed: ' || lms_bold_html(v_when) || '</p><p>Edge English</p></div>';
    insert into notifications (recipient_kind, recipient_id, email, locale, template, payload, dedupe_key)
    values ('tutor', v_tutor, v_to, 'en', 'tutor_signed_copy',
            jsonb_build_object('intended_email', v_intended, 'subject', v_subject, 'html', v_html, 'text', v_text, 'signature_id', v_sig,
                               'attachments', jsonb_build_array(jsonb_build_object('filename', v_file, 'content', replace(encode(v_pdf, 'base64'), E'\n', '')))),
            'tutor_signed_copy:' || v_sig)
    returning id into v_nid;
    perform lms_mail_dispatch(v_nid);
  end if;
  return jsonb_build_object('ok', true, 'signature_id', v_sig, 'signed_at', v_at, 'repeated', false);
end $$;
revoke all on function tutor_sign(uuid, text, text, text) from public, anon;
grant execute on function tutor_sign(uuid, text, text, text) to authenticated;

-- PDF 받기: 강사 본인 · 운영자
create or replace function tutor_signed_pdf(p_signature uuid, p_tutor uuid default null) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_tutor uuid := lms_screen_tutor(p_tutor);
  s tutor_signatures;
begin
  select * into s from tutor_signatures where id = p_signature and tutor_id = v_tutor;
  if not found then raise exception 'This document is not available.' using errcode = '42501'; end if;
  return jsonb_build_object('filename', regexp_replace(lms_sign_doc_title(s.document_id), '[^A-Za-z0-9]+', '-', 'g')
                              || '-v' || (select revision from terms_documents where id = s.document_id) || '-signed.pdf',
                            'base64', replace(encode(s.pdf, 'base64'), E'\n', ''), 'sha256', s.pdf_sha256);
end $$;
revoke all on function tutor_signed_pdf(uuid, uuid) from public, anon;
grant execute on function tutor_signed_pdf(uuid, uuid) to authenticated;

-- 5. 운영자 화면 ------------------------------------------------------------
create or replace function admin_sign_docs() returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not is_admin() then raise exception '운영자만 볼 수 있어요.' using errcode = '42501'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object(
      'id', d.id, 'code', d.terms_code, 'title', v.title, 'revision', d.revision, 'status', d.status,
      'body', d.body_md, 'statement', d.required_items -> 0 ->> 'text', 'sha256', d.content_sha256,
      'published_at', d.published_at, 'created_at', d.created_at,
      'requests', coalesce((select jsonb_agg(jsonb_build_object('request_id', r.id, 'tutor_id', t.id, 'tutor', t.name, 'requested_at', r.created_at, 'due_at', r.due_at,
                   'signature_id', s.id, 'signed_at', s.signed_at, 'country', s.country,
                   'mail_status', (select n.status from notifications n where n.dedupe_key = 'tutor_signed_copy:' || s.id),
                   'mail_error', (select n.last_error from notifications n where n.dedupe_key = 'tutor_signed_copy:' || s.id)) order by t.name)
                 from tutor_sign_requests r join tutors t on t.id = r.tutor_id left join tutor_signatures s on s.request_id = r.id
                 where r.document_id = d.id), '[]'::jsonb))
      order by v.title, d.revision desc)
    from terms_documents d join terms_versions v on v.code = d.terms_code
    where v.audience = 'tutor' and d.format = 'text' and jsonb_array_length(d.required_items) > 0), '[]'::jsonb);
end $$;
revoke all on function admin_sign_docs() from public, anon;
grant execute on function admin_sign_docs() to authenticated;

-- 초안 저장: p_document 가 있으면 그 초안 고치기, 없으면 p_title 의 새 판(같은 이름 문서가 있으면 다음 판) 만들기
create or replace function admin_sign_doc_save(p_document uuid, p_title text, p_body text, p_statement text) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_title text := trim(coalesce(p_title, ''));
  v_body text := trim(replace(coalesce(p_body, ''), E'\r', ''));
  v_stmt text := trim(coalesce(p_statement, ''));
  v_code text;
  v_id uuid;
begin
  if not is_admin() then raise exception '운영자만 할 수 있어요.' using errcode = '42501'; end if;
  if v_body = '' or v_stmt = '' then raise exception '전문과 서명 문구를 넣어 주세요.'; end if;
  perform set_config('app.actor_id', coalesce(auth.uid()::text, ''), true);
  if p_document is not null then
    update terms_documents set body_md = v_body, required_items = jsonb_build_array(jsonb_build_object('key', 'sign', 'text', v_stmt))
    where id = p_document and status = 'draft' returning id into v_id;
    if v_id is null then raise exception '게시한 판은 고칠 수 없어요. 새 판을 만드세요.'; end if;
    return v_id;
  end if;
  if v_title = '' then raise exception '문서 이름을 넣어 주세요.'; end if;
  select code into v_code from terms_versions where audience = 'tutor' and title = v_title;
  if v_code is null then
    v_code := 'TS_' || left(upper(regexp_replace(v_title, '[^A-Za-z0-9]+', '_', 'g')), 40);
    insert into terms_versions (code, kind, audience, title, first_seen, is_draft, source_ref, note)
    values (v_code, 'contract', 'tutor', v_title, null, false, 'LMS', '강사 LMS 전자서명 문서 (H26(188))');
  end if;
  if exists (select 1 from terms_documents where terms_code = v_code and status = 'draft') then
    raise exception '이 문서에 아직 게시하지 않은 판이 있어요. 그 판을 고치세요.';
  end if;
  insert into terms_documents (terms_code, revision, format, body_md, required_items)
  values (v_code, coalesce((select max(revision) from terms_documents where terms_code = v_code), 0) + 1, 'text', v_body,
          jsonb_build_array(jsonb_build_object('key', 'sign', 'text', v_stmt)))
  returning id into v_id;
  return v_id;
end $$;
revoke all on function admin_sign_doc_save(uuid, text, text, text) from public, anon;
grant execute on function admin_sign_doc_save(uuid, text, text, text) to authenticated;

-- 회사 서명하고 게시: 대표 계정·시각이 회사 서명. 같은 문서의 이전 판은 retired (서명 안 한 요청은 To do 에서 빠짐)
create or replace function admin_sign_doc_publish(p_document uuid) returns void
language plpgsql security definer set search_path = public as $$
declare d terms_documents;
begin
  if not is_admin() then raise exception '운영자만 할 수 있어요.' using errcode = '42501'; end if;
  select * into d from terms_documents where id = p_document for update;
  if not found or d.status <> 'draft' then raise exception '게시할 초안이 아니에요.'; end if;
  perform set_config('app.actor_id', coalesce(auth.uid()::text, ''), true);
  update terms_documents set status = 'retired' where terms_code = d.terms_code and status = 'published';
  update terms_documents set status = 'published', published_at = now(), published_by = auth.uid() where id = d.id;
end $$;
revoke all on function admin_sign_doc_publish(uuid) from public, anon;
grant execute on function admin_sign_doc_publish(uuid) to authenticated;

-- 서명 요청 보내기 (강사 To do 에 생김). 이미 요청한 강사는 그대로
create or replace function admin_sign_request(p_document uuid, p_tutors uuid[]) returns integer
language plpgsql security definer set search_path = public as $$
declare n int;
begin
  if not is_admin() then raise exception '운영자만 할 수 있어요.' using errcode = '42501'; end if;
  if not exists (select 1 from terms_documents where id = p_document and status = 'published') then raise exception '게시한 판만 요청할 수 있어요.'; end if;
  perform set_config('app.actor_id', coalesce(auth.uid()::text, ''), true);
  insert into tutor_sign_requests (tutor_id, document_id, due_at, created_by)
  select t.id, p_document, now() + interval '7 days', auth.uid() from tutors t where t.id = any(p_tutors)   -- 대표 11/15: 7일
  on conflict (tutor_id, document_id) do nothing;
  get diagnostics n = row_count;
  return n;
end $$;
revoke all on function admin_sign_request(uuid, uuid[]) from public, anon;
grant execute on function admin_sign_request(uuid, uuid[]) to authenticated;

revoke all on function lms_pdf_text(jsonb) from public, anon, authenticated;
revoke all on function lms_pdf_wrap(text, numeric, numeric, boolean) from public, anon, authenticated;
revoke all on function lms_pdf_width(text, boolean) from public, anon, authenticated;
revoke all on function lms_pdf_safe(text) from public, anon, authenticated;
