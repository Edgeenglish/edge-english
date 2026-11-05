-- =====================================================================
-- 4530 Work 2차 재검증(2026-11-05, 67fbba0) R-22·R-25 DB 쪽 수정 — 시험용 DB 먼저, 운영 DB 는 대표 승인 뒤
--  1. R-25 예약 불가 사유 구분: lms_conflict_code(사유 글 → 코드 hours·closed·leave·busy·b2b·other) · lms_conflict_message(운영진 문구)
--     admin_makeup_confirm 은 '그 시간은 ○○와 겹칩니다' 대신 사유별 문장, tutor_screen 보강 후보·대체 요청에 why 코드(강사 화면 문구 구분)
--  2. R-22 admin_matching_current: 예정(앞으로) 수업과 지난 미기록 수업을 나눠 돌려줌(upcoming·past_unrecorded·next_at·first_at)
-- 지우는 문장 없음. 기존 표·데이터 그대로. 다시 실행해도 같은 결과
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. R-25 사유 코드·문구 (lms_makeup_conflict / lms_sub_conflict 가 돌려주는 글 기준)
-- ---------------------------------------------------------------------
create or replace function lms_conflict_code(p_text text) returns text
language sql immutable as $$
  select case
    when p_text is null then null
    when p_text like '%06:00~22:30%' then 'hours'
    when p_text like '%열어 둔 시간%' then 'closed'
    when p_text like '%휴무%' then 'leave'
    when p_text like '%이어 붙이는%' then 'b2b'
    when p_text like '%다른 수업%' then 'busy'
    else 'other' end
$$;
revoke all on function lms_conflict_code(text) from public, anon, authenticated;

create or replace function lms_conflict_message(p_text text) returns text
language sql immutable as $$
  select case lms_conflict_code(p_text)
    when 'hours' then '강사 현지 06:00~22:30 에 시작하는 시간만 예약할 수 있습니다.'
    when 'closed' then '강사가 열어 둔 시간이 아닙니다. 강사가 Schedule·Availability 에서 연 시간만 예약할 수 있습니다.'
    when 'leave' then '그 시간은 강사 휴무입니다.'
    when 'busy' then '그 시간은 강사의 다른 수업과 겹칩니다 (앞뒤 휴식 10분 포함).'
    when 'b2b' then p_text || ' 규칙에 걸립니다.'
    else '그 시간은 예약할 수 없습니다 (' || coalesce(p_text, '') || ').' end
$$;
revoke all on function lms_conflict_message(text) from public, anon, authenticated;

-- admin_makeup_confirm: 4520 그대로 + 예약 불가 사유별 문구 (R-25)
create or replace function admin_makeup_confirm(p_makeup_request uuid, p_starts_at timestamptz)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  r makeup_requests;
  s record;
  c record;
  e enrollments;
  v_end timestamptz;
  v_lesson uuid;
  v_conf text;
  v_enr uuid;
