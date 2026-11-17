-- =====================================================================
-- 학생 홈 [정규 시간 변경] · [강사 변경 상담] (정책 원본 H26(208)·보충·보충 2, 대표 11/17)
--  ① 정규 시간 변경: 학생 신청(후보 1·2순위) → 운영진 확정(admin_regular_change 로 그대로 옮김, 충돌 검사 다시)
--     · 수강기간(enrollment_periods)마다 확정 1회 · 적용 = 월요일 주 단위(한국 시간)
--     · 그 주에 바뀌는 첫 수업(옮겨지는 기존 수업·새 수업 중 빠른 날) 4일 전 날까지 신청(한국 날짜)
--     · 가능한 시간 = 적용 주부터 수강 종료일까지 매주 비어 있는 시간(보강 달력·정규 일정 수정과 같은 검사)
--  ② 강사 변경 상담: 이유(선택)만 남김. 운영진만 봄(강사 화면·메일 어디에도 안 나감)
-- 지우는 문장 없음. 되돌리기: 새 표·함수만이라 쓰지 않으면 영향 없음
-- =====================================================================

create table if not exists regular_change_requests (
  id uuid primary key default gen_random_uuid(),
  student_id uuid not null references students(id),
  enrollment_id uuid not null references enrollments(id),
  tutor_id uuid not null references tutors(id),
  old_slots jsonb not null,           -- 신청할 때 정규 일정 [{weekday,time}] (한국 시간)
  items jsonb not null,               -- [{old:{weekday,time}, c1:{weekday,time,week,first}, c2:{...}|null}]
  reason text,
  status text not null default 'pending' check (status in ('pending', 'confirmed', 'rejected', 'withdrawn')),
  via text not null default 'student' check (via in ('student', 'admin')),
  created_by uuid,
  created_at timestamptz not null default now(),
  decided_at timestamptz,
  decided_by uuid,
  chosen jsonb,                       -- 확정한 새 정규 일정 [{weekday,time}]
  effective_from date,
  period_id uuid references enrollment_periods(id),
  regular_change_id uuid references regular_changes(id)
);
create unique index if not exists regular_change_requests_one_pending on regular_change_requests(student_id) where status = 'pending';
alter table regular_change_requests enable row level security;

create table if not exists tutor_change_requests (
  id uuid primary key default gen_random_uuid(),
  student_id uuid not null references students(id),
  tutor_id uuid references tutors(id),   -- 요청할 때 담당 강사 (운영진 참고용)
  reasons text[] not null default '{}',
  note text,
  status text not null default 'open' check (status in ('open', 'done')),
  via text not null default 'student' check (via in ('student', 'admin')),
  created_by uuid,
  created_at timestamptz not null default now(),
  done_at timestamptz,
  done_by uuid
);
create unique index if not exists tutor_change_requests_one_open on tutor_change_requests(student_id) where status = 'open';
alter table tutor_change_requests enable row level security;

do $$ begin
  if not exists (select 1 from pg_trigger where tgname = 'regular_change_requests_no_delete') then
    perform lms_protect('public.regular_change_requests');
    create trigger regular_change_requests_no_delete before delete on regular_change_requests for each row execute function forbid_delete();
  end if;
  if not exists (select 1 from pg_trigger where tgname = 'tutor_change_requests_no_delete') then
    perform lms_protect('public.tutor_change_requests');
    create trigger tutor_change_requests_no_delete before delete on tutor_change_requests for each row execute function forbid_delete();
  end if;
end $$;

-- 한 주의 월요일 / 그 주의 요일(0=일) 날짜
create or replace function lms_rc_monday(d date) returns date language sql immutable as $$
  select d - (extract(isodow from d)::int - 1)
$$;
create or replace function lms_rc_day(p_week date, p_dow int) returns date language sql immutable as $$
  select p_week + ((p_dow + 6) % 7)
$$;

