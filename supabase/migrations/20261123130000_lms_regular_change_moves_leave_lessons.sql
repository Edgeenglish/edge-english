-- =====================================================================
-- [정규 일정 수정](admin_regular_change): 강사 휴무 처리 중이지만 학생이 아직 답하지 않은 수업(choice 'undecided', 대체강사 진행 전)도 새 정규 시간으로 옮김
-- (정책 원본 H26(208) 보충 14, 대표 11/23 '일단 다 옮겨지고, 휴무에 걸리면 그에 맞는 할 일이 학생에게 떠야')
--  · 옮긴 새 시각이 휴무 안 → 그 휴무 항목 시각을 새 시각으로 맞춤 (학생 할 일 그대로, 새 시각으로 보임)
--  · 옮긴 새 시각이 휴무 밖 → 휴무 처리에서 뺌(lesson_gone_at) — 평소 수업
--  · 휴무 안으로 옮기는 수업은 강사 근무시간·다른 수업 겹침 검사를 하지 않음 (휴무라 그 시간 강사 수업 없음)
--  · 정규 일정은 그대로인데 앞으로 수업 중 정규 시간과 어긋난 수업이 있으면 같은 일정으로도 저장 가능 (어긋난 수업만 다시 맞춤)
--  계기: 운영 STU-0007 수·금 오후 7시 변경 뒤 휴무 기간 12/28·12/30·1/4 수업이 옛 시간(월·수 오전 11시)에 남음
-- 지우는 문장 없음 (함수 본문 일부 바꾸기 — 바꿀 글이 없으면 멈춤)
-- =====================================================================
do $$
declare
  d text := pg_get_functiondef('public.admin_regular_change(uuid,jsonb,date,text,boolean)'::regprocedure);
  -- 옮길 수 있는 휴무 항목 = 학생 답 전 · 대체강사 진행 전 · 철회 안 됨
  open_li constant text := $q$li.lesson_gone_at is null and not (li.choice = 'undecided' and li.sub_tutor_id is null and li.sub_stage is null and li.sub_lesson_id is null and li.withdrawn_at is null)$q$;
  a1 text := $q$    and not exists (select 1 from leave_items li where li.lesson_id = x.id and li.lesson_gone_at is null);$q$;
  b1 text;
  a2 text := $q$  if v_new = v_old and not exists ($q$;
  b2 text;
  a3 text := $q$    v_why := null;
    if not lms_tutor_start_ok(t.id, t0) then v_why := 'tutor_hours_range';$q$;
  b3 text := $q$    v_why := null;
    if exists (select 1 from tutor_time_off o where o.tutor_id = t.id and o.kind = 'leave' and o.starts_at < t1 and t0 < o.ends_at) then null;   -- 휴무 안: 휴무 처리로 들어감
    elsif not lms_tutor_start_ok(t.id, t0) then v_why := 'tutor_hours_range';$q$;
  a4 text := $q$  -- 휴무 안으로 옮긴 수업은 그 휴무 처리에 넣음$q$;
  b4 text := $q$  -- 휴무 처리 중(학생 답 전)이던 수업을 옮김: 새 시각이 휴무 안이면 그 항목 시각을 맞추고, 휴무 밖이면 휴무 처리에서 뺌
  update leave_items li set starts_at = (mv.x ->> 'to')::timestamptz, ends_at = (mv.x ->> 'to_end')::timestamptz, time_off_id = (mv.x ->> 'leave')::uuid
  from jsonb_array_elements(v_moved) mv(x)
  where li.lesson_id = (mv.x ->> 'lesson_id')::uuid and li.lesson_gone_at is null and mv.x ->> 'leave' is not null;
  update leave_items li set lesson_gone_at = now()
  from jsonb_array_elements(v_moved) mv(x)
  where li.lesson_id = (mv.x ->> 'lesson_id')::uuid and li.lesson_gone_at is null and mv.x ->> 'leave' is null;
$q$ || a4;
  a5 text := $q$rs.effective_to >= p_from - 1$q$;
  b5 text := $q$coalesce(rs.effective_to, 'infinity'::date) >= p_from - 1$q$;
begin
  b1 := '    and not exists (select 1 from leave_items li where li.lesson_id = x.id and ' || open_li || ');';
  b2 := $q$  if v_new = v_old and not exists (select 1 from lessons x
                                   where x.enrollment_id = e.id and x.kind = 'regular' and x.state = 'scheduled' and x.voided_at is null
                                     and x.starts_at > now() and x.kst_date >= p_from and x.original_tutor_id is null and x.tutor_id = t.id
                                     and not exists (select 1 from leave_items li where li.lesson_id = x.id and $q$ || open_li || $q$)
                                     and not exists (select 1 from jsonb_array_elements(v_new) z
                                                     where (z ->> 'weekday')::int = extract(dow from x.starts_at at time zone 'Asia/Seoul')
                                                       and (z ->> 'time')::time = (x.starts_at at time zone 'Asia/Seoul')::time))
     and not exists ($q$;
  if strpos(d, a1) = 0 or strpos(d, a2) = 0 or strpos(d, a3) = 0 or strpos(d, a4) = 0 or strpos(d, a5) = 0 then
    raise exception 'admin_regular_change 본문이 예상과 달라 바꾸지 않았습니다.';
  end if;
  d := replace(replace(replace(replace(replace(d, a1, b1), a2, b2), a3, b3), a4, b4), a5, b5);
  execute d;
end $$;

-- 학생 정규 시간 변경 '가능한 시간': 옮겨질 수업 기준을 같게 (학생 답 전 휴무 수업도 옮겨짐 — 휴무 날짜는 검사 안 함)
do $$
declare
  d text := pg_get_functiondef('public.lms_rc_free(uuid,uuid,date,date,integer,time,integer)'::regprocedure);
  a1 text := $q$and not exists (select 1 from leave_items li where li.lesson_id = x.id and li.lesson_gone_at is null)) then$q$;
  b1 text := $q$and not exists (select 1 from leave_items li where li.lesson_id = x.id and li.lesson_gone_at is null and not (li.choice = 'undecided' and li.sub_tutor_id is null and li.sub_stage is null and li.sub_lesson_id is null and li.withdrawn_at is null))) then$q$;
begin
  if strpos(d, a1) = 0 then raise exception 'lms_rc_free 본문이 예상과 달라 바꾸지 않았습니다.'; end if;
  execute replace(d, a1, b1);
end $$;
