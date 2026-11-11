-- 재등록 안내 자동 메일이 정상 발송된 수강권 목록 (대표 11/11: 안내 메일이 나갔으면 대시보드 '수강기간 종료 임박' 카드에 안 뜨게)
--  - renewal_notices(문자 [보냄])에는 넣지 않음: 그러면 뒤 단계 자동 메일(lms_renewal_mail_due)이 멈춤
--  - 운영자(추가 인증 완료)만 읽음. 읽기만 하는 함수, 다시 실행해도 같은 결과
create or replace function admin_renewal_mail_sent()
returns table (enrollment_id uuid, sent_at timestamptz)
language sql stable security definer set search_path = public as $$
  select split_part(n.dedupe_key, ':', 2)::uuid, max(n.sent_at)
  from notifications n
  where is_admin() and n.dedupe_key like 'renewal_mail:%' and n.status = 'sent'
  group by 1
$$;
revoke all on function admin_renewal_mail_sent() from public, anon;
grant execute on function admin_renewal_mail_sent() to authenticated;
