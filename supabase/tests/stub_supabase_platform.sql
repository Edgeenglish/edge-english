-- 로컬 검증용: 실물 Supabase에만 있는 것을 흉내 냄 (마이그레이션 적용 뒤에 실행). 실제 Supabase에는 적용하지 않음
-- 2026-10-17 시험용 프로젝트에서 authz-probe 가 이 두 가지 때문에 실패했다 → 로컬에서도 같은 조건을 만들어 둔다
-- 1) 확장(btree_gist) 함수는 플랫폼 관리자 소유라 anon 실행 권한이 남음 (우리 SQL의 revoke 가 닿지 않음)
do $$
declare f regprocedure;
begin
  for f in select p.oid::regprocedure from pg_proc p join pg_depend d on d.objid = p.oid and d.classid = 'pg_proc'::regclass and d.deptype = 'e'
           join pg_extension e on e.oid = d.refobjid where e.extname = 'btree_gist'
  loop execute format('grant execute on function %s to anon, authenticated', f); end loop;
end $$;
-- 2) Supabase '자동 RLS 켜기' 이벤트 트리거 함수 (public, SECURITY DEFINER)
create or replace function public.rls_auto_enable() returns event_trigger
language plpgsql security definer set search_path = pg_catalog as $$ begin null; end $$;
revoke execute on function public.rls_auto_enable() from public, anon;   -- 실물: anon 호출 시 permission denied (2026-10-17 확인)
grant execute on function public.rls_auto_enable() to authenticated;
