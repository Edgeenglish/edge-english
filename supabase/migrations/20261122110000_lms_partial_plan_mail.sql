-- =====================================================================
-- 일부 확정 일정안 강사 메일 (2026-11-22 대표 문구 확정 '넣어')
--  partial 일정안이 확정되면 강사 메일 본문을 아래 틀로 (숫자·날짜·도시·시각은 등록마다 자동, 해당 없는 줄은 없음)
--   RENEWED - 이름 (40 min, 24 classes)            ← 신규면 CONFIRMED new student - …
--   Next period: 23 Nov – 14 Feb                     ← 실제 수강권 기간 (시작일 – 최종 종료일)
--   • Confirmed: 9 classes · Mon, Thu 9:00 PM *Melbourne Time* / 7:00 PM *KST*
--     Mon 23 Nov, Thu 26 Nov, …
--   • Your time off: 4 classes. Arrangements are pending.
--     Thu 24 Dec, …
--   • New times needed: 11 classes. In Buenos Aires, Mon, Thu 7:00 AM *Buenos Aires Time* / 7:00 PM *KST* is before your working hours.
--     We'll arrange new times with the student. If the student wants, you can also talk about new times in class and let us know the time you agree on.
--     Thu 7 Jan, …
--   Thank you for teaching 이름!
--  partial 이 아닌 일정안 메일은 그대로
-- =====================================================================

create or replace function lms_mail_en_day(p_at timestamptz, p_tz text)
returns text language sql stable as $$ select replace(lms_mail_en_date(p_at, p_tz), ', ', ' ') $$;

create or replace function lms_partial_mail_lines(p_plan uuid, p_header text, p_closing text)
returns text[]
language plpgsql stable security definer set search_path = public as $$
declare
  pl schedule_plans;
  e enrollments;
  v_tz text;
  v_every timestamptz[];
  v_out text[];
  n integer;
  v_days text;
  v_cities text;
  v_times text;
  v_when text;
begin
  select * into pl from schedule_plans where id = p_plan;
  select * into e from enrollments where id = pl.enrollment_id;
  v_out := array[p_header || E'\n' || 'Next period: ' || to_char(e.start_date, 'FMDD Mon') || ' – ' || to_char(coalesce(e.final_end_date, e.base_end_date), 'FMDD Mon')];

  -- 확정 (휴무 기록 없는 수업)
  select count(*), string_agg(lms_mail_en_day(l.starts_at, lms_tutor_tz_at(pl.tutor_id, l.starts_at)), ', ' order by l.starts_at)
    into n, v_days
  from lessons l
  where l.enrollment_id = e.id and l.kind = 'regular' and l.voided_at is null and l.state <> 'canceled'
    and not exists (select 1 from leave_items i where i.lesson_id = l.id and i.withdrawn_at is null);
  if n > 0 then
    select array_agg(f order by f) into v_every from (
      select min(l.starts_at) f from lessons l
      where l.enrollment_id = e.id and l.kind = 'regular' and l.voided_at is null and l.state <> 'canceled'
        and not exists (select 1 from leave_items i where i.lesson_id = l.id and i.withdrawn_at is null)
      group by extract(dow from l.starts_at at time zone 'Asia/Seoul')) q;
    v_tz := lms_tutor_tz_at(pl.tutor_id, v_every[1]);
    v_out := v_out || ('• Confirmed: ' || n || ' classes · ' || regexp_replace(lms_mail_en_every(v_every, v_tz), '^Every ', '') || E'\n' || v_days);
  end if;

  -- 강사 휴무
  select count(*), string_agg(lms_mail_en_day(l.starts_at, lms_tutor_tz_at(pl.tutor_id, l.starts_at)), ', ' order by l.starts_at)
    into n, v_days
  from lessons l join leave_items i on i.lesson_id = l.id and i.withdrawn_at is null
  where l.enrollment_id = e.id and l.kind = 'regular' and l.voided_at is null;
  if n > 0 then
    v_out := v_out || ('• Your time off: ' || n || ' classes. Arrangements are pending.' || E'\n' || v_days);
  end if;

  -- 새 시간 필요 (해외 체류 근무 시간 밖)
  select count(*),
         string_agg(lms_mail_en_day(((p.original_date + p.time_kst) at time zone 'Asia/Seoul'), lms_tutor_tz_at(pl.tutor_id, ((p.original_date + p.time_kst) at time zone 'Asia/Seoul'))), ', ' order by p.seq)
    into n, v_days
  from plan_pending_lessons p where p.plan_id = pl.id and p.resolved_at is null;
  if n > 0 then
    select string_agg(distinct c.city, ' / ') into v_cities
    from plan_pending_lessons p
    join tutor_locations c on c.id = lms_tutor_location_at(pl.tutor_id, ((p.original_date + p.time_kst) at time zone 'Asia/Seoul'))
    where p.plan_id = pl.id and p.resolved_at is null;
    select array_agg(f order by f) into v_every from (
      select min((p.original_date + p.time_kst) at time zone 'Asia/Seoul') f from plan_pending_lessons p
      where p.plan_id = pl.id and p.resolved_at is null group by extract(dow from p.original_date)) q;
    v_tz := lms_tutor_tz_at(pl.tutor_id, v_every[1]);
    v_times := regexp_replace(lms_mail_en_every(v_every, v_tz), '^Every ', '');
    -- 근무 시작 전인지 끝난 뒤인지 (그 요일 근무 시간 기준, 섞이면 outside)
    select case when bool_and(z.lt < z.s0) then 'before' when bool_and(z.lt > z.s1) then 'after' else 'outside' end into v_when
    from (
      select (q.t at time zone a.timezone)::time lt, min(a.start_local) s0, max(a.end_local) s1
      from (select (p.original_date + p.time_kst) at time zone 'Asia/Seoul' t from plan_pending_lessons p where p.plan_id = pl.id and p.resolved_at is null) q
      join tutor_availability a on a.tutor_id = pl.tutor_id and a.location_id = lms_tutor_location_at(pl.tutor_id, q.t)
        and a.weekday = extract(dow from (q.t at time zone a.timezone))
        and a.effective_from <= (q.t at time zone a.timezone)::date and (a.effective_to is null or a.effective_to >= (q.t at time zone a.timezone)::date)
      group by q.t, a.timezone) z;
    v_out := v_out || ('• New times needed: ' || n || ' classes. '
      || coalesce('In ' || v_cities || ', ', '') || v_times || ' is ' || coalesce(v_when, 'outside') || ' your working hours. '
      || 'We''ll arrange new times with the student. If the student wants, you can also talk about new times in class and let us know the time you agree on.'
      || E'\n' || v_days);
  end if;
  return v_out || p_closing;
