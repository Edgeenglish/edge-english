-- =====================================================================
-- 2순위 ①: 강사 휴무·대체강사 (운영진) — 정책 원본 A41·A20, 2026-10-27 대표 시안 승인 (Q1 학생별+일부 날짜 예외, Q2 학생 OK 뒤 확정)
--  - 휴무 넣기 → 그 기간 강사 수업(+ 시트에서 넘어온 휴가 보강)을 휴무 처리 목록(leave_items)으로 모음
--  - 학생 선택지는 둘뿐: 1순위 대체강사가 원래 날짜·시간 / 2순위 기존 강사를 기다렸다가 보강
--  - 대체강사: 강사에게 안내 [보냈어요] → 강사 가능 → 학생 안내 → 학생 OK → 확정 (학생 OK 전에는 수업 강사가 안 바뀜)
--  - 기다림: 수업 결과 'Tutor long-term leave' → 기존 보강 흐름(1700)으로 보강. 변경권 차감 없음
--    보강이 종료일 뒤로 확정되면 마지막 보강일까지만 자동 연장, 날짜가 바뀌면 다시 계산 (A20). 연장된 날 정규 수업 없음
-- 기존 표·데이터를 지우지 않음. 다시 실행해도 같은 결과
-- 숫자: 휴식 10분(POL-OP-21)은 코드 src/lms/rules/policy.ts 와 같아야 함 (자동 테스트)
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. 휴무 처리 목록: 휴무 날짜의 수업 1개(또는 시트 휴가 보강 1개)당 1줄
-- ---------------------------------------------------------------------
create table if not exists leave_items (
  id uuid primary key default gen_random_uuid(),
  time_off_id uuid not null references tutor_time_off(id),
  tutor_id uuid not null references tutors(id),               -- 휴무인 원래 강사
  student_id uuid not null references students(id),
  enrollment_id uuid not null references enrollments(id),
  lesson_id uuid references lessons(id),                       -- 휴무 날짜의 수업
  migrated_item_id uuid references migrated_items(id),         -- 시트에서 넘어온 휴가 보강 (수업이 아직 없음)
  starts_at timestamptz not null,                              -- 원래 수업 시각
  ends_at timestamptz not null,
  choice text not null default 'undecided' check (choice in ('undecided', 'substitute', 'wait')),
  sub_tutor_id uuid references tutors(id),
  sub_stage text check (sub_stage in ('asked', 'tutor_ok', 'confirmed')),
  sub_lesson_id uuid references lessons(id),                   -- 확정된 대체 수업
  decided_at timestamptz,
  decided_by uuid,
  created_by uuid,
  created_at timestamptz not null default now(),
  check ((lesson_id is null) <> (migrated_item_id is null)),
  check (ends_at > starts_at),
  check ((choice = 'substitute') = (sub_tutor_id is not null) and (sub_tutor_id is null) = (sub_stage is null)),
  check ((coalesce(sub_stage, '') = 'confirmed') = (sub_lesson_id is not null)),
  check (sub_tutor_id is distinct from tutor_id)
);
create unique index if not exists leave_items_one_per_lesson on leave_items (lesson_id) where lesson_id is not null;
create unique index if not exists leave_items_one_per_migrated on leave_items (migrated_item_id) where migrated_item_id is not null;
create index if not exists leave_items_time_off on leave_items (time_off_id);
do $$
begin
  if not exists (select 1 from pg_trigger where tgname = 'leave_items_audit') then
    perform lms_protect('leave_items'::regclass);
    create trigger leave_items_no_delete before delete on leave_items for each row execute function forbid_delete();
  end if;
end $$;

-- ---------------------------------------------------------------------
-- 2. 안내 기록: 대체강사 안내 3가지 (sub_ask 대체강사에게 가능 확인 / sub_student 학생에게 대체강사 안내 / sub_confirmed 대체강사에게 확정)
-- ---------------------------------------------------------------------
alter table lesson_notices add column if not exists leave_item_id uuid references leave_items(id);
do $$
declare
  c text;
