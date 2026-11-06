-- =====================================================================
-- 보낸 안내 기록 남기기 (2026-10-30 대표 시험: 한 수업만 '다시 고르기' 뒤 같은 강사를 다시 고르면 예전 보낸 문의 글에서 그 수업이 빠지고 번호가 바뀜)
--  - 원인: 다시 고르기·다시 묻기 때 보낸 안내를 not_needed 로 바꾸며 sent_at 을 지움 (새 안내를 만들려고, 한 수업·한 받는 사람에 살아 있는 안내는 하나)
--  - lesson_notices.was_sent_at: 보낸 안내가 보낼 필요 없음으로 바뀌어도 보낸 시각을 남김 → 화면이 보낸 원문·번호를 그대로 다시 만듦
--    '보냄 되돌리기'(sent → pending)는 보낸 기록이 아님 (남기지 않음)
--  - 이미 지워진 것은 변경 이력(audit_log)에서 채움 (새 칸만). 다시 실행해도 같은 결과
-- =====================================================================

alter table lesson_notices add column if not exists was_sent_at timestamptz;

create or replace function lesson_notices_keep_sent() returns trigger
language plpgsql as $$
begin
  if old.status = 'sent' and new.status = 'not_needed' then
    new.was_sent_at := coalesce(old.was_sent_at, old.sent_at);
  end if;
  return new;
end $$;
revoke all on function lesson_notices_keep_sent() from public, anon, authenticated;

drop trigger if exists lesson_notices_keep_sent on lesson_notices;
create trigger lesson_notices_keep_sent before update of status on lesson_notices
  for each row execute function lesson_notices_keep_sent();

-- 이미 지워진 보낸 시각: 변경 이력에서 '보냄 → 보낼 필요 없음'으로 바뀐 마지막 기록의 보낸 시각
update lesson_notices n set was_sent_at = h.sent_at
from (
  select distinct on (a.row_id) a.row_id, (a.old_row ->> 'sent_at')::timestamptz as sent_at
  from audit_log a
  where a.table_name = 'lesson_notices' and a.action = 'UPDATE'
    and a.old_row ->> 'status' = 'sent' and a.new_row ->> 'status' = 'not_needed' and a.old_row ->> 'sent_at' is not null
  order by a.row_id, a.at desc
) h
where n.id::text = h.row_id and n.status = 'not_needed' and n.was_sent_at is null;