end $$;
revoke all on function lms_partial_mail_lines(uuid, text, text) from public, anon, authenticated;

-- 확정 알림 트리거: partial 일정안이면 위 본문, 아니면 그대로
create or replace function lms_plan_confirmed_notice()
returns trigger
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
      '[Edge English] CONFIRMED new student - ' || v_name || ' · first class ' || lms_mail_en_date(x.first_at, lms_tutor_tz_at(tu.id, x.first_at)),
      case when new.partial then
        lms_partial_mail_lines(new.id, 'CONFIRMED new student - ' || v_name || ' (' || e.duration_min || ' min, ' || e.lessons_purchased || ' classes)',
                               'It''s in your LMS schedule. Thank you!')
      else array[
        'CONFIRMED new student - ' || v_name || ' (' || e.duration_min || ' min, ' || e.lessons_purchased || ' classes)',
        'Time: ' || lms_tutor_every(tu.id, v_every, x.last_at, null) || E'\n'
          || 'First class: ' || lms_mail_en_at(x.first_at, lms_tutor_tz_at(tu.id, x.first_at)) || ' · last ' || lms_mail_en_date(x.last_at, lms_tutor_tz_at(tu.id, x.last_at)),
        'It''s in your LMS schedule. Thank you!'] end);
  else
    v_id := lms_tutor_update_add(new.tutor_id, st.id, 'renewal',
      jsonb_build_object('first', x.first_at, 'last', x.last_at, 'every', to_jsonb(v_every), 'minutes', e.duration_min, 'classes', e.lessons_purchased, 'same', v_same),
      x.first_end, 'plan_confirmed:' || new.id,
      '[Edge English] RENEWED - ' || v_name || ' · next period from ' || lms_mail_en_date(x.first_at, lms_tutor_tz_at(tu.id, x.first_at)),
      case when new.partial then
        lms_partial_mail_lines(new.id, 'RENEWED - ' || v_name || ' (' || e.duration_min || ' min, ' || e.lessons_purchased || ' classes)',
                               'Thank you for teaching ' || v_name || '!')
      else array[
        'RENEWED - ' || v_name || ' (' || e.duration_min || ' min, ' || e.lessons_purchased || ' classes)',
        'Next period: ' || lms_mail_en_date(x.first_at, lms_tutor_tz_at(tu.id, x.first_at)) || ' – ' || lms_mail_en_date(x.last_at, lms_tutor_tz_at(tu.id, x.last_at)) || E'\n'
          || case when v_same then 'Time: ' || lms_tutor_every(tu.id, v_every, x.last_at, null) || ' (same schedule)'
                  else 'New schedule: ' || lms_tutor_every(tu.id, v_every, x.last_at, null) end,
        'Thank you for teaching ' || v_name || '!'] end);
  end if;
  select email_notification_id into v_mail from tutor_updates where source_key = 'plan_confirmed:' || new.id;
  if v_mail is not null then
    insert into schedule_notices (plan_id, recipient_kind, recipient_id, channel, status, sent_at, sent_via)
    values (new.id, 'tutor', new.tutor_id, 'email', 'sent', now(), 'system')
    on conflict (plan_id, recipient_kind) do nothing;
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
