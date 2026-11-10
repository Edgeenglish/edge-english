-- =====================================================================
-- 첫 수업 Follow-up 재촉 메일 (대표 2026-11-10, 문구 대표 확정)
--  첫 수업 뒤 1시간이 지났는데 First Lesson Follow-up(Level · Wants to Improve · Class Style · Class Notes)이
--  다 저장되지 않았으면 담당 강사에게 영어 메일 1번 (같은 강사·수강생에게 다시 보내지 않음)
--   - 1시간 기준 = 첫 수업 끝난 시각과 Class Record 처음 저장 시각 중 늦은 쪽 (Follow-up 은 기록을 저장해야 생김)
--   - 이 기능을 켠 시각(feature_flags 'first_lesson_followup_nudge_since' 의 updated_at) 뒤에 기준이 지난 건만
--     → 켜기 전에 밀린 Follow-up 에는 한꺼번에 보내지 않음
--  예약 실행(pg_cron) 15분마다. 발송은 기존 자동 메일과 같음(send_emails 꺼져 있으면 운영진 메일로만)
-- 표·기존 데이터는 바꾸지 않음. 다시 실행해도 같은 결과
-- =====================================================================

insert into feature_flags (key, enabled, note)
values ('first_lesson_followup_nudge_since', false, '첫 수업 Follow-up 재촉 메일 시작 시각 — 이 줄의 updated_at 뒤에 1시간 기준이 지난 건만 보냄 (스위치 아님)')
on conflict (key) do nothing;

create or replace function lms_followup_nudge_run(p_now timestamptz default now()) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  x record;
  j jsonb;
  st students;
  tu tutors;
  l lessons;
  v_since timestamptz := (select f.updated_at from feature_flags f where f.key = 'first_lesson_followup_nudge_since');
  v_base timestamptz;
  v_live boolean := coalesce((select f.enabled from feature_flags f where f.key = 'send_emails'), false);
  v_intended text;
  v_to text;
  v_name text;
  v_first text;
  v_todo text[];
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
  if v_since is null then return jsonb_build_object('nudged', 0); end if;
  for x in
    select distinct rs.student_id, rs.tutor_id from regular_schedules rs
    where lms_tutor_student_access(rs.tutor_id, rs.student_id) = 'regular'
      and not exists (select 1 from notifications n where n.dedupe_key = 'followup_nudge:' || rs.tutor_id || ':' || rs.student_id)
  loop
    j := lms_first_lesson_todo(x.tutor_id, x.student_id);
    if j is null or coalesce((j ->> 'pending')::int, 0) = 0 then continue; end if;
    select * into l from lessons where id = (j -> 'first_lesson' ->> 'id')::uuid;
    v_base := greatest(l.ends_at, coalesce((j -> 'first_lesson' ->> 'recorded_at')::timestamptz, l.ends_at));
    if v_base < v_since or v_base + interval '1 hour' > p_now then continue; end if;
    select * into st from students where id = x.student_id;
    select * into tu from tutors where id = x.tutor_id;
    v_intended := lms_notice_recipient_email('tutor', x.tutor_id);
    if v_intended is null then continue; end if;
    v_to := case when v_live then v_intended else 'support@edgeenglish.kr' end;
    v_name := coalesce(nullif(st.name_en, ''), st.name_ko);
    v_first := split_part(trim(v_name), ' ', 1);
    v_todo := array_remove(array[
      case when not (j -> 'done' ->> 'level')::boolean then 'Level' end,
      case when not (j -> 'done' ->> 'improve')::boolean then 'Wants to Improve' end,
      case when not (j -> 'done' ->> 'style')::boolean then 'Class Style' end,
      case when not coalesce((j -> 'done' ->> 'docs')::boolean, false) then 'Class Notes' end], null);
    v_subject := case when v_live then '' else '[시험 · ' || st.code || '] ' end
                 || '[Edge English] Reminder: first lesson follow-up - ' || v_name;
    v_lines := array[
      'REMINDER - First lesson follow-up - ' || v_name,
      'There are a few things to fill in about ' || v_first || ' after the first lesson.',
      'Still to do: ' || array_to_string(v_todo, ' · '),
      'Please complete them on your LMS Home (To do).'];
    v_body := array_to_string(v_lines, E'\n') || E'\n\n' || v_btn || ': ' || v_url || E'\n' || v_foot
              || case when v_live then '' else E'\n\n(시험 발송 · 원래 받는 사람: ' || v_intended || ')' end;
    v_html := '<div style="font-family:sans-serif;font-size:15px;line-height:1.6;color:#1d1b2a;max-width:480px">'
              || case when v_live then '' else '<p style="background:#fff4d6;color:#5c3b00;border-radius:8px;padding:8px 10px;font-size:13px;font-weight:600">시험 발송 · 원래 받는 사람: ' || lms_html(v_intended) || '</p>' end
              || '<p style="font-weight:700">' || lms_html(v_lines[1]) || '</p>'
              || '<p>' || lms_html(v_lines[2]) || '<br>' || lms_html(v_lines[3]) || '<br>' || lms_html(v_lines[4]) || '</p>'
              || '<p><a href="' || lms_html(v_url) || '" style="display:inline-block;background:#5b3df0;color:#fff;border-radius:10px;padding:11px 18px;font-weight:700;text-decoration:none">' || lms_html(v_btn) || '</a></p>'
              || '<p style="font-size:12.5px;color:#55526a;border-top:1px solid #e6e3ef;padding-top:10px">' || lms_html(v_foot) || '</p></div>';
    insert into notifications (recipient_kind, recipient_id, email, locale, template, payload, dedupe_key)
    values ('tutor', x.tutor_id, v_to, 'en', 'first_lesson_followup_nudge',
            jsonb_build_object('intended_email', v_intended, 'subject', v_subject, 'html', v_html, 'text', v_body),
            'followup_nudge:' || x.tutor_id || ':' || x.student_id)
    on conflict (dedupe_key) do nothing
    returning id into v_id;
    if v_id is not null then perform lms_mail_dispatch(v_id); v_n := v_n + 1; end if;
  end loop;
  return jsonb_build_object('nudged', v_n);
end $$;
revoke all on function lms_followup_nudge_run(timestamptz) from public, anon, authenticated;

-- 15분마다 실행 (pg_cron 이 있는 Supabase 에서만. 같은 이름이면 덮어씀)
do $$
begin
  if to_regnamespace('cron') is not null then
    perform cron.schedule('lms-followup-nudge', '*/15 * * * *', 'select lms_followup_nudge_run(); select lms_mail_run();');
  end if;
end $$;
