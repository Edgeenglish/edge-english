-- =====================================================================
-- 강사 귀책 자동 연장 보완 (QA 11/8, 정책 원본 H26(94) '종료일 자동 단축 없음')
--  - 기존(시행 전) 휴무 보강 연장(A20)도 줄이지 않음: 그 보강을 취소·앞당겨도 이미 늘어난 종료일 그대로
--    (예전: 보강을 없애면 -n 줄을 넣어 종료일이 줄었음 → 이제는 늘리기만)
-- 표·데이터는 바꾸지 않음. 다시 실행해도 같은 결과
-- =====================================================================

create or replace function lms_leave_sync_extension(p_enrollment uuid) returns void
language plpgsql security definer set search_path = public as $$
declare
  e enrollments;
  v_actor uuid := coalesce(nullif(current_setting('app.actor_id', true), '')::uuid, auth.uid());
  v_pre date;
  v_last date;
  v_cur integer;
  v_target integer;
begin
  select * into e from enrollments where id = p_enrollment for update;
  if not found then return; end if;
  select e.base_end_date + coalesce(sum(days) filter (where auto_source is null), 0)::int,
         coalesce(sum(days) filter (where auto_source = 'leave_makeup'), 0)::int
  into v_pre, v_cur from enrollment_extensions where enrollment_id = e.id;
  select max(x.kst_date) into v_last from lessons x
  where x.enrollment_id = e.id and x.state <> 'canceled'
    and ((x.kind = 'makeup' and exists (select 1 from lessons o where o.id = x.makeup_of and o.class_status = 'Tutor long-term leave'
                                         and lms_fault_event(o.id) is null))
      or (x.kind = 'migrated_makeup' and exists (select 1 from migrated_items m where m.lesson_id = x.id and m.tutor_leave)));
  -- 줄이지 않음 (H26(94) 자동 단축 없음, QA 11/8: 기존 휴무 보강을 취소해도 종료일 그대로)
  v_target := greatest(coalesce(v_last - v_pre, 0), 0, v_cur);
  if v_target <> v_cur then
    if v_actor is null then raise exception '처리한 사람을 알 수 없습니다.'; end if;
    begin
      insert into enrollment_extensions (enrollment_id, days, reason, note, approved_by, auto_source)
      values (e.id, v_target - v_cur, 'tutor_long_term_leave', 'LMS 강사 휴무 보강 자동 연장 (A20)', v_actor, 'leave_makeup');
    exception when exclusion_violation then
      raise exception '다음 수강권 기간과 겹쳐 종료일을 늘릴 수 없습니다. 보강 날짜를 다시 확인해 주세요.' using hint = 'next_enrollment';
    end;
  end if;
  perform lms_fault_sync_extension(e.id);   -- 기본 종료일이 바뀌었으면 자동 연장도 맞춤
end $$;
revoke all on function lms_leave_sync_extension(uuid) from public, anon, authenticated;
