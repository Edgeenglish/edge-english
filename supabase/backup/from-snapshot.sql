-- 복구 직전 저장본 꺼내기 — 읽기만 함. 복구를 잘못했을 때, 그 복구 바로 전 상태를 백업 CSV와 같은 모양으로 꺼냄
-- 사용: SQL Editor → 실행 → [Export] → [Download CSV] → Claude가 이 파일로 다시 복구 SQL을 만듦 (대표 승인 후)
-- 기본은 가장 최근 저장본. 다른 것은 아래 order by 대신 where id = 번호
with s as (select id, backup from lms_backup.snapshots order by id desc limit 1)
select case when e.key = '_meta' then 0 when e.key = '_sequences' then 1000 else 1 end as 순서,
       e.key as 표,
       case when jsonb_typeof(e.value) = 'array' then jsonb_array_length(e.value) else 0 end as 행수,
       e.value::text as 내용
from s, jsonb_each(s.backup) e
order by 순서, 표;
