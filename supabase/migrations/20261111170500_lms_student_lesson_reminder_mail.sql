-- 학생 수업 리마인더 메일 (11/11 대표 확정: 정규·보강 모두 수업 24시간 전·2시간 전, '내 정보' 이메일 알림 설정과 연동)
--  - 2900(lms_send_lesson_reminders 직접 발송)은 쓰지 않고, 지금 자동 메일 구조를 그대로 씀:
--    notifications 대기열(dedupe_key 로 한 번만) → lms_mail_dispatch → lms_mail_run(예약 실행) 결과 기록, 실패는 기존처럼 failed + 운영진 다시 보내기
--  - 받는 주소 = 자동 안내와 같은 기준(lms_notice_recipient_email). send_emails 꺼짐(시험) = support@ 로만 + 제목 '[시험 · 학생 번호]'
--  - 정규 수업 = remind_regular, 보강·보상·이월 보강 = remind_makeup (학생이 끄면 아직 안 보낸 알림은 안 감: 보낼 때 확인)
--  - 취소·무효 수업 제외, 시간이 바뀌면 바뀐 시각 기준(dedupe_key 에 시작 시각), 휴무 처리 확정 전 수업 제외,
--    알림 시점 뒤에 시각을 정한 수업은 그 알림 건너뜀(time_set_at), 알림 시점에서 1시간 넘게 지나면 늦은 알림 안 보냄
--  - 시각은 다른 학생 자동 메일과 같은 모양(lms_mail_ko_at): '11월 12일(목) 오후 12시 30분 [시드니 시간] / 오전 10시 30분 [한국 시간]'
--  - 시작 조건: feature_flags 'lesson_reminder_since' 가 있을 때만 (시험 DB 에만 넣음, 운영은 별도 승인)
--  - 강사 알림은 바꾸지 않음
alter table students add column if not exists remind_regular boolean not null default true;
alter table students add column if not exists remind_makeup boolean not null default true;

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

create or replace function lms_lesson_reminder_mail(l lessons, p_which text) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_live boolean := coalesce((select x.enabled from feature_flags x where x.key = 'send_emails'), false);
  st students;
  tu tutors;
  v_tz text;
  v_intended text;
  v_to text;
  v_sub boolean := l.original_tutor_id is not null;
  v_kind text := case when l.kind = 'regular' then '수업' else '보강 수업' end;
  v_min int := round(extract(epoch from l.ends_at - l.starts_at) / 60)::int;
  v_when text;
  v_url text;
  v_btn text := '수업 입장하기';
  v_p1 text;
  v_p2 text;
  v_subject text;
  v_off text := '알림 끄기: 엣지영어 LMS › 내 정보 › 이메일 알림 설정';
  v_foot text := '문의: 카카오톡 채널 엣지영어';
  v_html text;
  v_body text;
  v_key text := 'lesson_reminder:' || l.id || ':' || to_char(l.starts_at at time zone 'UTC', 'YYYYMMDD"T"HH24MI') || ':' || p_which;
  v_id uuid;
