-- =====================================================================
-- ③ 학생 LMS: 수업 확인 · 직접 취소 · 보강 신청 · 강사 휴무 안내에 답하기 (2026-10-28 대표: Q1 A안 · Q2 날짜 고르기 · Q3 처음부터 켬)
--  - 학생 본인(이메일 코드 로그인), 또는 운영자(TOTP 완료)가 ?student= 로 그대로 보기·대신 입력 (같은 검사, 운영자는 admin_ 함수)
--  - 취소: 이미 있는 student_change_lesson / admin_change_lesson (1700) 그대로
--  - 보강 신청: admin_makeup_request 와 같은 처리(lms_makeup_request_core). 학생은 '보강 가능한 날짜' 중에서만, 최대 2개
--    → 강사 화면 보강 요청 → 운영진 확정 (D-43, 학생 신청만으로 확정되지 않음)
--  - 휴무 안내 답 (A안 한 번에): [좋아요] = admin_leave_student_ok 와 같은 처리 (대체강사가 가능하다고 한 수업만)
--    [기존 강사님과 보강] = admin_leave_choose 'wait' 와 같은 처리 → 이어서 보강 날짜 고르기
--  - 학생 화면 보기 전 운영진이 준비 중인 휴무 수업(대체강사 묻는 중)은 학생에게 보이지 않음
--  - 학생 로그인 계정 만들기 admin_student_login (강사 admin_tutor_login 과 같은 방식)
-- 기존 표·데이터를 지우지 않음. 다시 실행해도 같은 결과
-- =====================================================================

-- 누구의 학생 화면인지: 학생 본인, 또는 운영자(TOTP 완료)가 고른 학생
create or replace function lms_screen_student(p_student uuid) returns uuid
language plpgsql stable security definer set search_path = public as $$
declare
  mine uuid := my_student_id();
begin
  if is_admin() and p_student is not null then return p_student; end if;
  if mine is null or (p_student is not null and p_student <> mine) then
    raise exception '학생 계정으로 로그인해 주세요.' using errcode = '42501';
  end if;
  return mine;
end $$;
revoke all on function lms_screen_student(uuid) from public, anon, authenticated;

-- 학생 화면에서 보는 수강권: 수강 중·결제 확인된 것 중 가장 최근 (없으면 가장 최근 것)
create or replace function lms_student_enrollment(p_student uuid) returns uuid
language sql stable security definer set search_path = public as $$
  select e.id from enrollments e where e.student_id = p_student
  order by (e.status in ('active', 'confirmed')) desc, e.seq desc limit 1
