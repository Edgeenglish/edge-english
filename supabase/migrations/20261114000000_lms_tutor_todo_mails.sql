-- =====================================================================
-- 강사 To do 새 항목 메일 (대표 2026-11-14): 처음 1통 + 24시간 안에 답이 없으면 1통 더
--  ① 대체 수업 요청(운영진이 휴무 때 대체강사로 고른 수업): 고른 뒤 첫 메일 1통(같은 강사 것은 한 통에 모음) + 재촉 1통
--  ② 신규 수강생 문의: 첫 메일은 이미 있음(lms_plan_request_notice) → 재촉 1통만 추가
--  재촉 기준 (보강 요청과 같은 방식, H26(133)): 처음 메일(고른 때) 24시간 뒤, 또는 수업(첫 수업) 24시간 전 중 먼저 오는 때.
--    고른 때 이미 수업까지 24시간 이내였으면 재촉 없음(첫 메일만). 지난 수업·이미 답한 것·닫힌 것은 안 보냄
--  보강 요청·첫 수업 후 확인·기록할 수업은 이 migration 에서 바꾸지 않음 (이미 정한 방식 유지 / 기록할 수업 묶음 메일은 별도)
--  메일 글: 대체강사 문의는 기존 WhatsApp 문구 그대로(휴무 강사 이름 안 씀), 재촉은 대표 확정 초안 그대로
--  켜기 전 쌓인 것에는 보내지 않음: feature_flags 'tutor_todo_mail_since' 의 updated_at 뒤에 생긴 것만 (스위치 아님)
--  예약 실행(pg_cron) 15분마다. 발송은 기존 자동 메일과 같음(send_emails 꺼져 있으면 운영진 메일로만, '[시험 · 학생 번호]')
-- 칸 3개 추가 + 함수 3개. 표·기존 데이터를 바꾸지 않음. 다시 실행해도 같은 결과
-- =====================================================================

alter table leave_items add column if not exists ask_mailed_at timestamptz;
alter table leave_items add column if not exists ask_nudged_at timestamptz;
alter table schedule_plans add column if not exists nudged_at timestamptz;

insert into feature_flags (key, enabled, note)
values ('tutor_todo_mail_since', false, '강사 To do 새 항목 메일 시작 시각 — 이 줄의 updated_at 뒤에 생긴 것만 보냄 (스위치 아님)')
on conflict (key) do nothing;

-- ① 대체 수업 요청: 첫 메일(강사별 한 통) + 재촉(강사별 한 통). p_dry = true 이면 보내지 않고 글만 돌려줌 (검증용)
create or replace function lms_cover_mail_run(p_now timestamptz default now(), p_since timestamptz default null, p_dry boolean default false)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_since timestamptz := coalesce(p_since, (select f.updated_at from feature_flags f where f.key = 'tutor_todo_mail_since'));
  g record;
  tu tutors;
  v_ids uuid[];
  v_list text;
  v_first_student uuid;
  v_min_decided timestamptz;
  v_paras text[];
  v_subject text;
  v_key text;
  v_id uuid;
  v_first int := 0;
  v_nudge int := 0;
  v_out jsonb := '[]'::jsonb;
