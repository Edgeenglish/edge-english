-- =====================================================================
-- 강사 통보를 강사 LMS 로 (정책 원본 H26(116)(122)(125)(127)) + 첫 수업 안내 메일 (H26(129))
-- + 강사 [None of these times work] → 운영진 메일 (H26(124) ②) + 보강 재촉 정리 (H26(133))
-- 시험 DB 먼저. 운영 배포는 대표 승인 뒤.
--
--  ① 강사 Updates: 새 표 tutor_updates(신규 배정·재등록·정규 시간 변경·첫 수업 전 날짜 변경)
--     + 이미 있는 lesson_notices(운영진 확정 보강·보강 시간 변경·보강에서 빠짐·보강 취소·취소 되돌림·대체 수업 확정)
--     + 수강생 취소 수업 → tutor_updates_feed() 하나로. 그 수업이 끝나면 저절로 빠짐 (H26(127))
--  ② 강사 메일 6종: 신규 문의(To do)·신규 배정 확정·대체 수업 확정·정규 시간 변경·재등록 + 첫 수업 안내
--     문구 = 시안 docs/lms/previews/tutor-updates-drafts.html (H26(127)) · H26(129) 대표 지시문
--  ③ 운영진 강사 WhatsApp 복사 카드 없앰: 강사에게 가는 lesson_notices 는 넣을 때 'not_needed'
--  ④ 신규 문의: 강사가 To do 에서 [I can take it]/[I can't] (tutor_plan_answer, 운영자 대신 가능). 확정은 운영진 (H22)
--  ⑤ 재등록: 새 기간 일정 확정 = 강사 메일 + Updates + 운영진 재등록 업무 자동 끝 (POL-OP-14 새 문구, H26(116))
--  ⑥ 첫 수업 안내(학생·강사): 첫 수업 24시간 전 1통, 그 안에 확정되면 바로. 보낸 뒤 바뀌면 변경 안내 (H26(129))
--     이 기능을 켠 시각(feature_flags 'first_class_mail_since' updated_at) 뒤에 만든 수강권만
--  ⑦ 강사 메일 끝 문구 통일: 확정 "It's in your LMS schedule." · 변경 "Your LMS schedule is updated." (H26(127))
--  ⑧ 보강 신청 강사 메일 문구를 H26(124) 대로 (원래 수업 줄 + 'Please confirm one time in the LMS.')
-- 발송은 기존 자동 메일과 같음 (send_emails 꺼져 있으면 운영진 메일로만, 강사·학생 직접 + support@ 숨은참조)
-- =====================================================================

-- ---------------------------------------------------------------------
-- 0. 신규 문의 강사 답 칸
-- ---------------------------------------------------------------------
alter table schedule_plans add column if not exists tutor_answer text;
alter table schedule_plans add column if not exists tutor_answered_at timestamptz;
alter table schedule_plans add column if not exists tutor_answered_by uuid;
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'schedule_plans_tutor_answer_check') then
    alter table schedule_plans add constraint schedule_plans_tutor_answer_check check (tutor_answer in ('yes', 'no'));
  end if;
end $$;

-- ---------------------------------------------------------------------
-- 1. 강사 Updates 표 (알기만 하면 되는 통보. 강사 확인 버튼·추적 없음)
-- ---------------------------------------------------------------------
create table if not exists tutor_updates (
  id uuid primary key default gen_random_uuid(),
  tutor_id uuid not null references tutors(id),
  student_id uuid not null references students(id),
  kind text not null check (kind in ('new_student', 'renewal', 'schedule_change', 'class_moved')),
  info jsonb not null default '{}'::jsonb,
  visible_until timestamptz not null,
  source_key text not null unique,
  email_notification_id uuid references notifications(id),
  email_error text,
  created_at timestamptz not null default now()
);
create index if not exists tutor_updates_tutor_until on tutor_updates (tutor_id, visible_until);
do $$ begin
  if not exists (select 1 from pg_trigger where tgname = 'tutor_updates_no_delete') then
    perform lms_protect('public.tutor_updates');
    create trigger tutor_updates_no_delete before delete on tutor_updates for each row execute function forbid_delete();
  end if;
end $$;

insert into feature_flags (key, enabled, note)
values ('first_class_mail_since', false, '첫 수업 안내 메일 시작 시각 — 이 줄의 updated_at 뒤에 만든 수강권만 보냄 (스위치 아님, H26(129))')
on conflict (key) do nothing;

-- ---------------------------------------------------------------------
-- 2. 글 도우미 (모양은 src/lms/admin/time-text.ts 와 같음)
-- ---------------------------------------------------------------------
-- 'Mon, 16 Nov'
create or replace function lms_mail_en_date(p_at timestamptz, p_tz text) returns text
language sql stable as $$
  select (array['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'])[extract(dow from x)::int + 1] || ', ' || extract(day from x)::int || ' '
         || (array['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'])[extract(month from x)::int]
  from (select p_at at time zone coalesce(nullif(p_tz, ''), 'Asia/Seoul') as x) q
$$;

-- 'Every Mon, Wed 6:00 PM *Ho Chi Minh Time* / 8:00 PM *KST*' (요일마다 한 번씩 고른 시각들로, 시각이 다르면 '; ' 로 나눔)
create or replace function lms_mail_en_every(p_times timestamptz[], p_tz text) returns text
language sql stable as $$
  with z as (select coalesce(nullif(p_tz, ''), 'Asia/Seoul') as tz),
  t as (
    select distinct on (extract(dow from x at time zone z.tz)) x,
           extract(dow from x at time zone z.tz)::int as ld,
           extract(dow from x at time zone 'Asia/Seoul')::int as kd,
           lms_mail_en_clock(x, z.tz) as lc, lms_mail_en_clock(x, 'Asia/Seoul') as kc
    from unnest(p_times) x, z
    order by extract(dow from x at time zone z.tz), x
  ),
  g as (
    select lc, kc, (kd - ld + 7) % 7 as shift, min(ld) as o,
           string_agg((array['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'])[ld + 1], ', ' order by ld) as ldays,
           string_agg((array['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'])[kd + 1], ', ' order by ld) as kdays
    from t group by lc, kc, (kd - ld + 7) % 7
  )
  select 'Every ' || string_agg(
           case when z.tz = 'Asia/Seoul' then ldays || ' ' || lc || ' *KST*'
                else ldays || ' ' || lc || ' *' || lms_mail_en_zone(z.tz) || '* / ' || case when shift = 0 then '' else kdays || ' ' end || kc || ' *KST*' end,
           '; ' order by o)
  from g, z group by z.tz
$$;

-- '11월 11일(수)' · '오전 9:00' (학생 화면과 같은 모양, 학생 거주지 시간만)
create or replace function lms_mail_ko_date(p_at timestamptz, p_tz text) returns text
language sql stable as $$
  select extract(month from x)::int || '월 ' || extract(day from x)::int || '일(' || (array['일', '월', '화', '수', '목', '금', '토'])[extract(dow from x)::int + 1] || ')'
  from (select p_at at time zone coalesce(nullif(p_tz, ''), 'Asia/Seoul') as x) q
$$;
create or replace function lms_mail_ko_clock(p_at timestamptz, p_tz text) returns text
language sql stable as $$
  select case when extract(hour from x) < 12 then '오전 ' else '오후 ' end
         || (case when extract(hour from x)::int % 12 = 0 then 12 else extract(hour from x)::int % 12 end) || ':' || to_char(x, 'MI')
  from (select p_at at time zone coalesce(nullif(p_tz, ''), 'Asia/Seoul') as x) q
