-- =====================================================================
-- 강사 Class Record ①②③ (정책 원본 H26(136)(138), 시안 11/11)
--  ① 강사 Class Record 'Student canceled': 강사가 학생이 알린 시각을 넣고 기존 학생 취소 규칙(lms_change_core)으로 자동 판정
--  ② 수업 종류 = 강사 시트 Class Type: class_type(lessons) 하나로 판정 → 화면이 이름만 붙임
--     regular · makeup · compensation · cover · carry_in(지난 수강기간에서 이월) · carry_out(다음 수강기간으로 이월, 취소된 원래 수업 줄)
--  ③ 대체 수업 양쪽: 맡은 강사 Held = Normal, 원래 강사 화면에 회색 줄(covered_by_other) — 기록할 수업·급여에는 안 들어감
-- 되돌리기: drop function public.tutor_student_cancel(uuid, uuid, timestamptz, boolean); drop function public.class_type(lessons);
--          drop function public.lms_class_type(lessons, boolean); tutor_screen·tutor_record_class·student_screen·lms_student_profile_json·
--          admin_student_detail 는 20261111120000 이전 정의로 (이 파일 앞 migration 들)
-- =====================================================================

-- ② 수업 종류 판정 (p_cover = false 면 대체 여부를 빼고 원래 종류 — 원래 강사 회색 줄용)
create or replace function public.lms_class_type(l lessons, p_cover boolean) returns text
language sql stable security definer set search_path = public as $$
  select case
    when p_cover and l.original_tutor_id is not null and l.original_tutor_id <> l.tutor_id then 'cover'
    when l.kind = 'carryover' then 'carry_in'
    when l.kind = 'makeup' and exists (select 1 from lessons o where o.id = l.makeup_of and o.enrollment_id <> l.enrollment_id) then 'carry_in'
    when l.kind = 'migrated_makeup' and exists (select 1 from migrated_items mi join enrollments e on e.id = l.enrollment_id
                                                where mi.lesson_id = l.id and mi.original_date < e.start_date) then 'carry_in'
    when l.kind = 'compensation' then 'compensation'
    when l.kind in ('makeup', 'migrated_makeup') then 'makeup'
    when exists (select 1 from lessons y where y.makeup_of = l.id and y.enrollment_id <> l.enrollment_id and y.voided_at is null) then 'carry_out'
    else 'regular' end
$$;
-- PostgREST 계산 칸: select=...,class_type
create or replace function public.class_type(l lessons) returns text
language sql stable security definer set search_path = public as $$ select lms_class_type(l, true) $$;
revoke all on function public.lms_class_type(lessons, boolean) from public, anon;
revoke all on function public.class_type(lessons) from public, anon;
grant execute on function public.lms_class_type(lessons, boolean) to authenticated;
grant execute on function public.class_type(lessons) to authenticated;

-- ③ 강사 화면: 수업 종류 + 원래 강사였던 대체 수업 회색 줄
create or replace function public.tutor_screen(p_tutor uuid, p_from date, p_to date)
 returns jsonb
 language plpgsql
 stable security definer
 set search_path to 'public'
as $function$
declare
  v_tutor uuid := lms_screen_tutor(p_tutor);
  t tutors;
