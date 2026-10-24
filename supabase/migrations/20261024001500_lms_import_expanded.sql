-- =====================================================================
-- 기존 학생 입력 확대 (D-52 확대판, 정책 원본 H26 · 2026-10-24 대표 결정 6가지)
--  기존 화면(migration 1300)·충돌 검사(1400)는 그대로 쓰고, 넣는 내용만 늘림
--  1. 남은 수업 = 아직 진행·차감되지 않은 수업 전부 = 정규 + 예약된 보강 + 미예약 보강 + 추가 수업
--     · 시트에는 남은 수가 따로 없음 → '시트 총 수업 수 − 이미 진행·차감된 수(Class Status 기준, 회차 번호 아님)'와 비교
--     · 한 수업을 정규·보강으로 두 번 세지 않음: 보강의 원래 수업 날짜가 시작일 이후면 그날 정규 수업을 만들지 않음
--  2. 숫자가 달라도 저장. 시트 대조 전·원래 날짜 확인 필요는 대시보드 '처리할 일'에 남고, 확인하면 사라짐
--  3. [+ 수업 날짜 추가](근거 필수, 그날 하나만) · [+ 미예약 보강](원래 수업 날짜 또는 '날짜 확인 필요') 구분
--  4. 보강의 원래 수업 날짜는 원칙적으로 필수. 시트에서 알 수 없으면 가짜 날짜 대신 '날짜 확인 필요'
--  5. 시트 대조 결과는 확인 시각·담당자로 기록 (import_checks) — 한 번 확인한 학생은 다시 묻지 않음
--  6. LMS 전환일(students.lms_since)은 비워 둠 = 시트로 관리. 학생 상세에서 나중에 정함 (입력일 ≠ 전환일, H26(7))
--  + 지금 28일 수강기간·그 기간 남은 변경권 (기존 정책: 기간마다 주1회 1·주2회 2·주3회 이상 3, 이월 없음)
-- 권한: 운영자(TOTP)만. 기존 표·데이터를 지우지 않음. 다시 실행해도 같은 결과
-- =====================================================================

-- 수업 종류에 '이관 추가 수업' 추가 (제약 교체 — 데이터는 그대로)
do $$
begin
  if exists (select 1 from pg_constraint where conname = 'lessons_kind_check'
             and pg_get_constraintdef(oid) not like '%migrated_extra%') then
    alter table lessons drop constraint lessons_kind_check;
  end if;
  if not exists (select 1 from pg_constraint where conname = 'lessons_kind_check') then
    alter table lessons add constraint lessons_kind_check
      check (kind in ('regular', 'makeup', 'compensation', 'carryover', 'migrated_makeup', 'migrated_extra'));
  end if;
end $$;

-- LMS 전환일: 이날부터 이 학생의 수업기록·변경권·보강은 LMS만. 비어 있으면 시트로 관리 (학생 상세에서 정함)
alter table students add column if not exists lms_since date;

-- 이관한 보강·추가 수업 (원래 수업은 시트에 있어 lessons.makeup_of 로 연결할 수 없음)
create table if not exists migrated_items (
  id uuid primary key default gen_random_uuid(),
  enrollment_id uuid not null references enrollments(id),
  kind text not null check (kind in ('makeup_booked', 'makeup_open', 'extra')),
  lesson_id uuid unique references lessons(id),     -- 예약된 보강·추가 수업의 그날 수업 (미예약 보강은 없음)
  original_date date,                               -- 보강의 원래 수업 날짜 (한국 날짜)
  origin_unknown boolean not null default false,    -- 시트에서 원래 날짜를 알 수 없음 → '날짜 확인 필요' (가짜 날짜 금지)
  origin_checked_at timestamptz,                    -- 나중에 날짜를 넣었거나 '확인 불가'로 정리한 시각
  origin_checked_by uuid,
  reason text,                                      -- 추가 수업의 근거 (예: 시트 18회차 · 이월 1회)
  created_by uuid,
  created_at timestamptz not null default now(),
  check ((kind = 'makeup_open') = (lesson_id is null)),
  check (kind = 'extra' or ((original_date is not null) <> origin_unknown)),
  check (kind <> 'extra' or (coalesce(trim(reason), '') <> '' and original_date is null and not origin_unknown)),
  check (not origin_unknown or origin_checked_at is null or origin_checked_by is not null)
);
create index if not exists migrated_items_enrollment on migrated_items (enrollment_id);
-- 같은 원래 수업으로 보강 두 개 금지 (한 수업 = 보강 하나)
create unique index if not exists migrated_items_one_makeup_per_origin on migrated_items (enrollment_id, original_date)
  where original_date is not null;

