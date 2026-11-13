-- 강사 휴무 신청 (정책 원본 H26(137), 대표 11/13 확정)
--  · 강사가 Home 'Time off' 에서 현지 날짜(첫날~마지막 날)·종류·사유로 신청 → 운영진 대시보드 '강사 휴무 신청'
--  · 운영진 [휴무 화면 열기] → 휴무 화면이 신청대로 채워짐 → 저장하면 신청이 자동 '승인' / [반려] = 사유 필수, 강사에게 보임
--  · 3일 이상만 (1~2일은 Calendar 의 Cancel class) · 계획된 휴무는 14일 전 (늦으면 경고만, 신청은 받음) · 급한 일은 기한 없음
--  · 휴무는 강사 현지 첫날 0:00 ~ 마지막 날 24:00 실제 시각으로 잡음 (한국 날짜로만 바꾸면 경계 수업이 빠지거나 더 들어감)
--  · 승인 전 강사 철회 가능 · 끝난 휴무는 다음 날 Home 에서 빠짐 · 확인 창 본인 기록 = 올해(현지 1/1부터)

create table if not exists tutor_time_off_requests (
  id uuid primary key default gen_random_uuid(),
  tutor_id uuid not null references tutors(id),
  first_day date not null,                -- 강사 현지 날짜
  last_day date not null,
  starts_at timestamptz not null,         -- 현지 첫날 0:00
  ends_at timestamptz not null,           -- 현지 마지막 날 다음 날 0:00
  kind text not null check (kind in ('planned', 'urgent')),
  reason text not null check (btrim(reason) <> ''),
  late boolean not null default false,    -- 계획된 휴무인데 14일 전보다 늦게 신청
  status text not null default 'pending' check (status in ('pending', 'approved', 'rejected', 'withdrawn')),
  reject_reason text,
  time_off_id uuid references tutor_time_off(id),
  created_by uuid,
  created_via text,                       -- 'tutor' | 'admin' (운영자 대신)
  created_at timestamptz not null default now(),
  decided_by uuid,
  decided_at timestamptz,
  check (last_day >= first_day and ends_at > starts_at),
  check (status <> 'rejected' or btrim(coalesce(reject_reason, '')) <> '')
);
create index if not exists tutor_time_off_requests_tutor on tutor_time_off_requests (tutor_id, status);
alter table tutor_time_off_requests enable row level security;
revoke all on table tutor_time_off_requests from anon, authenticated;

-- 신청 규칙 숫자 (대표 11/13 확정): 3일 이상 · 계획된 휴무 14일 전
create or replace function lms_time_off_min_days() returns integer language sql immutable as $$ select 3 $$;
create or replace function lms_time_off_notice_days() returns integer language sql immutable as $$ select 14 $$;
revoke all on function lms_time_off_min_days() from public, anon;
revoke all on function lms_time_off_notice_days() from public, anon;
grant execute on function lms_time_off_min_days() to authenticated;
grant execute on function lms_time_off_notice_days() to authenticated;

-- ---------------------------------------------------------------------
-- 휴무 후보 수업: 실제 시각 범위 [t0, t1). 이관 미예약 휴무 보강은 날짜만 있어 한국 날짜로 봄
-- 기존 lms_leave_candidates(날짜) = 한국 날짜 0:00 ~ 끝날 다음 날 0:00 로 이 함수를 부름 (결과 같음)
-- ---------------------------------------------------------------------
create or replace function lms_leave_candidates_at(p_tutor uuid, p_t0 timestamptz, p_t1 timestamptz)
returns table (lesson_id uuid, migrated_item_id uuid, student_id uuid, enrollment_id uuid, starts_at timestamptz, ends_at timestamptz, choice text)
language sql stable security definer set search_path = public as $$
  select l.id, null::uuid, l.student_id, l.enrollment_id, l.starts_at, l.ends_at, 'undecided'
  from lessons l
  where l.tutor_id = p_tutor and l.state = 'scheduled'
    and l.starts_at < p_t1 and p_t0 < l.ends_at
    and not exists (select 1 from leave_items i where i.lesson_id = l.id and i.withdrawn_at is null)
  union all
  select null::uuid, m.id, e.student_id, e.id,
         ((m.original_date + rs.start_time_kst) at time zone 'Asia/Seoul'),
         ((m.original_date + rs.start_time_kst) at time zone 'Asia/Seoul') + make_interval(mins => rs.duration_min), 'undecided'
  from migrated_items m
  join enrollments e on e.id = m.enrollment_id
  join regular_schedules rs on rs.student_id = e.student_id and rs.tutor_id = p_tutor
   and rs.weekday = extract(dow from m.original_date) and rs.effective_from <= m.original_date
   and (rs.effective_to is null or rs.effective_to >= m.original_date)
  where m.kind = 'makeup_open' and m.tutor_leave
    and m.original_date between (p_t0 at time zone 'Asia/Seoul')::date and ((p_t1 - interval '1 second') at time zone 'Asia/Seoul')::date
    and not exists (select 1 from leave_items i where i.migrated_item_id = m.id and i.withdrawn_at is null)
