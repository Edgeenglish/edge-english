-- =====================================================================
-- 4402. 강사 화면 Students 메뉴 — 운영자 보기 (2026-11-04 대표: 강사 계정 접근 권한은 그대로, 운영자도 같은 목록)
--  - tutor_students_list(p_tutor): 강사 본인(p_tutor 비움) 또는 운영자(TOTP, 강사 고름) — lms_screen_tutor 가 확인
--  - 누가 보이는지는 4300 lms_tutor_student_access 그대로 (정규 담당 + 확정된 대체수업 학생, 대체는 이메일 없음)
--  - tutor_my_students 는 그대로 둠 (지우는 문장 없음). 다시 실행해도 같은 결과
-- =====================================================================
create or replace function tutor_students_list(p_tutor uuid default null)
returns table (student_id uuid, display_name text, country text, timezone text, level text, class_type text, class_note_url text, access text)
language sql stable security definer set search_path = public as $$
  select s.id, lms_tutor_student_label(s.name_en, s.display_name), s.country, s.timezone, s.level, s.class_type, s.class_note_url, a.access
  from students s
  cross join lateral (select lms_tutor_student_access(lms_screen_tutor(p_tutor), s.id) as access) a
  where a.access is not null
$$;
revoke all on function tutor_students_list(uuid) from public, anon;
grant execute on function tutor_students_list(uuid) to authenticated;
