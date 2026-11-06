-- =====================================================================
-- 기존 학생 입력 시안 2 (D-52, 2026-10-26 대표 승인 · 강사 휴가 처리 원칙 A41 ④)
--  1500(기존 학생 입력 확대) 위에 고침. 함수 교체 + import_checks 칸 2개 추가. 기존 데이터는 바꾸지 않음
--  1. 정규 수업은 28일 기간 계산 끝까지만 만든다. 종료일이 그보다 늦어도(연장) 늘어난 날에는 정규 수업을 만들지 않는다
--     (연장 = 새 정규 수업 추가가 아니라 미완료 수업을 끝낼 수 있는 기간 확대. 늘어난 날에는 보강·추가 수업만)
--  2. 늘어난 날은 연장 기록(enrollment_extensions)으로 남김: base_end = 계산 끝, final_end = 시트 종료일
--     이유: 강사 장기 휴무 연장 / 학생 장기 연기(24주만) / 기타(메모). 안 고르면 저장은 하되 '종료일 이유 확인'으로 처리할 일에 남김
--     (2026-10-26 대표: 기록만 남기고 끝내지 않음) → 운영진이 이유를 고르면(admin_import_set_end_reason) 사라짐
--  3. 수강 시작일(1기간 시작)부터 모든 28일 기간을 기록 (지난 기간 포함). 지금 기간의 남은 변경권만 시트 값으로
--  4. 보강·추가 수업 날짜는 수강 종료일(연장 포함)까지만
--  5. 원래 날짜 정리(admin_import_set_origin)의 기준 '입력 시작일' = LMS가 만든 첫 수업 날 (start_date 가 수강 시작일로 바뀌어서)
-- 다시 실행해도 같은 결과
-- =====================================================================

alter table import_checks add column if not exists end_reason text;   -- 종료일이 계산과 다를 때 이유 (enrollment_extensions.reason 과 같은 값)
alter table import_checks add column if not exists end_note text;
alter table import_checks add column if not exists end_days integer not null default 0;     -- 종료일 − 기간 계산 끝 (0 = 같음)
alter table import_checks add column if not exists weeks integer;                            -- 상품 (학생 장기 연기는 24주만 확인용)
alter table import_checks add column if not exists end_checked_at timestamptz;               -- 종료일 이유를 정한 시각·담당자
alter table import_checks add column if not exists end_checked_by uuid;
-- 강사 휴가로 생긴 보강 (A41): 수강 종료일이 지나도 보강 권리가 사라지지 않고, 보강을 종료일 뒤로 잡으면 연장으로 처리
alter table migrated_items add column if not exists tutor_leave boolean not null default false;

-- 정규 수업 마지막 날 = 종료일과 28일 기간 계산 끝 중 빠른 날 (course 가 없으면 종료일)
create or replace function lms_import_regular_end(p jsonb)
returns date
language sql immutable as $$
  select case when p -> 'course' ->> 'period_start' is null then (p ->> 'end_date')::date
              else least((p ->> 'end_date')::date,
                         (p -> 'course' ->> 'period_start')::date
                           + ((p -> 'course' ->> 'weeks')::int / 4 - (p -> 'course' ->> 'period_idx')::int + 1) * 28 - 1) end
$$;
revoke all on function lms_import_regular_end(jsonb) from public, anon, authenticated;

-- 입력 → 수업 후보: 정규는 위 마지막 날까지
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
    from generate_series((p ->> 'from_date')::date, lms_import_regular_end(p), interval '1 day') d
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

