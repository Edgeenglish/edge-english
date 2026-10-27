-- 운영 DB 표 만들기 확인 (읽기만). 결과 8줄이 모두 '통과'면 정상
select 항목, case when ok then '통과' else '실패' end as 결과 from (
  select 1 as n, 'LMS 표 45개' as 항목, (select count(*) from pg_tables where schemaname = 'public') = 45 as ok
  union all select 2, 'RLS 꺼진 표 없음', not exists (select 1 from pg_tables where schemaname = 'public' and not rowsecurity)
  union all select 3, '로그인 안 한 사용자(anon)가 읽을 수 있는 표 없음',
    not exists (select 1 from pg_class c join pg_namespace s on s.oid = c.relnamespace
                where s.nspname = 'public' and c.relkind in ('r', 'v') and has_table_privilege('anon', c.oid, 'select'))
  union all select 4, '기준 데이터: 상태값 14 · 판본 16 · 기능 스위치 5',
    (select count(*) from class_status_rules) = 14 and (select count(*) from terms_versions) = 16 and (select count(*) from feature_flags) = 5
  union all select 5, '최신 기능까지 (신규 배정 확정·운영자 TOTP)',
    to_regclass('public.schedule_plans') is not null and exists (select 1 from pg_proc where proname = 'is_owner')
  union all select 6, '서버 키 권한 (학생 표 읽기·쓰기)',
    not exists (select 1 from pg_roles where rolname = 'service_role') or has_table_privilege('service_role', 'public.students', 'insert')
  union all select 7, '빈 운영 DB (학생·강사·수업 0, 가상 데이터 없음)',
    (select count(*) from students) = 0 and (select count(*) from tutors) = 0 and (select count(*) from lessons) = 0
  union all select 8, '프로젝트 이름 = edgeenglish-lms (복구 안전장치)',
    to_regclass('lms_backup.project') is not null and (select name from lms_backup.project) = 'edgeenglish-lms'
) t order by n;
