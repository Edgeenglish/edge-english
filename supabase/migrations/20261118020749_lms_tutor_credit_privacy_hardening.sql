-- Tutor credit privacy: stale-form errors and direct REST reads must not reveal
-- the internal exhausted-credit status. Student/admin policies remain intact.
-- All tutor screens use authenticated SECURITY DEFINER RPCs, not table reads.
alter policy tutor_own on public.lessons using (false);

-- Allowlist the tutor response, so new internal decision fields stay private.
create or replace function public.lms_tutor_cancel_decision(d jsonb)
returns jsonb language sql immutable security invoker set search_path = public as $$
  select coalesce(jsonb_object_agg(key, value), '{}'::jsonb)
    || jsonb_build_object('status', public.lms_tutor_class_status((d ->> 'status')::public.class_status))
  from jsonb_each(d)
  where key = any(array['lesson_id', 'who', 'timing', 'requested_at', 'starts_at',
    'hours_before', 'reward_won', 'holiday', 'dry_run', 'repeated', 'change_request_id'])
$$;
revoke all on function public.lms_tutor_cancel_decision(jsonb) from public, anon, authenticated;

do $patch$
declare def text; old text; replacement text;
begin
  def := pg_get_functiondef('public.tutor_record_class(uuid,text,text,text,boolean,integer,boolean,integer)'::regprocedure);
  old := 'raise exception ''This class was canceled (%). No record needed.'', coalesce(l.class_status::text, ''removed'') using hint = ''canceled'';';
  replacement := 'raise exception ''This class was canceled. No record needed.'' using hint = ''canceled'';';
  if position(old in def) = 0 then raise exception 'Unexpected tutor_record_class body'; end if;
  execute replace(def, old, replacement);

  def := pg_get_functiondef('public.tutor_cancel_class(uuid,uuid,text,boolean)'::regprocedure);
  old := '  v_result := lms_change_core(v_key, p_lesson, ''tutor'',';
  replacement := $body$  -- Preserve committed-request replay, but never expose core's raw-status error.
  if v_lesson.state <> 'scheduled' and (p_dry_run or not exists (
    select 1 from change_requests where idempotency_key = v_key
  )) then
    raise exception 'This class has already been processed. Please refresh.' using hint = 'not_scheduled';
  end if;
  v_result := lms_change_core(v_key, p_lesson, 'tutor',$body$;
  if position(old in def) = 0 then raise exception 'Unexpected tutor_cancel_class body'; end if;
  execute replace(def, old, replacement);
end
$patch$;