-- 그 주에 바뀌는 첫 수업 날짜: 바꾸는 수업마다 옛 요일·새 요일 날짜 중 가장 빠른 날 (items: [{old:{weekday}, new:{weekday}}])
create or replace function lms_rc_first(p_week date, p_items jsonb) returns date language sql immutable as $$
  select min(least(lms_rc_day(p_week, (x -> 'old' ->> 'weekday')::int), lms_rc_day(p_week, (x -> 'new' ->> 'weekday')::int)))
  from jsonb_array_elements(p_items) x
$$;

-- 새 정규 시간이 p_from 부터 p_until 까지 매주 비어 있는지 (admin_regular_change 검사와 같음: 06:00~22:30·Availability·휴무·다른 수업+휴식 10분·재등록 대기 자리)
create or replace function lms_rc_free(p_tutor uuid, p_student uuid, p_from date, p_until date, p_dow int, p_time time, p_min int)
returns boolean language sql stable security definer set search_path = public as $$
  with d as (
    select g::date as d from generate_series(lms_rc_day(lms_rc_monday(p_from), p_dow), p_until, interval '7 days') g
    where g::date >= p_from
  ), t as (
    select (d.d + p_time) at time zone 'Asia/Seoul' as t0 from d
  )
  select count(*) > 0 and coalesce(bool_and(
       lms_tutor_start_ok(p_tutor, t.t0)
       and lms_tutor_available(p_tutor, t.t0)
       and not exists (select 1 from tutor_time_off o where o.tutor_id = p_tutor and o.starts_at < t.t0 + make_interval(mins => p_min) and t.t0 < o.ends_at)
       and not exists (select 1 from lessons y where y.tutor_id = p_tutor and y.state <> 'canceled' and y.voided_at is null
                         and not (y.student_id = p_student and y.kind = 'regular' and y.state = 'scheduled')
                         and y.starts_at < t.t0 + make_interval(mins => p_min) + interval '10 minutes' and t.t0 - interval '10 minutes' < y.ends_at)
       and not exists (select 1 from lms_slot_hold_hits(p_tutor, t.t0, t.t0 + make_interval(mins => p_min)) h where h.student_id <> p_student)
     ), false)
  from t
$$;

-- 가장 빠른 적용 주(월요일): 신청한 주가 아닌 다음 주부터 · 그 주 첫 바뀌는 수업 4일 전 날까지 · 그 수강기간에 확정된 변경 없음 · 수강 종료일 안
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
    if f <= e.final_end_date and p_today <= f - 4
       and not exists (select 1 from regular_change_requests r where r.enrollment_id = p_enrollment and r.status = 'confirmed'
                         and r.period_id = lms_lesson_period(p_enrollment, f) and r.id is distinct from p_skip) then
      return w;
    end if;
    w := w + 7;
  end loop;
  return null;
end $$;

-- 학생 정규 일정 맥락 (수강권·강사 하나·지금 정규 일정)
create or replace function lms_rc_context(p_student uuid, out e enrollments, out tutor tutors, out slots jsonb, out future_pending boolean)
language plpgsql stable security definer set search_path = public as $$
declare
  v_today date := (now() at time zone 'Asia/Seoul')::date;
  v_n int;
  v_t uuid;
begin
  select * into e from enrollments x where x.id = lms_student_enrollment(p_student);
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

-- ① 학생: 신청 화면에 필요한 것 (가능한 시간은 한국 요일·시각, 강사 개인 일정 안 보냄)
create or replace function student_regular_change_options(p_student uuid)
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
  w0 := lms_rc_monday(v_today) + 7;
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
    'tutor', (c.tutor).name, 'slots', c.slots, 'free', v_free,
    'periods', coalesce((select jsonb_agg(jsonb_build_object('start', p.start_date, 'end', p.end_date,
                 'used', exists (select 1 from regular_change_requests r where r.status = 'confirmed' and r.period_id = p.id)) order by p.idx)
               from enrollment_periods p where p.enrollment_id = (c.e).id), '[]'::jsonb));
end $$;

