-- =====================================================================
-- 강사 화면 수업 취소 입구 (ChatGPT 작업, 시험 DB 에 11/9 lms_tutor_cancel_entry 로 먼저 적용됨 — 저장소에 파일이 없어 시험 DB 기록 그대로 옮김)
--  운영 DB 미적용. 취소 규칙·변경권·적립금·보강·안내는 기존 lms_change_core·트리거 그대로
-- =====================================================================
-- Entry point only: cancellation policy, credits, rewards, make-up and notices
-- remain in the existing lms_change_core and its triggers.
-- Rollback: drop function public.tutor_cancel_class(uuid, uuid, text, boolean);
create or replace function public.tutor_cancel_class(
  p_request_id uuid, p_lesson uuid, p_reason text, p_dry_run boolean
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_admin boolean := is_admin();
  v_mine uuid := my_tutor_id();
  v_lesson lessons;
  v_result jsonb;
  v_key text;
begin
  if auth.uid() is null then
    raise exception 'Sign in to cancel a class.' using errcode = '42501';
  end if;
  select * into v_lesson from lessons where id = p_lesson for update;
  if not found or not coalesce((v_admin or (my_role() = 'tutor' and v_mine is not null and v_lesson.tutor_id = v_mine)), false) then
    raise exception 'You can only cancel your own classes.' using errcode = '42501';
  end if;
  if p_request_id is null or p_dry_run is null then raise exception 'Invalid cancellation request.'; end if;
  if length(coalesce(p_reason, '')) > 500 then raise exception 'Reason must be 500 characters or fewer.'; end if;
  if not p_dry_run and nullif(trim(p_reason), '') is null then raise exception 'Enter a cancellation reason.'; end if;
  if v_lesson.voided_at is not null or exists (select 1 from payroll_items where lesson_id = p_lesson) then
    raise exception 'This class cannot be canceled.';
  end if;
  if exists (select 1 from leave_items li where li.lesson_id = p_lesson and li.lesson_gone_at is null
    and (li.choice = 'undecided' or (li.choice = 'substitute' and li.sub_stage <> 'confirmed'))) then
    raise exception 'This class is being arranged by Edge English.';
  end if;
  v_key := 'tutor_cancel:' || auth.uid()::text || ':' || p_lesson::text || ':' || p_request_id::text;
  v_result := lms_change_core(v_key, p_lesson, 'tutor',
    case when v_admin then 'admin_on_behalf' else 'tutor_app' end, now(), p_dry_run, auth.uid());
  if not p_dry_run and not coalesce((v_result ->> 'repeated')::boolean, false) then
    update change_requests set reason = trim(p_reason) where id = (v_result ->> 'change_request_id')::uuid;
  end if;
  return v_result;
end $$;
revoke all on function public.tutor_cancel_class(uuid, uuid, text, boolean) from public, anon;
grant execute on function public.tutor_cancel_class(uuid, uuid, text, boolean) to authenticated;
