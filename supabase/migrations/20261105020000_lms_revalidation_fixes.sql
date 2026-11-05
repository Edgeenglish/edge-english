-- =====================================================================
-- 4520 Work 최종 재검증(2026-11-05) R-01~21 중 DB 쪽 수정 — 시험용 DB 먼저, 운영 DB 는 대표 승인 뒤
--  1. R-18 이관 휴무 보강(migrated_makeup) 확정 때 종료일 자동 연장이 빠짐: admin_makeup_confirm 이 lessons INSERT 뒤에
--     migrated_items.lesson_id 를 연결해 lessons 의 AFTER INSERT 트리거(lessons_leave_extension)가 그 이관권을 못 찾았음
--     → migrated_items 에 연결(lesson_id·tutor_leave·kind)이 바뀌면 같은 트랜잭션에서 lms_leave_sync_extension 을 다시 계산하는 트리거 +
--       admin_makeup_confirm 도 연결 뒤 바로 호출. 확정·없애기·되돌리기·재확정 어느 경로든 같은 최종 종료일 기준
--  2. R-12 student_screen.credit_periods: 수강권의 모든 28일 기간(시작·끝·지급·잔여) — 화면이 수업 날짜가 속한 기간의 변경권으로 미리 보기
--  3. R-16 lms_hours_cell: 답 대기 'r' 은 아직 답하지 않은 후보만, 이미 '가능' 이라고 답해 운영진 확정을 기다리는 칸은 'a'
--     (잠금 정책은 그대로 — 안내만 구분). tutor_schedule_save 의 거절 문구도 구분
--  4. R-15 admin_regular_change: 새 일정에서도 날짜·시각이 그대로인 수업은 '바뀌는 수업' 이 아니라 '그대로 두는 수업(same)'
--  5. R-09 admin_leave_create: 같은 강사의 겹치는 휴무가 있으면 미리 보기에 보여 주고 저장은 거절(hint leave_overlap). 같은 기간 재입력은 전처럼 한 줄
--  6. R-10 기존 배정이 있는 신규 매칭의 '수업 컨펌 완료': admin_matching_current(읽기) · admin_matching_notified(학생 안내 완료 기록 → 업무 완료)
--  7. R-06 처리 내역에 시트 '대조 완료' 기록(④) + 다시 열기 admin_import_unmark_checked
--  8. R-05 Google Meet 회의실 주소 검사 lms_meet_url_ok: 대체강사 확정(admin_leave_student_ok)은 유효한 회의실 링크가 있어야 함
-- 지우는 문장(drop·delete) 새로 없음 (tutor_schedule_save 안의 delete 는 4403 함수 내용 그대로). 기존 표·데이터 그대로. 다시 실행해도 같은 결과
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. R-18 이관권 연결이 바뀌면 휴무 자동 연장 재계산
-- ---------------------------------------------------------------------
create or replace function migrated_items_leave_extension() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.enrollment_id is not null and (new.lesson_id is distinct from old.lesson_id or new.tutor_leave is distinct from old.tutor_leave or new.kind is distinct from old.kind) then
    perform lms_leave_sync_extension(new.enrollment_id);
  end if;
  return null;
end $$;
revoke all on function migrated_items_leave_extension() from public, anon, authenticated;
do $$
begin
  if not exists (select 1 from pg_trigger where tgname = 'migrated_items_leave_extension' and tgrelid = 'migrated_items'::regclass) then
    create trigger migrated_items_leave_extension after update of lesson_id, tutor_leave, kind on migrated_items
      for each row execute function migrated_items_leave_extension();
  end if;
end $$;

-- admin_makeup_confirm: 4500 그대로 + 이관권 연결 뒤 연장 재계산을 같은 트랜잭션에서 (트리거와 같은 계산 — 두 번 불려도 결과 같음)
create or replace function admin_makeup_confirm(p_makeup_request uuid, p_starts_at timestamptz)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  r makeup_requests;
  s record;
  c record;
  e enrollments;
  v_end timestamptz;
  v_lesson uuid;
  v_conf text;
  v_enr uuid;
