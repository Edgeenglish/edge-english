-- 강사 화면에서 학생 이메일 숨김 (대표 11/15: 강사가 학생에게 이메일 보낼 일 없음 — 늦어요·수업 기록은 LMS 로 대체)
-- 운영자 자기 학생 화면(access 'admin')은 그대로. 운영자가 강사 화면을 대신 볼 때(?tutor=, access 'regular')도 강사와 같게 안 보임.
-- 지금 함수 본문에서 해당 한 줄만 바꿈. 본문이 예상과 다르면 멈춤.
do $mig$
declare d text; n text;
begin
  d := pg_get_functiondef('public.lms_student_profile_json(uuid, text)'::regprocedure);
  n := replace(d, $x$'email', case when v_full then s.email end,$x$, $x$'email', case when p_access = 'admin' then s.email end,$x$);
  if n = d then raise exception 'lms_student_profile_json: 예상한 email 줄이 없음 — 멈춤'; end if;
  execute n;

  d := pg_get_functiondef('public.tutor_my_students()'::regprocedure);
  n := replace(d, $x$case when a.access = 'regular' then s.email end$x$, $x$null::text$x$);
  if n = d then raise exception 'tutor_my_students: 예상한 email 줄이 없음 — 멈춤'; end if;
  execute n;
end
$mig$;
