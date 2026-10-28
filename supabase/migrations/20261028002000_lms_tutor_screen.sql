-- =====================================================================
-- ② 강사 LMS: 수업 일정 확인 · Class Record 직접 입력 · 보강 가능 여부 응답 (2026-10-27 대표 확정 순서 나안, H26(18))
--  - 수업 결과는 lessons.class_status 하나 (POL-ST-02). 강사가 고르는 것은 '진행 / 강사 지각 / 학생 노쇼' 셋뿐이고
--    정확한 상태 이름(Normal · Make-up completed · Covered by another tutor)은 수업 종류·대체 여부로 DB가 정함
--    → class_status_rules 로 회차·변경권·급여 지급이 자동 (같은 표를 정산이 씀)
--  - 취소·휴무 같은 '시스템이 아는 결과'는 1700·1800 처리에서 이미 기록됨 → 강사는 진행 대상 수업만 입력 (POL-TU-07)
--  - 원래 수업 길이(lessons.starts_at~ends_at)는 기록으로 바뀌지 않음. 급여 인정 시간은 정산 때 payroll_items.minutes 로 따로
--  - 정산 표(payroll_items)에 들어간 수업은 강사가 결과를 못 고침
--  - 보강: 강사는 학생이 원한 시간마다 가능/불가만 답함. 확정은 지금처럼 운영진 admin_makeup_confirm (D-43, 가능 ≠ 확정)
--  - 운영자(TOTP 완료)는 강사 화면을 그대로 열어 볼 수 있고, 같은 함수로 대신 입력할 수 있음 (같은 검사·같은 기록)
-- 기존 표·데이터를 지우지 않음. 다시 실행해도 같은 결과
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. 보강 시간별 강사 답 (가능/불가)
-- ---------------------------------------------------------------------
alter table makeup_candidates add column if not exists tutor_answer text;
alter table makeup_candidates add column if not exists answered_at timestamptz;
alter table makeup_candidates add column if not exists answered_by uuid;
alter table makeup_requests add column if not exists tutor_answered_at timestamptz;
do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'makeup_candidates_answer_check') then
    alter table makeup_candidates add constraint makeup_candidates_answer_check
      check (tutor_answer is null or tutor_answer in ('yes', 'no'));
    alter table makeup_candidates add constraint makeup_candidates_answer_when
      check ((tutor_answer is null) = (answered_at is null));
  end if;
end $$;

-- ---------------------------------------------------------------------
-- 2. 누구의 강사 화면인지: 강사 본인, 또는 운영자(TOTP 완료)가 고른 강사
-- ---------------------------------------------------------------------
create or replace function lms_screen_tutor(p_tutor uuid) returns uuid
language plpgsql stable security definer set search_path = public as $$
declare
  mine uuid := my_tutor_id();
begin
  if is_admin() and p_tutor is not null then return p_tutor; end if;
  if mine is null or (p_tutor is not null and p_tutor <> mine) then
    raise exception 'Please sign in with your tutor account.' using errcode = '42501';
  end if;
  return mine;
end $$;
revoke all on function lms_screen_tutor(uuid) from public, anon, authenticated;

-- 수업 회차 (시트 Class Count 'n/총'): 학생 수업이 소진되는 수업만 번호가 붙음 (POL-ST-01 consumes_lesson)
--  · 기존 학생 입력(import_checks)이면 시트에서 이미 진행된 수부터 이어서 셈
--  · 예정 수업은 그대로 진행된다고 보고 번호를 미리 붙임, 보상 수업은 셈에서 뺌
create or replace function lms_lesson_count(p_lesson uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  select case when l.voided_at is not null or l.kind = 'compensation'
              or (l.class_status is not null and not r.consumes_lesson) then null
         else jsonb_build_object(
           'n', coalesce(c.sheet_used, 0) + (
             select count(*) from lessons x left join class_status_rules xr on xr.status = x.class_status
             where x.enrollment_id = l.enrollment_id and x.voided_at is null and x.kind <> 'compensation'
               and (x.class_status is null or xr.consumes_lesson)
               and (x.starts_at, x.id) <= (l.starts_at, l.id)),
           'total', coalesce(c.sheet_total, e.lessons_purchased + e.lessons_carried_in)) end
  from lessons l
  join enrollments e on e.id = l.enrollment_id
  left join class_status_rules r on r.status = l.class_status
  left join import_checks c on c.enrollment_id = e.id
  where l.id = p_lesson
$$;
revoke all on function lms_lesson_count(uuid) from public, anon, authenticated;

-- 그 시간에 강사의 다른 수업(휴식 10분 포함)·휴무가 있는지 (admin_makeup_confirm 과 같은 기준)
create or replace function lms_tutor_busy(p_tutor uuid, p_start timestamptz, p_end timestamptz) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from lessons x where x.tutor_id = p_tutor and x.state <> 'canceled'
                 and x.starts_at < p_end + interval '10 minutes' and p_start - interval '10 minutes' < x.ends_at)   -- POL-OP-21
      or exists (select 1 from tutor_time_off o where o.tutor_id = p_tutor and o.starts_at < p_end and p_start < o.ends_at)
