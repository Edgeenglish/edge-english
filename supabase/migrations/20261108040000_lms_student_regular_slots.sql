-- =====================================================================
-- 학생 화면 '수업 시간' (대표 11/8, 정책 원본 H26(95) ②): 홈 '수강·결제·적립금' 칸에 매주 정규 요일·시각·강사
--  지금 적용 중인 정규 일정 (아직 시작 전이면 곧 시작할 일정). 화면이 학생 거주지 시간으로 바꿔 보여 줌
-- 표·데이터는 바꾸지 않음 (읽기 함수 하나). 다시 실행해도 같은 결과
-- =====================================================================
create or replace function student_regular_slots(p_student uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_student uuid := lms_screen_student(p_student);
  v_today date := (now() at time zone 'Asia/Seoul')::date;
  v_ref date;
begin
  select greatest(v_today, min(r.effective_from)) into v_ref from regular_schedules r
  where r.student_id = v_student and (r.effective_to is null or r.effective_to >= v_today);
  if v_ref is null then return '[]'::jsonb; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object('weekday', r.weekday, 'time', to_char(r.start_time_kst, 'HH24:MI'),
                                        'minutes', r.duration_min, 'tutor', t.name) order by r.weekday, r.start_time_kst)
    from regular_schedules r join tutors t on t.id = r.tutor_id
    where r.student_id = v_student and r.effective_from <= v_ref and (r.effective_to is null or r.effective_to >= v_ref)), '[]'::jsonb);
end $$;
revoke all on function student_regular_slots(uuid) from public, anon;
grant execute on function student_regular_slots(uuid) to authenticated;
