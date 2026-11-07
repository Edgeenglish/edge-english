-- =====================================================================
-- 강사 귀책 수강기간 자동 연장 (정책 원본 H26(90)·(91)·(92)·(93), 2026-11-07 대표 확정)
--  - 수강 종료일은 하나(final_end_date). 강사 장기휴무(3일 이상)·강사 노쇼로 놓친 수업 수만큼 정규 요일로 자동 연장
--    · 대체강사 수업이 잡힌 날은 휴무로 놓친 수업이 아님(그 대체 수업이 노쇼면 노쇼 1회) · 무료 보상수업은 안 셈
--  - 종료일은 연장이 생길 때만 바뀜. 보강을 일찍 끝내도 줄이지 않음(자동 단축 없음, 대표 11/7 최종).
--    마지막 수업이 늘어난 날보다 늦으면 그 날까지 — 이미 잡힌 수업이 종료일 밖으로 밀리지 않음
--  - 다음 수강권(재등록)이 있으면 그 시작일 전날을 넘지 않음 (재등록 일정 그대로)
--  - 시행일 = 이 migration 을 적용한 날(한국 날짜, feature_flags 'tutor_fault_extension_since' 의 updated_at).
--    그 전에 생긴 일(운영진 수동 연장 · 기존 휴무 보강)은 지금 방식 그대로 — 다시 계산하거나 겹쳐 더하지 않음
--  - 3일 미만 강사 휴무는 연장 대상 아님 → 휴무 화면이 막고 수업 변경에서 강사 사전·늦은 취소 (알린 시각 기준)
--  - 종료 5일 이내에 강사가 알린 사전·늦은 취소: 학생 [맞는 시간이 없어요] → 운영진 '예외 연장 검토' 카드
-- 기존 표·데이터를 지우거나 덮어쓰지 않음. 다시 실행해도 같은 결과
-- =====================================================================

-- 1. 시행일 ------------------------------------------------------------
insert into feature_flags (key, enabled, note)
values ('tutor_fault_extension_since', false, '강사 귀책 자동 연장 시행일 — 이 줄의 updated_at(한국 날짜) 이후 생긴 강사 휴무·노쇼부터 (스위치 아님, H26(92))')
on conflict (key) do nothing;

create or replace function lms_fault_since() returns date
language sql stable security definer set search_path = public as $$
  select (f.updated_at at time zone 'Asia/Seoul')::date from feature_flags f where f.key = 'tutor_fault_extension_since'
$$;
revoke all on function lms_fault_since() from public, anon, authenticated;

-- 2. 연장 장부: 자동 연장 구분 · 사유 --------------------------------------
alter table enrollment_extensions drop constraint if exists enrollment_extensions_auto_source_check;
alter table enrollment_extensions add constraint enrollment_extensions_auto_source_check check (auto_source in ('leave_makeup', 'fault'));
alter table enrollment_extensions drop constraint if exists enrollment_extensions_reason_check;
alter table enrollment_extensions add constraint enrollment_extensions_reason_check
  check (reason in ('student_long_term_leave', 'tutor_long_term_leave', 'admin_exception', 'correction', 'tutor_fault'));

-- 3. 시행일 이후 생긴 강사 귀책 사건인지 ----------------------------------
--  노쇼: 수업 날짜(한국)가 시행일 이후 · 휴무: 3일 이상 휴무를 넣은 날(한국)이 시행일 이후 (휴무 기록이 없으면 수업 날짜)
create or replace function lms_fault_event(p_lesson uuid) returns text
language sql stable security definer set search_path = public as $$
  select case
    when lms_fault_since() is null then null
    when l.class_status = 'Tutor no-show' and l.kst_date >= lms_fault_since() then 'no_show'
    when l.class_status = 'Tutor long-term leave' and coalesce(
           (select (o.created_at at time zone 'Asia/Seoul')::date >= lms_fault_since() and o.ends_at - o.starts_at >= interval '3 days'
            from leave_items li join tutor_time_off o on o.id = li.time_off_id
            where li.lesson_id = l.id order by li.created_at desc limit 1),
           l.kst_date >= lms_fault_since()) then 'leave'
  end
  from lessons l where l.id = p_lesson and l.voided_at is null
$$;
revoke all on function lms_fault_event(uuid) from public, anon, authenticated;

-- 4. 기준일 뒤 n번째 정규 수업 요일 (기준일 당시 정규 일정의 요일, 없으면 가장 최근 일정)
create or replace function lms_nth_regular_day(p_student uuid, p_after date, p_n integer) returns date
language plpgsql stable security definer set search_path = public as $$
declare
  v_days integer[];
  d date := p_after;
  k integer := 0;
