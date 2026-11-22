-- =====================================================================
-- 강사 화면 학생 이름: 별명이 있으면 어디서나 '영문 이름 (별명)' (2026-11-22 대표)
--  별명만 보이던 곳 4개를 lms_tutor_student_label 로: tutor_updates_feed(수강생 취소 줄) · tutor_canceled_classes · tutor_hours · lms_weekly_classes
--  화면 데이터 함수만 — 메일 없음
-- =====================================================================
do $$
declare
  f text;
  d text;
  a text := 'coalesce(s.display_name, s.name_en)';
begin
  foreach f in array array['tutor_updates_feed(uuid)', 'tutor_canceled_classes', 'tutor_hours', 'lms_weekly_classes(uuid,text,date)'] loop
    d := pg_get_functiondef(case when f like '%(%' then f::regprocedure else f::regproc::oid end);
    if position(a in d) = 0 then raise exception '자리 못 찾음: %', f; end if;
    execute replace(d, a, 'lms_tutor_student_label(s.name_en, s.display_name)');
  end loop;
end $$;
