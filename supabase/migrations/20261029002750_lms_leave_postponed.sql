-- =====================================================================
-- 강사 장기휴무로 못 들은 수업 = '휴무로 미뤄진 수업' (2026-10-28 대표 확정, ChatGPT 상의안 반영)
--  - 일반 보강: 그대로 '보강', 원래 수강기간 종료일까지만
--  - 휴무로 미뤄진 수업: 원래 종료일 뒤에도 진행 가능 (A20 자동 연장 줄 auto_source='leave_makeup' 은 그대로 둠 — 기록 변경 없음)
--  - 재등록·결제 마감(이월 POL-RN-01·고정 시간 맡아 두기 POL-RN-02)과 일반 보강 기한 = 원래 종료일
--    원래 종료일 = base_end_date + 휴무 자동 연장이 아닌 연장(시트에서 넘어온 연장·예외 연장 포함) — final_end_date 는 그대로 둠
--  - 다음 수강권 정규 수업은 이전 수강권의 휴무로 미뤄진 수업을 마친 뒤부터 (정규 수업 넣을 때 DB가 막음)
--  - 함수 내용은 기존과 같고 종료일 기준만 바꿈: lms_slot_hold_hits · admin_leave_renewal_pending · admin_makeup_confirm · lms_change_core(보강 기한 안내)
-- 기존 표·데이터를 지우거나 바꾸지 않음. 다시 실행해도 같은 결과
-- =====================================================================

-- 원래 수강기간 종료일 (휴무로 미뤄진 수업 때문에 늘어난 날 제외)
create or replace function lms_original_end(p_enrollment uuid) returns date
language sql stable security definer set search_path = public as $$
  select e.base_end_date + coalesce((select sum(x.days) from enrollment_extensions x
                                     where x.enrollment_id = e.id and x.auto_source is null), 0)::int
  from enrollments e where e.id = p_enrollment
$$;
revoke all on function lms_original_end(uuid) from public, anon, authenticated;

-- 휴무로 미뤄진 수업인지: 강사 장기휴무로 취소된 수업의 보강, 또는 시트에서 넘어온 강사 휴가 보강을 예약한 수업
create or replace function lms_is_leave_postponed(p_lesson uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from lessons l join lessons o on o.id = l.makeup_of
                 where l.id = p_lesson and o.class_status = 'Tutor long-term leave')
      or exists (select 1 from migrated_items m where m.lesson_id = p_lesson and m.tutor_leave)
$$;
revoke all on function lms_is_leave_postponed(uuid) from public, anon, authenticated;

-- 다음 정규 수업을 시작할 수 있는 첫날: 원래 종료일 다음 날, 휴무로 미뤄진 수업이 그 뒤에 잡혀 있으면 마지막 수업 다음 날
-- 날짜를 아직 안 잡은 휴무로 미뤄진 수업이 있으면 null (날짜부터 잡아야 함)
create or replace function lms_next_regular_from(p_enrollment uuid) returns date
language sql stable security definer set search_path = public as $$
  select case
    when exists (select 1 from lessons l where l.enrollment_id = p_enrollment and l.voided_at is null and l.class_status = 'Tutor long-term leave'
                 and not exists (select 1 from lessons x where x.makeup_of = l.id and x.state <> 'canceled'))
      or exists (select 1 from migrated_items m where m.enrollment_id = p_enrollment and m.kind = 'makeup_open' and m.tutor_leave)
    then null
    else greatest(lms_original_end(p_enrollment),
                  coalesce((select max((l.starts_at at time zone 'Asia/Seoul')::date) from lessons l
                            where l.enrollment_id = p_enrollment and l.state <> 'canceled' and l.voided_at is null and lms_is_leave_postponed(l.id)),
                           lms_original_end(p_enrollment))) + 1 end
$$;
revoke all on function lms_next_regular_from(uuid) from public, anon, authenticated;

-- 다음 수강권 정규 수업이 이전 수강권의 휴무로 미뤄진 수업보다 먼저 생기지 않게
create or replace function lessons_after_leave_postponed() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  prev uuid;
  v_from date;
