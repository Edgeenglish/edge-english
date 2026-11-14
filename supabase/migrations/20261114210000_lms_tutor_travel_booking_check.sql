-- 강사 해외 이동 기간 3차 (정책 원본 H26(173)(176), 대표 11/14 '3 가'): 신규 배정·재등록의 저장·확정 검사를 이동 기간 시간표 기준으로
--  · 운영자 배정 달력은 시각마다 그때 있는 지역의 시간표로 '가능'을 판정 (화면: src/lms/rules/booking.ts windowOn)
--  · DB 도 같은 기준: 수업 시각이 이동 기간 안이면 그 기간 매주 시간표(lms_tutor_weekly_ok)에 맞아야 함 → 아니면 충돌 'tutor_travel_hours'
--    lms_plan_conflicts 는 lms_new_plan_lessons(제안·등록)·lms_confirm_plan(확정)·lms_lessons_conflicts(회차 목록) 모두가 씀
--  · 이동 기간 밖 수업은 전과 같음 (Regular 시간 검사는 화면에서만 — 기존 동작 그대로)
create or replace function public.lms_plan_conflicts(p_tutor uuid, p_slots jsonb, p_start date, p_end date, p_dur smallint)
 returns jsonb language plpgsql stable security definer set search_path to 'public' as $function$
declare
  v_break interval := interval '10 minutes';   -- POL-OP-21 (코드 CONFIRMED.minBreakMin 과 같아야 함)
  d date := p_start;
  s jsonb;
  t0 timestamptz;
  t1 timestamptz;
  out jsonb := '[]'::jsonb;
begin
  while d <= p_end loop
    select x into s from jsonb_array_elements(p_slots) x where (x ->> 'weekday')::int = extract(dow from d);
    if found then
      t0 := (d + (s ->> 'time')::time) at time zone 'Asia/Seoul';
      t1 := t0 + make_interval(mins => p_dur);
      out := out || coalesce((
        select jsonb_agg(jsonb_build_object('date', d, 'time', s ->> 'time', 'reason',
                 case when l.starts_at < t1 and t0 < l.ends_at then (case when l.kind = 'regular' then 'tutor_regular' else 'tutor_makeup' end) else 'break' end,
                 'other_starts_at', l.starts_at, 'other_ends_at', l.ends_at))
        from lessons l
        where l.tutor_id = p_tutor and l.state <> 'canceled'
          and l.starts_at < t1 + v_break and t0 - v_break < l.ends_at), '[]'::jsonb);
      out := out || coalesce((
        select jsonb_agg(jsonb_build_object('date', d, 'time', s ->> 'time', 'reason', 'tutor_time_off',
                 'other_starts_at', o.starts_at, 'other_ends_at', o.ends_at))
        from tutor_time_off o where o.tutor_id = p_tutor and o.starts_at < t1 and t0 < o.ends_at), '[]'::jsonb);
      -- 재등록 대기 중인 다른 학생의 고정 시간 (A22, migration 1400)
      out := out || coalesce((
        select jsonb_agg(jsonb_build_object('date', d, 'time', s ->> 'time', 'reason', 'tutor_hold',
                 'other_starts_at', h.o0, 'other_ends_at', h.o1, 'other', h.student_name, 'hold_end', h.hold_end))
        from lms_slot_hold_hits(p_tutor, t0, t1) h), '[]'::jsonb);
      -- 해외 이동 기간 안이면 그 기간 매주 시간표에 맞아야 함 (H26(173), 화면 booking.ts 와 같은 기준)
      if lms_tutor_location_at(p_tutor, t0) is not null and not lms_tutor_weekly_ok(p_tutor, t0) then
        out := out || jsonb_build_array(jsonb_build_object('date', d, 'time', s ->> 'time', 'reason', 'tutor_travel_hours',
                 'timezone', lms_tutor_tz_at(p_tutor, t0)));
      end if;
    end if;
    d := d + 1;
  end loop;
  return out;
end $function$;