begin
  if not exists (select 1 from pg_constraint where conname = 'lesson_notices_one_source') then
    for c in select conname from pg_constraint where conrelid = 'lesson_notices'::regclass and contype = 'c'
             and (pg_get_constraintdef(oid) like '%makeup_request_id%' or pg_get_constraintdef(oid) like '%event%') loop
      execute format('alter table lesson_notices drop constraint %I', c);
    end loop;
    alter table lesson_notices add constraint lesson_notices_event_check check (event in (
      'change', 'makeup_ask', 'makeup_confirmed', 'makeup_voided', 'revert', 'sub_ask', 'sub_student', 'sub_confirmed'));
    alter table lesson_notices add constraint lesson_notices_one_source
      check (num_nonnulls(change_request_id, makeup_request_id, leave_item_id) = 1);
    alter table lesson_notices add constraint lesson_notices_change_events
      check ((event in ('change', 'revert')) = (change_request_id is not null));
    alter table lesson_notices add constraint lesson_notices_leave_events
      check ((event in ('sub_ask', 'sub_student', 'sub_confirmed')) = (leave_item_id is not null));
  end if;
end $$;
-- 같은 안내는 한 번 (대체강사를 바꿨다가 다시 고르면 예전 안내는 '보낼 필요 없음'이라 새로 생김)
create unique index if not exists lesson_notices_once_leave on lesson_notices (leave_item_id, event, recipient_id)
  where leave_item_id is not null and status <> 'not_needed';

-- ---------------------------------------------------------------------
-- 3. 강사 휴무 보강 연장 (A20): 자동 연장 줄은 auto_source 로 구분 — 시트에서 넘어온 연장·예외 연장은 건드리지 않음
-- ---------------------------------------------------------------------
alter table enrollment_extensions add column if not exists auto_source text check (auto_source in ('leave_makeup'));

-- 기존 강사를 기다린 보강(휴무 수업의 보강 + 시트 휴가 보강을 예약한 수업) 중 마지막 날까지만 연장.
-- 기준 = '휴가 자동 연장 전' 종료일 → 보강 날짜가 앞당겨지면 연장도 줄어듦
create or replace function lms_leave_sync_extension(p_enrollment uuid) returns void
language plpgsql security definer set search_path = public as $$
declare
  e enrollments;
  v_actor uuid := coalesce(nullif(current_setting('app.actor_id', true), '')::uuid, auth.uid());
  v_pre date;
  v_last date;
  v_cur integer;
  v_target integer;
begin
  select * into e from enrollments where id = p_enrollment for update;
  if not found then return; end if;
  select e.base_end_date + coalesce(sum(days) filter (where auto_source is null), 0)::int,
         coalesce(sum(days) filter (where auto_source = 'leave_makeup'), 0)::int
  into v_pre, v_cur from enrollment_extensions where enrollment_id = e.id;
  select max(x.kst_date) into v_last from lessons x
  where x.enrollment_id = e.id and x.state <> 'canceled'
    and ((x.kind = 'makeup' and exists (select 1 from lessons o where o.id = x.makeup_of and o.class_status = 'Tutor long-term leave'))
      or (x.kind = 'migrated_makeup' and exists (select 1 from migrated_items m where m.lesson_id = x.id and m.tutor_leave)));
  v_target := greatest(coalesce(v_last - v_pre, 0), 0);
  if v_target = v_cur then return; end if;
  if v_actor is null then raise exception '처리한 사람을 알 수 없습니다.'; end if;
  begin
    insert into enrollment_extensions (enrollment_id, days, reason, note, approved_by, auto_source)
    values (e.id, v_target - v_cur, 'tutor_long_term_leave', 'LMS 강사 휴무 보강 자동 연장 (A20)', v_actor, 'leave_makeup');
  exception when exclusion_violation then
    raise exception '다음 수강권 기간과 겹쳐 종료일을 늘릴 수 없습니다. 보강 날짜를 다시 확인해 주세요.' using hint = 'next_enrollment';
  end;
end $$;
revoke all on function lms_leave_sync_extension(uuid) from public, anon, authenticated;

-- 보강이 생기거나 없어지거나 날짜가 바뀌면 다시 계산 (확정·없애기·되돌리기 어느 경로든 같게)
create or replace function lessons_leave_extension() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.kind in ('makeup', 'migrated_makeup') then
    perform lms_leave_sync_extension(new.enrollment_id);
  end if;
  return null;
end $$;
revoke all on function lessons_leave_extension() from public, anon, authenticated;
drop trigger if exists lessons_leave_extension on lessons;
create trigger lessons_leave_extension after insert or update of state, starts_at on lessons
  for each row execute function lessons_leave_extension();

