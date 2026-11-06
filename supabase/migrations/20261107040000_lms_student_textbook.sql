-- QA C-04 (2026-11-07 대표 결정): 강사가 정한 교재를 학생 '학습자료' 화면에도 보여 줌
-- 교재 원본은 students.textbook (운영진 '교재' 칸 = 강사 첫 수업 후 확인 4600 에서 고른 교재, 같은 칸).
-- 학생에게 보이는 조건: 교재가 있고, 강사 확인 수업 방식이 없거나(예전 학생) Textbook-based 이거나 Mixed 에 Textbook 포함.
--   (Conversation 등으로 바꾸면 4600 이 교재 칸을 남겨 두므로, 그때는 학생에게 안 보임)
-- 권한: 학생 본인 또는 운영자(학생 고른 문맥) — 학생 화면 다른 함수와 같은 lms_screen_student
create or replace function student_textbook(p_student uuid default null)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_student uuid := lms_screen_student(p_student);
  s students;
begin
  select * into s from students where id = v_student;
  if nullif(trim(coalesce(s.textbook, '')), '') is null then return jsonb_build_object('textbook', null); end if;
  if s.tutor_class_style is not null and not (s.tutor_class_style = 'textbook'
       or (s.tutor_class_style = 'mixed' and 'textbook' = any(coalesce(s.tutor_class_style_mix, '{}')))) then
    return jsonb_build_object('textbook', null);
  end if;
  return jsonb_build_object('textbook', trim(s.textbook));
end $$;
revoke all on function student_textbook(uuid) from public, anon;
grant execute on function student_textbook(uuid) to authenticated;
