CREATE OR REPLACE FUNCTION public.student_enrollment_history(p_student uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_student uuid := lms_screen_student(p_student);
  v_current uuid := lms_student_enrollment(v_student);
begin
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'schedule_pending', e.status in ('confirmed', 'active')
               and e.final_end_date >= (now() at time zone 'Asia/Seoul')::date
               and exists (select 1 from payments p where p.enrollment_id=e.id)
               and exists (select 1 from enrollments prev where prev.id=e.previous_enrollment_id
                 and (prev.weekly_count <> e.weekly_count or prev.duration_min <> e.duration_min))
               and not exists (select 1 from lessons l where l.enrollment_id=e.id and l.kind='regular' and l.voided_at is null),
             'id', e.id, 'current', e.id = v_current, 'status', e.status,
             'duration_min', e.duration_min, 'weekly_count', e.weekly_count, 'weeks', e.weeks, 'legacy_label', e.legacy_label,
             'start_date', e.start_date, 'final_end_date', e.final_end_date,
             'method', (select p.method from payments p where p.enrollment_id = e.id order by p.confirmed_at desc limit 1),
             'confirmed_on', (select min((p.confirmed_at at time zone 'Asia/Seoul')::date) from payments p where p.enrollment_id = e.id))
           order by e.seq desc)
    from enrollments e where e.student_id = v_student and e.status <> 'canceled'), '[]'::jsonb);
end $function$