$$;
revoke all on function lms_tutor_busy(uuid, timestamptz, timestamptz) from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- 3. 강사 화면 한 번에 읽기: 강사 정보 + 기간 안 수업(한국 날짜 기준) + 답할 보강 신청
--    학생 정보는 수업에 필요한 것만 (이름·레벨·수업 노트 링크) — 연락처·결제·변경권은 주지 않음
-- ---------------------------------------------------------------------
create or replace function tutor_screen(p_tutor uuid, p_from date, p_to date)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_tutor uuid := lms_screen_tutor(p_tutor);
  t tutors;
begin
  if p_from is null or p_to is null or p_to < p_from then raise exception 'Invalid date range.'; end if;
  select * into t from tutors where id = v_tutor;
  return jsonb_build_object(
    'tutor', jsonb_build_object('id', t.id, 'name', t.name, 'timezone', t.timezone, 'meet_url', t.meet_url),
    'lessons', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', l.id, 'starts_at', l.starts_at, 'ends_at', l.ends_at, 'kind', l.kind, 'state', l.state, 'class_status', l.class_status,
        'student', coalesce(s.display_name, s.name_en), 'level', s.level, 'note_url', s.class_note_url,
        'covering', l.original_tutor_id is not null and l.original_tutor_id <> l.tutor_id,
        'makeup_of', o.starts_at,
        'count', lms_lesson_count(l.id),
        'topics', cr.covered_topics, 'remarks', cr.remarks, 'recorded_at', cr.first_submitted_at,
        'locked', exists (select 1 from payroll_items p where p.lesson_id = l.id))
        order by l.starts_at)
      from lessons l
      join students s on s.id = l.student_id
      left join lessons o on o.id = l.makeup_of
      left join class_records cr on cr.lesson_id = l.id
      where l.tutor_id = v_tutor and l.voided_at is null
        and (l.kst_date between p_from and p_to
             or (l.state = 'scheduled' and l.starts_at <= now()
                 and l.starts_at >= (select min(u.created_at) from app_users u where u.tutor_id = v_tutor)))), '[]'::jsonb),
    -- 기록할 수업: 시작했는데 결과가 없는 수업 (강사 LMS 계정이 생긴 뒤 시작한 수업만 — 그 전 수업은 시트에 기록됨)
    'to_record', coalesce((
      select jsonb_agg(l.id order by l.starts_at)
      from lessons l
      where l.tutor_id = v_tutor and l.state = 'scheduled' and l.voided_at is null and l.starts_at <= now()
        and l.starts_at >= (select min(u.created_at) from app_users u where u.tutor_id = v_tutor)), '[]'::jsonb),
    'makeups', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', r.id, 'student', coalesce(s.display_name, s.name_en),
        'original_at', src.starts_at, 'original_date', mi.original_date,
        'note', r.tutor_note, 'answered_at', r.tutor_answered_at,
        'slots', (select jsonb_agg(jsonb_build_object(
                    'id', c.id, 'starts_at', c.starts_at, 'ends_at', c.ends_at, 'answer', c.tutor_answer,
                    'busy', lms_tutor_busy(r.tutor_id, c.starts_at, c.ends_at), 'past', c.starts_at <= now())
                    order by c.starts_at)
                  from makeup_candidates c where c.request_id = r.id and c.proposed_by = 'student'))
        order by r.created_at)
      from makeup_requests r
      join students s on s.id = r.student_id
      left join lessons src on src.id = r.source_lesson_id
      left join migrated_items mi on mi.id = r.migrated_item_id
      where r.tutor_id = v_tutor and r.status in ('requested', 'countered')), '[]'::jsonb));