begin
  if coalesce(p_n, 0) <= 0 then return p_after; end if;
  select array_agg(distinct r.weekday::int) into v_days from regular_schedules r
  where r.student_id = p_student and r.effective_from <= p_after and (r.effective_to is null or r.effective_to >= p_after);
  if v_days is null then
    select array_agg(distinct r.weekday::int) into v_days from regular_schedules r
    where r.student_id = p_student and r.effective_from = (select max(x.effective_from) from regular_schedules x where x.student_id = p_student);
  end if;
  if v_days is null then return p_after + p_n; end if;   -- 정규 일정이 없는 예외: 달력 날짜로
  loop
    d := d + 1;
    if extract(dow from d)::int = any(v_days) then k := k + 1; end if;
    exit when k >= p_n or d > p_after + 400;
  end loop;
  return d;
end $$;
revoke all on function lms_nth_regular_day(uuid, date, integer) from public, anon, authenticated;

-- 5. 자동 연장 계산 (auto_source 'fault' 줄만 더함 — 운영진 연장·기존 휴무 연장은 그대로, 줄이지 않음)
create or replace function lms_fault_sync_extension(p_enrollment uuid) returns void
language plpgsql security definer set search_path = public as $$
declare
  e enrollments;
  v_actor uuid := coalesce(nullif(current_setting('app.actor_id', true), '')::uuid, auth.uid());
  v_base date;
  v_cur integer;
  v_leave integer;
  v_noshow integer;
  v_cap date;
  v_last date;
  v_next date;
  v_target date;
begin
  if lms_fault_since() is null then return; end if;
  select * into e from enrollments where id = p_enrollment for update;
  if not found then return; end if;
  select e.base_end_date + coalesce(sum(x.days) filter (where x.auto_source is distinct from 'fault'), 0)::int,
         coalesce(sum(x.days) filter (where x.auto_source = 'fault'), 0)::int
  into v_base, v_cur from enrollment_extensions x where x.enrollment_id = e.id;

  select count(*) filter (where q.ev = 'leave'), count(*) filter (where q.ev = 'no_show')
  into v_leave, v_noshow
  from (select l.id, lms_fault_event(l.id) as ev from lessons l
        where l.enrollment_id = e.id and l.voided_at is null and l.class_status in ('Tutor no-show', 'Tutor long-term leave')) q
  where q.ev is not null;
  if v_leave + v_noshow = 0 and v_cur = 0 then return; end if;   -- 시행 뒤 사건이 없는 수강권은 건드리지 않음

  v_cap := lms_nth_regular_day(e.student_id, v_base, v_leave + v_noshow);
  select max(l.kst_date) into v_last from lessons l where l.enrollment_id = e.id and l.voided_at is null and l.state <> 'canceled';
  -- 늘어난 날 · 이미 잡힌 마지막 수업 · 지금 종료일 중 늦은 날 (줄이지 않음)
  v_target := greatest(v_cap, coalesce(v_last, v_base), v_base + v_cur);
  -- 다음 수강권(재등록) 시작일 전날까지만
  select min(n.start_date) into v_next from enrollments n
  where n.student_id = e.student_id and n.id <> e.id and n.start_date > e.start_date and n.status <> 'canceled';
  if v_next is not null and v_target >= v_next then v_target := greatest(v_base, v_next - 1); end if;

  if (v_target - v_base) = v_cur then return; end if;
  if v_actor is null then raise exception '처리한 사람을 알 수 없습니다.'; end if;
  begin
    insert into enrollment_extensions (enrollment_id, days, reason, note, approved_by, auto_source)
    values (e.id, (v_target - v_base) - v_cur, 'tutor_fault',
            format('LMS 강사 귀책 자동 연장 (H26(92)) · 강사 휴무 %s · 노쇼 %s', v_leave, v_noshow), v_actor, 'fault');
  exception when exclusion_violation then
    raise exception '다음 수강권 기간과 겹쳐 종료일을 늘릴 수 없습니다. 보강 날짜를 다시 확인해 주세요.' using hint = 'next_enrollment';
  end;
end $$;
revoke all on function lms_fault_sync_extension(uuid) from public, anon, authenticated;

-- 수업 상태·날짜가 바뀔 때마다 (노쇼 기록·휴무 '기다림'·보강 확정·취소·되돌리기 어느 경로든 같게)
create or replace function lessons_fault_extension() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  perform lms_fault_sync_extension(new.enrollment_id);
  if tg_op = 'UPDATE' and old.enrollment_id is distinct from new.enrollment_id then
    perform lms_fault_sync_extension(old.enrollment_id);
  end if;
  return null;
