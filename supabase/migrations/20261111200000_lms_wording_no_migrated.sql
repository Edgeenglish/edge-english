-- =====================================================================
-- 화면 문구: 사용자에게 보이는 글에 '이관' 표현을 쓰지 않음 (대표 11/11 — '보강 수업'·'보강'으로)
--  admin_void_makeup 오류 문구만 바꿈. 동작·표·데이터는 그대로 (20261102100000 과 같은 함수 본문)
-- =====================================================================

create or replace function admin_void_makeup(p_lesson uuid, p_note text)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  l lessons;
  r makeup_requests;
begin
  if not is_admin() then raise exception '운영자(추가 인증 완료)만 처리할 수 있습니다.' using errcode = '42501'; end if;
  select * into l from lessons where id = p_lesson for update;
  if not found or l.kind not in ('makeup', 'migrated_makeup', 'compensation') then raise exception '보강 수업이 아닙니다.'; end if;
  if l.voided_at is not null then return jsonb_build_object('lesson_id', l.id, 'repeated', true); end if;
  if l.state <> 'scheduled' then raise exception '이미 진행·변경된 보강입니다.'; end if;
  select * into r from makeup_requests where confirmed_lesson_id = l.id;
  if not found then raise exception '보강 신청 기록이 없는 보강입니다 (시트에서 확인해 주세요).'; end if;
  perform set_config('app.actor_id', me::text, true);
  perform set_config('app.actor_via', 'admin_void_makeup', true);
  update lessons set state = 'canceled', canceled_at = now(), voided_at = now(), voided_by = me, void_note = nullif(trim(p_note), '')
  where id = l.id;
  update makeup_requests set status = 'voided', decided_at = now(), decided_by = me where id = r.id;
  if r.migrated_item_id is not null then
    update migrated_items set kind = 'makeup_open', lesson_id = null where id = r.migrated_item_id;
  end if;
  if l.kind = 'compensation' then
    update compensations set status = 'available', used_lesson_id = null where id = l.compensation_id and used_lesson_id = l.id;
  end if;
  update lesson_notices set status = 'not_needed' where makeup_request_id = r.id and event = 'makeup_confirmed' and status = 'pending';
  insert into lesson_notices (makeup_request_id, event, recipient_kind, recipient_id)
  select r.id, 'makeup_voided', n.recipient_kind, n.recipient_id from lesson_notices n
  where n.makeup_request_id = r.id and n.event = 'makeup_confirmed' and n.status = 'sent'
  on conflict do nothing;
  return jsonb_build_object('lesson_id', l.id, 'repeated', false);
end $$;
revoke all on function admin_void_makeup(uuid, text) from public, anon;
grant execute on function admin_void_makeup(uuid, text) to authenticated;