begin
  if p_from is null or p_to is null or p_to < p_from then raise exception 'Invalid date range.'; end if;
  select * into t from tutors where id = v_tutor;
  return jsonb_build_object(
    'tutor', jsonb_build_object('id', t.id, 'name', t.name, 'timezone', t.timezone, 'meet_url', t.meet_url),
    'lessons', coalesce((
      select jsonb_agg(case when l.tutor_id = v_tutor then jsonb_build_object(
        'id', l.id, 'starts_at', l.starts_at, 'ends_at', l.ends_at, 'kind', l.kind, 'type', lms_class_type(l, true), 'state', l.state, 'class_status', l.class_status,
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
      else jsonb_build_object(
        -- 원래 강사 화면: 다른 강사가 맡은 수업 (맡은 강사 이름·기록 내용은 안 보냄)
        'id', l.id, 'starts_at', l.starts_at, 'ends_at', l.ends_at, 'kind', l.kind, 'type', lms_class_type(l, false), 'state', l.state, 'class_status', null,
        'student', lms_tutor_student_label(s.name_en, s.display_name), 'student_id', s.id, 'level', s.level, 'note_url', null,
        'covering', false, 'covered_by_other', true, 'makeup_of', o.starts_at, 'count', lms_lesson_count(l.id),
        'student_late', false, 'tutor_late', false, 'locked', false, 'leave_open', false)
      end order by l.starts_at)
      from lessons l
      join students s on s.id = l.student_id
      left join lessons o on o.id = l.makeup_of
      left join class_records cr on cr.lesson_id = l.id
      where l.voided_at is null
        and ((l.tutor_id = v_tutor
              and (l.kst_date between p_from and p_to
                   or (l.state = 'scheduled' and l.starts_at <= now()
                       and l.starts_at >= (select min(u.created_at) from app_users u where u.tutor_id = v_tutor))))
          or (l.original_tutor_id = v_tutor and l.tutor_id <> v_tutor and l.kst_date between p_from and p_to))), '[]'::jsonb),
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
end $function$;

-- ③ 대체강사 Held = Normal (시트 규칙 Cover class + Normal). 이미 저장된 기록은 그대로
create or replace function public.tutor_record_class(p_lesson uuid, p_result text, p_topics text, p_remarks text, p_student_late boolean, p_student_late_min integer, p_tutor_late boolean, p_tutor_late_min integer)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare
  me uuid := auth.uid();
  l lessons;
  v_status class_status;
  v_topics text := nullif(trim(coalesce(p_topics, '')), '');
  v_remarks text := nullif(trim(coalesce(p_remarks, '')), '');
  v_old class_records;
  v_result text := case when p_result = 'late' then 'held' else p_result end;
  v_held boolean := v_result = 'held';
  v_s_late boolean := v_held and coalesce(p_student_late, false);
  v_t_late boolean := v_held and (coalesce(p_tutor_late, false) or p_result = 'late');
  v_s_min int := case when v_s_late then p_student_late_min end;
  v_t_min int := case when v_t_late then p_tutor_late_min end;
  v_linked text[];
begin
  select * into l from lessons where id = p_lesson for update;
  if not found then raise exception 'Class not found.'; end if;
  if not (is_admin() or (my_tutor_id() is not null and l.tutor_id = my_tutor_id())) then
    raise exception 'This is not your class.' using errcode = '42501';
  end if;
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
                     when l.original_tutor_id is not null and l.original_tutor_id <> l.tutor_id then 'Normal'
                     when l.kind in ('makeup', 'migrated_makeup', 'compensation') then 'Make-up completed'
                     else 'Normal' end;
  elsif v_result = 'student_no_show' then
    v_status := 'Student no-show';
  elsif v_result = 'tutor_no_show' then
    v_status := 'Tutor no-show';
  else
    raise exception 'Please choose how the class went.';
  end if;

  if l.class_status = 'Tutor no-show' and v_status <> 'Tutor no-show' then
    select array_remove(array[
      (select format('compensation class %s', to_char(x.starts_at at time zone 'Asia/Seoul', 'Mon DD HH24:MI "KST"'))
         from compensations c join lessons x on x.id = c.used_lesson_id where c.source_lesson_id = l.id and c.status = 'used' and x.voided_at is null and x.state <> 'canceled' limit 1),
      (select format('make-up class %s', to_char(x.starts_at at time zone 'Asia/Seoul', 'Mon DD HH24:MI "KST"'))
         from lessons x where x.makeup_of = l.id and x.voided_at is null and x.state <> 'canceled' order by x.starts_at limit 1)
    ], null) into v_linked;
    if cardinality(v_linked) > 0 then
      raise exception 'This no-show already has % booked. Edge English must remove it first (Lesson change > Make-up), then the result can be changed.',
        array_to_string(v_linked, ', ') using hint = 'linked';
    end if;
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
    if not lms_grants_makeup(v_status) then
      update makeup_requests set status = 'withdrawn', decided_at = now(), decided_by = me
      where source_lesson_id = l.id and compensation_id is null and status in ('requested', 'countered');
      update lesson_notices set status = 'not_needed'
      where status = 'pending' and makeup_request_id in (select id from makeup_requests where source_lesson_id = l.id and compensation_id is null and status = 'withdrawn');
    end if;
  end if;
  insert into class_records (lesson_id, covered_topics, remarks, student_late, student_late_min, tutor_late, tutor_late_min, submitted_by)
  values (l.id, v_topics, v_remarks, v_s_late, v_s_min, v_t_late, v_t_min, me)
  on conflict (lesson_id) do update set covered_topics = excluded.covered_topics, remarks = excluded.remarks,
    student_late = excluded.student_late, student_late_min = excluded.student_late_min,
    tutor_late = excluded.tutor_late, tutor_late_min = excluded.tutor_late_min, submitted_by = excluded.submitted_by;
  return jsonb_build_object('lesson_id', l.id, 'class_status', v_status, 'repeated', false);
end $function$;

-- ① 강사 Class Record 'Student canceled': 학생이 알린 시각(p_told_at)으로 기존 학생 취소 규칙 그대로 판정
--    (6시간 전 이상 = 사전 취소·변경권 1개 / 공휴일 취소 / 변경권 없음 / 6시간 미만 = 늦은 취소). 운영자 보기도 같은 함수, 이력 via = admin_on_behalf
create or replace function public.tutor_student_cancel(p_request_id uuid, p_lesson uuid, p_told_at timestamptz, p_dry_run boolean)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_admin boolean := is_admin();
  v_mine uuid := my_tutor_id();
  l lessons;
  v_end date;
  v_key text;
begin
  if auth.uid() is null then raise exception 'Sign in first.' using errcode = '42501'; end if;
  if p_request_id is null or p_dry_run is null then raise exception 'Invalid request.'; end if;
  v_key := 'tutor_student_cancel:' || auth.uid()::text || ':' || coalesce(p_lesson::text, '') || ':' || p_request_id::text;
  select * into l from lessons where id = p_lesson for update;
  if not found or not coalesce((v_admin or (my_role() = 'tutor' and v_mine is not null and l.tutor_id = v_mine)), false) then
    raise exception 'This is not your class.' using errcode = '42501';
  end if;
  -- 같은 요청을 다시 보내면 처음 결과 그대로 (lms_change_core 가 같은 키로 돌려줌)
  if not p_dry_run and exists (select 1 from change_requests where idempotency_key = v_key) then
    return lms_change_core(v_key, p_lesson, 'student', 'tutor_app', now(), false, auth.uid());
  end if;
  if p_told_at is null then raise exception 'Enter when the student canceled.'; end if;
  if l.voided_at is not null or l.state <> 'scheduled' then raise exception 'This class is already recorded.' using hint = 'not_scheduled'; end if;
  if exists (select 1 from payroll_items where lesson_id = l.id) then
    raise exception 'This class is already in payroll. Please contact Edge English to change it.' using hint = 'locked';
  end if;
  if l.kind = 'compensation' then raise exception 'Please contact Edge English about this compensation class.'; end if;
  if exists (select 1 from leave_items li where li.lesson_id = l.id and li.lesson_gone_at is null
             and (li.choice = 'undecided' or (li.choice = 'substitute' and li.sub_stage <> 'confirmed'))) then
    raise exception 'This class is being arranged by Edge English.';
  end if;
  if p_told_at > now() then raise exception 'This time is in the future.' using hint = 'future'; end if;
  if p_told_at >= l.starts_at then
    raise exception 'The student told you after the class started. Choose Student no-show.' using hint = 'already_started';
  end if;
  select final_end_date into v_end from enrollments where id = l.enrollment_id;
  if l.starts_at >= ((v_end + 1)::timestamp at time zone 'Asia/Seoul') then
    raise exception 'This class is outside the course period. Please contact Edge English.' using hint = 'outside_enrollment';
  end if;
  return lms_change_core(v_key, p_lesson, 'student', case when v_admin then 'admin_on_behalf' else 'tutor_app' end,
                         p_told_at, p_dry_run, auth.uid());
end $$;
revoke all on function public.tutor_student_cancel(uuid, uuid, timestamptz, boolean) from public, anon;
grant execute on function public.tutor_student_cancel(uuid, uuid, timestamptz, boolean) to authenticated;

-- ② 학생·운영진 화면 JSON 에 수업 종류(type) 더하기 — 지금 정의에 칸 하나만 끼워 넣음 (다시 실행해도 한 번만)
do $$
declare
  d text;
  n text;
begin
  d := pg_get_functiondef('public.student_screen(uuid)'::regprocedure);
  if position('class_type(' in d) = 0 then
    n := replace(d, $a$'substitute', l.original_tutor_id is not null,$a$, $a$'substitute', l.original_tutor_id is not null, 'type', class_type(l),$a$);
    if n = d then raise exception 'student_screen: 끼워 넣을 자리를 못 찾음'; end if;
    execute n;
  end if;

  d := pg_get_functiondef('public.lms_student_profile_json(uuid, text)'::regprocedure);
  if position('class_type(' in d) = 0 then
    n := replace(d, $a$jsonb_build_object('id', l.id, 'kind', l.kind, 'seq', l.seq,$a$, $a$jsonb_build_object('id', l.id, 'kind', l.kind, 'type', class_type(l), 'seq', l.seq,$a$);
    if n = d then raise exception 'lms_student_profile_json: 끼워 넣을 자리를 못 찾음'; end if;
    execute n;
  end if;

  d := pg_get_functiondef('public.admin_student_detail(uuid)'::regprocedure);
  if position('class_type(' in d) = 0 then
    n := replace(d, $a$jsonb_build_object('id', l.id, 'kind', l.kind, 'starts_at', l.starts_at, 'state', l.state,$a$,
                    $a$jsonb_build_object('id', l.id, 'kind', l.kind, 'type', (select class_type(x) from lessons x where x.id = l.id), 'starts_at', l.starts_at, 'state', l.state,$a$);
    if n = d then raise exception 'admin_student_detail: 끼워 넣을 자리를 못 찾음'; end if;
    execute n;
  end if;
end $$;
