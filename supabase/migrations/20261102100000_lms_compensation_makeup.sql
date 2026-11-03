-- =====================================================================
-- 4100 강사 노쇼 무료 보상수업 = 기존 보강 기능 재사용 (2026-11-02 대표 최종 결정, 정책 원본 H항목 · POL-TU-03)
--  - 7일 사용 제한 폐지: compensations_deadline 트리거(지급일+7일) 없앰. expires_on 칸은 그대로 두고 쓰지 않음(기록 보존)
--  - 사용 기한 = 일반 보강과 같이 수강기간(종료일)까지. 종료일 23:59 KST까지 재등록 결제가 된 다음 수강권이 있으면
--    그 수강권 종료일까지 이월(이어서 반복, POL-RN-01). 재등록 안 하면 보강과 같이 소멸(화면에서 빠짐, 기록은 남김)
--  - 신청: 학생이 일반 보강처럼 '보강 가능한 날짜'에서 1~2개 고름 → 강사 화면 Make-up requests 답 → 운영진 확정
--    makeup_requests.compensation_id 로 구분 (같은 노쇼 수업의 '원래 수업 보강'과 '무료 보상 +1'이 따로 열림)
--  - 확정: lessons kind='compensation'·compensation_id (차감·회차 없음, lms_lesson_count 그대로), compensations 'used'·used_lesson_id
--    이월된 날짜면 그 날짜가 들어가는 재등록 수강권에 수업을 붙임
--  - 중복 막기: 보상권당 열린 신청 1개(unique) · 살아 있는 보상 수업 1개(unique) · 확정 때 보상권 잠금·상태 확인
--  - 보상권이 없어지면(강사 노쇼를 다른 결과로 고침 → voided) 열린 신청도 닫음
--  - 운영진 보강 없애기(admin_void_makeup)는 보상 수업도 → 보상권 다시 'available'
--  - 화면: student_screen(보상 권리·신청 상세 원래 수업·강사·확정 날짜), tutor_screen(Compensation 표시)
-- 기존 표·데이터를 지우지 않음. 다시 실행해도 같은 결과
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. 7일 기한 없애기 · 신청에 보상권 칸
-- ---------------------------------------------------------------------
drop trigger if exists compensations_deadline on compensations;
drop function if exists compensation_set_deadline();

alter table makeup_requests add column if not exists compensation_id uuid references compensations(id);
-- 원래 수업 보강의 '열린 신청 1개'는 보상 신청과 따로 셈
drop index if exists makeup_requests_one_open;
create unique index makeup_requests_one_open on makeup_requests (source_lesson_id)
  where status in ('requested', 'countered') and compensation_id is null;
create unique index if not exists makeup_requests_one_open_comp on makeup_requests (compensation_id)
  where status in ('requested', 'countered') and compensation_id is not null;
-- 보상권 하나에 살아 있는 보상 수업 하나
create unique index if not exists lessons_one_live_compensation on lessons (compensation_id)
  where compensation_id is not null and state <> 'canceled';

-- ---------------------------------------------------------------------
-- 2. 사용 기한: 수강권 종료일 → 종료일 23:59 KST까지 결제된 재등록이 있으면 그 수강권 종료일 (이어서)
--    결제 기록이 하나도 없는 재등록(시트에서 옮긴 수강권, 결제는 시트)은 운영진이 등록한 것으로 보고 이월
-- ---------------------------------------------------------------------
create or replace function lms_comp_chain(p_enrollment uuid)
returns table (enrollment_id uuid, start_date date, final_end_date date)
language plpgsql stable security definer set search_path = public as $$
declare
  e enrollments;
  n enrollments;
  i int := 0;
begin
  select * into e from enrollments where id = p_enrollment;
  if not found then return; end if;
  loop
    enrollment_id := e.id; start_date := e.start_date; final_end_date := e.final_end_date;
    return next;
    select x.* into n from enrollments x
    where x.previous_enrollment_id = e.id and x.status in ('confirmed', 'active', 'completed')
      and (not exists (select 1 from payments p where p.enrollment_id = x.id)
           or exists (select 1 from payments p where p.enrollment_id = x.id
                      and p.paid_at < ((e.final_end_date + 1)::timestamp at time zone 'Asia/Seoul')));
    exit when not found;
    i := i + 1;
    exit when i > 50;
    e := n;
  end loop;