$$;
revoke all on function lms_student_enrollment(uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- 1. 보강 가능한 날짜 (운영진 휴무 화면 admin_leave_makeup_options 와 같은 계산을 모든 보강에)
--    강사 일정·휴무·보통 수업 시간 · 학생 다른 수업 · 종료일 / 정규 요일이 아닌 날의 정규 시각
--    강사 휴무 보강은 휴무가 끝난 날부터, 종료일 뒤 정규 요일도 (휴무 보강은 종료일 제한 없음, A41)
-- ---------------------------------------------------------------------
create or replace function lms_makeup_options(p_lesson uuid, p_item uuid)
returns table (section text, starts_at timestamptz, ends_at timestamptz)
language plpgsql stable security definer set search_path = public as $$
declare
  s record;
  e enrollments;
  v_leave boolean;
  v_back date;
  v_today date := (now() at time zone 'Asia/Seoul')::date;
begin
  select * into s from lms_makeup_source(p_lesson, p_item);
  select * into e from enrollments where id = s.enrollment_id;
  v_leave := s.tutor_leave or exists (select 1 from lessons l where l.id = p_lesson and l.class_status = 'Tutor long-term leave');
  select (o.ends_at at time zone 'Asia/Seoul')::date into v_back
  from leave_items li join tutor_time_off o on o.id = li.time_off_id
  where (li.lesson_id = p_lesson or li.migrated_item_id = p_item) limit 1;
  v_back := coalesce(v_back, v_today + 1);

  return query
  with rs as (
    select r.weekday, r.start_time_kst from regular_schedules r
    where r.student_id = s.student_id and r.tutor_id = s.tutor_id and (r.effective_to is null or r.effective_to >= v_today)
  ),
  slots as (
    select 'in_period'::text as sec, ((d::date + t.start_time_kst) at time zone 'Asia/Seoul') as x
    from generate_series(greatest(v_today + 1, v_back), e.final_end_date, interval '1 day') d
    cross join (select distinct start_time_kst from rs) t
    where extract(dow from d) not in (select weekday from rs)
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
revoke all on function lms_makeup_options(uuid, uuid) from public, anon, authenticated;

create or replace function student_makeup_options(p_student uuid, p_lesson uuid, p_item uuid)
returns table (section text, starts_at timestamptz, ends_at timestamptz)
language plpgsql stable security definer set search_path = public as $$
declare
  v_student uuid := lms_screen_student(p_student);
begin
  if (select x.student_id from lms_makeup_source(p_lesson, p_item) x) <> v_student then
    raise exception '본인 수업만 볼 수 있습니다.' using errcode = '42501';
  end if;
  return query select * from lms_makeup_options(p_lesson, p_item);
end $$;
revoke all on function student_makeup_options(uuid, uuid, uuid) from public, anon;
grant execute on function student_makeup_options(uuid, uuid, uuid) to authenticated;

-- ---------------------------------------------------------------------
-- 2. 보강 신청: 운영진 대신 입력(admin_makeup_request)과 학생 신청이 같은 처리
-- ---------------------------------------------------------------------
create or replace function lms_makeup_request_core(p_lesson uuid, p_item uuid, p_slots jsonb, p_requested_at timestamptz, p_via text, p_actor uuid)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  s record;
  e enrollments;
  v_id uuid;
  x jsonb;
  t timestamptz;
begin
  select * into s from lms_makeup_source(p_lesson, p_item);
  select * into e from enrollments where id = s.enrollment_id;
  if jsonb_typeof(p_slots) <> 'array' or jsonb_array_length(p_slots) = 0 then raise exception '보강 시간을 하나 이상 넣어 주세요.'; end if;
  select id into v_id from makeup_requests
  where status in ('requested', 'countered') and (source_lesson_id = p_lesson or migrated_item_id = p_item);
  if found then return jsonb_build_object('makeup_request_id', v_id, 'repeated', true); end if;
  perform set_config('app.actor_id', coalesce(p_actor::text, ''), true);
  perform set_config('app.actor_via', 'lms_makeup_request_core', true);
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
revoke all on function lms_makeup_request_core(uuid, uuid, jsonb, timestamptz, text, uuid) from public, anon, authenticated;

create or replace function admin_makeup_request(p_lesson uuid, p_item uuid, p_slots jsonb, p_requested_at timestamptz)
returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception '운영자(추가 인증 완료)만 처리할 수 있습니다.' using errcode = '42501'; end if;
  return lms_makeup_request_core(p_lesson, p_item, p_slots, p_requested_at, 'admin_on_behalf', auth.uid());
end $$;
revoke all on function admin_makeup_request(uuid, uuid, jsonb, timestamptz) from public, anon;
grant execute on function admin_makeup_request(uuid, uuid, jsonb, timestamptz) to authenticated;

-- 학생 본인: 보강 가능한 날짜 중에서만, 한 수업당 최대 2개 (2026-10-27 대표)
create or replace function student_makeup_request(p_lesson uuid, p_item uuid, p_slots jsonb)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_student uuid := my_student_id();
  x jsonb;
begin
  if v_student is null or (select s.student_id from lms_makeup_source(p_lesson, p_item) s) <> v_student then
    raise exception '본인 수업만 보강 신청할 수 있습니다.' using errcode = '42501';
  end if;
  if jsonb_typeof(p_slots) <> 'array' or jsonb_array_length(p_slots) not between 1 and 2 then
    raise exception '보강 날짜를 1~2개 골라 주세요.';
  end if;
  for x in select * from jsonb_array_elements(p_slots) loop
    if not exists (select 1 from lms_makeup_options(p_lesson, p_item) o where o.starts_at = (x ->> 'starts_at')::timestamptz) then
      raise exception '보강 가능한 날짜가 아닙니다. 화면을 새로 열어 다시 골라 주세요.' using hint = 'not_an_option';
    end if;
  end loop;
  return lms_makeup_request_core(p_lesson, p_item, p_slots, now(), 'student_app', auth.uid());
end $$;
revoke all on function student_makeup_request(uuid, uuid, jsonb) from public, anon;
grant execute on function student_makeup_request(uuid, uuid, jsonb) to authenticated;

-- ---------------------------------------------------------------------
-- 3. 휴무 안내 답: 운영진 화면과 같은 처리 (권한 검사만 뺀 사본 — 운영진 함수는 그대로)
-- ---------------------------------------------------------------------
create or replace function lms_leave_choose_core(p_items uuid[], p_choice text, p_sub_tutor uuid)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  it leave_items;
  l lessons;
  v_conf text;
  v_changed integer := 0;
begin
  if p_choice not in ('substitute', 'wait') then raise exception '대체강사 또는 기다림 중에서 골라 주세요.'; end if;
  if p_choice = 'substitute' and p_sub_tutor is null then raise exception '대체강사를 골라 주세요.'; end if;
  perform set_config('app.actor_id', me::text, true);
  perform set_config('app.actor_via', 'lms_leave_choose_core', true);

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
revoke all on function lms_leave_choose_core(uuid[], text, uuid) from public, anon, authenticated;

create or replace function lms_leave_student_ok_core(p_items uuid[])
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  it leave_items;
  v_conf text;
  v_lesson uuid;
  v_changed integer := 0;
begin
  perform set_config('app.actor_id', me::text, true);
  perform set_config('app.actor_via', 'lms_leave_student_ok_core', true);
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
revoke all on function lms_leave_student_ok_core(uuid[]) from public, anon, authenticated;

-- p_answer: 'ok' = 좋아요(대체강사와 평소 시간) / 'makeup' = 기존 강사님과 보강
-- 학생이 답할 수 있는 수업 = 대체강사가 가능하다고 한(tutor_ok) 아직 확정 전 · 시작 전 수업
create or replace function student_leave_answer(p_items uuid[], p_answer text)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_student uuid := my_student_id();
begin
  if p_answer not in ('ok', 'makeup') then raise exception '답을 골라 주세요.'; end if;
  if coalesce(array_length(p_items, 1), 0) = 0 then raise exception '수업이 없습니다.'; end if;
  if v_student is null or exists (select 1 from leave_items where id = any(p_items) and student_id <> v_student)
     or (select count(*) from leave_items where id = any(p_items)) <> array_length(p_items, 1) then
    raise exception '본인 수업만 답할 수 있습니다.' using errcode = '42501';
  end if;
  if exists (select 1 from leave_items where id = any(p_items)
             and (choice <> 'substitute' or sub_stage <> 'tutor_ok' or starts_at <= now())) then
    raise exception '이미 정해졌거나 지난 수업이 있어요. 화면을 새로 열어 주세요.' using hint = 'not_open';
  end if;
  if p_answer = 'ok' then return lms_leave_student_ok_core(p_items); end if;
  return lms_leave_choose_core(p_items, 'wait', null);
end $$;
revoke all on function student_leave_answer(uuid[], text) from public, anon;
grant execute on function student_leave_answer(uuid[], text) to authenticated;

-- ---------------------------------------------------------------------
-- 4. 학생 화면 한 번에 읽기 (본인 것만: 수업·변경권·보강·휴무 안내·결제 확인일·적립금)
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
begin
  select * into st from students where id = v_student;
  select * into e from enrollments where id = lms_student_enrollment(v_student);
  select * into v_period from enrollment_periods p
  where p.enrollment_id = e.id and p.start_date <= (now() at time zone 'Asia/Seoul')::date order by p.idx desc limit 1;
  -- 수업·보강은 지금 수강권 + 아직 열린 다른 수강권(재등록 결제 뒤에도 이전 수강권의 보강이 남을 수 있음)
  v_open := array(select x.id from enrollments x where x.student_id = v_student and (x.status in ('active', 'confirmed') or x.id = e.id));
  return jsonb_build_object(
    'student', jsonb_build_object('id', st.id, 'code', st.code, 'name_ko', st.name_ko, 'timezone', st.timezone),
    'enrollment', case when e.id is null then null else jsonb_build_object(
      'id', e.id, 'weeks', e.weeks, 'legacy_label', e.legacy_label, 'weekly_count', e.weekly_count, 'duration_min', e.duration_min,
      'start_date', e.start_date, 'final_end_date', e.final_end_date, 'status', e.status,
      'lessons_total', coalesce((select c.sheet_total from import_checks c where c.enrollment_id = e.id), e.lessons_purchased + e.lessons_carried_in),
      'credits_left', case when v_period.id is null then 0 else credit_balance(v_period.id) end,
      'credits_granted', coalesce(v_period.credits_granted, 0),
      'confirmed_on', (select min((p.confirmed_at at time zone 'Asia/Seoul')::date) from payments p where p.enrollment_id = e.id and p.confirmed_at is not null),
      'renewal_paid', exists (select 1 from enrollments n where n.previous_enrollment_id = e.id and n.status in ('confirmed', 'active'))) end,
    'lessons', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', l.id, 'kind', l.kind, 'starts_at', l.starts_at, 'ends_at', l.ends_at, 'state', l.state, 'class_status', l.class_status,
        'tutor', t.name, 'meet_url', t.meet_url, 'makeup_of', l.makeup_of) order by l.starts_at)
      from lessons l join tutors t on t.id = l.tutor_id
      where l.enrollment_id = any(v_open) and l.voided_at is null), '[]'::jsonb),
    -- 보강을 받을 수 있는데 아직 날짜가 없는 것 (취소한 수업 · 시트에서 넘어온 날짜 미정 보강)
    'makeup_rights', coalesce((
      select jsonb_agg(r order by r ->> 'original_at') from (
        select jsonb_build_object('lesson_id', l.id, 'item_id', null, 'original_at', l.starts_at,
                 'tutor_leave', l.class_status = 'Tutor long-term leave') as r
        from lessons l
        where l.enrollment_id = any(v_open) and l.voided_at is null and (lms_grants_makeup(l.class_status) or l.class_status = 'Tutor long-term leave')
          and not exists (select 1 from lessons x where x.makeup_of = l.id and x.state <> 'canceled')
        union all
        select jsonb_build_object('lesson_id', null, 'item_id', m.id, 'original_at', m.original_date::timestamp at time zone 'Asia/Seoul',
                 'tutor_leave', coalesce(m.tutor_leave, false))
        from migrated_items m where m.enrollment_id = any(v_open) and m.kind = 'makeup_open') q), '[]'::jsonb),
    'makeup_requests', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', r.id, 'status', r.status, 'lesson_id', r.source_lesson_id, 'item_id', r.migrated_item_id,
        'requested_at', r.requested_at, 'confirmed_lesson_id', r.confirmed_lesson_id,
        'candidates', (select coalesce(jsonb_agg(c.starts_at order by c.starts_at), '[]'::jsonb) from makeup_candidates c where c.request_id = r.id and c.proposed_by = 'student'))
        order by r.requested_at desc)
      from makeup_requests r where r.student_id = v_student and r.status in ('requested', 'countered', 'confirmed')
        and r.requested_at > now() - interval '60 days'), '[]'::jsonb),
    -- 휴무 안내: 대체강사가 가능하다고 한 수업(답 기다림)·확정된 대체 수업·보강으로 정한 수업만. 지난 수업은 빼고
    'leave', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', li.id, 'starts_at', li.starts_at, 'choice', li.choice, 'stage', li.sub_stage, 'sub_tutor', sub.name,
        'lesson_id', li.lesson_id, 'item_id', li.migrated_item_id,
        'off_from', o.starts_at, 'off_to', o.ends_at) order by li.starts_at)
      from leave_items li
      join tutor_time_off o on o.id = li.time_off_id
      left join tutors sub on sub.id = li.sub_tutor_id
      where li.student_id = v_student and li.starts_at > now()
        and ((li.choice = 'substitute' and li.sub_stage in ('tutor_ok', 'confirmed')) or li.choice = 'wait')), '[]'::jsonb),
    'points', coalesce((
      select jsonb_agg(jsonb_build_object('id', g.id, 'on', (g.created_at at time zone 'Asia/Seoul')::date, 'kind', g.kind, 'amount', g.amount, 'note', g.note)
        order by g.created_at)
      from reward_ledger g where g.student_id = v_student), '[]'::jsonb));
