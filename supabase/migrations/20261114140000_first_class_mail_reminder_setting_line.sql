-- 첫 수업 일정 안내 메일(학생)에 한 줄: 수업 알림 메일은 내 정보에서 켜고 끌 수 있음 (대표 11/14 A안, 정책 원본 H26(174))
-- 일정이 바뀌어 다시 보내는 메일(p_change)에는 넣지 않음. 그 밖의 본문·받는 사람·중복 방지 키는 그대로
create or replace function public.lms_first_class_mail_student(e enrollments, f lessons, p_every timestamp with time zone[], p_label text, p_change boolean, p_key text, p_version text, p_slots jsonb)
 returns uuid
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare
  v_live boolean := coalesce((select x.enabled from feature_flags x where x.key = 'send_emails'), false);
  st students;
  tu tutors;
  v_tz text;
  v_intended text;
  v_to text;
  v_subject text;
  v_url text;
  v_btn text := '수업 입장하기';
  v_zone text;
  v_p1 text;
  v_p2 text;
  v_opt text := case when p_change then '' else '수업 알림 메일은 엣지영어 LMS › 내 정보 › 이메일 알림 설정에서 켜고 끌 수 있어요.' end;
  v_foot text := '문의: 카카오톡 채널 엣지영어';
  v_html text;
  v_body text;
  v_id uuid;
begin
  select * into st from students where id = e.student_id;
  select * into tu from tutors where id = f.tutor_id;
  v_tz := coalesce(nullif(st.timezone, ''), 'Asia/Seoul');
  v_intended := lms_notice_recipient_email('student', st.id);
  if v_intended is null then return null; end if;
  v_to := case when v_live then v_intended else 'support@edgeenglish.kr' end;
  v_subject := case when v_live then '' else '[시험 · ' || st.code || '] ' end
               || case when p_change then '[엣지영어] 첫 수업 일정이 변경됐어요' else '[엣지영어] 첫 수업 일정 안내' end;
  v_url := coalesce(nullif(trim(tu.meet_url), ''), lms_url() || '/student');
  v_zone := regexp_replace(lms_mail_ko_zone(v_tz), ' 시간$', '');
  v_p1 := case when p_change then '첫 수업 일정이 변경되어 다시 안내해 드려요.' else '안녕하세요, ' || st.name_ko || '님! ☺️' || E'\n' || '첫 수업 일정을 안내해 드려요.' end;
  v_p2 := '첫 수업: ' || lms_mail_ko_date(f.starts_at, v_tz) || ' ' || lms_mail_ko_clock(f.starts_at, v_tz) || E'\n'
          || '담당 강사: ' || tu.name || E'\n'
          || p_label || ': ' || lms_mail_ko_every(p_every, v_tz);
  v_body := v_p1 || E'\n\n' || v_p2 || E'\n\n' || v_btn || ': ' || v_url || E'\n\n' || '모든 시간은 ' || v_zone || ' 시간대 기준이에요.'
            || case when v_opt = '' then '' else E'\n' || v_opt end
            || E'\n' || v_foot
            || case when v_live then '' else E'\n\n(시험 발송 · 원래 받는 사람: ' || v_intended || ')' end;
  v_html := '<div style="font-family:sans-serif;font-size:15px;line-height:1.6;color:#1d1b2a;max-width:480px">'
            || case when v_live then '' else '<p style="background:#fff4d6;color:#5c3b00;border-radius:8px;padding:8px 10px;font-size:13px;font-weight:600">시험 발송 · 원래 받는 사람: ' || lms_html(v_intended) || '</p>' end
            || '<p>' || replace(lms_html(v_p1), E'\n', '<br>') || '</p>'
            || '<p style="font-weight:700">' || replace(lms_html(v_p2), E'\n', '<br>') || '</p>'
            || '<p><a href="' || lms_html(v_url) || '" style="display:inline-block;background:#5b3df0;color:#fff;border-radius:10px;padding:11px 18px;font-weight:700;text-decoration:none">' || lms_html(v_btn) || '</a></p>'
            || '<p style="font-size:13px;color:#55526a">모든 시간은 ' || lms_html(v_zone) || ' 시간대 기준이에요.'
            || case when v_opt = '' then '' else '<br>' || lms_html(v_opt) end || '</p>'
            || '<p style="font-size:12.5px;color:#55526a;border-top:1px solid #e6e3ef;padding-top:10px">' || lms_html(v_foot) || '</p></div>';
  insert into notifications (recipient_kind, recipient_id, email, locale, template, payload, dedupe_key)
  values ('student', st.id, v_to, 'ko', 'lesson_notice_first_class',
          jsonb_build_object('intended_email', v_intended, 'subject', v_subject, 'html', v_html, 'text', v_body,
                             'enrollment_id', e.id, 'version', p_version, 'slots', p_slots, 'stage', case when p_change then 'change' else 'reminder' end),
          p_key)
  on conflict (dedupe_key) do nothing
  returning id into v_id;
  if v_id is not null then perform lms_mail_dispatch(v_id); end if;
  return v_id;
end $function$;