begin
  if not is_admin() then raise exception '운영자(추가 인증 완료)만 처리할 수 있습니다.' using errcode = '42501'; end if;
  select * into r from makeup_requests where id = p_makeup_request for update;
  if not found then raise exception '보강 신청이 없습니다.'; end if;
  if r.status = 'confirmed' then return jsonb_build_object('makeup_request_id', r.id, 'lesson_id', r.confirmed_lesson_id, 'repeated', true); end if;
  if r.status not in ('requested', 'countered') then raise exception '이미 닫힌 보강 신청입니다.'; end if;
  if p_starts_at <= now() then raise exception '지난 시간은 보강으로 넣을 수 없습니다.'; end if;
  -- 강사가 불가라고 답한 시간 (QA-01 D, 4500)
  if exists (select 1 from makeup_candidates x where x.request_id = r.id and x.starts_at = p_starts_at and x.proposed_by = 'student' and x.tutor_answer = 'no') then
    raise exception '강사가 불가라고 답한 시간입니다. 다른 시간을 고르거나 학생에게 다시 날짜를 받아 주세요.' using hint = 'tutor_no';
  end if;

  if r.compensation_id is not null then
    perform 1 from compensations where id = r.compensation_id for update;   -- 같은 보상권 두 번 쓰기 막기
    select * into c from lms_comp_source(r.compensation_id);
    if p_starts_at >= ((c.use_until + 1)::timestamp at time zone 'Asia/Seoul') then
      raise exception '보상수업 사용 기한(%) 뒤의 시간입니다.', c.use_until using hint = 'after_end';
    end if;
    select * into e from enrollments where id = c.enrollment_id;
    v_end := p_starts_at + make_interval(mins => e.duration_min);
    v_conf := lms_makeup_conflict(r.tutor_id, c.student_id, p_starts_at, v_end,
                exists (select 1 from makeup_candidates x where x.request_id = r.id and x.starts_at = p_starts_at and x.proposed_by = 'student'));
    if v_conf is not null then raise exception '그 시간은 %와 겹칩니다.', v_conf using hint = 'schedule_conflict'; end if;
    v_enr := lms_comp_lesson_enrollment(r.compensation_id, (p_starts_at at time zone 'Asia/Seoul')::date);
    perform set_config('app.actor_id', me::text, true);
    perform set_config('app.actor_via', 'admin_makeup_confirm', true);
    if not exists (select 1 from makeup_candidates where request_id = r.id and starts_at = p_starts_at) then
      insert into makeup_candidates (request_id, starts_at, ends_at, proposed_by) values (r.id, p_starts_at, v_end, 'tutor');
    end if;
    begin
      insert into lessons (enrollment_id, student_id, tutor_id, kind, starts_at, ends_at, compensation_id, created_by)
      values (v_enr, c.student_id, r.tutor_id, 'compensation', p_starts_at, v_end, r.compensation_id, me)
      returning id into v_lesson;
    exception when exclusion_violation then
      raise exception '그 시간에 학생 또는 강사의 다른 수업이 있습니다.' using hint = 'schedule_conflict';
    end;
    update compensations set status = 'used', used_lesson_id = v_lesson where id = r.compensation_id;
  else
    select * into s from lms_makeup_source(r.source_lesson_id, r.migrated_item_id);
    select * into e from enrollments where id = s.enrollment_id;
    if not s.tutor_leave and p_starts_at >= ((e.final_end_date + 1)::timestamp at time zone 'Asia/Seoul') then
      raise exception '수강 종료일(%) 뒤의 시간입니다.', e.final_end_date using hint = 'after_end';
    end if;
    v_end := p_starts_at + make_interval(mins => e.duration_min);
    v_conf := lms_makeup_conflict(r.tutor_id, s.student_id, p_starts_at, v_end,
                exists (select 1 from makeup_candidates x where x.request_id = r.id and x.starts_at = p_starts_at and x.proposed_by = 'student'));
    if v_conf is not null then raise exception '그 시간은 %와 겹칩니다.', v_conf using hint = 'schedule_conflict'; end if;

    perform set_config('app.actor_id', me::text, true);
    perform set_config('app.actor_via', 'admin_makeup_confirm', true);
    if not exists (select 1 from makeup_candidates where request_id = r.id and starts_at = p_starts_at) then
      insert into makeup_candidates (request_id, starts_at, ends_at, proposed_by) values (r.id, p_starts_at, v_end, 'tutor');
    end if;
    begin
      insert into lessons (enrollment_id, student_id, tutor_id, kind, starts_at, ends_at, makeup_of, created_by)
      values (s.enrollment_id, s.student_id, r.tutor_id,
              case when r.source_lesson_id is null then 'migrated_makeup' else 'makeup' end,
              p_starts_at, v_end, r.source_lesson_id, me)
      returning id into v_lesson;
    exception when exclusion_violation then
      raise exception '그 시간에 학생 또는 강사의 다른 수업이 있습니다.' using hint = 'schedule_conflict';
    end;
    if r.migrated_item_id is not null then
      update migrated_items set kind = 'makeup_booked', lesson_id = v_lesson where id = r.migrated_item_id;
      -- R-18 (4520): 이관권이 수업에 연결된 뒤 휴무 자동 연장 재계산 (lessons 트리거는 연결 전에 돌아 못 찾았음)
      perform lms_leave_sync_extension(s.enrollment_id);
    end if;
  end if;
  update makeup_requests set status = 'confirmed', confirmed_lesson_id = v_lesson, decided_at = now(), decided_by = me where id = r.id;
  update lesson_notices set status = 'not_needed' where makeup_request_id = r.id and event = 'makeup_ask' and status = 'pending';
  insert into lesson_notices (makeup_request_id, event, recipient_kind, recipient_id)
  values (r.id, 'makeup_confirmed', 'student', r.student_id), (r.id, 'makeup_confirmed', 'tutor', r.tutor_id);
  return jsonb_build_object('makeup_request_id', r.id, 'lesson_id', v_lesson, 'repeated', false);
end $$;
revoke all on function admin_makeup_confirm(uuid, timestamptz) from public, anon;
grant execute on function admin_makeup_confirm(uuid, timestamptz) to authenticated;

-- ---------------------------------------------------------------------
-- 3. R-16 칸 판정: r = 아직 답하지 않은 후보 / a = '가능' 이라고 답했고 운영진 확정 대기 (둘 다 못 바꾸는 칸, 안내만 다름)
--    순서 c·l·p·s·r·a·b·x·o (4500 그대로 + a)
-- ---------------------------------------------------------------------
create or replace function lms_hours_cell(p_tutor uuid, p_at timestamptz) returns text
language sql stable security definer set search_path = public as $$
  select case
    when exists (select 1 from lessons x where x.tutor_id = p_tutor and x.state <> 'canceled' and x.voided_at is null
                 and x.starts_at < p_at + interval '30 minutes' and p_at < x.ends_at) then 'c'
    when exists (select 1 from tutor_time_off o where o.tutor_id = p_tutor and o.kind = 'leave'
                 and o.starts_at < p_at + interval '30 minutes' and p_at < o.ends_at) then 'l'
    when p_at < now() + interval '6 hours' then 'p'
    when not lms_tutor_available(p_tutor, p_at) then 's'
    when exists (select 1 from makeup_candidates c join makeup_requests r on r.id = c.request_id
                 where r.tutor_id = p_tutor and r.status in ('requested', 'countered') and c.tutor_answer is null
                   and c.starts_at < p_at + interval '30 minutes' and p_at < c.ends_at)
      or exists (select 1 from leave_items i where i.sub_tutor_id = p_tutor and i.sub_stage = 'asked'
                 and i.starts_at < p_at + interval '30 minutes' and p_at < i.ends_at) then 'r'
    when exists (select 1 from makeup_candidates c join makeup_requests r on r.id = c.request_id
                 where r.tutor_id = p_tutor and r.status in ('requested', 'countered') and c.tutor_answer = 'yes'
                   and c.starts_at < p_at + interval '30 minutes' and p_at < c.ends_at)
      or exists (select 1 from leave_items i where i.sub_tutor_id = p_tutor and i.sub_stage = 'tutor_ok'
                 and i.starts_at < p_at + interval '30 minutes' and p_at < i.ends_at) then 'a'
    when exists (select 1 from tutor_time_off o where o.tutor_id = p_tutor and o.kind = 'block'
                 and o.starts_at < p_at + interval '30 minutes' and p_at < o.ends_at) then 'b'
    when not lms_tutor_weekly_ok(p_tutor, p_at) then 'x'
    else 'o' end
$$;
revoke all on function lms_hours_cell(uuid, timestamptz) from public, anon, authenticated;

-- tutor_schedule_save: 4403 그대로 + 'a'(답 보냄·확정 대기) 거절 문구 구분 (R-16)
create or replace function tutor_schedule_save(p_tutor uuid, p_action text, p_cells text[] default null, p_note text default null, p_block uuid default null)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_tutor uuid := lms_screen_tutor(p_tutor);
  v_tz text;
  v_today date;
  v_last date;
  v_times time[];
  v_note text := nullif(btrim(coalesce(p_note, '')), '');
  v_keys text[];
  k text;
  v_c text;
  v_at timestamptz;
  v_end timestamptz;
  v_cut timestamptz;
  o record;
  v_s timestamptz;
  v_e timestamptz;
  v_runs tstzrange[];
  v_xs boolean[];
  i int;
  v_changes jsonb;
