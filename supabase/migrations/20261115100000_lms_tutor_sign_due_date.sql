-- 강사 서명 요청 기한을 날짜로 고르기 (대표 11/15 확정, H26(193)): 기한 = 강사마다 현지 시간 그 날짜 끝(23:59)
--  - admin_sign_request(…, p_due_date): 날짜를 주면 강사별 현지 그 날 23:59 까지, 안 주면 지금처럼 요청 + 7일
--  - 이번 부속합의서: 11/19(목) — 강사 화면·메일에 'Thu, 19 Nov' (시간 없이 날짜만)
--  - 운영자 현황: due_local = 강사 현지 기한 날짜
-- 되돌리기: drop function admin_sign_request(uuid, uuid[], boolean, date); 20261115070000 의 admin_sign_request(3인자)·admin_sign_docs 다시 실행
drop function if exists admin_sign_request(uuid, uuid[], boolean);
create or replace function admin_sign_request(p_document uuid, p_tutors uuid[], p_mail boolean default true, p_due_date date default null) returns integer
language plpgsql security definer set search_path = public as $$
declare
  n int := 0;
  v_id uuid;
  v_tutor uuid;
begin
  if not is_admin() then raise exception '운영자만 할 수 있어요.' using errcode = '42501'; end if;
  if not exists (select 1 from terms_documents where id = p_document and status = 'published') then raise exception '게시한 판만 요청할 수 있어요.'; end if;
  if p_due_date is not null and p_due_date < (now() at time zone 'Asia/Seoul')::date then raise exception '기한은 오늘 이후 날짜로 골라 주세요.'; end if;
  perform set_config('app.actor_id', coalesce(auth.uid()::text, ''), true);
  foreach v_tutor in array coalesce(p_tutors, '{}') loop
    v_id := null;
    insert into tutor_sign_requests (tutor_id, document_id, due_at, created_by)
    select t.id, p_document,
           case when p_due_date is null then now() + interval '7 days'   -- 대표 11/15: 기본 7일
                else ((p_due_date + 1)::timestamp at time zone lms_tutor_tz_on(t.id, p_due_date)) - interval '1 minute' end,
           auth.uid()
    from tutors t where t.id = v_tutor
    on conflict (tutor_id, document_id) do nothing
    returning id into v_id;
    if v_id is not null then
      n := n + 1;
      if p_mail then perform lms_sign_request_mail(v_id); end if;
    end if;
  end loop;
  return n;
end $$;
revoke all on function admin_sign_request(uuid, uuid[], boolean, date) from public, anon;
grant execute on function admin_sign_request(uuid, uuid[], boolean, date) to authenticated;

create or replace function admin_sign_docs() returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not is_admin() then raise exception '운영자만 볼 수 있어요.' using errcode = '42501'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object(
      'id', d.id, 'code', d.terms_code, 'title', v.title, 'revision', d.revision, 'status', d.status,
      'body', d.body_md, 'statement', d.required_items -> 0 ->> 'text', 'sha256', d.content_sha256,
      'published_at', d.published_at, 'created_at', d.created_at,
      'requests', coalesce((select jsonb_agg(jsonb_build_object('request_id', r.id, 'tutor_id', t.id, 'tutor', t.name, 'requested_at', r.created_at, 'due_at', r.due_at,
                   'due_local', (r.due_at at time zone lms_tutor_tz_at(t.id, r.due_at))::date,
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
