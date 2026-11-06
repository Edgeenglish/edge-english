-- 운영 프로젝트가 비어 있는지 확인 (읽기만). 정상 결과: 표_개수 0
-- 0이 아니면 멈추고 Claude에게 (시험용 프로젝트에 잘못 들어왔을 수 있음 — 시험용은 41)
select count(*) as 표_개수 from pg_tables where schemaname = 'public';
