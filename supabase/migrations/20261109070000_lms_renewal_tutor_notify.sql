-- =====================================================================
-- 재등록 강사 통보 한 번으로 끝내기 (대표 2026-11-09 A안, 송O나 STU-0004 카드 — 시험 DB 먼저, 운영 미반영)
--  - '강사 확인 대신 기록'·'일정 조치 완료' 단계 없앰 (강사 화면 [확인] 버튼이 없어 운영진이 대신 누르기만 하던 단계)
--  - 새 수강권 일정이 확정돼 있으면(일정 확정 화면에서 강사·요일·시간 확정 = 수업이 만들어짐) [강사에게 통보] 한 번으로
--    통보 기록 + 업무 완료(status done) → 운영진 할 일에서 빠짐
--  - 일정이 아직 확정 안 됐으면(강사 변경·일정 조정 등) 통보 거절 → 카드에 '새 기간 일정 확정'이 먼저 남음
--  - 강사 변경 예정 표시(tutor_change_planned)인데 확정 일정 강사가 그대로면 거절
--  - 완료 조건(DB 검사): 강사·통보 시각·일정 확정 시각(schedule_checked_at = 확정 일정 시각). 강사 확인 시각은 더 요구하지 않음
--  - POL-OP-14 변경 필요 (정책 원본 수정은 대표 승인 뒤). 기존 데이터 변경 없음. 다시 실행해도 같은 결과
-- =====================================================================
do $$
declare c record;
begin
  for c in select conname from pg_constraint where conrelid = 'admin_tasks'::regclass and contype = 'c'
             and pg_get_constraintdef(oid) like '%renewal_tutor_notice%' and pg_get_constraintdef(oid) like '%tutor_acknowledged_at%'
  loop
    execute format('alter table admin_tasks drop constraint %I', c.conname);
  end loop;
  if not exists (select 1 from pg_constraint where conname = 'admin_tasks_renewal_done') then
    alter table admin_tasks add constraint admin_tasks_renewal_done
      check (status <> 'done' or kind <> 'renewal_tutor_notice'
             or (tutor_id is not null and tutor_notified_at is not null and schedule_checked_at is not null));
  end if;
end $$;

create or replace function admin_renewal_notify_tutor(p_task uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  t admin_tasks;
  pl schedule_plans;
begin
  if not is_admin() then raise exception '운영자(추가 인증 완료)만 처리할 수 있습니다.' using errcode = '42501'; end if;
  select * into t from admin_tasks where id = p_task and kind = 'renewal_tutor_notice' for update;
  if not found then raise exception '재등록 업무가 없습니다.'; end if;
  if t.status = 'done' then return jsonb_build_object('task_id', t.id, 'repeated', true); end if;
  if t.status <> 'open' then raise exception '닫힌 업무입니다.'; end if;
  select * into pl from schedule_plans where enrollment_id = t.enrollment_id and state = 'confirmed' order by confirmed_at desc limit 1;
  if not found then raise exception '새 기간 일정을 먼저 확정해 주세요.' using hint = 'schedule_first'; end if;
  if t.tutor_change_planned and pl.tutor_id is not distinct from t.tutor_id then
    raise exception '강사 변경 예정이에요. 새 강사로 일정을 먼저 확정해 주세요.' using hint = 'schedule_first';
  end if;
  perform set_config('app.actor_id', coalesce(me::text, ''), true);
  perform set_config('app.actor_via', 'admin_renewal_notify_tutor', true);
  update admin_tasks set tutor_id = pl.tutor_id, tutor_notified_at = coalesce(tutor_notified_at, now()),
         schedule_checked_at = coalesce(schedule_checked_at, pl.confirmed_at, now()),
         status = 'done', done_at = now(), done_by = me
  where id = t.id;
  return jsonb_build_object('task_id', t.id, 'repeated', false);
end $$;
revoke all on function admin_renewal_notify_tutor(uuid) from public, anon;
grant execute on function admin_renewal_notify_tutor(uuid) to authenticated;
