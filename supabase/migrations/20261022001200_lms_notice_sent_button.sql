-- =====================================================================
-- 최종 안내: [복사] ≠ 보냄 → 운영자가 [보냈어요]를 눌러야 '보냄' (2026-10-22 대표 승인, 정책 원본 A39(2) 갱신)
--  - 화면의 [복사]는 문구를 클립보드에 넣기만 하고 아무것도 기록하지 않는다
--  - [보냈어요] = admin_mark_notice_sent → 그 받는 사람(학생 또는 강사)만 '보냄' (sent_via = 'manual')
--  - 학생·강사 둘 다 '보냄'이어야 신규 매칭 업무 완료. 한쪽이라도 아니면 처리할 일에 계속 남음 (lms_finish_matching, 그대로)
--  - 예전 방식으로 기록된 행(sent_via = 'copy', 시험용 DB)은 그대로 둠
-- 기존 표·데이터를 지우지 않음. 다시 실행해도 같은 결과
-- =====================================================================

do $$
begin
  if exists (select 1 from pg_constraint where conname = 'schedule_notices_sent_via_check'
             and pg_get_constraintdef(oid) not like '%manual%') then
    alter table schedule_notices drop constraint schedule_notices_sent_via_check;
  end if;
  if not exists (select 1 from pg_constraint where conname = 'schedule_notices_sent_via_check') then
    alter table schedule_notices add constraint schedule_notices_sent_via_check
      check (sent_via in ('copy', 'manual', 'system'));   -- copy = 예전(복사 = 보냄), manual = [보냈어요], system = 자동 발송기
  end if;
end $$;

-- [보냈어요] = 그쪽 안내 보냄. 이미 보낸 건은 그대로(시각 안 바뀜). 양쪽 다 보내면 매칭 업무 완료
create or replace function admin_mark_notice_sent(p_notice_id uuid)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  nt record;
  done boolean;
begin
  if not is_admin() then raise exception '운영자(추가 인증 완료)만 기록할 수 있습니다.' using errcode = '42501'; end if;
  select n.*, p.state as plan_state into nt from schedule_notices n join schedule_plans p on p.id = n.plan_id where n.id = p_notice_id for update of n;
  if not found then raise exception '안내가 없습니다.'; end if;
  if nt.plan_state <> 'confirmed' then raise exception '확정된 일정의 안내가 아닙니다.'; end if;
  perform set_config('app.actor_id', me::text, true);
  perform set_config('app.actor_via', 'admin_mark_notice_sent', true);
  if nt.status <> 'sent' then
    update schedule_notices set status = 'sent', sent_at = now(), sent_by = me, sent_via = 'manual',
                                attempts = attempts + 1, last_attempt_at = now()
    where id = p_notice_id;
  end if;
  done := lms_finish_matching(nt.plan_id, me);
  return jsonb_build_object('notice_id', p_notice_id, 'status', 'sent', 'repeated', nt.status = 'sent', 'all_sent', done);
end $$;
