-- =====================================================================
-- 4400. Class Record 출결·지각 구조 (2026-11-04 대표 요청 7)
--  - 수업 결과(하나): Held · Student no-show · Tutor no-show(운영자만, 4000) + 지각(별도): Student late · Tutor late (분 단위)
--  - class_records: student_late_min · tutor_late · tutor_late_min 추가. 기존 student_late(boolean)는 그대로 두고 함께 맞춤
--  - 결과 이름은 전과 같이 DB가 정함: Held + 강사 지각 = 'Tutor Late - Student Present'(14개 상태·인센티브 'late' 그대로, POL-ST-01)
--    → 예전 'I was late' 기록은 자동으로 Held + Tutor late 로 읽힘 (분은 비어 있음). 지각만으로 노쇼·보상은 생기지 않음
--  - tutor_record_class 7개 인자 새 함수 + 예전 5개 인자 함수는 새 함수로 넘김 (지우는 문장 없이, PostgREST 겹침 없음: 새 인자에 기본값 없음)
--  - 다시 실행해도 같은 결과
-- =====================================================================

alter table class_records add column if not exists student_late_min int check (student_late_min is null or student_late_min > 0);
alter table class_records add column if not exists tutor_late boolean not null default false;
alter table class_records add column if not exists tutor_late_min int check (tutor_late_min is null or tutor_late_min > 0);

-- 예전 기록 호환: 'Tutor Late - Student Present' = 강사 지각 (분은 모름 → 비움)
update class_records cr set tutor_late = true
from lessons l where l.id = cr.lesson_id and l.class_status = 'Tutor Late - Student Present' and not cr.tutor_late;

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
  if l.class_status = 'Tutor no-show' and not is_admin() then
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
    if not is_admin() then raise exception 'Only the Edge English team can record a tutor no-show.' using errcode = '42501'; end if;
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

-- 예전 화면(5개 인자) 호환: 새 함수로 넘김
create or replace function tutor_record_class(p_lesson uuid, p_result text, p_topics text, p_remarks text, p_student_late boolean default false)
returns jsonb
language sql security definer set search_path = public as $$
  select tutor_record_class(p_lesson, p_result, p_topics, p_remarks, p_student_late, null::int, p_result = 'late', null::int);
$$;

-- 강사 화면: 지각 칸 추가 (4300 그대로 + student_late_min · tutor_late · tutor_late_min)
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
                    'busy', lms_makeup_conflict(r.tutor_id, r.student_id, c.starts_at, c.ends_at, true) is not null, 'past', c.starts_at <= now())
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
        'busy', lms_sub_conflict(v_tutor, i.starts_at, i.ends_at, i.lesson_id) is not null)
        order by i.starts_at)
      from leave_items i join students s on s.id = i.student_id
      where i.sub_tutor_id = v_tutor and i.choice = 'substitute' and i.sub_stage = 'asked' and i.starts_at > now() and i.lesson_gone_at is null), '[]'::jsonb));
end $$;
revoke all on function tutor_screen(uuid, date, date) from public, anon;
grant execute on function tutor_screen(uuid, date, date) to authenticated;