-- ---------------------------------------------------------------------
-- 4. 보강 권리: 강사 휴무로 '기다림'을 고른 수업도 보강 받음 (종료일 제한 없음, A41 ⑦)
--    이관 보강의 강사 = 원래 담당 (대체 수업의 강사가 아님)
-- ---------------------------------------------------------------------
create or replace function lms_makeup_source(p_lesson uuid, p_item uuid, out enrollment_id uuid, out student_id uuid,
                                             out tutor_id uuid, out tutor_leave boolean)
language plpgsql stable security definer set search_path = public as $$
declare
  l lessons;
  it migrated_items;
begin
  if (p_lesson is null) = (p_item is null) then raise exception '보강할 수업을 하나 골라 주세요.'; end if;
  if p_lesson is not null then
    select * into l from lessons where id = p_lesson;
    if not found or not (lms_grants_makeup(l.class_status) or l.class_status = 'Tutor long-term leave') then
      raise exception '보강을 받을 수 있는 수업이 아닙니다.';
    end if;
    if exists (select 1 from lessons x where x.makeup_of = l.id and x.state <> 'canceled') then raise exception '이미 보강이 잡혀 있습니다.'; end if;
    enrollment_id := l.enrollment_id; student_id := l.student_id; tutor_id := l.tutor_id;
    tutor_leave := l.class_status = 'Tutor long-term leave';
  else
    select * into it from migrated_items where id = p_item;
    if not found or it.kind <> 'makeup_open' then raise exception '예약 전 보강이 아닙니다.'; end if;
    select e.student_id into student_id from enrollments e where e.id = it.enrollment_id;
    select coalesce(x.original_tutor_id, x.tutor_id) into tutor_id from lessons x
    where x.enrollment_id = it.enrollment_id and x.voided_at is null order by x.starts_at desc limit 1;
    enrollment_id := it.enrollment_id; tutor_leave := coalesce(it.tutor_leave, false);
  end if;
