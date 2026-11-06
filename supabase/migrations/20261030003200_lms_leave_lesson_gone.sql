-- =====================================================================
-- 휴무 처리 줄과 실제 수업 상태 맞추기 (2026-10-30 전체 흐름 재설계 R5, docs/lms/requests/2026-10-30-flow-redesign.md)
--  - 문제: 학생이 휴무에 걸린 수업(대체 확정 포함)을 취소·변경해도 휴무 처리 줄은 그대로 → 학생 휴무 안내에 대체강사 확정·입장 링크가 계속,
--    강사 대체 요청·운영진 휴무 화면·대시보드에도 할 일로 남음
--  - leave_items.lesson_gone_at: 그 수업(또는 확정된 대체 수업)이 휴무 처리 밖에서 취소되면 시각을 적고, 수업이 되살아나면(변경 되돌리기) 지움
--    휴무 처리 자체의 취소('Tutor long-term leave' = 기존 강사와 보강)와 운영진 무르기(voided)는 '밖에서 취소'가 아님
--  - 학생 화면 휴무 안내 · 강사 화면 대체 요청에서 뺌 (운영진 화면·대시보드는 앱이 같은 칸으로 거름)
-- 기존 표·데이터를 지우지 않음 (새 칸만 채움). 다시 실행해도 같은 결과
-- =====================================================================

alter table leave_items add column if not exists lesson_gone_at timestamptz;

create or replace function lms_lesson_gone(l lessons) returns boolean
language sql immutable as $$
  select l.state = 'canceled' and l.voided_at is null and l.class_status is distinct from 'Tutor long-term leave'
$$;

create or replace function lessons_leave_gone() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  update leave_items i
  set lesson_gone_at = case when lms_lesson_gone(new) then coalesce(i.lesson_gone_at, now()) end
  where (i.lesson_id = new.id or i.sub_lesson_id = new.id)
    and (i.lesson_gone_at is null) = lms_lesson_gone(new);
  return null;
end $$;

revoke all on function lms_lesson_gone(lessons) from public, anon, authenticated;
revoke all on function lessons_leave_gone() from public, anon, authenticated;

drop trigger if exists lessons_leave_gone on lessons;
create trigger lessons_leave_gone after update of state, class_status, voided_at on lessons
  for each row when (old.state is distinct from new.state or old.class_status is distinct from new.class_status or old.voided_at is distinct from new.voided_at)
  execute function lessons_leave_gone();

-- 이미 밖에서 취소된 수업 채우기 (새 칸만)
update leave_items i set lesson_gone_at = coalesce(l.canceled_at, now())
from lessons l
where l.id = coalesce(i.sub_lesson_id, i.lesson_id) and lms_lesson_gone(l) and i.lesson_gone_at is null;

-- 학생 화면: 2800 그대로 + 휴무 안내에서 밖에서 취소된 수업 뺌
create or replace function student_screen(p_student uuid)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_student uuid := lms_screen_student(p_student);
  st students;
  e enrollments;
  v_period enrollment_periods;
  v_open uuid[];
begin
  select * into st from students where id = v_student;
  select * into e from enrollments where id = lms_student_enrollment(v_student);
  select * into v_period from enrollment_periods p
  where p.enrollment_id = e.id and p.start_date <= (now() at time zone 'Asia/Seoul')::date order by p.idx desc limit 1;
  -- 수업·보강은 지금 수강권 + 아직 열린 다른 수강권(재등록 결제 뒤에도 이전 수강권의 보강이 남을 수 있음)
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
        'substitute', l.original_tutor_id is not null) order by l.starts_at)
      from lessons l join tutors t on t.id = l.tutor_id
      where l.enrollment_id = any(v_open) and l.voided_at is null), '[]'::jsonb),
    -- 보강을 받을 수 있는데 아직 날짜가 없는 것 (취소한 수업 · 시트에서 넘어온 날짜 미정 보강)
    'makeup_rights', coalesce((
      select jsonb_agg(r order by r ->> 'original_at') from (
        select jsonb_build_object('lesson_id', l.id, 'item_id', null, 'original_at', l.starts_at,
                 'tutor_leave', l.class_status = 'Tutor long-term leave') as r
        from lessons l
        where l.enrollment_id = any(v_open) and l.voided_at is null and (lms_grants_makeup(l.class_status) or l.class_status = 'Tutor long-term leave')
          and not exists (select 1 from lessons x where x.makeup_of = l.id and x.state <> 'canceled')
        union all
        select jsonb_build_object('lesson_id', null, 'item_id', m.id, 'original_at', m.original_date::timestamp at time zone 'Asia/Seoul',
                 'tutor_leave', coalesce(m.tutor_leave, false))
        from migrated_items m where m.enrollment_id = any(v_open) and m.kind = 'makeup_open') q), '[]'::jsonb),
    'makeup_requests', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', r.id, 'status', r.status, 'lesson_id', r.source_lesson_id, 'item_id', r.migrated_item_id,
        'requested_at', r.requested_at, 'confirmed_lesson_id', r.confirmed_lesson_id,
        'tutor_leave', (select x.tutor_leave from lms_makeup_source(r.source_lesson_id, r.migrated_item_id) x),
        'candidates', (select coalesce(jsonb_agg(c.starts_at order by c.starts_at), '[]'::jsonb) from makeup_candidates c where c.request_id = r.id and c.proposed_by = 'student'))
        order by r.requested_at desc)
      from makeup_requests r where r.student_id = v_student and r.status in ('requested', 'countered', 'confirmed')
        and r.requested_at > now() - interval '60 days'), '[]'::jsonb),
    -- 휴무 안내: 대체강사가 가능하다고 한 수업(답 기다림)·확정된 대체 수업·보강으로 정한 수업만. 지난 수업은 빼고
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
    -- 변경권: 지금 기간과 쓴 기록 (대표 10/29: 변경권 칸 누르면 언제 썼는지)
    'credit_period', case when v_period.id is null then null else jsonb_build_object('start', v_period.start_date, 'end', v_period.end_date) end,
    'credit_uses', coalesce((
      select jsonb_agg(jsonb_build_object('at', c.created_at, 'reason', c.reason, 'delta', c.delta, 'lesson_at', l.starts_at) order by c.created_at)
      from credit_ledger c left join lessons l on l.id = c.lesson_id where c.period_id = v_period.id), '[]'::jsonb),
    'holidays', coalesce((select jsonb_agg(h.day order by h.day) from holidays h
      where h.day between (now() at time zone 'Asia/Seoul')::date and (now() at time zone 'Asia/Seoul')::date + 200), '[]'::jsonb),
    'points', coalesce((
      select jsonb_agg(jsonb_build_object('id', g.id, 'on', (g.created_at at time zone 'Asia/Seoul')::date, 'kind', g.kind, 'amount', g.amount, 'note', g.note)
        order by g.created_at)
      from reward_ledger g where g.student_id = v_student), '[]'::jsonb));
