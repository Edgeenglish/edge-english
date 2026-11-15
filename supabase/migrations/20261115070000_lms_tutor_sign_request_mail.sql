-- 강사 서명 요청 알림 메일 (대표 11/15 확정, H26(190)): 요청할 때 강사에게 1회만. 자동 재촉 메일 없음
--  - admin_sign_request(문서, 강사들, p_mail 기본 true): 새로 요청한 강사에게만 메일
--  - admin_sign_request_mail(요청): 아직 안 보낸 요청에 1회 보내기 (운영자 화면 [요청 메일 보내기]). 이미 보냈으면 그대로
--  - 받는 사람 = 강사 등록 이메일, send_emails 꺼져 있으면 support@ 로 (시험 발송)
-- 되돌리기: drop function admin_sign_request(uuid, uuid[], boolean), admin_sign_request_mail(uuid), lms_sign_request_mail(uuid);
--   20261115050000 의 admin_sign_request(uuid, uuid[]) · admin_sign_docs() 를 다시 실행

create or replace function lms_sign_request_mail(p_request uuid) returns boolean
language plpgsql security definer set search_path = public as $$
declare
  v_live boolean := coalesce((select f.enabled from feature_flags f where f.key = 'send_emails'), false);
  r tutor_sign_requests;
  tu tutors;
  v_title text;
  v_intended text;
  v_to text;
  v_subject text;
  v_text text;
  v_html text;
  v_nid uuid;
begin
  select * into r from tutor_sign_requests where id = p_request;
  if not found then return false; end if;
  if exists (select 1 from notifications where dedupe_key = 'tutor_sign_request:' || r.id) then return false; end if;
  if exists (select 1 from tutor_signatures where request_id = r.id) then return false; end if;
  select * into tu from tutors where id = r.tutor_id;
  v_intended := lms_notice_recipient_email('tutor', tu.id);
  if v_intended is null then return false; end if;
  v_title := lms_sign_doc_title(r.document_id);
  v_to := case when v_live then v_intended else 'support@edgeenglish.kr' end;
  -- 대표 11/15 확정 문구
  v_subject := case when v_live then '' else '[시험 · ' || tu.name || '] ' end || '[Edge English] Document ready for your signature';
  v_text := 'Hi ' || tu.name || ',' || E'\n\n' || 'Please log in to the LMS and sign the ' || v_title || ' within 7 days.' || E'\n'
    || 'You can find it under To do on your Home page.' || E'\n\n' || 'Thank you!' || E'\n' || 'Edge English Team'
    || case when v_live then '' else E'\n\n(시험 발송 · 원래 받는 사람: ' || v_intended || ')' end;
  v_html := '<div style="font-family:sans-serif;font-size:15px;line-height:1.6;color:#1d1b2a;max-width:480px">'
    || case when v_live then '' else '<p style="background:#fff4d6;color:#5c3b00;border-radius:8px;padding:8px 10px;font-size:13px;font-weight:600">시험 발송 · 원래 받는 사람: ' || lms_html(v_intended) || '</p>' end
    || '<p>Hi ' || lms_html(tu.name) || ',</p>'
    || '<p>Please log in to the LMS and sign the ' || lms_html(v_title) || ' within 7 days.<br>You can find it under To do on your Home page.</p>'
    || '<p>Thank you!<br>Edge English Team</p></div>';
  insert into notifications (recipient_kind, recipient_id, email, locale, template, payload, dedupe_key)
  values ('tutor', tu.id, v_to, 'en', 'tutor_sign_request',
          jsonb_build_object('intended_email', v_intended, 'subject', v_subject, 'html', v_html, 'text', v_text, 'request_id', r.id),
          'tutor_sign_request:' || r.id)
  on conflict (dedupe_key) do nothing
  returning id into v_nid;
  if v_nid is null then return false; end if;
  perform lms_mail_dispatch(v_nid);
  return true;
end $$;
revoke all on function lms_sign_request_mail(uuid) from public, anon, authenticated;

drop function if exists admin_sign_request(uuid, uuid[]);
create or replace function admin_sign_request(p_document uuid, p_tutors uuid[], p_mail boolean default true) returns integer
language plpgsql security definer set search_path = public as $$
declare
  n int := 0;
  v_id uuid;
  v_tutor uuid;
begin
  if not is_admin() then raise exception '운영자만 할 수 있어요.' using errcode = '42501'; end if;
  if not exists (select 1 from terms_documents where id = p_document and status = 'published') then raise exception '게시한 판만 요청할 수 있어요.'; end if;
  perform set_config('app.actor_id', coalesce(auth.uid()::text, ''), true);
  foreach v_tutor in array coalesce(p_tutors, '{}') loop
    v_id := null;
    insert into tutor_sign_requests (tutor_id, document_id, due_at, created_by)
    select t.id, p_document, now() + interval '7 days', auth.uid() from tutors t where t.id = v_tutor   -- 대표 11/15: 7일
    on conflict (tutor_id, document_id) do nothing
    returning id into v_id;
    if v_id is not null then
      n := n + 1;
      if p_mail then perform lms_sign_request_mail(v_id); end if;
    end if;
  end loop;
  return n;
end $$;
revoke all on function admin_sign_request(uuid, uuid[], boolean) from public, anon;
grant execute on function admin_sign_request(uuid, uuid[], boolean) to authenticated;

create or replace function admin_sign_request_mail(p_request uuid) returns boolean
language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception '운영자만 할 수 있어요.' using errcode = '42501'; end if;
  return lms_sign_request_mail(p_request);
end $$;
revoke all on function admin_sign_request_mail(uuid) from public, anon;
grant execute on function admin_sign_request_mail(uuid) to authenticated;

-- 운영자 현황에 요청 메일 상태 더함 (request_mail_status: null = 안 보냄)
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
                   'has_email', lms_notice_recipient_email('tutor', t.id) is not null,
                   'request_mail_status', (select n.status from notifications n where n.dedupe_key = 'tutor_sign_request:' || r.id),
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
