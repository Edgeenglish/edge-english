-- =====================================================================
-- 보강 요청 재촉 메일 (대표 2026-11-08, H26(104))
--  강사가 아직 답하지 않은 보강 요청에, 아래 둘 중 먼저 오는 때 강사에게 영어 메일 1번 (같은 요청에는 다시 보내지 않음)
--   ① 요청이 들어온 지 24시간
--   ② 학생이 고른 시간 중 가장 빠른 앞으로의 시각까지 24시간 남음
--  예약 실행(pg_cron) 15분마다: 재촉 확인 + 메일 보냄/실패 기록
--  발송은 기존 자동 메일과 같음: send_emails 가 꺼져 있으면 운영진 메일로만 ('[시험 · 학생 번호]' 표시)
-- 표·기존 데이터는 바꾸지 않음 (칸 1개 추가). 다시 실행해도 같은 결과
-- =====================================================================

alter table makeup_requests add column if not exists nudged_at timestamptz;

create or replace function lms_makeup_nudge_run(p_now timestamptz default now()) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  x record;
  st students;
  tu tutors;
  v_live boolean := coalesce((select f.enabled from feature_flags f where f.key = 'send_emails'), false);
  v_intended text;
  v_to text;
  v_lines text[];
  v_subject text;
  v_url text := lms_url() || '/tutor';
  v_btn text := 'Open Edge English LMS';
  v_foot text := 'Reply to this email or message us on WhatsApp if you have a question.';
  v_body text;
  v_html text;
  v_id uuid;
  v_n integer := 0;
begin
  for x in
    select r.id, r.student_id, r.tutor_id, coalesce(r.requested_at, r.created_at) as asked_at,
           (select min(c.starts_at) from makeup_candidates c where c.request_id = r.id and c.proposed_by = 'student' and c.starts_at > p_now) as earliest
    from makeup_requests r
    where r.status = 'requested' and r.tutor_answered_at is null and r.nudged_at is null
  loop
    -- 앞으로의 희망 시각이 하나도 없으면 재촉해도 답할 수 없음
    if x.earliest is null then continue; end if;
    if not (x.asked_at + interval '24 hours' <= p_now or x.earliest - interval '24 hours' <= p_now) then continue; end if;
    select * into st from students where id = x.student_id;
    select * into tu from tutors where id = x.tutor_id;
    v_intended := lms_notice_recipient_email('tutor', x.tutor_id);
    if v_intended is null then continue; end if;
    v_to := case when v_live then v_intended else 'support@edgeenglish.kr' end;
    v_subject := case when v_live then '' else '[시험 · ' || st.code || '] ' end
                 || '[Edge English] Reminder: make-up request - ' || coalesce(nullif(st.name_en, ''), st.name_ko);
    v_lines := array[
      'REMINDER - Make-up request - ' || coalesce(nullif(st.name_en, ''), st.name_ko),
      'Requested: ' || lms_mail_en_at(x.asked_at, tu.timezone),
      'Earliest time: ' || lms_mail_en_at(x.earliest, tu.timezone)];
    v_body := lms_strip_bold(array_to_string(v_lines, E'\n')) || E'\n\n' || v_btn || ': ' || v_url || E'\n' || v_foot
              || case when v_live then '' else E'\n\n(시험 발송 · 원래 받는 사람: ' || v_intended || ')' end;
    v_html := '<div style="font-family:sans-serif;font-size:15px;line-height:1.6;color:#1d1b2a;max-width:480px">'
              || case when v_live then '' else '<p style="background:#fff4d6;color:#5c3b00;border-radius:8px;padding:8px 10px;font-size:13px;font-weight:600">시험 발송 · 원래 받는 사람: ' || lms_html(v_intended) || '</p>' end
              || '<p style="font-weight:700">' || lms_bold_html(v_lines[1]) || '</p>'
              || '<p>' || lms_bold_html(v_lines[2]) || '<br>' || lms_bold_html(v_lines[3]) || '</p>'
              || '<p><a href="' || lms_html(v_url) || '" style="display:inline-block;background:#5b3df0;color:#fff;border-radius:10px;padding:11px 18px;font-weight:700;text-decoration:none">' || lms_html(v_btn) || '</a></p>'
              || '<p style="font-size:12.5px;color:#55526a;border-top:1px solid #e6e3ef;padding-top:10px">' || lms_html(v_foot) || '</p></div>';
    insert into notifications (recipient_kind, recipient_id, email, locale, template, payload, dedupe_key)
    values ('tutor', x.tutor_id, v_to, 'en', 'lesson_notice_makeup_nudge',
            jsonb_build_object('intended_email', v_intended, 'subject', v_subject, 'html', v_html, 'text', v_body),
            'makeup_nudge:' || x.id)
    on conflict (dedupe_key) do nothing
    returning id into v_id;
    update makeup_requests set nudged_at = p_now where id = x.id;
    if v_id is not null then perform lms_mail_dispatch(v_id); v_n := v_n + 1; end if;
  end loop;
  return jsonb_build_object('nudged', v_n);
end $$;
revoke all on function lms_makeup_nudge_run(timestamptz) from public, anon, authenticated;

-- 15분마다 실행 (pg_cron 이 있는 Supabase 에서만. 같은 이름이면 덮어씀)
do $$
begin
  begin
    create extension if not exists pg_cron with schema pg_catalog;
  exception when others then
    raise notice 'pg_cron 을 켜지 못함: %', sqlerrm;
  end;
  if to_regnamespace('cron') is not null then
    perform cron.schedule('lms-makeup-nudge', '*/15 * * * *', 'select lms_makeup_nudge_run(); select lms_mail_run();');
  end if;
end $$;
