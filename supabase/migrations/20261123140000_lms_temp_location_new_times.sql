-- =====================================================================
-- 강사 임시 근무 지역 변경 → 새 수업 시간 고르기 (정책 원본 H26(218), 대표 11/23)
--  시안: docs/lms/previews/tutor-temp-location-new-times.html
--  대상 회차 (매번 다시 찾음, 처리 상태가 저장된 회차는 저장된 상태로):
--   ① 이미 있는 정규 수업 — 강사 임시 근무 지역 기간 안인데 그 지역 가능 시간(매주·하루 열기)이 아닌 예정 수업
--      (강사 휴무·막아 둔 시간과 겹치는 수업, 휴무 처리 중 수업, 대체강사 수업은 빼고 — 그건 기존 절차)
--   ② 일부 확정 때 남긴 '시간 협의 필요' 회차 (plan_pending_lessons, 20261122100000)
--  D-43 예외 (이 회차에만): 학생이 강사 가능 시간 중 고르면 확정 직전 다시 검사 → 통과한 회차만 바로 확정
--   강사는 학생과 합의한 시간을 보냄 → 학생 [이 일정에 동의하기] 뒤에만 같은 검사로 확정
--   검사에 걸린 회차만 '운영진 확인', 나머지는 확정. 같은 주(월~일, 한국 날짜) 안에서만, 수강 종료일 안에서만
--  정규 시간(regular_schedules)·변경권·시작/종료일·결제는 그대로. 메일은 아직 없음 (문구 대표 확정 전, CLAUDE.md 16)
-- =====================================================================

create table if not exists temp_location_moves (
  id uuid primary key default gen_random_uuid(),
  tutor_id uuid not null references tutors(id),
  student_id uuid not null references students(id),
  enrollment_id uuid not null references enrollments(id),
  location_id uuid not null references tutor_locations(id),
  lesson_id uuid references lessons(id),
  pending_id uuid references plan_pending_lessons(id),
  orig_starts_at timestamptz not null,
  minutes integer not null,
  -- proposed = 강사 신청(학생 동의 대기) · returned = 학생 '다시 조정' · later = 나중에 고르기
  -- confirmed = 확정 · admin = 운영진 확인 · admin_done = 운영진이 다른 방법으로 처리
  state text not null check (state in ('proposed', 'returned', 'later', 'confirmed', 'admin', 'admin_done')),
  new_starts_at timestamptz,
  conflict text,
  batch_id uuid,
  by_kind text check (by_kind in ('tutor', 'student', 'admin')),
  by_admin boolean not null default false,
  result_lesson_id uuid references lessons(id),
  created_by uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  decided_at timestamptz,
  check (num_nonnulls(lesson_id, pending_id) = 1)
);
create unique index if not exists temp_location_moves_lesson on temp_location_moves (lesson_id) where lesson_id is not null;
create unique index if not exists temp_location_moves_pending on temp_location_moves (pending_id) where pending_id is not null;
create index if not exists temp_location_moves_tutor on temp_location_moves (tutor_id, state);
create index if not exists temp_location_moves_student on temp_location_moves (student_id, state);
alter table temp_location_moves enable row level security;
drop policy if exists temp_location_moves_admin_read on temp_location_moves;
create policy temp_location_moves_admin_read on temp_location_moves for select using (is_admin());
revoke insert, update, delete on temp_location_moves from anon, authenticated;
drop trigger if exists temp_location_moves_no_delete on temp_location_moves;
create trigger temp_location_moves_no_delete before delete on temp_location_moves for each row execute function forbid_delete();
drop trigger if exists temp_location_moves_audit on temp_location_moves;
create trigger temp_location_moves_audit after insert or update or delete on temp_location_moves for each row execute function write_audit();
drop trigger if exists temp_location_moves_touch on temp_location_moves;
create trigger temp_location_moves_touch before update on temp_location_moves for each row execute function touch_updated_at();

-- 대상 회차 전부 (key = 'l:'수업 id · 'p:'협의 필요 회차 id). state null = 아직 아무 처리 없음
create or replace function lms_ttl_rows(p_tutor uuid, p_student uuid)
returns table (key text, lesson_id uuid, pending_id uuid, tutor_id uuid, student_id uuid, enrollment_id uuid, location_id uuid,
               orig_starts_at timestamptz, minutes integer, state text, new_starts_at timestamptz, conflict text, batch_id uuid, move_id uuid)
