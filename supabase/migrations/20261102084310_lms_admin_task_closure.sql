-- 운영진이 대시보드 업무만 종료. 수업·결제·안내의 실제 상태는 변경하지 않는다.
create table public.admin_task_closures (
  id uuid primary key default gen_random_uuid(),
  task_kind text not null,
  task_id text not null,
  signature text not null,
  closed boolean not null default true,
  closed_at timestamptz not null default now(),
  closed_by uuid not null,
  unique(task_kind, task_id)
);
select lms_protect('public.admin_task_closures'::regclass);

create function public.admin_set_task_closed(p_kind text, p_id text, p_signature text, p_closed boolean)
returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null or not is_admin() then
    raise exception '추가 인증을 완료한 운영자만 처리할 수 있습니다.' using errcode = '42501';
  end if;
  if p_kind not in ('new_student_matching', 'renewal_tutor_notice', 'long_leave_request', 'no_show_report', 'ending_soon', 'makeup_unrequested', 'auto_failure', 'import_check', 'lesson_change', 'tutor_leave', 'class_record_missing')
    or p_id is null or p_id = '' or p_signature is null or p_signature = '' or p_closed is null then
    raise exception '업무 정보가 올바르지 않습니다.';
  end if;
  perform set_config('app.actor_id', auth.uid()::text, true);
  perform set_config('app.actor_via', 'admin_set_task_closed', true);
  insert into public.admin_task_closures(task_kind, task_id, signature, closed, closed_at, closed_by)
  values (p_kind, p_id, p_signature, p_closed, now(), auth.uid())
  on conflict(task_kind, task_id) do update
  set signature = excluded.signature, closed = excluded.closed, closed_at = excluded.closed_at, closed_by = excluded.closed_by;
end $$;
revoke all on function public.admin_set_task_closed(text, text, text, boolean) from public, anon;
grant execute on function public.admin_set_task_closed(text, text, text, boolean) to authenticated;
