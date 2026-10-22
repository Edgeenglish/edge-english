-- 엣지영어 LMS 데이터 백업 — 읽기만 함 (데이터를 바꾸지 않음)
-- 쓰는 때: 운영 DB를 바꾸기(마이그레이션 적용) 직전, 실제 데이터를 많이 넣기 전후
-- 사용: Supabase → SQL Editor → New query → 이 파일 전체 붙여 넣기 → Run
--       → 결과 표 오른쪽 위 [Export] → [Download CSV] → 파일 이름 앞에 날짜를 붙여 구글 드라이브 'LMS 백업' 폴더에 보관
-- 결과: 표마다 한 줄 (표 이름 · 행 수 · 내용 JSON). 맨 위 _meta 줄에 백업 시각, _sequences 줄에 번호 순서,
--       _auth_users 줄에 로그인 계정 번호·이메일 (새 프로젝트로 복구할 때 계정 연결용)
-- 복구: Claude가 이 CSV로 복구 SQL을 만든다 (scripts/lms-restore-sql.mjs). 복구는 대표 승인 후에만
-- pg_temp = 이번 실행에서만 쓰는 임시 함수 (DB에 아무것도 남지 않음)
create or replace function pg_temp.lms_backup()
returns table (순서 int, 표 text, 행수 bigint, 내용 text)
language plpgsql as $$
declare
  r record;
  n bigint;
  j jsonb;
  i int := 0;
begin
  순서 := 0; 표 := '_meta';
  select count(*) into 행수 from pg_class c join pg_namespace s on s.oid = c.relnamespace where s.nspname = 'public' and c.relkind = 'r';
  내용 := jsonb_build_object('format', 'edge-lms-backup-1', 'at', now(), 'tables', 행수,
                            'students', (select count(*) from public.students))::text;
  return next;
  for r in select c.relname from pg_class c join pg_namespace s on s.oid = c.relnamespace
           where s.nspname = 'public' and c.relkind = 'r' order by c.relname loop
    execute format('select count(*), coalesce(jsonb_agg(to_jsonb(t)), ''[]''::jsonb) from public.%I t', r.relname) into n, j;
    i := i + 1; 순서 := i; 표 := r.relname; 행수 := n; 내용 := j::text;
    return next;
  end loop;
  순서 := i + 1; 표 := '_sequences';
  select count(*), coalesce(jsonb_object_agg(sequencename, last_value), '{}'::jsonb) into 행수, j
  from pg_sequences where schemaname = 'public';
  내용 := j::text;
  return next;
  순서 := i + 2; 표 := '_auth_users'; 행수 := 0; 내용 := '[]';
  if to_regclass('auth.users') is not null then
    execute 'select count(*), coalesce(jsonb_agg(jsonb_build_object(''id'', id, ''email'', email) order by email), ''[]''::jsonb) from auth.users'
      into 행수, j;
    내용 := j::text;
  end if;
  return next;
end $$;
select * from pg_temp.lms_backup() order by 순서;