end $$;
revoke all on function student_screen(uuid) from public, anon;
grant execute on function student_screen(uuid) to authenticated;

-- 운영자 보기 막대: 학생 목록 + 로그인 계정 여부
create or replace function admin_student_accounts()
returns table (id uuid, code text, name_ko text, has_login boolean)
language plpgsql stable security definer set search_path = public as $$
begin
  if not is_admin() then raise exception '운영자(추가 인증 완료)만 볼 수 있습니다.' using errcode = '42501'; end if;
  return query select s.id, s.code, s.name_ko, exists (select 1 from app_users u where u.student_id = s.id)
  from students s order by s.code;
end $$;
revoke all on function admin_student_accounts() from public, anon;
grant execute on function admin_student_accounts() to authenticated;

-- ---------------------------------------------------------------------
-- 5. 학생 로그인 계정 만들기 (admin_tutor_login 과 같은 방식, 대표만). 비밀번호 없음 — 이메일 6자리 코드 (POL-AC-03)
--    학생 기록의 이메일 칸은 바꾸지 않음 (POL-AC-04: 이메일이 같다고 자동 연결하지 않고, 대표가 고른 학생에만 연결)
-- ---------------------------------------------------------------------
create or replace function admin_student_login(p_student uuid, p_email text)
returns table (student_name text, email text, created boolean)
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_email text := lower(trim(coalesce(p_email, '')));
  v_name text;
  v_linked uuid;
  v_uid uuid;
  v_role text;
  v_new boolean := false;
