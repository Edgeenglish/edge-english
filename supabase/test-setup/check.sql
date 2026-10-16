-- 시험용 Supabase 적용 확인 (읽기만 함). 결과 표의 result 가 모두 '통과'면 정상
select item, case when ok then '통과' else '실패' end as result from (
  select 'LMS 표 개수 (30개 이상)' as item, count(*) >= 30 as ok
    from information_schema.tables where table_schema = 'public' and table_type = 'BASE TABLE'
  union all
  select 'RLS 꺼진 LMS 표 없음', not exists (
    select 1 from pg_tables where schemaname = 'public' and not rowsecurity)
  union all
  select 'btree_gist 확장 설치됨', exists (select 1 from pg_extension where extname = 'btree_gist')
  union all
  select '상태값 14개', (select count(*) from class_status_rules) = 14
  union all
  select '가상 데이터: 열린 업무 4건 이상', (select count(*) from admin_task_board) >= 4
  union all
  select '실제처럼 보이는 학생 없음 (모두 가상)', not exists (select 1 from students where name_ko not like '가상%')
) t;
