-- =====================================================================
-- 서버 키(service_role) 표 권한 명시 (2026-10-17 5-4 실물 점검에서 발견)
-- 시험용 프로젝트에서는 새 표가 service_role 에게 자동으로 열리지 않았다 → 서버 키로 app_users 연결이 403
-- (GET app_users·audit_log·students 모두 42501 permission denied 확인). 지금까지는 Supabase 기본 권한에 기대고 있었음.
-- - 서버 키: LMS 표 읽기·쓰기 (RLS는 service_role 의 bypassrls 로 통과 — 쓰기는 서버 기능만 하는 설계)
-- - 변경 이력(audit_log)은 서버 키도 고치거나 지울 수 없음 (추가·읽기만)
-- - 앱 사용자(anon·authenticated) 권한은 바꾸지 않음
-- 다시 실행해도 같은 결과 (권한 부여·회수만, 데이터 변경 없음)
-- =====================================================================
do $$
begin
  if exists (select 1 from pg_roles where rolname = 'service_role') then
    execute 'grant usage on schema public to service_role';
    execute 'grant select, insert, update, delete on all tables in schema public to service_role';
    execute 'revoke update, delete, truncate on audit_log from service_role';
    execute 'grant usage, select on all sequences in schema public to service_role';
    execute 'grant execute on all functions in schema public to service_role';
    -- 앞으로 만드는 표·시퀀스·함수도 서버 키에 같은 권한
    execute 'alter default privileges in schema public grant select, insert, update, delete on tables to service_role';
    execute 'alter default privileges in schema public grant usage, select on sequences to service_role';
    execute 'alter default privileges in schema public grant execute on functions to service_role';
  end if;
end $$;
