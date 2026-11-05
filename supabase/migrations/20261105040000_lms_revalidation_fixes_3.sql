-- =====================================================================
-- 4540 Work 3차 재검증(b16c683) R-25 보완 — 시험용 DB 먼저, 운영 DB 는 대표 승인 뒤
--  예약 불가 사유가 겹칠 때 먼저 풀어야 하는 제약부터: 휴무 → 다른 수업(휴식 10분) → 현지 06:00~22:30 → 강사가 열지 않은 시간 → 연속 수업 규칙
--  (전에는 '열지 않은 시간' 을 휴무보다 먼저 봐서, 휴무 중인 닫힌 시간에 '시간을 열라' 고 안내했음)
--  강사 '가능' 답 거절 문구도 사유별 영어 문장(lms_conflict_message_en)
-- 지우는 문장 없음. 다시 실행해도 같은 결과
-- =====================================================================

create or replace function lms_conflict_message_en(p_text text) returns text
language sql immutable as $$
  select case lms_conflict_code(p_text)
    when 'leave' then 'You are on leave at this time.'
    when 'busy' then 'You have another class at this time (10-minute break included).'
    when 'hours' then 'Outside class hours (06:00–22:30 your local time).'
    when 'closed' then 'This time is not in your open hours. Open it in Schedule first, then answer again.'
    when 'b2b' then 'Too many classes in a row without a break.'
    else 'This time is not available.' end
$$;
revoke all on function lms_conflict_message_en(text) from public, anon, authenticated;

-- 4500 그대로 + 검사 순서만 (휴무·다른 수업·시작 가능 시간·열지 않은 시간·연속 규칙)
create or replace function lms_makeup_conflict(p_tutor uuid, p_student uuid, p_start timestamptz, p_end timestamptz, p_student_wants boolean)
returns text
language plpgsql stable security definer set search_path = public as $$
declare
  v_break constant interval := interval '10 minutes';      -- POL-OP-21 (policy.ts CONFIRMED.minBreakMin)
  v_b2b_min constant integer := 20;                         -- POL-OP-21 예외 (policy.ts CONFIRMED.backToBackNoBreakDurationMin)
  v_b2b_max constant integer := 2;                          -- POL-OP-21 예외 (policy.ts CONFIRMED.backToBackNoBreakMaxLessons)
  v_new_b2b boolean := p_student_wants and p_end - p_start = make_interval(mins => v_b2b_min);
  v_near uuid[];
  v_chain integer;
begin
  -- 1) 강사 휴무 (열어도 소용없음)
  if exists (select 1 from tutor_time_off o where o.tutor_id = p_tutor and o.kind = 'leave' and o.starts_at < p_end and p_start < o.ends_at) then
    return '강사 휴무';
  end if;
  -- 2) 강사 다른 수업 (휴식 10분 포함, 같은 학생 20분 수업 2개까지 이어 붙이기 예외)
  if exists (select 1 from lessons x where x.tutor_id = p_tutor and x.state <> 'canceled'
             and x.starts_at < p_end + v_break and p_start - v_break < x.ends_at
             and (x.starts_at < p_end and p_start < x.ends_at
                  or not (v_new_b2b and x.student_id = p_student and x.ends_at - x.starts_at = make_interval(mins => v_b2b_min)))) then
    return '강사 다른 수업(휴식 10분 포함)';
  end if;
  -- 3) 강사 현지 06:00~22:30 시작만 (POL-OP-02, 4200)
  if not lms_tutor_start_ok(p_tutor, p_start) then
    return '강사 현지 06:00~22:30 밖의 시작 시각';
  end if;
  -- 4) 강사가 연 시간(매주 Availability 또는 Schedule 에서 그날만 열기)이어야 함 (QA-01, 4500). 그날만 막은 시간(block)도 여기
  if not lms_tutor_available(p_tutor, p_start)
     or exists (select 1 from tutor_time_off o where o.tutor_id = p_tutor and o.kind = 'block' and o.starts_at < p_end and p_start < o.ends_at) then
    return '강사가 열어 둔 시간이 아님(Availability·Schedule)';
  end if;
  -- 5) 이어 붙이기 규칙
  select coalesce(array_agg(x.id), '{}') into v_near from lessons x
  where x.tutor_id = p_tutor and x.state <> 'canceled'
    and x.starts_at < p_end + v_break and p_start - v_break < x.ends_at;
  if cardinality(v_near) = 0 then return null; end if;
  select 1 + cardinality(v_near) + count(distinct y.id) into v_chain from lessons y
  where y.tutor_id = p_tutor and y.state <> 'canceled' and y.id <> all(v_near)
    and not (y.starts_at < p_end + v_break and p_start - v_break < y.ends_at)
    and exists (select 1 from lessons x where x.id = any(v_near)
                and y.starts_at < x.ends_at + v_break and x.starts_at - v_break < y.ends_at);
  if v_chain > v_b2b_max then
    return format('쉬지 않고 이어 붙이는 수업(%s분 %s개까지)', v_b2b_min, v_b2b_max);
  end if;
  return null;
