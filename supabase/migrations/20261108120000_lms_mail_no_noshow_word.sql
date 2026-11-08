-- 학생 메일에 '노쇼' 표현 쓰지 않음 (11/8 대표): 무료 보상수업 확정 메일 '강사 노쇼 수업:' → '강사 사정으로 진행하지 못한 수업:'
-- 운영진·강사 화면·DB 기록(class_status 'Tutor no-show')은 그대로. 이 함수의 다른 부분은 20261108100000 과 같음 (그 줄만 바꿈)
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
               || ' · ' || lms_mail_ko_when(l.starts_at, st.timezone) || ' (' || lms_mail_ko_zone(st.timezone) || ')';
    v_lines := array[
      '[엣지영어] ' || st.name_ko || '님, ' || case when v_comp then '무료 보상수업이 확정됐어요' else '보강이 확정됐어요' end,
      case when v_comp then '강사 사정으로 진행하지 못한 수업: ' else '원래 수업: ' end || v_origin,
      case when v_comp then '보상수업: ' else '보강 수업: ' end || v_when || ' · ' || v_minutes || '분',
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
