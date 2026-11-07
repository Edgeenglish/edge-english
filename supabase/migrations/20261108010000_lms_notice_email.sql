-- =====================================================================
-- 강사 자율 운영 2단계 (2026-11-07 대표 확정, 정책 원본 H26(86)): 보강이 확정되면 학생·강사 양쪽에 자동 이메일
--  - 범위: lesson_notices.event = 'makeup_confirmed' 만 (다른 안내 유형은 이후 단계적으로)
--  - 기존 카톡(학생)·WhatsApp(강사) 복사 안내는 그대로 두고 병행 (status 칸은 수동 안내, email_* 칸은 자동 메일)
--  - 메일 내용: 원래 수업·보강 수업 날짜·시각(받는 사람 현지 시간 + 한국 시간), 담당 강사, LMS 링크
--  - 받는 주소: students.email / tutors.email → 없으면 로그인 이메일(auth.users, app_users 연결)
--  - 중복 방지: notifications.dedupe_key = 'lesson_notice_email:' || 안내 id (안내 1건 = 메일 1통), Resend Idempotency-Key 같음
--  - 발송: 안내 줄이 생기는 순간 pg_net 으로 Resend API 호출(같은 트랜잭션 → 확정이 취소되면 메일도 안 나감)
--    결과는 다음에 운영진 화면이 admin_mail_sync() 를 부를 때(또는 예약 실행) net._http_response 를 보고 보냄/실패로 기록
--  - 실패·주소 없음은 운영진 화면에 사유와 함께 남고 [다시 보내기](admin_resend_notice_email) 로만 재시도 — 자동 재시도 없음
--  - feature_flags.send_emails 가 꺼져 있으면 support@edgeenglish.kr 로만 가고 제목 앞에 '[시험 · 학생 번호]' (실제 발송은 별도 승인)
--  - Resend 키는 Supabase Vault 'resend_api_key'. 키·pg_net 이 없으면 queued 로 남고 사유를 적음 (운영진 화면에서 보임)
-- 새 규칙·새 숫자 없음. 다시 실행해도 같은 결과
-- =====================================================================

alter table notifications add column if not exists net_request_id bigint;

alter table lesson_notices add column if not exists email_status text
  check (email_status in ('queued', 'sent', 'failed', 'no_address'));
alter table lesson_notices add column if not exists email_to text;          -- 실제로 보낸 주소 (시험이면 support@)
alter table lesson_notices add column if not exists email_intended text;    -- 원래 받는 사람 주소
alter table lesson_notices add column if not exists email_queued_at timestamptz;
alter table lesson_notices add column if not exists email_sent_at timestamptz;
alter table lesson_notices add column if not exists email_error text;
alter table lesson_notices add column if not exists email_attempts integer not null default 0;
alter table lesson_notices add column if not exists email_notification_id uuid references notifications(id);

-- ---------------------------------------------------------------------
-- 글자 도우미 (화면 TS 문구와 같은 모양: src/lms/admin/lesson-change.ts koAt·enAt)
-- ---------------------------------------------------------------------
create or replace function lms_html(p text) returns text
language sql immutable as $$
  select replace(replace(replace(replace(coalesce(p, ''), '&', '&amp;'), '<', '&lt;'), '>', '&gt;'), '"', '&quot;')
$$;
revoke all on function lms_html(text) from public, anon, authenticated;

-- '11월 13일(목) 오전 9시' · '11월 13일(목) 오후 9시 30분'
create or replace function lms_mail_ko_when(p_at timestamptz, p_tz text) returns text
language sql stable as $$
  select extract(month from x)::int || '월 ' || extract(day from x)::int || '일('
         || (array['일', '월', '화', '수', '목', '금', '토'])[extract(dow from x)::int + 1] || ') '
         || case when extract(hour from x) < 12 then '오전 ' else '오후 ' end
         || (case when extract(hour from x)::int % 12 = 0 then 12 else extract(hour from x)::int % 12 end) || '시'
         || case when extract(minute from x)::int > 0 then ' ' || extract(minute from x)::int || '분' else '' end
  from (select p_at at time zone coalesce(nullif(p_tz, ''), 'Asia/Seoul') as x) q
$$;
revoke all on function lms_mail_ko_when(timestamptz, text) from public, anon, authenticated;

