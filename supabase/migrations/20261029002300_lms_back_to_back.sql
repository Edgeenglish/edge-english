-- =====================================================================
-- 보강 back to back: 같은 학생 수업에 이어서 보강 잡기 (2026-10-28 대표 확정, 정책 원본 H26(30)+보완, POL-OP-21 예외)
--  - 학생이 원한 시간(보강 신청 때 학생이 낸 시간)일 때만. 강사가 말한 다른 시간에는 예외 없음 (강사가 요청할 수 없음)
--  - 기본은 수업 사이 휴식 10분 그대로 (10분 쉬고 이어도 back to back)
--  - 예외: 20분 수업끼리, 같은 학생이면 휴식 없이(10분 미만) 붙일 수 있음. 쉬지 않고 붙이는 건 2개(연속 40분)까지
--  - 40·50분 수업은 같은 학생이어도 반드시 10분 휴식. 다른 학생 수업과는 항상 10분
--  - 바뀌는 곳: 보강 확정(admin_makeup_confirm) · 강사 화면 보강 시간 '이미 수업 있음' 표시(tutor_screen)
--    다른 판정(신규 등록·기존 학생 입력·대체강사·휴무 보강 가능 날짜)은 그대로 10분
-- 기존 표·데이터를 지우지 않음. 다시 실행해도 같은 결과
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. 보강 시간 충돌: 강사 휴무 · 강사 다른 수업(휴식 10분, 위 예외) · 쉬지 않고 3개 이상. 문제 없으면 null
--    p_student_wants = 학생이 원한 시간인지 (아니면 예외 없이 10분)
-- ---------------------------------------------------------------------
create or replace function lms_makeup_conflict(p_tutor uuid, p_student uuid, p_start timestamptz, p_end timestamptz, p_student_wants boolean)
returns text
language plpgsql stable security definer set search_path = public as $$
declare
  v_break constant interval := interval '10 minutes';      -- POL-OP-21 (policy.ts CONFIRMED.minBreakMin)
  v_b2b_min constant integer := 20;                         -- POL-OP-21 예외 (policy.ts CONFIRMED.backToBackNoBreakDurationMin)
  v_b2b_max constant integer := 2;                          -- POL-OP-21 예외 (policy.ts CONFIRMED.backToBackNoBreakMaxLessons)
  v_new_b2b boolean := p_student_wants and p_end - p_start = make_interval(mins => v_b2b_min);
  v_near uuid[];
  v_chain integer;
begin
  if exists (select 1 from tutor_time_off o where o.tutor_id = p_tutor and o.starts_at < p_end and p_start < o.ends_at) then
    return '강사 휴무';
  end if;
  -- 겹치는 수업, 또는 휴식 10분 안인데 예외(같은 학생·둘 다 20분·학생이 원한 시간)가 아닌 수업
  if exists (select 1 from lessons x where x.tutor_id = p_tutor and x.state <> 'canceled'
             and x.starts_at < p_end + v_break and p_start - v_break < x.ends_at
             and (x.starts_at < p_end and p_start < x.ends_at
                  or not (v_new_b2b and x.student_id = p_student and x.ends_at - x.starts_at = make_interval(mins => v_b2b_min)))) then
    return '강사 다른 수업(휴식 10분 포함)';
  end if;
  -- 쉬지 않고 붙는 수업 수: 새 수업 + 휴식 10분 안의 수업들 + 그 수업들에 다시 10분 안으로 붙은 수업들
  select coalesce(array_agg(x.id), '{}') into v_near from lessons x
  where x.tutor_id = p_tutor and x.state <> 'canceled'
    and x.starts_at < p_end + v_break and p_start - v_break < x.ends_at;
  if cardinality(v_near) = 0 then return null; end if;
  select 1 + cardinality(v_near) + count(distinct y.id) into v_chain from lessons y
  where y.tutor_id = p_tutor and y.state <> 'canceled' and y.id <> all(v_near)
    and not (y.starts_at < p_end + v_break and p_start - v_break < y.ends_at)
    and exists (select 1 from lessons x where x.id = any(v_near)
                and y.starts_at < x.ends_at + v_break and x.starts_at - v_break < y.ends_at);
  if v_chain > v_b2b_max then
    return format('쉬지 않고 이어 붙이는 수업(%s분 %s개까지)', v_b2b_min, v_b2b_max);
  end if;
  return null;
end $$;
revoke all on function lms_makeup_conflict(uuid, uuid, timestamptz, timestamptz, boolean) from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- 2. 보강 확정: 충돌 판정만 위 함수로 (나머지는 1700 그대로)
-- ---------------------------------------------------------------------
create or replace function admin_makeup_confirm(p_makeup_request uuid, p_starts_at timestamptz)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  r makeup_requests;
  s record;
  e enrollments;
  v_end timestamptz;
  v_lesson uuid;
  v_conf text;