end $$;
revoke all on function lms_makeup_conflict(uuid, uuid, timestamptz, timestamptz, boolean) from public, anon, authenticated;

-- tutor_makeup_answer: 4500 그대로 + 거절 문구를 사유별로 (R-25)
create or replace function tutor_makeup_answer(p_request uuid, p_yes uuid[], p_note text)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  r makeup_requests;
  v_note text := nullif(trim(coalesce(p_note, '')), '');
  v_yes uuid[] := coalesce(p_yes, '{}');
  v_conf text;
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
  if exists (select 1 from makeup_candidates c where c.id = any(v_yes) and c.starts_at <= now()) then
    raise exception 'One of the times you chose has already passed. Please reload the page.' using hint = 'busy';
  end if;
  select lms_makeup_conflict(r.tutor_id, r.student_id, c.starts_at, c.ends_at, true) into v_conf
  from makeup_candidates c where c.id = any(v_yes) and lms_makeup_conflict(r.tutor_id, r.student_id, c.starts_at, c.ends_at, true) is not null
  order by c.starts_at limit 1;
  if v_conf is not null then
    raise exception 'You can''t say yes to one of these times: %', lms_conflict_message_en(v_conf) using hint = 'busy', detail = lms_conflict_code(v_conf);
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

-- lms_sub_conflict: 대체강사 판정도 같은 순서·같은 말 (휴무 / 다른 수업 / 시작 가능 시간 / 강사가 막은 시간 = 열지 않은 시간)
create or replace function lms_sub_conflict(p_tutor uuid, p_start timestamptz, p_end timestamptz, p_except_lesson uuid)
returns text
language plpgsql stable security definer set search_path = public as $$
declare
  v_break constant interval := interval '10 minutes';   -- POL-OP-21 (policy.ts CONFIRMED.minBreakMin)
begin
  if exists (select 1 from tutor_time_off o where o.tutor_id = p_tutor and o.kind = 'leave' and o.starts_at < p_end and p_start < o.ends_at) then
    return '강사 휴무';
  end if;
  if exists (select 1 from lessons x where x.tutor_id = p_tutor and x.state <> 'canceled' and x.id is distinct from p_except_lesson
             and x.starts_at < p_end + v_break and p_start - v_break < x.ends_at) then
    return '강사 다른 수업(휴식 10분 포함)';
  end if;
  if not lms_tutor_start_ok(p_tutor, p_start) then
    return '강사 현지 06:00~22:30 밖의 시작 시각';
  end if;
  if exists (select 1 from tutor_time_off o where o.tutor_id = p_tutor and o.kind = 'block' and o.starts_at < p_end and p_start < o.ends_at) then
    return '강사가 열어 둔 시간이 아님(Schedule 에서 막은 시간)';
  end if;
  return null;
end $$;
revoke all on function lms_sub_conflict(uuid, timestamptz, timestamptz, uuid) from public, anon, authenticated;
