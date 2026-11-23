-- =====================================================================
-- 정규 시간 변경 (H26(208) 보충 4, 대표 11/17)
--  ① 확정 오류 고침 (Work QA): 두 수업 요일을 함께 바꿀 때 앞에서 바꾼 요일을 다음 차례가 또 바꿔 '같은 요일 두 번'으로 막히던 것
--     → 새 정규 일정을 원래 일정에서 한 번에 만듦 (시험 DB 에서 Work 가 고친 내용과 같음)
--  ② '변경 시작 주' (학생이 미래 주를 고름, 기본 = 후보마다 가장 빠른 주): 지금 수강권 종료일 안의 월요일만
--     · 신청 화면: 고른 주부터 매주 비어 있는 시간 · 신청: 모든 후보가 그 주에 적용 가능해야 함(4일 전·수강기간 1회·종료일)
-- 지우는 문장 없음 (함수 인자가 바뀌어 옛 함수 2개는 drop function — 데이터 아님)
-- =====================================================================

-- ③ 옮긴 수업이 수강 종료일 뒤로 밀리는 후보는 처음부터 빼기 (Claude QA: 종료 12/9(수) 학생이 월→목이면 마지막 12/7 수업이 12/10 으로 가 확정 때 '종료일 뒤'로 막힘)
--    그 주부터 종료일까지 새 요일 횟수 >= 옛 요일 횟수 (바꾸는 수업마다)
create or replace function lms_rc_fits_end(p_week date, p_items jsonb, p_end date) returns boolean language sql immutable as $$
  select coalesce(bool_and(
    (case when lms_rc_day(p_week, (x -> 'new' ->> 'weekday')::int) > p_end then 0 else (p_end - lms_rc_day(p_week, (x -> 'new' ->> 'weekday')::int)) / 7 + 1 end)
    >= (case when lms_rc_day(p_week, (x -> 'old' ->> 'weekday')::int) > p_end then 0 else (p_end - lms_rc_day(p_week, (x -> 'old' ->> 'weekday')::int)) / 7 + 1 end)), true)
  from jsonb_array_elements(p_items) x
$$;

-- ④ 수강기간이 끝났고 다음 수강권(재등록)이 이미 확정돼 있으면 다음 수강권 기준으로 (재등록 때 강사·시간이 바뀌면 '변경 예정'으로 막히던 것, Claude QA 11/18)
create or replace function lms_rc_context(p_student uuid, out e enrollments, out tutor tutors, out slots jsonb, out future_pending boolean)
language plpgsql stable security definer set search_path = public as $$
declare
  v_today date := (now() at time zone 'Asia/Seoul')::date;
  v_n int;
  v_t uuid;
begin
  select * into e from enrollments x where x.id = lms_student_enrollment(p_student);
  if e.id is not null and e.final_end_date < v_today then
    select * into e from enrollments x where x.student_id = p_student and x.status in ('confirmed', 'active') and x.start_date > e.final_end_date
    order by x.start_date limit 1;
  end if;
  if e.id is null or e.status not in ('confirmed', 'active') then e := null; return; end if;
  select jsonb_agg(jsonb_build_object('weekday', rs.weekday, 'time', to_char(rs.start_time_kst, 'HH24:MI')) order by rs.weekday, rs.start_time_kst),
         count(distinct rs.tutor_id), (array_agg(distinct rs.tutor_id))[1]
    into slots, v_n, v_t
  from regular_schedules rs
  where rs.student_id = p_student and rs.effective_from <= greatest(v_today, e.start_date)
    and (rs.effective_to is null or rs.effective_to >= greatest(v_today, e.start_date));
  if slots is null or v_n <> 1 then slots := null; return; end if;
  select * into tutor from tutors where id = v_t;
  future_pending := exists (select 1 from regular_schedules rs where rs.student_id = p_student
                             and rs.effective_from > greatest(v_today, e.start_date) and rs.effective_from > date '1950-01-01');
end $$;
revoke all on function lms_rc_context(uuid) from public, anon, authenticated;

-- ⑤ 속도 (Claude QA 11/18: 12주 수강권에서 신청 화면 5.8초): 매주 검사를 앞 주부터 하다 하나라도 막히면 바로 멈춤, 싼 검사부터
create or replace function lms_rc_free(p_tutor uuid, p_student uuid, p_from date, p_until date, p_dow int, p_time time, p_min int)
returns boolean language plpgsql stable security definer set search_path = public as $$
declare
  d date;
  t0 timestamptz;
  t1 timestamptz;
  n int := 0;
