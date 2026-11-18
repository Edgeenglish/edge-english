-- =====================================================================
-- 정규 시간 변경: 모든 정규 수업 같은 시작 시간 (정책 원본 H26(208) 보충 7·8, 대표 11/18 확정)
--  · 학생 신청 = 일정 전체(요일 N개 + 시간 하나)를 1·2순위로. 요일만 바꾸거나, 시간을 바꾸면 모든 수업 함께
--  · 주 3회 학생의 '1회만 다른 시간'은 운영진이 [정규 일정 수정]으로 (학생 화면 없음) · 운영진 수정은 제한 없음
--  · items 모양: [{c1:{days:[요일…],time,week,first}, c2:{…}|null}] (한 신청에 한 줄)
-- 지우는 문장 없음 (같은 이름 함수 교체만)
-- =====================================================================

-- 일정 두 개(옛·새)를 비교해 그 주에 바뀌는 첫 수업 날짜 (옛에만 있거나 새에만 있는 요일·시각 중 가장 빠른 날)
create or replace function lms_rc_first2(p_week date, p_old jsonb, p_new jsonb) returns date language sql immutable as $$
  select min(lms_rc_day(p_week, (x ->> 'weekday')::int)) from (
    select o.x from jsonb_array_elements(p_old) o(x)
    where not exists (select 1 from jsonb_array_elements(p_new) n(y) where (n.y ->> 'weekday')::int = (o.x ->> 'weekday')::int and (n.y ->> 'time')::time = (o.x ->> 'time')::time)
    union all
    select n.y from jsonb_array_elements(p_new) n(y)
    where not exists (select 1 from jsonb_array_elements(p_old) o(x) where (n.y ->> 'weekday')::int = (o.x ->> 'weekday')::int and (n.y ->> 'time')::time = (o.x ->> 'time')::time)
  ) d(x)
$$;

-- 옮긴 수업이 수강 종료일 뒤로 밀리지 않는지: 그 주부터 종료일까지 새 일정 수업 수 >= 옛 일정 수업 수
create or replace function lms_rc_fits2(p_week date, p_old jsonb, p_new jsonb, p_end date) returns boolean language sql immutable as $$
  select coalesce((select sum(case when lms_rc_day(p_week, (x ->> 'weekday')::int) > p_end then 0 else (p_end - lms_rc_day(p_week, (x ->> 'weekday')::int)) / 7 + 1 end) from jsonb_array_elements(p_new) x), 0)
      >= coalesce((select sum(case when lms_rc_day(p_week, (x ->> 'weekday')::int) > p_end then 0 else (p_end - lms_rc_day(p_week, (x ->> 'weekday')::int)) / 7 + 1 end) from jsonb_array_elements(p_old) x), 0)
$$;

create or replace function lms_rc_week_ok2(p_enrollment uuid, p_old jsonb, p_new jsonb, p_today date, p_week date, p_skip uuid default null)
returns boolean language plpgsql stable security definer set search_path = public as $$
declare
  e enrollments;
  f date;
begin
  select * into e from enrollments where id = p_enrollment;
  if p_week is null or extract(isodow from p_week) <> 1 or p_week < lms_rc_monday(p_today) + 7 or p_week > e.final_end_date then return false; end if;
  f := lms_rc_first2(p_week, p_old, p_new);
  return f is not null and f <= e.final_end_date and p_today <= f - 4 and lms_rc_fits2(p_week, p_old, p_new, e.final_end_date)
    and not exists (select 1 from regular_change_requests r where r.enrollment_id = p_enrollment and r.status = 'confirmed'
                      and r.period_id = lms_lesson_period(p_enrollment, f) and r.id is distinct from p_skip);
end $$;

create or replace function lms_rc_week2(p_enrollment uuid, p_old jsonb, p_new jsonb, p_today date, p_skip uuid default null)
returns date language plpgsql stable security definer set search_path = public as $$
declare
  e enrollments;
  w date;
begin
  select * into e from enrollments where id = p_enrollment;
  w := lms_rc_monday(p_today) + 7;
  while w <= e.final_end_date loop
    if lms_rc_week_ok2(p_enrollment, p_old, p_new, p_today, w, p_skip) then return w; end if;
    w := w + 7;
  end loop;
  return null;
end $$;

-- 후보(요일들 + 시간) → 정규 일정 [{weekday,time}] (요일 순)
create or replace function lms_rc_slots_of(p_cand jsonb) returns jsonb language sql immutable as $$
  select jsonb_agg(jsonb_build_object('weekday', d::int, 'time', to_char((p_cand ->> 'time')::time, 'HH24:MI')) order by d::int)
  from (select distinct jsonb_array_elements_text(p_cand -> 'days') d) x