$$;
-- '매주 월·수·금 오전 9:00'
create or replace function lms_mail_ko_every(p_times timestamptz[], p_tz text) returns text
language sql stable as $$
  with z as (select coalesce(nullif(p_tz, ''), 'Asia/Seoul') as tz),
  t as (
    select distinct on (extract(dow from x at time zone z.tz)) extract(dow from x at time zone z.tz)::int as d, lms_mail_ko_clock(x, z.tz) as c
    from unnest(p_times) x, z order by extract(dow from x at time zone z.tz), x
  ),
  g as (select c, min(d) as o, string_agg((array['일', '월', '화', '수', '목', '금', '토'])[d + 1], '·' order by d) as days from t group by c)
  select '매주 ' || string_agg(days || ' ' || c, ', ' order by o) from g
$$;

-- 고정 일정(KST 요일·시각 slots)을 기준 날짜부터 요일마다 한 번씩 실제 시각으로
create or replace function lms_slot_times(p_slots jsonb, p_from date) returns timestamptz[]
language sql stable as $$
  select array_agg(t order by t) from (
    select ((p_from + (((s ->> 'weekday')::int - extract(dow from p_from)::int + 7) % 7)) + (s ->> 'time')::time) at time zone 'Asia/Seoul' as t
    from jsonb_array_elements(coalesce(p_slots, '[]'::jsonb)) s
  ) q
$$;

-- 학생의 고정 일정(그날 유효한 regular_schedules) → slots jsonb
create or replace function lms_slots_on(p_student uuid, p_day date) returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('weekday', weekday, 'time', to_char(start_time_kst, 'HH24:MI')) order by weekday, start_time_kst), '[]'::jsonb)
  from regular_schedules where student_id = p_student and effective_from <= p_day and (effective_to is null or effective_to >= p_day)
$$;

create or replace function lms_student_en(st students) returns text
language sql immutable as $$ select coalesce(nullif(st.name_en, ''), st.name_ko) $$;

-- ---------------------------------------------------------------------
-- 3. 강사 메일 한 통 (기존 강사 메일과 같은 모양·버튼·끝 줄). notifications 에 넣고 바로 보냄
--    받는 주소가 없으면 null. template 이 'lesson_notice_' 로 시작해 lms_mail_run 이 못 보낸 것을 다시 보냄
-- ---------------------------------------------------------------------
create or replace function lms_tutor_mail(p_tutor uuid, p_student uuid, p_template text, p_key text, p_subject text, p_paras text[], p_bold_first boolean default true)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  v_live boolean := coalesce((select f.enabled from feature_flags f where f.key = 'send_emails'), false);
  st students;
  v_intended text;
  v_to text;
  v_url text := lms_url() || '/tutor';
  v_btn text := 'Open Edge English LMS';
  v_foot text := 'Reply to this email or message us on WhatsApp if you have a question.';
  v_subject text;
  v_body text;
  v_html text;
  v_id uuid;
begin
  select * into st from students where id = p_student;
  v_intended := lms_notice_recipient_email('tutor', p_tutor);
  if v_intended is null then return null; end if;
  select id into v_id from notifications where dedupe_key = p_key;
  if v_id is not null then return v_id; end if;
  v_to := case when v_live then v_intended else 'support@edgeenglish.kr' end;
  v_subject := case when v_live then '' else '[시험 · ' || st.code || '] ' end || p_subject;
  v_body := lms_strip_bold(array_to_string(p_paras, E'\n\n')) || E'\n\n' || v_btn || ': ' || v_url || E'\n' || v_foot
            || case when v_live then '' else E'\n\n(시험 발송 · 원래 받는 사람: ' || v_intended || ')' end;
  v_html := '<div style="font-family:sans-serif;font-size:15px;line-height:1.6;color:#1d1b2a;max-width:480px">'
            || case when v_live then '' else '<p style="background:#fff4d6;color:#5c3b00;border-radius:8px;padding:8px 10px;font-size:13px;font-weight:600">시험 발송 · 원래 받는 사람: ' || lms_html(v_intended) || '</p>' end;
  for i in 1 .. coalesce(cardinality(p_paras), 0) loop
    v_html := v_html || case when i = 1 and p_bold_first then '<p style="font-weight:700">' else '<p>' end
              || replace(lms_bold_html(p_paras[i]), E'\n', '<br>') || '</p>';
  end loop;
  v_html := v_html
            || '<p><a href="' || lms_html(v_url) || '" style="display:inline-block;background:#5b3df0;color:#fff;border-radius:10px;padding:11px 18px;font-weight:700;text-decoration:none">' || lms_html(v_btn) || '</a></p>'
            || '<p style="font-size:12.5px;color:#55526a;border-top:1px solid #e6e3ef;padding-top:10px">' || lms_html(v_foot) || '</p></div>';
  insert into notifications (recipient_kind, recipient_id, email, locale, template, payload, dedupe_key)
  values ('tutor', p_tutor, v_to, 'en', p_template,
          jsonb_build_object('intended_email', v_intended, 'subject', v_subject, 'html', v_html, 'text', v_body, 'student_id', p_student),
          p_key)
  on conflict (dedupe_key) do nothing
  returning id into v_id;
  if v_id is null then select id into v_id from notifications where dedupe_key = p_key; return v_id; end if;
  perform lms_mail_dispatch(v_id);
  return v_id;
end $$;

-- Updates 한 줄 + (제목이 있으면) 강사 메일 1통. 같은 source_key 는 한 번만
create or replace function lms_tutor_update_add(p_tutor uuid, p_student uuid, p_kind text, p_info jsonb, p_until timestamptz, p_key text,
                                                p_subject text, p_paras text[])
returns uuid language plpgsql security definer set search_path = public as $$
declare
  v_id uuid;
  v_mail uuid;
begin
  insert into tutor_updates (tutor_id, student_id, kind, info, visible_until, source_key)
  values (p_tutor, p_student, p_kind, p_info, p_until, p_key)
  on conflict (source_key) do nothing
  returning id into v_id;
  if v_id is null then return null; end if;
  if p_subject is not null then
    v_mail := lms_tutor_mail(p_tutor, p_student, 'lesson_notice_tutor_' || p_kind, 'tutor_update:' || p_key, p_subject, p_paras);
    update tutor_updates set email_notification_id = v_mail, email_error = case when v_mail is null then '강사 이메일이 없어요' end where id = v_id;
  end if;
  return v_id;
end $$;

-- ---------------------------------------------------------------------
-- 4. 신규 수강생 일정 문의 → 강사 To do + 메일 ① (운영진이 강사·시간을 고르면 자동, 확정 아님)
--    끝날 때(커밋 때) 아직 '답 대기'인 신규 등록 일정안만. 바로 확정(강사 답 받음)하면 안 보냄
-- ---------------------------------------------------------------------
create or replace function lms_plan_first_times(p_plan uuid, out first_at timestamptz, out every timestamptz[])
language plpgsql stable security definer set search_path = public as $$
declare
  pl schedule_plans;
begin
  select * into pl from schedule_plans where id = p_plan;
  if pl.lesson_dates is not null and jsonb_array_length(pl.lesson_dates) > 0 then
    select min(((x ->> 'date')::date + (x ->> 'time')::time) at time zone 'Asia/Seoul') into first_at from jsonb_array_elements(pl.lesson_dates) x;
  end if;
  every := lms_slot_times(pl.slots, coalesce((first_at at time zone 'Asia/Seoul')::date, pl.start_date));
  if first_at is null then first_at := every[1]; end if;
  if every is null then
    select array_agg(t order by t) into every from (
      select distinct on (extract(dow from t0 at time zone 'Asia/Seoul')) t0 as t
      from (select ((x ->> 'date')::date + (x ->> 'time')::time) at time zone 'Asia/Seoul' as t0 from jsonb_array_elements(pl.lesson_dates) x) a
      order by extract(dow from t0 at time zone 'Asia/Seoul'), t0) b;
  end if;
end $$;

