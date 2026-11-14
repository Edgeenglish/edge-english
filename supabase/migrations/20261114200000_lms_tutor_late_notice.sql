-- 강사 '늦어요' 알림 (대표 2026-11-13 범위·설계, 2026-11-14 문구 확정·'시스템에 넣어')
--  - 강사가 Schedule 수업 창 / Home 오늘 수업 / Class Record 줄에서 [Running late] → 지각 시간(5·10·15·20분 이상) + 이유(선택, 5가지)
--  - 수업 시작 2시간 전부터 시작 전까지만. 한 수업에 한 번만 (다시 눌러도 같은 결과, 메일 각 1통)
--  - 학생 메일 1통(한국어, 거주지 시간) + 운영진(support@) 메일 1통 + 학생 홈 '다음 수업' 카드 노란 띠
--  - 수업 시간·상태·수강권·지각 기록(Class Record)은 바꾸지 않는 통보. 사전 알림은 지각 면제가 아님 (POL-TU-01 그대로)
--  - 운영자는 운영자 보기(?tutor=)에서 같은 함수로 대신 보냄
-- 표 1개 + 함수 3개. 기존 데이터를 바꾸지 않음. 다시 실행해도 같은 결과
-- 되돌리기: drop function tutor_late_notice(uuid, integer, text, uuid), tutor_late_notices(uuid), student_tutor_late_notices(uuid); drop table tutor_late_notices;

create table if not exists tutor_late_notices (
  id uuid primary key default gen_random_uuid(),
  lesson_id uuid not null unique references lessons(id),
  tutor_id uuid not null references tutors(id),
  student_id uuid not null references students(id),
  minutes integer not null check (minutes in (5, 10, 15, 20)),  -- 20 = '20분 이상'
  reason text check (reason in ('internet', 'power', 'device', 'personal', 'previous')),
  created_by uuid,
  created_at timestamptz not null default now()
);
alter table tutor_late_notices enable row level security;
do $$ begin
  if not exists (select 1 from pg_trigger where tgname = 'tutor_late_notices_no_delete') then
    perform lms_protect('public.tutor_late_notices');
    create trigger tutor_late_notices_no_delete before delete on tutor_late_notices for each row execute function forbid_delete();
  end if;
end $$;

-- 운영자 메일용 한국 시간 글: '11/14(토) 오후 8:00'
create or replace function lms_kst_short(p_at timestamptz) returns text
language sql stable set search_path = public as $$
  select to_char(p_at at time zone 'Asia/Seoul', 'FMMM/FMDD') || '('
    || (array['일','월','화','수','목','금','토'])[extract(dow from p_at at time zone 'Asia/Seoul')::int + 1] || ') '
    || case when extract(hour from p_at at time zone 'Asia/Seoul') < 12 then '오전 ' else '오후 ' end
    || to_char(p_at at time zone 'Asia/Seoul', 'FMHH12:MI')
$$;
revoke all on function lms_kst_short(timestamptz) from public, anon, authenticated;