end $$;
revoke all on function tutor_screen(uuid, date, date) from public, anon;
grant execute on function tutor_screen(uuid, date, date) to authenticated;

-- ---------------------------------------------------------------------
-- 4. Class Record 입력 (강사 본인 또는 운영자 대신 입력)
--    p_result: 'held'(진행) | 'late'(강사 지각, 학생 있음 — 사유 필수 POL-TU-01) | 'student_no_show'(학생 노쇼 POL-TU-09)
--    · 시작 시각 뒤에만, 예정·진행 기록된 수업만 (취소된 수업은 이미 결과가 있음)
--    · 다시 저장하면 고침 (첫 기록 시각은 그대로 — POL-TU-06 10분 기준). 정산에 들어간 수업은 못 고침
-- ---------------------------------------------------------------------
create or replace function tutor_record_class(p_lesson uuid, p_result text, p_topics text, p_remarks text)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  l lessons;
  v_status class_status;
  v_topics text := nullif(trim(coalesce(p_topics, '')), '');
  v_remarks text := nullif(trim(coalesce(p_remarks, '')), '');
  v_old class_records;
begin
  select * into l from lessons where id = p_lesson for update;
  if not found then raise exception 'Class not found.'; end if;
  if not (is_admin() or (my_tutor_id() is not null and l.tutor_id = my_tutor_id())) then
    raise exception 'This is not your class.' using errcode = '42501';
  end if;
  if l.voided_at is not null or l.state = 'canceled' then
    raise exception 'This class was canceled (%). No record needed.', coalesce(l.class_status::text, 'removed') using hint = 'canceled';
  end if;
  if l.starts_at > now() then raise exception 'You can record this class after it starts.' using hint = 'not_started'; end if;
  if exists (select 1 from payroll_items where lesson_id = l.id) then
    raise exception 'This class is already in payroll. Please contact Edge English to change it.' using hint = 'locked';
  end if;
  if p_result = 'held' then
    if v_topics is null then raise exception 'Please enter the covered topics.' using hint = 'topics'; end if;
    v_status := case when l.kind in ('makeup', 'migrated_makeup', 'compensation') then 'Make-up completed'
                     when l.original_tutor_id is not null and l.original_tutor_id <> l.tutor_id then 'Covered by another tutor'
                     else 'Normal' end;
  elsif p_result = 'late' then
    if v_topics is null then raise exception 'Please enter the covered topics.' using hint = 'topics'; end if;
    if v_remarks is null then raise exception 'Please write the reason for being late in Remarks.' using hint = 'remarks'; end if;
    v_status := 'Tutor Late - Student Present';
  elsif p_result = 'student_no_show' then
    v_status := 'Student no-show';
  else
    raise exception 'Please choose how the class went.';
  end if;

  select * into v_old from class_records where lesson_id = l.id;
  if l.state = 'done' and l.class_status = v_status and found
     and v_old.covered_topics is not distinct from v_topics and v_old.remarks is not distinct from v_remarks then
    return jsonb_build_object('lesson_id', l.id, 'class_status', v_status, 'repeated', true);
  end if;

  perform set_config('app.actor_id', me::text, true);
  perform set_config('app.actor_via', case when is_admin() then 'admin_record_class' else 'tutor_record_class' end, true);
  update lessons set state = 'done', class_status = v_status where id = l.id and (state, class_status) is distinct from ('done', v_status);
  insert into class_records (lesson_id, covered_topics, remarks, submitted_by)
  values (l.id, v_topics, v_remarks, me)
  on conflict (lesson_id) do update set covered_topics = excluded.covered_topics, remarks = excluded.remarks, submitted_by = excluded.submitted_by;
  return jsonb_build_object('lesson_id', l.id, 'class_status', v_status, 'repeated', false);
end $$;
revoke all on function tutor_record_class(uuid, text, text, text) from public, anon;
grant execute on function tutor_record_class(uuid, text, text, text) to authenticated;

-- ---------------------------------------------------------------------
-- 5. 보강 가능 여부 답 (학생이 원한 시간마다 가능/불가 + 메모). 확정은 운영진 (D-43)
--    · 다시 답하면 고침. 답이 오면 강사에게 WhatsApp으로 물어볼 안내(makeup_ask)는 '보낼 필요 없음'
-- ---------------------------------------------------------------------
create or replace function tutor_makeup_answer(p_request uuid, p_yes uuid[], p_note text)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  r makeup_requests;
  v_note text := nullif(trim(coalesce(p_note, '')), '');
  v_yes uuid[] := coalesce(p_yes, '{}');
