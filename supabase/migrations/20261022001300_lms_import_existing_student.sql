-- =====================================================================
-- 기존 학생 간단 입력 (D-52, 정책 원본 H23(3), 2026-10-22 대표 승인)
--  - 지금 수업 중인 학생의 고정 시간표만: 이름·강사·요일·시각·수업 길이·지금 수강 종료일 → 시작일(기본 오늘)~종료일 정규 수업
--  - 지난 수업 기록·변경권·보강 권리·결제는 옮기지 않음 (종료 때까지 시트, 재등록 때 정식 등록)
--  - 확정된 미래 보강: 날짜·시각·수업 길이·담당 강사 → 그날 하나만 있는 수업(kind = 'migrated_makeup')
--    · 원래 수업이 시트에 있어 makeup_of 를 채울 수 없으므로 일반 보강(makeup)과 구분
--    · 정규 시간표(regular_schedules)에 넣지 않음 → 그 요일·시각의 정규 수업 가능 시간을 매주 막지 않고 그날만 막음
--  - 충돌 검사 (저장 전, 하나라도 있으면 아무것도 저장 안 함): 정규·보강 각각
--    · 같은 강사의 다른 수업과 겹침 / 앞뒤 휴식 10분 부족 (A38, POL-OP-21)
--    · 강사 휴무·막은 시간 (tutor_time_off)
--    · 이번 입력끼리 (정규와 보강이 겹침 등)
--  - 결제 기록이 없으므로 신규 매칭 업무·안내는 만들지 않음 (이미 수업 중인 학생)
--  - 강사 가능 시간·A37(수업 시작 시각) 밖이어도 막지 않음: 이미 하고 있는 실제 시간표를 옮기는 것이므로
-- 권한: 운영자(TOTP)만. 같은 요청 번호로 두 번 저장해도 1번만 (registration_requests 재사용)
-- 기존 표·데이터를 지우지 않음. 다시 실행해도 같은 결과
-- =====================================================================

-- 수업 종류에 '이관 보강' 추가 (제약 교체 — 데이터는 그대로)
do $$
begin
  if exists (select 1 from pg_constraint where conname = 'lessons_kind_check'
             and pg_get_constraintdef(oid) not like '%migrated_makeup%') then
    alter table lessons drop constraint lessons_kind_check;
  end if;
  if not exists (select 1 from pg_constraint where conname = 'lessons_kind_check') then
    alter table lessons add constraint lessons_kind_check
      check (kind in ('regular', 'makeup', 'compensation', 'carryover', 'migrated_makeup'));
  end if;
end $$;

-- 입력 → 수업 후보 (정규 + 보강). 저장하지 않고 목록만
create or replace function lms_import_candidates(p jsonb)
returns table (n int, kind text, tutor_id uuid, starts_at timestamptz, ends_at timestamptz, kst_date date, kst_time text)
language sql stable security definer set search_path = public as $$
  with slots as (
    select (x ->> 'weekday')::int as wd, (x ->> 'time')::time as t from jsonb_array_elements(coalesce(p -> 'slots', '[]'::jsonb)) x
  ), reg as (
    select d::date as dd, s.t
    from generate_series((p ->> 'from_date')::date, (p ->> 'end_date')::date, interval '1 day') d
    join slots s on extract(dow from d)::int = s.wd
  ), c as (
    select 'regular'::text as kind, (p ->> 'tutor_id')::uuid as tutor_id, (dd + t) at time zone 'Asia/Seoul' as s0,
           ((p ->> 'duration_min')::int) as dur, dd, t
    from reg
    union all
    select 'migrated_makeup', (m ->> 'tutor_id')::uuid, ((m ->> 'date')::date + (m ->> 'time')::time) at time zone 'Asia/Seoul',
           (m ->> 'duration_min')::int, (m ->> 'date')::date, (m ->> 'time')::time
    from jsonb_array_elements(coalesce(p -> 'makeups', '[]'::jsonb)) m
  )
  select (row_number() over (order by s0, kind))::int, kind, tutor_id, s0, s0 + make_interval(mins => dur), dd, to_char(t, 'HH24:MI')
  from c
$$;
revoke all on function lms_import_candidates(jsonb) from public, anon, authenticated;

