-- =====================================================================
-- [정규 일정 수정](admin_regular_change): 옮긴 수업이 강사 휴무(tutor_time_off kind 'leave') 안으로 들어가면
-- 막지 않고 그 휴무 처리에 넣는다 (정책 원본 H26(208) 보충 11, 대표 11/23 '응')
--  계기: 운영 STU-0007 월·수 → 수·금 오후 7시 — 기존 12/21(월) 수업이 12/23(수) Benny 휴무로 들어가 저장이 막힘.
--        같은 휴무의 다른 수업처럼 '대체강사와 수업 / 기존 강사와 보강'을 학생이 고르게 함(보강은 수강 종료일 뒤도 가능)
--  강사가 막아 둔 시간(kind 'block')은 지금처럼 막음
--  학생 정규 시간 변경 신청의 '가능한 시간' 검사(lms_rc_free)도 같은 기준(휴무는 막지 않음)
-- 지우는 문장 없음 (함수 본문 일부 바꾸기 — 바꿀 글이 없으면 멈춤)
-- =====================================================================
do $$
declare
  d text := pg_get_functiondef('public.admin_regular_change(uuid,jsonb,date,text,boolean)'::regprocedure);
  a1 text := $q$elsif exists (select 1 from tutor_time_off o where o.tutor_id = t.id and o.starts_at < t1 and t0 < o.ends_at) then v_why := 'tutor_time_off';$q$;
  b1 text := $q$elsif exists (select 1 from tutor_time_off o where o.tutor_id = t.id and o.kind <> 'leave' and o.starts_at < t1 and t0 < o.ends_at) then v_why := 'tutor_time_off';$q$;
  a2 text := $q$v_moved := v_moved || jsonb_build_object('lesson_id', l.id, 'seq', l.seq, 'from', l.starts_at, 'from_end', l.ends_at, 'to', t0, 'to_end', t1, 'problem', v_why);$q$;
  b2 text := $q$v_moved := v_moved || jsonb_build_object('lesson_id', l.id, 'seq', l.seq, 'from', l.starts_at, 'from_end', l.ends_at, 'to', t0, 'to_end', t1, 'problem', v_why,
      'leave', (select o.id from tutor_time_off o where o.tutor_id = t.id and o.kind = 'leave' and o.starts_at < t1 and t0 < o.ends_at order by o.starts_at limit 1));$q$;
  a3 text := $q$  insert into regular_changes (student_id, enrollment_id, tutor_id, effective_from, old_slots, new_slots, moved, kept, reason, created_by)$q$;
  b3 text := $q$  -- 휴무 안으로 옮긴 수업은 그 휴무 처리에 넣음 (admin_leave_create 와 같은 방식, 학생 휴무 안내 알림 포함)
  with ins as (
    insert into leave_items (time_off_id, tutor_id, student_id, enrollment_id, lesson_id, migrated_item_id, starts_at, ends_at, choice, created_by)
    select (mv.x ->> 'leave')::uuid, t.id, n.student_id, n.enrollment_id, n.lesson_id, n.migrated_item_id, n.starts_at, n.ends_at, n.choice, auth.uid()
    from jsonb_array_elements(v_moved) mv(x)
    cross join lateral lms_leave_candidates_at(t.id, (mv.x ->> 'to')::timestamptz, (mv.x ->> 'to_end')::timestamptz) n
    where mv.x ->> 'leave' is not null and n.lesson_id = (mv.x ->> 'lesson_id')::uuid
    on conflict do nothing
    returning id, student_id
  )
  insert into lesson_notices (leave_item_id, event, recipient_kind, recipient_id)
  select id, 'leave_options', 'student', student_id from ins;
$q$ || a3;
begin
  if strpos(d, a1) = 0 or strpos(d, a2) = 0 or strpos(d, a3) = 0 then
    raise exception 'admin_regular_change 본문이 예상과 달라 바꾸지 않았습니다.';
  end if;
  d := replace(replace(replace(d, a1, b1), a2, b2), a3, b3);
  execute d;
end $$;

create or replace function lms_rc_free(p_tutor uuid, p_student uuid, p_from date, p_until date, p_dow int, p_time time, p_min int)
returns boolean language plpgsql stable security definer set search_path = public as $$
declare
  d date;
  t0 timestamptz;
  t1 timestamptz;
  n int := 0;
begin
  d := lms_rc_day(lms_rc_monday(p_from), p_dow);
  if d < p_from then d := d + 7; end if;
  while d <= p_until loop
    if exists (select 1 from lessons x
               where x.student_id = p_student and x.kind = 'regular' and x.state = 'scheduled' and x.voided_at is null
                 and x.tutor_id = p_tutor and x.original_tutor_id is null and x.starts_at > now()
                 and lms_rc_monday((x.starts_at at time zone 'Asia/Seoul')::date) = lms_rc_monday(d)
                 and not exists (select 1 from leave_items li where li.lesson_id = x.id and li.lesson_gone_at is null)) then
      t0 := (d + p_time) at time zone 'Asia/Seoul';
      t1 := t0 + make_interval(mins => p_min);
      -- 강사 휴무 안이면 그 휴무 처리로 들어가므로 막지 않음 (그 날 근무시간·다른 수업 검사도 건너뜀)
      if not exists (select 1 from tutor_time_off o where o.tutor_id = p_tutor and o.kind = 'leave' and o.starts_at < t1 and t0 < o.ends_at) then
        if not lms_tutor_start_ok(p_tutor, t0) or not lms_tutor_available(p_tutor, t0) then return false; end if;
        if exists (select 1 from tutor_time_off o where o.tutor_id = p_tutor and o.starts_at < t1 and t0 < o.ends_at) then return false; end if;
        if exists (select 1 from lessons y where y.tutor_id = p_tutor and y.state <> 'canceled' and y.voided_at is null
                     and not (y.student_id = p_student and y.kind = 'regular' and y.state = 'scheduled')
                     and y.starts_at < t1 + interval '10 minutes' and t0 - interval '10 minutes' < y.ends_at) then return false; end if;
        if exists (select 1 from lms_slot_hold_hits(p_tutor, t0, t1) h where h.student_id <> p_student) then return false; end if;
      end if;
      n := n + 1;
    end if;
    d := d + 7;
  end loop;
  return n > 0;
end $$;
revoke all on function lms_rc_free(uuid, uuid, date, date, int, time, int) from public, anon, authenticated;