begin
  if not is_admin() then raise exception '운영자(추가 인증 완료)만 처리할 수 있습니다.' using errcode = '42501'; end if;
  select * into r from makeup_requests where id = p_makeup_request for update;
  if not found then raise exception '보강 신청이 없습니다.'; end if;
  if r.status = 'confirmed' then return jsonb_build_object('makeup_request_id', r.id, 'lesson_id', r.confirmed_lesson_id, 'repeated', true); end if;
  if r.status not in ('requested', 'countered') then raise exception '이미 닫힌 보강 신청입니다.'; end if;
  if p_starts_at <= now() then raise exception '지난 시간은 보강으로 넣을 수 없습니다.'; end if;
  -- 강사가 불가라고 답한 시간 (QA-01 D, 4500)
  if exists (select 1 from makeup_candidates x where x.request_id = r.id and x.starts_at = p_starts_at and x.proposed_by = 'student' and x.tutor_answer = 'no') then
    raise exception '강사가 불가라고 답한 시간입니다. 다른 시간을 고르거나 학생에게 다시 날짜를 받아 주세요.' using hint = 'tutor_no';
  end if;

  if r.compensation_id is not null then
    perform 1 from compensations where id = r.compensation_id for update;   -- 같은 보상권 두 번 쓰기 막기
    select * into c from lms_comp_source(r.compensation_id);
    if p_starts_at >= ((c.use_until + 1)::timestamp at time zone 'Asia/Seoul') then
      raise exception '보상수업 사용 기한(%) 뒤의 시간입니다.', c.use_until using hint = 'after_end';
    end if;
    select * into e from enrollments where id = c.enrollment_id;
    v_end := p_starts_at + make_interval(mins => e.duration_min);
    v_conf := lms_makeup_conflict(r.tutor_id, c.student_id, p_starts_at, v_end,
                exists (select 1 from makeup_candidates x where x.request_id = r.id and x.starts_at = p_starts_at and x.proposed_by = 'student'));
    if v_conf is not null then raise exception '%', lms_conflict_message(v_conf) using hint = 'schedule_conflict', detail = lms_conflict_code(v_conf); end if;
    v_enr := lms_comp_lesson_enrollment(r.compensation_id, (p_starts_at at time zone 'Asia/Seoul')::date);
    perform set_config('app.actor_id', me::text, true);
    perform set_config('app.actor_via', 'admin_makeup_confirm', true);
    if not exists (select 1 from makeup_candidates where request_id = r.id and starts_at = p_starts_at) then
      insert into makeup_candidates (request_id, starts_at, ends_at, proposed_by) values (r.id, p_starts_at, v_end, 'tutor');
    end if;
    begin
      insert into lessons (enrollment_id, student_id, tutor_id, kind, starts_at, ends_at, compensation_id, created_by)
      values (v_enr, c.student_id, r.tutor_id, 'compensation', p_starts_at, v_end, r.compensation_id, me)
      returning id into v_lesson;
    exception when exclusion_violation then
      raise exception '그 시간에 학생 또는 강사의 다른 수업이 있습니다.' using hint = 'schedule_conflict';
    end;
    update compensations set status = 'used', used_lesson_id = v_lesson where id = r.compensation_id;
  else
    select * into s from lms_makeup_source(r.source_lesson_id, r.migrated_item_id);
    select * into e from enrollments where id = s.enrollment_id;
    if not s.tutor_leave and p_starts_at >= ((e.final_end_date + 1)::timestamp at time zone 'Asia/Seoul') then
      raise exception '수강 종료일(%) 뒤의 시간입니다.', e.final_end_date using hint = 'after_end';
    end if;
    v_end := p_starts_at + make_interval(mins => e.duration_min);
    v_conf := lms_makeup_conflict(r.tutor_id, s.student_id, p_starts_at, v_end,
                exists (select 1 from makeup_candidates x where x.request_id = r.id and x.starts_at = p_starts_at and x.proposed_by = 'student'));
    if v_conf is not null then raise exception '%', lms_conflict_message(v_conf) using hint = 'schedule_conflict', detail = lms_conflict_code(v_conf); end if;

    perform set_config('app.actor_id', me::text, true);
    perform set_config('app.actor_via', 'admin_makeup_confirm', true);
    if not exists (select 1 from makeup_candidates where request_id = r.id and starts_at = p_starts_at) then
      insert into makeup_candidates (request_id, starts_at, ends_at, proposed_by) values (r.id, p_starts_at, v_end, 'tutor');
    end if;
    begin
      insert into lessons (enrollment_id, student_id, tutor_id, kind, starts_at, ends_at, makeup_of, created_by)
      values (s.enrollment_id, s.student_id, r.tutor_id,
              case when r.source_lesson_id is null then 'migrated_makeup' else 'makeup' end,
              p_starts_at, v_end, r.source_lesson_id, me)
      returning id into v_lesson;
    exception when exclusion_violation then
      raise exception '그 시간에 학생 또는 강사의 다른 수업이 있습니다.' using hint = 'schedule_conflict';
    end;
    if r.migrated_item_id is not null then
      update migrated_items set kind = 'makeup_booked', lesson_id = v_lesson where id = r.migrated_item_id;
      -- R-18 (4520): 이관권이 수업에 연결된 뒤 휴무 자동 연장 재계산
      perform lms_leave_sync_extension(s.enrollment_id);
    end if;
  end if;
  update makeup_requests set status = 'confirmed', confirmed_lesson_id = v_lesson, decided_at = now(), decided_by = me where id = r.id;
  update lesson_notices set status = 'not_needed' where makeup_request_id = r.id and event = 'makeup_ask' and status = 'pending';
  insert into lesson_notices (makeup_request_id, event, recipient_kind, recipient_id)
  values (r.id, 'makeup_confirmed', 'student', r.student_id), (r.id, 'makeup_confirmed', 'tutor', r.tutor_id);
  return jsonb_build_object('makeup_request_id', r.id, 'lesson_id', v_lesson, 'repeated', false);
