-- =====================================================================
-- 강사 휴무 새 순서 (2026-10-28 대표 시안 승인, 정책 원본 H26(27), 반영 목록 16)
--  1 대체 강사에게 묻기 → 2 학생에게 휴무 안내 · 대체 강사 제안 (글 하나) → 3 학생 답 입력 → 4 확정 안내 보내기
--  - 운영진이 먼저 대체강사(또는 '대체 강사 없음 → 보강')를 고름 → 대체강사 고르기가 학생 답이 아니게 됨
--    · admin_leave_choose: 고를 때 휴무 안내(leave_options)를 '보냄'으로 바꾸지 않고, 대체강사를 바꿀 때도 '보낼 필요 없음'으로 만들지 않음 (2단계 글 [보냄]으로 보냄)
--    · admin_leave_student_ok: 학생이 '좋아요' 하면 2단계 글(휴무 안내 + 대체강사 제안)은 보낸 것
--    · admin_leave_notice_unsend: 2단계 글을 되돌릴 수 있는 때 = 확정 전 · 보강 신청 전 (예전: 학생 답 전)
--  나머지(대체강사 묻기·가능·확정·보강·되돌리기)는 1800 그대로
-- 기존 표·데이터를 지우지 않음. 다시 실행해도 같은 결과
-- =====================================================================

create or replace function admin_leave_choose(p_items uuid[], p_choice text, p_sub_tutor uuid)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  it leave_items;
  l lessons;
  v_conf text;
  v_changed integer := 0;
