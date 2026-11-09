-- =====================================================================
-- 학생 메일 시각에 기준 시간대 이름을 항상 붙임 (대표 2026-11-08: 한국 거주 학생도 '한국 시간' 기준이 분명히 보여야 함)
--  - 한 가지 모양, 시간대 이름은 항상 뒤에 한국어로 (대표 2026-11-08 '템플릿 통일')
--  - 한국 거주: '11월 11일(수) 오전 11시 (한국 시간)'
--  - 해외 거주: '11월 12일(목) 오후 7시 (토론토 시간) = 11월 13일(금) 오전 9시 (한국 시간)'
--  - 제목: '보강이 확정됐어요 · 11월 11일(수) 오전 11시 (한국 시간)' (해외는 거주지 시간 하나), 본문 길이는 ' · 40분'
--  - 카톡 복사 문구(src/lms/admin/lesson-change.ts koAt)와 같은 모양. 20261108010000 뒤에 적용. 다시 실행해도 같은 결과
-- =====================================================================

-- '한국 시간' · '멜버른 시간' — 도시 이름은 한국어 (src/lms/admin/places.ts koZoneCity 와 같은 표, vitest 가 대조). 표에 없으면 영어 도시 이름
create or replace function lms_mail_ko_zone(p_tz text) returns text
language sql immutable as $$
  select case when coalesce(nullif(p_tz, ''), 'Asia/Seoul') = 'Asia/Seoul' then '한국'
              else case p_tz
                when 'America/New_York' then '뉴욕'
                when 'America/Detroit' then '디트로이트'
                when 'America/Chicago' then '시카고'
                when 'America/Denver' then '덴버'
                when 'America/Phoenix' then '피닉스'
                when 'America/Los_Angeles' then '로스앤젤레스'
                when 'Pacific/Honolulu' then '호놀룰루'
                when 'America/Anchorage' then '앵커리지'
                when 'America/Toronto' then '토론토'
                when 'America/Vancouver' then '밴쿠버'
                when 'America/Edmonton' then '에드먼턴'
                when 'America/Winnipeg' then '위니펙'
                when 'America/Regina' then '리자이나'
                when 'America/Halifax' then '핼리팩스'
                when 'Australia/Sydney' then '시드니'
                when 'Australia/Melbourne' then '멜버른'
                when 'Australia/Brisbane' then '브리즈번'
                when 'Australia/Perth' then '퍼스'
                when 'Australia/Adelaide' then '애들레이드'
                when 'Australia/Hobart' then '호바트'
                when 'Australia/Darwin' then '다윈'
                when 'Pacific/Auckland' then '오클랜드'
                when 'Europe/London' then '런던'
                when 'Asia/Tokyo' then '도쿄'
                when 'Asia/Shanghai' then '상하이'
                when 'Asia/Hong_Kong' then '홍콩'
                when 'Asia/Taipei' then '타이베이'
                when 'Asia/Singapore' then '싱가포르'
                when 'Asia/Ho_Chi_Minh' then '호찌민'
                when 'Asia/Bangkok' then '방콕'
                when 'Asia/Manila' then '마닐라'
                when 'Asia/Kuala_Lumpur' then '쿠알라룸푸르'
                when 'Asia/Jakarta' then '자카르타'
                when 'Asia/Makassar' then '발리'
                when 'Asia/Dubai' then '두바이'
                when 'Europe/Berlin' then '베를린'
                when 'Europe/Paris' then '파리'
                when 'Europe/Amsterdam' then '암스테르담'
                when 'Europe/Madrid' then '마드리드'
                when 'Europe/Dublin' then '더블린'
                when 'Europe/Warsaw' then '바르샤바'
                else replace(split_part(p_tz, '/', array_length(string_to_array(p_tz, '/'), 1)), '_', ' ') end
         end || ' 시간'
$$;
revoke all on function lms_mail_ko_zone(text) from public, anon, authenticated;

-- 한 가지 모양: 한국 거주 '11월 11일(수) 오전 11시 (한국 시간)'
--              해외 거주 '11월 12일(목) 오후 7시 (토론토 시간) = 11월 13일(금) 오전 9시 (한국 시간)'
create or replace function lms_mail_ko_at(p_at timestamptz, p_tz text) returns text
language sql stable as $$
  select case when coalesce(nullif(p_tz, ''), 'Asia/Seoul') = 'Asia/Seoul' then lms_mail_ko_when(p_at, 'Asia/Seoul') || ' (한국 시간)'
              else lms_mail_ko_when(p_at, p_tz) || ' (' || lms_mail_ko_zone(p_tz) || ') = ' || lms_mail_ko_when(p_at, 'Asia/Seoul') || ' (한국 시간)' end
$$;
revoke all on function lms_mail_ko_at(timestamptz, text) from public, anon, authenticated;

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
      case when v_comp then '강사 노쇼 수업: ' else '원래 수업: ' end || v_origin,
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
