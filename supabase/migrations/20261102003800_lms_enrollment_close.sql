-- =====================================================================
-- 재등록 안 하는 학생 수강 종료 (2026-11-02 대표: 정O연 재등록 안내에 답 없음, 할 일에 계속 떠 있지 않게 직접 끄기)
--  - admin_enrollment_close: 운영자(TOTP)만. 수강기간이 끝났고 남은 예정 수업이 없는 수강권만 status 'completed'
--    → 대시보드 '수강기간 종료 임박'·'수강 중 학생'에서 빠짐. 학생·수업·결제 기록은 그대로(지우지 않음), 변경 이력은 audit_log
--  - p_undo = true: 'completed' → 'active' 되돌리기 (잘못 눌렀을 때)
--  - 다시 오면 재등록(새 수강권)으로 시작. 다시 실행해도 같은 결과
-- =====================================================================

create or replace function admin_enrollment_close(p_enrollment uuid, p_undo boolean default false)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  e enrollments;
begin
  if not is_admin() then raise exception '운영자(추가 인증 완료)만 처리할 수 있습니다.' using errcode = '42501'; end if;
  select * into e from enrollments where id = p_enrollment for update;
  if not found then raise exception '수강권을 찾을 수 없습니다.'; end if;
  perform set_config('app.actor_id', auth.uid()::text, true);
  perform set_config('app.actor_via', 'admin_enrollment_close', true);
  if p_undo then
    if e.status <> 'completed' then return jsonb_build_object('status', e.status, 'repeated', true); end if;
    update enrollments set status = 'active' where id = e.id;
    return jsonb_build_object('status', 'active', 'repeated', false);
  end if;
  if e.status = 'completed' then return jsonb_build_object('status', 'completed', 'repeated', true); end if;
  if e.status not in ('active', 'confirmed') then raise exception '수강 중인 수강권이 아닙니다.'; end if;
  if e.final_end_date >= (now() at time zone 'Asia/Seoul')::date then
    raise exception '수강기간이 아직 끝나지 않았습니다 (종료일 %).', e.final_end_date;
  end if;
  if exists (select 1 from lessons l where l.enrollment_id = e.id and l.state = 'scheduled' and l.voided_at is null and l.starts_at > now()) then
    raise exception '앞으로 남은 수업이 있어 종료할 수 없습니다.';
  end if;
  update enrollments set status = 'completed' where id = e.id;
  return jsonb_build_object('status', 'completed', 'repeated', false);
end $$;
revoke all on function admin_enrollment_close(uuid, boolean) from public, anon;
grant execute on function admin_enrollment_close(uuid, boolean) to authenticated;
