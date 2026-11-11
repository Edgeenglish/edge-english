-- Test-project read-only regression probe. Uses existing fixtures; creates no records.
-- Invoke after the migration, within BEGIN/ROLLBACK. Output is aggregate only.
do $$
declare
  admin_uid uuid; student_uid uuid; sid uuid; other_sid uuid; tutor_uid uuid;
  row record; events jsonb; mine jsonb; denied boolean; checked int := 0; total int := 0;
  old_counts jsonb;
begin
  select auth_user_id into admin_uid from app_users where role = 'admin' limit 1;
  select auth_user_id, student_id into student_uid, sid from app_users where role = 'student' limit 1;
  select id into other_sid from students where id <> sid limit 1;
  select auth_user_id into tutor_uid from app_users where role = 'tutor' limit 1;
  if admin_uid is null or student_uid is null or other_sid is null or tutor_uid is null then
    raise exception 'History QA needs existing admin, two students, and tutor fixtures';
  end if;
  old_counts := jsonb_build_array((select count(*) from students), (select count(*) from lessons),
    (select count(*) from payments), (select count(*) from notifications), (select count(*) from audit_log));
  perform set_config('request.jwt.claims', jsonb_build_object('sub', admin_uid, 'aal', 'aal2')::text, true);
  for row in select id from students loop
    events := student_processing_history(row.id);
    if exists (select 1 from jsonb_array_elements(events) e
      left join audit_log a on a.id = split_part(e->>'id', ':', 1)::bigint
      where a.id is null or a.new_row->>'student_id' <> row.id::text or (e->>'at')::timestamptz <> a.at) then
      raise exception 'History ownership or actual processing timestamp mismatch';
    end if;
    if exists (select 1 from (select (e->>'at')::timestamptz at,
      lag((e->>'at')::timestamptz) over (order by ord) prev from jsonb_array_elements(events) with ordinality x(e,ord)) x where at > prev) then
      raise exception 'History is not newest first';
    end if;
    if jsonb_array_length(events) <> (select count(distinct e->>'id') from jsonb_array_elements(events) e) then
      raise exception 'Duplicate processing event';
    end if;
    if exists (select 1 from jsonb_array_elements(events) e cross join lateral jsonb_object_keys(e) k
      where k not in ('id','at','kind','request_id','lesson_at','original_date','tutor','compensation','tutor_fault','booked_at','slots')) then
      raise exception 'Unreviewed field exposed';
    end if;
    checked := checked + 1; total := total + jsonb_array_length(events);
  end loop;
  mine := student_processing_history(sid);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', student_uid, 'aal', 'aal1')::text, true);
  set local role authenticated;
  if student_processing_history(null) <> mine or student_processing_history(sid) <> mine then
    raise exception 'Student own history differs from admin view';
  end if;
  denied := false;
  begin perform student_processing_history(other_sid); exception when insufficient_privilege then denied := true; end;
  if not denied then raise exception 'Other student history exposed'; end if;
  perform set_config('request.jwt.claims', jsonb_build_object('sub', tutor_uid, 'aal', 'aal2')::text, true);
  denied := false;
  begin perform student_processing_history(sid); exception when insufficient_privilege then denied := true; end;
  if not denied then raise exception 'Tutor can access student history'; end if;
  perform set_config('request.jwt.claims', jsonb_build_object('sub', admin_uid, 'aal', 'aal1')::text, true);
  denied := false;
  begin perform student_processing_history(sid); exception when insufficient_privilege then denied := true; end;
  if not denied then raise exception 'Admin without MFA can access history'; end if;
  perform set_config('request.jwt.claims', '{}', true);
  denied := false;
  begin perform student_processing_history(sid); exception when insufficient_privilege then denied := true; end;
  if not denied then raise exception 'Missing identity can access history'; end if;
  reset role;
  if has_function_privilege('anon', 'public.student_processing_history(uuid)', 'EXECUTE') then
    raise exception 'Anonymous execute must be revoked';
  end if;
  if old_counts <> jsonb_build_array((select count(*) from students), (select count(*) from lessons),
    (select count(*) from payments), (select count(*) from notifications), (select count(*) from audit_log)) then
    raise exception 'Read operation changed data';
  end if;
  perform set_config('history.qa_result', jsonb_build_object('students_checked',checked,'events_checked',total,
    'ownership_sort_unique_allowlist','passed','student_other_tutor_admin_mfa_anon','passed','data_unchanged','passed')::text,true);
end $$;
select current_setting('history.qa_result')::jsonb as history_qa;