begin
  select * into st from students where id = l.student_id;
  select * into tu from tutors where id = l.tutor_id;
  v_intended := lms_notice_recipient_email('student', st.id);
  if v_intended is null then return null; end if;
  v_to := case when v_live then v_intended else 'support@edgeenglish.kr' end;
  v_tz := coalesce(nullif(st.timezone, ''), 'Asia/Seoul');
  v_when := lms_mail_ko_at(l.starts_at, v_tz);
  v_url := coalesce(nullif(trim(tu.meet_url), ''), lms_url() || '/student');
  v_subject := case when v_live then '' else '[시험 · ' || st.code || '] ' end
               || '[엣지영어] ' || v_kind || ' 안내' || case when v_sub then ' (대체강사)' else '' end || ' · ' || split_part(v_when, ' / ', 1);
  v_p1 := st.name_ko || '님, ' || v_kind || ' 안내드려요.';
  v_p2 := '일시: ' || v_when || ' (' || v_min || '분)' || E'\n' || '강사: ' || tu.name || case when v_sub then ' (대체강사)' else '' end;
  v_body := v_p1 || E'\n\n' || case when v_sub then '대체강사 수업이에요. 수업 링크가 달라요.' || E'\n\n' else '' end
            || v_p2 || E'\n\n' || v_btn || ': ' || v_url || E'\n\n'
            || v_off || E'\n' || v_foot
            || case when v_live then '' else E'\n\n(시험 발송 · 원래 받는 사람: ' || v_intended || ')' end;
  v_html := '<div style="font-family:sans-serif;font-size:15px;line-height:1.6;color:#1d1b2a;max-width:480px">'
            || case when v_live then '' else '<p style="background:#fff4d6;color:#5c3b00;border-radius:8px;padding:8px 10px;font-size:13px;font-weight:600">시험 발송 · 원래 받는 사람: ' || lms_html(v_intended) || '</p>' end
            || '<p>' || lms_html(v_p1) || '</p>'
            || case when v_sub then '<p style="background:#fff6dd;color:#7a5200;border-radius:8px;padding:9px 11px;font-weight:600">대체강사 수업이에요. 수업 링크가 달라요.</p>' else '' end
            || '<p style="font-weight:700">' || replace(lms_html(v_p2), E'\n', '<br>') || '</p>'
            || '<p><a href="' || lms_html(v_url) || '" style="display:inline-block;background:#5b3df0;color:#fff;border-radius:10px;padding:11px 18px;font-weight:700;text-decoration:none">' || lms_html(v_btn) || '</a></p>'
            || '<p style="font-size:12.5px;color:#55526a;border-top:1px solid #e6e3ef;padding-top:10px">' || lms_html(v_off) || '<br>' || lms_html(v_foot) || '</p></div>';
  insert into notifications (recipient_kind, recipient_id, email, locale, template, payload, dedupe_key)
  values ('student', st.id, v_to, 'ko', 'lesson_reminder_' || p_which,
          jsonb_build_object('intended_email', v_intended, 'subject', v_subject, 'html', v_html, 'text', v_body,
                             'lesson_id', l.id, 'starts_at', l.starts_at, 'which', p_which),
          v_key)
  on conflict (dedupe_key) do nothing
  returning id into v_id;
  if v_id is not null then perform lms_mail_dispatch(v_id); end if;
  return v_id;
end $$;

-- 2900 의 직접 발송 함수·옛 목록 함수는 쓰지 않음 (대기열 구조로 바꿈, 예약 실행에 걸린 적 없음)
drop function if exists lms_send_lesson_reminders();
drop function if exists lms_lesson_reminders_due(timestamptz);

-- 지금 보낼 리마인더 (보내지 않고 목록만 — 시험용)
create or replace function lms_lesson_reminders_due(p_now timestamptz default now())
returns table (lesson_id uuid, which text)
language sql stable security definer set search_path = public as $$
  select l.id, w.which
  from lessons l
  join students s on s.id = l.student_id
  cross join lateral (values ('24h', interval '24 hours'), ('2h', interval '2 hours')) as w(which, before)
  where l.state = 'scheduled' and l.voided_at is null
    and p_now >= l.starts_at - w.before and p_now < l.starts_at - w.before + interval '1 hour' and p_now < l.starts_at
    and coalesce(l.time_set_at, '-infinity') <= l.starts_at - w.before
    and case when l.kind = 'regular' then s.remind_regular else s.remind_makeup end
    and not exists (select 1 from leave_items li where li.lesson_id = l.id and li.lesson_gone_at is null
                    and (li.choice = 'undecided' or (li.choice = 'substitute' and li.sub_stage <> 'confirmed')))
    and not exists (select 1 from notifications n
                    where n.dedupe_key = 'lesson_reminder:' || l.id || ':' || to_char(l.starts_at at time zone 'UTC', 'YYYYMMDD"T"HH24MI') || ':' || w.which)
$$;

create or replace function lms_lesson_reminder_run(p_now timestamptz default now()) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  x record;
  l lessons;
  v_n integer := 0;
begin
  if not exists (select 1 from feature_flags f where f.key = 'lesson_reminder_since') then return jsonb_build_object('sent', 0); end if;
  for x in select * from lms_lesson_reminders_due(p_now) loop
    select * into l from lessons where id = x.lesson_id;
    if lms_lesson_reminder_mail(l, x.which) is not null then v_n := v_n + 1; end if;
  end loop;
  return jsonb_build_object('sent', v_n);
end $$;

revoke all on function lms_lesson_reminder_mail(lessons, text) from public, anon, authenticated;
revoke all on function lms_lesson_reminders_due(timestamptz) from public, anon, authenticated;
revoke all on function lms_lesson_reminder_run(timestamptz) from public, anon, authenticated;

-- 15분마다 (pg_cron 이 있는 Supabase 에서만)
do $$
begin
  if to_regnamespace('cron') is not null then
    perform cron.schedule('lms-lesson-reminders', '*/15 * * * *', 'select lms_lesson_reminder_run(); select lms_mail_run();');
  end if;
end $$;
