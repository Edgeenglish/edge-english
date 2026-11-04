-- =====================================================================
-- 4500. Work QA(2026-11-04) 보고서 수정 — 예약 확정 검사·권리 정합성 (QA-01 · QA-12 · QA-13 · QA-08) + 대표 추가 요청 1·3
--  QA-01 강사 불가 답·닫힌 시간·현지 06:00 전인데도 확정됨
--   - lms_makeup_conflict: 강사가 연 시간(매주 Availability 또는 Schedule 그날만 열기, lms_tutor_available)이 아니면 충돌
--     → 운영진 보강·보상 확정, 강사 '가능' 답, 강사 화면 busy, 학생 보강 가능한 날짜 모두 같은 판정.
--     학생 후보는 처음부터 연 시간에서만 나오므로(2800·4200), 후보가 생긴 뒤 강사가 그 시간을 닫으면 확정이 막힘 (QA-01 A)
--     강사가 말한 다른 시간을 운영진이 넣을 때도 같음 — 그 시간은 강사가 Schedule 에서 먼저 열어야 함(기록된 날짜별 개방 = 최종 검사와 일치)
--   - lms_sub_conflict(대체강사): 강사 현지 06:00~22:30 시작 규칙(4200, POL-OP-02)을 대체 묻기·가능·확정 모든 경로에 적용 (QA-01 C)
--     '보통 시간 밖' 은 2700 대표 결정(예외는 항상 있음, 강사가 받아 주면 됨) 그대로 안내만 — 정책 변경은 대표 결정 사항으로 보고 (QA-01 B)
--   - admin_makeup_confirm: 강사가 '불가' 라고 답한 학생 후보 시간은 확정 못 함 (QA-01 D)
--  QA-12 보강·보상수업이 이미 잡힌 강사 노쇼를 Held 로 바꾸면 조용히 모순 상태가 남음
--   - tutor_record_class: 노쇼를 다른 결과로 고치기 전에 사용된 보상권·살아 있는 보강·열린 보강 신청을 확인 → 있으면 거절(운영진이 먼저 정리)
--  QA-13 변경권 0개(또는 6시간 안) 보강 취소 뒤 원래 수업의 보강권이 되살아남
--   - 보강 수업이 '취소'(voided 아님)되면 그 권리는 보강 수업 자체의 결과로 이어진 것 → 원래 수업은 다시 보강권이 되지 않음
--     (student_screen makeup_rights · lms_makeup_source · 화면 makeupRights 같은 기준). 운영진 '보강 없애기'·'되돌리기'(voided)는 전처럼 원래 권리 복구
--   - 신청 내역: 확정된 보강 수업이 취소되면 '확정' 대신 취소로 보임 (confirmed_state)
--  QA-08 강사가 모든 후보에 '불가' 라고 답하면 학생에게 '최종 확정 대기' 대신 재조율 상태로 (tutor_declined_all)
--  추가 요청 1 (Back-to-back): 학생 '보강 가능한 날짜' 가 10분 휴식만 보던 것을 lms_makeup_conflict(같은 학생 20분 수업끼리 예외, POL-OP-21)로 → 학생이 직접 이어 붙일 수 있음
--  추가 요청 3: 운영진 변경권 수동 조정 admin_credit_adjust(사유 필수, ±1, 이력 = credit_ledger 'admin_adjust', 전후 수량 반환) + admin_credits 읽기
-- 기존 표·데이터를 지우지 않음. 다시 실행해도 같은 결과. 숫자(휴식 10분·20분·2개·06:00~22:30)는 기존 값 그대로
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. 보강 충돌: 강사가 연 시간이 아니면 충돌 (QA-01 A) — 나머지는 4200 그대로
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
  -- 강사 현지 06:00~22:30 시작만 (POL-OP-02, 4200)
  if not lms_tutor_start_ok(p_tutor, p_start) then
    return '강사 현지 06:00~22:30 밖의 시작 시각';
  end if;
  -- 강사가 연 시간(매주 Availability 또는 Schedule 에서 그날만 열기)이어야 함 (QA-01, 4500)
  if not lms_tutor_available(p_tutor, p_start) then
    return '강사가 열어 둔 시간이 아님(Availability·Schedule)';
  end if;
  if exists (select 1 from tutor_time_off o where o.tutor_id = p_tutor and o.starts_at < p_end and p_start < o.ends_at) then
    return '강사 휴무';
  end if;
  if exists (select 1 from lessons x where x.tutor_id = p_tutor and x.state <> 'canceled'
             and x.starts_at < p_end + v_break and p_start - v_break < x.ends_at
             and (x.starts_at < p_end and p_start < x.ends_at
                  or not (v_new_b2b and x.student_id = p_student and x.ends_at - x.starts_at = make_interval(mins => v_b2b_min)))) then
    return '강사 다른 수업(휴식 10분 포함)';
  end if;
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
-- 1-b. Schedule 칸 판정 (4403 그대로, 순서만): 매주 닫힌 칸(s)은 답 대기(r)보다 먼저 —
--      후보 시간을 강사가 닫아 두면 그 칸은 '닫힘' 으로 보이고 Make available 로 다시 열 수 있음 (QA-01 A 재조율 경로).
--      전에는 r 이 먼저라 '먼저 답하세요' 와 '닫힌 시간은 가능 답 불가' 가 서로 막았음. 열린 칸의 답 대기(r)·6시간 안(p)·수업(c)·휴무(l)는 그대로
-- ---------------------------------------------------------------------
create or replace function lms_hours_cell(p_tutor uuid, p_at timestamptz) returns text
language sql stable security definer set search_path = public as $$
  select case
    when exists (select 1 from lessons x where x.tutor_id = p_tutor and x.state <> 'canceled' and x.voided_at is null
                 and x.starts_at < p_at + interval '30 minutes' and p_at < x.ends_at) then 'c'
    when exists (select 1 from tutor_time_off o where o.tutor_id = p_tutor and o.kind = 'leave'
                 and o.starts_at < p_at + interval '30 minutes' and p_at < o.ends_at) then 'l'
    when p_at < now() + interval '6 hours' then 'p'
    when not lms_tutor_available(p_tutor, p_at) then 's'
    when exists (select 1 from makeup_candidates c join makeup_requests r on r.id = c.request_id
                 where r.tutor_id = p_tutor and r.status in ('requested', 'countered') and coalesce(c.tutor_answer, 'yes') = 'yes'
                   and c.starts_at < p_at + interval '30 minutes' and p_at < c.ends_at)
      or exists (select 1 from leave_items i where i.sub_tutor_id = p_tutor and i.sub_stage in ('asked', 'tutor_ok')
                 and i.starts_at < p_at + interval '30 minutes' and p_at < i.ends_at) then 'r'
    when exists (select 1 from tutor_time_off o where o.tutor_id = p_tutor and o.kind = 'block'
                 and o.starts_at < p_at + interval '30 minutes' and p_at < o.ends_at) then 'b'
    when not lms_tutor_weekly_ok(p_tutor, p_at) then 'x'
    else 'o' end
