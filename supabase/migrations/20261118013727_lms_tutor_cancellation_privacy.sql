-- 2026-11-18 대표 승인: 강사에게 변경권 잔고/소진 여부를 노출하지 않는다.
-- POL-CHG-01·04: 사전 취소 Pay N, 직전 취소 Pay Y. 학생 차감/보강 판정은 그대로.
-- lms_change_core 는 6시간 미만 여부를 변경권보다 먼저 판정한다.

update public.class_status_rules set tutor_paid = false where status = 'No change credits left';

-- 데이터 조회 없는 내부 표시 변환. 기존 RPC의 소유권/인증 검사는 유지한다.
create or replace function public.lms_tutor_class_status(s public.class_status)
returns public.class_status language sql immutable security invoker set search_path = public as $$
  select case when s in ('No change credits left', 'Student canceled in advance (public holiday)')
    then 'Student canceled in advance'::public.class_status else s end
$$;
revoke all on function public.lms_tutor_class_status(public.class_status) from public, anon, authenticated;

create or replace function public.lms_tutor_cancel_decision(d jsonb)
returns jsonb language sql immutable security invoker set search_path = public as $$
  select (d - array['credits_left', 'credits_after', 'uses_credit', 'makeup_allowed', 'makeup_until', 'policy_refs'])
    || jsonb_build_object('status', public.lms_tutor_class_status((d ->> 'status')::public.class_status))
$$;
revoke all on function public.lms_tutor_cancel_decision(jsonb) from public, anon, authenticated;

-- 최신 함수의 인증/기능은 보존하고 강사에게 반환하는 부분만 수정. 모양이 다르면 중단.
do $patch$
declare
  f text;
  def text;
  old text;
  replacement text;
begin
  foreach f in array array['tutor_screen(uuid,date,date)', 'tutor_canceled_classes(uuid)'] loop
    def := pg_get_functiondef(('public.' || f)::regprocedure);
    old := '''class_status'', l.class_status';
    replacement := '''class_status'', public.lms_tutor_class_status(l.class_status)';
    if position(replacement in def) = 0 then
      if position(old in def) = 0 then raise exception 'Unexpected function body: %', f; end if;
      execute replace(def, old, replacement);
    end if;
  end loop;

  foreach f in array array['tutor_canceled_classes(uuid)', 'tutor_updates_feed(uuid)'] loop
    def := pg_get_functiondef(('public.' || f)::regprocedure);
    old := 'l.class_status in (''Student canceled in advance'', ''Student canceled in advance (public holiday)'', ''Student canceled late'')';
    replacement := 'l.class_status in (''Student canceled in advance'', ''Student canceled in advance (public holiday)'', ''Student canceled late'', ''No change credits left'')';
    if position(replacement in def) = 0 then
      if position(old in def) = 0 then raise exception 'Unexpected cancellation filter: %', f; end if;
      execute replace(def, old, replacement);
    end if;
  end loop;

  def := pg_get_functiondef('public.tutor_student_cancel(uuid,uuid,timestamptz,boolean)'::regprocedure);
  if position('return lms_tutor_cancel_decision(' in def) = 0 then
    if position('return lms_change_core(' in def) = 0 then raise exception 'Unexpected tutor_student_cancel body'; end if;
    def := replace(def, 'return lms_change_core(', 'return lms_tutor_cancel_decision(lms_change_core(');
    def := replace(def, 'auth.uid());', 'auth.uid()));');
    execute def;
  end if;

  def := pg_get_functiondef('public.tutor_cancel_class(uuid,uuid,text,boolean)'::regprocedure);
  if position('return lms_tutor_cancel_decision(v_result);' in def) = 0 then
    if position('return v_result;' in def) = 0 then raise exception 'Unexpected tutor_cancel_class body'; end if;
    execute replace(def, 'return v_result;', 'return lms_tutor_cancel_decision(v_result);');
  end if;
end
$patch$;
