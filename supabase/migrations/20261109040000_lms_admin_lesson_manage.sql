-- =====================================================================
-- 운영진 수업 관리 2차 (2026-11-09 대표 승인 = 정책 원본 H26(103), 시안 https://claude.ai/artifact/FR9ajCE7S1eCchNZEkQf3P)
--  학생 상세 '보강·보상수업' 카드의 [+ 수업 추가]·[수정]
--  1) admin_lesson_add: 보강권(원래 수업·시트 이관) 또는 보상권 하나로 바로 확정. 강사를 고름(기본은 화면에서 담당 강사)
--     = 기존 admin_makeup_confirm_now 와 같은 길(lms_makeup_request_core → lms_makeup_book), 사유 없음 → 선택 메모
--     변경권 차감 없음. 같은 수업분 보강 중복은 lms_makeup_source 가 막고, 동시 저장은 원래 수업 줄 잠금으로 막음
--  2) admin_lesson_edit: 확정된 보강·보상수업의 날짜·시간·강사를 고침. 같은 lesson id, 보강권/보상권 연결·변경권·수업 횟수 그대로
--     makeup_requests.tutor_id 도 새 강사로. 검사 = admin_makeup_reschedule 과 같음(새 강사 기준)
--     안내: 학생 1건(makeup_rescheduled) + 강사: 같은 강사면 makeup_rescheduled 1건,
--           강사가 바뀌면 이전 강사 취소(makeup_tutor_removed) 1건 + 새 강사 확정(makeup_confirmed) 1건
--     아직 안 보낸 예전 확정·변경 안내 카드는 '필요 없음'(최신 1건만)
--  3) 운영 기록(admin_makeup_logs): 사유 칸 비워도 됨(선택 메모 note), 이전·새 강사 칸 추가
--  4) 메일(lms_notice_mail = 20261109030000 그대로 + 아래만): 학생 '보강 강사가/시간·강사가 바뀌었어요',
--     이전 강사 'CANCELED make-up' 메일. 보내기 설정(feature_flags.send_emails)은 그대로
-- 기존 admin_makeup_confirm_now·admin_makeup_reschedule(수업 변경·보강 화면)은 그대로 둠(새 기능 검증 뒤 정리, 대표 11/9)
-- 새 숫자 없음. 다시 실행해도 같은 결과
-- =====================================================================

-- 1. 운영 기록: 사유 선택, 강사 칸 -------------------------------------------
alter table admin_makeup_logs alter column reason drop not null;
alter table admin_makeup_logs add column if not exists old_tutor_id uuid references tutors(id);
alter table admin_makeup_logs add column if not exists new_tutor_id uuid references tutors(id);
-- 수정 창에서 시간·강사는 그대로 두고 메모만 적은 경우 = 'note' 기록 (ChatGPT 검토 11/9)
alter table admin_makeup_logs drop constraint if exists admin_makeup_logs_action_check;
alter table admin_makeup_logs add constraint admin_makeup_logs_action_check check (action in ('confirm', 'reschedule', 'note'));

-- 2. 안내 종류: 이전 강사 취소 ------------------------------------------------
alter table lesson_notices drop constraint if exists lesson_notices_event_check;
alter table lesson_notices add constraint lesson_notices_event_check check (event in (
  'change', 'makeup_ask', 'makeup_confirmed', 'makeup_voided', 'revert', 'leave_options', 'sub_ask', 'sub_student', 'sub_confirmed',
  'makeup_rescheduled', 'makeup_tutor_removed'));

