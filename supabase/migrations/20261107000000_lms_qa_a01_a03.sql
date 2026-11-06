-- =====================================================================
-- 전체 QA·UX 보고서 반영 ① A-01 · A-03 (2026-11-07, docs/lms/requests/2026-11-06-full-qa-ux-audit.md, 정책 원본 H26(70))
--  A-01 학생 화면 수업 취소: 운영자 보기(?student=)가 브라우저 시각을 요청 시각으로 보내 '요청 받은 시각이 지금보다 늦습니다'
--       로 저장이 거절되던 것 → admin_change_lesson 의 p_requested_at 이 비어 있으면 서버 시각(now())으로 판정.
--       6시간 규칙·판정 내용은 그대로. 운영진 수업 변경 화면(요청 받은 시각을 직접 적는 곳)은 전과 같이 적은 시각으로 판정.
--       학생 본인 로그인(student_change_lesson)은 원래부터 now() 였음(바뀐 것 없음)
--  A-03 정규 일정 수정: 아직 적용 전인('적용 예정') 변경을 적용일 전에 취소·수정할 수 있게.
--       지금까지는 새 일정이 '적용 시작일에 유효한 일정'과 같으면 무조건 거절해, 예정 변경을 원래 시간으로 되돌리는
--       저장이 막혔음 → 적용 시작일 뒤에 시작하는(아직 효력 전) 정규 일정 줄이 있으면 같은 시간이라도 저장 허용
--       (그 줄은 전처럼 효력 없는 날짜로 치워 두고, 옮겨 둔 수업은 새 일정 = 원래 시각으로 되돌아옴).
--       나머지 검사·저장 방식·변경권(쓰지 않음)·수업 수는 그대로
-- =====================================================================

-- A-01 ---------------------------------------------------------------
create or replace function admin_change_lesson(p_request_id uuid, p_lesson uuid, p_who text, p_requested_at timestamptz, p_dry_run boolean)
returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception '운영자(추가 인증 완료)만 처리할 수 있습니다.' using errcode = '42501'; end if;
  -- 요청 시각을 비우면 서버 시각(지금)으로 판정 — 학생 화면 운영자 보기(지금 받은 요청)가 쓰는 길
  return lms_change_core(p_request_id::text, p_lesson, p_who, 'admin_on_behalf', coalesce(p_requested_at, now()), p_dry_run, auth.uid());
end $$;
revoke all on function admin_change_lesson(uuid, uuid, text, timestamptz, boolean) from public, anon;
grant execute on function admin_change_lesson(uuid, uuid, text, timestamptz, boolean) to authenticated;

-- A-03 ---------------------------------------------------------------
create or replace function admin_regular_change(p_student uuid, p_slots jsonb, p_from date, p_reason text, p_dry_run boolean default true)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_today date := (now() at time zone 'Asia/Seoul')::date;
  v_break constant interval := interval '10 minutes';   -- POL-OP-21
  e enrollments;
  t tutors;
  v_tutor uuid;
  v_lid uuid;
  v_old jsonb;
  v_new jsonb;
  v_n_slots integer;
  s jsonb;
  v_reason text := nullif(trim(coalesce(p_reason, '')), '');
  v_movable uuid[];
  v_moved jsonb := '[]'::jsonb;
  v_kept jsonb;
  v_skipped jsonb := '[]'::jsonb;
  v_problems jsonb := '[]'::jsonb;
  l lessons;
  d date;
  i integer := 0;
  t0 timestamptz;
  t1 timestamptz;
  v_why text;
  v_last date;
  v_change uuid;
  v_guard integer := 0;