language sql stable security definer set search_path = public as $$
  with det as (
    select 'l:' || l.id as key, l.id as lesson_id, null::uuid as pending_id, l.tutor_id, l.student_id, l.enrollment_id,
           lms_tutor_location_at(l.tutor_id, l.starts_at) as location_id, l.starts_at as orig,
           (extract(epoch from l.ends_at - l.starts_at) / 60)::int as minutes
    from lessons l
    where (p_tutor is null or l.tutor_id = p_tutor) and (p_student is null or l.student_id = p_student)
      and l.kind = 'regular' and l.state = 'scheduled' and l.voided_at is null and l.original_tutor_id is null
      and l.enrollment_id is not null and l.starts_at > now()
      and lms_tutor_location_at(l.tutor_id, l.starts_at) is not null
      and not lms_tutor_available(l.tutor_id, l.starts_at)
      and not exists (select 1 from tutor_time_off o where o.tutor_id = l.tutor_id and o.starts_at < l.ends_at and l.starts_at < o.ends_at)
      and not exists (select 1 from leave_items li where li.lesson_id = l.id and li.withdrawn_at is null)
      and not exists (select 1 from temp_location_moves m where m.lesson_id = l.id)
    union all
    select 'p:' || p.id, null::uuid, p.id, p.tutor_id, p.student_id, p.enrollment_id,
           lms_tutor_location_at(p.tutor_id, (p.original_date + p.time_kst) at time zone 'Asia/Seoul'),
           (p.original_date + p.time_kst) at time zone 'Asia/Seoul', e.duration_min::int
    from plan_pending_lessons p join enrollments e on e.id = p.enrollment_id
    where (p_tutor is null or p.tutor_id = p_tutor) and (p_student is null or p.student_id = p_student)
      and p.resolved_at is null
      and not exists (select 1 from temp_location_moves m where m.pending_id = p.id)
  )
  select d.key, d.lesson_id, d.pending_id, d.tutor_id, d.student_id, d.enrollment_id, d.location_id, d.orig, d.minutes,
         null::text, null::timestamptz, null::text, null::uuid, null::uuid
  from det d where d.location_id is not null
  union all
  select case when m.lesson_id is not null then 'l:' || m.lesson_id else 'p:' || m.pending_id end,
         m.lesson_id, m.pending_id, m.tutor_id, m.student_id, m.enrollment_id, m.location_id, m.orig_starts_at, m.minutes,
         m.state, m.new_starts_at, m.conflict, m.batch_id, m.id
  from temp_location_moves m
  where (p_tutor is null or m.tutor_id = p_tutor) and (p_student is null or m.student_id = p_student)
    and (m.state in ('confirmed', 'admin', 'admin_done')
         -- 아직 처리 안 끝난 회차는 지금도 옮길 필요가 있을 때만 (강사가 그 시간을 열었거나 수업이 취소됐으면 빠짐)
         or (m.lesson_id is not null and exists (select 1 from lessons l where l.id = m.lesson_id and l.state = 'scheduled' and l.voided_at is null
                                                   and l.starts_at > now() and not lms_tutor_available(l.tutor_id, l.starts_at)))
         or (m.pending_id is not null and exists (select 1 from plan_pending_lessons p where p.id = m.pending_id and p.resolved_at is null)))
$$;

-- 한 회차를 그 시각으로 옮길 수 있는지. null = 됨, 아니면 까닭 코드
--  outside 임시 근무 지역 기간 밖 · week 다른 주 · end 수강 기간 밖 · past 지난 시각 · off 강사 휴무 · hours 강사 가능 시간 아님
--  busy 강사 다른 수업·다른 학생 신청 대기·재등록 대기 고정 시간 · student 학생 다른 수업
create or replace function lms_ttl_conflict(p_tutor uuid, p_student uuid, p_enrollment uuid, p_location uuid, p_lesson uuid,
                                            p_orig timestamptz, p_min integer, p_at timestamptz)
returns text
language plpgsql stable security definer set search_path = public as $$
declare
  t1 timestamptz := p_at + make_interval(mins => p_min);
  d date := (p_at at time zone 'Asia/Seoul')::date;
  e enrollments;
  c text;
