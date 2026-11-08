-- =====================================================================
-- 자동 메일 운영진 숨은참조 (대표 2026-11-08): 학생·강사에게 실제로 보내는 메일마다 support@edgeenglish.kr 숨은참조(BCC) 1통
--  - send_emails 가 켜져 실제 주소로 갈 때만 붙음 (꺼져 있으면 이미 support@ 로만 감)
--  - 멈추기: 대표가 '숨은참조 그만' 하면 feature_flags 'email_bcc_ops_stop' enabled = true (기능 스위치는 모두 꺼진 채 시작하는 원칙 → 꺼짐 = 숨은참조 보냄)
--  - 받는 사람에게 숨은참조 주소는 보이지 않음. 다시 실행해도 같은 결과
-- =====================================================================

insert into feature_flags (key, enabled, note)
values ('email_bcc_ops_stop', false, '자동 메일 운영진 숨은참조(support@) 멈춤. 꺼짐 = 숨은참조 보냄, 대표가 멈추라고 하면 켬 (2026-11-08)')
on conflict (key) do nothing;

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
          || case when v_bcc and lower(x.email) <> 'support@edgeenglish.kr' then jsonb_build_object('bcc', jsonb_build_array('support@edgeenglish.kr')) else '{}'::jsonb end,
          jsonb_build_object('Authorization', 'Bearer ' || trim(v_key), 'Content-Type', 'application/json',
                             -- 같은 메일을 두 번 보내지 않음. [다시 보내기]는 시도 번호가 붙어 새 요청으로
                             'Idempotency-Key', x.dedupe_key || case when x.attempts > 0 then ':' || x.attempts else '' end);
  update notifications set net_request_id = v_req, attempts = attempts + 1, last_error = null where id = x.id;
  update lesson_notices set email_attempts = email_attempts + 1, email_error = null where email_notification_id = x.id;
  return true;
end $$;
revoke all on function lms_mail_dispatch(uuid) from public, anon, authenticated;