create or replace function lms_plan_request_notice() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  pl schedule_plans;
  e enrollments;
  st students;
  tu tutors;
  f record;
  v_name text;
  v_mail uuid;
begin
  select * into pl from schedule_plans where id = new.id;
  if not found or pl.state <> 'proposed' or pl.tutor_id is null then return null; end if;
  select * into e from enrollments where id = pl.enrollment_id;
  if e.previous_enrollment_id is not null then return null; end if;
  select * into st from students where id = e.student_id;
  select * into tu from tutors where id = pl.tutor_id;
  select * into f from lms_plan_first_times(pl.id);
  v_name := lms_student_en(st);
  v_mail := lms_tutor_mail(pl.tutor_id, st.id, 'lesson_notice_tutor_new_request', 'tutor_mail:plan_request:' || pl.id,
    '[Edge English] New student request - ' || v_name || ' · please answer in the LMS',
    array[
      'NEW STUDENT REQUEST - ' || v_name || ' (' || e.duration_min || ' min, ' || e.lessons_purchased || ' classes)' || E'\n' || 'Not confirmed yet.',
      'Time: ' || lms_mail_en_every(f.every, tu.timezone) || E'\n' || 'First class: ' || lms_mail_en_at(f.first_at, tu.timezone),
      'Can you take this student? Please answer on your LMS Home (To do).']);
  if v_mail is not null then
    perform set_config('app.actor_via', 'lms_plan_request_notice', true);
    update schedule_plans set proposal_sent_at = coalesce(proposal_sent_at, now()) where id = pl.id and state = 'proposed';
  end if;
  return null;
end $$;

drop trigger if exists schedule_plans_request_notice on schedule_plans;
create constraint trigger schedule_plans_request_notice after insert on schedule_plans
  deferrable initially deferred for each row execute function lms_plan_request_notice();

-- 강사 답 (To do 'New student request'): [I can take it]=yes / [I can't]=no. 운영진이 확정하기 전까지 바꿀 수 있음
create or replace function tutor_plan_answer(p_plan uuid, p_yes boolean, p_tutor uuid default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  me uuid := lms_screen_tutor(p_tutor);
  pl schedule_plans;
begin
  if p_yes is null then raise exception 'Please choose an answer.'; end if;
  select * into pl from schedule_plans where id = p_plan for update;
  if not found or pl.tutor_id is distinct from me then raise exception 'This request is not for you.' using errcode = '42501'; end if;
  if pl.state <> 'proposed' then raise exception 'This request is already closed. Please reload the page.' using hint = 'closed'; end if;
  perform set_config('app.actor_id', coalesce(auth.uid()::text, ''), true);
  perform set_config('app.actor_via', case when is_admin() then 'admin_plan_answer' else 'tutor_plan_answer' end, true);
  update schedule_plans set tutor_answer = case when p_yes then 'yes' else 'no' end, tutor_answered_at = now(), tutor_answered_by = auth.uid()
  where id = pl.id and tutor_answer is distinct from case when p_yes then 'yes' else 'no' end;
  return jsonb_build_object('plan_id', pl.id, 'answer', case when p_yes then 'yes' else 'no' end);
end $$;
revoke all on function tutor_plan_answer(uuid, boolean, uuid) from public, anon;
grant execute on function tutor_plan_answer(uuid, boolean, uuid) to authenticated;

-- 강사 To do 목록: 나에게 온 신규 문의 (답 대기 일정안, 신규 등록만)
create or replace function tutor_new_requests(p_tutor uuid default null) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  me uuid := lms_screen_tutor(p_tutor);
begin
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'plan_id', pl.id, 'student', lms_tutor_student_label(s.name_en, s.display_name),
             'minutes', e.duration_min, 'classes', e.lessons_purchased,
             'first', f.first_at, 'every', to_jsonb(f.every), 'answer', pl.tutor_answer) order by f.first_at)
    from schedule_plans pl
    join enrollments e on e.id = pl.enrollment_id and e.previous_enrollment_id is null
    join students s on s.id = e.student_id
    cross join lateral lms_plan_first_times(pl.id) f
    where pl.tutor_id = me and pl.state = 'proposed'), '[]'::jsonb);
end $$;
revoke all on function tutor_new_requests(uuid) from public, anon;
grant execute on function tutor_new_requests(uuid) to authenticated;

-- ---------------------------------------------------------------------
-- 5. 일정 확정(신규 배정·재등록) → 강사 Updates + 메일 ②/⑤, 운영진 강사 안내·재등록 업무 자동 끝
--    lms_confirm_plan 이 수업을 만든 뒤 state 를 'confirmed' 로 바꿀 때
-- ---------------------------------------------------------------------
create or replace function lms_enrollment_lessons(p_enrollment uuid, out first_at timestamptz, out first_end timestamptz, out last_at timestamptz)
language sql stable security definer set search_path = public as $$
  select min(starts_at), (array_agg(ends_at order by starts_at))[1], max(starts_at)
  from lessons where enrollment_id = p_enrollment and voided_at is null and state <> 'canceled'
$$;

create or replace function lms_plan_confirmed_notice() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  e enrollments;
  st students;
  tu tutors;
  x record;
  v_every timestamptz[];
  v_prev_tutor uuid;
  v_prev_last lessons;
  v_same boolean := false;
  v_new boolean;
  v_name text;
  v_id uuid;
  v_mail uuid;
  t admin_tasks;
begin
  select * into e from enrollments where id = new.enrollment_id;
  select * into st from students where id = e.student_id;
  select * into tu from tutors where id = new.tutor_id;
  select * into x from lms_enrollment_lessons(e.id);
  if x.first_at is null then return null; end if;
  v_every := lms_slot_times(new.slots, (x.first_at at time zone 'Asia/Seoul')::date);
  if v_every is null then v_every := array[x.first_at]; end if;
  v_name := lms_student_en(st);
  if e.previous_enrollment_id is not null then
    select * into v_prev_last from lessons where enrollment_id = e.previous_enrollment_id and kind = 'regular' and voided_at is null
    order by starts_at desc limit 1;
    v_prev_tutor := coalesce(v_prev_last.original_tutor_id, v_prev_last.tutor_id);
    if v_prev_last.id is not null then
      v_same := lms_slots_on(st.id, (v_prev_last.starts_at at time zone 'Asia/Seoul')::date) = lms_slots_on(st.id, e.start_date);
    end if;
  end if;
  v_new := e.previous_enrollment_id is null or v_prev_tutor is distinct from new.tutor_id;
  if v_new then
    v_id := lms_tutor_update_add(new.tutor_id, st.id, 'new_student',
      jsonb_build_object('first', x.first_at, 'last', x.last_at, 'every', to_jsonb(v_every), 'minutes', e.duration_min, 'classes', e.lessons_purchased),
      x.first_end, 'plan_confirmed:' || new.id,
      '[Edge English] CONFIRMED new student - ' || v_name || ' · first class ' || lms_mail_en_date(x.first_at, tu.timezone),
      array[
        'CONFIRMED new student - ' || v_name || ' (' || e.duration_min || ' min, ' || e.lessons_purchased || ' classes)',
        'Time: ' || lms_mail_en_every(v_every, tu.timezone) || E'\n'
          || 'First class: ' || lms_mail_en_at(x.first_at, tu.timezone) || ' · last ' || lms_mail_en_date(x.last_at, tu.timezone),
        'It''s in your LMS schedule. Thank you!']);
  else
    v_id := lms_tutor_update_add(new.tutor_id, st.id, 'renewal',
      jsonb_build_object('first', x.first_at, 'last', x.last_at, 'every', to_jsonb(v_every), 'minutes', e.duration_min, 'classes', e.lessons_purchased, 'same', v_same),
      x.first_end, 'plan_confirmed:' || new.id,
      '[Edge English] RENEWED - ' || v_name || ' · next period from ' || lms_mail_en_date(x.first_at, tu.timezone),
      array[
        'RENEWED - ' || v_name || ' (' || e.duration_min || ' min, ' || e.lessons_purchased || ' classes)',
        'Next period: ' || lms_mail_en_date(x.first_at, tu.timezone) || ' – ' || lms_mail_en_date(x.last_at, tu.timezone) || E'\n'
          || case when v_same then 'Time: ' || lms_mail_en_every(v_every, tu.timezone) || ' (same schedule)'
                  else 'New schedule: ' || lms_mail_en_every(v_every, tu.timezone) end,
        'Thank you for teaching ' || v_name || '!']);
  end if;
  select email_notification_id into v_mail from tutor_updates where source_key = 'plan_confirmed:' || new.id;
  if v_mail is not null then
    -- 신규 배정: 강사 안내는 시스템이 보냄 (운영진 카드에는 수강생 카톡만 남음)
    insert into schedule_notices (plan_id, recipient_kind, recipient_id, channel, status, sent_at, sent_via)
    values (new.id, 'tutor', new.tutor_id, 'email', 'sent', now(), 'system')
    on conflict (plan_id, recipient_kind) do nothing;
    -- 재등록: 운영진 업무 자동 끝 (강사 변경 예정인데 같은 강사로 확정한 경우만 남김)
    select * into t from admin_tasks where kind = 'renewal_tutor_notice' and enrollment_id = e.id and status = 'open' for update;
    if found and not (t.tutor_change_planned and t.tutor_id is not distinct from new.tutor_id) then
      update admin_tasks set tutor_id = new.tutor_id, tutor_notified_at = coalesce(tutor_notified_at, now()),
             schedule_checked_at = coalesce(schedule_checked_at, now()), status = 'done', done_at = now()
      where id = t.id;
    end if;
  end if;
  perform lms_first_class_check(e.id);
  return null;
