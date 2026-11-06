-- =====================================================================
-- 종료 임박 카드: 재등록 안내 [보냄] 기록 (2026-10-28 대표: 당분간 문자로 안내 → 문자 복사 + 누른 버튼은 회색으로 남게)
--  - 수강권 1개당 1줄. 한 번 보냄으로 기록하면 그대로 (다시 눌러도 같은 결과, 지우지 않음)
--  - 카드는 지금처럼 재등록 결제가 확인되면 빠짐 (POL-RN-08). 이 기록은 '보냄 ✓' 표시에만 씀
-- 기존 표·데이터를 지우지 않음. 다시 실행해도 같은 결과
-- =====================================================================

create table if not exists renewal_notices (
  id uuid primary key default gen_random_uuid(),
  enrollment_id uuid not null unique references enrollments(id),
  sent_at timestamptz not null default now(),
  sent_by uuid
);
do $$
begin
  if not exists (select 1 from pg_trigger where tgname = 'renewal_notices_audit') then
    perform lms_protect('renewal_notices'::regclass);
    create trigger renewal_notices_no_delete before delete on renewal_notices for each row execute function forbid_delete();
  end if;
end $$;

create or replace function admin_renewal_notice_sent(p_enrollment uuid)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  r renewal_notices;
begin
  if not is_admin() then raise exception '운영자(추가 인증 완료)만 기록할 수 있습니다.' using errcode = '42501'; end if;
  if not exists (select 1 from enrollments where id = p_enrollment) then raise exception '수강등록을 찾지 못했습니다.'; end if;
  perform set_config('app.actor_id', me::text, true);
  perform set_config('app.actor_via', 'admin_renewal_notice_sent', true);
  insert into renewal_notices (enrollment_id, sent_by) values (p_enrollment, me) on conflict (enrollment_id) do nothing;
  select * into r from renewal_notices where enrollment_id = p_enrollment;
  return jsonb_build_object('sent_at', r.sent_at);
end $$;
revoke all on function admin_renewal_notice_sent(uuid) from public, anon;
grant execute on function admin_renewal_notice_sent(uuid) to authenticated;
