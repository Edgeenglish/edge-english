-- =====================================================================
-- 학생 홈 · 일정과 휴무 안내 맞추기 (2026-10-30 대표 확인 3번)
--  - 문제: 휴무 처리 중(대체강사 미정·답 기다림·학생 답 전)인 수업이 학생 홈에는 휴무 강사와 정상 수업처럼 입장 버튼까지 보임
--  - lessons 마다 leave_open: 휴무 처리가 아직 확정 전인 수업 (미정 · 대체강사 확정 전). 화면은 '일정 조율 중' + 입장 버튼 안 보임
--  - student_screen 만 바꿈 (3200 그대로 + leave_open). 다시 실행해도 같은 결과
-- =====================================================================

create or replace function student_screen(p_student uuid)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_student uuid := lms_screen_student(p_student);
  st students;
  e enrollments;
  v_period enrollment_periods;
  v_open uuid[];
begin
  select * into st from students where id = v_student;
  select * into e from enrollments where id = lms_student_enrollment(v_student);
  select * into v_period from enrollment_periods p
  where p.enrollment_id = e.id and p.start_date <= (now() at time zone 'Asia/Seoul')::date order by p.idx desc limit 1;
  -- 수업·보강은 지금 수강권 + 아직 열린 다른 수강권(재등록 결제 뒤에도 이전 수강권의 보강이 남을 수 있음)
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
    -- 보강을 받을 수 있는데 아직 날짜가 없는 것 (취소한 수업 · 시트에서 넘어온 날짜 미정 보강)
    'makeup_rights', coalesce((
      select jsonb_agg(r order by r ->> 'original_at') from (
        select jsonb_build_object('lesson_id', l.id, 'item_id', null, 'original_at', l.starts_at,
                 'tutor_leave', l.class_status = 'Tutor long-term leave') as r
        from lessons l
        where l.enrollment_id = any(v_open) and l.voided_at is null and (lms_grants_makeup(l.class_status) or l.class_status = 'Tutor long-term leave')
          and not exists (select 1 from lessons x where x.makeup_of = l.id and x.state <> 'canceled')
        union all
        select jsonb_build_object('lesson_id', null, 'item_id', m.id, 'original_at', m.original_date::timestamp at time zone 'Asia/Seoul',
                 'tutor_leave', coalesce(m.tutor_leave, false))
        from migrated_items m where m.enrollment_id = any(v_open) and m.kind = 'makeup_open') q), '[]'::jsonb),
    'makeup_requests', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', r.id, 'status', r.status, 'lesson_id', r.source_lesson_id, 'item_id', r.migrated_item_id,
        'requested_at', r.requested_at, 'confirmed_lesson_id', r.confirmed_lesson_id,
        'tutor_leave', (select x.tutor_leave from lms_makeup_source(r.source_lesson_id, r.migrated_item_id) x),
        'candidates', (select coalesce(jsonb_agg(c.starts_at order by c.starts_at), '[]'::jsonb) from makeup_candidates c where c.request_id = r.id and c.proposed_by = 'student'))
        order by r.requested_at desc)
      from makeup_requests r where r.student_id = v_student and r.status in ('requested', 'countered', 'confirmed')
        and r.requested_at > now() - interval '60 days'), '[]'::jsonb),
    -- 휴무 안내: 대체강사가 가능하다고 한 수업(답 기다림)·확정된 대체 수업·보강으로 정한 수업만. 지난 수업은 빼고
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
    -- 변경권: 지금 기간과 쓴 기록 (대표 10/29: 변경권 칸 누르면 언제 썼는지)
    'credit_period', case when v_period.id is null then null else jsonb_build_object('start', v_period.start_date, 'end', v_period.end_date) end,
    'credit_uses', coalesce((
      select jsonb_agg(jsonb_build_object('at', c.created_at, 'reason', c.reason, 'delta', c.delta, 'lesson_at', l.starts_at) order by c.created_at)
      from credit_ledger c left join lessons l on l.id = c.lesson_id where c.period_id = v_period.id), '[]'::jsonb),
    'holidays', coalesce((select jsonb_agg(h.day order by h.day) from holidays h
      where h.day between (now() at time zone 'Asia/Seoul')::date and (now() at time zone 'Asia/Seoul')::date + 200), '[]'::jsonb),
    'points', coalesce((
      select jsonb_agg(jsonb_build_object('id', g.id, 'on', (g.created_at at time zone 'Asia/Seoul')::date, 'kind', g.kind, 'amount', g.amount, 'note', g.note)
        order by g.created_at)
      from reward_ledger g where g.student_id = v_student), '[]'::jsonb));
end $$;
revoke all on function student_screen(uuid) from public, anon;
grant execute on function student_screen(uuid) to authenticated;

-- 안내 여러 건을 한 번에 '보냄' (대표 10/30 확인 2번): 묶음으로 보낸 글은 같은 보낸 시각 → 화면이 보낸 글 원문·번호를 그대로 다시 만들 수 있음
-- admin_mark_lesson_notice_sent 와 같은 검사, 한 묶음(한 트랜잭션)이라 sent_at 이 모두 같음
create or replace function admin_mark_lesson_notices_sent(p_notices uuid[])
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  n lesson_notices;
  v_changed integer := 0;
begin
  if not is_admin() then raise exception '운영자(추가 인증 완료)만 기록할 수 있습니다.' using errcode = '42501'; end if;
  perform set_config('app.actor_id', me::text, true);
  perform set_config('app.actor_via', 'admin_mark_lesson_notices_sent', true);
  for n in select * from lesson_notices where id = any(p_notices) order by id for update loop
    if n.status = 'not_needed' then raise exception '보낼 필요가 없어진 안내가 있습니다. 화면을 새로 고쳐 주세요.'; end if;
    if n.status = 'pending' then
      update lesson_notices set status = 'sent', sent_at = now(), sent_by = me where id = n.id;
      v_changed := v_changed + 1;
    end if;
  end loop;
  return jsonb_build_object('changed', v_changed);
end $$;
revoke all on function admin_mark_lesson_notices_sent(uuid[]) from public, anon;
grant execute on function admin_mark_lesson_notices_sent(uuid[]) to authenticated;