begin
  select timezone into v_tz from tutors where id = v_tutor;
  v_today := (now() at time zone v_tz)::date;
  v_last := v_today + 84;   -- 오늘부터 12주 후까지 (대표 H26(50) ②)
  v_times := array(select lms_hours_times(v_tz, v_today));
  perform set_config('app.actor_id', coalesce(auth.uid()::text, ''), true);
  perform set_config('app.actor_via', case when is_admin() then 'admin_tutor_schedule' else 'tutor_schedule' end, true);
  if v_note is not null and char_length(v_note) > 100 then raise exception 'Note is too long (100 characters max).'; end if;   -- 대표 H26(50) ③

  if p_action in ('block', 'open') then
    v_keys := array(select distinct x from unnest(coalesce(p_cells, '{}')) x order by 1);
    if cardinality(v_keys) = 0 then raise exception 'Pick a time.'; end if;
    foreach k in array v_keys loop
      if k !~ '^\d{4}-\d\d-\d\dT\d\d:\d\d$' or not (right(k, 5)::time = any (v_times)) then raise exception 'Invalid time: %', k; end if;
      if left(k, 10)::date < v_today or left(k, 10)::date > v_last then raise exception 'You can only change times up to 12 weeks ahead.'; end if;
      v_at := (left(k, 10)::date + right(k, 5)::time) at time zone v_tz;
      v_c := lms_hours_cell(v_tutor, v_at);
      if v_c = 'c' then
        select format('You have a class at %s %s. Classes can''t be blocked.', to_char(x.starts_at at time zone v_tz, 'HH24:MI'), lms_city_time(v_tz)) into k
        from lessons x where x.tutor_id = v_tutor and x.state <> 'canceled' and x.voided_at is null
          and x.starts_at < v_at + interval '30 minutes' and v_at < x.ends_at order by x.starts_at limit 1;
        raise exception '%', k;
      end if;
      if v_c = 'p' then raise exception 'Can''t change: less than 6 hours away.'; end if;
      if v_c = 'r' then raise exception 'A make-up or cover request is waiting for this time. Answer it first.'; end if;
      if v_c = 'a' then raise exception 'Your answer has been sent for this time. Waiting for Edge English to confirm. Contact Edge English to change it.'; end if;
      if v_c = 'l' then raise exception 'This time is in your leave.'; end if;
      if p_action = 'block' and v_c not in ('o', 'x') then
        raise exception '% % is already %.', left(k, 10), right(k, 5), case v_c when 'b' then 'blocked' else 'not available' end;
      end if;
      if p_action = 'open' and v_c <> 's' then raise exception '% % is already available.', left(k, 10), right(k, 5); end if;
    end loop;

    -- 이어진 칸 = 한 줄 (메모는 줄마다 그대로, 다른 줄과 합치지 않음). 바꾸기 전에 묶음을 먼저 다 계산해 둠
    select array_agg(tstzrange(s, e) order by s), array_agg(all_x order by s) into v_runs, v_xs
    from (select min(a) s, max(a) + interval '30 minutes' e, bool_and(c = 'x') all_x
          from (select a, c, extract(epoch from a)::bigint / 1800 - row_number() over (partition by c = 'x' order by a) grp
                from (select (left(x, 10)::date + right(x, 5)::time) at time zone v_tz a, lms_hours_cell(v_tutor, (left(x, 10)::date + right(x, 5)::time) at time zone v_tz) c
                      from unnest(v_keys) x) q) z
          group by grp, (c = 'x')) w;
    for i in 1 .. cardinality(v_runs) loop
      v_s := lower(v_runs[i]);
      v_e := upper(v_runs[i]);
      if p_action = 'open' then
        -- 붙어 있는 그날만 연 줄과 합침
        v_at := v_s;
        v_end := v_e;
        for o in select * from tutor_open_once where tutor_id = v_tutor and starts_at <= v_end and v_at <= ends_at loop
          v_at := least(v_at, o.starts_at);
          v_end := greatest(v_end, o.ends_at);
          delete from tutor_open_once where id = o.id;
        end loop;
        insert into tutor_open_once (tutor_id, starts_at, ends_at, created_by) values (v_tutor, v_at, v_end, auth.uid());
      elsif v_xs[i] then
        -- 그날만 연 칸을 다시 막음 = 그 열기를 그 칸만 거둠 (매주 닫힌 시간으로 돌아감)
        for o in select * from tutor_open_once where tutor_id = v_tutor and starts_at < v_e and v_s < ends_at loop
          delete from tutor_open_once where id = o.id;
          if o.starts_at < v_s then insert into tutor_open_once (tutor_id, starts_at, ends_at, created_by) values (v_tutor, o.starts_at, v_s, o.created_by); end if;
          if v_e < o.ends_at then insert into tutor_open_once (tutor_id, starts_at, ends_at, created_by) values (v_tutor, v_e, o.ends_at, o.created_by); end if;
        end loop;
      else
        insert into tutor_time_off (tutor_id, starts_at, ends_at, kind, reason, created_by) values (v_tutor, v_s, v_e, 'block', v_note, auth.uid());
      end if;
    end loop;
    v_changes := jsonb_build_object('from', v_today, 'weekly_open', '[]'::jsonb, 'weekly_close', '[]'::jsonb,
      'once_close', case when p_action = 'block' then to_jsonb(v_keys) else '[]'::jsonb end, 'once_open', '[]'::jsonb,
      'day_open', case when p_action = 'open' then to_jsonb(v_keys) else '[]'::jsonb end, 'note', v_note);

  elsif p_action in ('note', 'unblock') then
    select * into o from tutor_time_off where id = p_block and tutor_id = v_tutor and kind = 'block';
    if not found then raise exception 'This blocked time is gone. Please refresh.'; end if;
    if o.ends_at <= now() then raise exception 'Can''t change: this time has passed.'; end if;
    if p_action = 'note' then
      update tutor_time_off set reason = v_note where id = o.id;
      v_changes := jsonb_build_object('from', v_today, 'weekly_open', '[]'::jsonb, 'weekly_close', '[]'::jsonb, 'once_close', '[]'::jsonb, 'once_open', '[]'::jsonb,
        'day_open', '[]'::jsonb, 'note', v_note,
        'note_of', to_char(o.starts_at at time zone v_tz, 'YYYY-MM-DD"T"HH24:MI') || '/' || to_char(o.ends_at at time zone v_tz, 'YYYY-MM-DD"T"HH24:MI'));
    else
      -- 6시간 안 부분은 못 바꿈 → 그 뒤 첫 30분 칸(강사 현지)부터만 풂
      v_cut := date_bin(interval '30 minutes', ((now() + interval '6 hours') at time zone v_tz) + interval '30 minutes' - interval '1 microsecond', timestamp '2000-01-01') at time zone v_tz;
      if o.ends_at <= v_cut then raise exception 'Can''t change: less than 6 hours away.'; end if;
      v_keys := array(select to_char(g at time zone v_tz, 'YYYY-MM-DD"T"HH24:MI')
                      from generate_series(greatest(o.starts_at, v_cut), o.ends_at - interval '1 second', interval '30 minutes') g
                      where (g at time zone v_tz)::time = any (v_times));
      delete from tutor_time_off where id = o.id;
      if o.starts_at < v_cut then
        insert into tutor_time_off (tutor_id, starts_at, ends_at, kind, reason, created_by) values (v_tutor, o.starts_at, v_cut, 'block', o.reason, o.created_by);
      end if;
      v_changes := jsonb_build_object('from', v_today, 'weekly_open', '[]'::jsonb, 'weekly_close', '[]'::jsonb, 'once_close', '[]'::jsonb,
        'once_open', to_jsonb(v_keys), 'day_open', '[]'::jsonb, 'note', null);
    end if;
  else
    raise exception 'Invalid action.';
  end if;

  insert into tutor_hours_changes (tutor_id, actor, by_admin, changes) values (v_tutor, auth.uid(), is_admin(), v_changes);
  return v_changes;