end $$;
revoke all on function student_screen(uuid) from public, anon;
grant execute on function student_screen(uuid) to authenticated;

-- 강사 화면: 3000 그대로 + 대체 요청에서 밖에서 취소된 수업 뺌
create or replace function tutor_screen(p_tutor uuid, p_from date, p_to date)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_tutor uuid := lms_screen_tutor(p_tutor);
  t tutors;
begin
  if p_from is null or p_to is null or p_to < p_from then raise exception 'Invalid date range.'; end if;
  select * into t from tutors where id = v_tutor;
  return jsonb_build_object(
    'tutor', jsonb_build_object('id', t.id, 'name', t.name, 'timezone', t.timezone, 'meet_url', t.meet_url),
    'lessons', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', l.id, 'starts_at', l.starts_at, 'ends_at', l.ends_at, 'kind', l.kind, 'state', l.state, 'class_status', l.class_status,
        'student', coalesce(s.display_name, s.name_en), 'level', s.level, 'note_url', s.class_note_url,
        'covering', l.original_tutor_id is not null and l.original_tutor_id <> l.tutor_id,
        'makeup_of', o.starts_at,
        'count', lms_lesson_count(l.id),
        'topics', cr.covered_topics, 'remarks', cr.remarks, 'student_late', coalesce(cr.student_late, false), 'recorded_at', cr.first_submitted_at,
        'locked', exists (select 1 from payroll_items p where p.lesson_id = l.id))
        order by l.starts_at)
      from lessons l
      join students s on s.id = l.student_id
      left join lessons o on o.id = l.makeup_of
      left join class_records cr on cr.lesson_id = l.id
      where l.tutor_id = v_tutor and l.voided_at is null
        and (l.kst_date between p_from and p_to
             or (l.state = 'scheduled' and l.starts_at <= now()
                 and l.starts_at >= (select min(u.created_at) from app_users u where u.tutor_id = v_tutor)))), '[]'::jsonb),
    -- 기록할 수업: 시작했는데 결과가 없는 수업 (강사 LMS 계정이 생긴 뒤 시작한 수업만 — 그 전 수업은 시트에 기록됨)
    'to_record', coalesce((
      select jsonb_agg(l.id order by l.starts_at)
      from lessons l
      where l.tutor_id = v_tutor and l.state = 'scheduled' and l.voided_at is null and l.starts_at <= now()
        and l.starts_at >= (select min(u.created_at) from app_users u where u.tutor_id = v_tutor)), '[]'::jsonb),
    'makeups', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', r.id, 'student', coalesce(s.display_name, s.name_en),
        'original_at', src.starts_at, 'original_date', mi.original_date,
        'note', r.tutor_note, 'answered_at', r.tutor_answered_at,
        'slots', (select jsonb_agg(jsonb_build_object(
                    'id', c.id, 'starts_at', c.starts_at, 'ends_at', c.ends_at, 'answer', c.tutor_answer,
                    'busy', lms_makeup_conflict(r.tutor_id, r.student_id, c.starts_at, c.ends_at, true) is not null, 'past', c.starts_at <= now())
                    order by c.starts_at)
                  from makeup_candidates c where c.request_id = r.id and c.proposed_by = 'student'))
        order by r.created_at)
      from makeup_requests r
      join students s on s.id = r.student_id
      left join lessons src on src.id = r.source_lesson_id
      left join migrated_items mi on mi.id = r.migrated_item_id
      where r.tutor_id = v_tutor and r.status in ('requested', 'countered')), '[]'::jsonb),
    -- 대체 수업 요청: 운영진이 이 강사를 대체강사로 골라 답을 기다리는 수업 (2600). 휴무 강사 이름은 안 보임
    'covers', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', i.id, 'student', coalesce(s.display_name, s.name_en), 'starts_at', i.starts_at, 'ends_at', i.ends_at,
        'busy', lms_sub_conflict(v_tutor, i.starts_at, i.ends_at, i.lesson_id) is not null)
        order by i.starts_at)
      from leave_items i join students s on s.id = i.student_id
      where i.sub_tutor_id = v_tutor and i.choice = 'substitute' and i.sub_stage = 'asked' and i.starts_at > now() and i.lesson_gone_at is null), '[]'::jsonb));
end $$;
revoke all on function tutor_screen(uuid, date, date) from public, anon;
grant execute on function tutor_screen(uuid, date, date) to authenticated;
