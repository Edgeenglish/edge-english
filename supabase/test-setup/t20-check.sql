-- migration 2000(강사 LMS: 수업 일정·Class Record 입력·보강 가능 여부 답) 적용 확인 — 읽기만. 4줄 모두 '통과'면 정상
select 항목, case when ok then '통과' else '실패' end as 결과 from (
  select 1 as n, '강사 화면 함수는 로그인 사용자만 (본인 강사·운영자 확인은 함수 안에서)' as 항목,
    has_function_privilege('authenticated', 'tutor_screen(uuid, date, date)', 'execute')
    and exists (select 1 from pg_proc where proname = 'tutor_record_class' and has_function_privilege('authenticated', oid, 'execute'))   -- 3000에서 인자 하나 늘어남
    and has_function_privilege('authenticated', 'tutor_makeup_answer(uuid, uuid[], text)', 'execute')
    and has_function_privilege('authenticated', 'admin_tutor_accounts()', 'execute')
    and has_function_privilege('authenticated', 'admin_class_record_missing()', 'execute')
    and not has_function_privilege('anon', 'tutor_screen(uuid, date, date)', 'execute')
    and not has_function_privilege('authenticated', 'lms_screen_tutor(uuid)', 'execute') as ok
  union all select 2, '보강 시간별 강사 답 칸 (가능/불가·답한 시각)',
    exists (select 1 from information_schema.columns where table_name = 'makeup_candidates' and column_name = 'tutor_answer')
    and exists (select 1 from information_schema.columns where table_name = 'makeup_requests' and column_name = 'tutor_answered_at')
    and exists (select 1 from pg_constraint where conname = 'makeup_candidates_answer_check')
  union all select 3, '수업 기록 표 그대로 (첫 기록 시각 유지·지울 수 없음)',
    exists (select 1 from pg_trigger where tgname = 'class_records_keep_first')
    and exists (select 1 from pg_trigger where tgname = 'class_records_no_delete')
  union all select 4, '기존 학생·수업 데이터 그대로 (표 45개 이상)', (select count(*) from pg_tables where schemaname = 'public') >= 45
) t order by n;
