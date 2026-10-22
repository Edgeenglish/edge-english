-- migration 1200([보냈어요])·1300(기존 학생 간단 입력) 적용 확인 — 읽기만. 모든 줄이 '통과'면 정상
select 항목, case when ok then '통과' else '실패' end as 결과 from (
  select 1 as n, '[보냈어요] 기록 방식(manual) 허용' as 항목,
    exists (select 1 from pg_constraint where conname = 'schedule_notices_sent_via_check' and pg_get_constraintdef(oid) like '%manual%') as ok
  union all select 2, '[보냈어요] 함수가 manual 로 기록', (select prosrc from pg_proc where proname = 'admin_mark_notice_sent') like '%''manual''%'
  union all select 3, '수업 종류에 이관 보강 추가', exists (select 1 from pg_constraint where conname = 'lessons_kind_check' and pg_get_constraintdef(oid) like '%migrated_makeup%')
  union all select 4, '기존 학생 입력 함수: 운영자만 (로그인 안 한 사용자 불가)',
    has_function_privilege('authenticated', 'admin_import_existing_student(uuid, jsonb)', 'execute')
    and not has_function_privilege('anon', 'admin_import_existing_student(uuid, jsonb)', 'execute')
  union all select 5, '충돌 계산 내부 함수는 앱에서 직접 못 부름', not has_function_privilege('authenticated', 'lms_import_conflicts(jsonb)', 'execute')
  union all select 6, '기존 학생·수업 데이터 그대로 (표 41개)', (select count(*) from pg_tables where schemaname = 'public') = 41
) t order by n;