end $$;
revoke all on function lms_comp_chain(uuid) from public, anon, authenticated;

create or replace function lms_comp_use_until(p_enrollment uuid) returns date
language sql stable security definer set search_path = public as $$
  select max(c.final_end_date) from lms_comp_chain(p_enrollment) c
$$;
revoke all on function lms_comp_use_until(uuid) from public, anon, authenticated;

-- 보상 신청할 수 있는 보상권인지 (쓸 수 있는 상태 · 기한 안)
create or replace function lms_comp_source(p_comp uuid, out enrollment_id uuid, out student_id uuid, out tutor_id uuid,
                                           out source_lesson_id uuid, out use_until date)
language plpgsql stable security definer set search_path = public as $$
declare
  c compensations;
begin
  select * into c from compensations where id = p_comp;
  if not found then raise exception '보상수업이 없습니다.'; end if;
  if c.status = 'used' then raise exception '이미 날짜를 잡은 보상수업입니다.' using hint = 'comp_used'; end if;
  if c.status <> 'available' then raise exception '쓸 수 없는 보상수업입니다.' using hint = 'comp_closed'; end if;
  use_until := lms_comp_use_until(c.enrollment_id);
  if use_until < (now() at time zone 'Asia/Seoul')::date then
    raise exception '보상수업 사용 기한(%)이 지났습니다.', use_until using hint = 'comp_expired';
  end if;
  enrollment_id := c.enrollment_id; student_id := c.student_id; source_lesson_id := c.source_lesson_id;
  -- 노쇼한 수업의 강사 (원래 수업 보강과 같은 강사, lms_makeup_source 와 같게)
  select l.tutor_id into tutor_id from lessons l where l.id = c.source_lesson_id;
end $$;
revoke all on function lms_comp_source(uuid) from public, anon, authenticated;

-- 이월된 날짜면 그 날짜가 들어가는 재등록 수강권
create or replace function lms_comp_lesson_enrollment(p_comp uuid, p_day date) returns uuid
language sql stable security definer set search_path = public as $$
  select coalesce(
    (select c.enrollment_id from lms_comp_chain((select enrollment_id from compensations where id = p_comp)) c
     where c.final_end_date >= p_day order by c.final_end_date limit 1),
    (select enrollment_id from compensations where id = p_comp))
$$;
revoke all on function lms_comp_lesson_enrollment(uuid, date) from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- 3. 보강 가능한 날짜: 보상수업도 같은 계산 (2800 그대로 + p_comp). 보상수업은 사용 기한까지(종료일 뒤 정규 요일 없음)
-- ---------------------------------------------------------------------
drop function if exists student_makeup_options(uuid, uuid, uuid);
drop function if exists lms_makeup_options(uuid, uuid);
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
      and lms_sub_conflict(s.tutor_id, y.x, y.x + make_interval(mins => e.duration_min), null) is null
      and lms_tutor_available(s.tutor_id, y.x)
      and not exists (select 1 from lessons l where l.student_id = s.student_id and l.state <> 'canceled'
                      and l.starts_at < y.x + make_interval(mins => e.duration_min) and y.x < l.ends_at)
  )
  select z.sec, z.x, z.f from (select f1.*, row_number() over (partition by f1.sec order by f1.x) as n from free f1) z
  where z.sec = 'in_period' or z.n <= 1
  order by z.x;
end $$;
revoke all on function lms_makeup_options(uuid, uuid, uuid) from public, anon, authenticated;

create or replace function student_makeup_options(p_student uuid, p_lesson uuid, p_item uuid, p_comp uuid default null)
returns table (section text, starts_at timestamptz, ends_at timestamptz)
language plpgsql stable security definer set search_path = public as $$
declare
  v_student uuid := lms_screen_student(p_student);
  v_owner uuid;
