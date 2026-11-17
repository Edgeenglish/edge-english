-- =====================================================================
-- 자동 메일을 못 보낸 안내는 '할 일 아님(not_needed)' 줄이어도 운영진이 직접 보낸 뒤 [보냄]으로 닫을 수 있게 (대표 11/15, H26(102) 보충)
--  - 강사 줄은 넣을 때부터 not_needed(20261111120000) → 메일이 실패·주소 없음이면 '자동 메일 못 보냄' 카드가 떠도 [보냄]이 거절됐음
--  - 기준: [메일 다시 보내기] 성공 → 메일 상태 sent 로 카드 자동 종료 / WhatsApp·카톡으로 직접 안내 → [보냄] / 아무것도 안 함 → 실패 카드 유지
--  - [보냄]은 안내 줄 status 만 sent(sent_by = 운영자)로 바꾸고 email_status 는 그대로(실패 기록 유지 — 메일을 보낸 것처럼 보이지 않게)
--  - 허용: not_needed 이면서 메일 실패(failed)·주소 없음(no_address)·대기 중 오류(queued + email_error), 강사 휴무 줄(leave_item_id) 제외
--  - 그 밖의 not_needed 는 지금처럼 거절. 넣기만, 다시 실행해도 같은 결과
-- 되돌리기: 20261026001700 · 20261030003300 의 두 함수 정의를 그대로 다시 실행
-- =====================================================================
create or replace function lms_notice_mail_failed(n lesson_notices) returns boolean
language sql stable as $$
  select n.leave_item_id is null
     and (n.email_status in ('failed', 'no_address') or (n.email_status = 'queued' and n.email_error is not null))
$$;
revoke all on function lms_notice_mail_failed(lesson_notices) from public, anon, authenticated;

create or replace function admin_mark_lesson_notice_sent(p_notice uuid)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  n lesson_notices;
begin
  if not is_admin() then raise exception '운영자(추가 인증 완료)만 기록할 수 있습니다.' using errcode = '42501'; end if;
  select * into n from lesson_notices where id = p_notice for update;
  if not found then raise exception '안내가 없습니다.'; end if;
  if n.status = 'not_needed' and not lms_notice_mail_failed(n) then raise exception '보낼 필요가 없어진 안내입니다.'; end if;
  if n.status <> 'sent' then
    perform set_config('app.actor_id', me::text, true);
    perform set_config('app.actor_via', 'admin_mark_lesson_notice_sent', true);
    update lesson_notices set status = 'sent', sent_at = now(), sent_by = me where id = p_notice;
  end if;
  return jsonb_build_object('notice_id', p_notice, 'repeated', n.status = 'sent');
end $$;
revoke all on function admin_mark_lesson_notice_sent(uuid) from public, anon;
grant execute on function admin_mark_lesson_notice_sent(uuid) to authenticated;

create or replace function admin_mark_lesson_notices_sent(p_notices uuid[])
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  n lesson_notices;
  v_changed integer := 0;
begin
  if not is_admin() then raise exception '운영자(추가 인증 완료)만 기록할 수 있습니다.' using errcode = '42501'; end if;
  perform set_config('app.actor_id', me::text, true);
  perform set_config('app.actor_via', 'admin_mark_lesson_notices_sent', true);
  for n in select * from lesson_notices where id = any(p_notices) order by id for update loop
    if n.status = 'not_needed' and not lms_notice_mail_failed(n) then raise exception '보낼 필요가 없어진 안내가 있습니다. 화면을 새로 고쳐 주세요.'; end if;
    if n.status <> 'sent' then
      update lesson_notices set status = 'sent', sent_at = now(), sent_by = me where id = n.id;
      v_changed := v_changed + 1;
    end if;
  end loop;
  return jsonb_build_object('changed', v_changed);
end $$;
revoke all on function admin_mark_lesson_notices_sent(uuid[]) from public, anon;
grant execute on function admin_mark_lesson_notices_sent(uuid[]) to authenticated;