begin
  d := lms_rc_day(lms_rc_monday(p_from), p_dow);
  if d < p_from then d := d + 7; end if;
  while d <= p_until loop
    t0 := (d + p_time) at time zone 'Asia/Seoul';
    t1 := t0 + make_interval(mins => p_min);
    if not lms_tutor_start_ok(p_tutor, t0) or not lms_tutor_available(p_tutor, t0) then return false; end if;
    if exists (select 1 from tutor_time_off o where o.tutor_id = p_tutor and o.starts_at < t1 and t0 < o.ends_at) then return false; end if;
    if exists (select 1 from lessons y where y.tutor_id = p_tutor and y.state <> 'canceled' and y.voided_at is null
                 and not (y.student_id = p_student and y.kind = 'regular' and y.state = 'scheduled')
                 and y.starts_at < t1 + interval '10 minutes' and t0 - interval '10 minutes' < y.ends_at) then return false; end if;
    if exists (select 1 from lms_slot_hold_hits(p_tutor, t0, t1) h where h.student_id <> p_student) then return false; end if;
    n := n + 1;
    d := d + 7;
  end loop;
  return n > 0;
end $$;
revoke all on function lms_rc_free(uuid, uuid, date, date, int, time, int) from public, anon, authenticated;

-- 그 주(월요일)에 적용할 수 있는지 (lms_rc_week 와 같은 조건)
create or replace function lms_rc_week_ok(p_enrollment uuid, p_items jsonb, p_today date, p_week date)
returns boolean language plpgsql stable security definer set search_path = public as $$
declare
  e enrollments;
  f date;
begin
  select * into e from enrollments where id = p_enrollment;
  if p_week is null or extract(isodow from p_week) <> 1 or p_week < lms_rc_monday(p_today) + 7 or p_week > e.final_end_date then return false; end if;
  f := lms_rc_first(p_week, p_items);
  return f <= e.final_end_date and p_today <= f - 4 and lms_rc_fits_end(p_week, p_items, e.final_end_date)
    and not exists (select 1 from regular_change_requests r where r.enrollment_id = p_enrollment and r.status = 'confirmed'
                      and r.period_id = lms_lesson_period(p_enrollment, f));
end $$;
revoke all on function lms_rc_week_ok(uuid, jsonb, date, date) from public, anon, authenticated;

create or replace function lms_rc_week(p_enrollment uuid, p_items jsonb, p_today date, p_skip uuid default null)
returns date language plpgsql stable security definer set search_path = public as $$
declare
  e enrollments;
  w date;
  f date;
begin
  select * into e from enrollments where id = p_enrollment;
  w := lms_rc_monday(p_today) + 7;
  while w <= e.final_end_date loop
    f := lms_rc_first(w, p_items);
    if f <= e.final_end_date and p_today <= f - 4 and lms_rc_fits_end(w, p_items, e.final_end_date)
       and not exists (select 1 from regular_change_requests r where r.enrollment_id = p_enrollment and r.status = 'confirmed'
                         and r.period_id = lms_lesson_period(p_enrollment, f) and r.id is distinct from p_skip) then
      return w;
    end if;
    w := w + 7;
  end loop;
  return null;
end $$;

drop function if exists student_regular_change_options(uuid);
create or replace function student_regular_change_options(p_student uuid, p_from date default null)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  v_student uuid := lms_screen_student(p_student);
  v_today date := (now() at time zone 'Asia/Seoul')::date;
  c record;
  w0 date;
  v_free jsonb := '[]'::jsonb;
  v_dow int;
  v_n int;
  v_time time;
