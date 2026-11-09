-- =====================================================================
-- 메일 시각 글 한 가지 모양 + 학생이 취소하면 강사에게 자동 메일 (대표 2026-11-08)
--  1) 시각 글 규칙 (화면·WhatsApp·카톡과 같음, 코드 src/lms/admin/time-text.ts): 시각 바로 뒤에 기준 이름, 두 시간대는 ' / ',
--     보는 사람 시간대 먼저·한국 뒤. 영어 'Mon, 9 Nov 6:00 PM *Ho Chi Minh Time* / 8:00 PM *KST*' ('KST', 별표 = 굵게)
--     한국어 '11월 9일(월) 오후 6시 [호찌민 시간] / 오후 8시 [한국 시간]' (한국 거주는 '… [한국 시간]')
--  2) 영어 메일은 *…* 를 HTML 에서 굵게, 메일 제목·글자 본문에서는 별표를 뺌
--  3) 학생이 수업을 취소하면(change_requests.type = student_cancel) 그 수업 강사에게 영어 메일:
--     제목 '[Edge English] Class canceled - 학생 영문 이름 · 강사 현지 시각 + 도시', 본문 취소된 수업·취소 신청 시각(+6시간 안이면 늦은 취소 한 줄)
--     발송은 기존 자동 메일과 같음: send_emails 가 꺼져 있으면 운영진 메일로만
-- 표·데이터는 바꾸지 않음 (함수만). 다시 실행해도 같은 결과
-- =====================================================================

-- 1. 영어 시각 ----------------------------------------------------------
create or replace function lms_mail_en_zone(p_tz text) returns text
language sql immutable as $$
  select case when coalesce(nullif(p_tz, ''), 'Asia/Seoul') = 'Asia/Seoul' then 'KST'
              else replace(split_part(p_tz, '/', array_length(string_to_array(p_tz, '/'), 1)), '_', ' ') || ' Time' end
$$;

-- 'Mon, 9 Nov 6:00 PM'
create or replace function lms_mail_en_when(p_at timestamptz, p_tz text) returns text
language sql stable as $$
  select (array['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'])[extract(dow from x)::int + 1] || ', ' || extract(day from x)::int || ' '
         || (array['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'])[extract(month from x)::int] || ' '
         || (case when extract(hour from x)::int % 12 = 0 then 12 else extract(hour from x)::int % 12 end) || ':' || to_char(x, 'MI')
         || case when extract(hour from x) < 12 then ' AM' else ' PM' end
  from (select p_at at time zone coalesce(nullif(p_tz, ''), 'Asia/Seoul') as x) q
$$;

-- '6:00 PM'
create or replace function lms_mail_en_clock(p_at timestamptz, p_tz text) returns text
language sql stable as $$
  select (case when extract(hour from x)::int % 12 = 0 then 12 else extract(hour from x)::int % 12 end) || ':' || to_char(x, 'MI')
         || case when extract(hour from x) < 12 then ' AM' else ' PM' end
  from (select p_at at time zone coalesce(nullif(p_tz, ''), 'Asia/Seoul') as x) q
$$;

-- 'Mon, 9 Nov 6:00 PM *Ho Chi Minh Time* / 8:00 PM *KST*' (같은 날이면 뒤에 날짜 없이, 다르면 'Tue, 10 Nov 1:30 AM *KST*'). 한국 강사는 '… *KST*' 하나
create or replace function lms_mail_en_at(p_at timestamptz, p_tz text) returns text
language sql stable as $$
  select case when coalesce(nullif(p_tz, ''), 'Asia/Seoul') = 'Asia/Seoul' then lms_mail_en_when(p_at, 'Asia/Seoul') || ' *KST*'
              else lms_mail_en_when(p_at, p_tz) || ' *' || lms_mail_en_zone(p_tz) || '* / '
                   || case when (p_at at time zone p_tz)::date = (p_at at time zone 'Asia/Seoul')::date then lms_mail_en_clock(p_at, 'Asia/Seoul')
                           else lms_mail_en_when(p_at, 'Asia/Seoul') end || ' *KST*' end
$$;

