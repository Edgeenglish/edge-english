-- =====================================================================
-- 안내 메일이 정상 발송(email_status='sent')되면 그 안내 줄도 '보냄'으로 (대표 11/11)
--  - 운영진 대시보드 '○○ 안내 보내기' 카드는 lesson_notices.status='pending' 만 센다.
--    메일이 이미 나갔는데도 pending 으로 남아 카드가 계속 떠 있었음.
--  - 메일 발송 결과를 맞추는 함수(lms_mail_run)·강사 통보 메일이 email_status 를 'sent' 로 바꿀 때
--    같은 줄이 pending 이면 sent(sent_at = 메일 보낸 시각, sent_by 없음 = 시스템)로 같이 바꿈.
--  - 실패(failed)·주소 없음(no_address)은 그대로 pending → 카드 유지 (운영진이 직접 보내고 [보냄]).
--  - 지금 떠 있는 것: 메일이 이미 sent 인 pending 줄을 한 번 sent 로 정리 (넣기만, 다시 실행해도 같은 결과)
-- =====================================================================
create or replace function lesson_notices_mail_sent_done() returns trigger
language plpgsql as $$
begin
  if new.email_status = 'sent' and new.status = 'pending' then
    new.status := 'sent';
    new.sent_at := coalesce(new.email_sent_at, now());
  end if;
  return new;
end $$;
revoke all on function lesson_notices_mail_sent_done() from public, anon, authenticated;

drop trigger if exists lesson_notices_mail_sent_done on lesson_notices;
create trigger lesson_notices_mail_sent_done before update of email_status, email_sent_at on lesson_notices
  for each row execute function lesson_notices_mail_sent_done();

update lesson_notices
set status = 'sent', sent_at = coalesce(email_sent_at, now())
where status = 'pending' and email_status = 'sent';