$$;
revoke all on function lms_leave_candidates_at(uuid, timestamptz, timestamptz) from public, anon, authenticated;

create or replace function lms_leave_candidates(p_tutor uuid, p_from date, p_to date)
returns table (lesson_id uuid, migrated_item_id uuid, student_id uuid, enrollment_id uuid, starts_at timestamptz, ends_at timestamptz, choice text)
language sql stable security definer set search_path = public as $$
  select * from lms_leave_candidates_at(p_tutor, (p_from::timestamp at time zone 'Asia/Seoul'), ((p_to + 1)::timestamp at time zone 'Asia/Seoul'))
$$;
revoke all on function lms_leave_candidates(uuid, date, date) from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- 휴무 넣기 (휴무 화면). p_request = 강사 신청에서 열었을 때: 날짜를 안 바꿨으면 신청의 실제 시각으로 잡고, 저장하면 신청 '승인'
-- 5개 인자 판(기존 화면·시험)은 p_request 없이 이 함수를 부름
-- ---------------------------------------------------------------------
create or replace function admin_leave_create(p_tutor uuid, p_from date, p_to date, p_reason text, p_dry_run boolean, p_request uuid)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  t0 timestamptz := (p_from::timestamp at time zone 'Asia/Seoul');
  t1 timestamptz := ((p_to + 1)::timestamp at time zone 'Asia/Seoul');
  rq tutor_time_off_requests;
  v_off uuid;
  v_lessons integer;
  v_items integer;
  v_students integer;
  v_overlap jsonb;