end $$;
revoke all on function lessons_fault_extension() from public, anon, authenticated;
drop trigger if exists lessons_zz_fault_extension on lessons;
create trigger lessons_zz_fault_extension after insert or update of state, starts_at, class_status, voided_at, enrollment_id on lessons
  for each row execute function lessons_fault_extension();

-- 6. 기존 휴무 보강 연장(A20)은 시행 전 휴무만 — 시행 뒤 휴무는 위 자동 연장이 맡음 ------------
create or replace function lms_leave_sync_extension(p_enrollment uuid) returns void
language plpgsql security definer set search_path = public as $$
declare
  e enrollments;
  v_actor uuid := coalesce(nullif(current_setting('app.actor_id', true), '')::uuid, auth.uid());
  v_pre date;
  v_last date;
  v_cur integer;
  v_target integer;
begin
  select * into e from enrollments where id = p_enrollment for update;
  if not found then return; end if;
  select e.base_end_date + coalesce(sum(days) filter (where auto_source is null), 0)::int,
         coalesce(sum(days) filter (where auto_source = 'leave_makeup'), 0)::int
  into v_pre, v_cur from enrollment_extensions where enrollment_id = e.id;
  select max(x.kst_date) into v_last from lessons x
  where x.enrollment_id = e.id and x.state <> 'canceled'
    and ((x.kind = 'makeup' and exists (select 1 from lessons o where o.id = x.makeup_of and o.class_status = 'Tutor long-term leave'
                                         and lms_fault_event(o.id) is null))
      or (x.kind = 'migrated_makeup' and exists (select 1 from migrated_items m where m.lesson_id = x.id and m.tutor_leave)));
  v_target := greatest(coalesce(v_last - v_pre, 0), 0);
  if v_target <> v_cur then
    if v_actor is null then raise exception '처리한 사람을 알 수 없습니다.'; end if;
    begin
      insert into enrollment_extensions (enrollment_id, days, reason, note, approved_by, auto_source)
      values (e.id, v_target - v_cur, 'tutor_long_term_leave', 'LMS 강사 휴무 보강 자동 연장 (A20)', v_actor, 'leave_makeup');
    exception when exclusion_violation then
      raise exception '다음 수강권 기간과 겹쳐 종료일을 늘릴 수 없습니다. 보강 날짜를 다시 확인해 주세요.' using hint = 'next_enrollment';
    end;
  end if;
  perform lms_fault_sync_extension(e.id);   -- 기본 종료일이 바뀌었으면 자동 연장도 맞춤
end $$;
revoke all on function lms_leave_sync_extension(uuid) from public, anon, authenticated;

-- 7. 보강 날짜 제한: 종료일 뒤로도 고를 수 있는 것은 시행 전 휴무 보강만 (out tutor_leave = 그 뜻) ------
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
    -- H26(93): 시행 뒤 휴무 보강은 다른 보강과 같은 종료일까지
    tutor_leave := coalesce(l.class_status = 'Tutor long-term leave', false) and lms_fault_event(l.id) is null;
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

-- 보강 가능한 날짜: 4500 그대로 + 휴무 판정은 lms_makeup_source 하나로 (시행 뒤 휴무는 종료일까지)
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
    v_leave := s.tutor_leave;
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
      and lms_makeup_conflict(s.tutor_id, s.student_id, y.x, y.x + make_interval(mins => e.duration_min), true) is null
      and not exists (select 1 from lessons l where l.student_id = s.student_id and l.state <> 'canceled'
                      and l.starts_at < y.x + make_interval(mins => e.duration_min) and y.x < l.ends_at)
  )
  select z.sec, z.x, z.f from (select f1.*, row_number() over (partition by f1.sec order by f1.x) as n from free f1) z
  where z.sec = 'in_period' or z.n <= 1
  order by z.x;
end $$;
revoke all on function lms_makeup_options(uuid, uuid, uuid) from public, anon, authenticated;

-- 8. 3일 미만 강사 휴무는 연장 대상 아님 (H26(92) ④): 휴무 화면이 3일 미만 저장을 막고(수업 변경에서 강사 취소로),
--    위 lms_fault_event 도 3일 이상 휴무만 셈. 예전 휴무·시험 데이터 때문에 DB 에서 넣기 자체를 막지는 않음

-- 9. 종료 5일 이내 강사 취소 → [맞는 시간이 없어요] → 운영진 '예외 연장 검토' (H26(92) ⑤) ----------------
create table if not exists extension_reviews (
  lesson_id uuid primary key references lessons(id),     -- 강사가 취소한 수업 (보강권)
  enrollment_id uuid not null references enrollments(id),
  student_id uuid not null references students(id),
  requested_at timestamptz not null default now(),
  requested_by uuid
);
do $$ begin
  if not exists (select 1 from pg_policies where tablename = 'extension_reviews' and policyname = 'admin_read') then
    perform lms_protect('public.extension_reviews'::regclass);
  end if;