begin
  select * into c from lms_rc_context(v_student);
  if (c.e).id is null or c.slots is null then return jsonb_build_object('state', 'none'); end if;
  if exists (select 1 from regular_change_requests where student_id = v_student and status = 'pending') then
    return jsonb_build_object('state', 'pending');
  end if;
  if c.future_pending then return jsonb_build_object('state', 'scheduled'); end if;
  w0 := greatest(lms_rc_monday(v_today) + 7, coalesce(lms_rc_monday(p_from), v_today));
  if w0 > (c.e).final_end_date then return jsonb_build_object('state', 'ending'); end if;
  for v_dow in 0..6 loop
    for v_n in 0..47 loop
      v_time := time '00:00' + make_interval(mins => v_n * 30);
      if exists (select 1 from jsonb_array_elements(c.slots) s where (s ->> 'weekday')::int = v_dow and (s ->> 'time')::time = v_time) then continue; end if;
      if lms_rc_free((c.tutor).id, v_student, w0, (c.e).final_end_date, v_dow, v_time, (c.e).duration_min) then
        v_free := v_free || jsonb_build_object('weekday', v_dow, 'time', to_char(v_time, 'HH24:MI'));
      end if;
    end loop;
  end loop;
  return jsonb_build_object('state', 'ok', 'today', v_today, 'final_end', (c.e).final_end_date, 'duration', (c.e).duration_min,
    'tutor', (c.tutor).name, 'slots', c.slots, 'free', v_free, 'from', w0,
    'periods', coalesce((select jsonb_agg(jsonb_build_object('start', p.start_date, 'end', p.end_date,
                 'used', exists (select 1 from regular_change_requests r where r.status = 'confirmed' and r.period_id = p.id)) order by p.idx)
               from enrollment_periods p where p.enrollment_id = (c.e).id), '[]'::jsonb));
end $$;
revoke all on function student_regular_change_options(uuid, date) from public, anon;
grant execute on function student_regular_change_options(uuid, date) to authenticated;