end $$;
revoke all on function tutor_schedule_save(uuid, text, text[], text, uuid) from public, anon;
grant execute on function tutor_schedule_save(uuid, text, text[], text, uuid) to authenticated;


-- ---------------------------------------------------------------------
-- 2. R-12 학생 화면: 4500 그대로 + credit_periods (수강권의 모든 기간: 수업 날짜가 속한 기간의 변경권으로 미리 보기)
-- ---------------------------------------------------------------------
create or replace function student_screen(p_student uuid)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_student uuid := lms_screen_student(p_student);
  st students;
  e enrollments;
  v_period enrollment_periods;
  v_open uuid[];
  v_today date := (now() at time zone 'Asia/Seoul')::date;
begin
  select * into st from students where id = v_student;
  select * into e from enrollments where id = lms_student_enrollment(v_student);
  select * into v_period from enrollment_periods p
  where p.enrollment_id = e.id and p.start_date <= v_today order by p.idx desc limit 1;
  v_open := array(select x.id from enrollments x where x.student_id = v_student and (x.status in ('active', 'confirmed') or x.id = e.id));
  return jsonb_build_object(
    'student', jsonb_build_object('id', st.id, 'code', st.code, 'name_ko', st.name_ko, 'timezone', st.timezone),
    'enrollment', case when e.id is null then null else jsonb_build_object(
      'id', e.id, 'weeks', e.weeks, 'legacy_label', e.legacy_label, 'weekly_count', e.weekly_count, 'duration_min', e.duration_min,
      'start_date', e.start_date, 'final_end_date', e.final_end_date, 'status', e.status,
      'next_regular_from', lms_next_regular_from(e.id),
      'lessons_total', coalesce((select c.sheet_total from import_checks c where c.enrollment_id = e.id), e.lessons_purchased + e.lessons_carried_in),
      'credits_left', case when v_period.id is null then 0 else credit_balance(v_period.id) end,
      'credits_granted', coalesce(v_period.credits_granted, 0),
      'confirmed_on', (select min((p.confirmed_at at time zone 'Asia/Seoul')::date) from payments p where p.enrollment_id = e.id and p.confirmed_at is not null),
      'renewal_paid', exists (select 1 from enrollments n where n.previous_enrollment_id = e.id and n.status in ('confirmed', 'active'))) end,
    'lessons', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', l.id, 'kind', l.kind, 'starts_at', l.starts_at, 'ends_at', l.ends_at, 'state', l.state, 'class_status', l.class_status,
        'tutor', t.name, 'meet_url', t.meet_url, 'makeup_of', l.makeup_of, 'leave_postponed', lms_is_leave_postponed(l.id),
        'substitute', l.original_tutor_id is not null,
        'leave_open', exists (select 1 from leave_items li where li.lesson_id = l.id and li.lesson_gone_at is null
                              and (li.choice = 'undecided' or (li.choice = 'substitute' and li.sub_stage <> 'confirmed')))) order by l.starts_at)
      from lessons l join tutors t on t.id = l.tutor_id
      where l.enrollment_id = any(v_open) and l.voided_at is null), '[]'::jsonb),
    -- 보강을 받을 수 있는데 아직 날짜가 없는 것 (취소한 수업 · 시트에서 넘어온 날짜 미정 보강 · 강사 노쇼 무료 보상수업)
    -- QA-13 (4500): 보강 수업이 잡힌 뒤 취소(voided 아님)된 원래 수업은 다시 권리가 되지 않음 — 권리는 그 보강 수업의 결과를 따름
    'makeup_rights', coalesce((
      select jsonb_agg(r order by r ->> 'original_at', r ->> 'comp_id' nulls first) from (
        select jsonb_build_object('lesson_id', l.id, 'item_id', null, 'original_at', l.starts_at,
                 'tutor_leave', l.class_status = 'Tutor long-term leave') as r
        from lessons l
        where l.enrollment_id = any(v_open) and l.voided_at is null and (lms_grants_makeup(l.class_status) or l.class_status = 'Tutor long-term leave')
          and not exists (select 1 from lessons x where x.makeup_of = l.id and x.voided_at is null)
        union all
        select jsonb_build_object('lesson_id', null, 'item_id', m.id,
                 'original_at', coalesce((select li.starts_at from leave_items li where li.migrated_item_id = m.id order by li.starts_at limit 1),
                                         m.original_date::timestamp at time zone 'Asia/Seoul'),
                 'time_known', exists (select 1 from leave_items li where li.migrated_item_id = m.id),
                 'tutor_leave', coalesce(m.tutor_leave, false))
        from migrated_items m where m.enrollment_id = any(v_open) and m.kind = 'makeup_open'
          and not exists (select 1 from leave_items li where li.migrated_item_id = m.id and li.lesson_gone_at is null
                          and li.choice in ('undecided', 'substitute'))
        union all
        select jsonb_build_object('lesson_id', null, 'item_id', null, 'comp_id', c.id, 'original_at', src.starts_at,
                 'tutor', t.name, 'use_until', lms_comp_use_until(c.enrollment_id), 'tutor_leave', false)
        from compensations c
        join lessons src on src.id = c.source_lesson_id
        join tutors t on t.id = src.tutor_id
        where c.student_id = v_student and c.status = 'available' and lms_comp_use_until(c.enrollment_id) >= v_today) q), '[]'::jsonb),
    'leave_pending', coalesce((
      select jsonb_agg(jsonb_build_object('id', li.id, 'starts_at', li.starts_at, 'ends_at', li.ends_at) order by li.starts_at)
      from leave_items li
      where li.student_id = v_student and li.lesson_id is null and li.lesson_gone_at is null and li.starts_at > now()
        and (li.choice = 'undecided' or (li.choice = 'substitute' and li.sub_stage <> 'confirmed'))), '[]'::jsonb),
    -- 신청 내역 (4100 + 4500: 확정 수업 상태 · 강사가 모든 후보에 불가 답)
    'makeup_requests', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', r.id, 'status', r.status, 'lesson_id', r.source_lesson_id, 'item_id', r.migrated_item_id, 'comp_id', r.compensation_id,
        'requested_at', r.requested_at, 'confirmed_lesson_id', r.confirmed_lesson_id, 'tutor_answered_at', r.tutor_answered_at,
        'confirmed_state', cl.state,
        'tutor_declined_all', r.tutor_answered_at is not null
          and not exists (select 1 from makeup_candidates c where c.request_id = r.id and c.proposed_by = 'student' and c.tutor_answer = 'yes'),
        'original_at', coalesce(src.starts_at, (select m.original_date::timestamp at time zone 'Asia/Seoul' from migrated_items m where m.id = r.migrated_item_id)),
        'original_time_known', src.id is not null,
        'original_tutor', srct.name,
        'tutor', rt.name,
        'confirmed_at', cl.starts_at,
        'tutor_leave', coalesce(src.class_status = 'Tutor long-term leave',
                                (select m.tutor_leave from migrated_items m where m.id = r.migrated_item_id), false),
        'candidates', (select coalesce(jsonb_agg(c.starts_at order by c.starts_at), '[]'::jsonb) from makeup_candidates c where c.request_id = r.id and c.proposed_by = 'student'))
        order by r.requested_at desc)
      from makeup_requests r
      left join lessons src on src.id = r.source_lesson_id
      left join tutors srct on srct.id = src.tutor_id
      left join tutors rt on rt.id = r.tutor_id
      left join lessons cl on cl.id = r.confirmed_lesson_id
      where r.student_id = v_student and r.status in ('requested', 'countered', 'confirmed')
        and r.requested_at > now() - interval '60 days'), '[]'::jsonb),
    'leave', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', li.id, 'starts_at', li.starts_at, 'choice', li.choice, 'stage', li.sub_stage, 'sub_tutor', sub.name, 'sub_meet_url', sub.meet_url,
        'lesson_id', li.lesson_id, 'item_id', li.migrated_item_id,
        'off_from', o.starts_at, 'off_to', o.ends_at) order by li.starts_at)
      from leave_items li
      join tutor_time_off o on o.id = li.time_off_id
      left join tutors sub on sub.id = li.sub_tutor_id
      where li.student_id = v_student and li.starts_at > now() and li.lesson_gone_at is null
        and ((li.choice = 'substitute' and li.sub_stage in ('tutor_ok', 'confirmed')) or li.choice = 'wait')), '[]'::jsonb),
    'credit_period', case when v_period.id is null then null else jsonb_build_object('start', v_period.start_date, 'end', v_period.end_date) end,
    -- R-12 (4520): 모든 기간의 잔여 — 미래 수업 취소 미리 보기는 그 수업 날짜가 속한 기간으로
    'credit_periods', coalesce((
      select jsonb_agg(jsonb_build_object('idx', p.idx, 'start', p.start_date, 'end', p.end_date, 'granted', p.credits_granted, 'left', credit_balance(p.id)) order by p.idx)
      from enrollment_periods p where p.enrollment_id = e.id), '[]'::jsonb),
    'credit_uses', coalesce((
      select jsonb_agg(jsonb_build_object('at', c.created_at, 'reason', c.reason, 'delta', c.delta, 'note', c.note, 'lesson_at', l.starts_at) order by c.created_at)
      from credit_ledger c left join lessons l on l.id = c.lesson_id where c.period_id = v_period.id), '[]'::jsonb),
    'holidays', coalesce((select jsonb_agg(h.day order by h.day) from holidays h
      where h.day between v_today and v_today + 200), '[]'::jsonb),
    'points', coalesce((
      select jsonb_agg(jsonb_build_object('id', g.id, 'on', (g.created_at at time zone 'Asia/Seoul')::date, 'kind', g.kind, 'amount', g.amount, 'note', g.note)
        order by g.created_at)
      from reward_ledger g where g.student_id = v_student), '[]'::jsonb));
