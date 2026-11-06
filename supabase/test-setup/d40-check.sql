-- =====================================================================
-- D-40 적용 확인 (읽기만 함 — 아무것도 바꾸지 않음)
-- migration 20261018000900_lms_register_student.sql 을 실행한 뒤 SQL Editor 에서 Run → 모든 줄이 '통과' 면 완료
-- =====================================================================
with c(번호, 점검, ok) as (values
  (1, '시험용 프로젝트 (가상강사 2명 있음)',
      (select count(*) = 2 from tutors where name like '가상강사%')),
  (2, '등록 요청 기록 표 있음 + RLS 켜짐',
      coalesce((select relrowsecurity from pg_class where oid = to_regclass('public.registration_requests')), false)),
  (3, '등록 요청 기록 표: 로그인 안 한 사용자는 읽기·쓰기 모두 불가',
      coalesce(not has_table_privilege('anon', to_regclass('public.registration_requests'), 'select,insert,update,delete'), false)),
  (4, '등록 요청 기록 표: 로그인 사용자도 직접 쓰기 불가 (함수로만)',
      coalesce(not has_table_privilege('authenticated', to_regclass('public.registration_requests'), 'insert,update,delete'), false)),
  (5, '등록 요청 기록 표: 변경 이력 남김',
      exists (select 1 from pg_trigger where tgname = 'registration_requests_audit')),
  (6, '등록 저장 함수: 있음 · 로그인 안 한 사용자 실행 불가 · 로그인 사용자만 (안에서 운영자 TOTP 확인)',
      coalesce((select prosecdef from pg_proc where oid = to_regprocedure('public.admin_register_student(uuid,jsonb)'))
               and not has_function_privilege('anon', to_regprocedure('public.admin_register_student(uuid,jsonb)'), 'execute')
               and has_function_privilege('authenticated', to_regprocedure('public.admin_register_student(uuid,jsonb)'), 'execute'), false)),
  (7, '같은 이메일 확인 함수: 있음 · 로그인 안 한 사용자 실행 불가',
      coalesce(not has_function_privilege('anon', to_regprocedure('public.admin_students_with_email(text)'), 'execute')
               and has_function_privilege('authenticated', to_regprocedure('public.admin_students_with_email(text)'), 'execute'), false)),
  (8, '학생 표: 로그인 사용자 직접 쓰기 불가 (그대로)',
      not has_table_privilege('authenticated', 'public.students', 'insert,update,delete')),
  (9, '화면 시험용 가상강사 가능 시간 있음 (d40-availability.sql)',
      (select count(distinct tutor_id) = 2 from tutor_availability a join tutors t on t.id = a.tutor_id where t.name like '가상강사%'))
)
select 번호, 점검, case when ok then '통과' else '실패' end as 결과 from c order by 번호;