-- ① 학생: 신청 (items: [{old:{weekday,time}, c1:{weekday,time}, c2:{weekday,time}|null}])
create or replace function student_regular_change_request(p_student uuid, p_items jsonb, p_reason text default null)
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
      w := lms_rc_week((c.e).id, jsonb_build_array(jsonb_build_object('old', x -> 'old', 'new', cand)), v_today);
      if w is null or not lms_rc_free((c.tutor).id, v_student, w, (c.e).final_end_date, (cand ->> 'weekday')::int, (cand ->> 'time')::time, (c.e).duration_min) then
        raise exception '고른 시간이 이제 비어 있지 않아요. 다시 골라 주세요.' using hint = 'not_free';
      end if;
      v_item := v_item || jsonb_build_object(k, jsonb_build_object('weekday', (cand ->> 'weekday')::int, 'time', to_char((cand ->> 'time')::time, 'HH24:MI'),
                  'week', w, 'first', lms_rc_first(w, jsonb_build_array(jsonb_build_object('old', x -> 'old', 'new', cand)))));
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

create or replace function student_regular_change_withdraw(p_student uuid, p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare v_student uuid := lms_screen_student(p_student);
begin
  update regular_change_requests set status = 'withdrawn', decided_at = now(), decided_by = auth.uid()
  where id = p_id and student_id = v_student and status = 'pending';
  if not found then raise exception '취소할 수 있는 신청이 없어요.'; end if;
end $$;

-- ② 학생: 강사 변경 상담 (이유 코드: style·time·other_tutor·consult, 모두 선택)
create or replace function student_tutor_change_request(p_student uuid, p_reasons text[] default '{}', p_note text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_student uuid := lms_screen_student(p_student);
  v_id uuid;
begin
  if exists (select 1 from unnest(coalesce(p_reasons, '{}')) r where r not in ('style', 'time', 'other_tutor', 'consult')) then
    raise exception '상담 내용을 다시 골라 주세요.';
  end if;
  if exists (select 1 from tutor_change_requests where student_id = v_student and status = 'open') then
    raise exception '이미 요청했어요.' using hint = 'already';
  end if;
  insert into tutor_change_requests (student_id, tutor_id, reasons, note, via, created_by)
  values (v_student, (select ((x).tutor).id from lms_rc_context(v_student) x), coalesce(p_reasons, '{}'), nullif(trim(coalesce(p_note, '')), ''),
          case when is_admin() and p_student is not null then 'admin' else 'student' end, auth.uid())
  returning id into v_id;
  return jsonb_build_object('id', v_id);
end $$;

-- 학생: 내 신청 (처리 내역·홈 버튼 상태). 최근 120일
create or replace function student_change_requests(p_student uuid)
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'regular', coalesce((select jsonb_agg(jsonb_build_object('id', r.id, 'status', r.status, 'created_at', r.created_at, 'decided_at', r.decided_at,
                  'old_slots', r.old_slots, 'items', r.items, 'reason', r.reason, 'chosen', r.chosen, 'effective_from', r.effective_from) order by r.created_at desc)
                from regular_change_requests r where r.student_id = lms_screen_student(p_student) and r.created_at > now() - interval '120 days'), '[]'::jsonb),
    'tutor', coalesce((select jsonb_agg(jsonb_build_object('id', t.id, 'status', t.status, 'created_at', t.created_at, 'done_at', t.done_at,
                  'reasons', t.reasons, 'note', t.note) order by t.created_at desc)
                from tutor_change_requests t where t.student_id = lms_screen_student(p_student) and t.created_at > now() - interval '120 days'), '[]'::jsonb))
$$;

-- 운영진: 할 일 (대기 중인 정규 시간 변경 신청 · 열린 강사 변경 상담)
create or replace function admin_change_requests()
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not is_admin() then raise exception '운영자만 볼 수 있습니다.' using errcode = '42501'; end if;
  return jsonb_build_object(
    'regular', coalesce((select jsonb_agg(jsonb_build_object('id', r.id, 'student_code', st.code, 'student_name', st.name_ko, 'tutor', t.name,
                  'old_slots', r.old_slots, 'items', r.items, 'reason', r.reason, 'via', r.via, 'created_at', r.created_at) order by r.created_at)
                from regular_change_requests r join students st on st.id = r.student_id join tutors t on t.id = r.tutor_id
                where r.status = 'pending'), '[]'::jsonb),
    'tutor', coalesce((select jsonb_agg(jsonb_build_object('id', x.id, 'student_code', st.code, 'student_name', st.name_ko, 'tutor', t.name,
                  'reasons', x.reasons, 'note', x.note, 'via', x.via, 'created_at', x.created_at) order by x.created_at)
                from tutor_change_requests x join students st on st.id = x.student_id left join tutors t on t.id = x.tutor_id
                where x.status = 'open'), '[]'::jsonb));
end $$;

-- 운영진: 정규 시간 변경 확정·반려
--  p_choice: 바꾸는 수업마다 1 또는 2 (items 순서) · p_week: 다시 계산된 주로 확정할 때만 (앞 호출이 준 shifted_to)
--  확정 순간 admin_regular_change 미리 보기로 충돌 검사를 다시 돌리고, 막히면 저장하지 않고 사유 + 다음 가능한 주를 돌려줌
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
  v_new := r.old_slots;
  v_week := null;
  for i in 1..cardinality(p_choice) loop
    cand := (r.items -> (i - 1)) -> ('c' || p_choice[i]);
    if cand is null or jsonb_typeof(cand) <> 'object' then raise exception '고른 순위의 시간이 없어요.'; end if;
    v_pairs := v_pairs || jsonb_build_array(jsonb_build_object('old', (r.items -> (i - 1)) -> 'old', 'new', cand));
    select jsonb_agg(case when (s ->> 'weekday')::int = ((r.items -> (i - 1)) -> 'old' ->> 'weekday')::int
                          then jsonb_build_object('weekday', (cand ->> 'weekday')::int, 'time', cand ->> 'time') else s end)
      into v_new from jsonb_array_elements(v_new) s;
    v_week := greatest(v_week, (cand ->> 'week')::date);
  end loop;
  if p_week is not null then v_week := p_week; end if;

  -- 학생이 기한 안에 신청한 주 그대로 (H26(208) ⑥). 그 주 첫 바뀌는 수업이 이미 지났으면 오늘 기준으로 다시 계산
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
    -- 충돌: 다음 주부터 차례로 다시 돌려 막히지 않는 첫 주를 찾음
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

-- 운영진: 강사 변경 상담 완료
create or replace function admin_tutor_change_done(p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception '운영자만 처리할 수 있습니다.' using errcode = '42501'; end if;
  update tutor_change_requests set status = 'done', done_at = now(), done_by = auth.uid() where id = p_id and status = 'open';
  if not found then raise exception '이미 처리했어요.'; end if;
end $$;

revoke all on function lms_rc_free(uuid, uuid, date, date, int, time, int) from public, anon, authenticated;
revoke all on function lms_rc_week(uuid, jsonb, date, uuid) from public, anon, authenticated;
revoke all on function lms_rc_context(uuid) from public, anon, authenticated;
revoke all on function student_regular_change_options(uuid) from public, anon;
grant execute on function student_regular_change_options(uuid) to authenticated;
revoke all on function student_regular_change_request(uuid, jsonb, text) from public, anon;
grant execute on function student_regular_change_request(uuid, jsonb, text) to authenticated;
revoke all on function student_regular_change_withdraw(uuid, uuid) from public, anon;
grant execute on function student_regular_change_withdraw(uuid, uuid) to authenticated;
revoke all on function student_tutor_change_request(uuid, text[], text) from public, anon;
grant execute on function student_tutor_change_request(uuid, text[], text) to authenticated;
revoke all on function student_change_requests(uuid) from public, anon;
grant execute on function student_change_requests(uuid) to authenticated;
revoke all on function admin_change_requests() from public, anon;
grant execute on function admin_change_requests() to authenticated;
revoke all on function admin_regular_change_request_decide(uuid, text, int[], date) from public, anon;
grant execute on function admin_regular_change_request_decide(uuid, text, int[], date) to authenticated;
revoke all on function admin_tutor_change_done(uuid) from public, anon;
grant execute on function admin_tutor_change_done(uuid) to authenticated;