-- 2-1. 안내 한 번만 규칙: 보강 확정·변경·이전 강사 취소는 고칠 때마다 새 안내가 생겨야 함
--  (예전 규칙 '신청당 종류·받는 쪽 1건'이면 두 번째 시간 고치기·강사 바꾸기가 오류. admin_makeup_reschedule 두 번째 고치기도 같은 오류였음)
--  보강 묻기·보강 취소 안내는 받는 사람마다 1건 그대로 (on conflict do nothing 쓰는 곳 그대로 동작)
--  이름은 그대로 둠(예전 migration 을 다시 실행해도 'if not exists' 로 넘어가게). 이미 새 모양이면 그대로
do $$ begin
  if not exists (select 1 from pg_indexes where indexname = 'lesson_notices_once_makeup' and indexdef like '%recipient_id%') then
    drop index if exists lesson_notices_once_makeup;
    create unique index lesson_notices_once_makeup on lesson_notices (makeup_request_id, event, recipient_kind, recipient_id)
      where makeup_request_id is not null and event not in ('makeup_confirmed', 'makeup_rescheduled', 'makeup_tutor_removed');
  end if;
end $$;

-- 3. 수업 추가 ----------------------------------------------------------------
create or replace function admin_lesson_add(p_lesson uuid, p_item uuid, p_comp uuid, p_tutor uuid, p_starts_at timestamptz, p_note text default null)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v jsonb;
  v_req uuid;
  r makeup_requests;
begin
  if not is_admin() then raise exception '운영자(추가 인증 완료)만 처리할 수 있습니다.' using errcode = '42501'; end if;
  if num_nonnulls(p_lesson, p_item, p_comp) <> 1 then raise exception '어느 수업의 보강인지 골라 주세요.'; end if;
  if p_starts_at is null then raise exception '날짜·시간을 골라 주세요.'; end if;
  if p_tutor is null or not exists (select 1 from tutors where id = p_tutor and active) then raise exception '강사를 골라 주세요.'; end if;
  -- 같은 수업분을 두 번 저장(두 번 누름·두 화면) 막기: 원래 수업·이관 보강 줄을 잠그고 나서 확인 (보상권은 core 가 잠금)
  if p_lesson is not null then perform 1 from lessons where id = p_lesson for update; end if;
  if p_item is not null then perform 1 from migrated_items where id = p_item for update; end if;

  v := lms_makeup_request_core(p_lesson, p_item, jsonb_build_array(jsonb_build_object('starts_at', p_starts_at)), null, 'admin_on_behalf', auth.uid(), p_comp);
  v_req := (v ->> 'makeup_request_id')::uuid;
  update makeup_requests set tutor_id = p_tutor where id = v_req and tutor_id is distinct from p_tutor;
  v := lms_makeup_book(v_req, p_starts_at, 'admin_lesson_add', false);
  if coalesce((v ->> 'repeated')::boolean, false) then return v; end if;
  select * into r from makeup_requests where id = v_req;
  insert into admin_makeup_logs (makeup_request_id, lesson_id, student_id, action, reason, note, new_starts_at, new_tutor_id, actor)
  values (r.id, r.confirmed_lesson_id, r.student_id, 'confirm', null, nullif(btrim(p_note), ''), p_starts_at, p_tutor, auth.uid());
  return v;
end $$;
revoke all on function admin_lesson_add(uuid, uuid, uuid, uuid, timestamptz, text) from public, anon;
grant execute on function admin_lesson_add(uuid, uuid, uuid, uuid, timestamptz, text) to authenticated;

-- 4. 수업 수정 (날짜·시간·강사) --------------------------------------------------
create or replace function admin_lesson_edit(p_lesson uuid, p_tutor uuid, p_starts_at timestamptz, p_note text default null)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  l lessons;
  r makeup_requests;
  v_leave boolean;
  v_until date;
  e enrollments;
  v_end timestamptz;
  v_conf text;
  v_enr uuid;
  v_tutor uuid;
  v_tchg boolean;