begin
  select * into r from makeup_requests where id = p_request for update;
  if not found then raise exception 'Make-up request not found.'; end if;
  if not (is_admin() or (my_tutor_id() is not null and r.tutor_id = my_tutor_id())) then
    raise exception 'This is not your make-up request.' using errcode = '42501';
  end if;
  if r.status not in ('requested', 'countered') then
    raise exception 'This make-up request is already closed.' using hint = 'closed';
  end if;
  if exists (select 1 from unnest(v_yes) y where not exists
             (select 1 from makeup_candidates c where c.id = y and c.request_id = r.id and c.proposed_by = 'student')) then
    raise exception 'Unknown time in your answer. Please reload the page.';
  end if;
  if cardinality(v_yes) = 0 and v_note is null then
    raise exception 'None of the times work? Please write other times you are available in the note.' using hint = 'note';
  end if;
  perform set_config('app.actor_id', me::text, true);
  perform set_config('app.actor_via', case when is_admin() then 'admin_makeup_answer' else 'tutor_makeup_answer' end, true);
  update makeup_candidates c set tutor_answer = case when c.id = any(v_yes) then 'yes' else 'no' end, answered_at = now(), answered_by = me
  where c.request_id = r.id and c.proposed_by = 'student'
    and c.tutor_answer is distinct from case when c.id = any(v_yes) then 'yes' else 'no' end;
  update makeup_requests set tutor_note = v_note, tutor_answered_at = now() where id = r.id;
  update lesson_notices set status = 'not_needed' where makeup_request_id = r.id and event = 'makeup_ask' and status = 'pending';
  return jsonb_build_object('makeup_request_id', r.id, 'yes', cardinality(v_yes));
end $$;
revoke all on function tutor_makeup_answer(uuid, uuid[], text) from public, anon;
grant execute on function tutor_makeup_answer(uuid, uuid[], text) to authenticated;

-- ---------------------------------------------------------------------
-- 6. 운영자: 강사 화면을 열 강사 목록 (LMS 로그인 계정 연결 여부 포함)
-- ---------------------------------------------------------------------
create or replace function admin_tutor_accounts()
returns table (tutor_id uuid, name text, timezone text, active boolean, has_login boolean)
language plpgsql stable security definer set search_path = public as $$
begin
  if not is_admin() then raise exception '운영자(추가 인증 완료)만 볼 수 있습니다.' using errcode = '42501'; end if;
  return query select t.id, t.name, t.timezone, t.active, exists (select 1 from app_users u where u.tutor_id = t.id)
  from tutors t order by t.active desc, t.name;
end $$;
revoke all on function admin_tutor_accounts() from public, anon;
grant execute on function admin_tutor_accounts() to authenticated;

-- ---------------------------------------------------------------------
-- 7. 운영자 대시보드: Class Record 미기록 (강사 LMS 계정이 있는 강사의 수업만, 끝나고 10분 지남 — POL-TU-06)
-- ---------------------------------------------------------------------
create or replace function admin_class_record_missing()
returns table (lesson_id uuid, tutor_id uuid, tutor_name text, student_name text, student_code text, starts_at timestamptz, ends_at timestamptz)
language plpgsql stable security definer set search_path = public as $$
begin
  if not is_admin() then raise exception '운영자(추가 인증 완료)만 볼 수 있습니다.' using errcode = '42501'; end if;
  return query
  select l.id, t.id, t.name, s.name_ko, s.code, l.starts_at, l.ends_at
  from lessons l
  join tutors t on t.id = l.tutor_id
  join students s on s.id = l.student_id
  join lateral (select min(u.created_at) as since from app_users u where u.tutor_id = t.id) a on a.since is not null
  where l.state = 'scheduled' and l.voided_at is null
    and l.ends_at + interval '10 minutes' <= now()   -- POL-TU-06 수업 끝나고 10분 안 기록
    and l.starts_at >= a.since
  order by l.starts_at;
end $$;
revoke all on function admin_class_record_missing() from public, anon;
grant execute on function admin_class_record_missing() to authenticated;