begin
  if new.kind <> 'regular' then return new; end if;
  select e.previous_enrollment_id into prev from enrollments e where e.id = new.enrollment_id;
  if prev is null then return new; end if;
  if not exists (select 1 from lessons l where l.enrollment_id = prev and lms_is_leave_postponed(l.id))
     and not exists (select 1 from lessons l where l.enrollment_id = prev and l.class_status = 'Tutor long-term leave')
     and not exists (select 1 from migrated_items m where m.enrollment_id = prev and m.tutor_leave) then
    return new;   -- 휴무로 미뤄진 수업이 없던 수강권은 그대로
  end if;
  v_from := lms_next_regular_from(prev);
  if v_from is null then
    raise exception '이전 수강권에 날짜를 안 잡은 휴무로 미뤄진 수업이 있어요. 그 날짜를 먼저 잡아 주세요.' using hint = 'leave_postponed_open';
  end if;
  if (new.starts_at at time zone 'Asia/Seoul')::date < v_from then
    raise exception '다음 정규 수업은 휴무로 미뤄진 수업을 마친 뒤(%부터) 시작할 수 있어요.', v_from using hint = 'leave_postponed_first';
  end if;
  return new;
end $$;
revoke all on function lessons_after_leave_postponed() from public, anon, authenticated;
drop trigger if exists lessons_after_leave_postponed on lessons;
create trigger lessons_after_leave_postponed before insert on lessons for each row execute function lessons_after_leave_postponed();

create or replace function lms_slot_hold_hits(p_tutor uuid, p_start timestamptz, p_end timestamptz)
returns table (student_id uuid, student_name text, hold_end date, o0 timestamptz, o1 timestamptz)
language sql stable security definer set search_path = public as $$
  with last_end as (
    select e.student_id, max(lms_original_end(e.id)) as end_date
    from enrollments e
    where e.status in ('confirmed', 'active')
    group by e.student_id
  ), day as (
    select ((p_start at time zone 'Asia/Seoul')::date) as d
  )
  select rs.student_id, st.name_ko, le.end_date, x.o0, x.o0 + make_interval(mins => rs.duration_min)
  from regular_schedules rs
  join last_end le on le.student_id = rs.student_id
  join students st on st.id = rs.student_id
  cross join day
  cross join lateral (select ((day.d + rs.start_time_kst) at time zone 'Asia/Seoul') as o0) x
  where rs.tutor_id = p_tutor
    and day.d > le.end_date                                                   -- 종료일 뒤 날짜만 (안쪽은 실제 수업이 막음)
    and extract(dow from day.d)::int = rs.weekday
    and rs.effective_from <= le.end_date and (rs.effective_to is null or rs.effective_to >= le.end_date)
    and now() < ((le.end_date + 1)::timestamp at time zone 'Asia/Seoul')     -- 종료일 23:59 KST까지
    and x.o0 < p_end + interval '10 minutes' and p_start - interval '10 minutes' < x.o0 + make_interval(mins => rs.duration_min)
$$;
revoke all on function lms_slot_hold_hits(uuid, timestamptz, timestamptz) from public, anon, authenticated;

create or replace function admin_leave_renewal_pending(p_time_off uuid)
returns table (student_id uuid, student_name text, student_code text, end_date date, starts_at timestamptz, duration_min integer)
language plpgsql stable security definer set search_path = public as $$
declare
  o tutor_time_off;
begin
  if not is_admin() then raise exception '운영자(추가 인증 완료)만 볼 수 있습니다.' using errcode = '42501'; end if;
  select * into o from tutor_time_off where id = p_time_off;
  if not found then return; end if;
  return query
  with last_end as (
    select e.student_id, max(lms_original_end(e.id)) as end_date
    from enrollments e
    where e.status in ('confirmed', 'active')
    group by e.student_id
  )
  select rs.student_id, st.name_ko, st.code, le.end_date, ((d::date + rs.start_time_kst) at time zone 'Asia/Seoul'), rs.duration_min::integer
  from regular_schedules rs
  join last_end le on le.student_id = rs.student_id
  join students st on st.id = rs.student_id
  cross join lateral generate_series(greatest((o.starts_at at time zone 'Asia/Seoul')::date, le.end_date + 1),
                                     (o.ends_at at time zone 'Asia/Seoul')::date - 1, interval '1 day') d
  where rs.tutor_id = o.tutor_id
    and extract(dow from d)::int = rs.weekday
    and rs.effective_from <= le.end_date and (rs.effective_to is null or rs.effective_to >= le.end_date)
    and now() < ((le.end_date + 1)::timestamp at time zone 'Asia/Seoul')
  order by 2, 5;
end $$;
revoke all on function admin_leave_renewal_pending(uuid) from public, anon;
grant execute on function admin_leave_renewal_pending(uuid) to authenticated;