-- 저장 함수 (1500과 같고 위 1~4만 다름)
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
  v_cstart date;     -- 수강 시작일 (1기간 시작)
  v_calc_end date;   -- 28일 기간 계산 끝 = 정규 수업 마지막 날 상한
  v_reason text := nullif(p -> 'extension' ->> 'reason', '');
  v_note text := nullif(trim(p -> 'extension' ->> 'note'), '');
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
  v_cstart := v_pstart - (v_pidx - 1) * 28;
  v_calc_end := v_pstart + (v_weeks / 4 - v_pidx + 1) * 28 - 1;
  -- 종료일이 계산과 다르면 이유를 기록 (막지 않음). 이유를 안 골랐으면 v_reason 은 비운 채 저장 → 처리할 일 '종료일 이유 확인'
  if v_end <> v_calc_end then
    if v_reason is not null and v_reason not in ('tutor_long_term_leave', 'student_long_term_leave', 'admin_exception') then
      raise exception '종료일 변경 사유가 올바르지 않습니다.';
    end if;
    if v_reason = 'student_long_term_leave' and v_weeks <> 24 then raise exception '학생 장기 연기는 24주 상품만 가능합니다 (A09).'; end if;
    if v_reason = 'admin_exception' then v_note := coalesce(v_note, '기타'); end if;
  else
    v_reason := null; v_note := null;
  end if;
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
      if (m ->> 'date')::date > v_end then raise exception '보강 날짜(%)가 수강 종료일(%) 뒤예요. 종료일(연장)을 먼저 맞춰 주세요.', m ->> 'date', v_end; end if;
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
    if (m ->> 'date')::date > v_end then raise exception '추가 수업 날짜(%)가 수강 종료일(%) 뒤예요.', m ->> 'date', v_end; end if;
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

  -- 옛 상품 형태(legacy_label): 수강 시작일~계산 끝(base), 늘어난 날은 연장 기록으로 (final = base + 연장). 결제는 시트
  insert into enrollments (student_id, seq, legacy_label, weekly_count, duration_min, start_date, base_end_date,
                           lessons_purchased, status, created_by)
  values (sid, 1, format('기존 학생 이관 · %s주 (결제는 시트)', v_weeks), jsonb_array_length(v_slots), v_dur, v_cstart, least(v_end, v_calc_end),
          greatest(v_total, 1), 'active', me)
  returning id into eid;
  if v_end > v_calc_end then
    insert into enrollment_extensions (enrollment_id, days, reason, note, approved_by)
    values (eid, v_end - v_calc_end, coalesce(v_reason, 'admin_exception'),
            case when v_reason is null then '이유 확인 필요 (기존 학생 이관)' else coalesce(v_note, '기존 학생 이관 (시트 종료일)') end, me);
  end if;

  -- 1기간 ~ 마지막 기간 (28일씩, 지난 기간은 기록용). 지금 기간은 남은 변경권만큼 남기고, 다음 기간부터 새로 지급
  for i in 1 .. v_weeks / 4 loop
    insert into enrollment_periods (enrollment_id, idx, start_date, end_date, credits_granted)
    values (eid, i, v_cstart + (i - 1) * 28, v_cstart + (i - 1) * 28 + 27, v_grant)
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
      insert into migrated_items (enrollment_id, kind, lesson_id, original_date, origin_unknown, tutor_leave, created_by)
      values (eid, 'makeup_booked', lid, nullif(m ->> 'original_date', '')::date, coalesce((m ->> 'origin_unknown')::boolean, false),
              coalesce((m ->> 'tutor_leave')::boolean, false), me);
    elsif r.kind = 'migrated_extra' then
      select x into m from jsonb_array_elements(v_extras) x
      where (x ->> 'date')::date = r.kst_date and to_char((x ->> 'time')::time, 'HH24:MI') = r.kst_time limit 1;
      insert into migrated_items (enrollment_id, kind, lesson_id, reason, created_by) values (eid, 'extra', lid, trim(m ->> 'reason'), me);
    end if;
  end loop;
  for m in select * from jsonb_array_elements(v_makeups) x where x ->> 'status' = 'open' loop
    insert into migrated_items (enrollment_id, kind, original_date, origin_unknown, tutor_leave, created_by)
    values (eid, 'makeup_open', nullif(m ->> 'original_date', '')::date, coalesce((m ->> 'origin_unknown')::boolean, false),
            coalesce((m ->> 'tutor_leave')::boolean, false), me);
  end loop;

  insert into import_checks (enrollment_id, sheet_total, sheet_used, lms_left, end_reason, end_note, end_days, weeks,
                             end_checked_at, end_checked_by, created_by)
  values (eid, v_total, v_used, n_reg + n_mk + n_open + n_ex, v_reason, v_note, v_end - v_calc_end, v_weeks,
          case when v_reason is not null then now() end, case when v_reason is not null then me end, me);

  res := jsonb_build_object('student_id', sid, 'student_code', scode, 'enrollment_id', eid, 'lessons', n_reg, 'makeups', n_mk,
                            'open_makeups', n_open, 'extras', n_ex, 'lms_left', n_reg + n_mk + n_open + n_ex,
                            'sheet_left', v_total - v_used, 'start_date', v_from, 'end_date', v_end,
                            'course_start', v_cstart, 'regular_end', least(v_end, v_calc_end),
                            'end_reason_missing', v_end <> v_calc_end and v_reason is null);
  insert into registration_requests (id, created_by, student_id, enrollment_id, result)
  values (p_request_id, me, sid, eid, res);
  return res;
