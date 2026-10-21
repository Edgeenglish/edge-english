-- =====================================================================
-- 신규 학생 등록 저장 (2026-10-18 대표 최종 시안: 신청서 불러오기 + 강사·스케줄 선택)
-- 화면이 한 번 부르면 학생 · 수강등록 · (결제 확인) · (고정 일정 · 정규 수업)을 한 트랜잭션으로 만든다.
-- - 권한: TOTP까지 마친 운영자(is_admin, aal2)만. 표에는 앱 쓰기 권한을 주지 않고 이 함수만 연다 (POL-AC-07: 쓰기는 서버 쪽에서만)
-- - 중복 방지: 화면이 만든 요청 번호(request_id)가 같으면 처음 결과를 그대로 돌려준다 (저장 버튼 여러 번 눌러도 1번)
-- - 결제 확인 전에는 강사·정규 일정을 확정하지 않는다 (POL-OP-13). 결제 확인 기록이 들어가면 '신규 매칭' 업무가 기존 트리거로 생긴다
-- - 강사 배정까지 하면 업무의 '강사 배정'만 채운다. '학생 안내'는 안내가 실제로 끝났을 때 따로 (업무는 그때 사라짐)
-- - 일정 충돌: 강사의 다른 수업과 겹침 + 수업 사이 휴식 10분 + 강사 휴무 (POL-OP-21). 하나라도 있으면 아무것도 저장하지 않고
--   충돌 날짜 목록을 오류 상세(JSON)로 돌려준다. 화면이 먼저 같은 검사를 하지만, 그 사이 다른 등록이 생길 수 있어 여기서 다시 확인
-- - 수강등록의 적용 규칙(policy_basis)은 기본값(legacy) 그대로. 정책 원본 조건 안내·동의를 확인한 뒤 운영자가 바꾼다 (자동으로 최신 판본을 고르지 않음)
-- - 이메일이 같아도 기존 학생·계정에 연결하지 않는다 (POL-AC-04). 항상 새 학생 번호
-- 다시 실행해도 같은 결과
-- =====================================================================

create table if not exists registration_requests (
  id uuid primary key,                    -- 화면이 만든 요청 번호 (변경 이력이 id 로 행을 찾음)
  created_by uuid not null,
  student_id uuid not null references students(id),
  enrollment_id uuid not null references enrollments(id),
  result jsonb not null,
  created_at timestamptz not null default now()
);
do $$
begin
  if not exists (select 1 from pg_trigger where tgname = 'registration_requests_audit') then
    perform lms_protect('registration_requests'::regclass);
  end if;
end $$;

create or replace function admin_register_student(p_request_id uuid, p jsonb)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  prev jsonb;
  st jsonb := p -> 'student';
  co jsonb := p -> 'course';
  pay jsonb := p -> 'payment';
  slots jsonb := coalesce(p -> 'slots', '[]'::jsonb);
  v_tutor uuid := nullif(p ->> 'tutor_id', '')::uuid;
  v_weeks smallint := (co ->> 'weeks')::smallint;
  v_weekly smallint := (co ->> 'weekly_count')::smallint;
  v_dur smallint := (co ->> 'duration_min')::smallint;
  v_start date := (co ->> 'start_date')::date;
  v_end date;
  v_paid boolean := jsonb_typeof(p -> 'payment') = 'object';
  v_break interval := interval '10 minutes';   -- POL-OP-21 (코드 CONFIRMED.minBreakMin 과 같아야 함)
  sid uuid;
  scode text;
  eid uuid;
  d date;
  s jsonb;
  n integer := 0;
  t0 timestamptz;
  t1 timestamptz;
  conflicts jsonb := '[]'::jsonb;
  res jsonb;
