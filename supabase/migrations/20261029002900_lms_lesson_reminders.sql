-- =====================================================================
-- 학생 수업 알림 메일 (POL-OP-18 변경, 2026-10-29 대표 확정)
--  - 정규·보강 모두 기본 켬, 수업 24시간 전 1번 + 2시간 전 1번 (시간 고정)
--  - 학생이 정규·보강을 따로 켬/끔 (정규 = 정규 수업, 보강 = 그 밖의 수업: 보강·보상·이월)
--  - 대체강사 수업이면 '대체강사 수업이에요. 수업 링크가 달라요.' + 대체강사 링크
--  - 시작 시각을 24시간(2시간) 안에 정한 수업은 그 알림을 건너뜀 · 취소된 수업은 안 보냄
--    · 시간이 바뀌면 새 시간으로 다시 (같은 수업·같은 시각·같은 알림은 한 번만: notifications.dedupe_key)
--  - 보내기: Supabase 예약 실행(pg_cron)이 lms_send_lesson_reminders() 를 주기적으로 부름 → pg_net 으로 Resend API
--    Resend 키는 Supabase Vault 'resend_api_key' (키는 Supabase 화면에만). 키가 없으면 아무것도 안 보냄
--  - feature_flags.send_emails 가 꺼져 있으면 모두 support@edgeenglish.kr 로만 감 (시험)
-- 기존 표·데이터를 지우지 않음. 다시 실행해도 같은 결과
-- =====================================================================

alter table students add column if not exists remind_regular boolean not null default true;
alter table students add column if not exists remind_makeup boolean not null default true;

-- 수업 시작 시각을 정한 때 (비어 있으면 이 기능 전부터 있던 수업)
alter table lessons add column if not exists time_set_at timestamptz;
alter table lessons alter column time_set_at set default now();

create or replace function lessons_time_set_at() returns trigger
language plpgsql as $$
begin
  if tg_op = 'INSERT' or new.starts_at is distinct from old.starts_at then new.time_set_at := now(); end if;
  return new;
end $$;
drop trigger if exists lessons_time_set_at on lessons;
create trigger lessons_time_set_at before insert or update of starts_at on lessons
  for each row execute function lessons_time_set_at();
revoke all on function lessons_time_set_at() from public, anon, authenticated;

alter table notifications add column if not exists net_request_id bigint;

-- ---------------------------------------------------------------------
-- 글자 도우미
-- ---------------------------------------------------------------------
create or replace function lms_html(p text) returns text
language sql immutable as $$
  select replace(replace(replace(replace(coalesce(p, ''), '&', '&amp;'), '<', '&lt;'), '>', '&gt;'), '"', '&quot;')
$$;
revoke all on function lms_html(text) from public, anon, authenticated;

-- 10/30(금) 오후 8:00
create or replace function lms_ko_when(p_at timestamptz, p_tz text) returns text
language sql stable as $$
  select to_char(x, 'FMMM/FMDD') || '(' || (array['일', '월', '화', '수', '목', '금', '토'])[extract(dow from x)::int + 1] || ') '
         || case when extract(hour from x) < 12 then '오전 ' else '오후 ' end
         || (case when extract(hour from x)::int % 12 = 0 then 12 else extract(hour from x)::int % 12 end) || ':' || to_char(x, 'MI')
  from (select p_at at time zone p_tz as x) q
