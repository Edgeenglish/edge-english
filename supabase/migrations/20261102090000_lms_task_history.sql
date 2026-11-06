-- =====================================================================
-- 처리 내역 보기 (2026-11-02 대표: 정O연 카드가 사라진 뒤 어디서도 다시 볼 수 없음)
--  - admin_task_history(): 운영자만. ① [처리 종료]한 카드(admin_task_closures) ② 종료일 3일 지나 자동으로 빠진 '수강기간 종료 임박'
--    ③ [수강 종료](3800)한 수강권. 학생 이름 · 업무 · 상태 · 날짜 · 처리자 · 사유. 읽기만
--  - 다시 열기는 기존 함수: admin_set_task_closed(…, false) · admin_enrollment_close(…, true)
--    자동 제외 카드를 다시 열면 admin_task_closures 에 closed=false 줄 → 화면이 그 카드는 자동 제외하지 않음
--  - 기록을 지우거나 학생·수업 데이터를 바꾸지 않음. 다시 실행해도 같은 결과
-- =====================================================================

create or replace function admin_task_history()
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_today date := (now() at time zone 'Asia/Seoul')::date;
begin
  if not is_admin() then raise exception '운영자(추가 인증 완료)만 볼 수 있습니다.' using errcode = '42501'; end if;
  return coalesce((select jsonb_agg(x order by x ->> 'at' desc nulls last) from (
    -- ① 운영진이 [처리 종료]한 카드
    select jsonb_build_object('source', 'closed', 'kind', c.task_kind, 'task_id', c.task_id, 'signature', c.signature, 'at', c.closed_at,
      'by', (select case u.role when 'admin' then '운영자' when 'tutor' then '강사' else u.role end from app_users u where u.auth_user_id = c.closed_by),
      'name', coalesce((select s.name_ko from enrollments e join students s on s.id = e.student_id where c.task_kind = 'ending_soon' and e.id::text = c.task_id),
                       case when c.signature ~ '^\{' then coalesce(c.signature::jsonb ->> 'studentName', c.signature::jsonb ->> 'tutorName') end)) as x
    from admin_task_closures c where c.closed
    union all
    -- ② 종료일 3일 지나 자동으로 빠진 수강기간 종료 임박 (재등록 결제 안 됨, 다시 열지 않음)
    select jsonb_build_object('source', 'auto', 'kind', 'ending_soon', 'task_id', e.id, 'signature', e.id::text,
      'at', ((e.final_end_date + 3)::timestamp at time zone 'Asia/Seoul'), 'by', null, 'name', s.name_ko)
    from enrollments e join students s on s.id = e.student_id
    where e.status in ('active', 'confirmed') and e.final_end_date + 3 <= v_today
      and not exists (select 1 from enrollments n where n.student_id = e.student_id and n.status in ('active', 'confirmed') and n.final_end_date > e.final_end_date)
      and not exists (select 1 from enrollments n where n.previous_enrollment_id = e.id and n.status in ('confirmed', 'active'))
      and not exists (select 1 from admin_task_closures c where c.task_kind = 'ending_soon' and c.task_id = e.id::text)
    union all
    -- ③ [수강 종료]한 수강권
    select jsonb_build_object('source', 'enrollment', 'kind', 'ending_soon', 'task_id', e.id, 'signature', e.id::text,
      'at', h.at, 'by', h.email, 'name', s.name_ko)
    from enrollments e join students s on s.id = e.student_id
    left join lateral (select l.at, (select case u.role when 'admin' then '운영자' else u.role end from app_users u where u.auth_user_id = l.actor) email
                       from audit_log l where l.table_name = 'enrollments' and l.row_id = e.id::text and l.actor_via = 'admin_enrollment_close'
                       order by l.at desc limit 1) h on true
    where e.status = 'completed' and h.at is not null
  ) q), '[]'::jsonb);
end $$;
revoke all on function admin_task_history() from public, anon;
grant execute on function admin_task_history() to authenticated;
