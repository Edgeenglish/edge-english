-- Student cancellation and makeup request emails, including admin-on-behalf.
-- Test environment first. No historical backfill or delivery setting changes.

alter table public.lesson_notices drop constraint lesson_notices_event_check;
alter table public.lesson_notices add constraint lesson_notices_event_check check (event in
('change','makeup_ask','makeup_confirmed','makeup_voided','revert','leave_options','sub_ask','sub_student','sub_confirmed','makeup_rescheduled','makeup_tutor_removed','makeup_expired','makeup_requested'));

CREATE OR REPLACE FUNCTION public.lms_notice_mail(p_notice uuid)
 RETURNS TABLE(intended_email text, to_email text, subject text, html text, body text)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
  v_until date;
  v_reward integer;
  v_paras text[];
  g admin_makeup_logs;
  v_tchg boolean := false;
  v_tmchg boolean := true;
  v_otu tutors;
  v_what text;
begin
  select * into n from lesson_notices where id = p_notice;
  if not found then return; end if;

  -- Student and admin-on-behalf requests use the same notification path.
  if n.event = 'makeup_requested' or (n.event = 'change' and n.recipient_kind = 'student'
      and exists (select 1 from change_requests c where c.id = n.change_request_id and c.type = 'student_cancel')) then
    if n.event = 'change' then
      select * into cr from change_requests where id = n.change_request_id;
      if not found or cr.type <> 'student_cancel' then return; end if;
      select * into l from lessons where id = cr.lesson_id;
      select * into st from students where id = l.student_id;
      select * into tu from tutors where id = l.tutor_id;
      subject := '[엣지영어] 수업이 취소되었습니다';
      v_lines := array[
        st.name_ko || '님, 수업이 취소되었습니다.',
        '취소된 수업: ' || lms_mail_ko_at(l.starts_at, st.timezone),
        case when lms_grants_makeup(l.class_status) then '보강 날짜는 LMS에서 골라 주세요.' else '이번 수업은 차감되며 보강은 제공되지 않습니다.' end
      ];
      v_btn := case when lms_grants_makeup(l.class_status) then '보강 날짜 고르기' else 'LMS 일정 보기' end;
      v_url := v_url || '/student' || case when lms_grants_makeup(l.class_status) then '?makeup=' || l.id else '' end;
    else
      select * into r from makeup_requests where id = n.makeup_request_id;
      if not found then return; end if;
      select * into st from students where id = r.student_id;
      select * into tu from tutors where id = r.tutor_id;
      v_comp := r.compensation_id is not null;
      if n.recipient_kind = 'student' then
        v_what := case when v_comp then '보상수업' else '보강' end;
        subject := '[엣지영어] ' || v_what || ' 신청이 접수되었습니다';
        v_lines := array[st.name_ko || '님, ' || v_what || ' 신청이 접수되었습니다.', '강사님 확인 후 확정됩니다.'];
        select v_lines || coalesce(array_agg('신청 시간: ' || lms_mail_ko_at(c.starts_at, st.timezone) order by c.starts_at), array[]::text[])
          into v_lines from makeup_candidates c where c.request_id = r.id and c.proposed_by = 'student';
        v_lines := v_lines || ('담당 강사: ' || tu.name);
        v_btn := 'LMS에서 확인하기';
        v_url := v_url || '/student';
      else
        subject := '[Edge English] New ' || case when v_comp then 'compensation class' else 'make-up' end || ' request - ' || coalesce(nullif(st.name_en, ''), st.name_ko);
        v_lines := array['New ' || case when v_comp then 'compensation class' else 'make-up' end || ' request - ' || coalesce(nullif(st.name_en, ''), st.name_ko),
                         'Please confirm a time in the LMS.'];
        select v_lines || coalesce(array_agg('Requested time: ' || lms_mail_en_at(c.starts_at, tu.timezone) order by c.starts_at), array[]::text[])
          into v_lines from makeup_candidates c where c.request_id = r.id and c.proposed_by = 'student';
        v_btn := 'Open Edge English LMS';
        v_url := v_url || '/tutor';
      end if;
    end if;
    intended_email := lms_notice_recipient_email(n.recipient_kind, n.recipient_id);
    to_email := case when v_live then intended_email else 'support@edgeenglish.kr' end;
    if not v_live then subject := '[시험 · ' || st.code || '] ' || subject; end if;
    v_foot := case when n.recipient_kind = 'student' then '문의: 카카오톡 채널 엣지영어' else 'Reply to this email or message us on WhatsApp if you have a question.' end;
    body := lms_strip_bold(array_to_string(v_lines, E'\n')) || E'\n\n' || v_btn || ': ' || v_url || E'\n' || v_foot;
    select '<div style="font-family:sans-serif;font-size:15px;line-height:1.6;color:#1d1b2a;max-width:480px">' ||
      string_agg('<p>' || lms_bold_html(line) || '</p>', '' order by ord) ||
      '<p><a href="' || lms_html(v_url) || '" style="display:inline-block;background:#5b3df0;color:#fff;border-radius:10px;padding:11px 18px;font-weight:700;text-decoration:none">' || lms_html(v_btn) || '</a></p><p>' || lms_html(v_foot) || '</p></div>'
      into html from unnest(v_lines) with ordinality as lines(line, ord);
    return next;
    return;
  end if;


  -- 보강 신청 자동 만료 → 수강생 메일 1통 (대표 11/9 문구, lms_makeup_expire_run 이 안내 줄을 '복사 불필요'로 넣음)
  if n.event = 'makeup_expired' then
    select * into r from makeup_requests where id = n.makeup_request_id;
    if not found then return; end if;
    select * into st from students where id = r.student_id;
    v_comp := r.compensation_id is not null;
    intended_email := lms_notice_recipient_email('student', r.student_id);
    to_email := case when v_live then intended_email else 'support@edgeenglish.kr' end;
    if not v_live then v_test := '[시험 · ' || st.code || '] '; end if;
    v_what := case when v_comp then '보상수업' else '보강' end;
    subject := v_test || '[엣지영어] ' || v_what || ' 신청이 만료되었습니다';
    v_paras := array[
      st.name_ko || '님, 신청하신 ' || v_what || ' 시간이 강사님 확정 전에 지나 신청이 만료되었습니다.',
      case when v_comp then '보상수업을' else '보강 수업을' end || ' 받을 권리는 그대로 유지됩니다. 아래 버튼을 눌러 새로운 시간을 선택해 주세요.'];
    v_btn := v_what || ' 날짜 다시 고르기';
    v_url := v_url || '/student?makeup=' || coalesce(r.compensation_id, r.source_lesson_id, r.migrated_item_id);
    v_foot := '문의: 카카오톡 채널 엣지영어';
    body := array_to_string(v_paras, E'\n\n') || E'\n\n' || v_btn || ': ' || v_url || E'\n' || v_foot
            || case when v_live then '' else E'\n\n(시험 발송 · 원래 받는 사람: ' || coalesce(intended_email, '없음') || ')' end;
    html := '<div style="font-family:sans-serif;font-size:15px;line-height:1.6;color:#1d1b2a;max-width:480px">'
            || case when v_live then '' else '<p style="background:#fff4d6;color:#5c3b00;border-radius:8px;padding:8px 10px;font-size:13px;font-weight:600">시험 발송 · 원래 받는 사람: ' || lms_html(coalesce(intended_email, '없음')) || '</p>' end
            || '<p style="font-weight:700">' || lms_html(v_paras[1]) || '</p>'
            || '<p>' || lms_html(v_paras[2]) || '</p>'
            || '<p><a href="' || lms_html(v_url) || '" style="display:inline-block;background:#5b3df0;color:#fff;border-radius:10px;padding:11px 18px;font-weight:700;text-decoration:none">' || lms_html(v_btn) || '</a></p>'
            || '<p style="font-size:12.5px;color:#55526a;border-top:1px solid #e6e3ef;padding-top:10px">' || lms_html(v_foot) || '</p></div>';
    return next;
    return;
  end if;

  -- 강사 사정 취소(운영진이 '강사 취소'로 기록) → 수강생(한국어)·강사(영어) 둘 다 (대표 11/9, 문구 = 카톡·WhatsApp 안내 그대로)
  if n.event = 'change' and n.change_request_id is not null then
    select * into cr from change_requests where id = n.change_request_id;
    if found and cr.type = 'tutor_cancel' then
      select * into l from lessons where id = cr.lesson_id;
      select * into st from students where id = l.student_id;
      select * into tu from tutors where id = l.tutor_id;
      v_minutes := round(extract(epoch from l.ends_at - l.starts_at) / 60)::int;
      v_until := nullif(cr.decision ->> 'makeup_until', '')::date;
      if not coalesce((cr.decision ->> 'makeup_allowed')::boolean, false) then v_until := null; end if;
      v_reward := coalesce((cr.decision ->> 'reward_won')::int, 0);
      intended_email := lms_notice_recipient_email(n.recipient_kind, n.recipient_id);
      to_email := case when v_live then intended_email else 'support@edgeenglish.kr' end;
      if not v_live then v_test := '[시험 · ' || st.code || '] '; end if;
      if n.recipient_kind = 'student' then
        subject := v_test || '[엣지영어] 강사 사정으로 수업이 취소됐어요 · ' || lms_mail_ko_when(l.starts_at, st.timezone) || ' [' || lms_mail_ko_zone(st.timezone) || ']';
        v_paras := array[
          '[엣지영어] ' || st.name_ko || '님, 강사 사정으로 수업이 취소됐어요.',
          '취소된 수업: ' || lms_mail_ko_at(l.starts_at, st.timezone) || ' · ' || v_minutes || '분',
          case when v_reward > 0
               then '불편을 드려 정말 죄송합니다. 사과의 마음으로 다음 수강 등록 시 사용하실 수 있는 적립금 ' || to_char(v_reward, 'FM999,999,999') || '원을 드렸어요 (유효기간 없음).'
               else '불편을 드려 정말 죄송합니다.' end];
        if v_until is not null then
          v_paras := v_paras || ('아래 버튼에서 보강 날짜를 신청해 주세요. 강사님이 확인하면 확정돼요.' || E'\n'
                                 || '수업 중에 강사님과 정한 시간이 있다면 그 시간을 골라 주세요.' || E'\n'
                                 || '(신청 기한: ' || lms_mail_ko_at((v_until + 1)::timestamp at time zone 'Asia/Seoul' - interval '1 minute', st.timezone) || '까지)')::text;
          v_btn := '보강 날짜 고르기';
          v_url := v_url || '/student?makeup=' || l.id;
        else
          v_btn := 'LMS에서 일정 보기';
          v_url := v_url || '/student';
        end if;
        v_foot := '문의: 카카오톡 채널 엣지영어';
      else
        subject := v_test || '[Edge English] Class canceled (tutor) - ' || coalesce(nullif(st.name_en, ''), st.name_ko)
                   || ' · ' || lms_mail_en_when(l.starts_at, tu.timezone) || ' ' || lms_mail_en_zone(tu.timezone);
        v_paras := array[
          'CANCELED (tutor) - ' || coalesce(nullif(st.name_en, ''), st.name_ko) || ' (' || v_minutes || ' min)'
            || E'\n' || 'Class: ' || lms_mail_en_at(l.starts_at, tu.timezone)
            || E'\n' || 'No class at this time.'];
        if v_until is not null then
          v_paras := v_paras || ('Make-up: you can agree on a make-up time with your student during class (until '
                                 || lms_mail_en_at((v_until + 1)::timestamp at time zone 'Asia/Seoul' - interval '1 minute', tu.timezone)
                                 || '). Make sure that time is open in your Availability, then ask the student to request it in the LMS.' || E'\n'
                                 || 'When the request comes in, tap "Confirm make-up". If the student can''t find the time, let us know.')::text;
        end if;
        v_btn := 'Open Edge English LMS';
        v_foot := 'Reply to this email or message us on WhatsApp if you have a question.';
        v_url := v_url || '/tutor';
      end if;
      body := lms_strip_bold(array_to_string(v_paras, E'\n\n')) || E'\n\n' || v_btn || ': ' || v_url || E'\n' || v_foot
              || case when v_live then '' else E'\n\n(시험 발송 · 원래 받는 사람: ' || coalesce(intended_email, '없음') || ')' end;
      html := '<div style="font-family:sans-serif;font-size:15px;line-height:1.6;color:#1d1b2a;max-width:480px">'
              || case when v_live then '' else '<p style="background:#fff4d6;color:#5c3b00;border-radius:8px;padding:8px 10px;font-size:13px;font-weight:600">시험 발송 · 원래 받는 사람: ' || lms_html(coalesce(intended_email, '없음')) || '</p>' end
              || '<p style="font-weight:700">' || replace(lms_bold_html(v_paras[1]), E'\n', '<br>') || '</p>';
      for i in 2 .. cardinality(v_paras) loop
        html := html || '<p>' || replace(lms_bold_html(v_paras[i]), E'\n', '<br>') || '</p>';
      end loop;
      html := html
              || '<p><a href="' || lms_html(v_url) || '" style="display:inline-block;background:#5b3df0;color:#fff;border-radius:10px;padding:11px 18px;font-weight:700;text-decoration:none">' || lms_html(v_btn) || '</a></p>'
              || '<p style="font-size:12.5px;color:#55526a;border-top:1px solid #e6e3ef;padding-top:10px">' || lms_html(v_foot) || '</p></div>';
      return next;
      return;
    end if;
  end if;

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
    if (cr.decision ->> 'timing') = 'late' then v_lines := v_lines || 'Late cancel (less than 6 hours before class)'::text; end if;
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

  if n.event not in ('makeup_confirmed', 'makeup_rescheduled', 'makeup_tutor_removed') or n.makeup_request_id is null then return; end if;
  select * into r from makeup_requests where id = n.makeup_request_id;
  if r.confirmed_lesson_id is null then return; end if;
  select * into l from lessons where id = r.confirmed_lesson_id;
  select * into st from students where id = l.student_id;
  select * into tu from tutors where id = l.tutor_id;
  v_comp := r.compensation_id is not null;
  v_fix := n.event = 'makeup_rescheduled';
  if v_fix or n.event = 'makeup_tutor_removed' then
    select x.* into g from admin_makeup_logs x
    where x.makeup_request_id = r.id and x.action = 'reschedule' and x.created_at <= n.created_at
    order by x.created_at desc limit 1;
    v_old := g.old_starts_at;
    -- 운영진 수업 수정(20261109040000): 강사·시간 중 무엇이 바뀌었는지. 예전 기록(강사 칸 없음)은 시간만 바뀐 것
    v_tchg := g.old_tutor_id is not null and g.new_tutor_id is not null and g.old_tutor_id <> g.new_tutor_id;
    v_tmchg := g.old_starts_at is distinct from g.new_starts_at;
    if v_tchg then select * into v_otu from tutors where id = g.old_tutor_id; end if;
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

  if n.event = 'makeup_tutor_removed' then
    if n.recipient_kind <> 'tutor' then return; end if;
    select * into tu from tutors where id = n.recipient_id;
    v_when := lms_mail_en_at(coalesce(v_old, l.starts_at), tu.timezone);
    subject := v_test || 'CANCELED ' || case when v_comp then 'compensation class' else 'make-up' end || ' - ' || coalesce(nullif(st.name_en, ''), st.name_ko)
               || ' · ' || lms_mail_en_when(coalesce(v_old, l.starts_at), tu.timezone) || ' ' || lms_mail_en_zone(tu.timezone);
    v_lines := array[
      'CANCELED ' || case when v_comp then 'compensation class' else 'make-up' end || ' - ' || coalesce(nullif(st.name_en, ''), st.name_ko) || ' (' || v_minutes || ' min)',
      case when v_comp then 'Compensation class: ' else 'Make-up: ' end || v_when,
      'No class at this time. Please remove it from your schedule. Thank you!'];
    v_btn := 'Open Edge English LMS';
    v_foot := 'Reply to this email or message us on WhatsApp if you have a question.';
    v_url := v_url || '/tutor';
    body := lms_strip_bold(array_to_string(v_lines, E'\n')) || E'\n\n' || v_btn || ': ' || v_url || E'\n' || v_foot
            || case when v_live then '' else E'\n\n(시험 발송 · 원래 받는 사람: ' || coalesce(intended_email, '없음') || ')' end;
    html := '<div style="font-family:sans-serif;font-size:15px;line-height:1.6;color:#1d1b2a;max-width:480px">'
            || case when v_live then '' else '<p style="background:#fff4d6;color:#5c3b00;border-radius:8px;padding:8px 10px;font-size:13px;font-weight:600">시험 발송 · 원래 받는 사람: ' || lms_html(coalesce(intended_email, '없음')) || '</p>' end
            || '<p style="font-weight:700">' || lms_bold_html(v_lines[1]) || '</p>'
            || '<p><b>' || lms_bold_html(v_lines[2]) || '</b><br>' || lms_bold_html(v_lines[3]) || '</p>'
            || '<p><a href="' || lms_html(v_url) || '" style="display:inline-block;background:#5b3df0;color:#fff;border-radius:10px;padding:11px 18px;font-weight:700;text-decoration:none">' || lms_html(v_btn) || '</a></p>'
            || '<p style="font-size:12.5px;color:#55526a;border-top:1px solid #e6e3ef;padding-top:10px">' || lms_html(v_foot) || '</p></div>';
    return next;
    return;
  end if;

  if n.recipient_kind = 'student' then
    v_what := case when v_tchg and v_tmchg then '시간·강사가' when v_tchg then '강사가' else '시간이' end;
    v_when := lms_mail_ko_at(l.starts_at, st.timezone);
    v_origin := case when src.id is not null then lms_mail_ko_at(src.starts_at, st.timezone)
                     when v_origin_date is not null then extract(month from v_origin_date)::int || '월 ' || extract(day from v_origin_date)::int || '일'
                     else '시트 기록 보강' end;
    subject := v_test || '[엣지영어] '
               || case when v_fix then case when v_comp then '무료 보상수업 ' else '보강 ' end || v_what || ' 바뀌었어요'
                       else case when v_comp then '무료 보상수업이 확정됐어요' else '보강이 확정됐어요' end end
               || ' · ' || lms_mail_ko_when(l.starts_at, st.timezone) || ' [' || lms_mail_ko_zone(st.timezone) || ']';
    v_lines := array[
      '[엣지영어] ' || st.name_ko || '님, ' || case when v_fix then case when v_comp then '무료 보상수업 ' else '보강 ' end || v_what || ' 바뀌었어요'
                                   else case when v_comp then '무료 보상수업이 확정됐어요' else '보강이 확정됐어요' end end,
      case when v_comp then '강사 사정으로 진행하지 못한 수업: ' else '원래 수업: ' end || v_origin,
      case when v_fix and v_tmchg then '바뀐 시간: ' when v_comp then '보상수업: ' else '보강 수업: ' end || v_when || ' · ' || v_minutes || '분',
      '강사: ' || tu.name];
    if v_fix and v_old is not null and v_tchg and v_tmchg then v_lines := v_lines || ('이전: ' || lms_mail_ko_at(v_old, st.timezone) || ' · ' || v_otu.name || ' (취소)');
    elsif v_fix and v_tchg then v_lines := v_lines || ('이전 강사: ' || v_otu.name);
    elsif v_fix and v_old is not null then v_lines := v_lines || ('이전 시간: ' || lms_mail_ko_at(v_old, st.timezone) || ' (취소)'); end if;
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
end $function$
;

