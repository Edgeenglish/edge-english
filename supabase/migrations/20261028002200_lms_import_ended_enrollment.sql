-- =====================================================================
-- 기존 학생 입력: 시트에서 이미 다 끝난 수강권(남은 수업 0회)도 '기록용'으로 넣기 (2026-10-28 대표 '응')
--  - 재등록을 기다리는 학생(예: 정O연, 10/29 종료·남은 0회)을 LMS에 넣어 대시보드 '종료 임박' 카드로 계속 보이게 함
--    (카드는 종료일이 지나도 대표가 재등록 입력 또는 [끝냄]할 때까지 남음 — H26(28) ⑦)
--  - 바뀐 것은 한 줄: 정규 수업이 0회여도, 시트 남은 수가 보강·추가 수업 수와 같으면(보통 0) 거절하지 않음
--    그 밖의 검사·계산은 1600 그대로. 재등록 대기 자리(1400)도 그대로 종료일 23:59까지 맡아 둠
-- 기존 표·데이터를 지우지 않음. 다시 실행해도 같은 결과
-- =====================================================================

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
  if n_reg = 0 and (v_total - v_used) <> n_mk + n_open + n_ex then
    raise exception '시작일~종료일 사이에 정규 수업이 없습니다. 날짜·요일을 확인해 주세요.';
  end if;

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
