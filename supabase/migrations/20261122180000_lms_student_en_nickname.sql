-- =====================================================================
-- 강사 자동 메일 학생 이름도 '영문 이름 (별명)' (2026-11-22 대표 '오케이')
--  lms_student_en 은 강사에게 가는 영어 메일(재등록·첫 수업·지각·수업 알림·새 학생 요청·일정 변경·대체 확정)에서만 씀
--  별명이 없거나 영문 이름과 같으면 지금과 같음. 메일이 더 가지는 않음
-- =====================================================================
create or replace function lms_student_en(st students)
returns text language sql immutable as $$
  select lms_tutor_student_label(coalesce(nullif(st.name_en, ''), st.name_ko), st.display_name)
$$;