end $$;

-- 보일 조건: 강사 사전·늦은 취소 수업 · 보강 아직 없음 · 강사가 알린 날(한국)이 수강 종료일 5일 이내 · 종료일 안 지남
create or replace function lms_no_time_eligible(p_lesson uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from lessons l
    join enrollments e on e.id = l.enrollment_id
    join lateral (select c.requested_at from change_requests c
                  where c.lesson_id = l.id and c.type = 'tutor_cancel' and c.status = 'applied' and c.requested_at is not null
                  order by c.created_at desc limit 1) cr on true
    where l.id = p_lesson and l.voided_at is null
      and l.class_status in ('Tutor canceled in advance', 'Tutor canceled late')
      and not exists (select 1 from lessons x where x.makeup_of = l.id and x.voided_at is null)
      and e.final_end_date - (cr.requested_at at time zone 'Asia/Seoul')::date <= 5
      and e.final_end_date >= (now() at time zone 'Asia/Seoul')::date)
$$;
revoke all on function lms_no_time_eligible(uuid) from public, anon, authenticated;

-- 학생 화면: 링크를 보여 줄 보강권 + 이미 누른 것(회색 '요청함 ✓')
create or replace function student_no_time_rights(p_student uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_student uuid := lms_screen_student(p_student);
begin
  return coalesce((
    select jsonb_agg(jsonb_build_object('lesson_id', l.id, 'requested_at', r.requested_at))
    from lessons l left join extension_reviews r on r.lesson_id = l.id
    where l.student_id = v_student and l.voided_at is null
      and l.class_status in ('Tutor canceled in advance', 'Tutor canceled late')
      and not exists (select 1 from lessons x where x.makeup_of = l.id and x.voided_at is null)
      and (r.lesson_id is not null or lms_no_time_eligible(l.id))), '[]'::jsonb);
end $$;
revoke all on function student_no_time_rights(uuid) from public, anon;
grant execute on function student_no_time_rights(uuid) to authenticated;

create or replace function student_no_time_request(p_student uuid, p_lesson uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_student uuid := lms_screen_student(p_student);
  l lessons;
begin
  select * into l from lessons where id = p_lesson;
  if not found or l.student_id <> v_student then raise exception '본인 수업만 요청할 수 있습니다.' using errcode = '42501'; end if;
  if exists (select 1 from extension_reviews where lesson_id = p_lesson) then return jsonb_build_object('repeated', true); end if;
  if not lms_no_time_eligible(p_lesson) then raise exception '요청할 수 있는 수업이 아닙니다.' using hint = 'not_eligible'; end if;
  perform set_config('app.actor_id', coalesce(auth.uid()::text, ''), true);
  perform set_config('app.actor_via', 'student_no_time_request', true);
  insert into extension_reviews (lesson_id, enrollment_id, student_id, requested_by)
  values (p_lesson, l.enrollment_id, l.student_id, auth.uid());
  return jsonb_build_object('repeated', false);
end $$;
revoke all on function student_no_time_request(uuid, uuid) from public, anon;
grant execute on function student_no_time_request(uuid, uuid) to authenticated;

-- 운영진 대시보드 카드: 요청 뒤 운영진이 그 수강권 종료일을 연장했으면 빠짐 (닫기는 카드 닫기 기록)
create or replace function admin_extension_reviews() returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not is_admin() then raise exception '운영자(추가 인증 완료)만 볼 수 있습니다.' using errcode = '42501'; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'lesson_id', r.lesson_id, 'student_id', s.id, 'student_code', s.code, 'student_name', s.name_ko,
             'lesson_at', l.starts_at, 'class_status', l.class_status,
             'notice_at', (select c.requested_at from change_requests c where c.lesson_id = l.id and c.type = 'tutor_cancel' and c.status = 'applied'
                           order by c.created_at desc limit 1),
             'end_date', e.final_end_date, 'requested_at', r.requested_at) order by r.requested_at)
    from extension_reviews r
    join lessons l on l.id = r.lesson_id
    join enrollments e on e.id = r.enrollment_id
    join students s on s.id = r.student_id
    where e.status not in ('completed', 'canceled')
      and not exists (select 1 from enrollment_extensions x where x.enrollment_id = e.id and x.auto_source is null
                      and x.reason = 'admin_exception' and x.created_at > r.requested_at)), '[]'::jsonb);
end $$;
revoke all on function admin_extension_reviews() from public, anon;
grant execute on function admin_extension_reviews() to authenticated;
