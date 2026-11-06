-- =====================================================================
-- 로그인 직후 본인 역할 확인 (로그인 화면용, POL-AC-04·05)
-- 메일 코드만 통과한(aal1) 운영자도 '인증 앱 코드를 물어야 하는 사람'인지 알아야 하므로, 본인 역할 하나만 돌려준다.
-- - 본인 것만: auth.uid() 의 app_users.role (student / tutor / admin), 연결 안 된 계정은 null
-- - 다른 사람 역할·학생 번호 등은 돌려주지 않음. 운영자 권한 자체는 여전히 is_admin()(aal2) 로만
-- 다시 실행해도 같은 결과
-- =====================================================================
create or replace function my_role() returns text
language sql stable security definer set search_path = public as $$
  select role from app_users where auth_user_id = auth.uid()
$$;

revoke all on function my_role() from public, anon;
grant execute on function my_role() to authenticated;
do $$
begin
  if exists (select 1 from pg_roles where rolname = 'service_role') then
    execute 'grant execute on function my_role() to service_role';
  end if;
end $$;
