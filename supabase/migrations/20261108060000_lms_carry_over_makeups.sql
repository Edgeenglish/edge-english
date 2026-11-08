-- =====================================================================
-- 재등록 때 지난 수강권의 남은 보강을 새 수강권으로 이월 (2026-11-08, 대표 지시: 송O나 STU-0004)
--  운영진 안내(10/27 카톡): '재등록하시면 그대로 수업 이월, 다음 수강기간에 보강' = POL-RN-01(종료일까지 결제하면 이월)
--  admin_carry_over_makeups(요청 번호, p)
--   p = { student_code, items: [ {original_date: 'YYYY-MM-DD', starts_at: timestamptz | null}, ... ] }
--   - 대상: 그 학생의 가장 최근 재등록 수강권(새) 과 그 직전 수강권(지난)
--   - 새 수강권 결제가 지난 수강권 종료일 23:59 KST 안이어야 함 (POL-RN-01)
--   - 시트 이관 보강권(migrated_items makeup_open): 새 수강권으로 옮김. 날짜가 있으면 그 날짜로 보강 수업을 잡음
--     → 휴무로 미뤄진 보강도 새 수강권 안에서 하게 되므로, '휴무 보강 먼저' 규칙(2750)에 더 이상 걸리지 않음
--   - LMS 에서 취소한 수업의 보강권: 날짜가 있어야 함. 새 수강권에 그 수업의 보강(makeup_of)으로 잡음
--   - 날짜를 잡을 때 강사 = 지금 정규 수업 강사, 길이 = 지난 수강권 수업 길이, 충돌 검사 = 보강 확정과 같은 lms_makeup_conflict
--   - 새 수강권 이월 수(lessons_carried_in)에 옮긴 개수를 더함
--   - 같은 요청 번호로 다시 실행하면 처음 결과를 그대로 돌려줌. 지우는 것 없음
-- =====================================================================
create or replace function admin_carry_over_makeups(p_request_id uuid, p jsonb)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  prev jsonb;
  s students;
  en enrollments;
  pe enrollments;
  v_tutor uuid;
  it jsonb;
  d date;
  t timestamptz;
  m migrated_items;
  l lessons;
  lid uuid;
  why text;
  n int := 0;
  done jsonb := '[]'::jsonb;
  res jsonb;
begin
  if not is_admin() then raise exception '운영자(추가 인증 완료)만 처리할 수 있습니다.' using errcode = '42501'; end if;
  if p_request_id is null then raise exception '요청 번호가 없습니다.'; end if;
  perform pg_advisory_xact_lock(hashtextextended(p_request_id::text, 0));
  select result into prev from registration_requests where id = p_request_id;
  if found then return prev || '{"repeated": true}'::jsonb; end if;

  select * into s from students where code = p ->> 'student_code';
  if not found then raise exception '학생을 찾을 수 없습니다 (%).', p ->> 'student_code'; end if;
  select * into en from enrollments where student_id = s.id and previous_enrollment_id is not null
    and status in ('confirmed', 'active') order by seq desc limit 1 for update;
  if not found then raise exception '재등록한 수강권이 없습니다. 재등록을 먼저 넣어 주세요.'; end if;
  select * into pe from enrollments where id = en.previous_enrollment_id;
  if not exists (select 1 from payments x where x.enrollment_id = en.id
                 and x.paid_at < ((pe.final_end_date + 1)::timestamp at time zone 'Asia/Seoul')) then
    raise exception '지난 수강권 종료일(%) 23:59 KST 안에 결제한 재등록만 이월할 수 있습니다 (POL-RN-01).', pe.final_end_date;
  end if;
  if jsonb_typeof(p -> 'items') <> 'array' or jsonb_array_length(p -> 'items') = 0 then
    raise exception '이월할 보강을 넣어 주세요.';
  end if;
  select r.tutor_id into v_tutor from regular_schedules r
  where r.student_id = s.id and (r.effective_to is null or r.effective_to >= r.effective_from)
  order by r.effective_from desc limit 1;

  perform set_config('app.actor_id', me::text, true);
  perform set_config('app.actor_via', 'admin_carry_over_makeups', true);

  for it in select * from jsonb_array_elements(p -> 'items') loop
    d := (it ->> 'original_date')::date;
    t := nullif(it ->> 'starts_at', '')::timestamptz;
    if d is null then raise exception '원래 수업 날짜가 없습니다.'; end if;
    if t is not null then
      if v_tutor is null then raise exception '정규 수업 강사를 찾을 수 없습니다.'; end if;
      if t <= now() then raise exception '보강 날짜(%)가 이미 지났습니다.', t; end if;
      if (t at time zone 'Asia/Seoul')::date > en.final_end_date then
        raise exception '보강 날짜(%)가 새 수강권 종료일(%) 뒤입니다.', t, en.final_end_date;
      end if;
      why := lms_makeup_conflict(v_tutor, s.id, t, t + make_interval(mins => pe.duration_min), false);
      if why is not null then
        raise exception '% 보강 시간을 잡을 수 없습니다: %', to_char(t at time zone 'Asia/Seoul', 'MM/DD HH24:MI "KST"'), why using hint = 'schedule_conflict';
      end if;
    end if;

    select * into m from migrated_items x where x.enrollment_id = pe.id and x.kind = 'makeup_open' and x.original_date = d
      order by x.created_at limit 1 for update;
    if found then
      if t is null then
        update migrated_items set enrollment_id = en.id where id = m.id;
      else
        insert into lessons (enrollment_id, student_id, tutor_id, kind, starts_at, ends_at, created_by)
        values (en.id, s.id, v_tutor, 'migrated_makeup', t, t + make_interval(mins => pe.duration_min), me)
        returning id into lid;
        update migrated_items set enrollment_id = en.id, kind = 'makeup_booked', lesson_id = lid where id = m.id;
      end if;
      done := done || jsonb_build_object('original_date', d, 'from', 'sheet', 'starts_at', t, 'tutor_leave', m.tutor_leave);
    else
      select * into l from lessons x where x.enrollment_id = pe.id and x.kst_date = d and x.state = 'canceled' and x.voided_at is null
        and x.class_status::text in ('Student canceled in advance', 'Student canceled in advance (public holiday)',
                                     'Tutor canceled in advance', 'Tutor canceled late')
        and not exists (select 1 from lessons y where y.makeup_of = x.id and y.state <> 'canceled')
      order by x.starts_at limit 1 for update;
      if not found then raise exception '이월할 보강을 찾을 수 없습니다 (원래 수업 %).', d; end if;
      if t is null then raise exception '% 취소 수업의 보강은 날짜를 정해야 이월할 수 있습니다.', d; end if;
      insert into lessons (enrollment_id, student_id, tutor_id, kind, starts_at, ends_at, makeup_of, created_by)
      values (en.id, s.id, v_tutor, 'makeup', t, t + make_interval(mins => pe.duration_min), l.id, me)
      returning id into lid;
      done := done || jsonb_build_object('original_date', d, 'from', 'lms', 'starts_at', t);
    end if;
    n := n + 1;
  end loop;

  update enrollments set lessons_carried_in = lessons_carried_in + n where id = en.id;

  res := jsonb_build_object('student_code', s.code, 'enrollment_id', en.id, 'previous_enrollment_id', pe.id,
                            'carried', n, 'items', done);
  insert into registration_requests (id, created_by, student_id, enrollment_id, result)
  values (p_request_id, me, s.id, en.id, res);
  return res;
end $$;

revoke all on function admin_carry_over_makeups(uuid, jsonb) from public, anon;
grant execute on function admin_carry_over_makeups(uuid, jsonb) to authenticated;
