-- =====================================================================
-- 보강 신청 정리 (대표 2026-11-09 '①~⑤ 추천대로' + '강사에게 묻기 카드 대시보드에서 제거', 시험 DB 먼저 — 운영 미반영)
--  1) 학생 보강 신청 때 '보강 강사에게 묻기'(makeup_ask, 운영진 WhatsApp 복사) 안내를 더 만들지 않음
--     — 강사는 강사 화면 To-do 에서 바로 확정, 답이 없으면 재촉 메일·자동 만료. 이미 있는 미처리 묻기 안내는 '필요 없음'
--     (lms_makeup_request_core = 20261102100000 그대로 + makeup_ask 넣는 두 줄만 뺌)
--  2) 만료 메일을 안내 줄(lesson_notices event 'makeup_expired', 받는 사람 학생, 복사 불필요)로 → 자동 메일 큐·실패 표시·다시 보내기를
--     다른 자동 메일과 같이 씀(대시보드 '자동 메일 못 보냄' 카드). 문구 = 대표 11/9 (권리 유지 안내)
--     lms_notice_mail = 20261109040000 그대로 + 'makeup_expired' 갈래 · 트리거에 'makeup_expired' 추가
--  3) student_makeup_withdraw: 강사 확정 전(requested·countered) 학생이 직접 신청 취소 → 'withdrawn', 보강권 그대로,
--     강사 To-do 에서 바로 빠짐, 변경권은 되돌리지 않음(취소 때 쓴 변경권 그대로). 운영자 보기(?student=)도 같은 함수
--  4) student_screen: 신청 내역에 'withdrawn'(신청 취소)도
-- 다시 실행해도 같은 결과
-- =====================================================================

-- 1. 안내 종류: 만료 ---------------------------------------------------------------
alter table lesson_notices drop constraint if exists lesson_notices_event_check;
alter table lesson_notices add constraint lesson_notices_event_check check (event in (
  'change', 'makeup_ask', 'makeup_confirmed', 'makeup_voided', 'revert', 'leave_options', 'sub_ask', 'sub_student', 'sub_confirmed',
  'makeup_rescheduled', 'makeup_tutor_removed', 'makeup_expired'));

-- 2. 신청: 강사에게 묻기 안내 없음 --------------------------------------------------
create or replace function lms_makeup_request_core(p_lesson uuid, p_item uuid, p_slots jsonb, p_requested_at timestamptz, p_via text, p_actor uuid,
                                                   p_comp uuid default null)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  s record;
  c record;
  e enrollments;
  v_id uuid;
  x jsonb;
  t timestamptz;
begin
  if jsonb_typeof(p_slots) <> 'array' or jsonb_array_length(p_slots) = 0 then raise exception '보강 시간을 하나 이상 넣어 주세요.'; end if;
  perform set_config('app.actor_id', coalesce(p_actor::text, ''), true);
  perform set_config('app.actor_via', 'lms_makeup_request_core', true);
  if p_comp is not null then
    perform 1 from compensations where id = p_comp for update;   -- 같은 보상권 동시 신청 막기
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
  return jsonb_build_object('makeup_request_id', v_id, 'repeated', false);
end $$;
revoke all on function lms_makeup_request_core(uuid, uuid, jsonb, timestamptz, text, uuid, uuid) from public, anon, authenticated;

-- 이미 있는 미처리 '강사에게 묻기' 안내 → 필요 없음 (신청·강사 To-do 는 그대로)
update lesson_notices set status = 'not_needed' where event = 'makeup_ask' and status = 'pending';

-- 3. 만료 메일 ---------------------------------------------------------------------
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
end $$;
revoke all on function lms_notice_mail(uuid) from public, anon, authenticated;

create or replace function lesson_notices_email() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.event in ('makeup_confirmed', 'makeup_rescheduled', 'makeup_tutor_removed', 'change', 'makeup_expired') then
    perform lms_mail_enqueue_notice(new.id);
  end if;
  return null;
end $$;
revoke all on function lesson_notices_email() from public, anon, authenticated;

create or replace function lms_makeup_expire_run(p_now timestamptz default now()) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  x record;
  v_n integer := 0;
  v_mail integer := 0;
  v_k integer;