begin
  if not is_admin() then raise exception '운영자(추가 인증 완료)만 처리할 수 있습니다.' using errcode = '42501'; end if;
  select * into r from makeup_requests where id = p_makeup_request for update;
  if not found then raise exception '보강 신청이 없습니다.'; end if;
  if r.status = 'confirmed' then return jsonb_build_object('makeup_request_id', r.id, 'lesson_id', r.confirmed_lesson_id, 'repeated', true); end if;
  if r.status not in ('requested', 'countered') then raise exception '이미 닫힌 보강 신청입니다.'; end if;
  select * into s from lms_makeup_source(r.source_lesson_id, r.migrated_item_id);
  select * into e from enrollments where id = s.enrollment_id;
  if p_starts_at <= now() then raise exception '지난 시간은 보강으로 넣을 수 없습니다.'; end if;
  if not s.tutor_leave and p_starts_at >= ((e.final_end_date + 1)::timestamp at time zone 'Asia/Seoul') then
    raise exception '수강 종료일(%) 뒤의 시간입니다.', e.final_end_date using hint = 'after_end';
  end if;
  v_end := p_starts_at + make_interval(mins => e.duration_min);
  v_conf := lms_makeup_conflict(r.tutor_id, s.student_id, p_starts_at, v_end,
              exists (select 1 from makeup_candidates c where c.request_id = r.id and c.starts_at = p_starts_at and c.proposed_by = 'student'));
  if v_conf is not null then raise exception '그 시간은 %와 겹칩니다.', v_conf using hint = 'schedule_conflict'; end if;

  perform set_config('app.actor_id', me::text, true);
  perform set_config('app.actor_via', 'admin_makeup_confirm', true);
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
  end if;
  update makeup_requests set status = 'confirmed', confirmed_lesson_id = v_lesson, decided_at = now(), decided_by = me where id = r.id;
  update lesson_notices set status = 'not_needed' where makeup_request_id = r.id and event = 'makeup_ask' and status = 'pending';
  insert into lesson_notices (makeup_request_id, event, recipient_kind, recipient_id)
  values (r.id, 'makeup_confirmed', 'student', s.student_id), (r.id, 'makeup_confirmed', 'tutor', r.tutor_id);
  return jsonb_build_object('makeup_request_id', r.id, 'lesson_id', v_lesson, 'repeated', false);
end $$;
revoke all on function admin_makeup_confirm(uuid, timestamptz) from public, anon;
grant execute on function admin_makeup_confirm(uuid, timestamptz) to authenticated;

-- ---------------------------------------------------------------------
-- 3. 강사 화면: 학생이 원한 보강 시간의 '이미 수업 있음'(busy)도 같은 기준 (admin_makeup_confirm 과 같게)
-- ---------------------------------------------------------------------
create or replace function tutor_screen(p_tutor uuid, p_from date, p_to date)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_tutor uuid := lms_screen_tutor(p_tutor);
  t tutors;
begin
  if p_from is null or p_to is null or p_to < p_from then raise exception 'Invalid date range.'; end if;
  select * into t from tutors where id = v_tutor;
  return jsonb_build_object(
    'tutor', jsonb_build_object('id', t.id, 'name', t.name, 'timezone', t.timezone, 'meet_url', t.meet_url),
    'lessons', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', l.id, 'starts_at', l.starts_at, 'ends_at', l.ends_at, 'kind', l.kind, 'state', l.state, 'class_status', l.class_status,
        'student', coalesce(s.display_name, s.name_en), 'level', s.level, 'note_url', s.class_note_url,
        'covering', l.original_tutor_id is not null and l.original_tutor_id <> l.tutor_id,
        'makeup_of', o.starts_at,
        'count', lms_lesson_count(l.id),
        'topics', cr.covered_topics, 'remarks', cr.remarks, 'recorded_at', cr.first_submitted_at,
        'locked', exists (select 1 from payroll_items p where p.lesson_id = l.id))
        order by l.starts_at)
      from lessons l
      join students s on s.id = l.student_id
      left join lessons o on o.id = l.makeup_of
      left join class_records cr on cr.lesson_id = l.id
      where l.tutor_id = v_tutor and l.voided_at is null
        and (l.kst_date between p_from and p_to
             or (l.state = 'scheduled' and l.starts_at <= now()
                 and l.starts_at >= (select min(u.created_at) from app_users u where u.tutor_id = v_tutor)))), '[]'::jsonb),
    -- 기록할 수업: 시작했는데 결과가 없는 수업 (강사 LMS 계정이 생긴 뒤 시작한 수업만 — 그 전 수업은 시트에 기록됨)
    'to_record', coalesce((
      select jsonb_agg(l.id order by l.starts_at)
      from lessons l
      where l.tutor_id = v_tutor and l.state = 'scheduled' and l.voided_at is null and l.starts_at <= now()
        and l.starts_at >= (select min(u.created_at) from app_users u where u.tutor_id = v_tutor)), '[]'::jsonb),
    'makeups', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', r.id, 'student', coalesce(s.display_name, s.name_en),
        'original_at', src.starts_at, 'original_date', mi.original_date,
        'note', r.tutor_note, 'answered_at', r.tutor_answered_at,
        'slots', (select jsonb_agg(jsonb_build_object(
                    'id', c.id, 'starts_at', c.starts_at, 'ends_at', c.ends_at, 'answer', c.tutor_answer,
                    'busy', lms_makeup_conflict(r.tutor_id, r.student_id, c.starts_at, c.ends_at, true) is not null, 'past', c.starts_at <= now())
                    order by c.starts_at)
                  from makeup_candidates c where c.request_id = r.id and c.proposed_by = 'student'))
        order by r.created_at)
      from makeup_requests r
      join students s on s.id = r.student_id
      left join lessons src on src.id = r.source_lesson_id
      left join migrated_items mi on mi.id = r.migrated_item_id
      where r.tutor_id = v_tutor and r.status in ('requested', 'countered')), '[]'::jsonb));
end $$;
revoke all on function tutor_screen(uuid, date, date) from public, anon;
grant execute on function tutor_screen(uuid, date, date) to authenticated;