end $$;
revoke all on function student_screen(uuid) from public, anon;
grant execute on function student_screen(uuid) to authenticated;


-- ---------------------------------------------------------------------
-- 4. R-15 정규 일정 수정: 4300 그대로 + 새 일정에서도 날짜·시각이 그대로인 수업은 moved 가 아니라 kept(why 'same')
--    (바뀌는 수업 수·저장 결과·변경 이력·안내문이 같은 목록을 씀)
-- ---------------------------------------------------------------------
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
  if v_new = v_old then raise exception '지금 정규 일정과 같습니다. 바꿀 요일·시간을 골라 주세요.'; end if;
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
      'problems', v_problems, 'last_date', v_last);
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
  update regular_schedules rs set effective_to = p_from - 1
  where rs.student_id = p_student and rs.tutor_id = t.id and rs.effective_from < p_from and (rs.effective_to is null or rs.effective_to >= p_from);
  for s in select * from jsonb_array_elements(v_new) loop
    insert into regular_schedules (student_id, tutor_id, weekday, start_time_kst, duration_min, effective_from, change_reason)
    values (p_student, t.id, (s ->> 'weekday')::smallint, (s ->> 'time')::time, e.duration_min, p_from, v_reason);
  end loop;
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


-- ---------------------------------------------------------------------
-- 5. R-09 휴무 넣기: 같은 강사의 겹치는(또는 포함되는) 휴무가 있으면 미리 보기에 'overlap' 으로 보여 주고, 저장은 거절 (hint leave_overlap)
--    같은 기간을 다시 넣는 것은 전처럼 같은 휴무 한 줄(4510). 철회된 휴무는 겹침으로 보지 않음
-- ---------------------------------------------------------------------
create or replace function lms_leave_overlaps(p_tutor uuid, p_from date, p_to date) returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce((select jsonb_agg(jsonb_build_object('id', o.id, 'from', (o.starts_at at time zone 'Asia/Seoul')::date,
                                                        'to', ((o.ends_at at time zone 'Asia/Seoul')::date - 1), 'reason', o.reason) order by o.starts_at)
    from tutor_time_off o
    where o.tutor_id = p_tutor and o.kind = 'leave' and o.withdrawn_at is null
      and o.starts_at < ((p_to + 1)::timestamp at time zone 'Asia/Seoul') and (p_from::timestamp at time zone 'Asia/Seoul') < o.ends_at
      and not (o.starts_at = (p_from::timestamp at time zone 'Asia/Seoul') and o.ends_at = ((p_to + 1)::timestamp at time zone 'Asia/Seoul'))), '[]'::jsonb)