end $$;

-- ---------------------------------------------------------------------
-- 6. 정규 수업 시간 변경 → 강사 Updates + 메일 ④ (H26(122)), 운영진 강사 문구 없앰
-- ---------------------------------------------------------------------
create or replace function lms_regular_change_notice() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  st students;
  tu tutors;
  e enrollments;
  v_first timestamptz;
  v_until timestamptz;
  v_every timestamptz[];
  v_list text;
  v_n integer;
  v_name text;
  v_min integer;
  v_from text;
begin
  select * into st from students where id = new.student_id;
  select * into tu from tutors where id = new.tutor_id;
  select * into e from enrollments where id = new.enrollment_id;
  select min((m ->> 'to')::timestamptz), min((m ->> 'to_end')::timestamptz), count(*),
         string_agg('- ' || lms_mail_en_at((m ->> 'to')::timestamptz, tu.timezone), E'\n' order by (m ->> 'to')::timestamptz)
    into v_first, v_until, v_n, v_list
  from jsonb_array_elements(coalesce(new.moved, '[]'::jsonb)) m;
  v_every := lms_slot_times(new.new_slots, coalesce((v_first at time zone 'Asia/Seoul')::date, new.effective_from));
  v_until := coalesce(v_until, (new.effective_from + 1)::timestamp at time zone 'Asia/Seoul');
  v_min := coalesce(e.duration_min, (select duration_min from regular_schedules where student_id = st.id order by effective_from desc limit 1));
  v_name := lms_student_en(st);
  v_from := case when v_first is not null then lms_mail_en_date(v_first, tu.timezone) else lms_mail_en_date(new.effective_from::timestamp at time zone 'Asia/Seoul', 'Asia/Seoul') end;
  perform lms_tutor_update_add(new.tutor_id, st.id, 'schedule_change',
    jsonb_build_object('from', coalesce(v_first, new.effective_from::timestamp at time zone 'Asia/Seoul'), 'every', to_jsonb(v_every), 'minutes', v_min, 'changed', coalesce(v_n, 0)),
    v_until, 'regular_change:' || new.id,
    '[Edge English] SCHEDULE CHANGE - ' || v_name || ' · from ' || v_from,
    array[
      'SCHEDULE CHANGE - ' || v_name || ' (' || v_min || ' min), from ' || v_from,
      'New regular time: ' || coalesce(lms_mail_en_every(v_every, tu.timezone), ''),
      'Changed classes (' || coalesce(v_n, 0) || '):' || coalesce(E'\n' || v_list, ''),
      'Confirmed make-up and cover classes stay as they are. Your LMS schedule is updated. Thank you!']);
  if exists (select 1 from tutor_updates where source_key = 'regular_change:' || new.id and email_notification_id is not null) then
    update regular_changes set tutor_sent_at = coalesce(tutor_sent_at, now()) where id = new.id;
  end if;
  perform lms_first_class_check(new.enrollment_id);
  return null;
end $$;

drop trigger if exists regular_changes_tutor_notice on regular_changes;
create trigger regular_changes_tutor_notice after insert on regular_changes for each row execute function lms_regular_change_notice();

-- ---------------------------------------------------------------------
-- 7. 첫 수업 전 수업 날짜 변경 → 강사 Updates (H26(125)). 첫 수업이 바뀌면 첫 수업 변경 메일 (H26(129) 문구)
-- ---------------------------------------------------------------------
create or replace function lms_prestart_move_notice() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  l lessons;
  v_first boolean;
begin
  select * into l from lessons where id = new.lesson_id;
  v_first := not exists (select 1 from lessons x where x.enrollment_id = new.enrollment_id and x.id <> new.lesson_id
                         and x.voided_at is null and x.state <> 'canceled' and x.starts_at < greatest(new.from_starts_at, new.to_starts_at))
             or not exists (select 1 from lessons x where x.enrollment_id = new.enrollment_id and x.id <> new.lesson_id
                         and x.voided_at is null and x.state <> 'canceled' and x.starts_at < least(new.from_starts_at, new.to_starts_at));
  perform lms_tutor_update_add(l.tutor_id, new.student_id, 'class_moved',
    jsonb_build_object('to', new.to_starts_at, 'was', new.from_starts_at, 'is_first', v_first),
    new.to_ends_at, 'prestart_move:' || new.id, null, null);
  if v_first then perform lms_first_class_check(new.enrollment_id, now(), true); end if;
  return null;
end $$;

drop trigger if exists prestart_moves_tutor_notice on prestart_moves;
create trigger prestart_moves_tutor_notice after insert on prestart_moves for each row execute function lms_prestart_move_notice();

-- ---------------------------------------------------------------------
-- 8. 강사에게 가는 lesson_notices 는 운영진 복사 카드 없음 ('not_needed'). 메일·Updates 가 대신함
-- ---------------------------------------------------------------------
create or replace function lesson_notices_tutor_no_copy() returns trigger
language plpgsql as $$
begin
  if new.recipient_kind = 'tutor' and new.status = 'pending'
     and new.event in ('change', 'makeup_confirmed', 'makeup_rescheduled', 'makeup_tutor_removed', 'makeup_voided', 'revert', 'sub_confirmed', 'makeup_requested') then
    new.status := 'not_needed';
  end if;
  return new;
end $$;
drop trigger if exists lesson_notices_tutor_no_copy on lesson_notices;
create trigger lesson_notices_tutor_no_copy before insert on lesson_notices for each row execute function lesson_notices_tutor_no_copy();

-- 대체 수업 확정 → 대체강사 메일 ③ (같은 수강생·같은 번에 확정한 수업을 한 통으로, 휴무 강사 이름 없음)
create or replace function lms_sub_confirmed_mail() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  n lesson_notices;
  st students;
  tu tutors;
  v_ids uuid[];
  v_first timestamptz;
  v_min integer;
  v_list text;
  v_cnt integer;
  v_mail uuid;
  v_name text;