CREATE OR REPLACE FUNCTION public.lesson_notices_email()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if new.event in ('makeup_confirmed', 'makeup_rescheduled', 'makeup_tutor_removed', 'change', 'makeup_expired', 'makeup_requested') then
    perform lms_mail_enqueue_notice(new.id);
  end if;
  return null;
end $function$
;

CREATE OR REPLACE FUNCTION public.lms_makeup_options(p_lesson uuid, p_item uuid, p_comp uuid DEFAULT NULL::uuid)
 RETURNS TABLE(section text, starts_at timestamp with time zone, ends_at timestamp with time zone)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  s record;
  e enrollments;
  v_leave boolean;
  v_back date;
  v_until date;
  v_today date := (now() at time zone 'Asia/Seoul')::date;
begin
  if p_comp is not null then
    select * into s from lms_comp_source(p_comp);
    select * into e from enrollments where id = s.enrollment_id;
    v_leave := false;
    v_back := v_today;
    v_until := s.use_until;
  else
    select * into s from lms_makeup_source(p_lesson, p_item);
    select * into e from enrollments where id = s.enrollment_id;
    v_leave := s.tutor_leave;
    select (o.ends_at at time zone 'Asia/Seoul')::date into v_back
    from leave_items li join tutor_time_off o on o.id = li.time_off_id
    where (li.lesson_id = p_lesson or li.migrated_item_id = p_item) limit 1;
    v_back := coalesce(v_back, v_today);
    v_until := e.final_end_date;
  end if;

  return query
  with rs as (
    select r.weekday, r.start_time_kst from regular_schedules r
    where r.student_id = s.student_id and r.tutor_id = s.tutor_id and (r.effective_to is null or r.effective_to >= v_today)
  ),
  slots as (
    select 'in_period'::text as sec, ((d::date::timestamp + make_interval(mins => n * 30)) at time zone 'Asia/Seoul') as x
    from generate_series(greatest(v_today, v_back), v_until, interval '1 day') d
    cross join generate_series(0, 47) n
    union all
    select 'after_end', ((d::date + rs.start_time_kst) at time zone 'Asia/Seoul')
    from generate_series(greatest(e.final_end_date + 1, v_back, v_today), greatest(e.final_end_date + 1, v_back, v_today) + 180, interval '1 day') d
    join rs on rs.weekday = extract(dow from d)
    where v_leave
  ),
  free as (
    select y.sec, y.x, y.x + make_interval(mins => e.duration_min) as f from slots y
    where y.x > now()
      and not exists (select 1 from lessons original where original.id = p_lesson and original.starts_at = y.x)
      and lms_tutor_available(s.tutor_id, y.x)
      and lms_makeup_conflict(s.tutor_id, s.student_id, y.x, y.x + make_interval(mins => e.duration_min), true) is null
      and not exists (select 1 from lessons l where l.student_id = s.student_id and l.state <> 'canceled'
                      and l.starts_at < y.x + make_interval(mins => e.duration_min) and y.x < l.ends_at)
  )
  select z.sec, z.x, z.f from (select f1.*, row_number() over (partition by f1.sec order by f1.x) as n from free f1) z
  where z.sec = 'in_period' or z.n <= 1
  order by z.x;
