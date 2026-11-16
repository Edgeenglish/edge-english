-- 강사 [학생에게 연락하기] (H26(197), 대표 11/16 시안 3판 승인·'넣어')
--  - 학생이 수업에 안 들어올 때 강사가 Home 오늘 수업 / Schedule 수업 창 / Class Record 줄에서 [Contact student]
--  - 1차: 시작 5분 뒤 ~ 수업 끝까지 · 2차 [Contact student again]: 1차를 보냈고 수업 절반 뒤 ~ 수업 끝까지 (POL-TU-09)
--  - 학생 메일 1통(한국어, 회사 고정 문구 + 강사 한마디 150자 선택, [수업 들어가기] = 강사 Meet). 운영진은 기존 support@ 숨은참조로 받음(별도 메일 없음)
--  - 학생 이메일은 강사에게 보이지 않음(엣지영어가 보냄). 단계마다 한 번만, 다시 눌러도 같은 결과
--  - 기록(보낸 시각·누가 보냈는지)은 Class Record·운영자 보기에 남음 = 노쇼 판정 근거. 수업 상태·수강권은 바꾸지 않음
--  - 운영자는 운영자 보기(?tutor=)에서 같은 함수로 대신 보냄
-- 표 1개 + 함수 2개. 기존 데이터를 바꾸지 않음. 다시 실행해도 같은 결과
-- 되돌리기: drop function tutor_contact_student(uuid, integer, text, uuid), tutor_contact_notices(uuid); (표는 기록이 있으면 보존)

create table if not exists tutor_contact_notices (
  id uuid primary key default gen_random_uuid(),
  lesson_id uuid not null references lessons(id),
  stage integer not null check (stage in (1, 2)),
  tutor_id uuid not null references tutors(id),
  student_id uuid not null references students(id),
  note text check (note is null or char_length(note) <= 150),
  by_admin boolean not null default false,
  created_by uuid,
  created_at timestamptz not null default now(),
  unique (lesson_id, stage)
);
alter table tutor_contact_notices enable row level security;
do $$ begin
  if not exists (select 1 from pg_trigger where tgname = 'tutor_contact_notices_no_delete') then
    perform lms_protect('public.tutor_contact_notices');
    create trigger tutor_contact_notices_no_delete before delete on tutor_contact_notices for each row execute function forbid_delete();
  end if;
end $$;

