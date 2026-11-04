-- =====================================================================
-- 4401. 강사 본인도 Tutor no-show 기록 (2026-11-04 대표: 강사가 직접 고를 수 있어야 함, 4000 '운영자만' 변경)
--  - 결과·보상수업 1회·학생 보강 1회·강사 급여 없음은 4000 그대로 (기록 방식만 열림)
--  - 운영자가 기록한 강사 노쇼는 여전히 강사가 못 고침(submitted_by 가 본인일 때만 고칠 수 있음)
--  - 다시 실행해도 같은 결과
-- =====================================================================

create or replace function tutor_record_class(p_lesson uuid, p_result text, p_topics text, p_remarks text,
                                              p_student_late boolean, p_student_late_min int, p_tutor_late boolean, p_tutor_late_min int)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  l lessons;
  v_status class_status;
  v_topics text := nullif(trim(coalesce(p_topics, '')), '');
  v_remarks text := nullif(trim(coalesce(p_remarks, '')), '');
  v_old class_records;
  v_result text := case when p_result = 'late' then 'held' else p_result end;   -- 예전 화면 호환
  v_held boolean := v_result = 'held';
  -- 지각은 수업이 진행됐을(Held) 때만 뜻이 있음
  v_s_late boolean := v_held and coalesce(p_student_late, false);
  v_t_late boolean := v_held and (coalesce(p_tutor_late, false) or p_result = 'late');
  v_s_min int := case when v_s_late then p_student_late_min end;
  v_t_min int := case when v_t_late then p_tutor_late_min end;
begin
  select * into l from lessons where id = p_lesson for update;
  if not found then raise exception 'Class not found.'; end if;
  if not (is_admin() or (my_tutor_id() is not null and l.tutor_id = my_tutor_id())) then
    raise exception 'This is not your class.' using errcode = '42501';
  end if;
  -- 운영자가 기록한 강사 노쇼는 강사가 못 고침. 강사 본인이 기록한 것은 본인이 고칠 수 있음 (4401)
  if l.class_status = 'Tutor no-show' and not is_admin()
     and (select cr0.submitted_by from class_records cr0 where cr0.lesson_id = l.id) is distinct from me then
    raise exception 'Edge English recorded this class. Please contact the Edge English team.' using hint = 'locked';
  end if;
  if l.voided_at is not null or l.state = 'canceled' then
    raise exception 'This class was canceled (%). No record needed.', coalesce(l.class_status::text, 'removed') using hint = 'canceled';
  end if;
  if l.starts_at > now() then raise exception 'You can record this class after it starts.' using hint = 'not_started'; end if;
  if exists (select 1 from payroll_items where lesson_id = l.id) then
    raise exception 'This class is already in payroll. Please contact Edge English to change it.' using hint = 'locked';
  end if;
  if (v_s_min is not null and v_s_min <= 0) or (v_t_min is not null and v_t_min <= 0) then
    raise exception 'Late minutes must be more than 0.' using hint = 'late';
  end if;
  if v_held then
    if v_topics is null then raise exception 'Please enter the covered topics.' using hint = 'topics'; end if;
    if v_t_late and v_remarks is null then raise exception 'Please write why you were late in Remarks.' using hint = 'remarks'; end if;
    v_status := case when v_t_late then 'Tutor Late - Student Present'
                     when l.kind in ('makeup', 'migrated_makeup', 'compensation') then 'Make-up completed'
                     when l.original_tutor_id is not null and l.original_tutor_id <> l.tutor_id then 'Covered by another tutor'
                     else 'Normal' end;
  elsif v_result = 'student_no_show' then
    v_status := 'Student no-show';
  elsif v_result = 'tutor_no_show' then
    v_status := 'Tutor no-show';
  else
    raise exception 'Please choose how the class went.';
  end if;

  select * into v_old from class_records where lesson_id = l.id;
  if l.state = 'done' and l.class_status = v_status and found
     and v_old.covered_topics is not distinct from v_topics and v_old.remarks is not distinct from v_remarks
     and v_old.student_late = v_s_late and v_old.student_late_min is not distinct from v_s_min
     and v_old.tutor_late = v_t_late and v_old.tutor_late_min is not distinct from v_t_min then
    return jsonb_build_object('lesson_id', l.id, 'class_status', v_status, 'repeated', true);
  end if;

  perform set_config('app.actor_id', me::text, true);
  perform set_config('app.actor_via', case when is_admin() then 'admin_record_class' else 'tutor_record_class' end, true);
  update lessons set state = 'done', class_status = v_status where id = l.id and (state, class_status) is distinct from ('done', v_status);
  if v_status = 'Tutor no-show' then
    insert into compensations (student_id, enrollment_id, source_lesson_id, reason, confirmed_by)
    values (l.student_id, l.enrollment_id, l.id, 'tutor_no_show', me)
    on conflict (source_lesson_id) do update set status = 'available' where compensations.status = 'voided';
  else
    update compensations set status = 'voided' where source_lesson_id = l.id and status = 'available';
  end if;
  insert into class_records (lesson_id, covered_topics, remarks, student_late, student_late_min, tutor_late, tutor_late_min, submitted_by)
  values (l.id, v_topics, v_remarks, v_s_late, v_s_min, v_t_late, v_t_min, me)
  on conflict (lesson_id) do update set covered_topics = excluded.covered_topics, remarks = excluded.remarks,
    student_late = excluded.student_late, student_late_min = excluded.student_late_min,
    tutor_late = excluded.tutor_late, tutor_late_min = excluded.tutor_late_min, submitted_by = excluded.submitted_by;
  return jsonb_build_object('lesson_id', l.id, 'class_status', v_status, 'repeated', false);
end $$;
revoke all on function tutor_record_class(uuid, text, text, text, boolean, int, boolean, int) from public, anon;
grant execute on function tutor_record_class(uuid, text, text, text, boolean, int, boolean, int) to authenticated;