begin
  if not is_admin() then raise exception '운영자(추가 인증 완료)만 처리할 수 있습니다.' using errcode = '42501'; end if;
  if p_from is null or p_to is null or p_to < p_from then raise exception '휴무 끝일이 시작일보다 빠릅니다.'; end if;
  if not exists (select 1 from tutors where id = p_tutor) then raise exception '강사가 없습니다.'; end if;
  if p_request is not null then
    select * into rq from tutor_time_off_requests where id = p_request for update;
    if not found then raise exception '휴무 신청을 찾지 못했어요.'; end if;
    if rq.status <> 'pending' then raise exception '이미 처리된 휴무 신청입니다 (%).', rq.status; end if;
    if rq.tutor_id <> p_tutor then raise exception '신청한 강사와 다른 강사입니다.'; end if;
    -- 날짜를 신청 그대로 두면 강사 현지 실제 시각 (한국 날짜 범위 안에서)
    if p_from = (rq.starts_at at time zone 'Asia/Seoul')::date and p_to = ((rq.ends_at - interval '1 second') at time zone 'Asia/Seoul')::date then
      t0 := rq.starts_at; t1 := rq.ends_at;
    end if;
  end if;

  v_overlap := lms_leave_overlaps(p_tutor, p_from, p_to);
  select count(*) filter (where n.lesson_id is not null), count(*), count(distinct n.student_id)
  into v_lessons, v_items, v_students from lms_leave_candidates_at(p_tutor, t0, t1) n;
  if p_dry_run then
    return jsonb_build_object('dry_run', true, 'lessons', v_lessons, 'items', v_items, 'students', v_students, 'overlap', v_overlap,
      'existing', (select count(*) from leave_items i join tutor_time_off o on o.id = i.time_off_id
                   where o.tutor_id = p_tutor and o.starts_at = t0 and o.ends_at = t1 and o.withdrawn_at is null and i.withdrawn_at is null));
  end if;
  if jsonb_array_length(v_overlap) > 0 then
    raise exception '이미 있는 휴무(%~%)와 겹칩니다. 기존 휴무를 철회하고 다시 넣거나, 겹치지 않는 날짜로 나눠 넣어 주세요.',
      to_char((v_overlap -> 0 ->> 'from')::date, 'MM/DD'), to_char((v_overlap -> 0 ->> 'to')::date, 'MM/DD') using hint = 'leave_overlap';
  end if;

  perform set_config('app.actor_id', me::text, true);
  perform set_config('app.actor_via', 'admin_leave_create', true);
  select id into v_off from tutor_time_off where tutor_id = p_tutor and kind = 'leave' and starts_at = t0 and ends_at = t1 and withdrawn_at is null;
  if v_off is null then
    insert into tutor_time_off (tutor_id, starts_at, ends_at, kind, reason, notice_given_on, created_by)
    values (p_tutor, t0, t1, 'leave', nullif(trim(p_reason), ''), case when rq.id is not null then (rq.created_at at time zone 'Asia/Seoul')::date end, me)
    returning id into v_off;
  end if;
  with rev as (
    update leave_items i
    set time_off_id = v_off, tutor_id = p_tutor, student_id = n.student_id, enrollment_id = n.enrollment_id, starts_at = n.starts_at, ends_at = n.ends_at,
        choice = 'undecided', sub_tutor_id = null, sub_stage = null, sub_lesson_id = null, decided_at = null, decided_by = null,
        sub_declined = '{}', lesson_gone_at = null, withdrawn_at = null, created_by = me, created_at = now()
    from lms_leave_candidates_at(p_tutor, t0, t1) n
    where i.withdrawn_at is not null
      and ((n.lesson_id is not null and i.lesson_id = n.lesson_id) or (n.migrated_item_id is not null and i.migrated_item_id = n.migrated_item_id))
    returning i.id, i.student_id
  )
  insert into lesson_notices (leave_item_id, event, recipient_kind, recipient_id)
  select id, 'leave_options', 'student', student_id from rev;
  with ins as (
    insert into leave_items (time_off_id, tutor_id, student_id, enrollment_id, lesson_id, migrated_item_id, starts_at, ends_at, choice, created_by)
    select v_off, p_tutor, n.student_id, n.enrollment_id, n.lesson_id, n.migrated_item_id, n.starts_at, n.ends_at, n.choice, me
    from lms_leave_candidates_at(p_tutor, t0, t1) n
    on conflict do nothing
    returning id, student_id
  )
  insert into lesson_notices (leave_item_id, event, recipient_kind, recipient_id)
  select id, 'leave_options', 'student', student_id from ins;
  if rq.id is not null then
    update tutor_time_off_requests set status = 'approved', time_off_id = v_off, decided_by = me, decided_at = now() where id = rq.id;
  end if;
  return jsonb_build_object('dry_run', false, 'time_off_id', v_off, 'lessons', v_lessons, 'items', v_items, 'students', v_students);
end $$;
revoke all on function admin_leave_create(uuid, date, date, text, boolean, uuid) from public, anon;
grant execute on function admin_leave_create(uuid, date, date, text, boolean, uuid) to authenticated;

create or replace function admin_leave_create(p_tutor uuid, p_from date, p_to date, p_reason text, p_dry_run boolean)
returns jsonb
language sql security definer set search_path = public as $$
  select admin_leave_create(p_tutor, p_from, p_to, p_reason, p_dry_run, null::uuid)
$$;
revoke all on function admin_leave_create(uuid, date, date, text, boolean) from public, anon;
grant execute on function admin_leave_create(uuid, date, date, text, boolean) to authenticated;

-- ---------------------------------------------------------------------
-- 강사 화면 (운영자 보기 = p_tutor)
-- ---------------------------------------------------------------------
-- 고른 기간(현지 날짜)에 걸리는 수업 + 늦은 신청 여부 (신청 창이 날짜를 고를 때마다 부름)
create or replace function tutor_time_off_preview(p_tutor uuid, p_first date, p_last date)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_tutor uuid := lms_screen_tutor(p_tutor);
  v_tz text;
  v_today date;
  t0 timestamptz;
  t1 timestamptz;
begin
  select timezone into v_tz from tutors where id = v_tutor;
  v_today := (now() at time zone v_tz)::date;
  if p_first is null or p_last is null or p_last < p_first then raise exception 'Last day off must be on or after the first day.'; end if;
  t0 := (p_first::timestamp at time zone v_tz);
  t1 := ((p_last + 1)::timestamp at time zone v_tz);
  return jsonb_build_object(
    'days', p_last - p_first + 1,
    'notice_days', p_first - v_today,
    'classes', coalesce((
      select jsonb_agg(jsonb_build_object('starts_at', l.starts_at, 'ends_at', l.ends_at, 'student', lms_tutor_student_label(s.name_en, s.display_name)) order by l.starts_at)
      from lessons l join students s on s.id = l.student_id
      where l.tutor_id = v_tutor and l.state = 'scheduled' and l.starts_at < t1 and t0 < l.ends_at), '[]'::jsonb));
