-- Test DB virtual tutor only. All fixture/function writes roll back.
begin;
select set_config('request.jwt.claims','{"sub":"a889003b-dfc6-47fa-b583-b0c4428fe627","role":"authenticated","aal":"aal2"}',true);
CREATE OR REPLACE FUNCTION public.lms_local_monday(p_tz text)
 RETURNS date
 LANGUAGE sql
 STABLE
AS $function$
  select d - (extract(isodow from d)::int - 1) from (select (current_setting('edge.qa_clock')::timestamptz at time zone p_tz)::date as d) x
$function$
;
create temp table qa_monday_results(zone text, clock timestamptz, expected date, loaded date, saved date, row_ok boolean) on commit drop;
do $qa$
declare c record; h jsonb; w text[]; result jsonb;
begin
 for c in select * from (values
 ('America/Toronto','2026-11-15T15:30Z'::timestamptz,'2026-11-16'::date),
 ('Australia/Sydney','2026-11-15T13:30Z'::timestamptz,'2026-11-23'::date),
 ('America/Toronto','2027-03-14T07:30Z'::timestamptz,'2027-03-15'::date),
 ('America/Toronto','2026-11-01T06:30Z'::timestamptz,'2026-11-02'::date),
 ('Australia/Sydney','2026-10-03T16:30Z'::timestamptz,'2026-10-05'::date),
 ('Australia/Sydney','2027-04-03T16:30Z'::timestamptz,'2027-04-05'::date),
 ('Asia/Seoul','2026-12-31T15:30Z'::timestamptz,'2027-01-04'::date),
 ('Asia/Seoul','2026-11-15T15:00Z'::timestamptz,'2026-11-23'::date)
 ) t(zone,clock,expected) loop
  perform set_config('edge.qa_clock',c.clock::text,true);
  update tutors set timezone=c.zone where id='39a06579-decf-4452-8f99-45dc6ea547fd';
  h:=tutor_hours('39a06579-decf-4452-8f99-45dc6ea547fd');
  w:=array(select jsonb_array_elements_text(h->'weekly_open'));
  if '0:06:00'=any(w) then w:=w||array['0:06:30']; else w:=w||array['0:06:00']; end if;
  result:=tutor_hours_save('39a06579-decf-4452-8f99-45dc6ea547fd',w,'{}','{}');
  if (h->>'from')::date<>c.expected or (result->>'from')::date<>c.expected then raise exception 'Date mismatch %',c; end if;
  insert into qa_monday_results select c.zone,c.clock,c.expected,(h->>'from')::date,(result->>'from')::date,exists(select 1 from tutor_availability where tutor_id='39a06579-decf-4452-8f99-45dc6ea547fd' and effective_from=c.expected);
 end loop;
end $qa$;
select * from qa_monday_results;
rollback;