-- 시트 대조 기록 (입력 때 숫자 + 운영진 확인 시각·담당자)
create table if not exists import_checks (
  id uuid primary key default gen_random_uuid(),
  enrollment_id uuid not null unique references enrollments(id),
  sheet_total integer not null check (sheet_total >= 0),                         -- 시트의 등록 총 수업 수
  sheet_used integer not null check (sheet_used >= 0 and sheet_used <= sheet_total),  -- 시트에서 이미 진행·차감된 수
  lms_left integer not null check (lms_left >= 0),                               -- 저장 때 LMS 남은 수업 (정규+보강+미예약+추가)
  checked_at timestamptz,
  checked_by uuid,
  created_by uuid,
  created_at timestamptz not null default now(),
  check ((checked_at is null) = (checked_by is null))
);

do $$
declare t text;
begin
  foreach t in array array['migrated_items', 'import_checks'] loop
    if not exists (select 1 from pg_trigger where tgname = t || '_audit') then
      perform lms_protect(t::regclass);   -- 변경 이력 + RLS(운영자만 읽기) + 앱 사용자 쓰기 금지
      execute format('create trigger %I before delete on %I for each row execute function forbid_delete()', t || '_no_delete', t);
    end if;
  end loop;
end $$;

-- 입력 → 수업 후보 (출력 모양은 1300과 같음). 저장하지 않고 목록만
--  · 정규: 시작일~종료일, 보강의 원래 날짜(시작일 이후)·운영진이 뺀 날짜(skip_dates)는 만들지 않음
--  · 예약된 보강(status booked) → migrated_makeup, 수업 날짜 추가 → migrated_extra (정규 강사·길이)
create or replace function lms_import_candidates(p jsonb)
returns table (n int, kind text, tutor_id uuid, starts_at timestamptz, ends_at timestamptz, kst_date date, kst_time text)
language sql stable security definer set search_path = public as $$
  with slots as (
    select (x ->> 'weekday')::int as wd, (x ->> 'time')::time as t from jsonb_array_elements(coalesce(p -> 'slots', '[]'::jsonb)) x
  ), skip as (
    select (m ->> 'original_date')::date as d from jsonb_array_elements(coalesce(p -> 'makeups', '[]'::jsonb)) m
    where nullif(m ->> 'original_date', '') is not null
    union
    select x::date from jsonb_array_elements_text(coalesce(p -> 'skip_dates', '[]'::jsonb)) x
  ), reg as (
    select d::date as dd, s.t
    from generate_series((p ->> 'from_date')::date, (p ->> 'end_date')::date, interval '1 day') d
    join slots s on extract(dow from d)::int = s.wd
    where d::date not in (select d from skip where d is not null)
  ), c as (
    select 'regular'::text as kind, (p ->> 'tutor_id')::uuid as tutor_id, (dd + t) at time zone 'Asia/Seoul' as s0,
           ((p ->> 'duration_min')::int) as dur, dd, t
    from reg
    union all
    select 'migrated_makeup', (m ->> 'tutor_id')::uuid, ((m ->> 'date')::date + (m ->> 'time')::time) at time zone 'Asia/Seoul',
           (m ->> 'duration_min')::int, (m ->> 'date')::date, (m ->> 'time')::time
    from jsonb_array_elements(coalesce(p -> 'makeups', '[]'::jsonb)) m
    where coalesce(m ->> 'status', 'booked') = 'booked'
    union all
    select 'migrated_extra', (p ->> 'tutor_id')::uuid, ((x ->> 'date')::date + (x ->> 'time')::time) at time zone 'Asia/Seoul',
           (p ->> 'duration_min')::int, (x ->> 'date')::date, (x ->> 'time')::time
    from jsonb_array_elements(coalesce(p -> 'extras', '[]'::jsonb)) x
  )
  select (row_number() over (order by s0, kind))::int, kind, tutor_id, s0, s0 + make_interval(mins => dur), dd, to_char(t, 'HH24:MI')
  from c
