-- 강사 해외 이동 기간 4차 QA ④ (정책 원본 H26(176)(182)): 보강 강사를 바꾼 뒤 이전 강사에게 보내는 취소 안내 시각
--  old_tutor_tz = 이전 강사의 '그 보강 시각(바꾸기 전)'에 있던 지역 시간대 (lms_tutor_tz_at). 이동 기간이 없으면 전과 같음 (tutors.timezone)
create or replace function public.admin_makeup_logs_for(p_student uuid)
 returns jsonb language plpgsql stable security definer set search_path to 'public' as $function$
begin
  if not is_admin() then raise exception '운영자(추가 인증 완료)만 처리할 수 있습니다.' using errcode = '42501'; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', g.id, 'makeup_request_id', g.makeup_request_id, 'lesson_id', g.lesson_id, 'action', g.action, 'reason', g.reason, 'note', g.note,
      'old_starts_at', g.old_starts_at, 'new_starts_at', g.new_starts_at, 'created_at', g.created_at,
      'old_tutor', ot.name,
      'old_tutor_tz', case when ot.id is null then null else lms_tutor_tz_at(ot.id, coalesce(g.old_starts_at, g.new_starts_at)) end,
      'new_tutor', nt.name
    ) order by g.created_at desc)
    from admin_makeup_logs g
    left join tutors ot on ot.id = g.old_tutor_id
    left join tutors nt on nt.id = g.new_tutor_id
    where g.student_id = p_student), '[]'::jsonb);
end $function$;