-- 해외 학생: '11월 12일(수) 오후 7시 (한국 11월 13일(목) 오전 9시)' / 한국: 한국 시각만
create or replace function lms_mail_ko_at(p_at timestamptz, p_tz text) returns text
language sql stable as $$
  select case when coalesce(nullif(p_tz, ''), 'Asia/Seoul') = 'Asia/Seoul' then lms_mail_ko_when(p_at, 'Asia/Seoul')
              else lms_mail_ko_when(p_at, p_tz) || ' (한국 ' || lms_mail_ko_when(p_at, 'Asia/Seoul') || ')' end
$$;
revoke all on function lms_mail_ko_at(timestamptz, text) from public, anon, authenticated;

-- 'Thu 13 Nov 09:00'
create or replace function lms_mail_en_when(p_at timestamptz, p_tz text) returns text
language sql stable as $$
  select (array['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'])[extract(dow from x)::int + 1] || ' ' || extract(day from x)::int || ' '
         || (array['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'])[extract(month from x)::int] || ' '
         || to_char(x, 'HH24:MI')
  from (select p_at at time zone coalesce(nullif(p_tz, ''), 'Asia/Seoul') as x) q
$$;
revoke all on function lms_mail_en_when(timestamptz, text) from public, anon, authenticated;

-- 'Toronto Time' · 'Korea Time (KST)'
create or replace function lms_mail_en_zone(p_tz text) returns text
language sql immutable as $$
  select case when coalesce(nullif(p_tz, ''), 'Asia/Seoul') = 'Asia/Seoul' then 'Korea Time (KST)'
              else replace(split_part(p_tz, '/', array_length(string_to_array(p_tz, '/'), 1)), '_', ' ') || ' Time' end
$$;
revoke all on function lms_mail_en_zone(text) from public, anon, authenticated;

-- 'Wed 12 Nov 19:00 Toronto Time (Thu 13 Nov 09:00 KST)' / 한국 강사: 'Thu 13 Nov 09:00 KST'
create or replace function lms_mail_en_at(p_at timestamptz, p_tz text) returns text
language sql stable as $$
  select case when coalesce(nullif(p_tz, ''), 'Asia/Seoul') = 'Asia/Seoul' then lms_mail_en_when(p_at, 'Asia/Seoul') || ' KST'
              else lms_mail_en_when(p_at, p_tz) || ' ' || lms_mail_en_zone(p_tz) || ' (' || lms_mail_en_when(p_at, 'Asia/Seoul') || ' KST)' end
$$;
revoke all on function lms_mail_en_at(timestamptz, text) from public, anon, authenticated;

-- LMS 주소: 이 DB 가 운영(edgeenglish-lms)이면 운영 화면, 아니면 시험 화면 (lms_backup.project 이름으로 판단)
create or replace function lms_url() returns text
language sql stable security definer set search_path = public as $$
  select case when (select name from lms_backup.project limit 1) = 'edgeenglish-lms'
              then 'https://edge-english-git-lms-prod-support-2126.vercel.app/lms'
              else 'https://edge-english-git-lms-test-support-2126.vercel.app/lms' end
$$;
revoke all on function lms_url() from public, anon, authenticated;

-- 받는 사람 주소: 표의 이메일 → 없으면 로그인 이메일 (auth.users 가 없는 로컬 시험 DB 에서도 동작)
create or replace function lms_notice_recipient_email(p_kind text, p_id uuid) returns text
language plpgsql stable security definer set search_path = public as $$
declare
  v text;
begin
  if p_kind = 'student' then select nullif(trim(email), '') into v from students where id = p_id;
  else select nullif(trim(email), '') into v from tutors where id = p_id; end if;
  if v is null and to_regclass('auth.users') is not null then
    execute format('select lower(a.email) from app_users u join auth.users a on a.id = u.auth_user_id where u.%I = $1 and a.email is not null limit 1',
                   case when p_kind = 'student' then 'student_id' else 'tutor_id' end) into v using p_id;
  end if;
  return lower(v);