end $$;
revoke all on function admin_makeup_confirm(uuid, timestamptz) from public, anon;
grant execute on function admin_makeup_confirm(uuid, timestamptz) to authenticated;

-- tutor_screen: 4400 그대로 + 보강 후보 slots.why · 대체 요청 covers.why (R-25: 강사 화면에서 왜 못 고르는지 구분)
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
        'student', lms_tutor_student_label(s.name_en, s.display_name), 'student_id', s.id, 'level', s.level, 'note_url', s.class_note_url,
        'covering', l.original_tutor_id is not null and l.original_tutor_id <> l.tutor_id,
        'makeup_of', o.starts_at,
        'compensation_of', (select x.starts_at from compensations cc join lessons x on x.id = cc.source_lesson_id where cc.id = l.compensation_id),
        'count', lms_lesson_count(l.id),
        'topics', cr.covered_topics, 'remarks', cr.remarks, 'student_late', coalesce(cr.student_late, false), 'student_late_min', cr.student_late_min, 'tutor_late', coalesce(cr.tutor_late, false), 'tutor_late_min', cr.tutor_late_min, 'recorded_at', cr.first_submitted_at,
        'locked', exists (select 1 from payroll_items p where p.lesson_id = l.id),
        'compensation', (select c.status from compensations c where c.source_lesson_id = l.id),
        'leave_open', l.state = 'scheduled' and exists (select 1 from leave_items li where li.lesson_id = l.id and li.lesson_gone_at is null
                              and (li.choice = 'undecided' or (li.choice = 'substitute' and li.sub_stage <> 'confirmed'))))
        order by l.starts_at)
      from lessons l
      join students s on s.id = l.student_id
      left join lessons o on o.id = l.makeup_of
      left join class_records cr on cr.lesson_id = l.id
      where l.tutor_id = v_tutor and l.voided_at is null
        and (l.kst_date between p_from and p_to
             or (l.state = 'scheduled' and l.starts_at <= now()
                 and l.starts_at >= (select min(u.created_at) from app_users u where u.tutor_id = v_tutor)))), '[]'::jsonb),
    'to_record', coalesce((
      select jsonb_agg(l.id order by l.starts_at)
      from lessons l
      where l.tutor_id = v_tutor and l.state = 'scheduled' and l.voided_at is null and l.starts_at <= now()
        and l.starts_at >= (select min(u.created_at) from app_users u where u.tutor_id = v_tutor)
        and not exists (select 1 from leave_items li where li.lesson_id = l.id and li.lesson_gone_at is null
                         and (li.choice = 'undecided' or (li.choice = 'substitute' and li.sub_stage <> 'confirmed')))), '[]'::jsonb),
    'makeups', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', r.id, 'student', lms_tutor_student_label(s.name_en, s.display_name), 'student_id', s.id,
        'original_at', src.starts_at, 'original_date', mi.original_date,
        'compensation', r.compensation_id is not null,
        'note', r.tutor_note, 'answered_at', r.tutor_answered_at,
        'slots', (select jsonb_agg(jsonb_build_object(
                    'id', c.id, 'starts_at', c.starts_at, 'ends_at', c.ends_at, 'answer', c.tutor_answer,
                    'busy', lms_makeup_conflict(r.tutor_id, r.student_id, c.starts_at, c.ends_at, true) is not null,
                    'why', lms_conflict_code(lms_makeup_conflict(r.tutor_id, r.student_id, c.starts_at, c.ends_at, true)), 'past', c.starts_at <= now())
                    order by c.starts_at)
                  from makeup_candidates c where c.request_id = r.id and c.proposed_by = 'student'))
        order by r.created_at)
      from makeup_requests r
      join students s on s.id = r.student_id
      left join lessons src on src.id = r.source_lesson_id
      left join migrated_items mi on mi.id = r.migrated_item_id
      where r.tutor_id = v_tutor and r.status in ('requested', 'countered')), '[]'::jsonb),
    'covers', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', i.id, 'student', lms_tutor_student_label(s.name_en, s.display_name), 'student_id', s.id, 'starts_at', i.starts_at, 'ends_at', i.ends_at,
        'busy', lms_sub_conflict(v_tutor, i.starts_at, i.ends_at, i.lesson_id) is not null,
        'why', lms_conflict_code(lms_sub_conflict(v_tutor, i.starts_at, i.ends_at, i.lesson_id)))
        order by i.starts_at)
      from leave_items i join students s on s.id = i.student_id
      where i.sub_tutor_id = v_tutor and i.choice = 'substitute' and i.sub_stage = 'asked' and i.starts_at > now() and i.lesson_gone_at is null), '[]'::jsonb));
