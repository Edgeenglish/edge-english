-- Align the effective date shown and saved with the tutor's next local Monday.
-- No booking, collision, availability, authorization, or existing row changes.
-- Read the current definitions so unrelated concurrent function edits are preserved.
do $migration$
declare
  signature text;
  definition text;
  updated text;
begin
  foreach signature in array array['public.tutor_hours(uuid)', 'public.tutor_hours_save(uuid,text[],text[],text[])'] loop
    definition := pg_get_functiondef(signature::regprocedure);
    if position('v_from date := lms_next_monday();' in definition) = 0 then
      raise exception 'Unexpected effective-date definition: %', signature;
    end if;
    updated := replace(definition, 'v_from date := lms_next_monday();', 'v_from date;');
    if signature = 'public.tutor_hours(uuid)' then
      updated := replace(updated, 'v_mon := lms_local_monday(t.timezone);', 'v_mon := lms_local_monday(t.timezone);' || chr(10) || '  v_from := v_mon + 7;');
    else
      updated := replace(updated, 'v_mon := lms_local_monday(v_tz);', 'v_mon := lms_local_monday(v_tz);' || chr(10) || '  v_from := v_mon + 7;');
    end if;
    if position('v_from := v_mon + 7;' in updated) = 0 then
      raise exception 'Tutor local Monday calculation missing: %', signature;
    end if;
    execute updated;
  end loop;
end $migration$;