begin
  if p_comp is not null then
    select x.student_id into v_owner from lms_comp_source(p_comp) x;
  else
    select x.student_id into v_owner from lms_makeup_source(p_lesson, p_item) x;
  end if;
  if v_owner <> v_student then raise exception '본인 수업만 볼 수 있습니다.' using errcode = '42501'; end if;
  return query select * from lms_makeup_options(p_lesson, p_item, p_comp);
end $$;
revoke all on function student_makeup_options(uuid, uuid, uuid, uuid) from public, anon;
grant execute on function student_makeup_options(uuid, uuid, uuid, uuid) to authenticated;

-- ---------------------------------------------------------------------
-- 4. 보강 신청: 원래 수업 보강 · 보상수업 같은 처리 (2800 그대로 + p_comp)
--    고침: 원래 수업 보강의 '이미 열린 신청' 찾기에서 보상 신청을 뺌 (같은 노쇼 수업에 둘 다 열릴 수 있음)
-- ---------------------------------------------------------------------
drop function if exists admin_makeup_request(uuid, uuid, jsonb, timestamptz);
drop function if exists student_makeup_request(uuid, uuid, jsonb);
drop function if exists lms_makeup_request_core(uuid, uuid, jsonb, timestamptz, text, uuid);
create or replace function lms_makeup_request_core(p_lesson uuid, p_item uuid, p_slots jsonb, p_requested_at timestamptz, p_via text, p_actor uuid,
                                                   p_comp uuid default null)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  s record;
  c record;
  e enrollments;
  v_id uuid;
  x jsonb;
  t timestamptz;
begin
  if jsonb_typeof(p_slots) <> 'array' or jsonb_array_length(p_slots) = 0 then raise exception '보강 시간을 하나 이상 넣어 주세요.'; end if;
  perform set_config('app.actor_id', coalesce(p_actor::text, ''), true);
  perform set_config('app.actor_via', 'lms_makeup_request_core', true);
  if p_comp is not null then
    perform 1 from compensations where id = p_comp for update;   -- 같은 보상권 동시 신청 막기
    select * into c from lms_comp_source(p_comp);
    select * into e from enrollments where id = c.enrollment_id;
    select id into v_id from makeup_requests where status in ('requested', 'countered') and compensation_id = p_comp;
    if found then return jsonb_build_object('makeup_request_id', v_id, 'repeated', true); end if;
    insert into makeup_requests (source_lesson_id, compensation_id, student_id, tutor_id, via, requested_at, requested_by)
    values (c.source_lesson_id, p_comp, c.student_id, c.tutor_id, p_via, coalesce(p_requested_at, now()), p_actor)
    returning id into v_id;
    for x in select * from jsonb_array_elements(p_slots) loop
      t := (x ->> 'starts_at')::timestamptz;
      if t <= now() then raise exception '지난 시간은 보강으로 넣을 수 없습니다.'; end if;
      if t >= ((c.use_until + 1)::timestamp at time zone 'Asia/Seoul') then
        raise exception '보상수업 사용 기한(%) 뒤의 시간입니다.', c.use_until using hint = 'after_end';
      end if;
      insert into makeup_candidates (request_id, starts_at, ends_at, proposed_by)
      values (v_id, t, t + make_interval(mins => e.duration_min), 'student');
    end loop;
    insert into lesson_notices (makeup_request_id, event, recipient_kind, recipient_id) values (v_id, 'makeup_ask', 'tutor', c.tutor_id);
    return jsonb_build_object('makeup_request_id', v_id, 'repeated', false);
  end if;

  select * into s from lms_makeup_source(p_lesson, p_item);
  select * into e from enrollments where id = s.enrollment_id;
  select id into v_id from makeup_requests
  where status in ('requested', 'countered') and compensation_id is null and (source_lesson_id = p_lesson or migrated_item_id = p_item);
  if found then return jsonb_build_object('makeup_request_id', v_id, 'repeated', true); end if;
  insert into makeup_requests (source_lesson_id, migrated_item_id, student_id, tutor_id, via, requested_at, requested_by)
  values (p_lesson, p_item, s.student_id, s.tutor_id, p_via, coalesce(p_requested_at, now()), p_actor)
  returning id into v_id;
  for x in select * from jsonb_array_elements(p_slots) loop
    t := (x ->> 'starts_at')::timestamptz;
    if t <= now() then raise exception '지난 시간은 보강으로 넣을 수 없습니다.'; end if;
    if not s.tutor_leave and t >= ((e.final_end_date + 1)::timestamp at time zone 'Asia/Seoul') then
      raise exception '수강 종료일(%) 뒤의 시간입니다.', e.final_end_date using hint = 'after_end';
    end if;
    insert into makeup_candidates (request_id, starts_at, ends_at, proposed_by)
    values (v_id, t, t + make_interval(mins => e.duration_min), 'student');
  end loop;
  insert into lesson_notices (makeup_request_id, event, recipient_kind, recipient_id) values (v_id, 'makeup_ask', 'tutor', s.tutor_id);
  return jsonb_build_object('makeup_request_id', v_id, 'repeated', false);
