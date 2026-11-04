-- =====================================================================
-- 4510. 강사 휴무 철회 (Work QA 11/4 QA-17: 날짜·강사를 잘못 넣은 휴무를 되돌릴 화면 경로가 없음)
--  - admin_leave_withdraw(p_time_off, p_note, p_dry_run): 영향 미리 보기 → 사유 필수 → 철회
--    · 확정된 대체 수업 → 원래 강사로 되돌림(1800 lms_leave_unconfirm) · 대체 묻기/가능 단계 → 비움
--    · '기존 강사 보강' 으로 취소된 수업(Tutor long-term leave) → 다시 예정. 보강 신청·확정이 이미 있으면 철회 거절(보강부터 정리)
--    · 지난 수업(이미 시작·진행)이 걸려 있으면 거절 — 과거·완료 수업은 되돌리지 않음
--    · 안내 기록은 '보낼 필요 없음' 으로(보낸 시각은 was_sent_at 에 남음), 휴무 줄·수업 줄은 지우지 않음
--  - 표에서 지우지 않음: leave_items 는 삭제 금지(1800) → withdrawn_at 표시 + lesson_gone_at(닫힘 표시, 기존 화면이 모두 이 칸으로 거름)
--    tutor_time_off 는 기간을 효력 없는 날짜(1900-01-01, 4300 과 같은 방식)로 치우고 withdrawn_at·원래 기간·사유를 남김 → 충돌 판정·Schedule·휴무 목록에서 자동으로 빠짐
--  - 같은 수업을 나중에 다시 휴무에 넣을 수 있게: lms_leave_candidates 는 철회된 줄을 없는 것으로 보고, admin_leave_create 는 철회된 줄을 되살려 씀(수업당 한 줄 규칙 그대로)
--  - 3200 lessons_leave_gone 트리거는 철회된 줄을 다시 열지 않음
-- 기존 표·데이터를 지우지 않음. 다시 실행해도 같은 결과
-- =====================================================================

alter table leave_items add column if not exists withdrawn_at timestamptz;
alter table tutor_time_off add column if not exists withdrawn_at timestamptz;
alter table tutor_time_off add column if not exists withdrawn_by uuid;
alter table tutor_time_off add column if not exists withdraw_note text;
alter table tutor_time_off add column if not exists withdrawn_range tstzrange;

-- 3200 그대로 + 철회된 줄은 건드리지 않음
create or replace function lessons_leave_gone() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  update leave_items i
  set lesson_gone_at = case when lms_lesson_gone(new) then coalesce(i.lesson_gone_at, now()) end
  where (i.lesson_id = new.id or i.sub_lesson_id = new.id)
    and i.withdrawn_at is null
    and (i.lesson_gone_at is null) = lms_lesson_gone(new);
  return null;
end $$;
revoke all on function lessons_leave_gone() from public, anon, authenticated;

-- 1800 그대로 + 철회된 줄은 없는 것으로 (다시 휴무에 넣을 수 있음)
create or replace function lms_leave_candidates(p_tutor uuid, p_from date, p_to date)
returns table (lesson_id uuid, migrated_item_id uuid, student_id uuid, enrollment_id uuid, starts_at timestamptz, ends_at timestamptz, choice text)
language sql stable security definer set search_path = public as $$
  select l.id, null::uuid, l.student_id, l.enrollment_id, l.starts_at, l.ends_at, 'undecided'
  from lessons l
  where l.tutor_id = p_tutor and l.state = 'scheduled'
    and l.starts_at < ((p_to + 1)::timestamp at time zone 'Asia/Seoul') and (p_from::timestamp at time zone 'Asia/Seoul') < l.ends_at
    and not exists (select 1 from leave_items i where i.lesson_id = l.id and i.withdrawn_at is null)
  union all
  select null::uuid, m.id, e.student_id, e.id,
         ((m.original_date + rs.start_time_kst) at time zone 'Asia/Seoul'),
         ((m.original_date + rs.start_time_kst) at time zone 'Asia/Seoul') + make_interval(mins => rs.duration_min), 'undecided'
  from migrated_items m
  join enrollments e on e.id = m.enrollment_id
  join regular_schedules rs on rs.student_id = e.student_id and rs.tutor_id = p_tutor
   and rs.weekday = extract(dow from m.original_date) and rs.effective_from <= m.original_date
   and (rs.effective_to is null or rs.effective_to >= m.original_date)
  where m.kind = 'makeup_open' and m.tutor_leave and m.original_date between p_from and p_to
    and not exists (select 1 from leave_items i where i.migrated_item_id = m.id and i.withdrawn_at is null)
