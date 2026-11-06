-- 학생 지각 표시 (2026-10-29 대표 다안): 정상 수업 + 'Student was late' 체크.
-- Class Status를 늘리지 않아 수업 횟수·페이·보강 규칙은 그대로. 강사 일정 표에 '· Student late'로 보임

alter table class_records add column student_late boolean not null default false;

drop function tutor_record_class(uuid, text, text, text);
create or replace function tutor_record_class(p_lesson uuid, p_result text, p_topics text, p_remarks text, p_student_late boolean default false)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  l lessons;
  v_status class_status;
  v_topics text := nullif(trim(coalesce(p_topics, '')), '');
  v_remarks text := nullif(trim(coalesce(p_remarks, '')), '');
  v_old class_records;
  v_late boolean := p_result = 'held' and coalesce(p_student_late, false);   -- 학생 지각은 정상 진행(Held)일 때만
begin
  select * into l from lessons where id = p_lesson for update;
  if not found then raise exception 'Class not found.'; end if;
  if not (is_admin() or (my_tutor_id() is not null and l.tutor_id = my_tutor_id())) then
    raise exception 'This is not your class.' using errcode = '42501';
  end if;
  if l.voided_at is not null or l.state = 'canceled' then
    raise exception 'This class was canceled (%). No record needed.', coalesce(l.class_status::text, 'removed') using hint = 'canceled';
  end if;
  if l.starts_at > now() then raise exception 'You can record this class after it starts.' using hint = 'not_started'; end if;
  if exists (select 1 from payroll_items where lesson_id = l.id) then
    raise exception 'This class is already in payroll. Please contact Edge English to change it.' using hint = 'locked';
  end if;
  if p_result = 'held' then
    if v_topics is null then raise exception 'Please enter the covered topics.' using hint = 'topics'; end if;
    v_status := case when l.kind in ('makeup', 'migrated_makeup', 'compensation') then 'Make-up completed'
                     when l.original_tutor_id is not null and l.original_tutor_id <> l.tutor_id then 'Covered by another tutor'
                     else 'Normal' end;
  elsif p_result = 'late' then
    if v_topics is null then raise exception 'Please enter the covered topics.' using hint = 'topics'; end if;
    if v_remarks is null then raise exception 'Please write the reason for being late in Remarks.' using hint = 'remarks'; end if;
    v_status := 'Tutor Late - Student Present';
  elsif p_result = 'student_no_show' then
    v_status := 'Student no-show';
  else
    raise exception 'Please choose how the class went.';
  end if;

  select * into v_old from class_records where lesson_id = l.id;
  if l.state = 'done' and l.class_status = v_status and found
     and v_old.covered_topics is not distinct from v_topics and v_old.remarks is not distinct from v_remarks
     and v_old.student_late = v_late then
    return jsonb_build_object('lesson_id', l.id, 'class_status', v_status, 'repeated', true);
  end if;

  perform set_config('app.actor_id', me::text, true);
  perform set_config('app.actor_via', case when is_admin() then 'admin_record_class' else 'tutor_record_class' end, true);
  update lessons set state = 'done', class_status = v_status where id = l.id and (state, class_status) is distinct from ('done', v_status);
  insert into class_records (lesson_id, covered_topics, remarks, student_late, submitted_by)
  values (l.id, v_topics, v_remarks, v_late, me)
  on conflict (lesson_id) do update set covered_topics = excluded.covered_topics, remarks = excluded.remarks,
    student_late = excluded.student_late, submitted_by = excluded.submitted_by;
  return jsonb_build_object('lesson_id', l.id, 'class_status', v_status, 'repeated', false);
end $$;
revoke all on function tutor_record_class(uuid, text, text, text, boolean) from public, anon;
grant execute on function tutor_record_class(uuid, text, text, text, boolean) to authenticated;

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
      where i.sub_tutor_id = v_tutor and i.choice = 'substitute' and i.sub_stage = 'asked' and i.starts_at > now()), '[]'::jsonb));
end $$;
revoke all on function tutor_screen(uuid, date, date) from public, anon;
grant execute on function tutor_screen(uuid, date, date) to authenticated;