end $$;
revoke all on function lms_makeup_request_core(uuid, uuid, jsonb, timestamptz, text, uuid, uuid) from public, anon, authenticated;

create or replace function admin_makeup_request(p_lesson uuid, p_item uuid, p_slots jsonb, p_requested_at timestamptz, p_comp uuid default null)
returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception '운영자(추가 인증 완료)만 처리할 수 있습니다.' using errcode = '42501'; end if;
  return lms_makeup_request_core(p_lesson, p_item, p_slots, p_requested_at, 'admin_on_behalf', auth.uid(), p_comp);
end $$;
revoke all on function admin_makeup_request(uuid, uuid, jsonb, timestamptz, uuid) from public, anon;
grant execute on function admin_makeup_request(uuid, uuid, jsonb, timestamptz, uuid) to authenticated;

-- 학생 본인: 보강 가능한 날짜 중에서만, 한 번에 최대 2개 (2026-10-27 대표) — 보상수업도 같음
create or replace function student_makeup_request(p_lesson uuid, p_item uuid, p_slots jsonb, p_comp uuid default null)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_student uuid := my_student_id();
  v_owner uuid;
  x jsonb;
begin
  if p_comp is not null then
    select s.student_id into v_owner from lms_comp_source(p_comp) s;
  else
    select s.student_id into v_owner from lms_makeup_source(p_lesson, p_item) s;
  end if;
  if v_student is null or v_owner <> v_student then
    raise exception '본인 수업만 보강 신청할 수 있습니다.' using errcode = '42501';
  end if;
  if jsonb_typeof(p_slots) <> 'array' or jsonb_array_length(p_slots) not between 1 and 2 then
    raise exception '보강 날짜를 1~2개 골라 주세요.';
  end if;
  for x in select * from jsonb_array_elements(p_slots) loop
    if not exists (select 1 from lms_makeup_options(p_lesson, p_item, p_comp) o where o.starts_at = (x ->> 'starts_at')::timestamptz) then
      raise exception '보강 가능한 날짜가 아닙니다. 화면을 새로 열어 다시 골라 주세요.' using hint = 'not_an_option';
    end if;
  end loop;
  return lms_makeup_request_core(p_lesson, p_item, p_slots, now(), 'student_app', auth.uid(), p_comp);
end $$;
revoke all on function student_makeup_request(uuid, uuid, jsonb, uuid) from public, anon;
grant execute on function student_makeup_request(uuid, uuid, jsonb, uuid) to authenticated;

-- ---------------------------------------------------------------------
-- 5. 운영진 확정: 보상 신청이면 보상 수업(kind compensation) + 보상권 'used' (2300 그대로 + 보상 분기)
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
-- 6. 확정한 보강을 잘못 넣었을 때 없애기 (1700 그대로 + 보상 수업이면 보상권 다시 'available')
-- ---------------------------------------------------------------------
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
  if not found then raise exception '보강 신청 기록이 없는 보강입니다 (이관한 보강은 시트에서 확인).'; end if;
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