end $$;
revoke all on function tutor_time_off_preview(uuid, date, date) from public, anon;
grant execute on function tutor_time_off_preview(uuid, date, date) to authenticated;

-- Home 'Time off' 목록 + 올해 기록
create or replace function tutor_time_off_list(p_tutor uuid)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_tutor uuid := lms_screen_tutor(p_tutor);
  v_tz text;
  v_year_start timestamptz;
begin
  select timezone into v_tz from tutors where id = v_tutor;
  v_year_start := (date_trunc('year', now() at time zone v_tz))::timestamp at time zone v_tz;
  return jsonb_build_object(
    'timezone', v_tz,
    'today', (now() at time zone v_tz)::date,
    'rows', coalesce((
      select jsonb_agg(x order by x ->> 'first') from (
        -- 신청 (철회 제외, 승인된 것은 휴무가 철회되지 않은 것만), 마지막 날이 지나면 빠짐
        select jsonb_build_object('id', r.id, 'source', 'request', 'status', r.status, 'first', r.first_day, 'last', r.last_day,
                 'kind', r.kind, 'reason', r.reason, 'reject_reason', r.reject_reason, 'late', r.late, 'created_at', r.created_at,
                 'classes', (select count(*) from lessons l where l.tutor_id = r.tutor_id and l.state = 'scheduled' and l.starts_at < r.ends_at and r.starts_at < l.ends_at)) x
        from tutor_time_off_requests r
        left join tutor_time_off o on o.id = r.time_off_id
        where r.tutor_id = v_tutor and r.status in ('pending', 'approved', 'rejected') and r.ends_at > now()
          and not (r.status = 'approved' and o.withdrawn_at is not null)
        union all
        -- 운영진이 직접 넣은 휴무 (신청 없이) = 승인된 휴무로 보임
        select jsonb_build_object('id', o.id, 'source', 'leave', 'status', 'approved',
                 'first', (o.starts_at at time zone v_tz)::date, 'last', ((o.ends_at - interval '1 second') at time zone v_tz)::date)
        from tutor_time_off o
        where o.tutor_id = v_tutor and o.kind = 'leave' and o.withdrawn_at is null and o.ends_at > now()
          and not exists (select 1 from tutor_time_off_requests r where r.time_off_id = o.id)
      ) t), '[]'::jsonb),
    'year', coalesce((
      select jsonb_agg(jsonb_build_object('first', (o.starts_at at time zone v_tz)::date, 'last', ((o.ends_at - interval '1 second') at time zone v_tz)::date) order by o.starts_at)
      from tutor_time_off o
      where o.tutor_id = v_tutor and o.kind = 'leave' and o.withdrawn_at is null and o.starts_at >= v_year_start), '[]'::jsonb));
end $$;
revoke all on function tutor_time_off_list(uuid) from public, anon;
grant execute on function tutor_time_off_list(uuid) to authenticated;

create or replace function tutor_time_off_request(p_tutor uuid, p_first date, p_last date, p_kind text, p_reason text)
returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_tutor uuid := lms_screen_tutor(p_tutor);
  v_tz text;
  v_today date;
  t0 timestamptz;
  t1 timestamptz;
  v_id uuid;
begin
  select timezone into v_tz from tutors where id = v_tutor;
  v_today := (now() at time zone v_tz)::date;
  if p_first is null or p_last is null or p_last < p_first then raise exception 'Last day off must be on or after the first day.'; end if;
  if p_first < v_today then raise exception 'The first day off has already passed.'; end if;
  if p_last - p_first + 1 < lms_time_off_min_days() then raise exception 'For 1–2 days off, cancel each class in Calendar.'; end if;
  if p_kind not in ('planned', 'urgent') then raise exception 'Choose planned or urgent.'; end if;
  if btrim(coalesce(p_reason, '')) = '' then raise exception 'Please enter a reason.'; end if;
  t0 := (p_first::timestamp at time zone v_tz);
  t1 := ((p_last + 1)::timestamp at time zone v_tz);
  if exists (select 1 from tutor_time_off_requests r where r.tutor_id = v_tutor and r.status = 'pending' and r.starts_at < t1 and t0 < r.ends_at) then
    raise exception 'You already have a request for these days.';
  end if;
  if exists (select 1 from tutor_time_off o where o.tutor_id = v_tutor and o.kind = 'leave' and o.withdrawn_at is null and o.starts_at < t1 and t0 < o.ends_at) then
    raise exception 'You already have time off on these days.';
  end if;
  insert into tutor_time_off_requests (tutor_id, first_day, last_day, starts_at, ends_at, kind, reason, late, created_by, created_via)
  values (v_tutor, p_first, p_last, t0, t1, p_kind, btrim(p_reason),
          p_kind = 'planned' and p_first - v_today < lms_time_off_notice_days(),
          auth.uid(), case when is_admin() and my_tutor_id() is distinct from v_tutor then 'admin' else 'tutor' end)
  returning id into v_id;
  return v_id;