create or replace function admin_makeup_confirm(p_makeup_request uuid, p_starts_at timestamptz)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  r makeup_requests;
  s record;
  e enrollments;
  v_end timestamptz;
  v_lesson uuid;
  v_conf text;
begin
  if not is_admin() then raise exception '운영자(추가 인증 완료)만 처리할 수 있습니다.' using errcode = '42501'; end if;
  select * into r from makeup_requests where id = p_makeup_request for update;
  if not found then raise exception '보강 신청이 없습니다.'; end if;
  if r.status = 'confirmed' then return jsonb_build_object('makeup_request_id', r.id, 'lesson_id', r.confirmed_lesson_id, 'repeated', true); end if;
  if r.status not in ('requested', 'countered') then raise exception '이미 닫힌 보강 신청입니다.'; end if;
  select * into s from lms_makeup_source(r.source_lesson_id, r.migrated_item_id);
  select * into e from enrollments where id = s.enrollment_id;
  if p_starts_at <= now() then raise exception '지난 시간은 보강으로 넣을 수 없습니다.'; end if;
  if not s.tutor_leave and p_starts_at >= ((lms_original_end(e.id) + 1)::timestamp at time zone 'Asia/Seoul') then
    raise exception '수강 종료일(%) 뒤의 시간입니다.', lms_original_end(e.id) using hint = 'after_end';
  end if;
  v_end := p_starts_at + make_interval(mins => e.duration_min);
  v_conf := lms_makeup_conflict(r.tutor_id, s.student_id, p_starts_at, v_end,
              exists (select 1 from makeup_candidates c where c.request_id = r.id and c.starts_at = p_starts_at and c.proposed_by = 'student'));
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
  end if;
  update makeup_requests set status = 'confirmed', confirmed_lesson_id = v_lesson, decided_at = now(), decided_by = me where id = r.id;
  update lesson_notices set status = 'not_needed' where makeup_request_id = r.id and event = 'makeup_ask' and status = 'pending';
  insert into lesson_notices (makeup_request_id, event, recipient_kind, recipient_id)
  values (r.id, 'makeup_confirmed', 'student', s.student_id), (r.id, 'makeup_confirmed', 'tutor', r.tutor_id);
  return jsonb_build_object('makeup_request_id', r.id, 'lesson_id', v_lesson, 'repeated', false);
end $$;
revoke all on function admin_makeup_confirm(uuid, timestamptz) from public, anon;
grant execute on function admin_makeup_confirm(uuid, timestamptz) to authenticated;

create or replace function lms_change_core(p_key text, p_lesson uuid, p_who text, p_via text,
                                           p_requested_at timestamptz, p_dry_run boolean, p_actor uuid)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_notice constant interval := interval '6 hours';   -- POL-CHG-01 (policy.ts CONFIRMED.changeNoticeHours)
  v_reward constant integer := 2000;                  -- POL-TU-04 (policy.ts FAVORABLE_FOR_ALL.tutorLateCancelRewardWon)
  l lessons;
  e enrollments;
  prev change_requests;
  v_period uuid;
  v_left integer;
  v_advance boolean;
  v_holiday boolean;
  v_status class_status;
  v_uses boolean := false;
  v_reward_won integer := 0;
  v_refs text[];
  v_cr uuid;
  out jsonb;
