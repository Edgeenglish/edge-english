-- 강사 학생 정보 접근 (대표 11/14 결정, 개인정보 처리방침·강사 부속합의서 제8조와 같게)
-- ① 비활성 강사(tutors.active = false)는 모든 학생 정보 접근 즉시 차단 — my_tutor_id() 가 null
-- ② 배정이 끝난 학생은 마지막 수업 종료 24시간 뒤 차단 (전에는 60일). 정규 일정은 끝난 날 다음 날 하루까지
--    지금 담당 학생(끝나지 않은 정규 일정·앞으로 수업)은 그대로. 대체강사 24시간 규칙은 그대로
-- 수업 기록 입력(tutor_record_class)은 이 접근 권한과 따로라서 지난 수업 기록은 계속 쓸 수 있음(비활성 강사 제외)

create or replace function public.my_tutor_id()
 returns uuid
 language sql
 stable security definer
 set search_path to 'public'
as $function$
  select a.tutor_id from app_users a join tutors t on t.id = a.tutor_id
  where a.auth_user_id = auth.uid() and t.active
$function$;

create or replace function public.lms_tutor_student_access(p_tutor uuid, p_student uuid)
 returns text
 language sql
 stable security definer
 set search_path to 'public'
as $function$
  select case
    when p_tutor is null or p_student is null then null
    when not exists (select 1 from tutors t where t.id = p_tutor and t.active) then null
    when exists (select 1 from regular_schedules rs where rs.student_id = p_student and rs.tutor_id = p_tutor
                 and (rs.effective_to is null or rs.effective_to >= ((now() - interval '24 hours') at time zone 'Asia/Seoul')::date))
      or exists (select 1 from lessons l where l.student_id = p_student and l.state <> 'canceled' and l.voided_at is null
                 and coalesce(l.original_tutor_id, l.tutor_id) = p_tutor
                 and l.ends_at > now() - interval '24 hours')
      then 'regular'
    when exists (select 1 from lessons l where l.student_id = p_student and l.tutor_id = p_tutor
                 and l.original_tutor_id is not null and l.original_tutor_id <> p_tutor
                 and l.state <> 'canceled' and l.voided_at is null
                 and now() <= l.ends_at + interval '24 hours')
      then 'substitute'
    else null end
$function$;