-- 후보의 충돌 목록 (등록 화면과 같은 모양: date·time·reason + kind·other_*)
create or replace function lms_import_conflicts(p jsonb)
returns jsonb
language sql stable security definer set search_path = public as $$
  with c as (select * from lms_import_candidates(p)),
  brk as (select interval '10 minutes' as v),   -- A38 (코드 CONFIRMED.minBreakMin 과 같아야 함)
  hits as (
    -- 같은 강사의 기존 수업: 겹치면 그 수업 종류, 휴식 10분 안이면 break
    select c.n, c.kind, c.kst_date, c.kst_time,
           case when l.starts_at < c.ends_at and c.starts_at < l.ends_at
                then case when l.kind = 'regular' then 'tutor_regular' else 'tutor_makeup' end else 'break' end as reason,
           l.starts_at as o0, l.ends_at as o1, s.name_ko as other
    from c join lessons l on l.tutor_id = c.tutor_id and l.state <> 'canceled'
                         and l.starts_at < c.ends_at + (select v from brk) and c.starts_at - (select v from brk) < l.ends_at
    left join students s on s.id = l.student_id
    union all
    select c.n, c.kind, c.kst_date, c.kst_time, 'tutor_time_off', o.starts_at, o.ends_at, coalesce(o.reason, '휴무')
    from c join tutor_time_off o on o.tutor_id = c.tutor_id and o.starts_at < c.ends_at and c.starts_at < o.ends_at
    union all
    -- 이번 입력끼리: 같은 강사면 휴식 10분까지, 다른 강사여도 학생 본인 시간이 겹치면
    select a.n, a.kind, a.kst_date, a.kst_time,
           case when b.starts_at < a.ends_at and a.starts_at < b.ends_at then 'self' else 'break' end,
           b.starts_at, b.ends_at, '이번 입력'
    from c a join c b on a.n <> b.n
      and ((a.tutor_id = b.tutor_id and b.starts_at < a.ends_at + (select v from brk) and a.starts_at - (select v from brk) < b.ends_at)
           or (b.starts_at < a.ends_at and a.starts_at < b.ends_at))
  )
  select coalesce(jsonb_agg(jsonb_build_object('date', kst_date, 'time', kst_time, 'kind', kind, 'reason', reason,
                                               'other_starts_at', o0, 'other_ends_at', o1, 'other', other) order by n), '[]'::jsonb)
  from hits
$$;
revoke all on function lms_import_conflicts(jsonb) from public, anon, authenticated;

-- 화면에서 부르는 함수 (운영자 TOTP 세션만)
-- p = {student:{name_ko,name_en,email,phone,country,city,timezone,admin_memo}, tutor_id, slots:[{weekday,time}],
--      duration_min, from_date, end_date, makeups:[{date,time,duration_min,tutor_id}]}
create or replace function admin_import_existing_student(p_request_id uuid, p jsonb)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  prev jsonb;
  st jsonb := p -> 'student';
  v_tutor uuid := nullif(p ->> 'tutor_id', '')::uuid;
  v_dur int := (p ->> 'duration_min')::int;
  v_from date := (p ->> 'from_date')::date;
  v_end date := (p ->> 'end_date')::date;
  v_slots jsonb := coalesce(p -> 'slots', '[]'::jsonb);
  v_makeups jsonb := coalesce(p -> 'makeups', '[]'::jsonb);
  m jsonb;
  s jsonb;
  conflicts jsonb;
  n_reg int;
  n_mk int;
  sid uuid;
  scode text;
  eid uuid;
  r record;
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
  for m in select * from jsonb_array_elements(v_makeups) loop
    if (m ->> 'date')::date < v_from then raise exception '보강 날짜(%)가 시작일(%)보다 빠릅니다. 지난 보강은 넣지 않아요.', m ->> 'date', v_from; end if;
    if (m ->> 'duration_min')::int not in (20, 40, 50) then raise exception '보강 수업 길이는 20·40·50분만 가능합니다.'; end if;
    if not exists (select 1 from tutors where id = (m ->> 'tutor_id')::uuid and active) then raise exception '보강 강사를 골라 주세요.'; end if;
  end loop;

  select count(*) filter (where kind = 'regular'), count(*) filter (where kind = 'migrated_makeup') into n_reg, n_mk
  from lms_import_candidates(p);
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
  returning id, code into sid, scode;

  -- 옛 상품 형태(legacy_label)로: 지금 등록의 남은 기간만. 결제·변경권은 시트에 있음 (policy_basis 기본 legacy)
  insert into enrollments (student_id, seq, legacy_label, weekly_count, duration_min, start_date, base_end_date,
                           lessons_purchased, status, created_by)
  values (sid, 1, '기존 학생 이관 (남은 기간만, 결제·변경권은 시트)', jsonb_array_length(v_slots), v_dur, v_from, v_end, n_reg, 'active', me)
  returning id into eid;

  for s in select * from jsonb_array_elements(v_slots) loop
    insert into regular_schedules (student_id, tutor_id, weekday, start_time_kst, duration_min, effective_from, change_reason)
    values (sid, v_tutor, (s ->> 'weekday')::smallint, (s ->> 'time')::time, v_dur, v_from, '기존 학생 이관 (D-52)');
  end loop;

  for r in select * from lms_import_candidates(p) order by starts_at loop
    if r.kind = 'regular' then seqn := seqn + 1; end if;
    insert into lessons (enrollment_id, student_id, tutor_id, kind, seq, starts_at, ends_at, created_by)
    values (eid, sid, r.tutor_id, r.kind, case when r.kind = 'regular' then seqn end, r.starts_at, r.ends_at, me);
  end loop;

  res := jsonb_build_object('student_id', sid, 'student_code', scode, 'enrollment_id', eid, 'lessons', n_reg, 'makeups', n_mk,
                            'start_date', v_from, 'end_date', v_end);
  insert into registration_requests (id, created_by, student_id, enrollment_id, result)
  values (p_request_id, me, sid, eid, res);
  return res;
end $$;
revoke all on function admin_import_existing_student(uuid, jsonb) from public, anon;
grant execute on function admin_import_existing_student(uuid, jsonb) to authenticated;
