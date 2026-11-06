-- migration 1700(수업 변경·보강·되돌리기·안내 기록) 적용 확인 — 읽기만. 5줄 모두 '통과'면 정상
select 항목, case when ok then '통과' else '실패' end as 결과 from (
  select 1 as n, '변경·되돌리기·보강 처리 함수는 로그인 사용자만' as 항목,
    has_function_privilege('authenticated', 'admin_change_lesson(uuid, uuid, text, timestamptz, boolean)', 'execute')
    and has_function_privilege('authenticated', 'admin_revert_change(uuid, text)', 'execute')
    and has_function_privilege('authenticated', 'admin_makeup_confirm(uuid, timestamptz)', 'execute')
    and not has_function_privilege('anon', 'admin_change_lesson(uuid, uuid, text, timestamptz, boolean)', 'execute')
    and not has_function_privilege('authenticated', 'lms_change_core(text, uuid, text, text, timestamptz, boolean, uuid)', 'execute') as ok
  union all select 2, '변경권·적립금은 요청 1건당 1번 (되돌린 뒤 다시 변경 가능)',
    to_regclass('public.credit_ledger_once_per_request') is not null and to_regclass('public.reward_ledger_once_per_request') is not null
    and not exists (select 1 from pg_constraint where conname = 'credit_ledger_lesson_id_reason_key')
    and to_regclass('public.reward_ledger_one_grant_per_lesson') is null
  union all select 3, '같은 수업에 적용 중인 변경 1건 · 카톡 받은 시각 칸',
    to_regclass('public.change_requests_one_applied') is not null
    and exists (select 1 from information_schema.columns where table_name = 'change_requests' and column_name = 'requested_at')
  union all select 4, '안내 기록 표 (학생·강사 각각 [보냈어요])',
    to_regclass('public.lesson_notices') is not null
    and (select relrowsecurity from pg_class where oid = 'public.lesson_notices'::regclass)
  union all select 5, '기존 학생·수업 데이터 그대로 (표 44개 이상)', (select count(*) from pg_tables where schemaname = 'public') >= 44
) t order by n;
