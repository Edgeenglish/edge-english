-- =====================================================================
-- [정규 일정 수정](admin_regular_change)·학생 [정규 시간 변경] 신청: 강사가 막아 둔 시간(tutor_time_off kind 'block', 1회 휴무)이 있어도 막지 않음
-- (정책 원본 H26(208) 보충 13, 대표 11/23 '막아 둔 날이 있어도 무슨 상관, 정규 시간 변경이 신청 가능해야지')
--  옮긴 수업이 강사가 막아 둔 시간에 들어가면 저장 뒤 그 수업을 '강사 정상 취소'(Tutor canceled in advance)로 처리
--  → 학생 변경권 차감 없음, 수강기간 안에 학생이 보강을 잡음 (강사 취소와 같은 함수 lms_change_core, 학생·강사 알림 포함)
--  강사가 막아 둔 시간은 그대로 둠
--  계기: 운영 STU-0007 월·수 → 수·금 오후 7시 — 12/11(금) Benny 1회 휴무에 걸려 저장이 막힘
-- 지우는 문장 없음 (함수 본문 일부 바꾸기 — 바꿀 글이 없으면 멈춤)
-- =====================================================================
do $$
declare
  d text := pg_get_functiondef('public.admin_regular_change(uuid,jsonb,date,text,boolean)'::regprocedure);
  a1 text := $q$o.kind <> 'leave' and o.starts_at < t1 and t0 < o.ends_at) then v_why := 'tutor_time_off';$q$;
  b1 text := $q$o.kind not in ('leave', 'block') and o.starts_at < t1 and t0 < o.ends_at) then v_why := 'tutor_time_off';$q$;
  a2 text := $q$o.kind = 'leave' and o.starts_at < t1 and t0 < o.ends_at order by o.starts_at limit 1));$q$;
  b2 text := $q$o.kind = 'leave' and o.starts_at < t1 and t0 < o.ends_at order by o.starts_at limit 1),
      'block', (select o.id from tutor_time_off o where o.tutor_id = t.id and o.kind = 'block' and o.starts_at < t1 and t0 < o.ends_at order by o.starts_at limit 1));$q$;
  a3 text := $q$  return jsonb_build_object('ok', true, 'change_id', v_change,$q$;
  b3 text := $q$  -- 강사가 막아 둔 시간(1회 휴무) 안으로 옮긴 수업 = 강사 정상 취소 (학생 보강권)
  perform lms_change_core('regular_change_block:' || v_change || ':' || (mv.x ->> 'lesson_id'), (mv.x ->> 'lesson_id')::uuid, 'tutor', 'admin_on_behalf', now(), false, auth.uid())
  from jsonb_array_elements(v_moved) mv(x)
  where mv.x ->> 'block' is not null and mv.x ->> 'leave' is null;
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
      -- 강사 휴무·막아 둔 시간(1회 휴무) 안이면 휴무 처리·강사 정상 취소로 들어가므로 막지 않음 (그 날 다른 검사도 건너뜀)
      if not exists (select 1 from tutor_time_off o where o.tutor_id = p_tutor and o.kind in ('leave', 'block') and o.starts_at < t1 and t0 < o.ends_at) then
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
