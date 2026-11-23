-- =====================================================================
-- 강사 Home 알림 'Renewed' 줄 기간 끝 = 수강권 종료일 (2026-11-22 대표 '고쳐')
--  지금: Next period 끝을 '만든 마지막 수업일'로 보여 줌 → 일부만 확정한 등록(오O수 STU-0010)은 1/4로 보임 (실제 2/14)
--  고침: 확정 알림 info 에 period_end(= 최종 종료일) 를 넣고, 화면은 있으면 그걸 씀 (src/lms/tutor/updates.ts). 메일 문구는 그대로
-- =====================================================================
do $$
declare
  d text := pg_get_functiondef('lms_plan_confirmed_notice()'::regprocedure);
  a text := '''minutes'', e.duration_min, ''classes'', e.lessons_purchased';
begin
  if (length(d) - length(replace(d, a, ''))) / length(a) <> 2 then raise exception '자리 못 찾음'; end if;
  execute replace(d, a, a || ', ''period_end'', coalesce(e.final_end_date, e.base_end_date)');
end $$;
