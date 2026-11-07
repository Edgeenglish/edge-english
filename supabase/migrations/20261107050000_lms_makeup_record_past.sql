-- =====================================================================
-- 운영진 '이미 진행한 보강 기록' (2026-11-07 대표 결정 '1번으로 해', 정책 원본 H26(81) 강사 자율 운영 5단계의 운영진용 첫 부분)
--  계기: 강사가 더블 수업 등으로 보강을 먼저 진행했는데 LMS 에 그 보강이 없음 → 학생 화면에 '보강 날짜 고르기'가 계속 남음.
--  지금까지는 지난 시각으로 보강을 넣는 길이 없었음 (admin_makeup_request·admin_makeup_confirm 은 '지난 시간' 거절)
--  하는 일: 보강 받을 권리(취소된 수업 또는 이관 미예약 보강) 하나에 '이미 지난 시각'의 보강 수업을 만든다.
--   - 수업은 예정(scheduled) 상태로 만들어 강사 Class Record '기록할 수업'에 뜸 → 강사가 Held 등으로 기록 (급여·출결은 기존 그대로)
--   - 보강 신청 기록도 확정으로 남김(열린 신청이 있으면 그 신청을 확정). 이미 지난 일이라 학생·강사 안내 할 일은 만들지 않음
--   - 사유 필수. 시각 검사: 지금보다 이전, 같은 학생·강사 수업과 겹치면 거절(DB 겹침 금지). 강사 가능 시간·휴식 규칙은 보지 않음(이미 진행한 수업)
--   - 보상수업(강사 노쇼 보상권)은 이 함수로 하지 않음
--  다시 실행해도 같은 결과. 지우는 문장 없음
-- =====================================================================
create or replace function admin_makeup_record_past(p_lesson uuid, p_item uuid, p_starts_at timestamptz, p_note text)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  s record;
  e enrollments;
  v_note text := nullif(trim(coalesce(p_note, '')), '');
  v_end timestamptz;
  v_req uuid;
  v_lesson uuid;
begin
  if not is_admin() then raise exception '운영자(추가 인증 완료)만 처리할 수 있습니다.' using errcode = '42501'; end if;
  if p_starts_at is null or p_starts_at >= now() then raise exception '이미 지난 시각만 기록할 수 있습니다. 앞으로의 보강은 보강 신청으로 잡아 주세요.'; end if;
  if v_note is null then raise exception '사유를 적어 주세요.'; end if;
  select * into s from lms_makeup_source(p_lesson, p_item);   -- 보강 받을 권리가 아직 열려 있는지(이미 보강이 있으면 거절)
  select * into e from enrollments where id = s.enrollment_id;
  if p_lesson is not null and p_starts_at < (select starts_at from lessons where id = p_lesson) - interval '1 day' then
    raise exception '원래 수업보다 앞선 시각입니다. 날짜를 다시 확인해 주세요.';
  end if;
  v_end := p_starts_at + make_interval(mins => e.duration_min);

  perform set_config('app.actor_id', me::text, true);
  -- 사유는 변경 기록(audit_log.actor_via)에 같이 남김 — 표에 칸을 늘리지 않음
  perform set_config('app.actor_via', left('admin_makeup_record_past: ' || v_note, 300), true);
  -- 열린 보강 신청이 있으면 그 신청을 확정, 없으면 새 신청(운영진 대신)을 만들어 확정
  select id into v_req from makeup_requests
  where status in ('requested', 'countered') and compensation_id is null
    and (source_lesson_id = p_lesson or migrated_item_id = p_item) for update;
  if v_req is null then
    insert into makeup_requests (source_lesson_id, migrated_item_id, student_id, tutor_id, via, requested_at, requested_by)
    values (p_lesson, p_item, s.student_id, s.tutor_id, 'admin_on_behalf', now(), me)
    returning id into v_req;
  end if;
  if not exists (select 1 from makeup_candidates where request_id = v_req and starts_at = p_starts_at) then
    insert into makeup_candidates (request_id, starts_at, ends_at, proposed_by) values (v_req, p_starts_at, v_end, 'tutor');
  end if;
  begin
    insert into lessons (enrollment_id, student_id, tutor_id, kind, starts_at, ends_at, makeup_of, created_by)
    values (s.enrollment_id, s.student_id, s.tutor_id,
            case when p_lesson is null then 'migrated_makeup' else 'makeup' end,
            p_starts_at, v_end, p_lesson, me)
    returning id into v_lesson;
  exception when exclusion_violation then
    raise exception '그 시간에 학생 또는 강사의 다른 수업이 있습니다.' using hint = 'schedule_conflict';
  end;
  if p_item is not null then
    update migrated_items set kind = 'makeup_booked', lesson_id = v_lesson where id = p_item;
    perform lms_leave_sync_extension(s.enrollment_id);
  end if;
  update makeup_requests set status = 'confirmed', confirmed_lesson_id = v_lesson, decided_at = now(), decided_by = me where id = v_req;
  -- 이미 지난 일: 열려 있던 '강사에게 보강 가능 확인' 안내는 보낼 필요 없음, 확정 안내도 만들지 않음
  update lesson_notices set status = 'not_needed' where makeup_request_id = v_req and status = 'pending';
  return jsonb_build_object('makeup_request_id', v_req, 'lesson_id', v_lesson);
end $$;
revoke all on function admin_makeup_record_past(uuid, uuid, timestamptz, text) from public, anon;
grant execute on function admin_makeup_record_past(uuid, uuid, timestamptz, text) to authenticated;