$$;
revoke all on function lms_hours_cell(uuid, timestamptz) from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- 2. 대체강사 충돌: 현지 06:00~22:30 시작 규칙 추가 (QA-01 C). 보통 시간 밖은 2700 그대로(안내만, 강사가 받아 주면 됨)
-- ---------------------------------------------------------------------
create or replace function lms_sub_conflict(p_tutor uuid, p_start timestamptz, p_end timestamptz, p_except_lesson uuid)
returns text
language plpgsql stable security definer set search_path = public as $$
declare
  v_break constant interval := interval '10 minutes';   -- POL-OP-21 (policy.ts CONFIRMED.minBreakMin)
begin
  if not lms_tutor_start_ok(p_tutor, p_start) then
    return '강사 현지 06:00~22:30 밖의 시작 시각';
  end if;
  if exists (select 1 from tutor_time_off o where o.tutor_id = p_tutor and o.starts_at < p_end and p_start < o.ends_at) then
    return '강사 휴무';
  end if;
  if exists (select 1 from lessons x where x.tutor_id = p_tutor and x.state <> 'canceled' and x.id is distinct from p_except_lesson
             and x.starts_at < p_end + v_break and p_start - v_break < x.ends_at) then
    return '강사 다른 수업(휴식 10분 포함)';
  end if;
  return null;
