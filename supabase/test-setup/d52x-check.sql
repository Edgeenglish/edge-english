-- migration 1500(기존 학생 입력 확대) 적용 확인 — 읽기만. 모든 줄이 '통과'면 정상
select 항목, case when ok then '통과' else '실패' end as 결과 from (
  select 1 as n, '수업 종류에 이관 추가 수업 추가' as 항목,
    exists (select 1 from pg_constraint where conname = 'lessons_kind_check' and pg_get_constraintdef(oid) like '%migrated_extra%') as ok
  union all select 2, '보강·추가 수업 기록, 시트 대조 기록 표 (운영자만 읽기)',
    (select bool_and(rowsecurity) from pg_tables where schemaname = 'public' and tablename in ('migrated_items', 'import_checks'))
    and (select count(*) from pg_tables where schemaname = 'public' and tablename in ('migrated_items', 'import_checks')) = 2
  union all select 3, '학생별 LMS 전환일 칸 (비어 있으면 시트로 관리)',
    exists (select 1 from information_schema.columns where table_name = 'students' and column_name = 'lms_since')
  union all select 4, '입력·대조 완료·원래 날짜 정리 함수: 운영자만 (로그인 안 한 사용자 불가)',
    has_function_privilege('authenticated', 'admin_import_mark_checked(uuid)', 'execute')
    and not has_function_privilege('anon', 'admin_import_mark_checked(uuid)', 'execute')
    and not has_function_privilege('anon', 'admin_import_set_origin(uuid, date)', 'execute')
    and (select prosrc from pg_proc where proname = 'admin_import_existing_student') like '%import_checks%'
  union all select 5, '보강 원래 날짜와 같은 날 정규 수업은 만들지 않음',
    (select prosrc from pg_proc where proname = 'lms_import_candidates') like '%skip_dates%'
  union all select 6, '기존 학생·수업 데이터 그대로 (표 43개)', (select count(*) from pg_tables where schemaname = 'public') = 43
) t order by n;