$$;
revoke all on function lms_import_candidates(jsonb) from public, anon, authenticated;

-- 화면에서 부르는 함수 (운영자 TOTP 세션만). 1300의 입력에 더해:
-- p.course = {weeks, period_idx, period_start, credits_left}   지금 28일 기간·그 기간 남은 변경권
-- p.sheet = {total, used}                                       시트 총 수업 수·이미 진행·차감된 수
-- p.makeups[] = {status: booked|open, original_date | origin_unknown, date, time, duration_min, tutor_id (booked만)}
-- p.extras[] = {date, time, reason}                             수업 날짜 추가 (근거 필수)
-- p.skip_dates[] = 정규에서 뺄 날짜 (시트보다 많을 때 운영진이 고름)
create or replace function admin_import_existing_student(p_request_id uuid, p jsonb)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  prev jsonb;
  st jsonb := p -> 'student';
  co jsonb := p -> 'course';
  sh jsonb := p -> 'sheet';
  v_tutor uuid := nullif(p ->> 'tutor_id', '')::uuid;
  v_dur int := (p ->> 'duration_min')::int;
  v_from date := (p ->> 'from_date')::date;
  v_end date := (p ->> 'end_date')::date;
  v_slots jsonb := coalesce(p -> 'slots', '[]'::jsonb);
  v_makeups jsonb := coalesce(p -> 'makeups', '[]'::jsonb);
  v_extras jsonb := coalesce(p -> 'extras', '[]'::jsonb);
  v_weeks int := (co ->> 'weeks')::int;
  v_pidx int := (co ->> 'period_idx')::int;
  v_pstart date := (co ->> 'period_start')::date;
  v_cleft int := (co ->> 'credits_left')::int;
  v_total int := (sh ->> 'total')::int;
  v_used int := (sh ->> 'used')::int;
  v_grant int;
  m jsonb;
  s jsonb;
  conflicts jsonb;
  n_reg int;
  n_mk int;
  n_open int;
  n_ex int;
  sid uuid;
  scode text;
  eid uuid;
  pid uuid;
  lid uuid;
  r record;
  i int;
  seqn int := 0;
  res jsonb;