begin
  select * into n from lesson_notices where id = new.id;
  if n.event <> 'sub_confirmed' or n.recipient_kind <> 'tutor' or n.email_notification_id is not null or n.email_status is not null then return null; end if;
  select s.* into st from leave_items li join students s on s.id = li.student_id where li.id = n.leave_item_id;
  select * into tu from tutors where id = n.recipient_id;
  select array_agg(ln.id order by l.starts_at), min(l.starts_at), min(round(extract(epoch from l.ends_at - l.starts_at) / 60)::int), count(*),
         string_agg(lms_mail_en_at(l.starts_at, tu.timezone), E'\n' order by l.starts_at)
    into v_ids, v_first, v_min, v_cnt, v_list
  from lesson_notices ln
  join leave_items li on li.id = ln.leave_item_id and li.student_id = st.id and li.sub_stage = 'confirmed'
  join lessons l on l.id = li.sub_lesson_id and l.tutor_id = n.recipient_id
  where ln.event = 'sub_confirmed' and ln.recipient_kind = 'tutor' and ln.recipient_id = n.recipient_id
    and ln.created_at = n.created_at and ln.email_notification_id is null and ln.email_status is null;
  if v_cnt is null or v_cnt = 0 then return null; end if;
  select string_agg(i || ') ' || line, E'\n' order by i) into v_list
  from unnest(string_to_array(v_list, E'\n')) with ordinality as a(line, i);
  v_name := lms_student_en(st);
  v_mail := lms_tutor_mail(n.recipient_id, st.id, 'lesson_notice_sub_confirmed', 'tutor_mail:cover:' || v_ids[1],
    '[Edge English] CONFIRMED cover classes - ' || v_name || ' · from ' || lms_mail_en_date(v_first, tu.timezone),
    array['CONFIRMED cover classes - ' || v_name || ' (' || v_min || ' min)', v_list,
          case when v_cnt = 1 then 'It''s in your LMS schedule. Thank you!' else 'They''re in your LMS schedule. Thank you!' end]);
  if v_mail is null then
    update lesson_notices set email_status = 'no_address', email_queued_at = now(), email_error = '강사 이메일이 없어요' where id = any(v_ids);
  else
    update lesson_notices ln set email_status = 'queued', email_queued_at = now(), email_notification_id = v_mail,
           email_to = x.email, email_intended = x.payload ->> 'intended_email'
    from notifications x where x.id = v_mail and ln.id = any(v_ids);
  end if;
  return null;
end $$;
drop trigger if exists lesson_notices_sub_confirmed_mail on lesson_notices;
create constraint trigger lesson_notices_sub_confirmed_mail after insert on lesson_notices
  deferrable initially deferred for each row execute function lms_sub_confirmed_mail();

-- ---------------------------------------------------------------------
-- 9. 강사 Updates 목록 (Home). 가까운 수업부터, 그 수업이 끝나면 빠짐
--    kind: new_student · renewal · schedule_change · class_moved · cover · makeup_new · makeup_moved · makeup_removed · makeup_canceled · cancel_undone · canceled
-- ---------------------------------------------------------------------
create or replace function tutor_updates_feed(p_tutor uuid default null) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  me uuid := lms_screen_tutor(p_tutor);
begin
  return coalesce((select jsonb_agg(r order by (r ->> 'at')::timestamptz, r ->> 'id') from (
    -- 신규 배정·재등록·정규 시간 변경·첫 수업 전 날짜 변경
    select jsonb_build_object('id', u.id, 'kind', u.kind, 'student', lms_tutor_student_label(s.name_en, s.display_name), 'student_id', s.id,
             'at', coalesce(u.info ->> 'first', u.info ->> 'from', u.info ->> 'to'), 'info', u.info) as r
    from tutor_updates u join students s on s.id = u.student_id
    where u.tutor_id = me and u.visible_until > now()
    union all
    -- 보강: 요청마다 마지막 안내 한 줄 (강사가 직접 확정한 보강은 안 보임)
    select jsonb_build_object('id', z.id, 'kind', z.kind, 'student', lms_tutor_student_label(s.name_en, s.display_name), 'student_id', s.id,
             'at', z.at, 'info', jsonb_build_object('was', z.was, 'origin', z.origin))
    from (
      select distinct on (n.makeup_request_id) n.id, l.student_id,
             case when n.event = 'makeup_confirmed' then 'makeup_new'
                  when g.old_tutor_id is not null and g.old_tutor_id <> me then 'makeup_new'
                  else 'makeup_moved' end as kind,
             l.starts_at as at,
             case when n.event = 'makeup_rescheduled' and (g.old_tutor_id is null or g.old_tutor_id = me) then g.old_starts_at end as was,
             coalesce(src.starts_at, (select original_date::timestamp at time zone 'Asia/Seoul' from migrated_items where id = r.migrated_item_id)) as origin,
             n.event, coalesce(r.confirmed_in_tutor_screen, false) as by_tutor, l.ends_at
      from lesson_notices n
      join makeup_requests r on r.id = n.makeup_request_id
      join lessons l on l.id = r.confirmed_lesson_id and l.tutor_id = me and l.state = 'scheduled' and l.voided_at is null
      left join lessons src on src.id = coalesce(r.source_lesson_id, (select c.source_lesson_id from compensations c where c.id = r.compensation_id))
      left join lateral (select x.* from admin_makeup_logs x where x.makeup_request_id = r.id and x.action = 'reschedule' and x.created_at <= n.created_at
                         order by x.created_at desc limit 1) g on n.event = 'makeup_rescheduled'
      where n.recipient_kind = 'tutor' and n.recipient_id = me and n.event in ('makeup_confirmed', 'makeup_rescheduled')
      order by n.makeup_request_id, n.created_at desc
    ) z join students s on s.id = z.student_id
    where z.ends_at > now() and not (z.event = 'makeup_confirmed' and z.by_tutor)
    union all
    -- 보강에서 빠짐(다른 강사로) · 보강 취소
    select jsonb_build_object('id', n.id, 'kind', case when n.event = 'makeup_voided' then 'makeup_canceled' else 'makeup_removed' end,
             'student', lms_tutor_student_label(s.name_en, s.display_name), 'student_id', s.id,
             'at', coalesce(g.old_starts_at, l.starts_at), 'info', '{}'::jsonb)
    from lesson_notices n
    join makeup_requests r on r.id = n.makeup_request_id
    join lessons l on l.id = r.confirmed_lesson_id
    join students s on s.id = r.student_id
    left join lateral (select x.* from admin_makeup_logs x where x.makeup_request_id = r.id and x.action = 'reschedule' and x.created_at <= n.created_at
                       order by x.created_at desc limit 1) g on n.event = 'makeup_tutor_removed'
    where n.recipient_kind = 'tutor' and n.recipient_id = me and n.event in ('makeup_tutor_removed', 'makeup_voided')
      and coalesce(g.old_starts_at, l.starts_at) + (l.ends_at - l.starts_at) > now()
    union all
    -- 취소 되돌림: 그 수업이 다시 일정에
    select jsonb_build_object('id', n.id, 'kind', 'cancel_undone', 'student', lms_tutor_student_label(s.name_en, s.display_name), 'student_id', s.id,
             'at', l.starts_at, 'info', '{}'::jsonb)
    from lesson_notices n
    join change_requests c on c.id = n.change_request_id
    join lessons l on l.id = c.lesson_id and l.tutor_id = me and l.state = 'scheduled' and l.voided_at is null
    join students s on s.id = l.student_id
    where n.recipient_kind = 'tutor' and n.recipient_id = me and n.event = 'revert' and l.ends_at > now()
    union all
    -- 대체 수업 확정: 같은 수강생·같은 번에 확정한 수업 묶음, 마지막 수업이 끝날 때까지
    select jsonb_build_object('id', min(n.id::text), 'kind', 'cover', 'student', lms_tutor_student_label(s.name_en, s.display_name), 'student_id', s.id,
             'at', min(l.starts_at), 'info', jsonb_build_object('times', jsonb_agg(l.starts_at order by l.starts_at)))
    from lesson_notices n
    join leave_items li on li.id = n.leave_item_id and li.sub_stage = 'confirmed' and li.sub_tutor_id = me
    join lessons l on l.id = li.sub_lesson_id and l.tutor_id = me and l.state = 'scheduled' and l.voided_at is null
    join students s on s.id = li.student_id
    where n.recipient_kind = 'tutor' and n.recipient_id = me and n.event = 'sub_confirmed'
      and not exists (select 1 from lesson_notices n2 where n2.leave_item_id = n.leave_item_id and n2.event = 'sub_confirmed'
                      and n2.recipient_kind = 'tutor' and n2.recipient_id = me and n2.created_at > n.created_at)
    group by s.id, s.name_en, s.display_name, n.created_at
    having max(l.ends_at) > now()
    union all
    -- 수강생이 취소한 수업 (그 수업이 끝날 때까지)
    select jsonb_build_object('id', l.id, 'kind', 'canceled', 'student', coalesce(s.display_name, s.name_en), 'student_id', s.id,
             'at', l.starts_at, 'info', jsonb_build_object('late', l.class_status = 'Student canceled late'))
    from lessons l join students s on s.id = l.student_id
    where l.tutor_id = me and l.voided_at is null and l.state = 'canceled' and l.ends_at > now()
      and l.class_status in ('Student canceled in advance', 'Student canceled in advance (public holiday)', 'Student canceled late')
  ) q), '[]'::jsonb);