-- 신청: p_start = 학생이 고른 시작 주(월요일). 없으면 후보마다 가장 빠른 주
drop function if exists student_regular_change_request(uuid, jsonb, text);
create or replace function student_regular_change_request(p_student uuid, p_items jsonb, p_reason text default null, p_start date default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_student uuid := lms_screen_student(p_student);
  v_today date := (now() at time zone 'Asia/Seoul')::date;
  c record;
  x jsonb;
  k text;
  cand jsonb;
  v_items jsonb := '[]'::jsonb;
  v_item jsonb;
  v_olds int[] := '{}';
  v_kept int[];
  v_used int[] := '{}';
  v_mine int[];
  v_pair jsonb;
  w date;
  v_id uuid;
begin
  select * into c from lms_rc_context(v_student);
  if (c.e).id is null or c.slots is null then raise exception '지금은 정규 시간 변경을 신청할 수 없어요.'; end if;
  if c.future_pending then raise exception '이미 정규 시간 변경이 예정돼 있어요.'; end if;
  if exists (select 1 from regular_change_requests where student_id = v_student and status = 'pending') then
    raise exception '확인 중인 신청이 있어요.' using hint = 'pending';
  end if;
  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then raise exception '바꿀 수업을 골라 주세요.'; end if;
  for x in select * from jsonb_array_elements(p_items) loop
    if not exists (select 1 from jsonb_array_elements(c.slots) s where s = jsonb_build_object('weekday', (x -> 'old' ->> 'weekday')::int, 'time', x -> 'old' ->> 'time')) then
      raise exception '정규 일정이 바뀌었어요. 다시 열어 주세요.';
    end if;
    if (x -> 'old' ->> 'weekday')::int = any(v_olds) then raise exception '같은 수업을 두 번 고를 수 없어요.'; end if;
    v_olds := v_olds || (x -> 'old' ->> 'weekday')::int;
  end loop;
  select coalesce(array_agg((s ->> 'weekday')::int), '{}') into v_kept from jsonb_array_elements(c.slots) s where not ((s ->> 'weekday')::int = any(v_olds));

  for x in select * from jsonb_array_elements(p_items) loop
    if x -> 'c1' is null or jsonb_typeof(x -> 'c1') <> 'object' then raise exception '새 시간을 골라 주세요.'; end if;
    v_item := jsonb_build_object('old', jsonb_build_object('weekday', (x -> 'old' ->> 'weekday')::int, 'time', x -> 'old' ->> 'time'));
    v_mine := '{}';
    foreach k in array array['c1', 'c2'] loop
      cand := x -> k;
      if cand is null or jsonb_typeof(cand) <> 'object' then v_item := v_item || jsonb_build_object(k, null); continue; end if;
      if (cand ->> 'weekday')::int not between 0 and 6 or extract(minute from (cand ->> 'time')::time)::int not in (0, 30) then raise exception '시간을 다시 골라 주세요.'; end if;
      if (cand ->> 'weekday')::int = (x -> 'old' ->> 'weekday')::int and (cand ->> 'time')::time = (x -> 'old' ->> 'time')::time then
        raise exception '지금과 같은 시간이에요.';
      end if;
      if (cand ->> 'weekday')::int = any(v_kept) or (cand ->> 'weekday')::int = any(v_used) then raise exception '그 요일은 고를 수 없어요.'; end if;
      v_mine := v_mine || (cand ->> 'weekday')::int;
      v_pair := jsonb_build_array(jsonb_build_object('old', x -> 'old', 'new', cand));
      if p_start is null then
        w := lms_rc_week((c.e).id, v_pair, v_today);
      elsif lms_rc_week_ok((c.e).id, v_pair, v_today, p_start) then
        w := p_start;
      else
        raise exception '고른 시작 주에는 바꿀 수 없어요. 다시 골라 주세요.' using hint = 'bad_start';
      end if;
      if w is null or not lms_rc_free((c.tutor).id, v_student, w, (c.e).final_end_date, (cand ->> 'weekday')::int, (cand ->> 'time')::time, (c.e).duration_min) then
        raise exception '고른 시간이 이제 비어 있지 않아요. 다시 골라 주세요.' using hint = 'not_free';
      end if;
      v_item := v_item || jsonb_build_object(k, jsonb_build_object('weekday', (cand ->> 'weekday')::int, 'time', to_char((cand ->> 'time')::time, 'HH24:MI'),
                  'week', w, 'first', lms_rc_first(w, v_pair)));
    end loop;
    v_used := v_used || v_mine;
    v_items := v_items || jsonb_build_array(v_item);
  end loop;

  insert into regular_change_requests (student_id, enrollment_id, tutor_id, old_slots, items, reason, via, created_by)
  values (v_student, (c.e).id, (c.tutor).id, c.slots, v_items, nullif(trim(coalesce(p_reason, '')), ''),
          case when is_admin() and p_student is not null then 'admin' else 'student' end, auth.uid())
  returning id into v_id;
  return jsonb_build_object('id', v_id);
end $$;
revoke all on function student_regular_change_request(uuid, jsonb, text, date) from public, anon;
grant execute on function student_regular_change_request(uuid, jsonb, text, date) to authenticated;

-- 확정: 새 정규 일정을 원래 일정에서 한 번에 만듦 (①)
create or replace function admin_regular_change_request_decide(p_id uuid, p_action text, p_choice int[] default null, p_week date default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  r regular_change_requests;
  c record;
  v_today date := (now() at time zone 'Asia/Seoul')::date;
  v_pairs jsonb := '[]'::jsonb;
  v_new jsonb;
  v_week date;
  v_from date;
  v_first date;
  v_dry jsonb;
  v_res jsonb;
  v_shift date;
  i int;
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
  if p_choice is null or cardinality(p_choice) <> jsonb_array_length(r.items) then raise exception '수업마다 1순위·2순위 중 하나를 골라 주세요.'; end if;
  v_week := null;
  for i in 1..cardinality(p_choice) loop
    cand := (r.items -> (i - 1)) -> ('c' || p_choice[i]);
    if cand is null or jsonb_typeof(cand) <> 'object' then raise exception '고른 순위의 시간이 없어요.'; end if;
    v_pairs := v_pairs || jsonb_build_array(jsonb_build_object('old', (r.items -> (i - 1)) -> 'old', 'new', cand));
    v_week := greatest(v_week, (cand ->> 'week')::date);
  end loop;
  select jsonb_agg(coalesce(
    (select jsonb_build_object('weekday', (pair -> 'new' ->> 'weekday')::int, 'time', pair -> 'new' ->> 'time')
     from jsonb_array_elements(v_pairs) pair
     where (pair -> 'old' ->> 'weekday')::int = (s ->> 'weekday')::int),
    s) order by (s ->> 'weekday')::int)
  into v_new from jsonb_array_elements(r.old_slots) s;
  if p_week is not null then v_week := p_week; end if;

  v_first := lms_rc_first(v_week, v_pairs);
  if v_first <= v_today or exists (select 1 from regular_change_requests x where x.enrollment_id = r.enrollment_id and x.status = 'confirmed'
                                      and x.period_id = lms_lesson_period(r.enrollment_id, v_first)) then
    v_shift := lms_rc_week(r.enrollment_id, v_pairs, v_today, p_id);
    if p_week is null or v_first <= v_today then
      return jsonb_build_object('ok', false, 'why', 'passed', 'week', v_week, 'shifted_to', v_shift);
    end if;
  end if;
  v_from := greatest(v_week, v_today);
  v_dry := admin_regular_change(r.student_id, v_new, v_from, '학생 신청', true);
  if not (v_dry ->> 'ok')::boolean then
    v_shift := v_week + 7;
    while v_shift <= (c.e).final_end_date loop
      if lms_rc_first(v_shift, v_pairs) <= (c.e).final_end_date
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