-- 보내기: 강사 본인 / 운영자(대신, p_tutor). 이미 보낸 단계면 repeated
create or replace function tutor_contact_student(p_lesson uuid, p_stage integer, p_note text default null, p_tutor uuid default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_tutor uuid := lms_screen_tutor(p_tutor);
  v_live boolean := coalesce((select f.enabled from feature_flags f where f.key = 'send_emails'), false);
  v_note text := nullif(btrim(coalesce(p_note, '')), '');
  l lessons;
  st students;
  tu tutors;
  v_tz text;
  v_min int;
  v_intended text;
  v_to text;
  v_subject text;
  v_first text;
  v_mid text;
  v_when text;
  v_end text;
  v_url text;
  v_btn text := '수업 들어가기';
  v_foot text := '엣지영어 드림';
  v_text text;
  v_html text;
  v_id uuid;
begin
  select * into l from lessons where id = p_lesson;
  if not found or l.tutor_id is distinct from v_tutor then raise exception 'You can only send this for your own classes.' using errcode = '42501'; end if;
  if p_stage is null or p_stage not in (1, 2) then raise exception 'Please reload the page and try again.'; end if;
  if char_length(coalesce(v_note, '')) > 150 then raise exception 'Your message can be up to 150 characters.'; end if;
  if exists (select 1 from tutor_contact_notices where lesson_id = p_lesson and stage = p_stage) then return jsonb_build_object('repeated', true); end if;
  if l.state <> 'scheduled' or l.voided_at is not null or now() >= l.ends_at
     or (p_stage = 1 and now() < l.starts_at + interval '5 minutes')
     or (p_stage = 2 and (now() < l.starts_at + (l.ends_at - l.starts_at) / 2
                          or not exists (select 1 from tutor_contact_notices where lesson_id = p_lesson and stage = 1))) then
    raise exception '%', case when p_stage = 1 then 'This is available from 5 minutes after class starts until it ends.'
                              else 'This is available from halfway through class until it ends, after your first email.' end
      using hint = 'not_eligible';
  end if;
  if exists (select 1 from leave_items li where li.lesson_id = p_lesson and li.lesson_gone_at is null
    and (li.choice = 'undecided' or (li.choice = 'substitute' and li.sub_stage <> 'confirmed'))) then
    raise exception 'This class is being arranged by Edge English.';
  end if;
  perform set_config('app.actor_id', coalesce(auth.uid()::text, ''), true);
  perform set_config('app.actor_via', case when is_admin() then 'admin_on_behalf' else 'tutor_contact_student' end, true);
  insert into tutor_contact_notices (lesson_id, stage, tutor_id, student_id, note, by_admin, created_by)
  values (p_lesson, p_stage, v_tutor, l.student_id, v_note, is_admin(), auth.uid());

  select * into st from students where id = l.student_id;
  select * into tu from tutors where id = v_tutor;
  v_intended := lms_notice_recipient_email('student', st.id);
  if v_intended is null then return jsonb_build_object('repeated', false, 'mailed', false); end if;

  -- 학생 메일 (대표 11/16 확정 문구, 시안 3판)
  v_tz := coalesce(nullif(st.timezone, ''), 'Asia/Seoul');
  v_min := round(extract(epoch from l.ends_at - l.starts_at) / 60)::int;
  v_url := coalesce(nullif(btrim(tu.meet_url), ''), lms_url() || '/student');
  v_to := case when v_live then v_intended else 'support@edgeenglish.kr' end;
  if p_stage = 1 then
    v_subject := '[엣지영어] ' || tu.name || ' 강사님이 수업방에서 기다리고 있어요';
    v_first := st.name_ko || '님, ' || tu.name || ' 강사님이 수업방에서 기다리고 있어요.';
    v_mid := null;
    v_end := '오늘 수업 참여가 어려우시면 카카오톡 채널로 알려 주세요.';
  else
    v_subject := '[엣지영어] 아직 수업에 참여하실 수 있어요';
    v_first := st.name_ko || '님, 아직 수업에 참여하실 수 있어요.';
    v_mid := tu.name || ' 강사님은 수업이 끝날 때까지 기다리고 계세요.';
    v_end := null;
  end if;
  v_subject := case when v_live then '' else '[시험 · ' || st.code || '] ' end || v_subject;
  v_when := '수업: ' || lms_mail_ko_at(l.starts_at, v_tz) || ' · ' || v_min || '분';

  v_text := v_first
    || case when v_mid is null then '' else E'\n\n' || v_mid end
    || E'\n\n' || v_btn || ': ' || v_url
    || case when v_note is null then '' else E'\n\n' || tu.name || ' 강사님 메시지' || E'\n' || v_note end
    || E'\n\n' || v_when
    || case when v_end is null then '' else E'\n\n' || v_end end
    || E'\n\n' || v_foot
    || case when v_live then '' else E'\n\n(시험 발송 · 원래 받는 사람: ' || v_intended || ')' end;
  v_html := '<div style="font-family:sans-serif;font-size:15px;line-height:1.6;color:#1d1b2a;max-width:480px">'
    || case when v_live then '' else '<p style="background:#fff4d6;color:#5c3b00;border-radius:8px;padding:8px 10px;font-size:13px;font-weight:600">시험 발송 · 원래 받는 사람: ' || lms_html(v_intended) || '</p>' end
    || '<p style="font-weight:700">' || lms_html(v_first) || '</p>'
    || case when v_mid is null then '' else '<p>' || lms_html(v_mid) || '</p>' end
    || '<p><a href="' || lms_html(v_url) || '" style="display:inline-block;background:#5b3df0;color:#fff;border-radius:10px;padding:11px 18px;font-weight:700;text-decoration:none">' || lms_html(v_btn) || '</a></p>'
    || case when v_note is null then '' else
         '<div style="border-left:3px solid #5b3df0;background:#efebff;border-radius:0 10px 10px 0;padding:8px 12px;margin:0 0 14px">'
         || '<div style="font-size:12px;color:#55526a">' || lms_html(tu.name) || ' 강사님 메시지</div>'
         || '<div>' || replace(lms_html(v_note), E'\n', '<br>') || '</div></div>' end
    || '<p>' || lms_html(v_when) || '</p>'
    || case when v_end is null then '' else '<p>' || lms_html(v_end) || '</p>' end
    || '<p style="font-size:12.5px;color:#55526a;border-top:1px solid #e6e3ef;padding-top:10px">' || lms_html(v_foot) || '</p></div>';
  insert into notifications (recipient_kind, recipient_id, email, locale, template, payload, dedupe_key)
  values ('student', st.id, v_to, 'ko', 'tutor_contact_student',
          jsonb_build_object('intended_email', v_intended, 'subject', v_subject, 'html', v_html, 'text', v_text, 'lesson_id', l.id, 'stage', p_stage),
          'tutor_contact:' || l.id || ':' || p_stage)
  on conflict (dedupe_key) do nothing
  returning id into v_id;
  if v_id is not null then perform lms_mail_dispatch(v_id); end if;
  return jsonb_build_object('repeated', false, 'mailed', true);
end $$;
revoke all on function tutor_contact_student(uuid, integer, text, uuid) from public, anon;
grant execute on function tutor_contact_student(uuid, integer, text, uuid) to authenticated;

-- 강사 화면·운영자 보기 읽기: 이 강사 수업에 보낸 연락 (학생 이메일은 안 줌)
create or replace function tutor_contact_notices(p_tutor uuid default null) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_tutor uuid := lms_screen_tutor(p_tutor);
begin
  return coalesce((select jsonb_agg(jsonb_build_object('lesson_id', n.lesson_id, 'stage', n.stage, 'at', n.created_at, 'by_admin', n.by_admin) order by n.created_at)
                   from tutor_contact_notices n
                   where n.tutor_id = v_tutor), '[]'::jsonb);
end $$;
revoke all on function tutor_contact_notices(uuid) from public, anon;
grant execute on function tutor_contact_notices(uuid) to authenticated;
