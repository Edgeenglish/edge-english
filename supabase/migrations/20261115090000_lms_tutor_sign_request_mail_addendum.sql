-- 강사 서명 요청 메일: 학생 정보 보호 부속합의서 요청에는 대표 11/15 확정 제목·본문 (H26(192)), 다른 문서는 기존 일반 문구 그대로
--  - [date] = 기한(요청 + 7일)의 강사 현지 날짜 'Sun, 22 Nov' (To do 'Please sign by …' 와 같은 날짜)
-- 되돌리기: 20261115070000 의 lms_sign_request_mail 정의를 다시 실행
create or replace function lms_sign_request_mail(p_request uuid) returns boolean
language plpgsql security definer set search_path = public as $$
declare
  v_live boolean := coalesce((select f.enabled from feature_flags f where f.key = 'send_emails'), false);
  r tutor_sign_requests;
  tu tutors;
  v_title text;
  v_code text;
  v_due text;
  v_paras text[];
  v_intended text;
  v_to text;
  v_subject text;
  v_text text;
  v_html text;
  v_nid uuid;
  p text;
begin
  select * into r from tutor_sign_requests where id = p_request;
  if not found then return false; end if;
  if exists (select 1 from notifications where dedupe_key = 'tutor_sign_request:' || r.id) then return false; end if;
  if exists (select 1 from tutor_signatures where request_id = r.id) then return false; end if;
  select * into tu from tutors where id = r.tutor_id;
  v_intended := lms_notice_recipient_email('tutor', tu.id);
  if v_intended is null then return false; end if;
  v_title := lms_sign_doc_title(r.document_id);
  select terms_code into v_code from terms_documents where id = r.document_id;
  v_to := case when v_live then v_intended else 'support@edgeenglish.kr' end;
  if v_code = 'TS_STUDENT_DATA_PROTECTION_ADDENDUM' then
    -- 대표 11/15 확정 (부속합의서 전용)
    v_due := lms_mail_en_date(r.due_at, lms_tutor_tz_at(r.tutor_id, r.due_at));   -- 이동 기간이면 그 지역, 아니면 평소 시간대
    v_subject := 'Edge English – Student Data Protection Addendum (please sign)';
    v_paras := array[
      'Hi ' || tu.name || ',',
      'We''ve added a short Student Data Protection Addendum to your Freelance Instructor Contract. Your current contract stays the same — this only covers how student information is handled.',
      'We''d really appreciate it if you could review and sign the addendum through your LMS Home → To do by ' || v_due || '.',
      'You''ll also be asked to enter your country of residence. Once signed, you''ll receive a copy by email.',
      'Thank you!',
      'Edge English Team'];
  else
    -- 대표 11/15 승인 일반 문구 (다른 계약서·문서)
    v_subject := '[Edge English] Document ready for your signature';
    v_paras := array[
      'Hi ' || tu.name || ',',
      'Please log in to the LMS and sign the ' || v_title || ' within 7 days.' || E'\n' || 'You can find it under To do on your Home page.',
      'Thank you!' || E'\n' || 'Edge English Team'];
  end if;
  v_subject := case when v_live then '' else '[시험 · ' || tu.name || '] ' end || v_subject;
  v_text := array_to_string(v_paras, E'\n\n')
    || case when v_live then '' else E'\n\n(시험 발송 · 원래 받는 사람: ' || v_intended || ')' end;
  v_html := '<div style="font-family:sans-serif;font-size:15px;line-height:1.6;color:#1d1b2a;max-width:480px">'
    || case when v_live then '' else '<p style="background:#fff4d6;color:#5c3b00;border-radius:8px;padding:8px 10px;font-size:13px;font-weight:600">시험 발송 · 원래 받는 사람: ' || lms_html(v_intended) || '</p>' end;
  foreach p in array v_paras loop
    v_html := v_html || '<p>' || replace(lms_html(p), E'\n', '<br>') || '</p>';
  end loop;
  v_html := v_html || '</div>';
  insert into notifications (recipient_kind, recipient_id, email, locale, template, payload, dedupe_key)
  values ('tutor', tu.id, v_to, 'en', 'tutor_sign_request',
          jsonb_build_object('intended_email', v_intended, 'subject', v_subject, 'html', v_html, 'text', v_text, 'request_id', r.id),
          'tutor_sign_request:' || r.id)
  on conflict (dedupe_key) do nothing
  returning id into v_nid;
  if v_nid is null then return false; end if;
  perform lms_mail_dispatch(v_nid);
  return true;
end $$;
revoke all on function lms_sign_request_mail(uuid) from public, anon, authenticated;
