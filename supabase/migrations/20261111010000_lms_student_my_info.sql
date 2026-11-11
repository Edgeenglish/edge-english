-- 학생 '내 정보'·홈 (11/11 대표 시안 '학생 홈·내 정보 최신', H26(95) 내 정보 누락 금지 항목)
--  ① 나의 학습 정보 (강사 작성 4칸): 영어 레벨 · 학습 목표 · 수업 방식·교재 · 수업 노트(Google Docs) — 강사가 저장한 값만
--  ② 나의 누적 학습 시간: 진행된 수업(class_status_rules.outcome = 'held')의 길이 합, 모든 수강권
-- 읽기만 하는 함수 (데이터 변경 없음). 운영자 보기도 같은 함수 (lms_screen_student)
create or replace function student_my_info(p_student uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_student uuid := lms_screen_student(p_student);
  st students;
  v_book text; v_mat text; v_style text; v_parts text[]; v_m text;
begin
  select * into st from students where id = v_student;
  v_book := case when nullif(trim(coalesce(st.textbook, '')), '') is not null then ' · ' || st.textbook else '' end;
  v_mat := case when nullif(trim(coalesce(st.tutor_materials_note, '')), '') is not null then ' · ' || st.tutor_materials_note else '' end;
  v_style := case st.tutor_class_style
    when 'conversation' then '회화'
    when 'textbook' then '교재 중심' || v_book
    when 'student_materials' then '수강생 제공 자료' || v_mat
    when 'mixed' then '혼합' end;
  if st.tutor_class_style = 'mixed' then
    v_parts := array[]::text[];
    foreach v_m in array coalesce(st.tutor_class_style_mix, array[]::text[]) loop
      v_parts := v_parts || (case v_m when 'conversation' then '회화' when 'textbook' then '교재' || v_book
                                       when 'student_materials' then '수강생 자료' || v_mat else '기타' end);
    end loop;
    v_style := '혼합: ' || array_to_string(v_parts, ' + ');
  end if;
  return jsonb_build_object(
    'level', case when st.level_by is not null then st.level end,
    'goal', case when st.improve_tutor_at is not null then nullif(trim(coalesce(st.improve, '')), '') end,
    'style', case when st.tutor_class_style_at is not null then v_style end,
    'note_url', case when lms_is_google_doc_url(st.class_note_url) then st.class_note_url end,
    'learned_min', coalesce((
      select sum(extract(epoch from (l.ends_at - l.starts_at)) / 60)::int
      from lessons l join class_status_rules r on r.status = l.class_status
      where l.student_id = v_student and l.voided_at is null and l.state = 'done' and r.outcome = 'held'), 0));
end $$;
revoke all on function student_my_info(uuid) from public, anon;
grant execute on function student_my_info(uuid) to authenticated;