end $$;
revoke all on function tutor_screen(uuid, date, date) from public, anon;
grant execute on function tutor_screen(uuid, date, date) to authenticated;


-- ---------------------------------------------------------------------
-- 2. R-22 기존 배정 읽기: 예정(앞으로) 수업과 지난 미기록 수업을 나눔. scheduled 는 예전 호환(전체 scheduled 수)
-- ---------------------------------------------------------------------
create or replace function admin_matching_current(p_enrollment uuid)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  e enrollments;
  a admin_tasks;
begin
  if not is_admin() then raise exception '운영자(추가 인증 완료)만 볼 수 있습니다.' using errcode = '42501'; end if;
  select * into e from enrollments where id = p_enrollment;
  if not found then raise exception '수강등록을 찾지 못했어요.'; end if;
  select * into a from admin_tasks where kind = 'new_student_matching' and enrollment_id = e.id;
  return jsonb_build_object(
    'enrollment_id', e.id,
    'task', case when a.id is null then null else jsonb_build_object('id', a.id, 'status', a.status, 'tutor_assigned_at', a.tutor_assigned_at,
                                                                   'student_notified_at', a.student_notified_at, 'done_at', a.done_at) end,
    'plan', (select jsonb_build_object('id', p.id, 'state', p.state) from schedule_plans p where p.enrollment_id = e.id and p.state in ('proposed', 'confirmed') order by p.created_at desc limit 1),
    'tutor', (select jsonb_build_object('id', t.id, 'name', t.name, 'timezone', t.timezone) from tutors t
              where t.id = coalesce(a.tutor_id, (select l.tutor_id from lessons l where l.enrollment_id = e.id and l.state = 'scheduled' order by l.starts_at limit 1))),
    'slots', coalesce((select jsonb_agg(jsonb_build_object('weekday', rs.weekday, 'time', to_char(rs.start_time_kst, 'HH24:MI')) order by rs.weekday, rs.start_time_kst)
                       from lms_current_slots(e.student_id, greatest(e.start_date, (now() at time zone 'Asia/Seoul')::date)) rs), '[]'::jsonb),
    'scheduled', (select count(*) from lessons l where l.enrollment_id = e.id and l.state = 'scheduled' and l.voided_at is null),
    -- R-22 (4530): 앞으로 수업 / 지난 미기록 수업(시작했지만 Class Record 전) 따로
    'upcoming', (select count(*) from lessons l where l.enrollment_id = e.id and l.state = 'scheduled' and l.voided_at is null and l.starts_at > now()),
    'past_unrecorded', (select count(*) from lessons l where l.enrollment_id = e.id and l.state = 'scheduled' and l.voided_at is null and l.starts_at <= now()),
    'done_count', (select count(*) from lessons l where l.enrollment_id = e.id and l.state = 'done' and l.voided_at is null),
    'next_at', (select min(l.starts_at) from lessons l where l.enrollment_id = e.id and l.state = 'scheduled' and l.voided_at is null and l.starts_at > now()),
    'first_at', (select min(l.starts_at) from lessons l where l.enrollment_id = e.id and l.state <> 'canceled' and l.voided_at is null),
    'start_date', e.start_date, 'final_end_date', e.final_end_date, 'duration_min', e.duration_min, 'weekly_count', e.weekly_count,
    'lessons_total', e.lessons_purchased + e.lessons_carried_in);
end $$;
revoke all on function admin_matching_current(uuid) from public, anon;
grant execute on function admin_matching_current(uuid) to authenticated;