-- *…* 표시: 메일 HTML 은 굵게, 제목·글자 본문은 별표를 뺌
create or replace function lms_strip_bold(p_text text) returns text
language sql immutable as $$ select regexp_replace(coalesce(p_text, ''), '\*([^*]+)\*', '\1', 'g') $$;
create or replace function lms_bold_html(p_text text) returns text
language sql stable as $$ select regexp_replace(lms_html(p_text), '\*([^*]+)\*', '<b>\1</b>', 'g') $$;

-- 2. 한국어 시각 (학생) --------------------------------------------------
-- '오후 8시' / '오후 5시 30분'
create or replace function lms_mail_ko_hour(p_at timestamptz, p_tz text) returns text
language sql stable as $$
  select case when extract(hour from x) < 12 then '오전 ' else '오후 ' end
         || (case when extract(hour from x)::int % 12 = 0 then 12 else extract(hour from x)::int % 12 end) || '시'
         || case when extract(minute from x)::int > 0 then ' ' || extract(minute from x)::int || '분' else '' end
  from (select p_at at time zone coalesce(nullif(p_tz, ''), 'Asia/Seoul') as x) q
$$;

-- 한국 거주 '11월 9일(월) 오후 8시 [한국 시간]' / 해외 '11월 9일(월) 오후 6시 [호찌민 시간] / 오후 8시 [한국 시간]' (날짜가 다르면 뒤에도 날짜)
create or replace function lms_mail_ko_at(p_at timestamptz, p_tz text) returns text
language sql stable as $$
  select case when coalesce(nullif(p_tz, ''), 'Asia/Seoul') = 'Asia/Seoul' then lms_mail_ko_when(p_at, 'Asia/Seoul') || ' [한국 시간]'
              else lms_mail_ko_when(p_at, p_tz) || ' [' || lms_mail_ko_zone(p_tz) || '] / '
                   || case when (p_at at time zone p_tz)::date = (p_at at time zone 'Asia/Seoul')::date then lms_mail_ko_hour(p_at, 'Asia/Seoul')
                           else lms_mail_ko_when(p_at, 'Asia/Seoul') end || ' [한국 시간]' end
$$;