$$;
revoke all on function lms_leave_candidates(uuid, date, date) from public, anon, authenticated;

-- 1800 그대로 + 철회된 줄 되살리기
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
                   where o.tutor_id = p_tutor and o.starts_at = t0 and o.ends_at = t1 and o.withdrawn_at is null and i.withdrawn_at is null));
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
-- 휴무 철회: p_dry_run = 영향 미리 보기(바꾸지 않음). 사유 필수(철회 때)
-- ---------------------------------------------------------------------
create or replace function admin_leave_withdraw(p_time_off uuid, p_note text, p_dry_run boolean default true)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  o tutor_time_off;
  it leave_items;
  l lessons;
  v_note text := nullif(btrim(coalesce(p_note, '')), '');
  v_sub_back integer := 0;    -- 확정된 대체 수업 → 원래 강사
  v_ask_clear integer := 0;   -- 대체 묻기·가능 단계 비움
  v_wait_back integer := 0;   -- 보강 기다림 수업 → 다시 예정
  v_untouched integer := 0;   -- 미정 그대로 / 밖에서 취소된 수업
  v_notices integer := 0;
  v_block text[] := '{}';
  v_when text;
  v_ids uuid[] := '{}';
begin
  if not is_admin() then raise exception '운영자(추가 인증 완료)만 처리할 수 있습니다.' using errcode = '42501'; end if;
  select * into o from tutor_time_off where id = p_time_off for update;
  if not found or o.kind <> 'leave' then raise exception '휴무가 없습니다.'; end if;
  if o.withdrawn_at is not null then return jsonb_build_object('repeated', true, 'withdrawn_at', o.withdrawn_at); end if;

  for it in select * from leave_items where time_off_id = o.id and withdrawn_at is null order by starts_at loop
    v_ids := v_ids || it.id;
    v_when := to_char(it.starts_at at time zone 'Asia/Seoul', 'MM/DD HH24:MI');
    if it.lesson_gone_at is not null then v_untouched := v_untouched + 1; continue; end if;
    if it.lesson_id is not null then
      select * into l from lessons where id = it.lesson_id;
      if l.state = 'done' or (l.starts_at <= now() and l.state <> 'canceled') then
        v_block := v_block || format('%s 수업은 이미 시작·진행됐어요 (되돌리지 않음)', v_when); continue;
      end if;
    end if;
    if it.choice = 'substitute' then
      if it.sub_stage = 'confirmed' then
        if it.lesson_id is not null and l.state <> 'scheduled' then v_block := v_block || format('%s 대체 수업이 이미 진행·변경됐어요', v_when); continue; end if;
        v_sub_back := v_sub_back + 1;
      else
        v_ask_clear := v_ask_clear + 1;
      end if;
    elsif it.choice = 'wait' then
      if it.lesson_id is not null then
        if exists (select 1 from lessons x where x.makeup_of = l.id and x.state <> 'canceled')
           or exists (select 1 from makeup_requests r where r.source_lesson_id = l.id and r.status in ('requested', 'countered', 'confirmed')) then
          v_block := v_block || format('%s 수업은 보강 신청·확정이 있어요 — 보강부터 정리해 주세요', v_when); continue;
        end if;
        if l.state = 'canceled' and l.class_status = 'Tutor long-term leave' then v_wait_back := v_wait_back + 1; else v_untouched := v_untouched + 1; end if;
      else
        if exists (select 1 from migrated_items m where m.id = it.migrated_item_id and m.kind <> 'makeup_open')
           or exists (select 1 from makeup_requests r where r.migrated_item_id = it.migrated_item_id and r.status in ('requested', 'countered')) then
          v_block := v_block || format('%s 휴가 보강은 보강 신청·확정이 있어요 — 보강부터 정리해 주세요', v_when); continue;
        end if;
        v_untouched := v_untouched + 1;
      end if;
    else
      v_untouched := v_untouched + 1;
    end if;
  end loop;
  select count(*) into v_notices from lesson_notices where leave_item_id = any(v_ids) and status = 'pending';

  if p_dry_run or cardinality(v_block) > 0 then
    if not p_dry_run then
      raise exception '철회할 수 없어요: %', array_to_string(v_block, ' / ') using hint = 'blocked';
    end if;
    return jsonb_build_object('dry_run', true, 'items', cardinality(v_ids), 'sub_back', v_sub_back, 'ask_clear', v_ask_clear, 'wait_back', v_wait_back,
      'untouched', v_untouched, 'notices_pending', v_notices, 'blockers', to_jsonb(v_block),
      'from', (o.starts_at at time zone 'Asia/Seoul')::date, 'to', ((o.ends_at - interval '1 second') at time zone 'Asia/Seoul')::date);
  end if;
  if v_note is null then raise exception '철회 사유를 적어 주세요.' using hint = 'reason'; end if;

  perform set_config('app.actor_id', me::text, true);
  perform set_config('app.actor_via', 'admin_leave_withdraw', true);
  for it in select * from leave_items where id = any(v_ids) order by starts_at loop
    if it.lesson_gone_at is null then
      if it.choice = 'substitute' and it.sub_stage = 'confirmed' then
        perform lms_leave_unconfirm(it, me);
      elsif it.choice = 'wait' and it.lesson_id is not null then
        select * into l from lessons where id = it.lesson_id for update;
        if l.state = 'canceled' and l.class_status = 'Tutor long-term leave' then
          begin
            update lessons set state = 'scheduled', class_status = null, canceled_at = null, cancel_reason = null where id = l.id;
          exception when exclusion_violation then
            raise exception '% 그 시간에 다른 수업이 있어 되돌릴 수 없습니다.', to_char(it.starts_at at time zone 'Asia/Seoul', 'MM/DD HH24:MI');
          end;
        end if;
      end if;
    end if;
    -- 안내는 모두 '보낼 필요 없음' (보낸 것은 was_sent_at 에 남음, 3400). 줄은 닫힘(lesson_gone_at) + 철회 표시
    update lesson_notices set status = 'not_needed', sent_at = null, sent_by = null where leave_item_id = it.id and status in ('pending', 'sent');
    update leave_items set choice = 'undecided', sub_tutor_id = null, sub_stage = null, sub_lesson_id = null, decided_at = null, decided_by = null,
                           lesson_gone_at = coalesce(lesson_gone_at, now()), withdrawn_at = now()
    where id = it.id;
  end loop;
  update tutor_time_off
  set withdrawn_range = tstzrange(starts_at, ends_at), starts_at = timestamptz '1900-01-01 00:00:00+09', ends_at = timestamptz '1900-01-01 00:00:01+09',
      withdrawn_at = now(), withdrawn_by = me, withdraw_note = v_note
  where id = o.id;
  return jsonb_build_object('dry_run', false, 'items', cardinality(v_ids), 'sub_back', v_sub_back, 'ask_clear', v_ask_clear, 'wait_back', v_wait_back,
    'untouched', v_untouched, 'notices_pending', v_notices, 'repeated', false);
end $$;
revoke all on function admin_leave_withdraw(uuid, text, boolean) from public, anon;
grant execute on function admin_leave_withdraw(uuid, text, boolean) to authenticated;