begin
  if not is_admin() then raise exception '운영자(추가 인증 완료)만 정규 일정을 바꿀 수 있습니다.' using errcode = '42501'; end if;
  select * into e from enrollments x where x.id = lms_student_enrollment(p_student);
  if e.id is null or e.status not in ('confirmed', 'active') then
    raise exception '수강 중이거나 시작 예정인 수강권이 없어 정규 일정을 바꿀 수 없습니다.';
  end if;
  if p_from is null or p_from < v_today then raise exception '적용 시작일은 오늘(한국 날짜) 이후여야 합니다.'; end if;
  if p_from > e.final_end_date then raise exception '적용 시작일(%)이 최종 종료일(%) 뒤입니다.', p_from, e.final_end_date; end if;

  -- 지금 정규 일정 (적용 시작일에 유효한 것). 강사는 하나
  select jsonb_agg(jsonb_build_object('weekday', rs.weekday, 'time', to_char(rs.start_time_kst, 'HH24:MI')) order by rs.weekday, rs.start_time_kst),
         count(distinct rs.tutor_id), (array_agg(distinct rs.tutor_id))[1]
    into v_old, v_n_slots, v_tutor
  from regular_schedules rs
  where rs.student_id = p_student and rs.effective_from <= greatest(p_from, e.start_date)
    and (rs.effective_to is null or rs.effective_to >= greatest(p_from, e.start_date));
  if v_old is null then raise exception '이 학생의 정규 일정이 없습니다 (등록·이관 때 정규 일정이 만들어집니다).'; end if;
  if v_n_slots <> 1 then raise exception '정규 일정의 강사가 하나가 아닙니다. 운영진이 확인해 주세요.'; end if;
  select * into t from tutors where id = v_tutor;

  -- 새 일정 모양: 지금과 같은 수(주 횟수 그대로), 요일 0~6 중복 없음, 30분 단위
  if p_slots is null or jsonb_typeof(p_slots) <> 'array' then raise exception '새 정규 일정이 비어 있습니다.'; end if;
  if jsonb_array_length(p_slots) <> jsonb_array_length(v_old) then
    raise exception '주 %회 수강권이라 요일을 %개 골라야 합니다 (주 횟수는 이 화면에서 바꾸지 않습니다).', jsonb_array_length(v_old), jsonb_array_length(v_old);
  end if;
  select jsonb_agg(jsonb_build_object('weekday', (x ->> 'weekday')::int, 'time', to_char((x ->> 'time')::time, 'HH24:MI')) order by (x ->> 'weekday')::int)
    into v_new from jsonb_array_elements(p_slots) x;
  for s in select * from jsonb_array_elements(v_new) loop
    if (s ->> 'weekday')::int not between 0 and 6 then raise exception '요일 값이 잘못됐습니다.'; end if;
    if extract(minute from (s ->> 'time')::time)::int not in (0, 30) then raise exception '시작 시간은 30분 단위(예: 22:00, 22:30)로 골라 주세요.'; end if;
  end loop;
  if (select count(distinct x ->> 'weekday') from jsonb_array_elements(v_new) x) <> jsonb_array_length(v_new) then
    raise exception '같은 요일을 두 번 고를 수 없습니다.';
  end if;
  -- A-03: 적용 시작일 뒤에 시작하는(아직 효력 전) 정규 일정 줄이 있으면 같은 시간이라도 저장 = 그 예정 변경 취소
  if v_new = v_old and not exists (select 1 from regular_schedules rs
                                   where rs.student_id = p_student and rs.tutor_id = t.id
                                     and rs.effective_from > greatest(p_from, e.start_date) and rs.effective_from > date '1950-01-01') then
    raise exception '지금 정규 일정과 같습니다. 바꿀 요일·시간을 골라 주세요.';
  end if;
  if not p_dry_run and v_reason is null then raise exception '수정 사유를 적어 주세요.'; end if;

  -- 옮길 수업: 이 수강권의 앞으로 정규 수업 중 적용 시작일 이후, 대체강사 아님, 휴무 처리 중 아님
  select coalesce(array_agg(x.id order by x.starts_at), '{}') into v_movable
  from lessons x
  where x.enrollment_id = e.id and x.kind = 'regular' and x.state = 'scheduled' and x.voided_at is null
    and x.starts_at > now() and x.kst_date >= p_from
    and x.original_tutor_id is null and x.tutor_id = t.id
    and not exists (select 1 from leave_items li where li.lesson_id = x.id and li.lesson_gone_at is null);
  -- 그대로 두는 앞으로의 수업 (왜 그대로인지 같이)
  select coalesce(jsonb_agg(jsonb_build_object('lesson_id', x.id, 'kind', x.kind, 'seq', x.seq, 'starts_at', x.starts_at, 'ends_at', x.ends_at,
           'tutor', xt.name, 'tutor_tz', xt.timezone,
           'why', case when x.kst_date < p_from then 'before_from'
                       when x.original_tutor_id is not null and x.original_tutor_id <> x.tutor_id then 'substitute'
                       when x.kind = 'makeup' then 'makeup' when x.kind = 'compensation' then 'compensation'
                       when x.kind in ('migrated_makeup', 'migrated_extra', 'carryover') then 'makeup'
                       when exists (select 1 from leave_items li where li.lesson_id = x.id and li.lesson_gone_at is null) then 'leave_open'
                       else 'other' end) order by x.starts_at), '[]'::jsonb)
    into v_kept
  from lessons x join tutors xt on xt.id = x.tutor_id
  where x.student_id = p_student and x.state = 'scheduled' and x.voided_at is null and x.starts_at > now()
    and not (x.id = any(v_movable));
  if cardinality(v_movable) = 0 then
    raise exception '적용 시작일(%) 이후에 옮길 정규 수업이 없습니다.', p_from;
  end if;

  -- 새 날짜에 차례로 배치: 적용 시작일부터 새 요일에 맞는 날을 순서대로. 학생의 그대로 두는 수업과 겹치는 날은 건너뜀
  d := p_from;
  foreach v_lid in array v_movable loop
    select * into l from lessons where id = v_lid;
    loop
      v_guard := v_guard + 1;
      if v_guard > 2000 then raise exception '새 일정 날짜를 찾지 못했습니다.'; end if;
      select x into s from jsonb_array_elements(v_new) x where (x ->> 'weekday')::int = extract(dow from d);
      if found then
        t0 := (d + (s ->> 'time')::time) at time zone 'Asia/Seoul';
        t1 := t0 + make_interval(mins => e.duration_min);
        -- 학생 본인의 그대로 두는 수업과 겹치면 이 날은 건너뜀
        if exists (select 1 from lessons y where y.student_id = p_student and y.state <> 'canceled' and y.voided_at is null
                   and not (y.id = any(v_movable)) and y.starts_at < t1 and t0 < y.ends_at) then
          v_skipped := v_skipped || jsonb_build_object('date', d, 'time', s ->> 'time', 'why', 'student_busy');
          d := d + 1; continue;
        end if;
        exit;
      end if;
      d := d + 1;
    end loop;
    -- R-15 (4520): 새 일정에서도 같은 날짜·시각이면 바뀌는 수업이 아님 → 그대로 두는 수업(same), 검사도 안 함
    if t0 = l.starts_at and t1 = l.ends_at then
      v_kept := v_kept || jsonb_build_object('lesson_id', l.id, 'kind', l.kind, 'seq', l.seq, 'starts_at', l.starts_at, 'ends_at', l.ends_at,
                 'tutor', t.name, 'tutor_tz', t.timezone, 'why', 'same');
      v_last := d;
      d := d + 1;
      continue;
    end if;
    -- 검사 (강사 기준)
    v_why := null;
    if not lms_tutor_start_ok(t.id, t0) then v_why := 'tutor_hours_range';
    elsif not lms_tutor_available(t.id, t0) then v_why := 'tutor_unavailable';
    elsif exists (select 1 from tutor_time_off o where o.tutor_id = t.id and o.starts_at < t1 and t0 < o.ends_at) then v_why := 'tutor_time_off';
    elsif exists (select 1 from lessons y where y.tutor_id = t.id and y.state <> 'canceled' and not (y.id = any(v_movable))
                  and y.starts_at < t1 + v_break and t0 - v_break < y.ends_at) then v_why := 'tutor_busy';
    elsif exists (select 1 from lms_slot_hold_hits(t.id, t0, t1) h where h.student_id <> p_student) then v_why := 'tutor_hold';
    end if;
    if d > e.final_end_date then v_why := coalesce(v_why, 'after_end'); end if;
    if v_why is not null then
      v_problems := v_problems || jsonb_build_object('lesson_id', l.id, 'seq', l.seq, 'date', d, 'time', s ->> 'time', 'why', v_why,
        'other', case when v_why = 'tutor_busy' then (select st.name_ko || ' ' || to_char(y.starts_at at time zone 'Asia/Seoul', 'HH24:MI') || '–' || to_char(y.ends_at at time zone 'Asia/Seoul', 'HH24:MI')
                                                  from lessons y join students st on st.id = y.student_id
                                                  where y.tutor_id = t.id and y.state <> 'canceled' and not (y.id = any(v_movable))
                                                    and y.starts_at < t1 + v_break and t0 - v_break < y.ends_at order by y.starts_at limit 1)
                      when v_why = 'tutor_hold' then (select h.student_name from lms_slot_hold_hits(t.id, t0, t1) h where h.student_id <> p_student limit 1) end);
    end if;
    v_moved := v_moved || jsonb_build_object('lesson_id', l.id, 'seq', l.seq, 'from', l.starts_at, 'from_end', l.ends_at, 'to', t0, 'to_end', t1, 'problem', v_why);
    v_last := d;
    d := d + 1;
  end loop;

  -- 그대로 두는 수업은 시간순으로 (same 이 뒤에 붙었음)
  select coalesce(jsonb_agg(x order by (x ->> 'starts_at')::timestamptz), '[]'::jsonb) into v_kept from jsonb_array_elements(v_kept) x;
  if p_dry_run then
    return jsonb_build_object('ok', jsonb_array_length(v_problems) = 0, 'tutor', jsonb_build_object('id', t.id, 'name', t.name, 'timezone', t.timezone),
      'student_timezone', (select timezone from students where id = p_student),
      'enrollment', jsonb_build_object('id', e.id, 'final_end_date', e.final_end_date, 'duration_min', e.duration_min),
      'old_slots', v_old, 'new_slots', v_new, 'effective_from', p_from, 'moved', v_moved, 'kept', v_kept, 'skipped', v_skipped,
      'problems', v_problems, 'last_date', v_last,
      'cancels_pending', exists (select 1 from regular_schedules rs where rs.student_id = p_student and rs.tutor_id = t.id
                                 and rs.effective_from > greatest(p_from, e.start_date) and rs.effective_from > date '1950-01-01'));
  end if;
  if jsonb_array_length(v_problems) > 0 then
    raise exception '새 일정에 문제가 %건 있어 저장하지 않았습니다. 미리 보기를 다시 확인해 주세요.', jsonb_array_length(v_problems)
      using errcode = 'P0001', detail = v_problems::text, hint = 'regular_change_problems';
  end if;

  -- 저장: 옮기는 중 같은 학생 수업끼리 잠깐 겹치지 않게 두 단계로 (먼저 200년 뒤로 비켜 두고, 다시 새 시각으로)
  perform set_config('app.actor_id', auth.uid()::text, true);
  perform set_config('app.actor_via', 'admin_regular_change', true);
  for s in select * from jsonb_array_elements(v_moved) loop
    update lessons set starts_at = (s ->> 'to')::timestamptz + interval '200 years', ends_at = (s ->> 'to_end')::timestamptz + interval '200 years'
    where id = (s ->> 'lesson_id')::uuid;
  end loop;
  for s in select * from jsonb_array_elements(v_moved) loop
    update lessons set starts_at = (s ->> 'to')::timestamptz, ends_at = (s ->> 'to_end')::timestamptz where id = (s ->> 'lesson_id')::uuid;
  end loop;
  -- 정규 일정 표: 적용 시작일 전날까지로 닫고 새 줄. 적용 시작일 이후에 시작하는(아직 효력 전) 줄은 효력 없는 날짜(1900-01-01)로 치워 둠(지우지 않음)
  update regular_schedules rs
     set effective_from = date '1900-01-01' + (select count(*) from regular_schedules r2 where r2.student_id = rs.student_id and r2.weekday = rs.weekday and r2.effective_to < date '1950-01-01')::int,
         effective_to = date '1900-01-01' + (select count(*) from regular_schedules r2 where r2.student_id = rs.student_id and r2.weekday = rs.weekday and r2.effective_to < date '1950-01-01')::int,
         change_reason = coalesce(rs.change_reason, '') || ' [취소됨 ' || p_from || ']'
  where rs.student_id = p_student and rs.tutor_id = t.id and rs.effective_from >= p_from;
  -- A-03: 새 일정이 적용 시작일 직전까지 유효한 줄과 같으면(예정 변경 취소 = 원래대로) 그 줄을 닫지 않고 그대로 이어 감 (줄을 쪼개지 않음)
  if v_new = (select jsonb_agg(jsonb_build_object('weekday', rs.weekday, 'time', to_char(rs.start_time_kst, 'HH24:MI')) order by rs.weekday, rs.start_time_kst)
              from regular_schedules rs
              where rs.student_id = p_student and rs.tutor_id = t.id and rs.duration_min = e.duration_min
                and rs.effective_from > date '1950-01-01' and rs.effective_from < p_from and rs.effective_to >= p_from - 1) then
    update regular_schedules rs set effective_to = null,
           change_reason = coalesce(rs.change_reason, '') || ' [' || p_from || ' 다시 이어 감: ' || v_reason || ']'
    where rs.student_id = p_student and rs.tutor_id = t.id
      and rs.effective_from > date '1950-01-01' and rs.effective_from < p_from and rs.effective_to >= p_from - 1;
  else
    update regular_schedules rs set effective_to = p_from - 1
    where rs.student_id = p_student and rs.tutor_id = t.id and rs.effective_from < p_from and (rs.effective_to is null or rs.effective_to >= p_from);
    for s in select * from jsonb_array_elements(v_new) loop
      insert into regular_schedules (student_id, tutor_id, weekday, start_time_kst, duration_min, effective_from, change_reason)
      values (p_student, t.id, (s ->> 'weekday')::smallint, (s ->> 'time')::time, e.duration_min, p_from, v_reason);
    end loop;
  end if;
  insert into regular_changes (student_id, enrollment_id, tutor_id, effective_from, old_slots, new_slots, moved, kept, reason, created_by)
  values (p_student, e.id, t.id, p_from, v_old, v_new, v_moved, v_kept, v_reason, auth.uid())
  returning id into v_change;
  return jsonb_build_object('ok', true, 'change_id', v_change, 'moved', jsonb_array_length(v_moved), 'effective_from', p_from, 'last_date', v_last);
exception
  when exclusion_violation then
    raise exception '저장 중 겹침이 생겨 저장하지 않았습니다 (%). 미리 보기를 다시 확인해 주세요.', sqlerrm;
end $$;
revoke all on function admin_regular_change(uuid, jsonb, date, text, boolean) from public, anon;
grant execute on function admin_regular_change(uuid, jsonb, date, text, boolean) to authenticated;