$$;
revoke all on function lms_leave_overlaps(uuid, date, date) from public, anon, authenticated;

create or replace function admin_leave_create(p_tutor uuid, p_from date, p_to date, p_reason text, p_dry_run boolean)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  t0 timestamptz := (p_from::timestamp at time zone 'Asia/Seoul');
  t1 timestamptz := ((p_to + 1)::timestamp at time zone 'Asia/Seoul');
  v_off uuid;
  v_lessons integer;
  v_items integer;
  v_students integer;
  v_overlap jsonb;
begin
  if not is_admin() then raise exception '운영자(추가 인증 완료)만 처리할 수 있습니다.' using errcode = '42501'; end if;
  if p_from is null or p_to is null or p_to < p_from then raise exception '휴무 끝일이 시작일보다 빠릅니다.'; end if;
  if not exists (select 1 from tutors where id = p_tutor) then raise exception '강사가 없습니다.'; end if;

  v_overlap := lms_leave_overlaps(p_tutor, p_from, p_to);
  select count(*) filter (where n.lesson_id is not null), count(*), count(distinct n.student_id)
  into v_lessons, v_items, v_students from lms_leave_candidates(p_tutor, p_from, p_to) n;
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
    insert into tutor_time_off (tutor_id, starts_at, ends_at, kind, reason, created_by)
    values (p_tutor, t0, t1, 'leave', nullif(trim(p_reason), ''), me) returning id into v_off;
  end if;
  -- 전에 철회한 휴무의 줄이 남아 있으면(수업당 한 줄 규칙) 그 줄을 이 휴무로 되살림
  with rev as (
    update leave_items i
    set time_off_id = v_off, tutor_id = p_tutor, student_id = n.student_id, enrollment_id = n.enrollment_id, starts_at = n.starts_at, ends_at = n.ends_at,
        choice = 'undecided', sub_tutor_id = null, sub_stage = null, sub_lesson_id = null, decided_at = null, decided_by = null,
        sub_declined = '{}', lesson_gone_at = null, withdrawn_at = null, created_by = me, created_at = now()
    from lms_leave_candidates(p_tutor, p_from, p_to) n
    where i.withdrawn_at is not null
      and ((n.lesson_id is not null and i.lesson_id = n.lesson_id) or (n.migrated_item_id is not null and i.migrated_item_id = n.migrated_item_id))
    returning i.id, i.student_id
  )
  insert into lesson_notices (leave_item_id, event, recipient_kind, recipient_id)
  select id, 'leave_options', 'student', student_id from rev;
  -- 새로 들어온 줄마다 학생에게 두 가지 선택 안내 (화면은 학생마다 한 메시지로 묶어 복사)
  with ins as (
    insert into leave_items (time_off_id, tutor_id, student_id, enrollment_id, lesson_id, migrated_item_id, starts_at, ends_at, choice, created_by)
    select v_off, p_tutor, n.student_id, n.enrollment_id, n.lesson_id, n.migrated_item_id, n.starts_at, n.ends_at, n.choice, me
    from lms_leave_candidates(p_tutor, p_from, p_to) n
    on conflict do nothing
    returning id, student_id
  )
  insert into lesson_notices (leave_item_id, event, recipient_kind, recipient_id)
  select id, 'leave_options', 'student', student_id from ins;
  return jsonb_build_object('dry_run', false, 'time_off_id', v_off, 'lessons', v_lessons, 'items', v_items, 'students', v_students);
end $$;
revoke all on function admin_leave_create(uuid, date, date, text, boolean) from public, anon;
grant execute on function admin_leave_create(uuid, date, date, text, boolean) to authenticated;

-- ---------------------------------------------------------------------
-- 6. R-10 기존 배정이 있는 신규 매칭: 일정안(schedule_plans) 없이 강사·정규 수업이 이미 있는 등록(시트 이관·수동 배정)의
--    '수업 컨펌 완료' = 지금 배정 내용을 확인하고 학생 안내 완료를 기록 → 업무 완료. 일정안이 있으면 그 카드의 [보냄]으로 (이 함수는 거절)
-- ---------------------------------------------------------------------
create or replace function admin_matching_current(p_enrollment uuid)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  e enrollments;
  a admin_tasks;
begin
  if not is_admin() then raise exception '운영자(추가 인증 완료)만 볼 수 있습니다.' using errcode = '42501'; end if;
  select * into e from enrollments where id = p_enrollment;
  if not found then raise exception '수강등록을 찾지 못했어요.'; end if;
  select * into a from admin_tasks where kind = 'new_student_matching' and enrollment_id = e.id;
  return jsonb_build_object(
    'enrollment_id', e.id,
    'task', case when a.id is null then null else jsonb_build_object('id', a.id, 'status', a.status, 'tutor_assigned_at', a.tutor_assigned_at,
                                                                   'student_notified_at', a.student_notified_at, 'done_at', a.done_at) end,
    'plan', (select jsonb_build_object('id', p.id, 'state', p.state) from schedule_plans p where p.enrollment_id = e.id and p.state in ('proposed', 'confirmed') order by p.created_at desc limit 1),
    'tutor', (select jsonb_build_object('id', t.id, 'name', t.name, 'timezone', t.timezone) from tutors t
              where t.id = coalesce(a.tutor_id, (select l.tutor_id from lessons l where l.enrollment_id = e.id and l.state = 'scheduled' order by l.starts_at limit 1))),
    'slots', coalesce((select jsonb_agg(jsonb_build_object('weekday', rs.weekday, 'time', to_char(rs.start_time_kst, 'HH24:MI')) order by rs.weekday, rs.start_time_kst)
                       from lms_current_slots(e.student_id, greatest(e.start_date, (now() at time zone 'Asia/Seoul')::date)) rs), '[]'::jsonb),
    'scheduled', (select count(*) from lessons l where l.enrollment_id = e.id and l.state = 'scheduled' and l.voided_at is null),
    'first_at', (select min(l.starts_at) from lessons l where l.enrollment_id = e.id and l.state = 'scheduled' and l.voided_at is null),
    'start_date', e.start_date, 'final_end_date', e.final_end_date, 'duration_min', e.duration_min, 'weekly_count', e.weekly_count,
    'lessons_total', e.lessons_purchased + e.lessons_carried_in);