begin
  if p_at <= now() then return 'past'; end if;
  if lms_rc_monday(d) <> lms_rc_monday((p_orig at time zone 'Asia/Seoul')::date) then return 'week'; end if;
  if lms_tutor_location_at(p_tutor, p_at) is distinct from p_location then return 'outside'; end if;
  select * into e from enrollments where id = p_enrollment;
  if d < e.start_date or d > e.final_end_date then return 'end'; end if;
  c := lms_makeup_conflict(p_tutor, p_student, p_at, t1, false, p_lesson);
  if c is not null then
    return case when c like '강사 휴무%' then 'off' when c like '강사 현지%' or c like '강사가 열어 둔%' then 'hours' else 'busy' end;
  end if;
  if exists (select 1 from lms_slot_hold_hits(p_tutor, p_at, t1) h where h.student_id <> p_student) then return 'busy'; end if;
  -- 다른 학생이 이미 신청(동의 대기)한 시간
  if exists (select 1 from temp_location_moves m where m.tutor_id = p_tutor and m.state = 'proposed' and m.student_id <> p_student
             and m.new_starts_at is not null
             and m.new_starts_at < t1 + interval '10 minutes' and p_at - interval '10 minutes' < m.new_starts_at + make_interval(mins => m.minutes)) then
    return 'busy';
  end if;
  if exists (select 1 from lessons y where y.student_id = p_student and y.id is distinct from p_lesson and y.state <> 'canceled' and y.voided_at is null
             and y.starts_at < t1 and p_at < y.ends_at) then
    return 'student';
  end if;
  return null;
end $$;

-- 한 회차가 고를 수 있는 시각 (그 주 월~일 한국 날짜, 30분 간격)
create or replace function lms_ttl_cands(p_tutor uuid, p_student uuid, p_enrollment uuid, p_location uuid, p_lesson uuid,
                                         p_orig timestamptz, p_min integer)
returns setof timestamptz
language sql stable security definer set search_path = public as $$
  select s.t from (
    select ((lms_rc_monday((p_orig at time zone 'Asia/Seoul')::date) + d)::timestamp + make_interval(mins => n * 30)) at time zone 'Asia/Seoul' as t
    from generate_series(0, 6) d, generate_series(0, 47) n) s
  where s.t > now()
    and lms_tutor_location_at(p_tutor, s.t) = p_location
    and lms_tutor_available(p_tutor, s.t)
    and lms_ttl_conflict(p_tutor, p_student, p_enrollment, p_location, p_lesson, p_orig, p_min, s.t) is null
  order by s.t
$$;

-- 화면용 묶음 (강사·학생·위치마다 1건). 모든 회차가 확정·운영진 처리 끝이면 빠짐
create or replace function lms_ttl_items(p_tutor uuid, p_student uuid)
returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(g order by g ->> 'first'), '[]'::jsonb) from (
    select jsonb_build_object(
             'tutor_id', r.tutor_id, 'tutor', tu.name, 'student_id', r.student_id,
             'student', lms_tutor_student_label(s.name_en, s.display_name),
             'location_id', r.location_id, 'city', loc.city, 'timezone', loc.timezone, 'from', loc.starts_on, 'to', loc.ends_on,
             'first', min(r.orig_starts_at),
             'rc_pending', exists (select 1 from regular_change_requests q where q.student_id = r.student_id and q.status = 'pending'),
             'rows', jsonb_agg(jsonb_build_object('key', r.key, 'orig', r.orig_starts_at, 'minutes', r.minutes, 'state', r.state,
                                                  'new', r.new_starts_at, 'conflict', r.conflict) order by r.orig_starts_at)) as g
    from lms_ttl_rows(p_tutor, p_student) r
    join tutors tu on tu.id = r.tutor_id
    join students s on s.id = r.student_id
    join tutor_locations loc on loc.id = r.location_id
    group by r.tutor_id, tu.name, r.student_id, s.name_en, s.display_name, r.location_id, loc.city, loc.timezone, loc.starts_on, loc.ends_on
    having bool_or(r.state is null or r.state not in ('confirmed', 'admin_done'))
  ) x
$$;