begin
  if v_since is null then return jsonb_build_object('first', 0, 'nudge', 0, 'mails', v_out); end if;

  -- 첫 메일
  for g in
    select distinct it.sub_tutor_id as tutor_id from leave_items it
    where it.choice = 'substitute' and it.sub_stage = 'asked' and it.ask_mailed_at is null
      and it.decided_at >= v_since and it.starts_at > p_now
  loop
    select * into tu from tutors where id = g.tutor_id;
    select array_agg(q.id order by q.starts_at),
           string_agg(q.rn || ') ' || lms_mail_en_at(q.starts_at, tu.timezone) || ' · ' || q.name || ' · ' || q.dur || ' min', E'\n' order by q.starts_at),
           (array_agg(q.student_id order by q.starts_at))[1], min(q.decided_at)
      into v_ids, v_list, v_first_student, v_min_decided
    from (select it.id, it.starts_at, it.decided_at, it.student_id, row_number() over (order by it.starts_at) rn,
                 coalesce(nullif(s.name_en, ''), s.name_ko) as name, round(extract(epoch from (it.ends_at - it.starts_at)) / 60)::int as dur
          from leave_items it join students s on s.id = it.student_id
          where it.sub_tutor_id = g.tutor_id and it.choice = 'substitute' and it.sub_stage = 'asked' and it.ask_mailed_at is null
            and it.decided_at >= v_since and it.starts_at > p_now) q;
    v_subject := '[Edge English] Substitute request - please reply in the LMS';
    v_paras := array[
      'Substitute request - not confirmed yet',
      'One of our Edge English tutors is on leave. Are you available to teach these classes?' || E'\n' || v_list,
      'Please open To do on your LMS Home and mark the classes you can teach (leave the others unchecked).'];
    if p_dry then
      v_out := v_out || jsonb_build_object('kind', 'first', 'tutor', tu.name, 'subject', v_subject, 'paras', to_jsonb(v_paras));
    else
      v_key := 'tutor_mail:cover_ask:' || g.tutor_id || ':' || floor(extract(epoch from v_min_decided))::bigint;
      v_id := lms_tutor_mail(g.tutor_id, v_first_student, 'lesson_notice_tutor_cover_ask', v_key, v_subject, v_paras, true);
      if v_id is not null then
        update leave_items set ask_mailed_at = p_now where id = any(v_ids);
        v_first := v_first + 1;
      end if;
    end if;
  end loop;

  -- 재촉: 첫 메일을 보낸 뒤 24시간(또는 수업 24시간 전) 지났는데 아직 답이 없는(= 아직 '묻는 중') 수업. 고를 때 이미 24시간 이내였으면 재촉 없음
  for g in
    select distinct it.sub_tutor_id as tutor_id from leave_items it
    where it.choice = 'substitute' and it.sub_stage = 'asked' and it.ask_mailed_at is not null and it.ask_nudged_at is null
      and it.decided_at >= v_since and it.starts_at > p_now
      and it.starts_at > it.decided_at + interval '24 hours'
      and (it.decided_at + interval '24 hours' <= p_now or it.starts_at - interval '24 hours' <= p_now)
  loop
    select * into tu from tutors where id = g.tutor_id;
    select array_agg(q.id order by q.starts_at),
           string_agg(q.rn || ') ' || lms_mail_en_at(q.starts_at, tu.timezone) || ' · ' || q.name || ' · ' || q.dur || ' min', E'\n' order by q.starts_at),
           (array_agg(q.student_id order by q.starts_at))[1], min(q.decided_at)
      into v_ids, v_list, v_first_student, v_min_decided
    from (select it.id, it.starts_at, it.decided_at, it.student_id, row_number() over (order by it.starts_at) rn,
                 coalesce(nullif(s.name_en, ''), s.name_ko) as name, round(extract(epoch from (it.ends_at - it.starts_at)) / 60)::int as dur
          from leave_items it join students s on s.id = it.student_id
          where it.sub_tutor_id = g.tutor_id and it.choice = 'substitute' and it.sub_stage = 'asked' and it.ask_mailed_at is not null and it.ask_nudged_at is null
            and it.decided_at >= v_since and it.starts_at > p_now
            and it.starts_at > it.decided_at + interval '24 hours'
            and (it.decided_at + interval '24 hours' <= p_now or it.starts_at - interval '24 hours' <= p_now)) q;
    v_subject := '[Edge English] Reminder: cover request - please reply';
    v_paras := array[
      'Hi ' || tu.name || ',',
      'We haven''t heard back about the cover request we sent. Please open To do in LMS and mark the classes you can teach (leave the others unchecked).',
      v_list];
    if p_dry then
      v_out := v_out || jsonb_build_object('kind', 'nudge', 'tutor', tu.name, 'subject', v_subject, 'paras', to_jsonb(v_paras));
    else
      v_key := 'tutor_mail:cover_nudge:' || g.tutor_id || ':' || floor(extract(epoch from v_min_decided))::bigint;
      v_id := lms_tutor_mail(g.tutor_id, v_first_student, 'lesson_notice_tutor_cover_nudge', v_key, v_subject, v_paras, false);
      if v_id is not null then
        update leave_items set ask_nudged_at = p_now where id = any(v_ids);
        v_nudge := v_nudge + 1;
      end if;
    end if;
  end loop;

  return jsonb_build_object('first', v_first, 'nudge', v_nudge, 'mails', v_out);