end $$;
revoke all on function lms_sub_conflict(uuid, timestamptz, timestamptz, uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- 3. 학생 보강 가능한 날짜: 강사 충돌 판정을 보강 확정과 같은 함수로 (추가 요청 1: 같은 학생 20분 수업끼리 이어 붙이기 예외가 학생 화면에도 통함)
--    나머지(기간·30분 단위·학생 다른 수업·강사 연 시간)는 4100 그대로
-- ---------------------------------------------------------------------
create or replace function lms_makeup_options(p_lesson uuid, p_item uuid, p_comp uuid default null)
returns table (section text, starts_at timestamptz, ends_at timestamptz)
language plpgsql stable security definer set search_path = public as $$
declare
  s record;
  e enrollments;
  v_leave boolean;
  v_back date;
  v_until date;
  v_today date := (now() at time zone 'Asia/Seoul')::date;
begin
  if p_comp is not null then
    select * into s from lms_comp_source(p_comp);
    select * into e from enrollments where id = s.enrollment_id;
    v_leave := false;
    v_back := v_today + 1;
    v_until := s.use_until;
  else
    select * into s from lms_makeup_source(p_lesson, p_item);
    select * into e from enrollments where id = s.enrollment_id;
    v_leave := s.tutor_leave or exists (select 1 from lessons l where l.id = p_lesson and l.class_status = 'Tutor long-term leave');
    select (o.ends_at at time zone 'Asia/Seoul')::date into v_back
    from leave_items li join tutor_time_off o on o.id = li.time_off_id
    where (li.lesson_id = p_lesson or li.migrated_item_id = p_item) limit 1;
    v_back := coalesce(v_back, v_today + 1);
    v_until := e.final_end_date;
  end if;

  return query
  with rs as (
    select r.weekday, r.start_time_kst from regular_schedules r
    where r.student_id = s.student_id and r.tutor_id = s.tutor_id and (r.effective_to is null or r.effective_to >= v_today)
  ),
  slots as (
    -- 수업 시작은 항상 30분 단위 (2026-10-28 대표) → 강사 보통 수업 시간 안의 :00·:30 모두
    select 'in_period'::text as sec, ((d::date::timestamp + make_interval(mins => n * 30)) at time zone 'Asia/Seoul') as x
    from generate_series(greatest(v_today + 1, v_back), v_until, interval '1 day') d
    cross join generate_series(0, 47) n
    union all
    select 'after_end', ((d::date + rs.start_time_kst) at time zone 'Asia/Seoul')
    from generate_series(greatest(e.final_end_date + 1, v_back, v_today + 1), greatest(e.final_end_date + 1, v_back, v_today + 1) + 180, interval '1 day') d
    join rs on rs.weekday = extract(dow from d)
    where v_leave
  ),
  free as (
    select y.sec, y.x, y.x + make_interval(mins => e.duration_min) as f from slots y
    where y.x > now()
      and lms_tutor_available(s.tutor_id, y.x)
      -- 학생이 고르는 시간 = 학생이 원한 시간 → 같은 학생 20분 수업끼리 휴식 없이 붙이기 예외 적용 (POL-OP-21, 4500)
      and lms_makeup_conflict(s.tutor_id, s.student_id, y.x, y.x + make_interval(mins => e.duration_min), true) is null
      and not exists (select 1 from lessons l where l.student_id = s.student_id and l.state <> 'canceled'
                      and l.starts_at < y.x + make_interval(mins => e.duration_min) and y.x < l.ends_at)
  )
  select z.sec, z.x, z.f from (select f1.*, row_number() over (partition by f1.sec order by f1.x) as n from free f1) z
  where z.sec = 'in_period' or z.n <= 1
  order by z.x;
end $$;
revoke all on function lms_makeup_options(uuid, uuid, uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- 4. 보강 권리의 원본 판정 (QA-13): 보강 수업이 취소(voided 아님)되면 원래 수업은 다시 보강권이 되지 않음 — 2800 그대로 + 이 기준
-- ---------------------------------------------------------------------
create or replace function lms_makeup_source(p_lesson uuid, p_item uuid, out enrollment_id uuid, out student_id uuid,
                                             out tutor_id uuid, out tutor_leave boolean)
language plpgsql stable security definer set search_path = public as $$
declare
  l lessons;
  it migrated_items;
begin
  if (p_lesson is null) = (p_item is null) then raise exception '보강할 수업을 하나 골라 주세요.'; end if;
  if p_lesson is not null then
    select * into l from lessons where id = p_lesson;
    if not found or not coalesce(lms_grants_makeup(l.class_status) or l.class_status = 'Tutor long-term leave', false) then
      raise exception '보강을 받을 수 있는 수업이 아닙니다.';
    end if;
    if exists (select 1 from lessons x where x.makeup_of = l.id and x.voided_at is null and x.state <> 'canceled') then
      raise exception '이미 보강이 잡혀 있습니다.';
    end if;
    if exists (select 1 from lessons x where x.makeup_of = l.id and x.voided_at is null and x.state = 'canceled') then
      raise exception '이 수업의 보강이 이미 한 번 잡혔다가 취소됐습니다. 보강권은 그 보강 수업의 결과를 따릅니다 (POL-CHG-04·08).' using hint = 'makeup_consumed';
    end if;
    enrollment_id := l.enrollment_id; student_id := l.student_id; tutor_id := l.tutor_id;
    tutor_leave := coalesce(l.class_status = 'Tutor long-term leave', false);
  else
    select * into it from migrated_items where id = p_item;
    if not found or it.kind <> 'makeup_open' then raise exception '예약 전 보강이 아닙니다.'; end if;
    select e.student_id into student_id from enrollments e where e.id = it.enrollment_id;
    select coalesce(x.original_tutor_id, x.tutor_id) into tutor_id from lessons x
    where x.enrollment_id = it.enrollment_id and x.voided_at is null order by x.starts_at desc limit 1;
    enrollment_id := it.enrollment_id; tutor_leave := coalesce(it.tutor_leave, false);
  end if;
end $$;
revoke all on function lms_makeup_source(uuid, uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- 5. 운영진 보강 확정: 강사가 '불가' 라고 답한 후보 시간은 확정 못 함 (QA-01 D). 나머지는 4100 그대로
--    (강사 답이 없는 후보는 전처럼 확정 가능 — 카톡·WhatsApp 으로 이미 확인한 내용을 다시 묻지 않음, 추가 요청 5)
-- ---------------------------------------------------------------------
create or replace function admin_makeup_confirm(p_makeup_request uuid, p_starts_at timestamptz)
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
  if not is_admin() then raise exception '운영자(추가 인증 완료)만 처리할 수 있습니다.' using errcode = '42501'; end if;
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
    if v_conf is not null then raise exception '그 시간은 %와 겹칩니다.', v_conf using hint = 'schedule_conflict'; end if;
    v_enr := lms_comp_lesson_enrollment(r.compensation_id, (p_starts_at at time zone 'Asia/Seoul')::date);
    perform set_config('app.actor_id', me::text, true);
    perform set_config('app.actor_via', 'admin_makeup_confirm', true);
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
  end if;
  update makeup_requests set status = 'confirmed', confirmed_lesson_id = v_lesson, decided_at = now(), decided_by = me where id = r.id;
  update lesson_notices set status = 'not_needed' where makeup_request_id = r.id and event = 'makeup_ask' and status = 'pending';
  insert into lesson_notices (makeup_request_id, event, recipient_kind, recipient_id)
  values (r.id, 'makeup_confirmed', 'student', r.student_id), (r.id, 'makeup_confirmed', 'tutor', r.tutor_id);
  return jsonb_build_object('makeup_request_id', r.id, 'lesson_id', v_lesson, 'repeated', false);
end $$;
revoke all on function admin_makeup_confirm(uuid, timestamptz) from public, anon;
grant execute on function admin_makeup_confirm(uuid, timestamptz) to authenticated;

-- ---------------------------------------------------------------------
-- 6. 강사 보강 답: 닫힌 시간도 '가능' 으로 못 보냄 (판정은 lms_makeup_conflict 하나) — 4100 그대로 + 문구
-- ---------------------------------------------------------------------
create or replace function tutor_makeup_answer(p_request uuid, p_yes uuid[], p_note text)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  r makeup_requests;
  v_note text := nullif(trim(coalesce(p_note, '')), '');
  v_yes uuid[] := coalesce(p_yes, '{}');
begin
  select * into r from makeup_requests where id = p_request for update;
  if not found then raise exception 'Make-up request not found.'; end if;
  if not (is_admin() or (my_tutor_id() is not null and r.tutor_id = my_tutor_id())) then
    raise exception 'This is not your make-up request.' using errcode = '42501';
  end if;
  if r.status not in ('requested', 'countered') then
    raise exception 'This make-up request is already closed.' using hint = 'closed';
  end if;
  if exists (select 1 from unnest(v_yes) y where not exists
             (select 1 from makeup_candidates c where c.id = y and c.request_id = r.id and c.proposed_by = 'student')) then
    raise exception 'Unknown time in your answer. Please reload the page.';
  end if;
  if exists (select 1 from makeup_candidates c where c.id = any(v_yes)
             and (c.starts_at <= now() or lms_makeup_conflict(r.tutor_id, r.student_id, c.starts_at, c.ends_at, true) is not null)) then
    raise exception 'One of the times you chose is no longer open in your schedule, or overlaps another class or time off. Please reload the page.' using hint = 'busy';
  end if;
  if cardinality(v_yes) = 0 and v_note is null then
    raise exception 'None of the times work? Please write other times you are available in the note.' using hint = 'note';
  end if;
  perform set_config('app.actor_id', me::text, true);
  perform set_config('app.actor_via', case when is_admin() then 'admin_makeup_answer' else 'tutor_makeup_answer' end, true);
  update makeup_candidates c set tutor_answer = case when c.id = any(v_yes) then 'yes' else 'no' end, answered_at = now(), answered_by = me
  where c.request_id = r.id and c.proposed_by = 'student'
    and c.tutor_answer is distinct from case when c.id = any(v_yes) then 'yes' else 'no' end;
  update makeup_requests set tutor_note = v_note, tutor_answered_at = now() where id = r.id;
  update lesson_notices set status = 'not_needed' where makeup_request_id = r.id and event = 'makeup_ask' and status = 'pending';
  return jsonb_build_object('makeup_request_id', r.id, 'yes', cardinality(v_yes));
end $$;
revoke all on function tutor_makeup_answer(uuid, uuid[], text) from public, anon;
grant execute on function tutor_makeup_answer(uuid, uuid[], text) to authenticated;

-- ---------------------------------------------------------------------
-- 7. Class Record: 보강·보상수업이 이미 잡힌 강사 노쇼는 결과를 바로 못 바꿈 (QA-12). 4401 그대로 + 이 검사
--    운영진이 수업 변경·보강 화면에서 보강/보상수업을 먼저 없애면(admin_void_makeup) 그 뒤 고칠 수 있음. 확정 수업을 자동으로 취소하지 않음
-- ---------------------------------------------------------------------
create or replace function tutor_record_class(p_lesson uuid, p_result text, p_topics text, p_remarks text,
                                              p_student_late boolean, p_student_late_min int, p_tutor_late boolean, p_tutor_late_min int)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  l lessons;
  v_status class_status;
  v_topics text := nullif(trim(coalesce(p_topics, '')), '');
  v_remarks text := nullif(trim(coalesce(p_remarks, '')), '');
  v_old class_records;
  v_result text := case when p_result = 'late' then 'held' else p_result end;   -- 예전 화면 호환
  v_held boolean := v_result = 'held';
  v_s_late boolean := v_held and coalesce(p_student_late, false);
  v_t_late boolean := v_held and (coalesce(p_tutor_late, false) or p_result = 'late');
  v_s_min int := case when v_s_late then p_student_late_min end;
  v_t_min int := case when v_t_late then p_tutor_late_min end;
  v_linked text[];
begin
  select * into l from lessons where id = p_lesson for update;
  if not found then raise exception 'Class not found.'; end if;
  if not (is_admin() or (my_tutor_id() is not null and l.tutor_id = my_tutor_id())) then
    raise exception 'This is not your class.' using errcode = '42501';
  end if;
  if l.class_status = 'Tutor no-show' and not is_admin()
     and (select cr0.submitted_by from class_records cr0 where cr0.lesson_id = l.id) is distinct from me then
    raise exception 'Edge English recorded this class. Please contact the Edge English team.' using hint = 'locked';
  end if;
  if l.voided_at is not null or l.state = 'canceled' then
    raise exception 'This class was canceled (%). No record needed.', coalesce(l.class_status::text, 'removed') using hint = 'canceled';
  end if;
  if l.starts_at > now() then raise exception 'You can record this class after it starts.' using hint = 'not_started'; end if;
  if exists (select 1 from payroll_items where lesson_id = l.id) then
    raise exception 'This class is already in payroll. Please contact Edge English to change it.' using hint = 'locked';
  end if;
  if (v_s_min is not null and v_s_min <= 0) or (v_t_min is not null and v_t_min <= 0) then
    raise exception 'Late minutes must be more than 0.' using hint = 'late';
  end if;
  if v_held then
    if v_topics is null then raise exception 'Please enter the covered topics.' using hint = 'topics'; end if;
    if v_t_late and v_remarks is null then raise exception 'Please write why you were late in Remarks.' using hint = 'remarks'; end if;
    v_status := case when v_t_late then 'Tutor Late - Student Present'
                     when l.kind in ('makeup', 'migrated_makeup', 'compensation') then 'Make-up completed'
                     when l.original_tutor_id is not null and l.original_tutor_id <> l.tutor_id then 'Covered by another tutor'
                     else 'Normal' end;
  elsif v_result = 'student_no_show' then
    v_status := 'Student no-show';
  elsif v_result = 'tutor_no_show' then
    v_status := 'Tutor no-show';
  else
    raise exception 'Please choose how the class went.';
  end if;

  -- 강사 노쇼 → 다른 결과: 이미 잡힌(확정된) 보강·보상수업이 있으면 먼저 정리 (QA-12, 4500). 확정 수업을 자동 취소하지 않음
  --  날짜만 신청 중(확정 전)인 원래 수업 보강 신청은 아래에서 닫음 (보상 신청은 보상권 voided 트리거가 닫음, 4100)
  if l.class_status = 'Tutor no-show' and v_status <> 'Tutor no-show' then
    select array_remove(array[
      (select format('compensation class %s', to_char(x.starts_at at time zone 'Asia/Seoul', 'Mon DD HH24:MI "KST"'))
         from compensations c join lessons x on x.id = c.used_lesson_id where c.source_lesson_id = l.id and c.status = 'used' and x.voided_at is null and x.state <> 'canceled' limit 1),
      (select format('make-up class %s', to_char(x.starts_at at time zone 'Asia/Seoul', 'Mon DD HH24:MI "KST"'))
         from lessons x where x.makeup_of = l.id and x.voided_at is null and x.state <> 'canceled' order by x.starts_at limit 1)
    ], null) into v_linked;
    if cardinality(v_linked) > 0 then
      raise exception 'This no-show already has % booked. Edge English must remove it first (Lesson change > Make-up), then the result can be changed.',
        array_to_string(v_linked, ', ') using hint = 'linked';
    end if;
  end if;

  select * into v_old from class_records where lesson_id = l.id;
  if l.state = 'done' and l.class_status = v_status and found
     and v_old.covered_topics is not distinct from v_topics and v_old.remarks is not distinct from v_remarks
     and v_old.student_late = v_s_late and v_old.student_late_min is not distinct from v_s_min
     and v_old.tutor_late = v_t_late and v_old.tutor_late_min is not distinct from v_t_min then
    return jsonb_build_object('lesson_id', l.id, 'class_status', v_status, 'repeated', true);
  end if;

  perform set_config('app.actor_id', me::text, true);
  perform set_config('app.actor_via', case when is_admin() then 'admin_record_class' else 'tutor_record_class' end, true);
  update lessons set state = 'done', class_status = v_status where id = l.id and (state, class_status) is distinct from ('done', v_status);
  if v_status = 'Tutor no-show' then
    insert into compensations (student_id, enrollment_id, source_lesson_id, reason, confirmed_by)
    values (l.student_id, l.enrollment_id, l.id, 'tutor_no_show', me)
    on conflict (source_lesson_id) do update set status = 'available' where compensations.status = 'voided';
  else
    update compensations set status = 'voided' where source_lesson_id = l.id and status = 'available';
    -- 더는 보강을 받을 수 없는 결과면 날짜만 신청 중이던 원래 수업 보강 신청은 닫음 (기록은 남김, QA-12 4500)
    if not lms_grants_makeup(v_status) then
      update makeup_requests set status = 'withdrawn', decided_at = now(), decided_by = me
      where source_lesson_id = l.id and compensation_id is null and status in ('requested', 'countered');
      update lesson_notices set status = 'not_needed'
      where status = 'pending' and makeup_request_id in (select id from makeup_requests where source_lesson_id = l.id and compensation_id is null and status = 'withdrawn');
    end if;
  end if;
  insert into class_records (lesson_id, covered_topics, remarks, student_late, student_late_min, tutor_late, tutor_late_min, submitted_by)
  values (l.id, v_topics, v_remarks, v_s_late, v_s_min, v_t_late, v_t_min, me)
  on conflict (lesson_id) do update set covered_topics = excluded.covered_topics, remarks = excluded.remarks,
    student_late = excluded.student_late, student_late_min = excluded.student_late_min,
    tutor_late = excluded.tutor_late, tutor_late_min = excluded.tutor_late_min, submitted_by = excluded.submitted_by;
  return jsonb_build_object('lesson_id', l.id, 'class_status', v_status, 'repeated', false);
end $$;
revoke all on function tutor_record_class(uuid, text, text, text, boolean, int, boolean, int) from public, anon;
grant execute on function tutor_record_class(uuid, text, text, text, boolean, int, boolean, int) to authenticated;

-- ---------------------------------------------------------------------
-- 8. 운영진 변경권 수동 조정 (추가 요청 3): 사유 필수, 한 번에 ±1, 이력 = credit_ledger(reason 'admin_adjust', note, created_by, created_at)
--    한도는 기존 안전장치(credit_ledger_guard: 0 ~ 지급 수량) 그대로. 자동 차감(lms_change_core)은 바꾸지 않음
-- ---------------------------------------------------------------------
create or replace function admin_credits(p_student uuid)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  e enrollments;
  p enrollment_periods;
  v_today date := (now() at time zone 'Asia/Seoul')::date;
begin
  if not is_admin() then raise exception '운영자(추가 인증 완료)만 볼 수 있습니다.' using errcode = '42501'; end if;
  select * into e from enrollments where id = lms_student_enrollment(p_student);
  if not found then return jsonb_build_object('period', null); end if;
  select * into p from enrollment_periods x where x.enrollment_id = e.id and x.start_date <= v_today order by x.idx desc limit 1;
  if not found then return jsonb_build_object('period', null); end if;
  return jsonb_build_object(
    'period', jsonb_build_object('id', p.id, 'idx', p.idx, 'start', p.start_date, 'end', p.end_date),
    'granted', p.credits_granted,
    'left', credit_balance(p.id),
    'uses', coalesce((
      select jsonb_agg(jsonb_build_object('at', c.created_at, 'reason', c.reason, 'delta', c.delta, 'note', c.note, 'lesson_at', l.starts_at,
                                          'by', c.created_by) order by c.created_at desc)
      from credit_ledger c
      left join lessons l on l.id = c.lesson_id
      where c.period_id = p.id), '[]'::jsonb));
end $$;
revoke all on function admin_credits(uuid) from public, anon;
grant execute on function admin_credits(uuid) to authenticated;

create or replace function admin_credit_adjust(p_student uuid, p_delta integer, p_reason text)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  e enrollments;
  p enrollment_periods;
  v_reason text := nullif(btrim(coalesce(p_reason, '')), '');
  v_before integer;
  v_today date := (now() at time zone 'Asia/Seoul')::date;
begin
  if not is_admin() then raise exception '운영자(추가 인증 완료)만 처리할 수 있습니다.' using errcode = '42501'; end if;
  if p_delta not in (-1, 1) then raise exception '변경권은 한 번에 1개씩 더하거나 뺄 수 있습니다.'; end if;
  if v_reason is null then raise exception '조정 사유를 적어 주세요.' using hint = 'reason'; end if;
  if char_length(v_reason) > 200 then raise exception '사유는 200자까지 적을 수 있습니다.' using hint = 'reason'; end if;
  select * into e from enrollments where id = lms_student_enrollment(p_student);
  if not found then raise exception '수강 중인 수강권이 없습니다.'; end if;
  select * into p from enrollment_periods x where x.enrollment_id = e.id and x.start_date <= v_today order by x.idx desc limit 1 for update;
  if not found then raise exception '지금 진행 중인 변경권 기간이 없습니다.'; end if;
  v_before := credit_balance(p.id);
  perform set_config('app.actor_id', me::text, true);
  perform set_config('app.actor_via', 'admin_credit_adjust', true);
  begin
    insert into credit_ledger (period_id, reason, delta, note, created_by) values (p.id, 'admin_adjust', p_delta, v_reason, me);
  exception when raise_exception then
    if p_delta > 0 then
      raise exception '이번 기간에 지급된 변경권(%개)보다 많이 가질 수 없습니다.', p.credits_granted using hint = 'limit';
    else
      raise exception '남은 변경권이 없어 더 뺄 수 없습니다.' using hint = 'limit';
    end if;
  end;
  return jsonb_build_object('period_id', p.id, 'before', v_before, 'after', v_before + p_delta, 'granted', p.credits_granted, 'reason', v_reason);
end $$;
revoke all on function admin_credit_adjust(uuid, integer, text) from public, anon;
grant execute on function admin_credit_adjust(uuid, integer, text) to authenticated;

-- ---------------------------------------------------------------------
-- 9. 학생 화면 (4100 그대로 + QA-13 보강권 기준 · 신청 내역 확정 수업 상태 · QA-08 강사 전부 불가 · 변경권 기록 메모)
-- ---------------------------------------------------------------------
create or replace function student_screen(p_student uuid)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_student uuid := lms_screen_student(p_student);
  st students;
  e enrollments;
  v_period enrollment_periods;
  v_open uuid[];
  v_today date := (now() at time zone 'Asia/Seoul')::date;
begin
  select * into st from students where id = v_student;
  select * into e from enrollments where id = lms_student_enrollment(v_student);
  select * into v_period from enrollment_periods p
  where p.enrollment_id = e.id and p.start_date <= v_today order by p.idx desc limit 1;
  v_open := array(select x.id from enrollments x where x.student_id = v_student and (x.status in ('active', 'confirmed') or x.id = e.id));
  return jsonb_build_object(
    'student', jsonb_build_object('id', st.id, 'code', st.code, 'name_ko', st.name_ko, 'timezone', st.timezone),
    'enrollment', case when e.id is null then null else jsonb_build_object(
      'id', e.id, 'weeks', e.weeks, 'legacy_label', e.legacy_label, 'weekly_count', e.weekly_count, 'duration_min', e.duration_min,
      'start_date', e.start_date, 'final_end_date', e.final_end_date, 'status', e.status,
      'next_regular_from', lms_next_regular_from(e.id),
      'lessons_total', coalesce((select c.sheet_total from import_checks c where c.enrollment_id = e.id), e.lessons_purchased + e.lessons_carried_in),
      'credits_left', case when v_period.id is null then 0 else credit_balance(v_period.id) end,
      'credits_granted', coalesce(v_period.credits_granted, 0),
      'confirmed_on', (select min((p.confirmed_at at time zone 'Asia/Seoul')::date) from payments p where p.enrollment_id = e.id and p.confirmed_at is not null),
      'renewal_paid', exists (select 1 from enrollments n where n.previous_enrollment_id = e.id and n.status in ('confirmed', 'active'))) end,
    'lessons', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', l.id, 'kind', l.kind, 'starts_at', l.starts_at, 'ends_at', l.ends_at, 'state', l.state, 'class_status', l.class_status,
        'tutor', t.name, 'meet_url', t.meet_url, 'makeup_of', l.makeup_of, 'leave_postponed', lms_is_leave_postponed(l.id),
        'substitute', l.original_tutor_id is not null,
        'leave_open', exists (select 1 from leave_items li where li.lesson_id = l.id and li.lesson_gone_at is null
                              and (li.choice = 'undecided' or (li.choice = 'substitute' and li.sub_stage <> 'confirmed')))) order by l.starts_at)
      from lessons l join tutors t on t.id = l.tutor_id
      where l.enrollment_id = any(v_open) and l.voided_at is null), '[]'::jsonb),
    -- 보강을 받을 수 있는데 아직 날짜가 없는 것 (취소한 수업 · 시트에서 넘어온 날짜 미정 보강 · 강사 노쇼 무료 보상수업)
    -- QA-13 (4500): 보강 수업이 잡힌 뒤 취소(voided 아님)된 원래 수업은 다시 권리가 되지 않음 — 권리는 그 보강 수업의 결과를 따름
    'makeup_rights', coalesce((
      select jsonb_agg(r order by r ->> 'original_at', r ->> 'comp_id' nulls first) from (
        select jsonb_build_object('lesson_id', l.id, 'item_id', null, 'original_at', l.starts_at,
                 'tutor_leave', l.class_status = 'Tutor long-term leave') as r
        from lessons l
        where l.enrollment_id = any(v_open) and l.voided_at is null and (lms_grants_makeup(l.class_status) or l.class_status = 'Tutor long-term leave')
          and not exists (select 1 from lessons x where x.makeup_of = l.id and x.voided_at is null)
        union all
        select jsonb_build_object('lesson_id', null, 'item_id', m.id,
                 'original_at', coalesce((select li.starts_at from leave_items li where li.migrated_item_id = m.id order by li.starts_at limit 1),
                                         m.original_date::timestamp at time zone 'Asia/Seoul'),
                 'time_known', exists (select 1 from leave_items li where li.migrated_item_id = m.id),
                 'tutor_leave', coalesce(m.tutor_leave, false))
        from migrated_items m where m.enrollment_id = any(v_open) and m.kind = 'makeup_open'
          and not exists (select 1 from leave_items li where li.migrated_item_id = m.id and li.lesson_gone_at is null
                          and li.choice in ('undecided', 'substitute'))
        union all
        select jsonb_build_object('lesson_id', null, 'item_id', null, 'comp_id', c.id, 'original_at', src.starts_at,
                 'tutor', t.name, 'use_until', lms_comp_use_until(c.enrollment_id), 'tutor_leave', false)
        from compensations c
        join lessons src on src.id = c.source_lesson_id
        join tutors t on t.id = src.tutor_id
        where c.student_id = v_student and c.status = 'available' and lms_comp_use_until(c.enrollment_id) >= v_today) q), '[]'::jsonb),
    'leave_pending', coalesce((
      select jsonb_agg(jsonb_build_object('id', li.id, 'starts_at', li.starts_at, 'ends_at', li.ends_at) order by li.starts_at)
      from leave_items li
      where li.student_id = v_student and li.lesson_id is null and li.lesson_gone_at is null and li.starts_at > now()
        and (li.choice = 'undecided' or (li.choice = 'substitute' and li.sub_stage <> 'confirmed'))), '[]'::jsonb),
    -- 신청 내역 (4100 + 4500: 확정 수업 상태 · 강사가 모든 후보에 불가 답)
    'makeup_requests', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', r.id, 'status', r.status, 'lesson_id', r.source_lesson_id, 'item_id', r.migrated_item_id, 'comp_id', r.compensation_id,
        'requested_at', r.requested_at, 'confirmed_lesson_id', r.confirmed_lesson_id, 'tutor_answered_at', r.tutor_answered_at,
        'confirmed_state', cl.state,
        'tutor_declined_all', r.tutor_answered_at is not null
          and not exists (select 1 from makeup_candidates c where c.request_id = r.id and c.proposed_by = 'student' and c.tutor_answer = 'yes'),
        'original_at', coalesce(src.starts_at, (select m.original_date::timestamp at time zone 'Asia/Seoul' from migrated_items m where m.id = r.migrated_item_id)),
        'original_time_known', src.id is not null,
        'original_tutor', srct.name,
        'tutor', rt.name,
        'confirmed_at', cl.starts_at,
        'tutor_leave', coalesce(src.class_status = 'Tutor long-term leave',
                                (select m.tutor_leave from migrated_items m where m.id = r.migrated_item_id), false),
        'candidates', (select coalesce(jsonb_agg(c.starts_at order by c.starts_at), '[]'::jsonb) from makeup_candidates c where c.request_id = r.id and c.proposed_by = 'student'))
        order by r.requested_at desc)
      from makeup_requests r
      left join lessons src on src.id = r.source_lesson_id
      left join tutors srct on srct.id = src.tutor_id
      left join tutors rt on rt.id = r.tutor_id
      left join lessons cl on cl.id = r.confirmed_lesson_id
      where r.student_id = v_student and r.status in ('requested', 'countered', 'confirmed')
        and r.requested_at > now() - interval '60 days'), '[]'::jsonb),
    'leave', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', li.id, 'starts_at', li.starts_at, 'choice', li.choice, 'stage', li.sub_stage, 'sub_tutor', sub.name, 'sub_meet_url', sub.meet_url,
        'lesson_id', li.lesson_id, 'item_id', li.migrated_item_id,
        'off_from', o.starts_at, 'off_to', o.ends_at) order by li.starts_at)
      from leave_items li
      join tutor_time_off o on o.id = li.time_off_id
      left join tutors sub on sub.id = li.sub_tutor_id
      where li.student_id = v_student and li.starts_at > now() and li.lesson_gone_at is null
        and ((li.choice = 'substitute' and li.sub_stage in ('tutor_ok', 'confirmed')) or li.choice = 'wait')), '[]'::jsonb),
    'credit_period', case when v_period.id is null then null else jsonb_build_object('start', v_period.start_date, 'end', v_period.end_date) end,
    'credit_uses', coalesce((
      select jsonb_agg(jsonb_build_object('at', c.created_at, 'reason', c.reason, 'delta', c.delta, 'note', c.note, 'lesson_at', l.starts_at) order by c.created_at)
      from credit_ledger c left join lessons l on l.id = c.lesson_id where c.period_id = v_period.id), '[]'::jsonb),
    'holidays', coalesce((select jsonb_agg(h.day order by h.day) from holidays h
      where h.day between v_today and v_today + 200), '[]'::jsonb),
    'points', coalesce((
      select jsonb_agg(jsonb_build_object('id', g.id, 'on', (g.created_at at time zone 'Asia/Seoul')::date, 'kind', g.kind, 'amount', g.amount, 'note', g.note)
        order by g.created_at)
      from reward_ledger g where g.student_id = v_student), '[]'::jsonb));