end $$;
revoke all on function tutor_time_off_request(uuid, date, date, text, text) from public, anon;
grant execute on function tutor_time_off_request(uuid, date, date, text, text) to authenticated;

-- 승인 전 철회 (다시 눌러도 같은 결과)
create or replace function tutor_time_off_withdraw(p_tutor uuid, p_request uuid)
returns void
language plpgsql security definer set search_path = public as $$
declare
  v_tutor uuid := lms_screen_tutor(p_tutor);
  r tutor_time_off_requests;
begin
  select * into r from tutor_time_off_requests where id = p_request and tutor_id = v_tutor for update;
  if not found then raise exception 'Request not found.'; end if;
  if r.status = 'withdrawn' then return; end if;
  if r.status <> 'pending' then raise exception 'This request has already been handled by Edge English.'; end if;
  update tutor_time_off_requests set status = 'withdrawn', decided_by = auth.uid(), decided_at = now() where id = r.id;
end $$;
revoke all on function tutor_time_off_withdraw(uuid, uuid) from public, anon;
grant execute on function tutor_time_off_withdraw(uuid, uuid) to authenticated;

-- ---------------------------------------------------------------------
-- 운영진
-- ---------------------------------------------------------------------
-- 대시보드 '강사 휴무 신청' (대기 중만). 날짜는 강사 현지 + 휴무 화면에 채울 한국 날짜
create or replace function admin_time_off_requests()
returns table (id uuid, tutor_id uuid, tutor_name text, tutor_timezone text, first_day date, last_day date, kst_from date, kst_to date,
               kind text, reason text, late boolean, classes integer, created_at timestamptz)
language plpgsql stable security definer set search_path = public as $$
begin
  if not is_admin() then raise exception '운영자(추가 인증 완료)만 볼 수 있습니다.' using errcode = '42501'; end if;
  return query
  select r.id, r.tutor_id, t.name, t.timezone, r.first_day, r.last_day,
         (r.starts_at at time zone 'Asia/Seoul')::date, ((r.ends_at - interval '1 second') at time zone 'Asia/Seoul')::date,
         r.kind, r.reason, r.late,
         (select count(*)::integer from lessons l where l.tutor_id = r.tutor_id and l.state = 'scheduled' and l.starts_at < r.ends_at and r.starts_at < l.ends_at),
         r.created_at
  from tutor_time_off_requests r join tutors t on t.id = r.tutor_id
  where r.status = 'pending'
  order by r.first_day;
end $$;
revoke all on function admin_time_off_requests() from public, anon;
grant execute on function admin_time_off_requests() to authenticated;

create or replace function admin_time_off_reject(p_request uuid, p_reason text)
returns void
language plpgsql security definer set search_path = public as $$
declare
  r tutor_time_off_requests;
begin
  if not is_admin() then raise exception '운영자(추가 인증 완료)만 처리할 수 있습니다.' using errcode = '42501'; end if;
  if btrim(coalesce(p_reason, '')) = '' then raise exception '반려 사유를 넣어 주세요.'; end if;
  select * into r from tutor_time_off_requests where id = p_request for update;
  if not found then raise exception '휴무 신청을 찾지 못했어요.'; end if;
  if r.status = 'rejected' then return; end if;
  if r.status <> 'pending' then raise exception '이미 처리된 휴무 신청입니다.'; end if;
  update tutor_time_off_requests set status = 'rejected', reject_reason = btrim(p_reason), decided_by = auth.uid(), decided_at = now() where id = r.id;
end $$;
revoke all on function admin_time_off_reject(uuid, text) from public, anon;
grant execute on function admin_time_off_reject(uuid, text) to authenticated;
