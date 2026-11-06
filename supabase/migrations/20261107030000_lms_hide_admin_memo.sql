-- QA D-03 (2026-11-07): 학생이 students 표 본인 줄을 직접 읽으면(API) 운영 메모(admin_memo)까지 보이던 것 막기
-- 원인: RLS 정책 student_self 가 줄 전체를 열고, authenticated 에 표 전체 select 권한이 있었음.
--       학생 화면은 student_screen(서버 함수)만 써서 화면에는 안 보였지만, 직접 조회로는 읽혔음.
-- 고침: authenticated 의 students 직접 읽기 권한을 admin_memo 를 뺀 칸으로만 줌 (줄 단위 RLS 는 그대로).
--       운영 메모를 읽고 쓰는 곳은 모두 security definer 함수(admin_student_detail·lms_student_profile_json·
--       admin_student_update·admin_register_student·admin_import_existing_student)라 영향 없음.
-- 주의: 앞으로 students 에 새 칸을 추가하면, 화면이 그 칸을 표에서 직접 읽어야 할 때만
--       'grant select (새 칸) on students to authenticated' 를 같이 넣는다 (운영진 화면은 대부분 함수로 읽음).
revoke select on public.students from authenticated;
do $$
declare cols text;
begin
  select string_agg(quote_ident(column_name), ', ' order by ordinal_position) into cols
  from information_schema.columns
  where table_schema = 'public' and table_name = 'students' and column_name <> 'admin_memo';
  execute format('grant select (%s) on public.students to authenticated', cols);
end $$;