end $$;
revoke all on function lms_notice_recipient_email(text, uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- 보강 확정 메일 내용 (안내 1건 → 제목·HTML·본문). 다른 안내 유형은 null
-- ---------------------------------------------------------------------
create or replace function lms_notice_mail(p_notice uuid)
returns table (intended_email text, to_email text, subject text, html text, body text)
language plpgsql stable security definer set search_path = public as $$
declare
  n lesson_notices;
  r makeup_requests;
  l lessons;
  st students;
  tu tutors;
  src lessons;
  v_live boolean := coalesce((select f.enabled from feature_flags f where f.key = 'send_emails'), false);
  v_comp boolean;
  v_origin_date date;
  v_minutes integer;
  v_origin text;
  v_when text;
  v_lines text[];
  v_url text := lms_url();
  v_btn text;
  v_foot text;
  v_test text := '';
begin
  select * into n from lesson_notices where id = p_notice;
  if not found or n.event <> 'makeup_confirmed' or n.makeup_request_id is null then return; end if;
  select * into r from makeup_requests where id = n.makeup_request_id;
  if r.confirmed_lesson_id is null then return; end if;
  select * into l from lessons where id = r.confirmed_lesson_id;
  select * into st from students where id = l.student_id;
  select * into tu from tutors where id = l.tutor_id;
  v_comp := r.compensation_id is not null;
  v_minutes := round(extract(epoch from l.ends_at - l.starts_at) / 60)::int;
  if r.source_lesson_id is not null then select * into src from lessons where id = r.source_lesson_id; end if;
  if v_comp and src.id is null then
    select x.* into src from compensations c join lessons x on x.id = c.lesson_id where c.id = r.compensation_id;
  end if;
  if src.id is null and r.migrated_item_id is not null then select original_date into v_origin_date from migrated_items where id = r.migrated_item_id; end if;

  intended_email := lms_notice_recipient_email(n.recipient_kind, n.recipient_id);
  to_email := case when v_live then intended_email else 'support@edgeenglish.kr' end;
  if not v_live then v_test := '[시험 · ' || st.code || '] '; end if;

  if n.recipient_kind = 'student' then
    v_when := lms_mail_ko_at(l.starts_at, st.timezone);
    v_origin := case when src.id is not null then lms_mail_ko_at(src.starts_at, st.timezone)
                     when v_origin_date is not null then extract(month from v_origin_date)::int || '월 ' || extract(day from v_origin_date)::int || '일'
                     else '시트 기록 보강' end;
    subject := v_test || '[엣지영어] ' || case when v_comp then '무료 보상수업이 확정됐어요' else '보강이 확정됐어요' end
               || ' · ' || lms_mail_ko_when(l.starts_at, st.timezone);
    v_lines := array[
      '[엣지영어] ' || st.name_ko || '님, ' || case when v_comp then '무료 보상수업이 확정됐어요' else '보강이 확정됐어요' end,
      case when v_comp then '강사 노쇼 수업: ' else '원래 수업: ' end || v_origin,
      case when v_comp then '보상수업: ' else '보강 수업: ' end || v_when || ' (' || v_minutes || '분)',
      '강사: ' || tu.name];
    v_btn := 'LMS에서 일정 보기';
    v_foot := '문의: 카카오톡 채널 엣지영어';
    v_url := v_url || '/student';
  else
    v_when := lms_mail_en_at(l.starts_at, tu.timezone);
    v_origin := case when src.id is not null then lms_mail_en_at(src.starts_at, tu.timezone)
                     when v_origin_date is not null then to_char(v_origin_date, 'YYYY-MM-DD') else 'earlier class' end;
    subject := v_test || 'CONFIRMED ' || case when v_comp then 'compensation class' else 'make-up' end || ' - ' || coalesce(nullif(st.name_en, ''), st.name_ko)
               || ' · ' || lms_mail_en_when(l.starts_at, tu.timezone) || ' ' || lms_mail_en_zone(tu.timezone);
    v_lines := array[
      'CONFIRMED ' || case when v_comp then 'compensation class' else 'make-up' end || ' - ' || coalesce(nullif(st.name_en, ''), st.name_ko) || ' (' || v_minutes || ' min)',
      'Original class: ' || v_origin,
      case when v_comp then 'Compensation class: ' else 'Make-up: ' end || v_when,
      'Please add it to your schedule. Thank you!'];
    v_btn := 'Open Edge English LMS';
    v_foot := 'Reply to this email or message us on WhatsApp if you have a question.';
    v_url := v_url || '/tutor';
  end if;

  body := array_to_string(v_lines, E'\n') || E'\n\n' || v_btn || ': ' || v_url || E'\n' || v_foot
          || case when v_live then '' else E'\n\n(시험 발송 · 원래 받는 사람: ' || coalesce(intended_email, '없음') || ')' end;
  html := '<div style="font-family:sans-serif;font-size:15px;line-height:1.6;color:#1d1b2a;max-width:480px">'
          || case when v_live then '' else '<p style="background:#fff4d6;color:#5c3b00;border-radius:8px;padding:8px 10px;font-size:13px;font-weight:600">시험 발송 · 원래 받는 사람: ' || lms_html(coalesce(intended_email, '없음')) || '</p>' end
          || '<p style="font-weight:700">' || lms_html(v_lines[1]) || '</p>'
          || '<p>' || lms_html(v_lines[2]) || '<br><b>' || lms_html(v_lines[3]) || '</b><br>' || lms_html(v_lines[4]) || '</p>'
          || '<p><a href="' || lms_html(v_url) || '" style="display:inline-block;background:#5b3df0;color:#fff;border-radius:10px;padding:11px 18px;font-weight:700;text-decoration:none">' || lms_html(v_btn) || '</a></p>'
          || '<p style="font-size:12.5px;color:#55526a;border-top:1px solid #e6e3ef;padding-top:10px">' || lms_html(v_foot) || '</p></div>';
  return next;
end $$;
revoke all on function lms_notice_mail(uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- 보내기: 큐의 메일 1통을 pg_net 으로 Resend 에 (키·pg_net 이 없으면 큐에 그대로, 사유 기록)
-- ---------------------------------------------------------------------
create or replace function lms_mail_dispatch(p_notification uuid) returns boolean
language plpgsql security definer set search_path = public as $$
declare
  x notifications;
  v_key text;
  v_req bigint;
  v_has_net boolean := exists (select 1 from pg_proc p join pg_namespace s on s.oid = p.pronamespace where s.nspname = 'net' and p.proname = 'http_post');
  v_note text;
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
                             'html', x.payload ->> 'html', 'text', x.payload ->> 'text'),
          jsonb_build_object('Authorization', 'Bearer ' || trim(v_key), 'Content-Type', 'application/json',
                             -- 같은 메일을 두 번 보내지 않음. [다시 보내기]는 시도 번호가 붙어 새 요청으로
                             'Idempotency-Key', x.dedupe_key || case when x.attempts > 0 then ':' || x.attempts else '' end);
  update notifications set net_request_id = v_req, attempts = attempts + 1, last_error = null where id = x.id;
  update lesson_notices set email_attempts = email_attempts + 1, email_error = null where email_notification_id = x.id;
  return true;
end $$;
revoke all on function lms_mail_dispatch(uuid) from public, anon, authenticated;

-- 안내 1건 → 메일 큐에 (dedupe_key 로 한 번만) → 바로 보내기 시도
create or replace function lms_mail_enqueue_notice(p_notice uuid) returns void
language plpgsql security definer set search_path = public as $$
declare
  m record;
  n lesson_notices;
  v_id uuid;
begin
  select * into n from lesson_notices where id = p_notice;
  if not found or n.email_notification_id is not null then return; end if;
  select * into m from lms_notice_mail(p_notice);
  if m is null or m.subject is null then return; end if;
  if m.intended_email is null then
    update lesson_notices set email_status = 'no_address', email_queued_at = now(),
           email_error = case when n.recipient_kind = 'student' then '학생 이메일이 없어요 (학생 상세 › 프로필 또는 로그인 계정)' else '강사 이메일이 없어요' end
    where id = p_notice;
    return;
  end if;
  insert into notifications (recipient_kind, recipient_id, email, locale, template, payload, dedupe_key)
  values (n.recipient_kind, n.recipient_id, m.to_email, case when n.recipient_kind = 'student' then 'ko' else 'en' end, 'lesson_notice_' || n.event,
          jsonb_build_object('notice_id', n.id, 'intended_email', m.intended_email, 'subject', m.subject, 'html', m.html, 'text', m.body),
          'lesson_notice_email:' || n.id)
  on conflict (dedupe_key) do nothing
  returning id into v_id;
  if v_id is null then select id into v_id from notifications where dedupe_key = 'lesson_notice_email:' || n.id; end if;
  update lesson_notices set email_status = 'queued', email_to = m.to_email, email_intended = m.intended_email, email_queued_at = now(),
         email_error = null, email_notification_id = v_id where id = p_notice;
  perform lms_mail_dispatch(v_id);
end $$;
revoke all on function lms_mail_enqueue_notice(uuid) from public, anon, authenticated;

-- 안내 줄이 생기면 같은 트랜잭션에서 메일 큐에 (보강 확정만)
create or replace function lesson_notices_email() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.event = 'makeup_confirmed' then perform lms_mail_enqueue_notice(new.id); end if;
  return null;
end $$;
revoke all on function lesson_notices_email() from public, anon, authenticated;
drop trigger if exists lesson_notices_email on lesson_notices;
create trigger lesson_notices_email after insert on lesson_notices for each row execute function lesson_notices_email();

-- ---------------------------------------------------------------------
-- 결과 맞추기 + 못 보낸 것 다시 시도 (운영진 화면이 부름 · 나중에 예약 실행도 같은 함수)
--  ① 보낸 요청의 응답(net._http_response)을 보고 보냄/실패 기록 ② 키가 없어 못 보낸 큐 메일 다시 시도
-- ---------------------------------------------------------------------
create or replace function lms_mail_run() returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_sent integer := 0;
  v_failed integer := 0;
  v_tried integer := 0;
  x record;
begin
  if to_regclass('net._http_response') is not null then
    for x in execute $q$
      select n.id, h.status_code, h.created, left(coalesce(h.status_code::text || ' ', '') || coalesce(h.error_msg, h.content::text, ''), 500) as err
      from notifications n join net._http_response h on h.id = n.net_request_id
      where n.status = 'queued' and n.net_request_id is not null$q$
    loop
      if x.status_code between 200 and 299 then
        update notifications set status = 'sent', sent_at = coalesce(x.created, now()), last_error = null where id = x.id;
        update lesson_notices set email_status = 'sent', email_sent_at = coalesce(x.created, now()), email_error = null where email_notification_id = x.id;
        v_sent := v_sent + 1;
      else
        update notifications set status = 'failed', last_error = x.err where id = x.id;
        update lesson_notices set email_status = 'failed', email_error = coalesce(nullif(x.err, ''), '발송 서비스 오류') where email_notification_id = x.id;
        v_failed := v_failed + 1;
      end if;
    end loop;
  end if;
  for x in select id from notifications where status = 'queued' and net_request_id is null and template like 'lesson_notice_%' order by created_at loop
    if lms_mail_dispatch(x.id) then v_tried := v_tried + 1; end if;
  end loop;
  return jsonb_build_object('sent', v_sent, 'failed', v_failed, 'tried', v_tried);
end $$;
revoke all on function lms_mail_run() from public, anon, authenticated;

create or replace function admin_mail_sync() returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception '운영자만 볼 수 있습니다.' using errcode = '42501'; end if;
  return lms_mail_run();
end $$;
revoke all on function admin_mail_sync() from public, anon;
grant execute on function admin_mail_sync() to authenticated;

-- 실패·주소 없음인 안내를 다시 보냄 (주소를 다시 찾고, 시도 번호를 붙여 새 요청으로)
create or replace function admin_resend_notice_email(p_notice uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  n lesson_notices;
  m record;
begin
  if not is_admin() then raise exception '운영자(추가 인증 완료)만 처리할 수 있습니다.' using errcode = '42501'; end if;
  select * into n from lesson_notices where id = p_notice for update;
  if not found then raise exception '안내가 없습니다.'; end if;
  perform lms_mail_run();
  select * into n from lesson_notices where id = p_notice;
  if n.email_status = 'sent' then return jsonb_build_object('status', 'sent', 'repeated', true); end if;
  if n.email_status = 'queued' and n.email_notification_id is not null and exists (select 1 from notifications where id = n.email_notification_id and net_request_id is not null) then
    return jsonb_build_object('status', 'queued', 'repeated', true);   -- 보냈고 응답 대기 중 → 두 번 안 보냄
  end if;
  perform set_config('app.actor_id', auth.uid()::text, true);
  perform set_config('app.actor_via', 'admin_resend_notice_email', true);
  if n.email_notification_id is null then
    update lesson_notices set email_status = null, email_error = null where id = p_notice;   -- 주소 없음 → 주소 다시 찾기
    perform lms_mail_enqueue_notice(p_notice);
  else
    select * into m from lms_notice_mail(p_notice);
    if m.intended_email is null then
      update lesson_notices set email_status = 'no_address', email_error = '이메일이 없어요' where id = p_notice;
    else
      update notifications set status = 'queued', net_request_id = null, email = m.to_email,
             payload = payload || jsonb_build_object('intended_email', m.intended_email, 'subject', m.subject, 'html', m.html, 'text', m.body)
      where id = n.email_notification_id;
      update lesson_notices set email_status = 'queued', email_to = m.to_email, email_intended = m.intended_email, email_error = null where id = p_notice;
      perform lms_mail_dispatch(n.email_notification_id);
    end if;
  end if;
  select * into n from lesson_notices where id = p_notice;
  return jsonb_build_object('status', n.email_status, 'error', n.email_error, 'to', n.email_to, 'repeated', false);
end $$;
revoke all on function admin_resend_notice_email(uuid) from public, anon;
grant execute on function admin_resend_notice_email(uuid) to authenticated;

-- ---------------------------------------------------------------------
-- 보강 확정: 강사가 직접 확정해도 강사 안내 줄을 만들어 자동 메일이 가게 (대표 2026-11-07 '학생·강사 양쪽').
-- 강사가 직접 확정했으면 WhatsApp 복사 안내는 필요 없음(status not_needed, H26(82)) — 메일만 자동으로.
-- 나머지 본문은 20261108000000 과 같음
-- ---------------------------------------------------------------------
create or replace function lms_makeup_book(p_makeup_request uuid, p_starts_at timestamptz, p_via text, p_by_tutor boolean)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  r makeup_requests;
  s record;
  c record;
  e enrollments;
  v_end timestamptz;
  v_lesson uuid;
  v_conf text;
  v_enr uuid;
begin
  select * into r from makeup_requests where id = p_makeup_request for update;
  if not found then raise exception '보강 신청이 없습니다.'; end if;
  if r.status = 'confirmed' then return jsonb_build_object('makeup_request_id', r.id, 'lesson_id', r.confirmed_lesson_id, 'repeated', true); end if;
  if r.status not in ('requested', 'countered') then raise exception '이미 닫힌 보강 신청입니다.'; end if;
  if p_starts_at <= now() then raise exception '지난 시간은 보강으로 넣을 수 없습니다.'; end if;
  -- 강사가 불가라고 답한 시간 (QA-01 D, 4500)
  if exists (select 1 from makeup_candidates x where x.request_id = r.id and x.starts_at = p_starts_at and x.proposed_by = 'student' and x.tutor_answer = 'no') then
    raise exception '강사가 불가라고 답한 시간입니다. 다른 시간을 고르거나 학생에게 다시 날짜를 받아 주세요.' using hint = 'tutor_no';
  end if;

  if r.compensation_id is not null then
    perform 1 from compensations where id = r.compensation_id for update;   -- 같은 보상권 두 번 쓰기 막기
    select * into c from lms_comp_source(r.compensation_id);
    if p_starts_at >= ((c.use_until + 1)::timestamp at time zone 'Asia/Seoul') then
      raise exception '보상수업 사용 기한(%) 뒤의 시간입니다.', c.use_until using hint = 'after_end';
    end if;
    select * into e from enrollments where id = c.enrollment_id;
    v_end := p_starts_at + make_interval(mins => e.duration_min);
    v_conf := lms_makeup_conflict(r.tutor_id, c.student_id, p_starts_at, v_end,
                exists (select 1 from makeup_candidates x where x.request_id = r.id and x.starts_at = p_starts_at and x.proposed_by = 'student'));
    if v_conf is not null then raise exception '%', lms_conflict_message(v_conf) using hint = 'schedule_conflict', detail = lms_conflict_code(v_conf); end if;
    v_enr := lms_comp_lesson_enrollment(r.compensation_id, (p_starts_at at time zone 'Asia/Seoul')::date);
    perform set_config('app.actor_id', me::text, true);
    perform set_config('app.actor_via', p_via, true);
    if not exists (select 1 from makeup_candidates where request_id = r.id and starts_at = p_starts_at) then
      insert into makeup_candidates (request_id, starts_at, ends_at, proposed_by) values (r.id, p_starts_at, v_end, 'tutor');
    end if;
    begin
      insert into lessons (enrollment_id, student_id, tutor_id, kind, starts_at, ends_at, compensation_id, created_by)
      values (v_enr, c.student_id, r.tutor_id, 'compensation', p_starts_at, v_end, r.compensation_id, me)
      returning id into v_lesson;
    exception when exclusion_violation then
      raise exception '그 시간에 학생 또는 강사의 다른 수업이 있습니다.' using hint = 'schedule_conflict';
    end;
    update compensations set status = 'used', used_lesson_id = v_lesson where id = r.compensation_id;
  else
    select * into s from lms_makeup_source(r.source_lesson_id, r.migrated_item_id);
    select * into e from enrollments where id = s.enrollment_id;
    if not s.tutor_leave and p_starts_at >= ((e.final_end_date + 1)::timestamp at time zone 'Asia/Seoul') then
      raise exception '수강 종료일(%) 뒤의 시간입니다.', e.final_end_date using hint = 'after_end';
    end if;
    v_end := p_starts_at + make_interval(mins => e.duration_min);
    v_conf := lms_makeup_conflict(r.tutor_id, s.student_id, p_starts_at, v_end,
                exists (select 1 from makeup_candidates x where x.request_id = r.id and x.starts_at = p_starts_at and x.proposed_by = 'student'));
    if v_conf is not null then raise exception '%', lms_conflict_message(v_conf) using hint = 'schedule_conflict', detail = lms_conflict_code(v_conf); end if;

    perform set_config('app.actor_id', me::text, true);
    perform set_config('app.actor_via', p_via, true);
    if not exists (select 1 from makeup_candidates where request_id = r.id and starts_at = p_starts_at) then
      insert into makeup_candidates (request_id, starts_at, ends_at, proposed_by) values (r.id, p_starts_at, v_end, 'tutor');
    end if;
    begin
      insert into lessons (enrollment_id, student_id, tutor_id, kind, starts_at, ends_at, makeup_of, created_by)
      values (s.enrollment_id, s.student_id, r.tutor_id,
              case when r.source_lesson_id is null then 'migrated_makeup' else 'makeup' end,
              p_starts_at, v_end, r.source_lesson_id, me)
      returning id into v_lesson;
    exception when exclusion_violation then
      raise exception '그 시간에 학생 또는 강사의 다른 수업이 있습니다.' using hint = 'schedule_conflict';
    end;
    if r.migrated_item_id is not null then
      update migrated_items set kind = 'makeup_booked', lesson_id = v_lesson where id = r.migrated_item_id;
      -- R-18 (4520): 이관권이 수업에 연결된 뒤 휴무 자동 연장 재계산
      perform lms_leave_sync_extension(s.enrollment_id);
    end if;
  end if;
  update makeup_requests set status = 'confirmed', confirmed_lesson_id = v_lesson, decided_at = now(), decided_by = me,
         confirmed_in_tutor_screen = p_by_tutor where id = r.id;
  update lesson_notices set status = 'not_needed' where makeup_request_id = r.id and event = 'makeup_ask' and status = 'pending';
  -- 학생·강사 확정 안내 (자동 메일은 트리거). 카톡 복사는 운영진 차례, 강사가 직접 확정했으면 WhatsApp 복사는 필요 없음
  insert into lesson_notices (makeup_request_id, event, recipient_kind, recipient_id) values (r.id, 'makeup_confirmed', 'student', r.student_id);
  insert into lesson_notices (makeup_request_id, event, recipient_kind, recipient_id, status)
  values (r.id, 'makeup_confirmed', 'tutor', r.tutor_id, case when p_by_tutor then 'not_needed' else 'pending' end);
  return jsonb_build_object('makeup_request_id', r.id, 'lesson_id', v_lesson, 'repeated', false);
end $$;
revoke all on function lms_makeup_book(uuid, timestamptz, text, boolean) from public, anon, authenticated;
