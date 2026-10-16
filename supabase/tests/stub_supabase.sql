-- 로컬 검증용: Supabase에 원래 있는 것(역할, auth.uid(), 기본 권한)을 흉내만 냄. 실제 Supabase에는 적용하지 않음
-- 실제 Supabase 새 프로젝트처럼 public 에 새로 만드는 표·함수·시퀀스는 anon·authenticated·service_role 에게
-- 모든 권한이 자동으로 열린다(기본 권한). 마이그레이션이 이것을 제대로 막는지 같은 조건에서 확인하기 위함
do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'anon') then create role anon nologin noinherit; end if;
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then create role authenticated nologin noinherit; end if;
  if not exists (select 1 from pg_roles where rolname = 'service_role') then create role service_role nologin noinherit bypassrls; end if;
end $$;
create schema if not exists auth;
-- Supabase 의 auth.uid() 와 같은 방식 (예전 claim.sub 설정 → 없으면 claims JSON 의 sub)
create or replace function auth.uid() returns uuid language sql stable as $$
  select coalesce(nullif(current_setting('request.jwt.claim.sub', true), ''),
                  (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub'))::uuid
$$;
grant usage on schema auth to anon, authenticated, service_role;
grant usage on schema public to anon, authenticated, service_role;

alter default privileges in schema public grant all on tables to anon, authenticated, service_role;
alter default privileges in schema public grant all on functions to anon, authenticated, service_role;
alter default privileges in schema public grant all on sequences to anon, authenticated, service_role;