-- 보상권이 없어지면(강사 노쇼를 다른 결과로 고침 → voided) 열린 보상 신청도 닫음 (기록은 남김)
create or replace function compensations_close_requests() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.status = 'voided' and old.status <> 'voided' then
    update makeup_requests set status = 'withdrawn', decided_at = now()
    where compensation_id = new.id and status in ('requested', 'countered');
    update lesson_notices set status = 'not_needed'
    where status = 'pending' and makeup_request_id in (select id from makeup_requests where compensation_id = new.id);
  end if;
  return null;
end $$;
revoke all on function compensations_close_requests() from public, anon, authenticated;
drop trigger if exists compensations_close_requests on compensations;
create trigger compensations_close_requests after update of status on compensations
  for each row execute function compensations_close_requests();

-- ---------------------------------------------------------------------
-- 7. 학생 화면 (3700 그대로 + 보상 권리 · 신청 내역에 원래 수업·강사·확정 날짜·보상 구분)
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
  -- 수업·보강은 지금 수강권 + 아직 열린 다른 수강권(재등록 결제 뒤에도 이전 수강권의 보강이 남을 수 있음)
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
    'makeup_rights', coalesce((
      select jsonb_agg(r order by r ->> 'original_at', r ->> 'comp_id' nulls first) from (
        select jsonb_build_object('lesson_id', l.id, 'item_id', null, 'original_at', l.starts_at,
                 'tutor_leave', l.class_status = 'Tutor long-term leave') as r
        from lessons l
        where l.enrollment_id = any(v_open) and l.voided_at is null and (lms_grants_makeup(l.class_status) or l.class_status = 'Tutor long-term leave')
          and not exists (select 1 from lessons x where x.makeup_of = l.id and x.state <> 'canceled')
        union all
        -- 시트에서 옮긴 보강은 날짜만 있음 → 휴무 처리 수업이면 그 수업 시각, 아니면 날짜만 (3700: 00:00 으로 보이던 것)
        select jsonb_build_object('lesson_id', null, 'item_id', m.id,
                 'original_at', coalesce((select li.starts_at from leave_items li where li.migrated_item_id = m.id order by li.starts_at limit 1),
                                         m.original_date::timestamp at time zone 'Asia/Seoul'),
                 'time_known', exists (select 1 from leave_items li where li.migrated_item_id = m.id),
                 'tutor_leave', coalesce(m.tutor_leave, false))
        from migrated_items m where m.enrollment_id = any(v_open) and m.kind = 'makeup_open'
          -- 휴무 처리에서 대체강사 답 대기·미정인 수업은 보강 신청 대상이 아님 (기존 강사 보강으로 정하면 그때 보강)
          and not exists (select 1 from leave_items li where li.migrated_item_id = m.id and li.lesson_gone_at is null
                          and li.choice in ('undecided', 'substitute'))
        union all
        -- 강사 노쇼 무료 보상수업 (4100): 날짜를 안 잡은 것, 사용 기한(수강기간·기한 안 재등록이면 이월) 안
        select jsonb_build_object('lesson_id', null, 'item_id', null, 'comp_id', c.id, 'original_at', src.starts_at,
                 'tutor', t.name, 'use_until', lms_comp_use_until(c.enrollment_id), 'tutor_leave', false)
        from compensations c
        join lessons src on src.id = c.source_lesson_id
        join tutors t on t.id = src.tutor_id
        where c.student_id = v_student and c.status = 'available' and lms_comp_use_until(c.enrollment_id) >= v_today) q), '[]'::jsonb),
    -- 휴무 처리 중인데 수업 줄이 아직 없는 수업 (시트에서 옮긴 휴가 수업 · 미정 또는 대체강사 확정 전) → 일정에 '일정 조율 중' (3700)
    'leave_pending', coalesce((
      select jsonb_agg(jsonb_build_object('id', li.id, 'starts_at', li.starts_at, 'ends_at', li.ends_at) order by li.starts_at)
      from leave_items li
      where li.student_id = v_student and li.lesson_id is null and li.lesson_gone_at is null and li.starts_at > now()
        and (li.choice = 'undecided' or (li.choice = 'substitute' and li.sub_stage <> 'confirmed'))), '[]'::jsonb),
    -- 신청 내역: 원래 수업 시각·강사, 확정된 날짜 (4100: 확정 뒤 상세에 원래 수업·강사가 안 보이던 것)
    'makeup_requests', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', r.id, 'status', r.status, 'lesson_id', r.source_lesson_id, 'item_id', r.migrated_item_id, 'comp_id', r.compensation_id,
        'requested_at', r.requested_at, 'confirmed_lesson_id', r.confirmed_lesson_id, 'tutor_answered_at', r.tutor_answered_at,
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
    -- 휴무 안내: 대체강사가 가능하다고 한 수업(답 기다림)·확정된 대체 수업·보강으로 정한 수업만. 지난 수업은 빼고
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
    -- 변경권: 지금 기간과 쓴 기록 (대표 10/29: 변경권 칸 누르면 언제 썼는지)
    'credit_period', case when v_period.id is null then null else jsonb_build_object('start', v_period.start_date, 'end', v_period.end_date) end,
    'credit_uses', coalesce((
      select jsonb_agg(jsonb_build_object('at', c.created_at, 'reason', c.reason, 'delta', c.delta, 'lesson_at', l.starts_at) order by c.created_at)
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
-- 8. 강사 화면 (4000 그대로 + 보상 신청·보상 수업 구분: makeups.compensation, lessons.compensation_of)
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
        'compensation_of', (select x.starts_at from compensations cc join lessons x on x.id = cc.source_lesson_id where cc.id = l.compensation_id),
        'count', lms_lesson_count(l.id),
        'topics', cr.covered_topics, 'remarks', cr.remarks, 'student_late', coalesce(cr.student_late, false), 'recorded_at', cr.first_submitted_at,
        'locked', exists (select 1 from payroll_items p where p.lesson_id = l.id),
        'compensation', (select c.status from compensations c where c.source_lesson_id = l.id),
        'leave_open', l.state = 'scheduled' and exists (select 1 from leave_items li where li.lesson_id = l.id and li.lesson_gone_at is null
                              and (li.choice = 'undecided' or (li.choice = 'substitute' and li.sub_stage <> 'confirmed'))))
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
        and l.starts_at >= (select min(u.created_at) from app_users u where u.tutor_id = v_tutor)
        and not exists (select 1 from leave_items li where li.lesson_id = l.id and li.lesson_gone_at is null
                         and (li.choice = 'undecided' or (li.choice = 'substitute' and li.sub_stage <> 'confirmed')))), '[]'::jsonb),
    'makeups', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', r.id, 'student', coalesce(s.display_name, s.name_en),
        'original_at', src.starts_at, 'original_date', mi.original_date,
        'compensation', r.compensation_id is not null,
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
      where r.tutor_id = v_tutor and r.status in ('requested', 'countered')), '[]'::jsonb),
    -- 대체 수업 요청: 운영진이 이 강사를 대체강사로 골라 답을 기다리는 수업 (2600). 휴무 강사 이름은 안 보임
    'covers', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', i.id, 'student', coalesce(s.display_name, s.name_en), 'starts_at', i.starts_at, 'ends_at', i.ends_at,
        'busy', lms_sub_conflict(v_tutor, i.starts_at, i.ends_at, i.lesson_id) is not null)
        order by i.starts_at)
      from leave_items i join students s on s.id = i.student_id
      where i.sub_tutor_id = v_tutor and i.choice = 'substitute' and i.sub_stage = 'asked' and i.starts_at > now() and i.lesson_gone_at is null), '[]'::jsonb));
end $$;
revoke all on function tutor_screen(uuid, date, date) from public, anon;
grant execute on function tutor_screen(uuid, date, date) to authenticated;

-- ---------------------------------------------------------------------
-- 9. 강사 보강 답: 다른 수업·휴무와 겹치는 시간은 '가능'으로 보낼 수 없음 (11/3 ChatGPT 점검 ①: 겹치는 시간도 체크·전송됨)
--    강사 화면 'busy'·운영진 확정과 같은 판정(lms_makeup_conflict). 2000 그대로 + 이 검사
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
    raise exception 'One of the times you chose overlaps another class or time off. Please reload the page.' using hint = 'busy';
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
