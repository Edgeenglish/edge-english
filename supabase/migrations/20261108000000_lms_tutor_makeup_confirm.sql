-- 강사 자율 운영 1단계 (2026-11-07 대표 결정, 정책 원본 H26(82)): 강사가 학생이 보낸 보강 시간 하나를 골라 확정하면 바로 보강 수업 생성.
-- 확정 주체 = 강사 (D-43 원문 '학생은 신청만, 강사가 확인·확정'). 학생이 바로 확정하는 길은 없음.
--  1. makeup_requests.confirmed_in_tutor_screen: 강사 화면에서 확정했는지 (운영진 화면 표시용)
--  2. lms_makeup_book: 예전 admin_makeup_confirm 본문 그대로 (검사·수업 생성·이관권 연결·휴무 연장·안내 기록) — 운영진·강사 확정이 같은 코드
--     다른 점: 강사 확정이면 강사 확정 안내(WhatsApp 복사)는 만들지 않음, 학생 안내는 그대로 운영진 차례
--  3. admin_makeup_confirm: 운영자 확인 뒤 lms_makeup_book (동작 같음)
--  4. tutor_makeup_confirm(신청, 학생 시간): 본인 담당 신청·학생이 원한 시간만, 영어 오류 문구. 운영자 보기(?tutor=)도 같은 함수(기록 '운영자 대신')
-- 새 규칙·새 숫자 없음.

alter table makeup_requests add column if not exists confirmed_in_tutor_screen boolean not null default false;

create or replace function lms_makeup_book(p_makeup_request uuid, p_starts_at timestamptz, p_via text, p_by_tutor boolean)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  r makeup_requests;
  s record;
  c record;
  e enrollments;
  v_end timestamptz;
  v_lesson uuid;
  v_conf text;
  v_enr uuid;
begin
  select * into r from makeup_requests where id = p_makeup_request for update;
  if not found then raise exception '보강 신청이 없습니다.'; end if;
  if r.status = 'confirmed' then return jsonb_build_object('makeup_request_id', r.id, 'lesson_id', r.confirmed_lesson_id, 'repeated', true); end if;
  if r.status not in ('requested', 'countered') then raise exception '이미 닫힌 보강 신청입니다.'; end if;
  if p_starts_at <= now() then raise exception '지난 시간은 보강으로 넣을 수 없습니다.'; end if;
  -- 강사가 불가라고 답한 시간 (QA-01 D, 4500)
  if exists (select 1 from makeup_candidates x where x.request_id = r.id and x.starts_at = p_starts_at and x.proposed_by = 'student' and x.tutor_answer = 'no') then
    raise exception '강사가 불가라고 답한 시간입니다. 다른 시간을 고르거나 학생에게 다시 날짜를 받아 주세요.' using hint = 'tutor_no';
  end if;

  if r.compensation_id is not null then
    perform 1 from compensations where id = r.compensation_id for update;   -- 같은 보상권 두 번 쓰기 막기
    select * into c from lms_comp_source(r.compensation_id);
    if p_starts_at >= ((c.use_until + 1)::timestamp at time zone 'Asia/Seoul') then
      raise exception '보상수업 사용 기한(%) 뒤의 시간입니다.', c.use_until using hint = 'after_end';
    end if;
    select * into e from enrollments where id = c.enrollment_id;
    v_end := p_starts_at + make_interval(mins => e.duration_min);
    v_conf := lms_makeup_conflict(r.tutor_id, c.student_id, p_starts_at, v_end,
                exists (select 1 from makeup_candidates x where x.request_id = r.id and x.starts_at = p_starts_at and x.proposed_by = 'student'));
    if v_conf is not null then raise exception '%', lms_conflict_message(v_conf) using hint = 'schedule_conflict', detail = lms_conflict_code(v_conf); end if;
    v_enr := lms_comp_lesson_enrollment(r.compensation_id, (p_starts_at at time zone 'Asia/Seoul')::date);
    perform set_config('app.actor_id', me::text, true);
    perform set_config('app.actor_via', p_via, true);
    if not exists (select 1 from makeup_candidates where request_id = r.id and starts_at = p_starts_at) then
      insert into makeup_candidates (request_id, starts_at, ends_at, proposed_by) values (r.id, p_starts_at, v_end, 'tutor');
    end if;
    begin
      insert into lessons (enrollment_id, student_id, tutor_id, kind, starts_at, ends_at, compensation_id, created_by)
      values (v_enr, c.student_id, r.tutor_id, 'compensation', p_starts_at, v_end, r.compensation_id, me)
      returning id into v_lesson;
    exception when exclusion_violation then
      raise exception '그 시간에 학생 또는 강사의 다른 수업이 있습니다.' using hint = 'schedule_conflict';
    end;
    update compensations set status = 'used', used_lesson_id = v_lesson where id = r.compensation_id;
  else
    select * into s from lms_makeup_source(r.source_lesson_id, r.migrated_item_id);
    select * into e from enrollments where id = s.enrollment_id;
    if not s.tutor_leave and p_starts_at >= ((e.final_end_date + 1)::timestamp at time zone 'Asia/Seoul') then
      raise exception '수강 종료일(%) 뒤의 시간입니다.', e.final_end_date using hint = 'after_end';
    end if;
    v_end := p_starts_at + make_interval(mins => e.duration_min);
    v_conf := lms_makeup_conflict(r.tutor_id, s.student_id, p_starts_at, v_end,
                exists (select 1 from makeup_candidates x where x.request_id = r.id and x.starts_at = p_starts_at and x.proposed_by = 'student'));
    if v_conf is not null then raise exception '%', lms_conflict_message(v_conf) using hint = 'schedule_conflict', detail = lms_conflict_code(v_conf); end if;

    perform set_config('app.actor_id', me::text, true);
    perform set_config('app.actor_via', p_via, true);
    if not exists (select 1 from makeup_candidates where request_id = r.id and starts_at = p_starts_at) then
      insert into makeup_candidates (request_id, starts_at, ends_at, proposed_by) values (r.id, p_starts_at, v_end, 'tutor');
    end if;
    begin
      insert into lessons (enrollment_id, student_id, tutor_id, kind, starts_at, ends_at, makeup_of, created_by)
      values (s.enrollment_id, s.student_id, r.tutor_id,
              case when r.source_lesson_id is null then 'migrated_makeup' else 'makeup' end,
              p_starts_at, v_end, r.source_lesson_id, me)
      returning id into v_lesson;
    exception when exclusion_violation then
      raise exception '그 시간에 학생 또는 강사의 다른 수업이 있습니다.' using hint = 'schedule_conflict';
    end;
    if r.migrated_item_id is not null then
      update migrated_items set kind = 'makeup_booked', lesson_id = v_lesson where id = r.migrated_item_id;
      -- R-18 (4520): 이관권이 수업에 연결된 뒤 휴무 자동 연장 재계산
      perform lms_leave_sync_extension(s.enrollment_id);
    end if;
  end if;
  update makeup_requests set status = 'confirmed', confirmed_lesson_id = v_lesson, decided_at = now(), decided_by = me,
         confirmed_in_tutor_screen = p_by_tutor where id = r.id;
  update lesson_notices set status = 'not_needed' where makeup_request_id = r.id and event = 'makeup_ask' and status = 'pending';
  -- 학생 확정 안내는 운영진이 보냄(2단계 자동 메일 전까지). 강사가 직접 확정했으면 강사 안내는 만들지 않음 (H26(82))
  insert into lesson_notices (makeup_request_id, event, recipient_kind, recipient_id) values (r.id, 'makeup_confirmed', 'student', r.student_id);
  if not p_by_tutor then
    insert into lesson_notices (makeup_request_id, event, recipient_kind, recipient_id) values (r.id, 'makeup_confirmed', 'tutor', r.tutor_id);
  end if;
  return jsonb_build_object('makeup_request_id', r.id, 'lesson_id', v_lesson, 'repeated', false);
