-- =====================================================================
-- 운영진 적립금 넣기·빼기 (2026-11-08 대표 결정: 시트 이관분·시스템 실수 보상·적립금 사용 차감용)
--  admin_reward_adjust(요청 번호, 학생, 금액(+넣기 / -빼기), 사유)
--  - 운영자(추가 인증)만. 사유 필수(200자까지). 금액 0 불가. 잔액이 0 아래로 내려가면 막힘(기존 reward_ledger_guard)
--  - 넣기 = reward_ledger 'grant_admin', 빼기 = 'admin_adjust' (DB 에 이미 있던 종류, 사유 필수 검사도 이미 있음)
--  - 같은 요청 번호로 다시 실행하면 처음 결과를 그대로 돌려줌 (registration_requests 에 결과 보관)
--  - 강사 늦은 취소 2,000원 자동 적립(lms_change_core)은 그대로 (대표 11/8: 켜 둠)
-- =====================================================================
create or replace function admin_reward_adjust(p_request_id uuid, p_student uuid, p_amount integer, p_reason text)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  prev jsonb;
  v_reason text := nullif(btrim(coalesce(p_reason, '')), '');
  v_before integer;
  v_enr uuid;
  res jsonb;
begin
  if not is_admin() then raise exception '운영자(추가 인증 완료)만 처리할 수 있습니다.' using errcode = '42501'; end if;
  if p_request_id is null then raise exception '요청 번호가 없습니다.'; end if;
  perform pg_advisory_xact_lock(hashtextextended(p_request_id::text, 0));
  select result into prev from registration_requests where id = p_request_id;
  if found then return prev || '{"repeated": true}'::jsonb; end if;
  if not exists (select 1 from students where id = p_student) then raise exception '학생을 찾을 수 없습니다.'; end if;
  if p_amount is null or p_amount = 0 then raise exception '금액을 넣어 주세요.' using hint = 'amount'; end if;
  if v_reason is null then raise exception '사유를 적어 주세요.' using hint = 'reason'; end if;
  if char_length(v_reason) > 200 then raise exception '사유는 200자까지 적을 수 있습니다.' using hint = 'reason'; end if;
  v_enr := lms_student_enrollment(p_student);
  if v_enr is null then raise exception '이 학생은 수강권이 없습니다.'; end if;

  v_before := reward_balance(p_student);
  perform set_config('app.actor_id', me::text, true);
  perform set_config('app.actor_via', 'admin_reward_adjust', true);
  begin
    insert into reward_ledger (student_id, kind, amount, note, created_by)
    values (p_student, case when p_amount > 0 then 'grant_admin' else 'admin_adjust' end, p_amount, v_reason, me);
  exception when raise_exception then
    raise exception '적립금 잔액(%원)보다 많이 뺄 수 없습니다.', v_before using hint = 'balance';
  end;

  res := jsonb_build_object('student_id', p_student, 'amount', p_amount, 'before', v_before, 'after', v_before + p_amount, 'reason', v_reason);
  insert into registration_requests (id, created_by, student_id, enrollment_id, result)
  values (p_request_id, me, p_student, v_enr, res);
  return res;
end $$;

revoke all on function admin_reward_adjust(uuid, uuid, integer, text) from public, anon;
grant execute on function admin_reward_adjust(uuid, uuid, integer, text) to authenticated;