-- 보내기: 강사 본인 / 운영자(대신, p_tutor). 이미 보냈으면 repeated
create or replace function tutor_late_notice(p_lesson uuid, p_minutes integer, p_reason text default null, p_tutor uuid default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_tutor uuid := lms_screen_tutor(p_tutor);
  v_live boolean := coalesce((select f.enabled from feature_flags f where f.key = 'send_emails'), false);
  l lessons;
  st students;
  tu tutors;
  v_tz text;
  v_x text;
  v_min int;
  v_ko text;
  v_en text;
  v_intended text;
  v_to text;
  v_subject text;
  v_paras text[];
  v_url text := lms_url() || '/student';
  v_btn text := 'LMS에서 일정 보기';
  v_foot text := '문의: 카카오톡 채널 엣지영어';
  v_text text;
  v_html text;
  v_id uuid;
  p text;
  i int := 0;
begin
  select * into l from lessons where id = p_lesson;
  if not found or l.tutor_id is distinct from v_tutor then raise exception 'You can only send this for your own classes.' using errcode = '42501'; end if;
  if p_minutes is null or p_minutes not in (5, 10, 15, 20) then raise exception 'Choose how late you''ll be.'; end if;
  if p_reason is not null and p_reason not in ('internet', 'power', 'device', 'personal', 'previous') then raise exception 'Choose a reason again.'; end if;
  if exists (select 1 from tutor_late_notices where lesson_id = p_lesson) then return jsonb_build_object('repeated', true); end if;
  if l.state <> 'scheduled' or l.voided_at is not null
     or now() < l.starts_at - interval '2 hours' or now() >= l.starts_at then
    raise exception 'This is available from 2 hours before class until it starts.' using hint = 'not_eligible';
  end if;
  if exists (select 1 from leave_items li where li.lesson_id = p_lesson and li.lesson_gone_at is null
    and (li.choice = 'undecided' or (li.choice = 'substitute' and li.sub_stage <> 'confirmed'))) then
    raise exception 'This class is being arranged by Edge English.';
  end if;
  perform set_config('app.actor_id', coalesce(auth.uid()::text, ''), true);
  perform set_config('app.actor_via', case when is_admin() then 'admin_on_behalf' else 'tutor_late_notice' end, true);
  insert into tutor_late_notices (lesson_id, tutor_id, student_id, minutes, reason, created_by)
  values (p_lesson, v_tutor, l.student_id, p_minutes, p_reason, auth.uid());

  select * into st from students where id = l.student_id;
  select * into tu from tutors where id = v_tutor;
  v_tz := coalesce(nullif(st.timezone, ''), 'Asia/Seoul');
  v_x := case when p_minutes = 20 then '20분 이상' else '약 ' || p_minutes || '분' end;
  v_min := round(extract(epoch from l.ends_at - l.starts_at) / 60)::int;
  v_ko := case p_reason when 'internet' then '인터넷 연결에 문제가 생겼어요' when 'power' then '정전이 됐어요'
            when 'device' then '컴퓨터·장비에 문제가 생겼어요' when 'personal' then '갑자기 급한 일이 생겼어요'
            when 'previous' then '앞 일정이 늦게 끝났어요' end;
  v_en := case p_reason when 'internet' then 'Internet problem' when 'power' then 'Power outage'
            when 'device' then 'Computer or device issue' when 'personal' then 'Personal emergency'
            when 'previous' then 'Previous appointment ran late' end;

  -- 1) 학생 메일 (대표 11/14 확정 문구)
  v_intended := lms_notice_recipient_email('student', st.id);
  if v_intended is not null then
    v_to := case when v_live then v_intended else 'support@edgeenglish.kr' end;
    v_subject := case when v_live then '' else '[시험 · ' || st.code || '] ' end
      || '[엣지영어] 강사님이 ' || v_x || ' 늦을 예정이에요 · ' || lms_mail_ko_when(l.starts_at, v_tz) || ' [' || lms_mail_ko_zone(v_tz) || ']';
    v_paras := array[
      st.name_ko || '님, 강사님이 수업에 ' || v_x || ' 늦을 예정이에요.',
      '수업: ' || lms_mail_ko_at(l.starts_at, v_tz) || ' · ' || v_min || '분'
        || case when v_ko is null then '' else E'\n' || '이유: ' || v_ko end,
      '늦은 만큼 수업 시간을 연장해 드려요.' || E'\n' || '연장 수업이 어려우시면 카카오톡 채널로 알려 주세요.',
      '불편을 드려 죄송합니다.'];
    v_text := array_to_string(v_paras, E'\n\n') || E'\n\n' || v_btn || ': ' || v_url || E'\n' || v_foot
      || case when v_live then '' else E'\n\n(시험 발송 · 원래 받는 사람: ' || v_intended || ')' end;
    v_html := '<div style="font-family:sans-serif;font-size:15px;line-height:1.6;color:#1d1b2a;max-width:480px">'
      || case when v_live then '' else '<p style="background:#fff4d6;color:#5c3b00;border-radius:8px;padding:8px 10px;font-size:13px;font-weight:600">시험 발송 · 원래 받는 사람: ' || lms_html(v_intended) || '</p>' end;
    foreach p in array v_paras loop
      i := i + 1;
      v_html := v_html || case when i = 1 then '<p style="font-weight:700">' else '<p>' end || replace(lms_html(p), E'\n', '<br>') || '</p>';
    end loop;
    v_html := v_html
      || '<p><a href="' || lms_html(v_url) || '" style="display:inline-block;background:#5b3df0;color:#fff;border-radius:10px;padding:11px 18px;font-weight:700;text-decoration:none">' || lms_html(v_btn) || '</a></p>'
      || '<p style="font-size:12.5px;color:#55526a;border-top:1px solid #e6e3ef;padding-top:10px">' || lms_html(v_foot) || '</p></div>';
    insert into notifications (recipient_kind, recipient_id, email, locale, template, payload, dedupe_key)
    values ('student', st.id, v_to, 'ko', 'tutor_late_student',
            jsonb_build_object('intended_email', v_intended, 'subject', v_subject, 'html', v_html, 'text', v_text, 'lesson_id', l.id),
            'tutor_late_student:' || l.id)
    on conflict (dedupe_key) do nothing
    returning id into v_id;
    if v_id is not null then perform lms_mail_dispatch(v_id); end if;
  end if;

  -- 2) 운영진 메일 (대표 11/14 확정: 별도 1통)
  v_subject := case when v_live then '' else '[시험 · ' || st.code || '] ' end
    || '[강사 지각 알림] ' || tu.name || ' → ' || st.name_ko || ' · ' || v_x || ' · ' || lms_kst_short(l.starts_at) || ' 한국 시간';
  v_paras := array[
    '강사: ' || tu.name || E'\n'
    || '학생: ' || st.name_ko || ' (' || st.code || ')' || E'\n'
    || '수업: ' || lms_kst_short(l.starts_at) || ' 한국 시간 · ' || v_min || '분' || E'\n'
    || '예상 지각: ' || v_x
    || case when v_en is null then '' else E'\n' || '이유: ' || v_en end || E'\n'
    || '알린 시각: ' || lms_kst_short(now()) || ' 한국 시간'];
  v_text := v_paras[1];
  v_html := '<div style="font-family:sans-serif;font-size:15px;line-height:1.6;color:#1d1b2a;max-width:480px"><p>'
    || replace(lms_html(v_paras[1]), E'\n', '<br>') || '</p></div>';
  v_id := null;
  insert into notifications (recipient_kind, recipient_id, email, locale, template, payload, dedupe_key)
  values ('admin', null, 'support@edgeenglish.kr', 'ko', 'tutor_late_admin',
          jsonb_build_object('intended_email', 'support@edgeenglish.kr', 'subject', v_subject, 'html', v_html, 'text', v_text, 'lesson_id', l.id),
          'tutor_late_admin:' || l.id)
  on conflict (dedupe_key) do nothing
  returning id into v_id;
  if v_id is not null then perform lms_mail_dispatch(v_id); end if;
  return jsonb_build_object('repeated', false);
