-- migration 1800(강사 휴무·대체강사) 적용 확인 — 읽기만. 5줄 모두 '통과'면 정상
select 항목, case when ok then '통과' else '실패' end as 결과 from (
  select 1 as n, '휴무 처리 함수는 로그인 사용자만 (운영자 확인은 함수 안에서)' as 항목,
    has_function_privilege('authenticated', 'admin_leave_create(uuid, date, date, text, boolean)', 'execute')
    and has_function_privilege('authenticated', 'admin_leave_choose(uuid[], text, uuid)', 'execute')
    and has_function_privilege('authenticated', 'admin_leave_student_ok(uuid[])', 'execute')
    and not has_function_privilege('anon', 'admin_leave_create(uuid, date, date, text, boolean)', 'execute')
    and not has_function_privilege('authenticated', 'lms_leave_sync_extension(uuid)', 'execute') as ok
  union all select 2, '휴무 처리 목록 표 (운영자만 읽기, 지울 수 없음)',
    to_regclass('public.leave_items') is not null
    and (select relrowsecurity from pg_class where oid = 'public.leave_items'::regclass)
    and exists (select 1 from pg_trigger where tgname = 'leave_items_no_delete')
  union all select 3, '대체강사 안내 기록 (가능 확인·학생 안내·확정)',
    exists (select 1 from information_schema.columns where table_name = 'lesson_notices' and column_name = 'leave_item_id')
    and exists (select 1 from pg_constraint where conname = 'lesson_notices_leave_events')
  union all select 4, '휴무 보강 자동 연장 (마지막 보강일까지만)',
    exists (select 1 from pg_trigger where tgname = 'lessons_leave_extension')
    and exists (select 1 from information_schema.columns where table_name = 'enrollment_extensions' and column_name = 'auto_source')
  union all select 5, '기존 학생·수업 데이터 그대로 (표 45개 이상)', (select count(*) from pg_tables where schemaname = 'public') >= 45
) t order by n;