$$;
revoke all on function lms_ko_when(timestamptz, text) from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- 지금 보낼 알림 (보내지는 않음 — 시험에서 그대로 확인)
-- ---------------------------------------------------------------------
create or replace function lms_lesson_reminders_due(p_now timestamptz default now())
returns table (dedupe_key text, student_id uuid, lesson_id uuid, which text, to_email text, intended_email text, subject text, html text)
language sql stable security definer set search_path = public as $$
  with c as (
    select l.*, s.name_ko, s.email as s_email, s.timezone as s_tz, s.city as s_city, s.code as s_code,
           t.name as tutor_name, t.meet_url,
           case when p_now >= l.starts_at - interval '2 hours' then '2h' else '24h' end as which,
           round(extract(epoch from l.ends_at - l.starts_at) / 60)::int as minutes
    from lessons l
    join students s on s.id = l.student_id
    join tutors t on t.id = l.tutor_id
    where l.state = 'scheduled' and l.voided_at is null
      and l.starts_at > p_now and l.starts_at <= p_now + interval '24 hours'
      and case when l.kind = 'regular' then s.remind_regular else s.remind_makeup end
      and nullif(trim(s.email), '') is not null
  ), d as (
    select c.*,
           'lesson_reminder:' || c.id || ':' || to_char(c.starts_at at time zone 'UTC', 'YYYYMMDD"T"HH24MI') || ':' || c.which as key,
           coalesce((select f.enabled from feature_flags f where f.key = 'send_emails'), false) as live,
           lms_ko_when(c.starts_at, 'Asia/Seoul') as kst,
           case when c.kind = 'regular' then '수업' else '보강 수업' end as kind_label,
           c.original_tutor_id is not null as sub
    from c
    -- 시작 시각을 알림 시점 뒤에 정했으면 그 알림은 건너뜀
    where coalesce(c.time_set_at, '-infinity') <= c.starts_at - case when c.which = '2h' then interval '2 hours' else interval '24 hours' end
  )
  select d.key, d.student_id, d.id, d.which,
         case when d.live then trim(d.s_email) else 'support@edgeenglish.kr' end,
         trim(d.s_email),
         case when d.live then '' else '[시험 · ' || d.s_code || '] ' end
           || '[엣지영어] ' || d.kst || ' ' || d.kind_label || case when d.sub then ' · 대체강사' else '' end,
         '<div style="font-family:sans-serif;font-size:15px;line-height:1.6;color:#1d1b2a;max-width:480px">'
         || '<p>' || lms_html(d.name_ko) || '님, ' || d.kind_label || ' 안내드려요.</p>'
         || case when d.sub then '<p style="background:#fff6dd;color:#7a5200;border-radius:8px;padding:9px 11px;font-weight:600">대체강사 수업이에요. 수업 링크가 달라요.</p>' else '' end
         || '<p><span style="color:#55526a">일시</span>&nbsp; <b>' || d.kst || ' (' || d.minutes || '분)'
         || case when d.s_tz <> 'Asia/Seoul'
                 then ' 한국 시간<br>' || lms_ko_when(d.starts_at, d.s_tz) || ' ' || lms_html(coalesce(nullif(trim(d.s_city), ''), d.s_tz))
                 else '' end || '</b><br>'
         || '<span style="color:#55526a">강사</span>&nbsp; <b>' || lms_html(d.tutor_name) || case when d.sub then ' (대체강사)' else '' end || '</b></p>'
         || case when nullif(trim(d.meet_url), '') is null then ''
                 else '<p><a href="' || lms_html(trim(d.meet_url)) || '" style="display:inline-block;background:#5b3df0;color:#fff;border-radius:10px;padding:11px 18px;font-weight:700;text-decoration:none">'
                      || case when d.sub then lms_html(d.tutor_name) || ' 강사님 수업 들어가기' else '수업 들어가기 (Google Meet)' end || '</a></p>' end
         || '<p style="font-size:12px;color:#55526a">알림 끄기: 엣지영어 LMS › 내 정보 › 수업 알림 메일</p></div>'
  from d
  where not exists (select 1 from notifications n where n.dedupe_key = d.key)
  order by d.starts_at
$$;
revoke all on function lms_lesson_reminders_due(timestamptz) from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- 보내기 (예약 실행이 부름): ① 지난번에 보낸 것의 결과 기록 ② 지금 보낼 것을 Resend 로
-- ---------------------------------------------------------------------
create or replace function lms_send_lesson_reminders() returns integer
language plpgsql security definer set search_path = public as $$
declare
  v_key text;
  r record;
  v_id uuid;
  v_req bigint;
  n integer := 0;
begin
  update notifications x
  set status = case when h.status_code between 200 and 299 then 'sent' else 'failed' end,
      sent_at = case when h.status_code between 200 and 299 then h.created end,
      last_error = case when h.status_code between 200 and 299 then null
                        else left(coalesce(h.status_code::text || ' ', '') || coalesce(h.error_msg, h.content::text, ''), 500) end
  from net._http_response h
  where x.net_request_id = h.id and x.status = 'queued';

  select decrypted_secret into v_key from vault.decrypted_secrets where name = 'resend_api_key';
  if nullif(trim(v_key), '') is null then return 0; end if;

  for r in select * from lms_lesson_reminders_due(now()) loop
    insert into notifications (recipient_kind, recipient_id, email, locale, template, payload, dedupe_key)
    values ('student', r.student_id, r.to_email, 'ko', 'lesson_reminder_' || r.which,
            jsonb_build_object('lesson_id', r.lesson_id, 'intended_email', r.intended_email, 'subject', r.subject), r.dedupe_key)
    on conflict (dedupe_key) do nothing
    returning id into v_id;
    continue when v_id is null;
    v_req := net.http_post(
      url := 'https://api.resend.com/emails',
      body := jsonb_build_object('from', '엣지영어 <support@edgeenglish.kr>', 'to', jsonb_build_array(r.to_email),
                                 'subject', r.subject, 'html', r.html),
      headers := jsonb_build_object('Authorization', 'Bearer ' || trim(v_key), 'Content-Type', 'application/json',
                                    'Idempotency-Key', r.dedupe_key));
    update notifications set net_request_id = v_req, attempts = attempts + 1 where id = v_id;
    n := n + 1;
  end loop;
  return n;
end $$;
revoke all on function lms_send_lesson_reminders() from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- 학생 알림 설정: 읽기(둘 다 null) · 바꾸기. 학생 본인 또는 운영자(?student=)
-- ---------------------------------------------------------------------
create or replace function student_reminders(p_student uuid, p_regular boolean default null, p_makeup boolean default null)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_student uuid := lms_screen_student(p_student);
  st students;
begin
  if p_regular is not null or p_makeup is not null then
    perform set_config('app.actor_id', auth.uid()::text, true);
    perform set_config('app.actor_via', case when is_admin() then 'admin_for_student' else 'student' end, true);
    update students set remind_regular = coalesce(p_regular, remind_regular), remind_makeup = coalesce(p_makeup, remind_makeup)
    where id = v_student;
  end if;
  select * into st from students where id = v_student;
  return jsonb_build_object('regular', st.remind_regular, 'makeup', st.remind_makeup, 'has_email', nullif(trim(st.email), '') is not null);
end $$;
revoke all on function student_reminders(uuid, boolean, boolean) from public, anon;
grant execute on function student_reminders(uuid, boolean, boolean) to authenticated;
