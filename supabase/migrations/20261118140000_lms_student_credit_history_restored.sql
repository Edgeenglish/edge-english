-- 학생 변경권 내역: 변경권을 쓰지 않은 취소를 운영진이 되돌린 기록도 줄로 (kind 'restored', 변경권 줄 없음) — 대표 11/18.
-- 읽기 전용 함수 교체만 (20261118100000 판에 restored 갈래만 더함). 데이터 변경 없음. 다시 실행해도 같은 결과.
create or replace function public.student_credit_history(p_student uuid default null)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  v_student uuid;
  v_today date := (now() at time zone 'Asia/Seoul')::date;
  v_current uuid;
begin
  if auth.uid() is null then
    raise exception '학생 계정으로 로그인해 주세요.' using errcode = '42501';
  end if;
  v_student := public.lms_screen_student(p_student);
  -- 홈 '남은 변경권'과 같은 기간 (student_screen 과 같은 기준)
  select x.id into v_current from public.enrollment_periods x
  where x.enrollment_id = public.lms_student_enrollment(v_student) and x.start_date <= v_today
  order by x.idx desc limit 1;

  return (
    with periods as (
      select p.* from public.enrollment_periods p
      join public.enrollments en on en.id = p.enrollment_id and en.student_id = v_student
    ), cancels as (   -- 수강생 쪽 취소 (학생 직접·운영진 대신·강사가 학생 대신 기록 모두)
      select c.id, c.created_at, c.requested_at, c.reverted_at, c.decision, c.status = 'reverted' reverted, l.id lesson_id, l.starts_at,
             public.lms_lesson_period(l.enrollment_id, l.kst_date) period_id
      from public.change_requests c
      join public.lessons l on l.id = c.lesson_id and l.student_id = v_student
      where c.student_id = v_student and c.type in ('student_cancel', 'admin_cancel')
        and c.decision->>'who' = 'student' and c.status in ('applied', 'reverted')
    ), items as (
      select g.period_id, g.created_at at, g.id::text item_id,
             case when g.reason = 'student_change' then 'use'
                  when g.reason = 'admin_restore' then 'return'
                  when g.lesson_id is null and g.note like '기존 학생 이관%' then 'migrated'
                  when g.delta > 0 then 'admin_add' else 'admin_remove' end kind,
             g.delta::int delta, l.starts_at lesson_at,
             coalesce(cu.requested_at, g.created_at) cancel_at,
             cu.decision->>'timing' timing, coalesce((cu.decision->>'holiday')::boolean, false) holiday,
             (cu.decision->>'credits_after')::int cr_after, coalesce(cu.reverted, false) reverted
      from public.credit_ledger g
      join periods p on p.id = g.period_id
      left join public.lessons l on l.id = g.lesson_id
      left join cancels cu on cu.id = g.change_request_id and g.reason = 'student_change'
      union all
      select c.period_id, c.created_at, c.id::text,
             case when coalesce((c.decision->>'holiday')::boolean, false) then 'holiday'
                  when c.decision->>'timing' = 'late' then 'late' else 'no_credit' end,
             0, c.starts_at, c.requested_at, c.decision->>'timing', coalesce((c.decision->>'holiday')::boolean, false),
             (c.decision->>'credits_after')::int, c.reverted
      from cancels c join periods p on p.id = c.period_id
      where not coalesce((c.decision->>'uses_credit')::boolean, false)
      union all
      -- 변경권을 쓰지 않은 취소를 운영진이 되돌린 기록 (대표 11/18: 복구된 사실도 같은 창에, 변경권 줄 없음)
      select c.period_id, c.reverted_at, c.id::text || ':restored', 'restored', 0, c.starts_at, c.reverted_at, null, false, null, false
      from cancels c join periods p on p.id = c.period_id
      where c.reverted and c.reverted_at is not null and not coalesce((c.decision->>'uses_credit')::boolean, false)
    )
    select coalesce(jsonb_agg(jsonb_build_object(
      'start', p.start_date, 'end', p.end_date, 'granted', p.credits_granted,
      'left', public.credit_balance(p.id), 'current', p.id = v_current,
      'items', coalesce((
        select jsonb_agg(jsonb_build_object(
          'id', i.item_id, 'at', i.at, 'kind', i.kind, 'delta', i.delta,
          'lesson_at', i.lesson_at, 'cancel_at', i.cancel_at, 'timing', i.timing, 'holiday', i.holiday, 'reverted', i.reverted,
          'after', coalesce(i.cr_after, p.credits_granted + coalesce((select sum(g2.delta) from public.credit_ledger g2
                     where g2.period_id = p.id and g2.created_at <= i.at), 0)::int)
        ) order by i.at desc, i.item_id desc)
        from items i where i.period_id = p.id), '[]'::jsonb)
    ) order by p.start_date desc), '[]'::jsonb)
    from periods p
    where p.start_date <= v_today or exists (select 1 from items i where i.period_id = p.id)
  );
end $$;
revoke all on function public.student_credit_history(uuid) from public, anon, authenticated;
grant execute on function public.student_credit_history(uuid) to authenticated;