begin
  if not is_admin() then raise exception '운영자(추가 인증 완료)만 처리할 수 있습니다.' using errcode = '42501'; end if;
  if p_choice not in ('substitute', 'wait') then raise exception '대체강사 또는 기다림 중에서 골라 주세요.'; end if;
  if p_choice = 'substitute' and p_sub_tutor is null then raise exception '대체강사를 골라 주세요.'; end if;
  perform set_config('app.actor_id', me::text, true);
  perform set_config('app.actor_via', 'admin_leave_choose', true);

  for it in select * from leave_items where id = any(p_items) order by starts_at for update loop
    if it.choice = p_choice and (p_choice = 'wait' or it.sub_tutor_id = p_sub_tutor) then continue; end if;
    if p_choice = 'substitute' and p_sub_tutor = it.tutor_id then raise exception '휴무인 강사는 대체강사가 될 수 없습니다.'; end if;
    if it.lesson_id is not null then select * into l from lessons where id = it.lesson_id for update; end if;
    -- (2500 전에는 여기서 휴무 안내를 '보냄'으로 바꿨음 — 새 순서에서는 운영진이 대체강사를 먼저 고르므로 학생 안내는 2단계에서 따로 보냄)

    -- 지금 상태 풀기
    if it.choice = 'substitute' then
      if it.sub_stage = 'confirmed' then
        if it.lesson_id is not null then
          if l.state <> 'scheduled' then raise exception '% 대체 수업이 이미 진행·변경됐습니다.', to_char(it.starts_at at time zone 'Asia/Seoul', 'MM/DD'); end if;
          begin
            update lessons set tutor_id = it.tutor_id, original_tutor_id = null where id = l.id;
          exception when exclusion_violation then
            raise exception '원래 강사의 그 시간에 다른 수업이 있어 되돌릴 수 없습니다.';
          end;
        else
          update lessons set state = 'canceled', canceled_at = now(), voided_at = now(), voided_by = me, void_note = '대체강사 수업 취소(휴무 처리 변경)'
          where id = it.sub_lesson_id and state = 'scheduled';
          if not found then raise exception '% 대체 수업이 이미 진행·변경됐습니다.', to_char(it.starts_at at time zone 'Asia/Seoul', 'MM/DD'); end if;
          update migrated_items set kind = 'makeup_open', lesson_id = null where id = it.migrated_item_id;
        end if;
      end if;
      -- 휴무 안내(2단계 글)는 남김: 1단계에서 대체강사 → 보강으로 바꿔도 학생에게는 아직 알려야 함
      update lesson_notices set status = 'not_needed' where leave_item_id = it.id and status = 'pending' and event <> 'leave_options';
    elsif it.choice = 'wait' and p_choice = 'substitute' then
      if it.lesson_id is not null then
        if exists (select 1 from lessons x where x.makeup_of = l.id and x.state <> 'canceled')
           or exists (select 1 from makeup_requests r where r.source_lesson_id = l.id and r.status in ('requested', 'countered', 'confirmed')) then
          raise exception '% 수업은 보강 신청·확정이 있어 대체강사로 바꿀 수 없습니다. 보강부터 정리해 주세요.', to_char(it.starts_at at time zone 'Asia/Seoul', 'MM/DD');
        end if;
        if l.state = 'canceled' and l.class_status = 'Tutor long-term leave' then
          update lessons set state = 'scheduled', class_status = null, canceled_at = null, cancel_reason = null where id = l.id;
          l.state := 'scheduled';
        end if;
      else
        if exists (select 1 from migrated_items m where m.id = it.migrated_item_id and m.kind <> 'makeup_open')
           or exists (select 1 from makeup_requests r where r.migrated_item_id = it.migrated_item_id and r.status in ('requested', 'countered')) then
          raise exception '% 휴가 보강은 보강 신청·확정이 있어 대체강사로 바꿀 수 없습니다. 보강부터 정리해 주세요.', to_char(it.starts_at at time zone 'Asia/Seoul', 'MM/DD');
        end if;
      end if;
    end if;

    -- 새 상태
    if p_choice = 'wait' then
      if it.lesson_id is not null and l.state = 'scheduled' then
        update lessons set state = 'canceled', class_status = 'Tutor long-term leave', canceled_at = now(), cancel_reason = 'tutor_leave'
        where id = l.id;
      elsif it.lesson_id is not null and l.class_status is distinct from 'Tutor long-term leave' then
        raise exception '% 수업이 이미 처리됐습니다 (%).', to_char(it.starts_at at time zone 'Asia/Seoul', 'MM/DD'), l.class_status;
      end if;
      update leave_items set choice = 'wait', sub_tutor_id = null, sub_stage = null, sub_lesson_id = null, decided_at = now(), decided_by = me
      where id = it.id;
    else
      if it.starts_at <= now() then raise exception '% 수업 시간이 지나 대체강사를 정할 수 없습니다.', to_char(it.starts_at at time zone 'Asia/Seoul', 'MM/DD'); end if;
      if it.lesson_id is not null and l.state <> 'scheduled' then
        raise exception '% 수업이 이미 처리됐습니다 (%).', to_char(it.starts_at at time zone 'Asia/Seoul', 'MM/DD'), l.class_status;
      end if;
      v_conf := lms_sub_conflict(p_sub_tutor, it.starts_at, it.ends_at, it.lesson_id);
      if v_conf is not null then
        raise exception '% 수업 시간은 대체강사의 %와 겹칩니다.', to_char(it.starts_at at time zone 'Asia/Seoul', 'MM/DD HH24:MI'), v_conf using hint = 'schedule_conflict';
      end if;
      update leave_items set choice = 'substitute', sub_tutor_id = p_sub_tutor, sub_stage = 'asked', sub_lesson_id = null,
                             decided_at = now(), decided_by = me
      where id = it.id;
      update lesson_notices set status = 'not_needed', sent_at = null, sent_by = null
      where leave_item_id = it.id and event = 'sub_ask' and recipient_id = p_sub_tutor and status = 'sent';
      insert into lesson_notices (leave_item_id, event, recipient_kind, recipient_id) values (it.id, 'sub_ask', 'tutor', p_sub_tutor);
    end if;
    v_changed := v_changed + 1;
  end loop;
  return jsonb_build_object('changed', v_changed);
end $$;
revoke all on function admin_leave_choose(uuid[], text, uuid) from public, anon;
grant execute on function admin_leave_choose(uuid[], text, uuid) to authenticated;

create or replace function admin_leave_student_ok(p_items uuid[])
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  it leave_items;
  v_conf text;
  v_lesson uuid;
  v_changed integer := 0;