end $$;
revoke all on function student_screen(uuid) from public, anon;
grant execute on function student_screen(uuid) to authenticated;

-- ---------------------------------------------------------------------
-- 10. 강사용 Student profile — 운영자 보기(?tutor=)에서 고른 강사 문맥 (QA-07): p_tutor 를 받아 그 강사의 시간대·권한 범위로.
--     강사 본인은 비움(전과 같음). 운영자가 고른 강사도 lms_screen_tutor 로 확인(강사는 다른 강사 못 고름). 4300 함수는 그대로 두고 인자 하나 더 받는 판을 추가
--     + 남은 수업 집계(QA-05): left_all(예약된 수업) 과 따로 left_unbooked(날짜 안 잡은 보강권·보상권) — 학생 홈 '남은 수업' 과 같은 기준
-- ---------------------------------------------------------------------
create or replace function tutor_student_profile(p_student uuid, p_tutor uuid)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  me uuid := case when is_admin() and p_tutor is not null then lms_screen_tutor(p_tutor) else my_tutor_id() end;
  v_access text;
  j jsonb;
  v_unbooked integer;
begin
  if is_admin() then
    v_access := 'regular';   -- 운영자가 강사 화면을 대신 볼 때(?tutor=)는 담당 강사와 같은 범위
  else
    if me is null then raise exception 'Please sign in with your tutor account.' using errcode = '42501'; end if;
    v_access := lms_tutor_student_access(me, p_student);
    if v_access is null then raise exception 'This student is not assigned to you.' using errcode = '42501'; end if;
  end if;
  j := lms_student_profile_json(p_student, v_access);
  if v_access = 'substitute' then
    j := j - 'upcoming' - 'enrollment' || jsonb_build_object(
      'upcoming', (select coalesce(jsonb_agg(x) filter (where (x ->> 'tutor_id')::uuid = me), '[]'::jsonb) from jsonb_array_elements(j -> 'upcoming') x),
      'enrollment', case when j -> 'enrollment' is null or j -> 'enrollment' = 'null'::jsonb then null else
        jsonb_build_object('duration_min', j -> 'enrollment' -> 'duration_min', 'weekly_count', j -> 'enrollment' -> 'weekly_count',
                           'final_end_date', j -> 'enrollment' -> 'final_end_date') end);
  elsif j -> 'enrollment' is not null and j -> 'enrollment' <> 'null'::jsonb then
    -- 날짜 안 잡은 보강권(취소 수업·시트 미예약 보강·보상권) — student_screen makeup_rights 와 같은 기준 (4500)
    select count(*) into v_unbooked from (
      select 1 from lessons l where l.enrollment_id = (j -> 'enrollment' ->> 'id')::uuid and l.voided_at is null
        and (lms_grants_makeup(l.class_status) or l.class_status = 'Tutor long-term leave')
        and not exists (select 1 from lessons x where x.makeup_of = l.id and x.voided_at is null)
      union all
      select 1 from migrated_items m where m.enrollment_id = (j -> 'enrollment' ->> 'id')::uuid and m.kind = 'makeup_open'
      union all
      select 1 from compensations c where c.enrollment_id = (j -> 'enrollment' ->> 'id')::uuid and c.status = 'available'
        and lms_comp_use_until(c.enrollment_id) >= (now() at time zone 'Asia/Seoul')::date) q;
    j := jsonb_set(j, '{enrollment,left_unbooked}', to_jsonb(coalesce(v_unbooked, 0)));
  end if;
  return j || jsonb_build_object('me', jsonb_build_object('id', me, 'timezone', (select timezone from tutors where id = me)));
end $$;
revoke all on function tutor_student_profile(uuid, uuid) from public, anon;
grant execute on function tutor_student_profile(uuid, uuid) to authenticated;
-- 예전 한 인자 판은 새 판으로 넘김 (호출하는 옛 화면 호환)
create or replace function tutor_student_profile(p_student uuid)
returns jsonb
language sql stable security definer set search_path = public as $$
  select tutor_student_profile(p_student, null)
$$;
revoke all on function tutor_student_profile(uuid) from public, anon;
grant execute on function tutor_student_profile(uuid) to authenticated;
