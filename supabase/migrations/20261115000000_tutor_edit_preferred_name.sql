-- 담당(정규) 강사가 학생 별칭(Preferred name)을 직접 기록 (대표 11/15: 신청서에 없는 정보라 수업 중 알게 되면 강사가 적음)
-- 성별·나이대·국가·도시·시간대·이름·이메일·전화는 계속 운영진만 (신청서 정보 / 시간 표시·메일 주소에 영향)
create or replace function public.tutor_student_update(p_student uuid, p jsonb)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare
  me uuid := my_tutor_id();
  n integer;
begin
  if not is_admin() then
    if me is null or lms_tutor_student_access(me, p_student) is distinct from 'regular' then
      raise exception 'Only the student''s regular tutor can edit this.' using errcode = '42501';
    end if;
  end if;
  perform set_config('app.actor_id', auth.uid()::text, true);
  perform set_config('app.actor_via', 'tutor_student_update', true);
  n := lms_student_apply(p_student, p, array['display_name', 'level', 'job', 'hobbies', 'interests', 'improve', 'hopes',
         'correction_style', 'correction_note', 'class_style', 'class_style_note'],
         case when is_admin() and me is null then 'admin' else 'tutor' end, 'tutor_student_update');
  return jsonb_build_object('changed', n);
end $function$;