begin
  if not is_admin() then raise exception '운영자(추가 인증 완료)만 처리할 수 있습니다.' using errcode = '42501'; end if;
  perform set_config('app.actor_id', me::text, true);
  perform set_config('app.actor_via', 'admin_leave_student_ok', true);
  for it in select * from leave_items where id = any(p_items) order by starts_at for update loop
    if it.choice <> 'substitute' then raise exception '대체강사를 고른 수업이 아닙니다.'; end if;
    if it.sub_stage = 'confirmed' then continue; end if;
    if it.sub_stage <> 'tutor_ok' then raise exception '대체강사가 가능하다고 한 뒤에 확정할 수 있습니다.'; end if;
    if it.starts_at <= now() then raise exception '% 수업 시간이 지났습니다.', to_char(it.starts_at at time zone 'Asia/Seoul', 'MM/DD'); end if;
    v_conf := lms_sub_conflict(it.sub_tutor_id, it.starts_at, it.ends_at, it.lesson_id);
    if v_conf is not null then
      raise exception '% 수업 시간은 대체강사의 %와 겹칩니다.', to_char(it.starts_at at time zone 'Asia/Seoul', 'MM/DD HH24:MI'), v_conf using hint = 'schedule_conflict';
    end if;
    begin
      if it.lesson_id is not null then
        update lessons set tutor_id = it.sub_tutor_id, original_tutor_id = it.tutor_id where id = it.lesson_id and state = 'scheduled'
        returning id into v_lesson;
        if v_lesson is null then raise exception '% 수업이 이미 처리됐습니다.', to_char(it.starts_at at time zone 'Asia/Seoul', 'MM/DD'); end if;
      else
        insert into lessons (enrollment_id, student_id, tutor_id, original_tutor_id, kind, starts_at, ends_at, created_by)
        values (it.enrollment_id, it.student_id, it.sub_tutor_id, it.tutor_id, 'migrated_makeup', it.starts_at, it.ends_at, me)
        returning id into v_lesson;
        update migrated_items set kind = 'makeup_booked', lesson_id = v_lesson where id = it.migrated_item_id and kind = 'makeup_open';
        if not found then raise exception '% 휴가 보강이 이미 예약됐습니다.', to_char(it.starts_at at time zone 'Asia/Seoul', 'MM/DD'); end if;
      end if;
    exception when exclusion_violation then
      raise exception '% 그 시간에 학생 또는 대체강사의 다른 수업이 있습니다.', to_char(it.starts_at at time zone 'Asia/Seoul', 'MM/DD HH24:MI') using hint = 'schedule_conflict';
    end;
    update lesson_notices set status = 'sent', sent_at = now(), sent_by = me
    where leave_item_id = it.id and event in ('leave_options', 'sub_student') and status = 'pending';
    update leave_items set sub_stage = 'confirmed', sub_lesson_id = v_lesson where id = it.id;
    update lesson_notices set status = 'not_needed', sent_at = null, sent_by = null
    where leave_item_id = it.id and event = 'sub_confirmed' and recipient_id in (it.sub_tutor_id, it.student_id) and status = 'sent';
    -- 학생 OK → 학생·강사 모두에게 최종 확정 안내 (2026-10-27 대표)
    insert into lesson_notices (leave_item_id, event, recipient_kind, recipient_id) values
      (it.id, 'sub_confirmed', 'tutor', it.sub_tutor_id), (it.id, 'sub_confirmed', 'student', it.student_id);
    v_changed := v_changed + 1;
  end loop;
  return jsonb_build_object('changed', v_changed);
end $$;
revoke all on function admin_leave_student_ok(uuid[]) from public, anon;
grant execute on function admin_leave_student_ok(uuid[]) to authenticated;

create or replace function admin_leave_notice_unsend(p_notices uuid[])
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  n lesson_notices;
  it leave_items;
  v_changed integer := 0;
begin
  if not is_admin() then raise exception '운영자(추가 인증 완료)만 처리할 수 있습니다.' using errcode = '42501'; end if;
  perform set_config('app.actor_id', me::text, true);
  perform set_config('app.actor_via', 'admin_leave_notice_unsend', true);
  for n in select * from lesson_notices where id = any(p_notices) and leave_item_id is not null for update loop
    if n.status <> 'sent' then continue; end if;
    select * into it from leave_items where id = n.leave_item_id;
    if (n.event = 'leave_options' and ((it.choice = 'substitute' and it.sub_stage = 'confirmed')
                                       or (it.choice = 'wait' and exists (select 1 from makeup_requests r where (r.source_lesson_id = it.lesson_id or r.migrated_item_id = it.migrated_item_id)
                                                                           and r.status in ('requested', 'countered', 'confirmed')))))
       or (n.event = 'sub_ask' and it.sub_stage is distinct from 'asked')
       or (n.event = 'sub_student' and it.sub_stage is distinct from 'tutor_ok')
       or (n.event = 'sub_confirmed' and it.sub_stage is distinct from 'confirmed') then
      raise exception '이미 다음 단계로 넘어간 안내입니다. 단계를 먼저 되돌려 주세요.';
    end if;
    update lesson_notices set status = 'pending', sent_at = null, sent_by = null where id = n.id;
    v_changed := v_changed + 1;
  end loop;
  return jsonb_build_object('changed', v_changed);
end $$;
revoke all on function admin_leave_notice_unsend(uuid[]) from public, anon;
grant execute on function admin_leave_notice_unsend(uuid[]) to authenticated;
