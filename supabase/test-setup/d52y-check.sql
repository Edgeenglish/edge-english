-- migration 1600(기존 학생 입력 시안 2) 적용 확인 — 읽기만. 4줄 모두 '통과'면 정상
select 항목, case when ok then '통과' else '실패' end as 결과 from (
  select 1 as n, '정규 수업은 28일 기간 계산 끝까지만 (연장된 날 정규 없음)' as 항목,
    to_regprocedure('lms_import_regular_end(jsonb)') is not null
    and (select prosrc from pg_proc where proname = 'lms_import_candidates') like '%lms_import_regular_end%' as ok
  union all select 2, '늘어난 종료일은 연장 기록으로 (이유 포함)',
    (select prosrc from pg_proc where proname = 'admin_import_existing_student') like '%enrollment_extensions%'
    and exists (select 1 from information_schema.columns where table_name = 'import_checks' and column_name = 'end_reason')
  union all select 3, '종료일 이유 미선택은 처리할 일로 남고 운영자만 해결 · 강사 휴가 보강 표시',
    has_function_privilege('authenticated', 'admin_import_set_end_reason(uuid, text, text)', 'execute')
    and not has_function_privilege('anon', 'admin_import_set_end_reason(uuid, text, text)', 'execute')
    and exists (select 1 from information_schema.columns where table_name = 'migrated_items' and column_name = 'tutor_leave')
  union all select 4, '기존 학생·수업 데이터 그대로 (표 43개 이상)', (select count(*) from pg_tables where schemaname = 'public') >= 43
) t order by n;
