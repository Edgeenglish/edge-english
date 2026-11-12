-- =====================================================================
-- 학생 화면 보강권에 '이월' 표시 (대표 2026-11-12: 카드 제목 '이월된 수업')
--  student_screen makeup_rights 에 carry_in = 지금 수강권(lms_student_enrollment)이 아닌 앞 수강권에서 넘어온 권리
--  (가져온 보강권 migrated_items 도 같은 기준). 다른 부분은 그대로. 다시 실행해도 같은 결과
-- =====================================================================
do $$
declare
  d text;
  d2 text;
begin
  d := pg_get_functiondef('student_screen(uuid)'::regprocedure);
  if position('''carry_in''' in d) > 0 then return; end if;
  d2 := replace(d, $a$'tutor_leave', l.class_status = 'Tutor long-term leave') as r$a$,
                   $a$'tutor_leave', l.class_status = 'Tutor long-term leave',
                 'carry_in', (e.id is not null and l.enrollment_id <> e.id)) as r$a$);
  d2 := replace(d2, $a$'tutor_leave', coalesce(m.tutor_leave, false))$a$,
                    $a$'tutor_leave', coalesce(m.tutor_leave, false),
                 'carry_in', (e.id is not null and m.enrollment_id <> e.id))$a$);
  if d2 = d or position('''carry_in''' in d2) = 0 then raise exception 'student_screen 패치 실패'; end if;
  execute d2;
end $$;