begin
  perform set_config('app.actor_via', 'lms_makeup_expire_run', true);
  for x in
    update makeup_requests r set status = 'expired', decided_at = p_now
    where r.status in ('requested', 'countered')
      and exists (select 1 from makeup_candidates c where c.request_id = r.id and c.proposed_by = 'student')
      and not exists (select 1 from makeup_candidates c where c.request_id = r.id and c.proposed_by = 'student' and c.starts_at > p_now)
    returning r.id, r.student_id
  loop
    v_n := v_n + 1;
    update lesson_notices set status = 'not_needed' where makeup_request_id = x.id and status = 'pending';
    -- 학생 메일 1통: 안내 줄이 생기면 트리거가 메일 큐에 (신청당 1줄 — 다시 실행해도 한 번만)
    insert into lesson_notices (makeup_request_id, event, recipient_kind, recipient_id, status)
    values (x.id, 'makeup_expired', 'student', x.student_id, 'not_needed')
    on conflict do nothing;
    get diagnostics v_k = row_count;
    v_mail := v_mail + v_k;
  end loop;
  return jsonb_build_object('expired', v_n, 'mailed', v_mail);
end $$;
revoke all on function lms_makeup_expire_run(timestamptz) from public, anon, authenticated;

-- 4. 학생 직접 신청 취소 (강사 확정 전) ---------------------------------------------
create or replace function student_makeup_withdraw(p_student uuid, p_request uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_student uuid := lms_screen_student(p_student);
  r makeup_requests;
begin
  select * into r from makeup_requests where id = p_request for update;
  if not found or r.student_id <> v_student then raise exception '본인 신청만 취소할 수 있습니다.' using errcode = '42501'; end if;
  if r.status = 'withdrawn' then return jsonb_build_object('makeup_request_id', r.id, 'repeated', true); end if;
  if r.status not in ('requested', 'countered') then raise exception '이미 확정됐거나 끝난 신청이에요.'; end if;
  perform set_config('app.actor_id', coalesce(auth.uid()::text, ''), true);
  perform set_config('app.actor_via', case when is_admin() then 'student_makeup_withdraw(운영자 대신)' else 'student_makeup_withdraw' end, true);
  update makeup_requests set status = 'withdrawn', decided_at = now(), decided_by = auth.uid() where id = r.id;
  update lesson_notices set status = 'not_needed' where makeup_request_id = r.id and status = 'pending';
  return jsonb_build_object('makeup_request_id', r.id, 'repeated', false);
end $$;
revoke all on function student_makeup_withdraw(uuid, uuid) from public, anon;
grant execute on function student_makeup_withdraw(uuid, uuid) to authenticated;

-- 5. 학생 화면: 신청 취소도 신청 내역에 ---------------------------------------------
create or replace function student_screen(p_student uuid)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_student uuid := lms_screen_student(p_student);
  st students;
  e enrollments;
  v_period enrollment_periods;
  v_open uuid[];
  v_today date := (now() at time zone 'Asia/Seoul')::date;
begin
  select * into st from students where id = v_student;
  select * into e from enrollments where id = lms_student_enrollment(v_student);
  select * into v_period from enrollment_periods p
  where p.enrollment_id = e.id and p.start_date <= v_today order by p.idx desc limit 1;
  v_open := array(select x.id from enrollments x where x.student_id = v_student and (x.status in ('active', 'confirmed') or x.id = e.id));
  return jsonb_build_object(
    'student', jsonb_build_object('id', st.id, 'code', st.code, 'name_ko', st.name_ko, 'timezone', st.timezone),
    'enrollment', case when e.id is null then null else jsonb_build_object(
      'id', e.id, 'weeks', e.weeks, 'legacy_label', e.legacy_label, 'weekly_count', e.weekly_count, 'duration_min', e.duration_min,
      'start_date', e.start_date, 'final_end_date', e.final_end_date, 'status', e.status,
      'next_regular_from', lms_next_regular_from(e.id),
      'lessons_total', coalesce((select c.sheet_total from import_checks c where c.enrollment_id = e.id), e.lessons_purchased + e.lessons_carried_in),
      'credits_left', case when v_period.id is null then 0 else credit_balance(v_period.id) end,
      'credits_granted', coalesce(v_period.credits_granted, 0),
      'confirmed_on', (select min((p.confirmed_at at time zone 'Asia/Seoul')::date) from payments p where p.enrollment_id = e.id and p.confirmed_at is not null),
      'renewal_paid', exists (select 1 from enrollments n where n.previous_enrollment_id = e.id and n.status in ('confirmed', 'active'))) end,
    'lessons', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', l.id, 'kind', l.kind, 'starts_at', l.starts_at, 'ends_at', l.ends_at, 'state', l.state, 'class_status', l.class_status,
        'tutor', t.name, 'meet_url', t.meet_url, 'makeup_of', l.makeup_of, 'leave_postponed', lms_is_leave_postponed(l.id),
        'substitute', l.original_tutor_id is not null,
        'leave_open', exists (select 1 from leave_items li where li.lesson_id = l.id and li.lesson_gone_at is null
                              and (li.choice = 'undecided' or (li.choice = 'substitute' and li.sub_stage <> 'confirmed')))) order by l.starts_at)
      from lessons l join tutors t on t.id = l.tutor_id
      where l.enrollment_id = any(v_open) and l.voided_at is null), '[]'::jsonb),
    -- 보강을 받을 수 있는데 아직 날짜가 없는 것 (취소한 수업 · 시트에서 넘어온 날짜 미정 보강 · 강사 노쇼 무료 보상수업)
    -- QA-13 (4500): 보강 수업이 잡힌 뒤 취소(voided 아님)된 원래 수업은 다시 권리가 되지 않음 — 권리는 그 보강 수업의 결과를 따름
    'makeup_rights', coalesce((
      select jsonb_agg(r order by r ->> 'original_at', r ->> 'comp_id' nulls first) from (
        select jsonb_build_object('lesson_id', l.id, 'item_id', null, 'original_at', l.starts_at,
                 'tutor_leave', l.class_status = 'Tutor long-term leave') as r
        from lessons l
        where l.enrollment_id = any(v_open) and l.voided_at is null and (lms_grants_makeup(l.class_status) or l.class_status = 'Tutor long-term leave')
          and not exists (select 1 from lessons x where x.makeup_of = l.id and x.voided_at is null)
        union all
        select jsonb_build_object('lesson_id', null, 'item_id', m.id,
                 'original_at', coalesce((select li.starts_at from leave_items li where li.migrated_item_id = m.id order by li.starts_at limit 1),
                                         m.original_date::timestamp at time zone 'Asia/Seoul'),
                 'time_known', exists (select 1 from leave_items li where li.migrated_item_id = m.id),
                 'tutor_leave', coalesce(m.tutor_leave, false))
        from migrated_items m where m.enrollment_id = any(v_open) and m.kind = 'makeup_open'
          and not exists (select 1 from leave_items li where li.migrated_item_id = m.id and li.lesson_gone_at is null
                          and li.choice in ('undecided', 'substitute'))
        union all
        select jsonb_build_object('lesson_id', null, 'item_id', null, 'comp_id', c.id, 'original_at', src.starts_at,
                 'tutor', t.name, 'use_until', lms_comp_use_until(c.enrollment_id), 'tutor_leave', false)
        from compensations c
        join lessons src on src.id = c.source_lesson_id
        join tutors t on t.id = src.tutor_id
        where c.student_id = v_student and c.status = 'available' and lms_comp_use_until(c.enrollment_id) >= v_today) q), '[]'::jsonb),
    'leave_pending', coalesce((
      select jsonb_agg(jsonb_build_object('id', li.id, 'starts_at', li.starts_at, 'ends_at', li.ends_at) order by li.starts_at)
      from leave_items li
      where li.student_id = v_student and li.lesson_id is null and li.lesson_gone_at is null and li.starts_at > now()
        and (li.choice = 'undecided' or (li.choice = 'substitute' and li.sub_stage <> 'confirmed'))), '[]'::jsonb),
    -- 신청 내역 (4100 + 4500: 확정 수업 상태 · 강사가 모든 후보에 불가 답)
    'makeup_requests', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', r.id, 'status', r.status, 'lesson_id', r.source_lesson_id, 'item_id', r.migrated_item_id, 'comp_id', r.compensation_id,
        'requested_at', r.requested_at, 'confirmed_lesson_id', r.confirmed_lesson_id, 'tutor_answered_at', r.tutor_answered_at,
        'confirmed_state', cl.state,
        'tutor_declined_all', r.tutor_answered_at is not null
          and not exists (select 1 from makeup_candidates c where c.request_id = r.id and c.proposed_by = 'student' and c.tutor_answer = 'yes'),
        'original_at', coalesce(src.starts_at, (select m.original_date::timestamp at time zone 'Asia/Seoul' from migrated_items m where m.id = r.migrated_item_id)),
        'original_time_known', src.id is not null,
        'original_tutor', srct.name,
        'tutor', rt.name,
        'confirmed_at', cl.starts_at,
        'tutor_leave', coalesce(src.class_status = 'Tutor long-term leave',
                                (select m.tutor_leave from migrated_items m where m.id = r.migrated_item_id), false),
        'candidates', (select coalesce(jsonb_agg(c.starts_at order by c.starts_at), '[]'::jsonb) from makeup_candidates c where c.request_id = r.id and c.proposed_by = 'student'))
        order by r.requested_at desc)
      from makeup_requests r
      left join lessons src on src.id = r.source_lesson_id
      left join tutors srct on srct.id = src.tutor_id
      left join tutors rt on rt.id = r.tutor_id
      left join lessons cl on cl.id = r.confirmed_lesson_id
      where r.student_id = v_student and r.status in ('requested', 'countered', 'confirmed', 'expired', 'withdrawn')
        and r.requested_at > now() - interval '60 days'), '[]'::jsonb),
    'leave', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', li.id, 'starts_at', li.starts_at, 'choice', li.choice, 'stage', li.sub_stage, 'sub_tutor', sub.name, 'sub_meet_url', sub.meet_url,
        'lesson_id', li.lesson_id, 'item_id', li.migrated_item_id,
        'off_from', o.starts_at, 'off_to', o.ends_at) order by li.starts_at)
      from leave_items li
      join tutor_time_off o on o.id = li.time_off_id
      left join tutors sub on sub.id = li.sub_tutor_id
      where li.student_id = v_student and li.starts_at > now() and li.lesson_gone_at is null
        and ((li.choice = 'substitute' and li.sub_stage in ('tutor_ok', 'confirmed')) or li.choice = 'wait')), '[]'::jsonb),
    'credit_period', case when v_period.id is null then null else jsonb_build_object('start', v_period.start_date, 'end', v_period.end_date) end,
    -- R-12 (4520): 모든 기간의 잔여 — 미래 수업 취소 미리 보기는 그 수업 날짜가 속한 기간으로
    'credit_periods', coalesce((
      select jsonb_agg(jsonb_build_object('idx', p.idx, 'start', p.start_date, 'end', p.end_date, 'granted', p.credits_granted, 'left', credit_balance(p.id)) order by p.idx)
      from enrollment_periods p where p.enrollment_id = e.id), '[]'::jsonb),
    'credit_uses', coalesce((
      select jsonb_agg(jsonb_build_object('at', c.created_at, 'reason', c.reason, 'delta', c.delta, 'note', c.note, 'lesson_at', l.starts_at) order by c.created_at)
      from credit_ledger c left join lessons l on l.id = c.lesson_id where c.period_id = v_period.id), '[]'::jsonb),
    'holidays', coalesce((select jsonb_agg(h.day order by h.day) from holidays h
      where h.day between v_today and v_today + 200), '[]'::jsonb),
    'points', coalesce((
      select jsonb_agg(jsonb_build_object('id', g.id, 'on', (g.created_at at time zone 'Asia/Seoul')::date, 'kind', g.kind, 'amount', g.amount, 'note', g.note)
        order by g.created_at)
      from reward_ledger g where g.student_id = v_student), '[]'::jsonb));
end $$;
revoke all on function student_screen(uuid) from public, anon;
grant execute on function student_screen(uuid) to authenticated;