end $$;
revoke all on function lms_makeup_source(uuid, uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- 5. 대체강사 가능 여부: 그 강사의 다른 수업(휴식 10분 포함)·휴무와 겹치는지. 겹치지 않으면 null
-- ---------------------------------------------------------------------
create or replace function lms_sub_conflict(p_tutor uuid, p_start timestamptz, p_end timestamptz, p_except_lesson uuid)
returns text
language plpgsql stable security definer set search_path = public as $$
declare
  v_break constant interval := interval '10 minutes';   -- POL-OP-21 (policy.ts CONFIRMED.minBreakMin)
begin
  if exists (select 1 from tutor_time_off o where o.tutor_id = p_tutor and o.starts_at < p_end and p_start < o.ends_at) then
    return '강사 휴무';
  end if;
  if exists (select 1 from lessons x where x.tutor_id = p_tutor and x.state <> 'canceled' and x.id is distinct from p_except_lesson
             and x.starts_at < p_end + v_break and p_start - v_break < x.ends_at) then
    return '강사 다른 수업(휴식 10분 포함)';
  end if;
  return null;
end $$;
revoke all on function lms_sub_conflict(uuid, timestamptz, timestamptz, uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- 6. 휴무 넣기 (미리 보기 같은 함수): 휴무 기록 + 걸리는 수업·시트 휴가 보강을 목록으로. 다시 실행하면 새로 생긴 수업만 추가
-- ---------------------------------------------------------------------

-- 휴무 기간(KST 날짜, 양 끝 포함)에 걸리는, 아직 목록에 없는 것
--  · 그 강사의 예정 수업 → '미정'
--  · 시트에서 넘어온 휴가 보강(기존 학생 입력 때 '강사 휴가'로 넣은 것) → 이미 '기다림'. 원래 시각 = 그 요일 고정 시각
create or replace function lms_leave_candidates(p_tutor uuid, p_from date, p_to date)
returns table (lesson_id uuid, migrated_item_id uuid, student_id uuid, enrollment_id uuid, starts_at timestamptz, ends_at timestamptz, choice text)
language sql stable security definer set search_path = public as $$
  select l.id, null::uuid, l.student_id, l.enrollment_id, l.starts_at, l.ends_at, 'undecided'
  from lessons l
  where l.tutor_id = p_tutor and l.state = 'scheduled'
    and l.starts_at < ((p_to + 1)::timestamp at time zone 'Asia/Seoul') and (p_from::timestamp at time zone 'Asia/Seoul') < l.ends_at
    and not exists (select 1 from leave_items i where i.lesson_id = l.id)
  union all
  select null::uuid, m.id, e.student_id, e.id,
         ((m.original_date + rs.start_time_kst) at time zone 'Asia/Seoul'),
         ((m.original_date + rs.start_time_kst) at time zone 'Asia/Seoul') + make_interval(mins => rs.duration_min), 'wait'
  from migrated_items m
  join enrollments e on e.id = m.enrollment_id
  join regular_schedules rs on rs.student_id = e.student_id and rs.tutor_id = p_tutor
   and rs.weekday = extract(dow from m.original_date) and rs.effective_from <= m.original_date
   and (rs.effective_to is null or rs.effective_to >= m.original_date)
  where m.kind = 'makeup_open' and m.tutor_leave and m.original_date between p_from and p_to
    and not exists (select 1 from leave_items i where i.migrated_item_id = m.id)
$$;
revoke all on function lms_leave_candidates(uuid, date, date) from public, anon, authenticated;

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
begin
  if not is_admin() then raise exception '운영자(추가 인증 완료)만 처리할 수 있습니다.' using errcode = '42501'; end if;
  if p_from is null or p_to is null or p_to < p_from then raise exception '휴무 끝일이 시작일보다 빠릅니다.'; end if;
  if not exists (select 1 from tutors where id = p_tutor) then raise exception '강사가 없습니다.'; end if;

  select count(*) filter (where n.lesson_id is not null), count(*), count(distinct n.student_id)
  into v_lessons, v_items, v_students from lms_leave_candidates(p_tutor, p_from, p_to) n;
  if p_dry_run then
    return jsonb_build_object('dry_run', true, 'lessons', v_lessons, 'items', v_items, 'students', v_students,
      'existing', (select count(*) from leave_items i join tutor_time_off o on o.id = i.time_off_id
                   where o.tutor_id = p_tutor and o.starts_at = t0 and o.ends_at = t1));
  end if;

  perform set_config('app.actor_id', me::text, true);
  perform set_config('app.actor_via', 'admin_leave_create', true);
  select id into v_off from tutor_time_off where tutor_id = p_tutor and kind = 'leave' and starts_at = t0 and ends_at = t1;
  if v_off is null then
    insert into tutor_time_off (tutor_id, starts_at, ends_at, kind, reason, created_by)
    values (p_tutor, t0, t1, 'leave', nullif(trim(p_reason), ''), me) returning id into v_off;
  end if;
  insert into leave_items (time_off_id, tutor_id, student_id, enrollment_id, lesson_id, migrated_item_id, starts_at, ends_at, choice, created_by)
  select v_off, p_tutor, n.student_id, n.enrollment_id, n.lesson_id, n.migrated_item_id, n.starts_at, n.ends_at, n.choice, me
  from lms_leave_candidates(p_tutor, p_from, p_to) n
  on conflict do nothing;
  return jsonb_build_object('dry_run', false, 'time_off_id', v_off, 'lessons', v_lessons, 'items', v_items, 'students', v_students);
end $$;
revoke all on function admin_leave_create(uuid, date, date, text, boolean) from public, anon;
grant execute on function admin_leave_create(uuid, date, date, text, boolean) to authenticated;

-- ---------------------------------------------------------------------
-- 7. 대체강사 / 기다림 고르기 (학생별로 여러 줄 한 번에, 일부 날짜만 다르게도 같은 함수)
-- ---------------------------------------------------------------------
create or replace function admin_leave_choose(p_items uuid[], p_choice text, p_sub_tutor uuid)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  it leave_items;
  l lessons;
  v_conf text;
  v_changed integer := 0;
begin
  if not is_admin() then raise exception '운영자(추가 인증 완료)만 처리할 수 있습니다.' using errcode = '42501'; end if;
  if p_choice not in ('substitute', 'wait') then raise exception '대체강사 또는 기다림 중에서 골라 주세요.'; end if;
  if p_choice = 'substitute' and p_sub_tutor is null then raise exception '대체강사를 골라 주세요.'; end if;
  perform set_config('app.actor_id', me::text, true);
  perform set_config('app.actor_via', 'admin_leave_choose', true);

  for it in select * from leave_items where id = any(p_items) order by starts_at for update loop
    if it.choice = p_choice and (p_choice = 'wait' or it.sub_tutor_id = p_sub_tutor) then continue; end if;
    if p_choice = 'substitute' and p_sub_tutor = it.tutor_id then raise exception '휴무인 강사는 대체강사가 될 수 없습니다.'; end if;
    if it.lesson_id is not null then select * into l from lessons where id = it.lesson_id for update; end if;

    -- 지금 상태 풀기
    if it.choice = 'substitute' then
      if it.sub_stage = 'confirmed' then
        if it.lesson_id is not null then
          if l.state <> 'scheduled' then raise exception '% 대체 수업이 이미 진행·변경됐습니다.', to_char(it.starts_at at time zone 'Asia/Seoul', 'MM/DD'); end if;
          begin
            update lessons set tutor_id = it.tutor_id, original_tutor_id = null where id = l.id;
          exception when exclusion_violation then
            raise exception '원래 강사의 그 시간에 다른 수업이 있어 되돌릴 수 없습니다.';
          end;
        else
          update lessons set state = 'canceled', canceled_at = now(), voided_at = now(), voided_by = me, void_note = '대체강사 수업 취소(휴무 처리 변경)'
          where id = it.sub_lesson_id and state = 'scheduled';
          if not found then raise exception '% 대체 수업이 이미 진행·변경됐습니다.', to_char(it.starts_at at time zone 'Asia/Seoul', 'MM/DD'); end if;
          update migrated_items set kind = 'makeup_open', lesson_id = null where id = it.migrated_item_id;
        end if;
      end if;
      update lesson_notices set status = 'not_needed' where leave_item_id = it.id and status = 'pending';
    elsif it.choice = 'wait' and p_choice = 'substitute' then
      if it.lesson_id is not null then
        if exists (select 1 from lessons x where x.makeup_of = l.id and x.state <> 'canceled')
           or exists (select 1 from makeup_requests r where r.source_lesson_id = l.id and r.status in ('requested', 'countered', 'confirmed')) then
          raise exception '% 수업은 보강 신청·확정이 있어 대체강사로 바꿀 수 없습니다. 보강부터 정리해 주세요.', to_char(it.starts_at at time zone 'Asia/Seoul', 'MM/DD');
        end if;
        if l.state = 'canceled' and l.class_status = 'Tutor long-term leave' then
          update lessons set state = 'scheduled', class_status = null, canceled_at = null, cancel_reason = null where id = l.id;
          l.state := 'scheduled';
        end if;
      else
        if exists (select 1 from migrated_items m where m.id = it.migrated_item_id and m.kind <> 'makeup_open')
           or exists (select 1 from makeup_requests r where r.migrated_item_id = it.migrated_item_id and r.status in ('requested', 'countered')) then
          raise exception '% 휴가 보강은 보강 신청·확정이 있어 대체강사로 바꿀 수 없습니다. 보강부터 정리해 주세요.', to_char(it.starts_at at time zone 'Asia/Seoul', 'MM/DD');
        end if;
      end if;
    end if;

    -- 새 상태
    if p_choice = 'wait' then
      if it.lesson_id is not null and l.state = 'scheduled' then
        update lessons set state = 'canceled', class_status = 'Tutor long-term leave', canceled_at = now(), cancel_reason = 'tutor_leave'
        where id = l.id;
      elsif it.lesson_id is not null and l.class_status is distinct from 'Tutor long-term leave' then
        raise exception '% 수업이 이미 처리됐습니다 (%).', to_char(it.starts_at at time zone 'Asia/Seoul', 'MM/DD'), l.class_status;
      end if;
      update leave_items set choice = 'wait', sub_tutor_id = null, sub_stage = null, sub_lesson_id = null, decided_at = now(), decided_by = me
      where id = it.id;
    else
      if it.starts_at <= now() then raise exception '% 수업 시간이 지나 대체강사를 정할 수 없습니다.', to_char(it.starts_at at time zone 'Asia/Seoul', 'MM/DD'); end if;
      if it.lesson_id is not null and l.state <> 'scheduled' then
        raise exception '% 수업이 이미 처리됐습니다 (%).', to_char(it.starts_at at time zone 'Asia/Seoul', 'MM/DD'), l.class_status;
      end if;
      v_conf := lms_sub_conflict(p_sub_tutor, it.starts_at, it.ends_at, it.lesson_id);
      if v_conf is not null then
        raise exception '% 수업 시간은 대체강사의 %와 겹칩니다.', to_char(it.starts_at at time zone 'Asia/Seoul', 'MM/DD HH24:MI'), v_conf using hint = 'schedule_conflict';
      end if;
      update leave_items set choice = 'substitute', sub_tutor_id = p_sub_tutor, sub_stage = 'asked', sub_lesson_id = null,
                             decided_at = now(), decided_by = me
      where id = it.id;
      insert into lesson_notices (leave_item_id, event, recipient_kind, recipient_id) values (it.id, 'sub_ask', 'tutor', p_sub_tutor);
    end if;
    v_changed := v_changed + 1;
  end loop;
  return jsonb_build_object('changed', v_changed);
end $$;
revoke all on function admin_leave_choose(uuid[], text, uuid) from public, anon;
grant execute on function admin_leave_choose(uuid[], text, uuid) to authenticated;

-- 대체강사가 가능하다고 함 → 학생에게 대체강사 안내 (강사가 답했으면 가능 확인 안내는 보낸 것)
create or replace function admin_leave_sub_ok(p_items uuid[])
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  it leave_items;
  v_changed integer := 0;
begin
  if not is_admin() then raise exception '운영자(추가 인증 완료)만 처리할 수 있습니다.' using errcode = '42501'; end if;
  perform set_config('app.actor_id', me::text, true);
  perform set_config('app.actor_via', 'admin_leave_sub_ok', true);
  for it in select * from leave_items where id = any(p_items) order by starts_at for update loop
    if it.choice <> 'substitute' then raise exception '대체강사를 고른 수업이 아닙니다.'; end if;
    if it.sub_stage <> 'asked' then continue; end if;
    update lesson_notices set status = 'sent', sent_at = now(), sent_by = me
    where leave_item_id = it.id and event = 'sub_ask' and status = 'pending';
    update leave_items set sub_stage = 'tutor_ok' where id = it.id;
    insert into lesson_notices (leave_item_id, event, recipient_kind, recipient_id) values (it.id, 'sub_student', 'student', it.student_id);
    v_changed := v_changed + 1;
  end loop;
  return jsonb_build_object('changed', v_changed);
end $$;
revoke all on function admin_leave_sub_ok(uuid[]) from public, anon;
grant execute on function admin_leave_sub_ok(uuid[]) to authenticated;

-- 학생 OK → 확정: 그 수업 강사가 대체강사로 바뀜 (원래 강사는 original_tutor_id). 학생 남은 횟수·종료일 그대로
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
    where leave_item_id = it.id and event = 'sub_student' and status = 'pending';
    update leave_items set sub_stage = 'confirmed', sub_lesson_id = v_lesson where id = it.id;
    insert into lesson_notices (leave_item_id, event, recipient_kind, recipient_id) values (it.id, 'sub_confirmed', 'tutor', it.sub_tutor_id);
    v_changed := v_changed + 1;
  end loop;
  return jsonb_build_object('changed', v_changed);
end $$;
revoke all on function admin_leave_student_ok(uuid[]) from public, anon;
grant execute on function admin_leave_student_ok(uuid[]) to authenticated;

-- 대체강사 고르기 목록: 강사마다 고른 수업 중 몇 회가 비어 있는지
create or replace function admin_leave_sub_options(p_items uuid[])
returns table (tutor_id uuid, name text, timezone text, free integer, busy_dates text[])
language plpgsql stable security definer set search_path = public as $$
begin
  if not is_admin() then raise exception '운영자(추가 인증 완료)만 볼 수 있습니다.' using errcode = '42501'; end if;
  return query
  select t.id, t.name, t.timezone,
         count(*) filter (where lms_sub_conflict(t.id, i.starts_at, i.ends_at, i.lesson_id) is null)::int,
         coalesce(array_agg(to_char(i.starts_at at time zone 'Asia/Seoul', 'FMMM/FMDD') order by i.starts_at)
                  filter (where lms_sub_conflict(t.id, i.starts_at, i.ends_at, i.lesson_id) is not null), '{}')
  from tutors t cross join leave_items i
  where i.id = any(p_items) and t.id <> i.tutor_id and t.active
  group by t.id, t.name, t.timezone
  order by 4 desc, t.name;
end $$;
revoke all on function admin_leave_sub_options(uuid[]) from public, anon;
grant execute on function admin_leave_sub_options(uuid[]) to authenticated;
