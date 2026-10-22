-- migration 1000 (신규 배정 확정) 적용 확인 — 읽기만. 모든 줄이 '통과'면 정상
select '1. 일정안·안내 표' as 항목, case when (select count(*) from information_schema.tables where table_schema = 'public' and table_name in ('schedule_plans', 'schedule_notices')) = 2 then '통과' else '실패' end as 결과
union all select '2. 확정·기록 함수 5개', case when (select count(*) from pg_proc where proname in ('admin_propose_schedule', 'admin_confirm_schedule', 'admin_close_plan', 'admin_mark_proposal_sent', 'admin_mark_notice_sent')) = 5 then '통과' else '실패' end
union all select '3. 강사 안내 없이 매칭 완료 금지', case when exists (select 1 from pg_constraint where conname = 'admin_tasks_matching_tutor_notified') then '통과' else '실패' end
union all select '4. 등록 함수가 일정안을 만듦', case when (select prosrc from pg_proc where proname = 'admin_register_student') like '%lms_new_plan%' then '통과' else '실패' end
union all select '5. 앱 사용자는 발송 결과 직접 기록 불가', case when not has_function_privilege('authenticated', 'lms_notice_result(uuid, text, text)', 'execute') then '통과' else '실패' end
union all select '6. 기존 학생 데이터 그대로 (6명)', case when (select count(*) from students) = 6 then '통과' else '확인 필요' end;