end $$;
revoke all on function admin_matching_current(uuid) from public, anon;
grant execute on function admin_matching_current(uuid) to authenticated;

create or replace function admin_matching_notified(p_enrollment uuid)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  a admin_tasks;
begin
  if not is_admin() then raise exception '운영자(추가 인증 완료)만 처리할 수 있습니다.' using errcode = '42501'; end if;
  select * into a from admin_tasks where kind = 'new_student_matching' and enrollment_id = p_enrollment for update;
  if not found then raise exception '이 등록의 신규 매칭 업무가 없습니다.'; end if;
  if a.status = 'done' then return jsonb_build_object('task_id', a.id, 'repeated', true, 'student_notified_at', a.student_notified_at); end if;
  if a.status <> 'open' then raise exception '이미 닫힌 업무입니다.'; end if;
  if a.tutor_id is null or a.tutor_assigned_at is null then raise exception '강사 배정이 먼저입니다.' using hint = 'assign_first'; end if;
  if exists (select 1 from schedule_plans p where p.enrollment_id = p_enrollment and p.state in ('proposed', 'confirmed')) then
    raise exception '일정안이 있는 등록은 일정안 카드의 [보냄]으로 안내 완료를 기록해 주세요.' using hint = 'has_plan';
  end if;
  if not exists (select 1 from lessons l where l.enrollment_id = p_enrollment and l.tutor_id = a.tutor_id and l.state = 'scheduled' and l.voided_at is null) then
    raise exception '이 강사의 예정된 수업이 없어 컨펌 완료로 기록할 수 없습니다. 먼저 수업(정규 일정)을 만들어 주세요.' using hint = 'no_lessons';
  end if;
  perform set_config('app.actor_id', me::text, true);
  perform set_config('app.actor_via', 'admin_matching_notified', true);
  -- '수업 컨펌 완료' = 강사·학생 양쪽에 지금 배정을 확인함 (일정안 경로의 양쪽 [보냄]과 같은 뜻 — 강사는 이미 배정돼 수업이 있음)
  update admin_tasks set student_notified_at = coalesce(student_notified_at, now()), tutor_notified_at = coalesce(tutor_notified_at, now()),
         status = 'done', done_at = now(), done_by = me
  where id = a.id returning * into a;
  return jsonb_build_object('task_id', a.id, 'repeated', false, 'student_notified_at', a.student_notified_at);
end $$;
revoke all on function admin_matching_notified(uuid) from public, anon;
grant execute on function admin_matching_notified(uuid) to authenticated;

-- ---------------------------------------------------------------------
-- 7. R-06 처리 내역: ④ 시트 '대조 완료' 기록(import_checks.checked_at) + 다시 열기(대조 전으로)
-- ---------------------------------------------------------------------
create or replace function admin_task_history()
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_today date := (now() at time zone 'Asia/Seoul')::date;
begin
  if not is_admin() then raise exception '운영자(추가 인증 완료)만 볼 수 있습니다.' using errcode = '42501'; end if;
  return coalesce((select jsonb_agg(x order by x ->> 'at' desc nulls last) from (
    -- ① 운영진이 [처리 종료]한 카드
    select jsonb_build_object('source', 'closed', 'kind', c.task_kind, 'task_id', c.task_id, 'signature', c.signature, 'at', c.closed_at,
      'by', (select case u.role when 'admin' then '운영자' when 'tutor' then '강사' else u.role end from app_users u where u.auth_user_id = c.closed_by),
      'name', coalesce((select s.name_ko from enrollments e join students s on s.id = e.student_id where c.task_kind = 'ending_soon' and e.id::text = c.task_id),
                       case when c.signature ~ '^\{' then coalesce(c.signature::jsonb ->> 'studentName', c.signature::jsonb ->> 'tutorName') end)) as x
    from admin_task_closures c where c.closed
    union all
    -- ② 종료일 3일 지나 자동으로 빠진 수강기간 종료 임박 (재등록 결제 안 됨, 다시 열지 않음)
    select jsonb_build_object('source', 'auto', 'kind', 'ending_soon', 'task_id', e.id, 'signature', e.id::text,
      'at', ((e.final_end_date + 3)::timestamp at time zone 'Asia/Seoul'), 'by', null, 'name', s.name_ko)
    from enrollments e join students s on s.id = e.student_id
    where e.status in ('active', 'confirmed') and e.final_end_date + 3 <= v_today
      and not exists (select 1 from enrollments n where n.student_id = e.student_id and n.status in ('active', 'confirmed') and n.final_end_date > e.final_end_date)
      and not exists (select 1 from enrollments n where n.previous_enrollment_id = e.id and n.status in ('confirmed', 'active'))
      and not exists (select 1 from admin_task_closures c where c.task_kind = 'ending_soon' and c.task_id = e.id::text)
    union all
    -- ③ [수강 종료]한 수강권
    select jsonb_build_object('source', 'enrollment', 'kind', 'ending_soon', 'task_id', e.id, 'signature', e.id::text,
      'at', h.at, 'by', h.email, 'name', s.name_ko)
    from enrollments e join students s on s.id = e.student_id
    left join lateral (select l.at, (select case u.role when 'admin' then '운영자' else u.role end from app_users u where u.auth_user_id = l.actor) email
                       from audit_log l where l.table_name = 'enrollments' and l.row_id = e.id::text and l.actor_via = 'admin_enrollment_close'
                       order by l.at desc limit 1) h on true
    where e.status = 'completed' and h.at is not null
    union all
    -- ④ 시트 [대조 완료] (R-06, 4520): 누가 언제 완료했는지, 다시 열기 = 대조 전으로
    select jsonb_build_object('source', 'checked', 'kind', 'import_check', 'task_id', c.enrollment_id, 'signature', c.enrollment_id::text,
      'at', c.checked_at, 'by', (select case u.role when 'admin' then '운영자' when 'tutor' then '강사' else u.role end from app_users u where u.auth_user_id = c.checked_by),
      'name', s.name_ko)
    from import_checks c join enrollments e on e.id = c.enrollment_id join students s on s.id = e.student_id
    where c.checked_at is not null
  ) q), '[]'::jsonb);