end $$;
revoke all on function tutor_updates_feed(uuid) from public, anon;
grant execute on function tutor_updates_feed(uuid) to authenticated;

-- ---------------------------------------------------------------------
-- 10. 첫 수업 안내 메일 (H26(129)) — 학생(한국어, 거주지 시간만)·강사(영어, 현지 / KST)
--  대상: 신규 / 재등록인데 고정 요일·시간이 바뀜 / 이전 고정 일정대로 이어지지 않고 쉬었다 시작 / 둘 다
--  때: 첫 수업 24시간 전(또는 그 안에 확정되면 바로) 1통. 보낸 뒤 첫 수업·고정 일정·강사가 바뀌면 바로 변경 안내
--  같은 일정 판(version)은 한 번만. 강사가 바뀌면 새 강사에게만. 첫 수업이 시작되면 끝
-- ---------------------------------------------------------------------
create or replace function lms_first_class_mail_student(e enrollments, f lessons, p_every timestamptz[], p_label text, p_change boolean, p_key text, p_version text, p_slots jsonb)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  v_live boolean := coalesce((select x.enabled from feature_flags x where x.key = 'send_emails'), false);
  st students;
  tu tutors;
  v_tz text;
  v_intended text;
  v_to text;
  v_subject text;
  v_url text;
  v_btn text := '수업 입장하기';
  v_zone text;
  v_p1 text;
  v_p2 text;
  v_foot text := '문의: 카카오톡 채널 엣지영어';
  v_html text;
  v_body text;
  v_id uuid;
begin
  select * into st from students where id = e.student_id;
  select * into tu from tutors where id = f.tutor_id;
  v_tz := coalesce(nullif(st.timezone, ''), 'Asia/Seoul');
  v_intended := lms_notice_recipient_email('student', st.id);
  if v_intended is null then return null; end if;
  v_to := case when v_live then v_intended else 'support@edgeenglish.kr' end;
  v_subject := case when v_live then '' else '[시험 · ' || st.code || '] ' end
               || case when p_change then '[엣지영어] 첫 수업 일정이 변경됐어요' else '[엣지영어] 첫 수업 일정 안내' end;
  v_url := coalesce(nullif(trim(tu.meet_url), ''), lms_url() || '/student');
  v_zone := regexp_replace(lms_mail_ko_zone(v_tz), ' 시간$', '');
  v_p1 := case when p_change then '첫 수업 일정이 변경되어 다시 안내해 드려요.' else '안녕하세요, ' || st.name_ko || '님! ☺️' || E'\n' || '첫 수업 일정을 안내해 드려요.' end;
  v_p2 := '첫 수업: ' || lms_mail_ko_date(f.starts_at, v_tz) || ' ' || lms_mail_ko_clock(f.starts_at, v_tz) || E'\n'
          || '담당 강사: ' || tu.name || E'\n'
          || p_label || ': ' || lms_mail_ko_every(p_every, v_tz);
  v_body := v_p1 || E'\n\n' || v_p2 || E'\n\n' || v_btn || ': ' || v_url || E'\n\n' || '모든 시간은 ' || v_zone || ' 시간대 기준이에요.' || E'\n' || v_foot
            || case when v_live then '' else E'\n\n(시험 발송 · 원래 받는 사람: ' || v_intended || ')' end;
  v_html := '<div style="font-family:sans-serif;font-size:15px;line-height:1.6;color:#1d1b2a;max-width:480px">'
            || case when v_live then '' else '<p style="background:#fff4d6;color:#5c3b00;border-radius:8px;padding:8px 10px;font-size:13px;font-weight:600">시험 발송 · 원래 받는 사람: ' || lms_html(v_intended) || '</p>' end
            || '<p>' || replace(lms_html(v_p1), E'\n', '<br>') || '</p>'
            || '<p style="font-weight:700">' || replace(lms_html(v_p2), E'\n', '<br>') || '</p>'
            || '<p><a href="' || lms_html(v_url) || '" style="display:inline-block;background:#5b3df0;color:#fff;border-radius:10px;padding:11px 18px;font-weight:700;text-decoration:none">' || lms_html(v_btn) || '</a></p>'
            || '<p style="font-size:13px;color:#55526a">모든 시간은 ' || lms_html(v_zone) || ' 시간대 기준이에요.</p>'
            || '<p style="font-size:12.5px;color:#55526a;border-top:1px solid #e6e3ef;padding-top:10px">' || lms_html(v_foot) || '</p></div>';
  insert into notifications (recipient_kind, recipient_id, email, locale, template, payload, dedupe_key)
  values ('student', st.id, v_to, 'ko', 'lesson_notice_first_class',
          jsonb_build_object('intended_email', v_intended, 'subject', v_subject, 'html', v_html, 'text', v_body,
                             'enrollment_id', e.id, 'version', p_version, 'slots', p_slots, 'stage', case when p_change then 'change' else 'reminder' end),
          p_key)
  on conflict (dedupe_key) do nothing
  returning id into v_id;
  if v_id is not null then perform lms_mail_dispatch(v_id); end if;
  return v_id;
end $$;

create or replace function lms_first_class_check(p_enrollment uuid, p_now timestamptz default now(), p_tutor_now boolean default false)
returns integer language plpgsql security definer set search_path = public as $$
declare
  v_since timestamptz := (select x.updated_at from feature_flags x where x.key = 'first_class_mail_since');
  e enrollments;
  f lessons;
  st students;
  tu tutors;
  p lessons;
  v_slots jsonb;
  v_prev_slots jsonb;
  v_expected timestamptz;
  v_same boolean := true;
  v_gap boolean := false;
  v_renew boolean;
  v_every timestamptz[];
  v_version text;
  v_in_window boolean;
  v_label text;
  v_name text;
  v_n integer := 0;
  v_last_version text;
  v_last_slots jsonb;
  v_reminded boolean;
  v_id uuid;
  rk text;
  rid uuid;