begin
  if not is_admin() then raise exception '운영자(추가 인증 완료)만 학생을 입력할 수 있습니다.' using errcode = '42501'; end if;
  if p_request_id is null then raise exception '요청 번호가 없습니다.'; end if;
  perform pg_advisory_xact_lock(hashtextextended(p_request_id::text, 0));
  select result into prev from registration_requests where id = p_request_id;
  if found then return prev || '{"repeated": true}'::jsonb; end if;

  -- 입력 확인
  if coalesce(trim(st ->> 'name_ko'), '') = '' or coalesce(trim(st ->> 'name_en'), '') = '' then raise exception '이름(한글·영문)을 넣어 주세요.'; end if;
  if v_tutor is null or not exists (select 1 from tutors where id = v_tutor and active) then raise exception '담당 강사를 골라 주세요.'; end if;
  if v_dur is null or v_dur not in (20, 40, 50) then raise exception '수업 길이는 20·40·50분만 가능합니다.'; end if;
  if v_from is null or v_end is null or v_end < v_from then raise exception '수강 종료일이 시작일보다 빠릅니다.'; end if;
  if jsonb_array_length(v_slots) not in (1, 2, 3, 5) then raise exception '주 수업 횟수는 1·2·3·5회만 가능합니다 (지금 %회).', jsonb_array_length(v_slots); end if;
  if (select count(distinct (x ->> 'weekday')::int) from jsonb_array_elements(v_slots) x) <> jsonb_array_length(v_slots) then
    raise exception '같은 요일에 정규 수업을 2개 넣을 수 없습니다.';
  end if;
  v_grant := least(jsonb_array_length(v_slots), 3);   -- 기간마다 변경권: 주1회 1·주2회 2·주3회 이상 3 (POL-CHG-03, credits.ts)

  if v_weeks is null or v_weeks not in (4, 12, 24) then raise exception '상품(1·3·6개월)을 골라 주세요.'; end if;
  if v_pidx is null or v_pidx < 1 or v_pidx > v_weeks / 4 then raise exception '지금 몇 번째 기간인지 골라 주세요.'; end if;
  if v_pstart is null then raise exception '지금 기간의 시작일을 넣어 주세요.'; end if;
  if v_cleft is null or v_cleft < 0 or v_cleft > v_grant then raise exception '이 기간 남은 변경권은 0~%개입니다.', v_grant; end if;
  if v_total is null or v_used is null or v_total < 0 or v_used < 0 or v_used > v_total then
    raise exception '시트의 총 수업 수와 진행·차감된 수를 확인해 주세요.';
  end if;

  for m in select * from jsonb_array_elements(v_makeups) loop
    if coalesce(m ->> 'status', '') not in ('booked', 'open') then raise exception '보강이 예약됨인지 미예약인지 골라 주세요.'; end if;
    if (nullif(m ->> 'original_date', '') is null) = not coalesce((m ->> 'origin_unknown')::boolean, false) then
      raise exception '보강의 원래 수업 날짜를 넣거나 ''날짜 확인 필요''를 골라 주세요.';
    end if;
    if m ->> 'status' = 'booked' then
      if (m ->> 'date')::date < v_from then raise exception '보강 날짜(%)가 시작일(%)보다 빠릅니다. 지난 보강은 넣지 않아요.', m ->> 'date', v_from; end if;
      if (m ->> 'duration_min')::int not in (20, 40, 50) then raise exception '보강 수업 길이는 20·40·50분만 가능합니다.'; end if;
      if not exists (select 1 from tutors where id = (m ->> 'tutor_id')::uuid and active) then raise exception '보강 강사를 골라 주세요.'; end if;
    end if;
  end loop;
  if (select count(*) - count(distinct y ->> 'original_date') from jsonb_array_elements(v_makeups) y where nullif(y ->> 'original_date', '') is not null) > 0 then
    raise exception '같은 원래 수업 날짜의 보강이 두 개 있어요. 한 수업에는 보강 하나입니다.';
  end if;
  for m in select * from jsonb_array_elements(v_extras) loop
    if coalesce(trim(m ->> 'reason'), '') = '' then raise exception '추가 수업의 근거를 적어 주세요 (예: 시트 몇 회차).'; end if;
    if (m ->> 'date')::date < v_from then raise exception '추가 수업 날짜(%)가 시작일보다 빠릅니다.', m ->> 'date'; end if;
  end loop;

  select count(*) filter (where kind = 'regular'), count(*) filter (where kind = 'migrated_makeup'), count(*) filter (where kind = 'migrated_extra')
    into n_reg, n_mk, n_ex
  from lms_import_candidates(p);
  n_open := (select count(*) from jsonb_array_elements(v_makeups) y where y ->> 'status' = 'open');
  if n_reg = 0 then raise exception '시작일~종료일 사이에 정규 수업이 없습니다. 날짜·요일을 확인해 주세요.'; end if;

  conflicts := lms_import_conflicts(p);
  if jsonb_array_length(conflicts) > 0 then
    raise exception '일정 충돌 %건 — 저장하지 않았습니다.', jsonb_array_length(conflicts)
      using errcode = 'P0001', detail = conflicts::text, hint = 'schedule_conflict';
  end if;

  perform set_config('app.actor_id', me::text, true);
  perform set_config('app.actor_via', 'admin_import_existing_student', true);

  insert into students (name_ko, name_en, email, phone, country, city, timezone, admin_memo)
  values (trim(st ->> 'name_ko'), trim(st ->> 'name_en'), nullif(lower(trim(st ->> 'email')), ''), nullif(st ->> 'phone', ''),
          nullif(st ->> 'country', ''), nullif(st ->> 'city', ''), st ->> 'timezone', nullif(st ->> 'admin_memo', ''))
  returning id, code into sid, scode;   -- lms_since 비움 = 시트로 관리

  -- 옛 상품 형태(legacy_label): 지금 등록의 남은 기간. 총 수업 수는 시트 숫자, 결제는 시트
  insert into enrollments (student_id, seq, legacy_label, weekly_count, duration_min, start_date, base_end_date,
                           lessons_purchased, status, created_by)
  values (sid, 1, format('기존 학생 이관 · %s주 (결제는 시트)', v_weeks), jsonb_array_length(v_slots), v_dur, v_from, v_end,
          greatest(v_total, 1), 'active', me)
  returning id into eid;

  -- 지금 기간 ~ 마지막 기간 (28일씩). 지금 기간은 남은 변경권만큼 남기고, 다음 기간부터 새로 지급
  for i in v_pidx .. v_weeks / 4 loop
    insert into enrollment_periods (enrollment_id, idx, start_date, end_date, credits_granted)
    values (eid, i, v_pstart + (i - v_pidx) * 28, v_pstart + (i - v_pidx) * 28 + 27, v_grant)
    returning id into pid;
    if i = v_pidx then
      for seqn in 1 .. v_grant - v_cleft loop
        insert into credit_ledger (period_id, reason, delta, note, created_by)
        values (pid, 'admin_adjust', -1, '기존 학생 이관: 시트에서 이미 사용한 변경권', me);
      end loop;
    end if;
  end loop;
  seqn := 0;

  for s in select * from jsonb_array_elements(v_slots) loop
    insert into regular_schedules (student_id, tutor_id, weekday, start_time_kst, duration_min, effective_from, change_reason)
    values (sid, v_tutor, (s ->> 'weekday')::smallint, (s ->> 'time')::time, v_dur, v_from, '기존 학생 이관 (D-52)');
  end loop;

  for r in select * from lms_import_candidates(p) order by starts_at loop
    if r.kind = 'regular' then seqn := seqn + 1; end if;
    insert into lessons (enrollment_id, student_id, tutor_id, kind, seq, starts_at, ends_at, created_by)
    values (eid, sid, r.tutor_id, r.kind, case when r.kind = 'regular' then seqn end, r.starts_at, r.ends_at, me)
    returning id into lid;
    if r.kind = 'migrated_makeup' then
      select x into m from jsonb_array_elements(v_makeups) x
      where x ->> 'status' = 'booked' and (x ->> 'date')::date = r.kst_date and to_char((x ->> 'time')::time, 'HH24:MI') = r.kst_time limit 1;
      insert into migrated_items (enrollment_id, kind, lesson_id, original_date, origin_unknown, created_by)
      values (eid, 'makeup_booked', lid, nullif(m ->> 'original_date', '')::date, coalesce((m ->> 'origin_unknown')::boolean, false), me);
    elsif r.kind = 'migrated_extra' then
      select x into m from jsonb_array_elements(v_extras) x
      where (x ->> 'date')::date = r.kst_date and to_char((x ->> 'time')::time, 'HH24:MI') = r.kst_time limit 1;
      insert into migrated_items (enrollment_id, kind, lesson_id, reason, created_by) values (eid, 'extra', lid, trim(m ->> 'reason'), me);
    end if;
  end loop;
  for m in select * from jsonb_array_elements(v_makeups) x where x ->> 'status' = 'open' loop
    insert into migrated_items (enrollment_id, kind, original_date, origin_unknown, created_by)
    values (eid, 'makeup_open', nullif(m ->> 'original_date', '')::date, coalesce((m ->> 'origin_unknown')::boolean, false), me);
  end loop;

  insert into import_checks (enrollment_id, sheet_total, sheet_used, lms_left, created_by)
  values (eid, v_total, v_used, n_reg + n_mk + n_open + n_ex, me);

  res := jsonb_build_object('student_id', sid, 'student_code', scode, 'enrollment_id', eid, 'lessons', n_reg, 'makeups', n_mk,
                            'open_makeups', n_open, 'extras', n_ex, 'lms_left', n_reg + n_mk + n_open + n_ex,
                            'sheet_left', v_total - v_used, 'start_date', v_from, 'end_date', v_end);
  insert into registration_requests (id, created_by, student_id, enrollment_id, result)
  values (p_request_id, me, sid, eid, res);
  return res;
