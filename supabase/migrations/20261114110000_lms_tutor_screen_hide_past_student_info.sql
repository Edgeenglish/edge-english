-- 강사 Home 수업 줄: 학생 정보 접근이 끝난 학생(배정 끝나고 마지막 수업 24시간 지남·비활성 강사)은 수준·노트 링크를 안 보냄 (대표 11/14 C)
-- 이름·수업 기록 칸은 그대로 → Class Record 입력 유지. 접근 판단은 lms_tutor_student_access (20261114100000) 하나
-- 지금 함수 본문에서 두 곳만 바꿔 다시 만듦 (본문이 바뀌어 있으면 멈춤)
do $migration$
declare
  d text := pg_get_functiondef('public.tutor_screen(uuid,date,date)'::regprocedure);
  a text := $r$'level', s.level, 'note_url', s.class_note_url,$r$;
  b text := $r$'level', s.level, 'note_url', null,$r$;
begin
  if position(a in d) = 0 or position(b in d) = 0 then
    raise exception 'tutor_screen 본문이 예상과 달라 멈춤';
  end if;
  d := replace(d, a, $r$'level', case when lms_tutor_student_access(v_tutor, s.id) is not null then s.level end, 'note_url', case when lms_tutor_student_access(v_tutor, s.id) is not null then s.class_note_url end,$r$);
  d := replace(d, b, $r$'level', case when lms_tutor_student_access(v_tutor, s.id) is not null then s.level end, 'note_url', null,$r$);
  execute d;
end
$migration$;
