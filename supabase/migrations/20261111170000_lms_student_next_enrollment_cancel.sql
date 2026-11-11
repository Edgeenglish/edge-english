-- =====================================================================
-- 다음 수강권(재등록 확정) 수업도 학생 화면에서 그 수강권 규칙으로 취소 (대표 11/11, H26(140) 발견분)
--  문제: 학생 화면이 '지금 수강권' 종료일·변경권 기간만 받아, 다음 수강권 수업은 '수강기간이 지난 수업이에요'로 취소 불가.
--        (DB 판정 lms_change_core 는 원래 수업의 수강권 기준이라 맞음 → 화면 미리 보기만 틀림)
--  고침: student_screen 수업마다 그 수업 수강권의 final_end_date, credit_periods 는 열린 수강권 전부(enrollment_id 포함)
-- 되돌리기: 이 파일 앞 student_screen 정의 (20261111140000 적용 뒤 상태)
-- =====================================================================
do $$
declare
  d text;
  n text;
begin
  d := pg_get_functiondef('public.student_screen(uuid)'::regprocedure);
  if position('''lesson_final_end_date''' in d) = 0 then
    n := replace(d, $a$'substitute', l.original_tutor_id is not null,$a$,
                    $a$'substitute', l.original_tutor_id is not null, 'lesson_final_end_date', (select x.final_end_date from enrollments x where x.id = l.enrollment_id),$a$);
    if n = d then raise exception 'student_screen: 수업 칸 자리를 못 찾음'; end if;
    d := n;
    n := replace(d, $a$jsonb_build_object('idx', p.idx, 'start', p.start_date, 'end', p.end_date, 'granted', p.credits_granted, 'left', credit_balance(p.id)) order by p.idx)
      from enrollment_periods p where p.enrollment_id = e.id)$a$,
                    $a$jsonb_build_object('idx', p.idx, 'start', p.start_date, 'end', p.end_date, 'granted', p.credits_granted, 'left', credit_balance(p.id), 'enrollment_id', p.enrollment_id) order by p.start_date, p.idx)
      from enrollment_periods p where p.enrollment_id = any(v_open))$a$);
    if n = d then raise exception 'student_screen: 변경권 기간 자리를 못 찾음'; end if;
    execute n;
  end if;
end $$;