begin
  if not is_owner() then raise exception '대표 계정(추가 인증 완료)만 학생 로그인 계정을 만들 수 있습니다.' using errcode = '42501'; end if;
  if v_email !~ '^[^\s@]+@[^\s@]+\.[^\s@]+$' then raise exception '이메일 주소를 다시 확인해 주세요.' using errcode = '22023'; end if;
  select s.name_ko into v_name from students s where s.id = p_student for update;
  if v_name is null then raise exception '학생을 찾을 수 없습니다.' using errcode = 'P0002'; end if;

  select u.auth_user_id into v_linked from app_users u where u.student_id = p_student;
  if v_linked is not null then
    if (select lower(a.email) from auth.users a where a.id = v_linked) = v_email then
      return query select v_name, v_email, false; return;
    end if;
    raise exception '% 학생은 이미 다른 이메일로 연결돼 있습니다.', v_name using errcode = '23505';
  end if;

  select a.id into v_uid from auth.users a where lower(a.email) = v_email;
  if v_uid is not null then
    select u.role into v_role from app_users u where u.auth_user_id = v_uid;
    if v_role is not null then raise exception '이 이메일은 이미 다른 사람(%)에 연결돼 있습니다.', v_role using errcode = '23505'; end if;
    update auth.users set email_confirmed_at = coalesce(email_confirmed_at, now()) where id = v_uid;
  else
    v_uid := gen_random_uuid();
    v_new := true;
    insert into auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
      raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
      confirmation_token, recovery_token, email_change_token_new, email_change, email_change_token_current,
      phone_change, phone_change_token, reauthentication_token, is_sso_user, is_anonymous)
    values ('00000000-0000-0000-0000-000000000000', v_uid, 'authenticated', 'authenticated', v_email,
      crypt(gen_random_uuid()::text, gen_salt('bf')), now(),
      '{"provider":"email","providers":["email"]}', '{}', now(), now(),
      '', '', '', '', '', '', '', '', false, false);
    insert into auth.identities (id, user_id, provider_id, provider, identity_data, created_at, updated_at)
    values (gen_random_uuid(), v_uid, v_uid::text, 'email',
      jsonb_build_object('sub', v_uid::text, 'email', v_email, 'email_verified', true, 'phone_verified', false), now(), now());
  end if;

  insert into app_users (auth_user_id, role, student_id) values (v_uid, 'student', p_student);
  return query select v_name, v_email, v_new;
end $$;
revoke all on function admin_student_login(uuid, text) from public, anon;
grant execute on function admin_student_login(uuid, text) to authenticated;