begin
  if not is_admin() then raise exception '운영자(추가 인증 완료)만 처리할 수 있습니다.' using errcode = '42501'; end if;
  if p_starts_at is null then raise exception '날짜·시간을 골라 주세요.'; end if;

  select * into l from lessons where id = p_lesson for update;
  if not found then raise exception '수업이 없습니다.'; end if;
  select * into r from makeup_requests where confirmed_lesson_id = l.id and status = 'confirmed' for update;
  if not found then raise exception '확정된 보강·보상수업만 고칠 수 있어요.'; end if;
  if l.state <> 'scheduled' or l.voided_at is not null then raise exception '예정된 수업만 고칠 수 있어요.'; end if;
  if l.starts_at <= now() then raise exception '이미 시작한 수업은 고칠 수 없어요.'; end if;
  v_tutor := coalesce(p_tutor, l.tutor_id);
  if not exists (select 1 from tutors where id = v_tutor and active) then raise exception '강사를 골라 주세요.'; end if;
  v_tchg := v_tutor <> l.tutor_id;
  if p_starts_at = l.starts_at and not v_tchg then
    -- 메모만 적었으면 기록만 남김 (안내·메일 없음)
    if nullif(btrim(p_note), '') is not null then
      insert into admin_makeup_logs (makeup_request_id, lesson_id, student_id, action, reason, note, old_starts_at, new_starts_at, old_tutor_id, new_tutor_id, actor)
      values (r.id, l.id, l.student_id, 'note', null, btrim(p_note), l.starts_at, l.starts_at, l.tutor_id, l.tutor_id, me);
      return jsonb_build_object('lesson_id', l.id, 'note_only', true, 'repeated', false);
    end if;
    return jsonb_build_object('lesson_id', l.id, 'repeated', true);
  end if;
  if p_starts_at <= now() then raise exception '지난 시간으로는 고칠 수 없어요.'; end if;
  v_end := p_starts_at + (l.ends_at - l.starts_at);

  -- 기한: admin_makeup_reschedule 과 같음 (보상수업 = 사용 기한, 보강 = 수강 종료일, 시행 전 강사 휴무 보강은 기한 없음)
  if r.compensation_id is not null then
    v_until := lms_comp_use_until((select enrollment_id from compensations where id = r.compensation_id));
    if p_starts_at >= ((v_until + 1)::timestamp at time zone 'Asia/Seoul') then
      raise exception '보상수업 사용 기한(%) 뒤의 시간입니다.', v_until using hint = 'after_end';
    end if;
    v_enr := lms_comp_lesson_enrollment(r.compensation_id, (p_starts_at at time zone 'Asia/Seoul')::date);
  else
    if r.source_lesson_id is not null then
      select coalesce(x.class_status = 'Tutor long-term leave', false) and lms_fault_event(x.id) is null into v_leave
      from lessons x where x.id = r.source_lesson_id;
    else
      select coalesce(it.tutor_leave, false) into v_leave from migrated_items it where it.id = r.migrated_item_id;
    end if;
    select * into e from enrollments where id = l.enrollment_id;
    if not coalesce(v_leave, false) and p_starts_at >= ((e.final_end_date + 1)::timestamp at time zone 'Asia/Seoul') then
      raise exception '수강 종료일(%) 뒤의 시간입니다.', e.final_end_date using hint = 'after_end';
    end if;
    v_enr := l.enrollment_id;
  end if;

  v_conf := lms_makeup_conflict(v_tutor, l.student_id, p_starts_at, v_end, true, l.id);
  if v_conf is not null then raise exception '%', lms_conflict_message(v_conf) using hint = 'schedule_conflict', detail = lms_conflict_code(v_conf); end if;

  perform set_config('app.actor_id', me::text, true);
  perform set_config('app.actor_via', 'admin_lesson_edit', true);
  begin
    update lessons set starts_at = p_starts_at, ends_at = v_end, enrollment_id = v_enr, tutor_id = v_tutor where id = l.id;
  exception when exclusion_violation then
    raise exception '그 시간에 학생 또는 강사의 다른 수업이 있습니다.' using hint = 'schedule_conflict';
  end;
  if v_tchg then update makeup_requests set tutor_id = v_tutor where id = r.id; end if;
  if not exists (select 1 from makeup_candidates where request_id = r.id and starts_at = p_starts_at) then
    insert into makeup_candidates (request_id, starts_at, ends_at, proposed_by) values (r.id, p_starts_at, v_end, 'tutor');
  end if;

  insert into admin_makeup_logs (makeup_request_id, lesson_id, student_id, action, reason, note, old_starts_at, new_starts_at, old_tutor_id, new_tutor_id, actor)
  values (r.id, l.id, l.student_id, 'reschedule', null, nullif(btrim(p_note), ''), l.starts_at, p_starts_at, l.tutor_id, v_tutor, me);

  -- 안내: 아직 안 보낸 예전 확정·변경 카드는 닫고 최신 1건만. 이전 강사 취소 카드는 새로 맡게 된 강사 것만 닫음
  update lesson_notices set status = 'not_needed'
  where makeup_request_id = r.id and status = 'pending'
    and (event in ('makeup_confirmed', 'makeup_rescheduled') or (event = 'makeup_tutor_removed' and recipient_id = v_tutor));
  insert into lesson_notices (makeup_request_id, event, recipient_kind, recipient_id) values (r.id, 'makeup_rescheduled', 'student', l.student_id);
  if v_tchg then
    insert into lesson_notices (makeup_request_id, event, recipient_kind, recipient_id) values (r.id, 'makeup_tutor_removed', 'tutor', l.tutor_id);
    insert into lesson_notices (makeup_request_id, event, recipient_kind, recipient_id) values (r.id, 'makeup_confirmed', 'tutor', v_tutor);
  else
    insert into lesson_notices (makeup_request_id, event, recipient_kind, recipient_id) values (r.id, 'makeup_rescheduled', 'tutor', l.tutor_id);
  end if;
  return jsonb_build_object('lesson_id', l.id, 'old_starts_at', l.starts_at, 'new_starts_at', p_starts_at,
                            'old_tutor_id', l.tutor_id, 'new_tutor_id', v_tutor, 'repeated', false);