end $$;
revoke all on function tutor_late_notice(uuid, integer, text, uuid) from public, anon;
grant execute on function tutor_late_notice(uuid, integer, text, uuid) to authenticated;

-- 강사 화면 읽기: 이 강사가 알린 (아직 끝나지 않은) 수업
create or replace function tutor_late_notices(p_tutor uuid default null) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_tutor uuid := lms_screen_tutor(p_tutor);
begin
  return coalesce((select jsonb_agg(jsonb_build_object('lesson_id', n.lesson_id, 'minutes', n.minutes, 'reason', n.reason, 'at', n.created_at) order by n.created_at)
                   from tutor_late_notices n join lessons l on l.id = n.lesson_id
                   where n.tutor_id = v_tutor and l.ends_at > now()), '[]'::jsonb);
end $$;
revoke all on function tutor_late_notices(uuid) from public, anon;
grant execute on function tutor_late_notices(uuid) to authenticated;

-- 학생 화면 읽기: 이 학생 수업 중 강사가 늦는다고 알린 (아직 끝나지 않은) 수업
create or replace function student_tutor_late_notices(p_student uuid default null) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_student uuid := lms_screen_student(p_student);
begin
  return coalesce((select jsonb_agg(jsonb_build_object('lesson_id', n.lesson_id, 'minutes', n.minutes, 'reason', n.reason) order by n.created_at)
                   from tutor_late_notices n join lessons l on l.id = n.lesson_id
                   where n.student_id = v_student and l.ends_at > now()), '[]'::jsonb);
end $$;
revoke all on function student_tutor_late_notices(uuid) from public, anon;
grant execute on function student_tutor_late_notices(uuid) to authenticated;