end $$;

-- ② 신규 수강생 문의 재촉 (첫 메일은 이미 lms_plan_request_notice 가 보냄, proposal_sent_at = 그때)
create or replace function lms_plan_nudge_run(p_now timestamptz default now(), p_since timestamptz default null, p_dry boolean default false)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_since timestamptz := coalesce(p_since, (select f.updated_at from feature_flags f where f.key = 'tutor_todo_mail_since'));
  x record;
  f record;
  e enrollments;
  st students;
  tu tutors;
  v_name text;
  v_subject text;
  v_paras text[];
  v_id uuid;
  v_n int := 0;
  v_out jsonb := '[]'::jsonb;
begin
  if v_since is null then return jsonb_build_object('nudge', 0, 'mails', v_out); end if;
  for x in
    select pl.id, pl.tutor_id, pl.enrollment_id, pl.proposal_sent_at as sent_at from schedule_plans pl
    where pl.state = 'proposed' and pl.tutor_id is not null and pl.tutor_answer is null
      and pl.proposal_sent_at is not null and pl.proposal_sent_at >= v_since and pl.nudged_at is null
  loop
    select * into e from enrollments where id = x.enrollment_id;
    if e.id is null or e.previous_enrollment_id is not null then continue; end if;
    select * into f from lms_plan_first_times(x.id);
    if f.first_at is null or f.first_at <= p_now then continue; end if;
    if f.first_at <= x.sent_at + interval '24 hours' then continue; end if;
    if not (x.sent_at + interval '24 hours' <= p_now or f.first_at - interval '24 hours' <= p_now) then continue; end if;
    select * into st from students where id = e.student_id;
    select * into tu from tutors where id = x.tutor_id;
    v_name := lms_student_en(st);
    v_subject := '[Edge English] Reminder: new student request - ' || v_name || ' · please answer in the LMS';
    v_paras := array[
      'REMINDER - NEW STUDENT REQUEST - ' || v_name || ' (' || e.duration_min || ' min, ' || e.lessons_purchased || ' classes)' || E'\n' || 'Still waiting for your answer.',
      'Time: ' || lms_mail_en_every(f.every, tu.timezone) || E'\n' || 'First class: ' || lms_mail_en_at(f.first_at, tu.timezone),
      'Can you take this student? Please answer on your LMS Home (To do).'];
    if p_dry then
      v_out := v_out || jsonb_build_object('kind', 'nudge', 'tutor', tu.name, 'subject', v_subject, 'paras', to_jsonb(v_paras));
    else
      v_id := lms_tutor_mail(x.tutor_id, st.id, 'lesson_notice_tutor_new_request_nudge', 'tutor_mail:plan_request_nudge:' || x.id, v_subject, v_paras, true);
      if v_id is not null then
        update schedule_plans set nudged_at = p_now where id = x.id;
        v_n := v_n + 1;
      end if;
    end if;
  end loop;
  return jsonb_build_object('nudge', v_n, 'mails', v_out);
end $$;

-- 한 번에 부르는 함수 (예약 실행용)
create or replace function lms_tutor_todo_mail_run(p_now timestamptz default now(), p_since timestamptz default null, p_dry boolean default false)
returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  return jsonb_build_object('cover', lms_cover_mail_run(p_now, p_since, p_dry), 'plan', lms_plan_nudge_run(p_now, p_since, p_dry));
end $$;

revoke all on function lms_cover_mail_run(timestamptz, timestamptz, boolean) from public, anon, authenticated;
revoke all on function lms_plan_nudge_run(timestamptz, timestamptz, boolean) from public, anon, authenticated;
revoke all on function lms_tutor_todo_mail_run(timestamptz, timestamptz, boolean) from public, anon, authenticated;

-- 15분마다 확인 (pg_cron 이 있는 Supabase 에서만)
do $$
begin
  if to_regnamespace('cron') is not null then
    perform cron.schedule('lms-tutor-todo-mail', '*/15 * * * *', 'select lms_tutor_todo_mail_run(); select lms_mail_run();');
  end if;
end $$;
