-- =====================================================================
-- 운영자 추가 인증(TOTP) 강제 + 운영자 역할 분리 (POL-AC-05·07, 정책 원본 A27·A34, D-29)
-- - 운영자 권한(is_admin)은 TOTP까지 마친 세션(Supabase JWT 의 aal = 'aal2')에서만 참
--   → 이메일 코드만 통과한 운영자 세션은 RLS상 학생·결제·수업 데이터를 한 줄도 못 봄 (화면이 아니라 DB가 막음)
-- - 운영자 역할: owner(대표) / staff(운영직원). 대표 전용 작업(환불 실행·승인, 적립금 지급·조정·취소,
--   금전 관련 중요 설정)은 서버 쓰기 기능이 is_owner() 로 확인한다. 쓰기 자체는 지금처럼 서버(service_role)만
-- - 직원의 읽기 범위는 아직 정하지 않음 → 지금은 운영자와 같음. 직원 계정을 실제로 만들기 전에 정한다 (07-decisions)
-- - 강사·학생은 TOTP 없음 (이메일 코드만)
-- 다시 실행해도 같은 결과
-- =====================================================================

alter table app_users add column if not exists admin_level text check (admin_level in ('owner', 'staff'));
-- 이미 있는 운영자 계정은 낮은 권한(staff)으로 둔다. 대표 계정은 서버·SQL Editor 에서 owner 로 따로 지정 (최소 권한)
update app_users set admin_level = 'staff' where role = 'admin' and admin_level is null;
update app_users set admin_level = null where role <> 'admin' and admin_level is not null;
do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'app_users_admin_level_role') then
    alter table app_users add constraint app_users_admin_level_role check ((role = 'admin') = (admin_level is not null));
  end if;
end $$;

-- TOTP까지 마친 세션인지 (Supabase Auth 가 발급한 JWT 의 aal 값)
create or replace function auth_is_aal2() returns boolean
language sql stable set search_path = public as $$
  select coalesce(auth.jwt() ->> 'aal', '') = 'aal2'
$$;

create or replace function is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select auth_is_aal2()
     and coalesce((select role = 'admin' from app_users where auth_user_id = auth.uid()), false)
$$;

-- 대표 전용 권한 확인 (서버 쓰기 기능이 호출 운영자 확인에 사용, POL-AC-07)
create or replace function is_owner() returns boolean
language sql stable security definer set search_path = public as $$
  select auth_is_aal2()
     and coalesce((select role = 'admin' and admin_level = 'owner' from app_users where auth_user_id = auth.uid()), false)
$$;

revoke all on function auth_is_aal2() from public, anon;
revoke all on function is_owner() from public, anon;
grant execute on function auth_is_aal2(), is_admin(), is_owner() to authenticated;
do $$
begin
  if exists (select 1 from pg_roles where rolname = 'service_role') then
    execute 'grant execute on function auth_is_aal2(), is_admin(), is_owner() to service_role';
  end if;
end $$;
