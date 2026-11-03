-- 대표 요청 2026-11-03: My hours 선택 범위는 강사 현지 06:00~22:30 시작.
-- 한국 시간 보기에서도 같은 현지 칸을 변환한다. 기존 가능 시간·수업 데이터는 변경하지 않는다.
-- 읽기(tutor_hours)와 저장(tutor_hours_save)이 같은 함수를 사용한다.
create or replace function public.lms_hours_times(p_tz text, p_monday date) returns setof time
language sql stable as $$
  select g::time
  from generate_series(timestamp '2000-01-01 06:00', timestamp '2000-01-01 22:30', interval '30 minutes') g
  order by 1
$$;
revoke all on function public.lms_hours_times(text, date) from public, anon, authenticated;