begin
  if not is_admin() then
    raise exception '운영자(추가 인증 완료)만 학생을 등록할 수 있습니다.' using errcode = '42501';
  end if;
  if p_request_id is null then raise exception '요청 번호가 없습니다.'; end if;

  -- 같은 요청이 동시에 두 번 와도 하나씩 처리 → 두 번째는 첫 결과를 받음
  perform pg_advisory_xact_lock(hashtextextended(p_request_id::text, 0));
  select result into prev from registration_requests where id = p_request_id;
  if found then return prev || '{"repeated": true}'::jsonb; end if;

  perform set_config('app.actor_id', me::text, true);
  perform set_config('app.actor_via', 'admin_register_student', true);

  if v_weeks is null or v_weeks not in (4, 12, 24) then raise exception '수강 기간은 4·12·24주만 가능합니다.'; end if;
  if v_start is null then raise exception '첫 수업일(수강 시작일)이 없습니다.'; end if;
  v_end := v_start + (v_weeks / 4 * 28 - 1);

  if not v_paid and (v_tutor is not null or jsonb_array_length(slots) > 0) then
    raise exception '결제 확인 전에는 강사·정규 일정을 확정할 수 없습니다 (POL-OP-13).';
  end if;
  if v_tutor is not null then
    if jsonb_array_length(slots) <> v_weekly then
      raise exception '정규 시간 수(%)가 주 횟수(%)와 다릅니다.', jsonb_array_length(slots), v_weekly;
    end if;
    if (select count(distinct (x ->> 'weekday')::int) from jsonb_array_elements(slots) x) <> jsonb_array_length(slots) then
      raise exception '같은 요일에 정규 수업을 2개 넣을 수 없습니다.';
    end if;
    if not exists (select 1 from jsonb_array_elements(slots) x where (x ->> 'weekday')::int = extract(dow from v_start)) then
      raise exception '수강 시작일은 첫 정규 수업일이어야 합니다 (시작일 요일이 수업 요일에 없음).';
    end if;
    if not exists (select 1 from tutors where id = v_tutor and active) then raise exception '활동 중인 강사가 아닙니다.'; end if;
  elsif jsonb_array_length(slots) > 0 then
    raise exception '정규 시간을 정하려면 강사도 정해야 합니다.';
  end if;

  -- 학생 (항상 새 학생 번호. 같은 이메일이 있어도 연결·병합하지 않음)
  insert into students (name_ko, name_en, email, phone, country, city, timezone, admin_memo)
  values (st ->> 'name_ko', st ->> 'name_en', nullif(lower(trim(st ->> 'email')), ''), nullif(st ->> 'phone', ''),
          nullif(st ->> 'country', ''), nullif(st ->> 'city', ''), st ->> 'timezone', nullif(st ->> 'admin_memo', ''))
  returning id, code into sid, scode;

  insert into enrollments (student_id, seq, weeks, weekly_count, duration_min, start_date, base_end_date,
                           lessons_purchased, amount_due, status, created_by)
  values (sid, 1, v_weeks, v_weekly, v_dur, v_start, v_end, v_weekly * v_weeks,
          nullif(co ->> 'amount_due', '')::integer, case when v_paid then 'confirmed' else 'pending_payment' end, me)
  returning id into eid;

  if v_paid then
    -- paid_at = 실제 입금·결제 완료 시각 (은행 거래내역·아임웹 주문 시각), external_ref = 아임웹 주문번호 등 (같은 결제 두 번 기록 방지)
    insert into payments (enrollment_id, method, payer_name, amount_received, paid_at, received_on, external_ref, confirmed_by)
    values (eid, pay ->> 'method', nullif(pay ->> 'payer_name', ''), (pay ->> 'amount')::integer, (pay ->> 'paid_at')::timestamptz,
            (((pay ->> 'paid_at')::timestamptz at time zone 'UTC') + interval '9 hours')::date, nullif(pay ->> 'external_ref', ''), me);
  end if;

  if v_tutor is not null then
    for s in select * from jsonb_array_elements(slots) loop
      insert into regular_schedules (student_id, tutor_id, weekday, start_time_kst, duration_min, effective_from)
      values (sid, v_tutor, (s ->> 'weekday')::smallint, (s ->> 'time')::time, v_dur, v_start);
    end loop;

    d := v_start;
    while d <= v_end loop
      select x into s from jsonb_array_elements(slots) x where (x ->> 'weekday')::int = extract(dow from d);
      if found then
        n := n + 1;
        t0 := (d + (s ->> 'time')::time) at time zone 'Asia/Seoul';
        t1 := t0 + make_interval(mins => v_dur);
        conflicts := conflicts || coalesce((
          select jsonb_agg(jsonb_build_object('date', d, 'time', s ->> 'time', 'reason',
                   case when l.starts_at < t1 and t0 < l.ends_at then (case when l.kind = 'regular' then 'tutor_regular' else 'tutor_makeup' end) else 'break' end,
                   'other_starts_at', l.starts_at, 'other_ends_at', l.ends_at))
          from lessons l
          where l.tutor_id = v_tutor and l.state <> 'canceled'
            and l.starts_at < t1 + v_break and t0 - v_break < l.ends_at), '[]'::jsonb);
        conflicts := conflicts || coalesce((
          select jsonb_agg(jsonb_build_object('date', d, 'time', s ->> 'time', 'reason', 'tutor_time_off',
                   'other_starts_at', o.starts_at, 'other_ends_at', o.ends_at))
          from tutor_time_off o where o.tutor_id = v_tutor and o.starts_at < t1 and t0 < o.ends_at), '[]'::jsonb);
        -- 충돌이 하나라도 나오면 더 넣지 않고 끝까지 검사만 (겹침 제약 오류 대신 충돌 날짜 전체를 돌려주려고)
        if jsonb_array_length(conflicts) = 0 then
          insert into lessons (enrollment_id, student_id, tutor_id, kind, seq, starts_at, ends_at, created_by)
          values (eid, sid, v_tutor, 'regular', n, t0, t1, me);
        end if;
      end if;
      d := d + 1;
    end loop;

    if jsonb_array_length(conflicts) > 0 then
      raise exception '일정 충돌 %건 — 저장하지 않았습니다.', jsonb_array_length(conflicts)
        using errcode = 'P0001', detail = conflicts::text, hint = 'schedule_conflict';
    end if;
    if n <> v_weekly * v_weeks then
      raise exception '만들어진 정규 수업 수(%)가 등록 회차(%)와 다릅니다.', n, v_weekly * v_weeks;
    end if;

    update admin_tasks set tutor_id = v_tutor, tutor_assigned_at = now()
    where kind = 'new_student_matching' and enrollment_id = eid;
  end if;

  res := jsonb_build_object('student_id', sid, 'student_code', scode, 'enrollment_id', eid,
                            'status', case when v_paid then 'confirmed' else 'pending_payment' end,
                            'lessons', n, 'start_date', v_start, 'end_date', v_end);
  insert into registration_requests (id, created_by, student_id, enrollment_id, result)
  values (p_request_id, me, sid, eid, res);
  return res;
end $$;

revoke all on function admin_register_student(uuid, jsonb) from public, anon;
grant execute on function admin_register_student(uuid, jsonb) to authenticated;

-- 같은 이메일 학생이 이미 있는지 (연결하지 않고 알려 주기만 — POL-AC-04). 운영자만
create or replace function admin_students_with_email(p_email text)
returns table (code text, name_ko text)
language sql stable security definer set search_path = public as $$
  select code, name_ko from students
  where is_admin() and email is not null and lower(email) = lower(trim(p_email))
  order by code
$$;
revoke all on function admin_students_with_email(text) from public, anon;
grant execute on function admin_students_with_email(text) to authenticated;
