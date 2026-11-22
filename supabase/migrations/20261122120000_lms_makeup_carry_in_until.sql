-- =====================================================================
-- 이월된 보강(지난 수강권 취소분)의 보강 날짜를 지금 수강권 종료일까지 찾고 받기
--  (대표 2026-11-22 '고쳐 당장': 학생 화면 기한은 12/20 인데 날짜 찾기는 지난 수강권 종료일 11/17 까지라 날짜가 0개)
--  lms_makeup_until(수강권) = 그 수강권 종료일, 단 이어지는 재등록(confirmed/active)을
--  그 종료일까지 결제했으면(POL-RN-01) 재등록 수강권 종료일
--  보강 날짜 찾기·신청·확정·시간 확인·운영자 보강 옮기기 5곳의 종료일 검사만 바꿈. 다시 실행해도 같은 결과
-- =====================================================================
create or replace function lms_makeup_until(p_enrollment uuid)
returns date language sql stable security definer set search_path = public as $$
  select greatest(e.final_end_date, coalesce((
    select max(n.final_end_date) from enrollments n
    where n.previous_enrollment_id = e.id and n.status in ('confirmed', 'active')
      and exists (select 1 from payments x where x.enrollment_id = n.id and x.received_on <= e.final_end_date)
  ), e.final_end_date))
  from enrollments e where e.id = p_enrollment
$$;
revoke all on function lms_makeup_until(uuid) from public, anon, authenticated;

do $$
declare
  f text;
  d text;
  d2 text;
begin
  foreach f in array array[
    'lms_makeup_options(uuid,uuid,uuid)',
    'lms_makeup_options_for_tutor(uuid,uuid,uuid,uuid)',
    'lms_makeup_request_for_tutor(uuid,uuid,jsonb,timestamptz,text,uuid,uuid,uuid)',
    'lms_makeup_book(uuid,timestamptz,text,boolean)',
    'lms_makeup_slot_ok(uuid,timestamptz)',
    'admin_makeup_reschedule(uuid,timestamptz,text,text)'
  ] loop
    d := pg_get_functiondef(f::regprocedure);
    if position('lms_makeup_until' in d) > 0 then continue; end if;
    d2 := replace(d, 'v_until := e.final_end_date;', 'v_until := lms_makeup_until(e.id);');
    d2 := replace(d2, '((e.final_end_date + 1)::timestamp', '((lms_makeup_until(e.id) + 1)::timestamp');
    d2 := replace(d2, '''수강 종료일(%) 뒤의 시간입니다.'', e.final_end_date', '''수강 종료일(%) 뒤의 시간입니다.'', lms_makeup_until(e.id)');
    if d2 = d then raise exception '% 패치 실패', f; end if;
    execute d2;
  end loop;
end $$;