end $$;
revoke all on function admin_task_history() from public, anon;
grant execute on function admin_task_history() to authenticated;

create or replace function admin_import_unmark_checked(p_enrollment uuid)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  c import_checks;
begin
  if not is_admin() then raise exception '운영자(추가 인증 완료)만 기록할 수 있습니다.' using errcode = '42501'; end if;
  select * into c from import_checks where enrollment_id = p_enrollment for update;
  if not found then raise exception '이관 기록이 없는 수강등록입니다.'; end if;
  if c.checked_at is not null then
    perform set_config('app.actor_id', me::text, true);
    perform set_config('app.actor_via', 'admin_import_unmark_checked', true);
    update import_checks set checked_at = null, checked_by = null where enrollment_id = p_enrollment returning * into c;
  end if;
  return jsonb_build_object('checked_at', c.checked_at, 'checked_by', c.checked_by);
end $$;
revoke all on function admin_import_unmark_checked(uuid) from public, anon;
grant execute on function admin_import_unmark_checked(uuid) to authenticated;

-- ---------------------------------------------------------------------
-- 8. R-05 Google Meet 회의실 주소 검사: https://meet.google.com/xxx-xxxx-xxx (또는 /lookup/…). 홈페이지 주소(meet.google.com/)는 회의실이 아님
--    대체강사 확정(admin_leave_student_ok)은 대체강사의 회의실 링크가 있어야 함 — 학생 화면에 '수업 링크' 로 나가기 때문
-- ---------------------------------------------------------------------
create or replace function lms_meet_url_ok(p_url text) returns boolean
language sql immutable as $$
  select coalesce(p_url, '') ~* '^https://meet\.google\.com/([a-z0-9]{3}-[a-z0-9]{4}-[a-z0-9]{3}|lookup/[A-Za-z0-9_-]+)(\?.*)?$'
$$;
revoke all on function lms_meet_url_ok(text) from public, anon;
grant execute on function lms_meet_url_ok(text) to authenticated;

-- admin_leave_student_ok: 2500 그대로 + 대체강사 Meet 회의실 링크 검사 (R-05)
create or replace function admin_leave_student_ok(p_items uuid[])
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  it leave_items;
  v_conf text;
  v_lesson uuid;
  v_changed integer := 0;
begin
  if not is_admin() then raise exception '운영자(추가 인증 완료)만 처리할 수 있습니다.' using errcode = '42501'; end if;
  perform set_config('app.actor_id', me::text, true);
  perform set_config('app.actor_via', 'admin_leave_student_ok', true);
  for it in select * from leave_items where id = any(p_items) order by starts_at for update loop
    if it.choice <> 'substitute' then raise exception '대체강사를 고른 수업이 아닙니다.'; end if;
    if it.sub_stage = 'confirmed' then continue; end if;
    if it.sub_stage <> 'tutor_ok' then raise exception '대체강사가 가능하다고 한 뒤에 확정할 수 있습니다.'; end if;
    if it.starts_at <= now() then raise exception '% 수업 시간이 지났습니다.', to_char(it.starts_at at time zone 'Asia/Seoul', 'MM/DD'); end if;
    -- R-05 (4520): 학생에게 '수업 링크' 로 나가는 대체강사 Meet 주소가 회의실 주소여야 확정
    if not lms_meet_url_ok((select meet_url from tutors where id = it.sub_tutor_id)) then
      raise exception '대체강사 %의 Google Meet 회의실 링크가 없거나 회의실 주소가 아닙니다 (예: https://meet.google.com/abc-defg-hij). 강사 정보에 링크를 먼저 넣어 주세요.',
        (select name from tutors where id = it.sub_tutor_id) using hint = 'meet_url';
    end if;
    v_conf := lms_sub_conflict(it.sub_tutor_id, it.starts_at, it.ends_at, it.lesson_id);
    if v_conf is not null then
      raise exception '% 수업 시간은 대체강사의 %와 겹칩니다.', to_char(it.starts_at at time zone 'Asia/Seoul', 'MM/DD HH24:MI'), v_conf using hint = 'schedule_conflict';
    end if;
    begin
      if it.lesson_id is not null then
        update lessons set tutor_id = it.sub_tutor_id, original_tutor_id = it.tutor_id where id = it.lesson_id and state = 'scheduled'
        returning id into v_lesson;
        if v_lesson is null then raise exception '% 수업이 이미 처리됐습니다.', to_char(it.starts_at at time zone 'Asia/Seoul', 'MM/DD'); end if;
      else
        insert into lessons (enrollment_id, student_id, tutor_id, original_tutor_id, kind, starts_at, ends_at, created_by)
        values (it.enrollment_id, it.student_id, it.sub_tutor_id, it.tutor_id, 'migrated_makeup', it.starts_at, it.ends_at, me)
        returning id into v_lesson;
        update migrated_items set kind = 'makeup_booked', lesson_id = v_lesson where id = it.migrated_item_id and kind = 'makeup_open';
        if not found then raise exception '% 휴가 보강이 이미 예약됐습니다.', to_char(it.starts_at at time zone 'Asia/Seoul', 'MM/DD'); end if;
      end if;
    exception when exclusion_violation then
      raise exception '% 그 시간에 학생 또는 대체강사의 다른 수업이 있습니다.', to_char(it.starts_at at time zone 'Asia/Seoul', 'MM/DD HH24:MI') using hint = 'schedule_conflict';
    end;
    update lesson_notices set status = 'sent', sent_at = now(), sent_by = me
    where leave_item_id = it.id and event in ('leave_options', 'sub_student') and status = 'pending';
    update leave_items set sub_stage = 'confirmed', sub_lesson_id = v_lesson where id = it.id;
    update lesson_notices set status = 'not_needed', sent_at = null, sent_by = null
    where leave_item_id = it.id and event = 'sub_confirmed' and recipient_id in (it.sub_tutor_id, it.student_id) and status = 'sent';
    -- 학생 OK → 학생·강사 모두에게 최종 확정 안내 (2026-10-27 대표)
    insert into lesson_notices (leave_item_id, event, recipient_kind, recipient_id) values
      (it.id, 'sub_confirmed', 'tutor', it.sub_tutor_id), (it.id, 'sub_confirmed', 'student', it.student_id);
    v_changed := v_changed + 1;
  end loop;
  return jsonb_build_object('changed', v_changed);
end $$;
revoke all on function admin_leave_student_ok(uuid[]) from public, anon;
grant execute on function admin_leave_student_ok(uuid[]) to authenticated;

