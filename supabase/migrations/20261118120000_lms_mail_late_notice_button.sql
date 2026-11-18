-- 학생 메일 [강사님께 늦는다고 알리기] 버튼 (대표 11/18 '시스템에 넣어', 정책 원본 H26(215))
-- 수업 2시간 전 리마인더(정규·보강·이월·보상)·강사 Contact student 1·2차 메일의 기존 버튼 아래에 두 번째 버튼.
-- 링크 /student?late=수업id → 학생 홈이 그 수업 '늦게 참여해요' 창을 바로 엶. 24시간 전 리마인더에는 넣지 않음(지각 알림은 시작 2시간 전부터).
-- 보내기 막기(한 수업 1번·끝난 수업)는 기존 student_late_notice 그대로

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
  v_late_btn text := '강사님께 늦는다고 알리기';
  v_late_url text := lms_url() || '/student?late=' || l.id;
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
            || v_p2 || E'\n\n' || v_btn || ': ' || v_url || case when p_which = '2h' then E'\n' || v_late_btn || ': ' || v_late_url else '' end || E'\n\n'
            || v_off || E'\n' || v_foot
            || case when v_live then '' else E'\n\n(시험 발송 · 원래 받는 사람: ' || v_intended || ')' end;
  v_html := '<div style="font-family:sans-serif;font-size:15px;line-height:1.6;color:#1d1b2a;max-width:480px">'
            || case when v_live then '' else '<p style="background:#fff4d6;color:#5c3b00;border-radius:8px;padding:8px 10px;font-size:13px;font-weight:600">시험 발송 · 원래 받는 사람: ' || lms_html(v_intended) || '</p>' end
            || '<p>' || lms_html(v_p1) || '</p>'
            || case when v_sub then '<p style="background:#fff6dd;color:#7a5200;border-radius:8px;padding:9px 11px;font-weight:600">대체강사 수업이에요. 수업 링크가 달라요.</p>' else '' end
            || '<p style="font-weight:700">' || replace(lms_html(v_p2), E'\n', '<br>') || '</p>'
            || '<p><a href="' || lms_html(v_url) || '" style="display:inline-block;background:#5b3df0;color:#fff;border-radius:10px;padding:11px 18px;font-weight:700;text-decoration:none">' || lms_html(v_btn) || '</a></p>'
            || case when p_which = '2h' then '<p><a href="' || lms_html(v_late_url) || '" style="display:inline-block;background:#fff;color:#4b2fd6;border:1.5px solid #5b3df0;border-radius:10px;padding:10px 17px;font-weight:700;text-decoration:none">' || lms_html(v_late_btn) || '</a></p>' else '' end
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
  v_intended text;
  v_to text;
  v_subject text;
  v_first text;
  v_end_at text;
  v_when text;
  v_end text;
  v_url text;
  v_btn text := '수업 들어가기';
  v_late_btn text := '강사님께 늦는다고 알리기';
  v_late_url text := lms_url() || '/student?late=' || p_lesson;
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

  -- 학생 메일 (대표 11/16 확정 문구 최종본: 친절한 전체 문구, 이름 = 성 포함, 시간 = 거주지 / 한국)
  v_tz := coalesce(nullif(st.timezone, ''), 'Asia/Seoul');
  v_url := coalesce(nullif(btrim(tu.meet_url), ''), lms_url() || '/student');
  v_to := case when v_live then v_intended else 'support@edgeenglish.kr' end;
  -- 끝나는 시각: 시작과 같은 날이면 시각만, 한국 시간은 거주지와 날짜가 다르면 날짜까지 (lms_mail_ko_at 과 같은 모양)
  v_end_at := case when (l.ends_at at time zone v_tz)::date = (l.starts_at at time zone v_tz)::date
                   then lms_mail_ko_hour(l.ends_at, v_tz) else lms_mail_ko_when(l.ends_at, v_tz) end;
  v_end_at := case when v_tz = 'Asia/Seoul' then v_end_at || ' [한국 시간]'
                   else v_end_at || ' [' || lms_mail_ko_zone(v_tz) || '] / '
                        || case when (l.ends_at at time zone v_tz)::date = (l.ends_at at time zone 'Asia/Seoul')::date
                                then lms_mail_ko_hour(l.ends_at, 'Asia/Seoul') else lms_mail_ko_when(l.ends_at, 'Asia/Seoul') end || ' [한국 시간]' end;
  if p_stage = 1 then
    v_subject := '[엣지영어] ' || tu.name || ' 강사님이 수업방에서 기다리고 있어요';
    v_first := st.name_ko || '님, 안녕하세요! 엣지영어입니다. ☺️' || E'\n'
      || '오늘 수업 시간이 시작되었는데 아직 입장하지 않으셔서 연락드려요.' || E'\n'
      || tu.name || ' 강사님이 수업방에서 기다리고 계세요. 지금이라도 참여하실 수 있으니 아래 버튼을 눌러 입장해 주세요!';
    v_when := '• 수업 시간: ' || lms_mail_ko_at(l.starts_at, v_tz);
    v_end := '늦게 입장하시더라도 기존 수업 종료 시간은 연장되지 않는 점 참고 부탁드려요.' || E'\n'
      || '오늘 수업 참여가 어려우시다면 엣지영어 카카오톡 채널로 알려 주세요.';
  else
    v_subject := '[엣지영어] 아직 수업에 참여하실 수 있어요';
    v_first := st.name_ko || '님, 안녕하세요! 엣지영어입니다. ☺️' || E'\n'
      || '아직 수업에 입장하지 않으셔서 한 번 더 연락드려요.' || E'\n'
      || tu.name || ' 강사님은 수업이 끝날 때까지 기다리고 계십니다.' || E'\n'
      || '남은 시간이라도 수업에 참여하실 수 있으니 아래 버튼을 눌러 주세요!';
    v_when := '• 수업 시작: ' || lms_mail_ko_at(l.starts_at, v_tz) || E'\n' || '• 수업 종료: ' || v_end_at;
    v_end := '늦게 입장하시더라도 수업 종료 시간은 동일하며, 별도로 연장되지 않습니다.';
  end if;
  v_subject := case when v_live then '' else '[시험 · ' || st.code || '] ' end || v_subject;

  -- 순서 (대표 11/16 '바꿔'): 인사·안내 → 수업 안내 → [수업 들어가기] → 강사 메시지 → 연장 안내 → 맺음
  v_text := v_first
    || E'\n\n' || '수업 안내' || E'\n' || v_when
    || E'\n\n' || v_btn || ': ' || v_url || E'\n' || v_late_btn || ': ' || v_late_url
    || case when v_note is null then '' else E'\n\n' || '💬 ' || tu.name || ' 강사님의 메시지' || E'\n' || v_note end
    || E'\n\n' || v_end
    || E'\n\n' || '감사합니다.' || E'\n' || v_foot
    || case when v_live then '' else E'\n\n(시험 발송 · 원래 받는 사람: ' || v_intended || ')' end;
  v_html := '<div style="font-family:sans-serif;font-size:15px;line-height:1.6;color:#1d1b2a;max-width:480px">'
    || case when v_live then '' else '<p style="background:#fff4d6;color:#5c3b00;border-radius:8px;padding:8px 10px;font-size:13px;font-weight:600">시험 발송 · 원래 받는 사람: ' || lms_html(v_intended) || '</p>' end
    || '<p>' || replace(lms_html(v_first), E'\n', '<br>') || '</p>'
    || '<p><b>수업 안내</b><br>' || replace(lms_html(v_when), E'\n', '<br>') || '</p>'
    || '<p><a href="' || lms_html(v_url) || '" style="display:inline-block;background:#5b3df0;color:#fff;border-radius:10px;padding:11px 18px;font-weight:700;text-decoration:none">' || lms_html(v_btn) || '</a></p>'
    || '<p><a href="' || lms_html(v_late_url) || '" style="display:inline-block;background:#fff;color:#4b2fd6;border:1.5px solid #5b3df0;border-radius:10px;padding:10px 17px;font-weight:700;text-decoration:none">' || lms_html(v_late_btn) || '</a></p>'
    || case when v_note is null then '' else
         '<div style="border-left:3px solid #5b3df0;background:#efebff;border-radius:0 10px 10px 0;padding:8px 12px;margin:0 0 14px">'
         || '<div style="font-size:12.5px;color:#55526a">💬 ' || lms_html(tu.name) || ' 강사님의 메시지</div>'
         || '<div>' || replace(lms_html(v_note), E'\n', '<br>') || '</div></div>' end
    || '<p>' || replace(lms_html(v_end), E'\n', '<br>') || '</p>'
    || '<p>감사합니다.<br>' || lms_html(v_foot) || '</p></div>';
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
