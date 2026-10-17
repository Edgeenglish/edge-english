-- 로컬 검증용: Supabase에 원래 있는 것(역할, auth.uid(), 기본 권한)을 흉내만 냄. 실제 Supabase에는 적용하지 않음
-- 실제 Supabase 새 프로젝트처럼 public 에 새로 만드는 표·함수·시퀀스가 앱 사용자(anon·authenticated)에게
-- 자동으로 열리는 상태를 흉내 낸다(기본 권한). 마이그레이션이 이것을 제대로 막는지 같은 조건에서 확인하기 위함
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

-- anon·authenticated: 가장 위험한 경우(새 표가 자동으로 열림)를 그대로 흉내 → 마이그레이션이 막는지 확인
-- service_role: 시험용 프로젝트 실물 확인(2026-10-17 5-4)에서 새 표 권한이 자동으로 주어지지 않았음 → 그 상태를 흉내
--               (서버 키 쓰기가 마이그레이션 710 의 명시적 권한만으로 되는지 확인)
alter default privileges in schema public grant all on tables to anon, authenticated;
alter default privileges in schema public grant all on functions to anon, authenticated, service_role;
alter default privileges in schema public grant all on sequences to anon, authenticated;