end $$;
revoke all on function lms_makeup_book(uuid, timestamptz, text, boolean) from public, anon, authenticated;

create or replace function admin_makeup_confirm(p_makeup_request uuid, p_starts_at timestamptz)
returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception '운영자(추가 인증 완료)만 처리할 수 있습니다.' using errcode = '42501'; end if;
  return lms_makeup_book(p_makeup_request, p_starts_at, 'admin_makeup_confirm', false);
end $$;
revoke all on function admin_makeup_confirm(uuid, timestamptz) from public, anon;
grant execute on function admin_makeup_confirm(uuid, timestamptz) to authenticated;

create or replace function tutor_makeup_confirm(p_request uuid, p_candidate uuid)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  r makeup_requests;
  c makeup_candidates;
  v_conf text;
  v_hint text;
  v_msg text;
begin
  select * into r from makeup_requests where id = p_request for update;
  if not found then raise exception 'Make-up request not found.'; end if;
  if not (is_admin() or (my_tutor_id() is not null and r.tutor_id = my_tutor_id())) then
    raise exception 'This is not your make-up request.' using errcode = '42501';
  end if;
  select * into c from makeup_candidates where id = p_candidate and request_id = r.id and proposed_by = 'student';
  if not found then raise exception 'Unknown time. Please reload the page.'; end if;
  -- 같은 시간으로 이미 확정됨(두 번 누름·다른 기기) → 같은 결과
  if r.status = 'confirmed' and exists (select 1 from lessons l where l.id = r.confirmed_lesson_id and l.starts_at = c.starts_at) then
    return jsonb_build_object('makeup_request_id', r.id, 'lesson_id', r.confirmed_lesson_id, 'repeated', true);
  end if;
  if r.status not in ('requested', 'countered') then
    raise exception 'This make-up request is already closed.' using hint = 'closed';
  end if;
  if c.starts_at <= now() then
    raise exception 'This time has already passed. Please reload the page.' using hint = 'busy';
  end if;
  v_conf := lms_makeup_conflict(r.tutor_id, r.student_id, c.starts_at, c.ends_at, true);
  if v_conf is not null then
    raise exception 'You can''t confirm this time: %', lms_conflict_message_en(v_conf) using hint = 'busy', detail = lms_conflict_code(v_conf);
  end if;
  perform set_config('app.actor_id', me::text, true);
  perform set_config('app.actor_via', case when is_admin() then 'admin_makeup_confirm_as_tutor' else 'tutor_makeup_confirm' end, true);
  update makeup_candidates set tutor_answer = 'yes', answered_at = now(), answered_by = me
  where id = c.id and tutor_answer is distinct from 'yes';
  update makeup_requests set tutor_answered_at = now() where id = r.id;
  begin
    return lms_makeup_book(r.id, c.starts_at, case when is_admin() then 'admin_makeup_confirm_as_tutor' else 'tutor_makeup_confirm' end, true);
  exception when raise_exception then
    get stacked diagnostics v_hint = pg_exception_hint, v_msg = message_text;
    if v_hint = 'after_end' then
      raise exception 'This time is after the end of the student''s course. Please tell Edge English.' using hint = 'after_end';
    elsif v_hint = 'schedule_conflict' then
      raise exception 'You or the student already have a class at this time.' using hint = 'busy';
    end if;
    raise exception '%', v_msg using hint = coalesce(v_hint, '');
  end;
end $$;
revoke all on function tutor_makeup_confirm(uuid, uuid) from public, anon;
grant execute on function tutor_makeup_confirm(uuid, uuid) to authenticated;