end $function$
;

CREATE OR REPLACE FUNCTION public.lms_makeup_request_core(p_lesson uuid, p_item uuid, p_slots jsonb, p_requested_at timestamp with time zone, p_via text, p_actor uuid, p_comp uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  s record;
  c record;
  e enrollments;
  v_id uuid;
  x jsonb;
  t timestamptz;
begin
  if jsonb_typeof(p_slots) <> 'array' or jsonb_array_length(p_slots) = 0 then raise exception '보강 시간을 하나 이상 넣어 주세요.'; end if;
  if p_lesson is not null and exists (
    select 1 from jsonb_array_elements(p_slots) slot
    join lessons original on original.id = p_lesson
      and original.starts_at = (slot ->> 'starts_at')::timestamptz
  ) then raise exception '취소한 수업의 원래 시간은 보강으로 신청할 수 없습니다.' using hint = 'original_slot'; end if;
  perform set_config('app.actor_id', coalesce(p_actor::text, ''), true);
  perform set_config('app.actor_via', 'lms_makeup_request_core', true);
  if p_comp is not null then
    perform 1 from compensations where id = p_comp for update;
    select * into c from lms_comp_source(p_comp);
    select * into e from enrollments where id = c.enrollment_id;
    select id into v_id from makeup_requests where status in ('requested', 'countered') and compensation_id = p_comp;
    if found then return jsonb_build_object('makeup_request_id', v_id, 'repeated', true); end if;
    insert into makeup_requests (source_lesson_id, compensation_id, student_id, tutor_id, via, requested_at, requested_by)
    values (c.source_lesson_id, p_comp, c.student_id, c.tutor_id, p_via, coalesce(p_requested_at, now()), p_actor)
    returning id into v_id;
    for x in select * from jsonb_array_elements(p_slots) loop
      t := (x ->> 'starts_at')::timestamptz;
      if t <= now() then raise exception '지난 시간은 보강으로 넣을 수 없습니다.'; end if;
      if t >= ((c.use_until + 1)::timestamp at time zone 'Asia/Seoul') then
        raise exception '보상수업 사용 기한(%) 뒤의 시간입니다.', c.use_until using hint = 'after_end';
      end if;
      insert into makeup_candidates (request_id, starts_at, ends_at, proposed_by)
      values (v_id, t, t + make_interval(mins => e.duration_min), 'student');
    end loop;
    insert into lesson_notices (makeup_request_id, event, recipient_kind, recipient_id, status)
      select v_id, 'makeup_requested', kind, id, 'not_needed'
      from (select 'student'::text as kind, student_id as id from makeup_requests where id = v_id
            union all select 'tutor', tutor_id from makeup_requests where id = v_id) recipients;
    return jsonb_build_object('makeup_request_id', v_id, 'repeated', false);
  end if;
  select * into s from lms_makeup_source(p_lesson, p_item);
  select * into e from enrollments where id = s.enrollment_id;
  select id into v_id from makeup_requests
  where status in ('requested', 'countered') and compensation_id is null and (source_lesson_id = p_lesson or migrated_item_id = p_item);
  if found then return jsonb_build_object('makeup_request_id', v_id, 'repeated', true); end if;
  insert into makeup_requests (source_lesson_id, migrated_item_id, student_id, tutor_id, via, requested_at, requested_by)
  values (p_lesson, p_item, s.student_id, s.tutor_id, p_via, coalesce(p_requested_at, now()), p_actor)
  returning id into v_id;
  for x in select * from jsonb_array_elements(p_slots) loop
    t := (x ->> 'starts_at')::timestamptz;
    if t <= now() then raise exception '지난 시간은 보강으로 넣을 수 없습니다.'; end if;
    if not s.tutor_leave and t >= ((e.final_end_date + 1)::timestamp at time zone 'Asia/Seoul') then
      raise exception '수강 종료일(%) 뒤의 시간입니다.', e.final_end_date using hint = 'after_end';
    end if;
    insert into makeup_candidates (request_id, starts_at, ends_at, proposed_by)
    values (v_id, t, t + make_interval(mins => e.duration_min), 'student');
  end loop;
  insert into lesson_notices (makeup_request_id, event, recipient_kind, recipient_id, status)
      select v_id, 'makeup_requested', kind, id, 'not_needed'
      from (select 'student'::text as kind, student_id as id from makeup_requests where id = v_id
            union all select 'tutor', tutor_id from makeup_requests where id = v_id) recipients;
    return jsonb_build_object('makeup_request_id', v_id, 'repeated', false);
end $function$
;

revoke all on function public.lms_notice_mail(uuid), public.lesson_notices_email(), public.lms_makeup_options(uuid,uuid,uuid), public.lms_makeup_request_core(uuid,uuid,jsonb,timestamptz,text,uuid,uuid) from public,anon,authenticated;

