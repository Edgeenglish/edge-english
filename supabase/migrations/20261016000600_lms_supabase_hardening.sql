-- =====================================================================
-- Supabase 실제 프로젝트용 권한 정리 (시험용 프로젝트 적용 전 추가)
-- Supabase는 public 스키마의 새 표·함수·시퀀스에 anon(로그인 안 한 사용자)·authenticated 권한을
-- 기본으로 줌. 표는 lms_protect 가 이미 막았고, 여기서는 함수·시퀀스를 막는다.
-- - 로그인 안 한 사용자(anon): LMS 함수·시퀀스 사용 불가
-- - 로그인 사용자(authenticated): 권한 정책(RLS)이 쓰는 함수만 실행 가능, 학생 번호 시퀀스는 사용 불가
-- - 쓰기는 서버(service_role)만
-- =====================================================================
revoke all on sequence student_code_seq from public, anon, authenticated;

revoke execute on all functions in schema public from public, anon;
grant execute on all functions in schema public to authenticated;
do $$
begin
  if exists (select 1 from pg_roles where rolname = 'service_role') then
    execute 'grant execute on all functions in schema public to service_role';
    execute 'grant usage, select on sequence student_code_seq to service_role';
  end if;
end $$;

-- 앞으로 만드는 함수도 anon 에게 자동으로 열리지 않게
alter default privileges in schema public revoke execute on functions from public, anon;