-- 3. 메일 만들기: 시각 모양 + 굵게 + 학생 취소 → 강사 메일 -----------------------
create or replace function lms_notice_mail(p_notice uuid)
returns table (intended_email text, to_email text, subject text, html text, body text)
language plpgsql stable security definer set search_path = public as $$
declare
  n lesson_notices;
  r makeup_requests;
  cr change_requests;
  l lessons;
  st students;
  tu tutors;
  src lessons;
  v_live boolean := coalesce((select f.enabled from feature_flags f where f.key = 'send_emails'), false);
  v_comp boolean;
  v_fix boolean;
  v_old timestamptz;
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
  if not found then return; end if;

  -- 학생이 수업을 취소 → 그 수업 강사에게 (강사가 직접 취소한 건·학생 안내는 메일 없음)
  if n.event = 'change' then
    if n.recipient_kind <> 'tutor' or n.change_request_id is null then return; end if;
    select * into cr from change_requests where id = n.change_request_id;
    if not found or cr.type <> 'student_cancel' then return; end if;
    select * into l from lessons where id = cr.lesson_id;
    select * into st from students where id = l.student_id;
    select * into tu from tutors where id = n.recipient_id;
    v_minutes := round(extract(epoch from l.ends_at - l.starts_at) / 60)::int;
    intended_email := lms_notice_recipient_email(n.recipient_kind, n.recipient_id);
    to_email := case when v_live then intended_email else 'support@edgeenglish.kr' end;
    if not v_live then v_test := '[시험 · ' || st.code || '] '; end if;
    subject := v_test || '[Edge English] Class canceled - ' || coalesce(nullif(st.name_en, ''), st.name_ko)
               || ' · ' || lms_mail_en_when(l.starts_at, tu.timezone) || ' ' || lms_mail_en_zone(tu.timezone);
    v_lines := array[
      'CANCELED - ' || coalesce(nullif(st.name_en, ''), st.name_ko) || ' (' || v_minutes || ' min)',
      'Class: ' || lms_mail_en_at(l.starts_at, tu.timezone),
      'Canceled by student on ' || lms_mail_en_at(coalesce(cr.requested_at, cr.created_at), tu.timezone)];
    if (cr.decision ->> 'timing') = 'late' then v_lines := v_lines || 'Late cancel (less than 6 hours before class)'; end if;
    v_btn := 'Open Edge English LMS';
    v_foot := 'Reply to this email or message us on WhatsApp if you have a question.';
    v_url := v_url || '/tutor';
    body := lms_strip_bold(array_to_string(v_lines, E'\n')) || E'\n\n' || v_btn || ': ' || v_url || E'\n' || v_foot
            || case when v_live then '' else E'\n\n(시험 발송 · 원래 받는 사람: ' || coalesce(intended_email, '없음') || ')' end;
    html := '<div style="font-family:sans-serif;font-size:15px;line-height:1.6;color:#1d1b2a;max-width:480px">'
            || case when v_live then '' else '<p style="background:#fff4d6;color:#5c3b00;border-radius:8px;padding:8px 10px;font-size:13px;font-weight:600">시험 발송 · 원래 받는 사람: ' || lms_html(coalesce(intended_email, '없음')) || '</p>' end
            || '<p style="font-weight:700">' || lms_bold_html(v_lines[1]) || '</p>'
            || '<p>' || lms_bold_html(v_lines[2]) || '<br>' || lms_bold_html(v_lines[3])
            || case when cardinality(v_lines) >= 4 then '<br><b>' || lms_html(v_lines[4]) || '</b>' else '' end || '</p>'
            || '<p><a href="' || lms_html(v_url) || '" style="display:inline-block;background:#5b3df0;color:#fff;border-radius:10px;padding:11px 18px;font-weight:700;text-decoration:none">' || lms_html(v_btn) || '</a></p>'
            || '<p style="font-size:12.5px;color:#55526a;border-top:1px solid #e6e3ef;padding-top:10px">' || lms_html(v_foot) || '</p></div>';
    return next;
    return;
  end if;

  if n.event not in ('makeup_confirmed', 'makeup_rescheduled') or n.makeup_request_id is null then return; end if;
  select * into r from makeup_requests where id = n.makeup_request_id;
  if r.confirmed_lesson_id is null then return; end if;
  select * into l from lessons where id = r.confirmed_lesson_id;
  select * into st from students where id = l.student_id;
  select * into tu from tutors where id = l.tutor_id;
  v_comp := r.compensation_id is not null;
  v_fix := n.event = 'makeup_rescheduled';
  if v_fix then
    select g.old_starts_at into v_old from admin_makeup_logs g
    where g.makeup_request_id = r.id and g.action = 'reschedule' and g.created_at <= n.created_at
    order by g.created_at desc limit 1;
  end if;
  v_minutes := round(extract(epoch from l.ends_at - l.starts_at) / 60)::int;
  if r.source_lesson_id is not null then select * into src from lessons where id = r.source_lesson_id; end if;
  if v_comp and src.id is null then
    select x.* into src from compensations c join lessons x on x.id = c.source_lesson_id where c.id = r.compensation_id;
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
    subject := v_test || '[엣지영어] '
               || case when v_fix then case when v_comp then '무료 보상수업 시간이 바뀌었어요' else '보강 시간이 바뀌었어요' end
                       else case when v_comp then '무료 보상수업이 확정됐어요' else '보강이 확정됐어요' end end
               || ' · ' || lms_mail_ko_when(l.starts_at, st.timezone) || ' [' || lms_mail_ko_zone(st.timezone) || ']';
    v_lines := array[
      '[엣지영어] ' || st.name_ko || '님, ' || case when v_fix then case when v_comp then '무료 보상수업 시간이 바뀌었어요' else '보강 시간이 바뀌었어요' end
                                   else case when v_comp then '무료 보상수업이 확정됐어요' else '보강이 확정됐어요' end end,
      case when v_comp then '강사 사정으로 진행하지 못한 수업: ' else '원래 수업: ' end || v_origin,
      case when v_fix then '바뀐 시간: ' when v_comp then '보상수업: ' else '보강 수업: ' end || v_when || ' · ' || v_minutes || '분',
      '강사: ' || tu.name];
    if v_fix and v_old is not null then v_lines := v_lines || ('이전 시간: ' || lms_mail_ko_at(v_old, st.timezone) || ' (취소)'); end if;
    v_btn := 'LMS에서 일정 보기';
    v_foot := '문의: 카카오톡 채널 엣지영어';
    v_url := v_url || '/student';
  else
    v_when := lms_mail_en_at(l.starts_at, tu.timezone);
    v_origin := case when src.id is not null then lms_mail_en_at(src.starts_at, tu.timezone)
                     when v_origin_date is not null then to_char(v_origin_date, 'YYYY-MM-DD') else 'earlier class' end;
    subject := v_test || case when v_fix then 'TIME CHANGED ' else 'CONFIRMED ' end
               || case when v_comp then 'compensation class' else 'make-up' end || ' - ' || coalesce(nullif(st.name_en, ''), st.name_ko)
               || ' · ' || lms_mail_en_when(l.starts_at, tu.timezone) || ' ' || lms_mail_en_zone(tu.timezone);
    v_lines := array[
      case when v_fix then 'TIME CHANGED ' else 'CONFIRMED ' end || case when v_comp then 'compensation class' else 'make-up' end
        || ' - ' || coalesce(nullif(st.name_en, ''), st.name_ko) || ' (' || v_minutes || ' min)',
      'Original class: ' || v_origin,
      case when v_fix then 'New time: ' when v_comp then 'Compensation class: ' else 'Make-up: ' end || v_when,
      case when v_fix then 'Please update your schedule. Thank you!' else 'Please add it to your schedule. Thank you!' end];
    if v_fix and v_old is not null then v_lines := v_lines || ('Previous time (canceled): ' || lms_mail_en_at(v_old, tu.timezone)); end if;
    v_btn := 'Open Edge English LMS';
    v_foot := 'Reply to this email or message us on WhatsApp if you have a question.';
    v_url := v_url || '/tutor';
  end if;

  body := lms_strip_bold(array_to_string(v_lines, E'\n')) || E'\n\n' || v_btn || ': ' || v_url || E'\n' || v_foot
          || case when v_live then '' else E'\n\n(시험 발송 · 원래 받는 사람: ' || coalesce(intended_email, '없음') || ')' end;
  html := '<div style="font-family:sans-serif;font-size:15px;line-height:1.6;color:#1d1b2a;max-width:480px">'
          || case when v_live then '' else '<p style="background:#fff4d6;color:#5c3b00;border-radius:8px;padding:8px 10px;font-size:13px;font-weight:600">시험 발송 · 원래 받는 사람: ' || lms_html(coalesce(intended_email, '없음')) || '</p>' end
          || '<p style="font-weight:700">' || lms_bold_html(v_lines[1]) || '</p>'
          || '<p>' || lms_bold_html(v_lines[2]) || '<br><b>' || lms_bold_html(v_lines[3]) || '</b><br>'
          || case when cardinality(v_lines) >= 5 then '<span style="color:#55526a;text-decoration:line-through">' || lms_bold_html(v_lines[5]) || '</span><br>' else '' end
          || lms_bold_html(v_lines[4]) || '</p>'
          || '<p><a href="' || lms_html(v_url) || '" style="display:inline-block;background:#5b3df0;color:#fff;border-radius:10px;padding:11px 18px;font-weight:700;text-decoration:none">' || lms_html(v_btn) || '</a></p>'
          || '<p style="font-size:12.5px;color:#55526a;border-top:1px solid #e6e3ef;padding-top:10px">' || lms_html(v_foot) || '</p></div>';
  return next;
end $$;
revoke all on function lms_notice_mail(uuid) from public, anon, authenticated;

-- 4. 메일 큐 트리거: 보강 확정·시간 변경 + 학생 취소 때 강사 안내 ----------------
create or replace function lesson_notices_email() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.event in ('makeup_confirmed', 'makeup_rescheduled') or (new.event = 'change' and new.recipient_kind = 'tutor') then
    perform lms_mail_enqueue_notice(new.id);
  end if;
  return null;
end $$;
revoke all on function lesson_notices_email() from public, anon, authenticated;