end $$;
revoke all on function admin_import_existing_student(uuid, jsonb) from public, anon;
grant execute on function admin_import_existing_student(uuid, jsonb) to authenticated;

-- 원래 날짜 정리 (5)
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
  -- 입력 시작일 = 이 등록에서 LMS가 만든 첫 수업 날 (1600부터 enrollments.start_date 는 수강 시작일이라 따로 구함)
  select coalesce(min(kst_date), (select start_date from enrollments where id = it.enrollment_id)) into v_from from lessons where enrollment_id = it.enrollment_id;
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

-- 종료일 이유 확인 (처리할 일 '종료일 이유 확인'에서): 이유를 정하면 그 항목이 사라짐. 이미 정했으면 다시 바꿀 수 있음
-- 연장 기록은 고치지 않고 정정 2줄(빼기 → 새 이유로 더하기)을 남겨 이력 보존. 일수는 그대로
create or replace function admin_import_set_end_reason(p_enrollment uuid, p_reason text, p_note text)
returns void
language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  c import_checks;
  v_note text := nullif(trim(p_note), '');
begin
  if not is_admin() then raise exception '운영자(추가 인증 완료)만 기록할 수 있습니다.' using errcode = '42501'; end if;
  select * into c from import_checks where enrollment_id = p_enrollment for update;
  if not found then raise exception '이관 기록이 없는 수강등록입니다.'; end if;
  if c.end_days = 0 then raise exception '종료일이 기간 계산과 같아서 이유가 필요 없습니다.'; end if;
  if p_reason not in ('tutor_long_term_leave', 'student_long_term_leave', 'admin_exception') then raise exception '종료일 변경 사유가 올바르지 않습니다.'; end if;
  if p_reason = 'student_long_term_leave' and c.weeks <> 24 then raise exception '학생 장기 연기는 24주 상품만 가능합니다 (A09).'; end if;
  if p_reason = 'admin_exception' and v_note is null then raise exception '기타는 메모를 적어 주세요.'; end if;
  perform set_config('app.actor_id', me::text, true);
  perform set_config('app.actor_via', 'admin_import_set_end_reason', true);
  if c.end_days > 0 then
    insert into enrollment_extensions (enrollment_id, days, reason, note, approved_by)
    values (p_enrollment, -c.end_days, 'correction', '종료일 이유 확인: 이전 기록 정정', me),
           (p_enrollment, c.end_days, p_reason, coalesce(v_note, '기존 학생 이관 (시트 종료일)'), me);
  end if;
  update import_checks set end_reason = p_reason, end_note = v_note, end_checked_at = now(), end_checked_by = me
  where enrollment_id = p_enrollment;
end $$;
revoke all on function admin_import_set_end_reason(uuid, text, text) from public, anon;
grant execute on function admin_import_set_end_reason(uuid, text, text) to authenticated;