$$;

revoke all on function lms_rc_week_ok2(uuid, jsonb, jsonb, date, date, uuid) from public, anon, authenticated;
revoke all on function lms_rc_week2(uuid, jsonb, jsonb, date, uuid) from public, anon, authenticated;

-- 신청: p_items = [{c1:{days,time}, c2:{days,time}|null}] · p_start = 학생이 고른 시작 주(월요일), 없으면 후보마다 가장 빠른 주
create or replace function student_regular_change_request(p_student uuid, p_items jsonb, p_reason text default null, p_start date default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_student uuid := lms_screen_student(p_student);
  v_today date := (now() at time zone 'Asia/Seoul')::date;
  c record;
  x jsonb;
  k text;
  cand jsonb;
  v_new jsonb;
  v_prev jsonb := null;
  v_item jsonb;
  s jsonb;
  w date;
  v_id uuid;
begin
  select * into c from lms_rc_context(v_student);
  if (c.e).id is null or c.slots is null then raise exception '지금은 정규 시간 변경을 신청할 수 없어요.'; end if;
  if c.future_pending then raise exception '이미 정규 시간 변경이 예정돼 있어요.'; end if;
  if exists (select 1 from regular_change_requests where student_id = v_student and status = 'pending') then
    raise exception '확인 중인 신청이 있어요.' using hint = 'pending';
  end if;
  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) <> 1 then raise exception '새 일정을 골라 주세요.'; end if;
  x := p_items -> 0;
  if x -> 'c1' is null or jsonb_typeof(x -> 'c1') <> 'object' then raise exception '새 일정을 골라 주세요.'; end if;
  v_item := '{}'::jsonb;
  foreach k in array array['c1', 'c2'] loop
    cand := x -> k;
    if cand is null or jsonb_typeof(cand) <> 'object' then v_item := v_item || jsonb_build_object(k, null); continue; end if;
    if jsonb_typeof(cand -> 'days') <> 'array' or extract(minute from (cand ->> 'time')::time)::int not in (0, 30)
       or exists (select 1 from jsonb_array_elements_text(cand -> 'days') d where d::int not between 0 and 6) then
      raise exception '일정을 다시 골라 주세요.';
    end if;
    v_new := lms_rc_slots_of(cand);
    if jsonb_array_length(v_new) <> jsonb_array_length(c.slots) then
      raise exception '요일을 %개 골라 주세요.', jsonb_array_length(c.slots);
    end if;
    if lms_rc_first2(lms_rc_monday(v_today), c.slots, v_new) is null then raise exception '지금 일정과 같아요.'; end if;
    if v_prev is not null and v_prev = v_new then raise exception '1순위와 같아요.'; end if;
    if p_start is null then
      w := lms_rc_week2((c.e).id, c.slots, v_new, v_today);
    elsif lms_rc_week_ok2((c.e).id, c.slots, v_new, v_today, p_start) then
      w := p_start;
    else
      raise exception '고른 시작 주에는 바꿀 수 없어요. 다시 골라 주세요.' using hint = 'bad_start';
    end if;
    if w is null then raise exception '고른 일정이 이제 비어 있지 않아요. 다시 골라 주세요.' using hint = 'not_free'; end if;
    for s in select * from jsonb_array_elements(v_new) loop
      if not exists (select 1 from jsonb_array_elements(c.slots) o where (o ->> 'weekday')::int = (s ->> 'weekday')::int and (o ->> 'time')::time = (s ->> 'time')::time)
         and not lms_rc_free((c.tutor).id, v_student, w, (c.e).final_end_date, (s ->> 'weekday')::int, (s ->> 'time')::time, (c.e).duration_min) then
        raise exception '고른 일정이 이제 비어 있지 않아요. 다시 골라 주세요.' using hint = 'not_free';
      end if;
    end loop;
    v_item := v_item || jsonb_build_object(k, jsonb_build_object(
      'days', (select jsonb_agg((y ->> 'weekday')::int order by (y ->> 'weekday')::int) from jsonb_array_elements(v_new) y),
      'time', to_char((cand ->> 'time')::time, 'HH24:MI'), 'week', w, 'first', lms_rc_first2(w, c.slots, v_new)));
    v_prev := v_new;
  end loop;

  insert into regular_change_requests (student_id, enrollment_id, tutor_id, old_slots, items, reason, via, created_by)
  values (v_student, (c.e).id, (c.tutor).id, c.slots, jsonb_build_array(v_item), nullif(trim(coalesce(p_reason, '')), ''),
          case when is_admin() and p_student is not null then 'admin' else 'student' end, auth.uid())
  returning id into v_id;
  return jsonb_build_object('id', v_id);