begin
  if p_who not in ('student', 'tutor') then raise exception '요청한 사람이 올바르지 않습니다.'; end if;
  if p_requested_at is null then raise exception '요청 받은 시각을 넣어 주세요.'; end if;
  if p_requested_at > now() then raise exception '요청 받은 시각이 지금보다 늦습니다.'; end if;

  if not p_dry_run then
    select * into prev from change_requests where idempotency_key = p_key;
    if found then
      return (prev.decision || jsonb_build_object('change_request_id', prev.id, 'repeated', true, 'dry_run', false));
    end if;
  end if;

  select * into l from lessons where id = p_lesson for update;
  if not found then raise exception '수업이 없습니다.'; end if;
  if l.state <> 'scheduled' then
    raise exception '이미 처리된 수업입니다 (%).', coalesce(l.class_status::text, '되돌린 보강') using hint = 'not_scheduled';
  end if;
  if p_requested_at >= l.starts_at then raise exception '수업 시작 뒤에 받은 요청이라 변경할 수 없습니다.' using hint = 'already_started'; end if;
  if l.kind = 'compensation' then raise exception '보상 수업 변경 규칙은 아직 정해지지 않았습니다 (POL-TU-10).'; end if;
  select * into e from enrollments where id = l.enrollment_id;
  if l.starts_at >= ((e.final_end_date + 1)::timestamp at time zone 'Asia/Seoul') and p_who = 'student' then
    raise exception '수강기간 밖의 수업입니다.' using hint = 'outside_enrollment';
  end if;

  v_advance := l.starts_at - p_requested_at >= v_notice;
  v_period := lms_lesson_period(e.id, l.kst_date);
  v_left := case when v_period is null then 0 else credit_balance(v_period) end;
  v_holiday := exists (select 1 from holidays where day = l.kst_date);

  if p_who = 'tutor' then
    -- 강사 사유: 학생 변경권은 절대 차감하지 않음. 6시간 미만이면 학생 적립금 (A15·A16)
    v_status := case when v_advance then 'Tutor canceled in advance' else 'Tutor canceled late' end;
    v_reward_won := case when v_advance then 0 else v_reward end;
    v_refs := array['POL-TU-04', 'POL-TU-05'];
  elsif not v_advance then
    v_status := 'Student canceled late';
    v_refs := array['POL-CHG-01', 'POL-CHG-02'];
  elsif v_holiday then
    v_status := 'Student canceled in advance (public holiday)';
    v_refs := array['POL-CHG-01', 'POL-CHG-06'];
  elsif v_left <= 0 then
    v_status := 'No change credits left';
    v_refs := array['POL-CHG-01', 'POL-CHG-04'];
  else
    v_status := 'Student canceled in advance';
    v_uses := true;
    v_refs := array['POL-CHG-01', 'POL-CHG-03'];
  end if;
  if l.kind <> 'regular' then v_refs := v_refs || array['POL-CHG-08']; end if;   -- 보강·추가 수업도 정규와 같은 규칙 (A03)

  out := jsonb_build_object(
    'lesson_id', l.id, 'who', p_who, 'status', v_status, 'timing', case when v_advance then 'advance' else 'late' end,
    'requested_at', p_requested_at, 'starts_at', l.starts_at,
    'hours_before', round(extract(epoch from (l.starts_at - p_requested_at)) / 3600.0, 1),
    'uses_credit', v_uses, 'credits_left', v_left, 'credits_after', v_left - case when v_uses then 1 else 0 end,
    'makeup_allowed', lms_grants_makeup(v_status), 'makeup_until', case when lms_grants_makeup(v_status) then lms_original_end(e.id) end,
    'reward_won', v_reward_won, 'holiday', v_holiday);
  if p_dry_run then return out || jsonb_build_object('dry_run', true, 'repeated', false); end if;

  if exists (select 1 from change_requests where lesson_id = l.id and status = 'applied'
             and type in ('student_cancel', 'tutor_cancel', 'admin_cancel')) then
    raise exception '이 수업에 이미 적용된 변경이 있습니다.' using hint = 'not_scheduled';
  end if;

  perform set_config('app.actor_id', coalesce(p_actor::text, ''), true);
  perform set_config('app.actor_via', 'lms_change_core', true);
  insert into change_requests (lesson_id, student_id, tutor_id, type, status, via, policy_refs, decision,
                               idempotency_key, requested_by, decided_by, decided_at, requested_at)
  values (l.id, l.student_id, l.tutor_id, case when p_who = 'tutor' then 'tutor_cancel' else 'student_cancel' end,
          'applied', p_via, v_refs, out, p_key, p_actor, p_actor, now(), p_requested_at)
  returning id into v_cr;
  update lessons set state = 'canceled', class_status = v_status, canceled_at = now(),
                     cancel_reason = case when p_who = 'tutor' then 'tutor' else 'student' end
  where id = l.id;
  if v_uses then
    insert into credit_ledger (period_id, lesson_id, change_request_id, reason, delta, created_by)
    values (v_period, l.id, v_cr, 'student_change', -1, p_actor);
  end if;
  if v_reward_won > 0 then
    insert into reward_ledger (student_id, kind, amount, lesson_id, change_request_id, created_by)
    values (l.student_id, 'grant_tutor_late_cancel', v_reward_won, l.id, v_cr, p_actor);
  end if;
  insert into lesson_notices (change_request_id, event, recipient_kind, recipient_id)
  values (v_cr, 'change', 'student', l.student_id), (v_cr, 'change', 'tutor', l.tutor_id);
  return out || jsonb_build_object('change_request_id', v_cr, 'dry_run', false, 'repeated', false);
end $$;
revoke all on function lms_change_core(text, uuid, text, text, timestamptz, boolean, uuid) from public, anon, authenticated;