begin
  if v_since is null then return 0; end if;
  select * into e from enrollments where id = p_enrollment;
  if not found or e.status not in ('confirmed', 'active') or e.created_at < v_since then return 0; end if;
  select * into f from lessons where enrollment_id = e.id and voided_at is null and state <> 'canceled' order by starts_at limit 1;
  if not found or f.starts_at <= p_now then return 0; end if;   -- 첫 수업이 시작됨(또는 수업 없음) → 끝
  select * into st from students where id = e.student_id;
  select * into tu from tutors where id = f.tutor_id;
  v_slots := lms_slots_on(st.id, greatest(e.start_date, (f.starts_at at time zone 'Asia/Seoul')::date));
  v_renew := e.previous_enrollment_id is not null;
  if v_renew then
    select * into p from lessons where enrollment_id = e.previous_enrollment_id and kind = 'regular' and voided_at is null and state <> 'canceled'
    order by starts_at desc limit 1;
    if p.id is not null then
      v_prev_slots := lms_slots_on(st.id, (p.starts_at at time zone 'Asia/Seoul')::date);
      v_same := v_prev_slots = v_slots;
      -- 이전 고정 일정대로 계속했다면 나왔을 다음 수업
      select min(t) into v_expected from unnest(lms_slot_times(v_prev_slots, (p.starts_at at time zone 'Asia/Seoul')::date + 1)) t;
      v_gap := v_expected is distinct from f.starts_at;
      if v_same and not v_gap then return 0; end if;            -- 같은 요일·시간 그대로 공백 없이 이어짐 → 안 보냄
    end if;
  end if;
  v_every := lms_slot_times(v_slots, (f.starts_at at time zone 'Asia/Seoul')::date);
  if v_every is null then v_every := array[f.starts_at]; end if;
  v_version := md5(f.id::text || f.starts_at::text || f.tutor_id::text || v_slots::text);
  v_in_window := p_now >= f.starts_at - interval '24 hours';
  v_name := lms_student_en(st);

  for rk, rid in select * from (values ('student', st.id), ('tutor', f.tutor_id)) v(k, i) loop
    v_last_version := null; v_last_slots := null;
    select x.payload ->> 'version', x.payload -> 'slots' into v_last_version, v_last_slots
    from notifications x where x.recipient_kind = rk and x.recipient_id = rid and x.template in ('lesson_notice_first_class', 'lesson_notice_tutor_first_class')
      and x.payload ->> 'enrollment_id' = e.id::text and x.status <> 'canceled'
    order by x.created_at desc limit 1;
    v_reminded := exists (select 1 from notifications x where x.recipient_kind = rk and x.recipient_id = rid
      and x.template in ('lesson_notice_first_class', 'lesson_notice_tutor_first_class') and x.payload ->> 'enrollment_id' = e.id::text
      and x.payload ->> 'stage' = 'reminder' and x.status <> 'canceled');
    v_id := null;
    if not v_reminded and v_in_window then
      -- 첫 안내 (24시간 전 / 그 안에 확정되면 바로)
      v_label := case when v_renew and not v_same then '새로 정한 수업 일정' else '정규 수업' end;
      if rk = 'student' then
        v_id := lms_first_class_mail_student(e, f, v_every, v_label, false, 'first_class:' || e.id || ':student:reminder:' || v_version, v_version, v_slots);
      else
        v_id := lms_tutor_first_class_mail(e, f, v_every, false, 'first_class:' || e.id || ':' || rid || ':reminder:' || v_version, v_version, v_slots, 'reminder');
      end if;
    elsif (v_reminded and v_last_version is distinct from v_version)
          or (rk = 'tutor' and p_tutor_now and v_last_version is distinct from v_version) then
      -- 보낸 뒤 바뀜 → 바로 변경 안내 (강사는 첫 수업 날짜가 바뀌면 24시간 전이 아니어도 바로, H26(127))
      v_label := case when v_last_slots is not null and v_last_slots <> v_slots then '새로 정한 수업 일정'
                      when v_last_slots is null and v_renew and not v_same then '새로 정한 수업 일정' else '정규 수업' end;
      if rk = 'student' then
        v_id := lms_first_class_mail_student(e, f, v_every, v_label, true, 'first_class:' || e.id || ':student:change:' || v_version, v_version, v_slots);
      else
        v_id := lms_tutor_first_class_mail(e, f, v_every, true, 'first_class:' || e.id || ':' || rid || ':change:' || v_version, v_version, v_slots, 'change');
      end if;
    end if;
    if v_id is not null then v_n := v_n + 1; end if;
  end loop;
  return v_n;
end $$;

create or replace function lms_tutor_first_class_mail(e enrollments, f lessons, p_every timestamptz[], p_change boolean, p_key text, p_version text, p_slots jsonb, p_stage text)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  st students;
  tu tutors;
  v_name text;
  v_id uuid;
begin
  select * into st from students where id = e.student_id;
  select * into tu from tutors where id = f.tutor_id;
  v_name := lms_student_en(st);
  v_id := lms_tutor_mail(tu.id, st.id, 'lesson_notice_tutor_first_class', p_key,
    case when p_change then '[Edge English] First Class Schedule Updated – ' else '[Edge English] Upcoming First Class – ' end || v_name,
    array[
      'Hi ' || tu.name || ',' || E'\n'
        || case when e.previous_enrollment_id is null then 'Here''s a reminder of your first class with ' || v_name || '.'
                else 'Here''s a reminder of your first class for the new course period.' end,
      'Student: ' || v_name || E'\n'
        || 'First class: ' || lms_mail_en_at(f.starts_at, tu.timezone) || E'\n'
        || 'Regular schedule: ' || lms_mail_en_every(p_every, tu.timezone)],
    false);
  if v_id is not null then
    update notifications set payload = payload || jsonb_build_object('enrollment_id', e.id, 'version', p_version, 'slots', p_slots, 'stage', p_stage)
    where id = v_id and not (payload ? 'version');
  end if;
  return v_id;
end $$;

create or replace function lms_first_class_run(p_now timestamptz default now()) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  x record;
  v_n integer := 0;
  v_since timestamptz := (select f.updated_at from feature_flags f where f.key = 'first_class_mail_since');
begin
  if v_since is null then return jsonb_build_object('sent', 0); end if;
  for x in
    select e.id from enrollments e
    where e.status in ('confirmed', 'active') and e.created_at >= v_since
      and exists (select 1 from lessons l where l.enrollment_id = e.id and l.voided_at is null and l.state <> 'canceled' and l.starts_at > p_now)
  loop
    v_n := v_n + lms_first_class_check(x.id, p_now);
  end loop;
  return jsonb_build_object('sent', v_n);
end $$;

-- 수업이 바뀌면(취소·되돌림·날짜 변경·강사 변경) 첫 수업 안내 다시 확인 — 보낸 뒤 바뀐 것만 바로 나감
create or replace function lms_lessons_first_class_recheck() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.enrollment_id is not null and (new.starts_at is distinct from old.starts_at or new.state is distinct from old.state
       or new.tutor_id is distinct from old.tutor_id or new.voided_at is distinct from old.voided_at) then
    perform lms_first_class_check(new.enrollment_id);
  end if;
  return null;
end $$;
drop trigger if exists lessons_first_class_recheck on lessons;
create constraint trigger lessons_first_class_recheck after update on lessons
  deferrable initially deferred for each row execute function lms_lessons_first_class_recheck();

drop trigger if exists schedule_plans_confirmed_notice on schedule_plans;
create trigger schedule_plans_confirmed_notice after update of state on schedule_plans
  for each row when (new.state = 'confirmed' and old.state is distinct from 'confirmed') execute function lms_plan_confirmed_notice();