create or replace function tutor_ttl_items(p_tutor uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  return lms_ttl_items(lms_screen_tutor(p_tutor), null);
end $$;

create or replace function student_ttl_items(p_student uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  return lms_ttl_items(null, lms_screen_student(p_student));
end $$;

-- 고르기 창: 아직 고르지 않은 회차와 회차마다 고를 수 있는 시각, 매주 시간 후보
create or replace function lms_ttl_options(p_tutor uuid, p_student uuid)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_rows jsonb;
  weekly jsonb;
  need integer;
begin
  with r as (
    select x.*, coalesce((select array_agg(c order by c) from lms_ttl_cands(x.tutor_id, x.student_id, x.enrollment_id, x.location_id, x.lesson_id,
                                                                           x.orig_starts_at, x.minutes) c), '{}') as cands
    from lms_ttl_rows(p_tutor, p_student) x
    where x.state is null or x.state in ('later', 'returned')
  )
  select coalesce(jsonb_agg(jsonb_build_object('key', r.key, 'orig', r.orig_starts_at, 'minutes', r.minutes, 'state', r.state,
                                               'cands', to_jsonb(r.cands)) order by r.orig_starts_at), '[]'::jsonb),
         (select coalesce(jsonb_agg(jsonb_build_object('dow', w.dow, 'time', w.tm, 'sample', w.sample) order by (w.dow + 6) % 7, w.tm), '[]'::jsonb)
          from (select extract(dow from c at time zone 'Asia/Seoul')::int as dow, to_char(c at time zone 'Asia/Seoul', 'HH24:MI') as tm, min(c) as sample
                from r, unnest(r.cands) c group by 1, 2) w),
         (select coalesce(max(n), 0) from (select count(*) n from r group by lms_rc_monday((r.orig_starts_at at time zone 'Asia/Seoul')::date)) k)
    into v_rows, weekly, need
  from r;
  return jsonb_build_object('rows', v_rows, 'weekly', weekly, 'need', need,
    'rc_pending', exists (select 1 from regular_change_requests q where q.student_id = p_student and q.status = 'pending'),
    'proposed', exists (select 1 from temp_location_moves m where m.tutor_id = p_tutor and m.student_id = p_student and m.state = 'proposed'));
end $$;

create or replace function tutor_ttl_options(p_tutor uuid, p_student uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  return lms_ttl_options(lms_screen_tutor(p_tutor), p_student);
end $$;

create or replace function student_ttl_options(p_student uuid, p_tutor uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  return lms_ttl_options(p_tutor, lms_screen_student(p_student));
end $$;

-- 같은 주 안 정규 회차 번호를 날짜순으로 (번호 묶음은 그대로 — 협의 필요 회차 번호와 안 겹치게)
create or replace function lms_ttl_reseq(p_enrollment uuid, p_week date)
returns void language plpgsql security definer set search_path = public as $$
declare
  ids uuid[];
  seqs integer[];
begin
  select array_agg(id order by starts_at, id), array_agg(seq order by seq) into ids, seqs
  from lessons where enrollment_id = p_enrollment and kind = 'regular' and lms_rc_monday((starts_at at time zone 'Asia/Seoul')::date) = p_week;
  if ids is null or not exists (select 1 from unnest(ids, seqs) u(i, n) join lessons l on l.id = u.i where l.seq <> u.n) then return; end if;
  update lessons set seq = seq + 100000 where id = any(ids);
  update lessons l set seq = u.n from unnest(ids, seqs) u(i, n) where l.id = u.i;
end $$;

-- 처리 줄 저장 (회차마다 1줄, 있으면 고침)
create or replace function lms_ttl_save(p_row jsonb, p_state text, p_at timestamptz, p_conflict text,
                                        p_batch uuid, p_by text, p_result uuid)
returns void
language plpgsql security definer set search_path = public as $$
declare
  v_id uuid;
begin
  select x.id into v_id from temp_location_moves x
  where x.lesson_id = (p_row ->> 'lesson_id')::uuid or x.pending_id = (p_row ->> 'pending_id')::uuid;
  if v_id is not null then
    update temp_location_moves set state = p_state, new_starts_at = p_at, conflict = p_conflict, batch_id = p_batch, by_kind = p_by,
           by_admin = is_admin() and p_by <> 'admin', result_lesson_id = coalesce(p_result, result_lesson_id),
           decided_at = case when p_state in ('confirmed', 'admin', 'admin_done') then now() end
    where id = v_id;
  else
    insert into temp_location_moves (tutor_id, student_id, enrollment_id, location_id, lesson_id, pending_id, orig_starts_at, minutes,
                                     state, new_starts_at, conflict, batch_id, by_kind, by_admin, result_lesson_id, created_by, decided_at)
    values ((p_row ->> 'tutor_id')::uuid, (p_row ->> 'student_id')::uuid, (p_row ->> 'enrollment_id')::uuid, (p_row ->> 'location_id')::uuid,
            (p_row ->> 'lesson_id')::uuid, (p_row ->> 'pending_id')::uuid, (p_row ->> 'orig_starts_at')::timestamptz, (p_row ->> 'minutes')::int,
            p_state, p_at, p_conflict, p_batch, p_by, is_admin() and p_by <> 'admin', p_result, auth.uid(),
            case when p_state in ('confirmed', 'admin', 'admin_done') then now() end);
  end if;
end $$;

-- 한 회차 확정 (확정 직전 다시 검사 → 통과하면 옮김/수업 만듦, 걸리면 운영진 확인). 돌려줌: confirmed · admin
create or replace function lms_ttl_confirm_one(p_tutor uuid, p_student uuid, p_key text, p_at timestamptz, p_batch uuid, p_by text)
returns text
language plpgsql security definer set search_path = public as $$
declare
  r record;
  c text;
  v_new uuid;
  p plan_pending_lessons;
begin
  select * into r from lms_ttl_rows(p_tutor, p_student) x where x.key = p_key;
  if not found then return 'gone'; end if;
  if p_at is null then
    c := 'asked';
  else
    c := lms_ttl_conflict(r.tutor_id, r.student_id, r.enrollment_id, r.location_id, r.lesson_id, r.orig_starts_at, r.minutes, p_at);
  end if;
  if c is null then
    perform set_config('app.actor_via', 'ttl_confirm', true);
    if r.lesson_id is not null then
      if not exists (select 1 from lessons where id = r.lesson_id and state = 'scheduled' and voided_at is null) then
        c := 'gone';
      else
        begin
          update lessons set starts_at = p_at, ends_at = p_at + make_interval(mins => r.minutes) where id = r.lesson_id;
          v_new := r.lesson_id;
        exception when exclusion_violation then c := 'busy';
        end;
      end if;
    else
      select * into p from plan_pending_lessons where id = r.pending_id for update;
      if p.resolved_at is not null then
        c := 'gone';
      else
        begin
          insert into lessons (enrollment_id, student_id, tutor_id, kind, seq, starts_at, ends_at, created_by)
          values (r.enrollment_id, r.student_id, r.tutor_id, 'regular', p.seq, p_at, p_at + make_interval(mins => r.minutes), auth.uid())
          returning id into v_new;
          update plan_pending_lessons set lesson_id = v_new, resolved_at = now() where id = p.id;
        exception when exclusion_violation or unique_violation then c := 'busy'; v_new := null;
        end;
      end if;
    end if;
  end if;
  perform lms_ttl_save(to_jsonb(r), case when c is null then 'confirmed' else 'admin' end, p_at, c, p_batch, p_by, v_new);
  return case when c is null then 'confirmed' else 'admin' end;
end $$;

-- 신청 공통. p_items = [{key, at}] · at 없으면 {key, admin:true}(운영진에게 맡김) 또는 {key, later:true}
--  p_by 'tutor' → 강사 신청(학생 동의 대기) · 'student' → 바로 확정
create or replace function lms_ttl_submit(p_tutor uuid, p_student uuid, p_items jsonb, p_by text)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  it jsonb;
  r record;
  v_batch uuid := gen_random_uuid();
  v_at timestamptz;
  c text;
  st text;
  n_ok integer := 0;
  n_admin integer := 0;
  n_sent integer := 0;
  v_weeks jsonb := '[]'::jsonb;
  w record;
begin
  perform pg_advisory_xact_lock(hashtextextended('ttl:' || p_tutor, 0));
  if exists (select 1 from regular_change_requests q where q.student_id = p_student and q.status = 'pending') then
    raise exception '%', case when p_by = 'tutor' then 'The student has a pending regular schedule change. Please try again after it is processed.'
                              else '정규 시간 변경 신청이 처리된 뒤에 고를 수 있어요.' end using hint = 'ttl';
  end if;
  if exists (select 1 from temp_location_moves m where m.tutor_id = p_tutor and m.student_id = p_student and m.state = 'proposed') then
    raise exception '%', case when p_by = 'tutor' then 'Waiting for the student to confirm your last request.'
                              else '선생님이 신청한 수업 시간을 먼저 확인해 주세요.' end using hint = 'ttl';
  end if;
  if jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then
    raise exception '%', case when p_by = 'tutor' then 'Choose at least one class.' else '고른 수업이 없어요.' end using hint = 'ttl';
  end if;
  for it in select * from jsonb_array_elements(p_items) loop
    select * into r from lms_ttl_rows(p_tutor, p_student) x where x.key = it ->> 'key';
    if not found or not (r.state is null or r.state in ('later', 'returned')) then
      raise exception '%', case when p_by = 'tutor' then 'This class was already handled. Please reopen the list.'
                                else '이미 처리된 수업이 있어요. 창을 닫고 다시 열어 주세요.' end using hint = 'ttl';
    end if;
    if (it ->> 'later')::boolean is true then
      perform lms_ttl_save(to_jsonb(r), 'later', null, null, v_batch, p_by, null);
      continue;
    end if;
    v_at := case when (it ->> 'admin')::boolean is true then null else (it ->> 'at')::timestamptz end;
    if v_at is null and (it ->> 'admin')::boolean is not true then
      raise exception '%', case when p_by = 'tutor' then 'Choose a time for every class.' else '시간을 고르지 않은 수업이 있어요.' end using hint = 'ttl';
    end if;
    if p_by = 'tutor' then
      if v_at is not null then
        c := lms_ttl_conflict(r.tutor_id, r.student_id, r.enrollment_id, r.location_id, r.lesson_id, r.orig_starts_at, r.minutes, v_at);
        if c is not null or not lms_tutor_available(r.tutor_id, v_at) then
          raise exception 'One of the times is no longer available (%). Please reopen the list.', coalesce(c, 'hours') using hint = 'ttl';
        end if;
      end if;
      perform lms_ttl_save(to_jsonb(r), 'proposed', v_at, null, v_batch, p_by, null);
      n_sent := n_sent + 1;
    else
      st := lms_ttl_confirm_one(p_tutor, p_student, r.key, v_at, v_batch, p_by);
      if st = 'confirmed' then n_ok := n_ok + 1; else n_admin := n_admin + 1; end if;
      v_weeks := v_weeks || jsonb_build_object('e', r.enrollment_id, 'w', lms_rc_monday((r.orig_starts_at at time zone 'Asia/Seoul')::date));
    end if;
  end loop;
  for w in select distinct (x ->> 'e')::uuid e, (x ->> 'w')::date wk from jsonb_array_elements(v_weeks) x loop
    perform lms_ttl_reseq(w.e, w.wk);
  end loop;
  return jsonb_build_object('ok', n_ok, 'admin', n_admin, 'sent', n_sent, 'batch', v_batch,
    'left', (select count(*) from lms_ttl_rows(p_tutor, p_student) x where x.state is null or x.state in ('later', 'returned')));
end $$;

create or replace function tutor_ttl_submit(p_tutor uuid, p_student uuid, p_items jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  return lms_ttl_submit(lms_screen_tutor(p_tutor), p_student, p_items, 'tutor');
end $$;

create or replace function student_ttl_submit(p_student uuid, p_tutor uuid, p_items jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  return lms_ttl_submit(p_tutor, lms_screen_student(p_student), p_items, 'student');
end $$;

-- 학생 답: 강사가 보낸 시간에 동의(→ 확정 직전 검사 → 확정/운영진 확인) 또는 다시 조정
create or replace function student_ttl_answer(p_student uuid, p_tutor uuid, p_agree boolean)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_student uuid := lms_screen_student(p_student);
  r record;
  v_batch uuid := gen_random_uuid();
  st text;
  n_ok integer := 0;
  n_admin integer := 0;
  w record;
begin
  perform pg_advisory_xact_lock(hashtextextended('ttl:' || p_tutor, 0));
  if not exists (select 1 from temp_location_moves m where m.tutor_id = p_tutor and m.student_id = v_student and m.state = 'proposed') then
    raise exception '이미 답한 신청이에요. 창을 닫고 다시 열어 주세요.' using hint = 'ttl';
  end if;
  if p_agree and exists (select 1 from regular_change_requests q where q.student_id = v_student and q.status = 'pending') then
    raise exception '정규 시간 변경 신청이 처리된 뒤에 동의할 수 있어요.' using hint = 'ttl';
  end if;
  for r in select * from lms_ttl_rows(p_tutor, v_student) x where x.state = 'proposed' order by x.orig_starts_at loop
    if p_agree then
      st := lms_ttl_confirm_one(p_tutor, v_student, r.key, r.new_starts_at, v_batch, 'student');
      if st = 'confirmed' then n_ok := n_ok + 1; else n_admin := n_admin + 1; end if;
    else
      perform lms_ttl_save(to_jsonb(r), 'returned', null, null, v_batch, 'student', null);
    end if;
  end loop;
  -- 수업이 취소돼 대상에서 빠진 신청 줄은 그대로 두면 다시 막으므로 '나중에'로 돌림
  update temp_location_moves set state = 'later', new_starts_at = null where tutor_id = p_tutor and student_id = v_student and state = 'proposed';
  if p_agree then
    for w in select distinct m.enrollment_id e, lms_rc_monday((m.orig_starts_at at time zone 'Asia/Seoul')::date) wk
             from temp_location_moves m where m.batch_id = v_batch loop
      perform lms_ttl_reseq(w.e, w.wk);
    end loop;
  end if;
  return jsonb_build_object('ok', n_ok, 'admin', n_admin, 'agree', p_agree,
    'left', (select count(*) from lms_ttl_rows(p_tutor, v_student) x where x.state is null or x.state in ('later', 'returned')));
end $$;

-- 운영진: 확인할 회차 목록 · 시간 넣어 확정 · 다른 방법으로 처리함
create or replace function admin_ttl_rows()
returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not is_admin() then raise exception '운영자(추가 인증 완료)만 볼 수 있습니다.' using errcode = '42501'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id', m.id, 'student_id', m.student_id, 'student_code', s.code, 'student', s.name_ko,
                     'tutor', tu.name, 'orig', m.orig_starts_at, 'new', m.new_starts_at, 'minutes', m.minutes, 'conflict', m.conflict,
                     'city', loc.city) order by m.orig_starts_at)
                   from temp_location_moves m join students s on s.id = m.student_id join tutors tu on tu.id = m.tutor_id
                   join tutor_locations loc on loc.id = m.location_id
                   where m.state = 'admin'), '[]'::jsonb);
end $$;

create or replace function admin_ttl_resolve(p_move uuid, p_starts_at timestamptz)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  m temp_location_moves;
  r record;
  st text;
begin
  if not is_admin() then raise exception '운영자(추가 인증 완료)만 처리할 수 있습니다.' using errcode = '42501'; end if;
  select * into m from temp_location_moves where id = p_move;
  if not found or m.state <> 'admin' then raise exception '이미 처리된 회차입니다.'; end if;
  perform pg_advisory_xact_lock(hashtextextended('ttl:' || m.tutor_id, 0));
  if p_starts_at is null then
    update temp_location_moves set state = 'admin_done', by_kind = 'admin', decided_at = now() where id = m.id;
    return jsonb_build_object('state', 'admin_done');
  end if;
  select * into r from lms_ttl_rows(m.tutor_id, m.student_id) x where x.move_id = m.id;
  st := lms_ttl_confirm_one(m.tutor_id, m.student_id, r.key, p_starts_at, gen_random_uuid(), 'admin');
  if st <> 'confirmed' then
    raise exception '그 시간에는 넣을 수 없습니다 (%).', (select conflict from temp_location_moves where id = m.id);
  end if;
  perform lms_ttl_reseq(m.enrollment_id, lms_rc_monday((m.orig_starts_at at time zone 'Asia/Seoul')::date));
  return jsonb_build_object('state', st);
end $$;

revoke all on function lms_ttl_rows(uuid, uuid), lms_ttl_conflict(uuid, uuid, uuid, uuid, uuid, timestamptz, integer, timestamptz),
  lms_ttl_cands(uuid, uuid, uuid, uuid, uuid, timestamptz, integer), lms_ttl_items(uuid, uuid), lms_ttl_options(uuid, uuid),
  lms_ttl_reseq(uuid, date), lms_ttl_submit(uuid, uuid, jsonb, text),
  lms_ttl_save(jsonb, text, timestamptz, text, uuid, text, uuid), lms_ttl_confirm_one(uuid, uuid, text, timestamptz, uuid, text) from public, anon, authenticated;
grant execute on function tutor_ttl_items(uuid), student_ttl_items(uuid), tutor_ttl_options(uuid, uuid), student_ttl_options(uuid, uuid),
  tutor_ttl_submit(uuid, uuid, jsonb), student_ttl_submit(uuid, uuid, jsonb), student_ttl_answer(uuid, uuid, boolean),
  admin_ttl_rows(), admin_ttl_resolve(uuid, timestamptz) to authenticated;