end $$;
revoke all on function admin_import_existing_student(uuid, jsonb) from public, anon;
grant execute on function admin_import_existing_student(uuid, jsonb) to authenticated;

-- 시트와 대조 완료: 확인 시각·담당자 기록 → 처리할 일에서 빠짐. 이미 완료면 그대로 (다시 묻지 않음)
create or replace function admin_import_mark_checked(p_enrollment uuid)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  c import_checks;
begin
  if not is_admin() then raise exception '운영자(추가 인증 완료)만 기록할 수 있습니다.' using errcode = '42501'; end if;
  select * into c from import_checks where enrollment_id = p_enrollment for update;
  if not found then raise exception '이관 기록이 없는 수강등록입니다.'; end if;
  if c.checked_at is null then
    perform set_config('app.actor_id', me::text, true);
    perform set_config('app.actor_via', 'admin_import_mark_checked', true);
    update import_checks set checked_at = now(), checked_by = me where enrollment_id = p_enrollment returning * into c;
  end if;
  return jsonb_build_object('checked_at', c.checked_at, 'checked_by', c.checked_by);
end $$;
revoke all on function admin_import_mark_checked(uuid) from public, anon;
grant execute on function admin_import_mark_checked(uuid) to authenticated;

-- 보강의 원래 수업 날짜 '확인 필요' 정리: 날짜를 찾았으면 넣고(입력 시작일 전 날짜만 — 그 뒤 날짜는 정규 수업이 이미 있어
-- 두 번 세게 됨), 시트에서도 끝내 알 수 없으면 p_date 없이 '확인 불가'로 정리 (가짜 날짜 금지)
create or replace function admin_import_set_origin(p_item uuid, p_date date)
returns void
language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  it migrated_items;
  v_from date;
begin
  if not is_admin() then raise exception '운영자(추가 인증 완료)만 기록할 수 있습니다.' using errcode = '42501'; end if;
  select * into it from migrated_items where id = p_item for update;
  if not found or it.kind = 'extra' then raise exception '보강 기록이 아닙니다.'; end if;
  if not it.origin_unknown then raise exception '이미 원래 날짜가 있는 보강입니다.'; end if;
  select start_date into v_from from enrollments where id = it.enrollment_id;
  if p_date is not null and p_date >= v_from then
    raise exception '원래 날짜는 입력 시작일(%) 전이어야 합니다. 그 뒤 날짜는 정규 수업이 이미 있어요.', v_from;
  end if;
  perform set_config('app.actor_id', me::text, true);
  perform set_config('app.actor_via', 'admin_import_set_origin', true);
  if p_date is not null then
    update migrated_items set original_date = p_date, origin_unknown = false, origin_checked_at = now(), origin_checked_by = me where id = p_item;
  else
    update migrated_items set origin_checked_at = now(), origin_checked_by = me where id = p_item;
  end if;
end $$;
revoke all on function admin_import_set_origin(uuid, date) from public, anon;
grant execute on function admin_import_set_origin(uuid, date) to authenticated;
