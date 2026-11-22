-- =====================================================================
-- 시간 협의 필요 회차를 화면·남은 수 계산에 넣기 (2026-11-22)
--  - student_pending_times / tutor_pending_times: 학생·강사·운영자 보기(같은 권한 검사 lms_screen_*)가 함께 씀
--  - lms_renewal_remaining: 협의 필요 회차도 남은 수에 넣음 (재등록 안내가 일찍 뜨지 않게)
-- =====================================================================

create or replace function student_pending_times(p_student uuid)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_student uuid := lms_screen_student(p_student);
begin
  return coalesce((
    select jsonb_agg(jsonb_build_object('seq', p.seq, 'enrollment_id', p.enrollment_id, 'reason', p.reason, 'minutes', e.duration_min,
             'starts_at', (p.original_date + p.time_kst) at time zone 'Asia/Seoul') order by p.original_date)
    from plan_pending_lessons p join enrollments e on e.id = p.enrollment_id
    where p.student_id = v_student and p.resolved_at is null), '[]'::jsonb);
end $$;

create or replace function tutor_pending_times(p_tutor uuid)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_tutor uuid := lms_screen_tutor(p_tutor);
begin
  return coalesce((
    select jsonb_agg(jsonb_build_object('student', lms_tutor_student_label(s.name_en, s.display_name), 'student_id', s.id, 'seq', p.seq, 'minutes', e.duration_min,
             'starts_at', (p.original_date + p.time_kst) at time zone 'Asia/Seoul') order by s.name_en, p.original_date)
    from plan_pending_lessons p join students s on s.id = p.student_id join enrollments e on e.id = p.enrollment_id
    where p.tutor_id = v_tutor and p.resolved_at is null), '[]'::jsonb);
end $$;

revoke all on function student_pending_times(uuid), tutor_pending_times(uuid) from public, anon;
grant execute on function student_pending_times(uuid), tutor_pending_times(uuid) to authenticated;

create or replace function lms_renewal_remaining(p_enrollment uuid, p_now timestamptz default now())
returns integer
language sql stable security definer set search_path = public as $$
  select
    (select count(*) from lessons l
      where l.enrollment_id = p_enrollment and l.voided_at is null and l.state = 'scheduled' and l.starts_at > p_now)::int
    + (select count(*) from lessons l
        where l.enrollment_id = p_enrollment and l.voided_at is null and l.class_status is not null
          and (l.state = 'canceled' or l.class_status = 'Tutor no-show')
          and (lms_grants_makeup(l.class_status) or l.class_status = 'Tutor long-term leave')
          and not exists (select 1 from lessons m where m.makeup_of = l.id and m.state <> 'canceled'))::int
    + (select count(*) from migrated_items m where m.enrollment_id = p_enrollment and m.kind = 'makeup_open')::int
    + (select count(*) from compensations c where c.enrollment_id = p_enrollment and c.status = 'available')::int
    + (select count(*) from plan_pending_lessons p where p.enrollment_id = p_enrollment and p.resolved_at is null)::int
$$;