end $$;

-- 확정: p_choice = {1} 또는 {2}. 확정 순간 [정규 일정 수정] 충돌 검사를 다시 돌림 (막히면 사유 + 다음 가능한 주)
create or replace function admin_regular_change_request_decide(p_id uuid, p_action text, p_choice int[] default null, p_week date default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  r regular_change_requests;
  c record;
  v_today date := (now() at time zone 'Asia/Seoul')::date;
  v_new jsonb;
  v_week date;
  v_from date;
  v_first date;
  v_dry jsonb;
  v_res jsonb;
  v_shift date;
  cand jsonb;
begin
  if not is_admin() then raise exception '운영자만 처리할 수 있습니다.' using errcode = '42501'; end if;
  select * into r from regular_change_requests where id = p_id for update;
  if not found or r.status <> 'pending' then raise exception '처리할 신청이 없어요 (이미 처리했거나 학생이 취소함).'; end if;
  if p_action = 'reject' then
    update regular_change_requests set status = 'rejected', decided_at = now(), decided_by = auth.uid() where id = p_id;
    return jsonb_build_object('ok', true, 'status', 'rejected');
  end if;
  if p_action <> 'confirm' then raise exception '처리 방법이 잘못됐습니다.'; end if;

  select * into c from lms_rc_context(r.student_id);
  if (c.e).id is null or c.slots is null or c.slots <> r.old_slots or (c.tutor).id <> r.tutor_id then
    raise exception '신청 뒤 정규 일정이 바뀌었어요. 반려하고 다시 신청받아 주세요.';
  end if;
  -- 재등록 직후(지난 수강기간이 끝났고 새 수강기간 시작 전)에는 [정규 일정 수정]이 지난 수강권을 보므로 새 수강기간 시작 뒤에 확정
  if lms_student_enrollment(r.student_id) <> r.enrollment_id then
    raise exception '새 수강기간이 시작되는 %부터 확정할 수 있어요.', to_char((select start_date from enrollments where id = r.enrollment_id), 'FMMM/FMDD');
  end if;
  if p_choice is null or cardinality(p_choice) <> 1 or p_choice[1] not in (1, 2) then raise exception '1순위·2순위 중 하나를 골라 주세요.'; end if;
  cand := (r.items -> 0) -> ('c' || p_choice[1]);
  if cand is null or jsonb_typeof(cand) <> 'object' or cand -> 'days' is null then raise exception '고른 순위의 일정이 없어요.'; end if;
  v_new := lms_rc_slots_of(cand);
  v_week := coalesce(p_week, (cand ->> 'week')::date);

  v_first := lms_rc_first2(v_week, r.old_slots, v_new);
  if v_first <= v_today or exists (select 1 from regular_change_requests x where x.enrollment_id = r.enrollment_id and x.status = 'confirmed'
                                      and x.period_id = lms_lesson_period(r.enrollment_id, v_first)) then
    v_shift := lms_rc_week2(r.enrollment_id, r.old_slots, v_new, v_today, p_id);
    if p_week is null or v_first <= v_today then
      return jsonb_build_object('ok', false, 'why', 'passed', 'week', v_week, 'shifted_to', v_shift);
    end if;
  end if;
  v_from := greatest(v_week, v_today);
  v_dry := admin_regular_change(r.student_id, v_new, v_from, '학생 신청', true);
  if not (v_dry ->> 'ok')::boolean then
    v_shift := v_week + 7;
    while v_shift <= (c.e).final_end_date loop
      if lms_rc_fits2(v_shift, r.old_slots, v_new, (c.e).final_end_date)
         and (admin_regular_change(r.student_id, v_new, v_shift, '학생 신청', true) ->> 'ok')::boolean then exit; end if;
      v_shift := v_shift + 7;
    end loop;
    if v_shift > (c.e).final_end_date then v_shift := null; end if;
    return jsonb_build_object('ok', false, 'why', 'problems', 'week', v_week, 'problems', v_dry -> 'problems', 'shifted_to', v_shift);
  end if;
  v_res := admin_regular_change(r.student_id, v_new, v_from, '학생 신청' || coalesce(': ' || r.reason, ''), false);
  update regular_change_requests
     set status = 'confirmed', decided_at = now(), decided_by = auth.uid(), chosen = v_new, effective_from = v_week,
         period_id = lms_lesson_period(r.enrollment_id, v_first), regular_change_id = (v_res ->> 'change_id')::uuid
   where id = p_id;
  return jsonb_build_object('ok', true, 'status', 'confirmed', 'week', v_week, 'moved', v_res -> 'moved');
end $$;