end $$;
revoke all on function admin_lesson_edit(uuid, uuid, timestamptz, text) from public, anon;
grant execute on function admin_lesson_edit(uuid, uuid, timestamptz, text) to authenticated;

-- 5. 운영 기록 읽기: 강사 이름 함께 ---------------------------------------------
create or replace function admin_makeup_logs_for(p_student uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not is_admin() then raise exception '운영자(추가 인증 완료)만 처리할 수 있습니다.' using errcode = '42501'; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', g.id, 'makeup_request_id', g.makeup_request_id, 'lesson_id', g.lesson_id, 'action', g.action, 'reason', g.reason, 'note', g.note,
      'old_starts_at', g.old_starts_at, 'new_starts_at', g.new_starts_at, 'created_at', g.created_at,
      'old_tutor', ot.name, 'old_tutor_tz', ot.timezone, 'new_tutor', nt.name
    ) order by g.created_at desc)
    from admin_makeup_logs g
    left join tutors ot on ot.id = g.old_tutor_id
    left join tutors nt on nt.id = g.new_tutor_id
    where g.student_id = p_student), '[]'::jsonb);
end $$;
revoke all on function admin_makeup_logs_for(uuid) from public, anon;
grant execute on function admin_makeup_logs_for(uuid) to authenticated;

-- 6. 메일: 20261109030000 의 lms_notice_mail 그대로 + 이전 강사 취소(makeup_tutor_removed)·학생 '강사가 바뀌었어요' 갈래만 추가 --------
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
  if new.event in ('makeup_confirmed', 'makeup_rescheduled', 'makeup_tutor_removed', 'change') then
    perform lms_mail_enqueue_notice(new.id);
  end if;
  return null;
end $$;
revoke all on function lesson_notices_email() from public, anon, authenticated;