-- ---------------------------------------------------------------------
-- 11. 강사 [None of these times work] + 가능 시간 글 → 운영진(support@) 메일 (H26(124) ②). 학생에게는 안 보냄
-- ---------------------------------------------------------------------
create or replace function lms_makeup_none_work_mail() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  v_live boolean := coalesce((select f.enabled from feature_flags f where f.key = 'send_emails'), false);
  st students;
  tu tutors;
  src lessons;
  v_subject text;
  v_lines text[];
  v_url text := lms_url() || '/admin';
  v_btn text := '운영자 화면 열기';
  v_body text;
  v_html text;
  v_id uuid;
  v_times text;
begin
  if new.tutor_answered_at is null or new.tutor_answered_at is not distinct from old.tutor_answered_at or new.tutor_note is null then return null; end if;
  if exists (select 1 from makeup_candidates c where c.request_id = new.id and c.proposed_by = 'student' and c.tutor_answer = 'yes') then return null; end if;
  select * into st from students where id = new.student_id;
  select * into tu from tutors where id = new.tutor_id;
  select * into src from lessons where id = coalesce(new.source_lesson_id, (select c.source_lesson_id from compensations c where c.id = new.compensation_id));
  select string_agg('- ' || lms_mail_ko_at(c.starts_at, 'Asia/Seoul'), E'\n' order by c.starts_at) into v_times
  from makeup_candidates c where c.request_id = new.id and c.proposed_by = 'student';
  v_subject := case when v_live then '' else '[시험 · ' || st.code || '] ' end
               || '[엣지영어 운영] 강사가 고른 보강 시간 모두 불가 · ' || st.name_ko || ' (' || st.code || ') · ' || tu.name;
  v_lines := array[
    '강사가 수강생이 고른 보강 시간이 모두 안 된다고 답했어요. 수강생에게는 메일이 가지 않았어요.',
    '수강생: ' || st.name_ko || ' (' || st.code || ')' || E'\n' || '강사: ' || tu.name
      || case when src.id is not null then E'\n' || '원래 수업: ' || lms_mail_ko_at(src.starts_at, 'Asia/Seoul') else '' end,
    '수강생이 고른 시간:' || E'\n' || coalesce(v_times, '-'),
    '강사가 적은 가능 시간:' || E'\n' || new.tutor_note];
  v_body := array_to_string(v_lines, E'\n\n') || E'\n\n' || v_btn || ': ' || v_url;
  v_html := '<div style="font-family:sans-serif;font-size:15px;line-height:1.6;color:#1d1b2a;max-width:480px">'
            || '<p style="font-weight:700">' || lms_html(v_lines[1]) || '</p>'
            || '<p>' || replace(lms_html(v_lines[2]), E'\n', '<br>') || '</p>'
            || '<p>' || replace(lms_html(v_lines[3]), E'\n', '<br>') || '</p>'
            || '<p style="background:#f3f1fa;border-radius:8px;padding:8px 10px">' || replace(lms_html(v_lines[4]), E'\n', '<br>') || '</p>'
            || '<p><a href="' || lms_html(v_url) || '" style="display:inline-block;background:#5b3df0;color:#fff;border-radius:10px;padding:11px 18px;font-weight:700;text-decoration:none">' || lms_html(v_btn) || '</a></p></div>';
  insert into notifications (recipient_kind, recipient_id, email, locale, template, payload, dedupe_key)
  values ('admin', null, 'support@edgeenglish.kr', 'ko', 'lesson_notice_makeup_none_work',
          jsonb_build_object('intended_email', 'support@edgeenglish.kr', 'subject', v_subject, 'html', v_html, 'text', v_body, 'makeup_request_id', new.id),
          'makeup_none_work:' || new.id)
  on conflict (dedupe_key) do nothing
  returning id into v_id;
  if v_id is not null then perform lms_mail_dispatch(v_id); end if;
  return null;
end $$;
drop trigger if exists makeup_requests_none_work_mail on makeup_requests;
create trigger makeup_requests_none_work_mail after update of tutor_answered_at on makeup_requests
  for each row execute function lms_makeup_none_work_mail();

-- ---------------------------------------------------------------------
-- 12. 보강 재촉 (H26(133)): 신청 때 이미 고른 시간 중 가장 빠른 것이 24시간 안이면 재촉 생략 (신청 즉시 메일과 겹침 방지)
-- ---------------------------------------------------------------------
create or replace function public.lms_makeup_nudge_run(p_now timestamp with time zone default now())
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
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
           (select min(c.starts_at) from makeup_candidates c where c.request_id = r.id and c.proposed_by = 'student' and c.starts_at > p_now) as earliest,
           (select min(c.starts_at) from makeup_candidates c where c.request_id = r.id and c.proposed_by = 'student') as first_pick
    from makeup_requests r
    where r.status = 'requested' and r.tutor_answered_at is null and r.nudged_at is null
  loop
    if x.earliest is null then continue; end if;
    -- 신청 당시 가장 빠른 시간까지 24시간 이내였으면 재촉 없음 (신청 즉시 메일만, H26(133))
    if x.first_pick <= x.asked_at + interval '24 hours' then continue; end if;
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
end $function$;

-- ---------------------------------------------------------------------
-- 13. 권한: 내부 함수는 앱 사용자가 직접 못 부름
-- ---------------------------------------------------------------------
revoke all on function lms_tutor_mail(uuid, uuid, text, text, text, text[], boolean) from public, anon, authenticated;
revoke all on function lms_tutor_update_add(uuid, uuid, text, jsonb, timestamptz, text, text, text[]) from public, anon, authenticated;
revoke all on function lms_first_class_check(uuid, timestamptz, boolean) from public, anon, authenticated;
revoke all on function lms_first_class_run(timestamptz) from public, anon, authenticated;
revoke all on function lms_first_class_mail_student(enrollments, lessons, timestamptz[], text, boolean, text, text, jsonb) from public, anon, authenticated;
revoke all on function lms_tutor_first_class_mail(enrollments, lessons, timestamptz[], boolean, text, text, jsonb, text) from public, anon, authenticated;
revoke all on function lms_plan_first_times(uuid) from public, anon, authenticated;
revoke all on function lms_enrollment_lessons(uuid) from public, anon, authenticated;
revoke all on function lms_slots_on(uuid, date) from public, anon, authenticated;

-- 15분마다 첫 수업 안내 확인 (pg_cron 이 있는 Supabase 에서만)
do $$
begin
  if to_regnamespace('cron') is not null then
    perform cron.schedule('lms-first-class-mail', '*/15 * * * *', 'select lms_first_class_run(); select lms_mail_run();');
  end if;
end $$;

-- 도우미·트리거 함수도 앱 사용자·비로그인은 직접 못 부름
revoke all on function lms_mail_en_date(timestamptz, text) from public, anon, authenticated;
revoke all on function lms_mail_en_every(timestamptz[], text) from public, anon, authenticated;
revoke all on function lms_mail_ko_date(timestamptz, text) from public, anon, authenticated;
revoke all on function lms_mail_ko_clock(timestamptz, text) from public, anon, authenticated;
revoke all on function lms_mail_ko_every(timestamptz[], text) from public, anon, authenticated;
revoke all on function lms_slot_times(jsonb, date) from public, anon, authenticated;
revoke all on function lms_student_en(students) from public, anon, authenticated;
revoke all on function lms_plan_request_notice() from public, anon, authenticated;
revoke all on function lms_plan_confirmed_notice() from public, anon, authenticated;
revoke all on function lms_regular_change_notice() from public, anon, authenticated;
revoke all on function lms_prestart_move_notice() from public, anon, authenticated;
revoke all on function lesson_notices_tutor_no_copy() from public, anon, authenticated;
revoke all on function lms_sub_confirmed_mail() from public, anon, authenticated;
revoke all on function lms_lessons_first_class_recheck() from public, anon, authenticated;
revoke all on function lms_makeup_none_work_mail() from public, anon, authenticated;
