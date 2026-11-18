-- Synthetic fixtures only; all writes, including queued mail, are rolled back.
begin;
create or replace function pg_temp.ok(c boolean, msg text) returns void language plpgsql as $$
begin if not coalesce(c, false) then raise exception 'FAIL: %', msg; end if; end $$;
insert into tutors(id,name,country,timezone) values ('aaaaaaaa-0000-4000-8000-0000000000e1','Eleanor Reed','Australia','Australia/Sydney');
insert into students(id,code,name_ko,name_en,timezone) values ('bbbbbbbb-0000-4000-8000-0000000000e1','STU-9481','한서준','Seojun Han','Asia/Seoul');
insert into enrollments(id,student_id,seq,contract_version,weeks,weekly_count,duration_min,start_date,base_end_date,lessons_purchased,status)
values ('cccccccc-0000-4000-8000-0000000000e1','bbbbbbbb-0000-4000-8000-0000000000e1',1,'SC2',4,3,40,current_date-7,current_date+20,12,'active');
insert into enrollment_periods(id,enrollment_id,idx,start_date,end_date,credits_granted)
values ('ffffffff-0000-4000-8000-0000000000e1','cccccccc-0000-4000-8000-0000000000e1',1,current_date-7,current_date+20,0);
insert into lessons(id,enrollment_id,student_id,tutor_id,kind,seq,starts_at,ends_at,state)
select ('dddddddd-0000-4000-8000-0000000000e'||i)::uuid,'cccccccc-0000-4000-8000-0000000000e1','bbbbbbbb-0000-4000-8000-0000000000e1','aaaaaaaa-0000-4000-8000-0000000000e1','regular',i,
 now()+i*interval '1 hour',now()+i*interval '1 hour'+interval '40 minutes','scheduled' from generate_series(1,4) i;
insert into app_users(auth_user_id,role,tutor_id) values ('eeeeeeee-0000-4000-8000-0000000000e1','tutor','aaaaaaaa-0000-4000-8000-0000000000e1');
select set_config('request.jwt.claims','{"sub":"eeeeeeee-0000-4000-8000-0000000000e1","aal":"aal1"}',true);
-- This fixture needs an ordinary day to exercise exhausted credits.
select pg_temp.ok(not exists(select 1 from holidays where day=((now()+interval '1 hour') at time zone 'Asia/Seoul')::date), 'ordinary-day fixture');
set local role authenticated;
do $test$
declare d jsonb;
begin
  d := tutor_student_cancel('99999999-0000-4000-8000-0000000000e1','dddddddd-0000-4000-8000-0000000000e1',now()-interval '5 hours',true);
  perform pg_temp.ok(d->>'status'='Student canceled in advance' and d->>'timing'='advance','exactly 6 hours = advance');
  perform pg_temp.ok(not (d ?| array['credits_left','credits_after','uses_credit','makeup_allowed','makeup_until']) and d::text not like '%No change credits left%', 'preview hides credits');
  d := tutor_student_cancel('99999999-0000-4000-8000-0000000000e1','dddddddd-0000-4000-8000-0000000000e1',now()-interval '5 hours',false);
  perform pg_temp.ok(d->>'status'='Student canceled in advance' and not(d ? 'credits_left'),'saved response hides credits');
  d := tutor_student_cancel('99999999-0000-4000-8000-0000000000e1','dddddddd-0000-4000-8000-0000000000e1',now()-interval '5 hours',false);
  perform pg_temp.ok(d->>'repeated'='true' and d->>'status'='Student canceled in advance' and not(d ? 'credits_left'),'replay hides credits');
  d := tutor_student_cancel('99999999-0000-4000-8000-0000000000e2','dddddddd-0000-4000-8000-0000000000e2',now()-interval '4 hours'+interval '1 millisecond',false);
  perform pg_temp.ok(d->>'status'='Student canceled late' and d->>'timing'='late','6 hours minus 1ms = late even with zero credits');
  d := tutor_screen(null,current_date-1,current_date+2);
  perform pg_temp.ok(d::text not like '%No change credits left%' and d::text not like '%credits_left%', 'screen hides credits');
  perform pg_temp.ok((select x->>'class_status' from jsonb_array_elements(d->'lessons') x where x->>'id'='dddddddd-0000-4000-8000-0000000000e1')='Student canceled in advance','screen advance');
  d := tutor_canceled_classes(null);
  perform pg_temp.ok(jsonb_array_length(d)=2 and d::text not like '%No change credits left%','cancel list includes exhausted-credit cancellation safely');
  d := tutor_updates_feed(null);
  perform pg_temp.ok((select count(*) from jsonb_array_elements(d) x where x->>'kind'='canceled')=2,'updates includes both cancellations');
  d := tutor_cancel_class('99999999-0000-4000-8000-0000000000e4','dddddddd-0000-4000-8000-0000000000e4','',true);
  perform pg_temp.ok(not(d ?| array['credits_left','credits_after','uses_credit']),'tutor own cancellation also hides balance');
end $test$;
reset role;
select pg_temp.ok((select class_status='No change credits left' from lessons where id='dddddddd-0000-4000-8000-0000000000e1'),'student internal outcome retained');
select pg_temp.ok((select consumes_lesson and not uses_credit and not tutor_paid from class_status_rules where status='No change credits left'),'student charged, no makeup, pay N');
select pg_temp.ok((select tutor_paid from class_status_rules where status='Student canceled late'),'late pay Y');
select pg_temp.ok((select count(*) from credit_ledger where period_id='ffffffff-0000-4000-8000-0000000000e1')=0,'zero-credit and late cancellations do not mutate balance');
-- Exception/restore credits affects only the student result, not tutor wording/pay.
update enrollment_periods set credits_granted=1 where id='ffffffff-0000-4000-8000-0000000000e1';
set local role authenticated;
do $test$
declare d jsonb;
begin
  d := tutor_student_cancel('99999999-0000-4000-8000-0000000000e3','dddddddd-0000-4000-8000-0000000000e3',now()-interval '3 hours',false);
  perform pg_temp.ok(d->>'status'='Student canceled in advance' and not(d ? 'credits_left'),'extra credit gives identical tutor response');
end $test$;
reset role;
select pg_temp.ok((select class_status='Student canceled in advance' from lessons where id='dddddddd-0000-4000-8000-0000000000e3'),'student makeup remains allowed with credit');
select pg_temp.ok(credit_balance('ffffffff-0000-4000-8000-0000000000e1')=0,'only the available student credit consumed');
select pg_temp.ok(not has_function_privilege('anon','tutor_screen(uuid,date,date)','execute'),'anonymous access still denied');
select pg_temp.ok(not has_function_privilege('authenticated','lms_tutor_cancel_decision(jsonb)','execute'),'internal helper is not public RPC');

-- Privilege tests use the actual authenticated role, not a database-owner view.
set local role authenticated;
do $test$
declare d jsonb; msg text; route text; denied boolean;
begin
  foreach route in array array[
    'select tutor_screen(null,current_date-1,current_date+3)',
    'select tutor_canceled_classes(null)', 'select tutor_updates_feed(null)',
    'select tutor_student_profile(''bbbbbbbb-0000-4000-8000-0000000000e1'')',
    'select tutor_student_profile(''bbbbbbbb-0000-4000-8000-0000000000e1'',null)',
    'select tutor_students_list(null)', 'select tutor_first_lesson_todos(null)',
    'select tutor_schedule(null,current_date,current_date+2,false)',
    'select tutor_hours(null)', 'select tutor_makeup_suggestions(null)',
    'select tutor_new_requests(null)', 'select tutor_time_off_list(null)'
  ] loop
    execute 'select coalesce(jsonb_agg(to_jsonb(q)), ''[]''::jsonb) from (' || route || ') q' into d;
    perform pg_temp.ok(coalesce(d::text,'') !~* '(credits_left|credits_after|credits_granted|credits_remaining|uses_credit|credit_balance|No change credits left)', 'private response: '||route);
  end loop;
  begin
    perform tutor_record_class('dddddddd-0000-4000-8000-0000000000e1','held','test','',false,null,false,null);
    raise exception 'unexpected record success';
  exception when others then
    perform pg_temp.ok(SQLERRM='This class was canceled. No record needed.','stale record error is private');
  end;
  begin
    perform tutor_record_class('dddddddd-0000-4000-8000-0000000000e1','held','test','',false);
    raise exception 'unexpected legacy record success';
  exception when others then
    perform pg_temp.ok(SQLERRM='This class was canceled. No record needed.','legacy record error is private');
  end;
  for i in 1..2 loop
    begin
      perform tutor_cancel_class('99999999-0000-4000-8000-0000000000e5','dddddddd-0000-4000-8000-0000000000e1','test',i=1);
      raise exception 'unexpected cancel success';
    exception when others then
      perform pg_temp.ok(SQLERRM='This class has already been processed. Please refresh.','stale cancel preview/save is private');
    end;
  end loop;
  perform pg_temp.ok(not exists(select 1 from lessons), 'raw lessons inaccessible');
  perform pg_temp.ok(not exists(select 1 from enrollment_periods), 'credit grants inaccessible');
  perform pg_temp.ok(not exists(select 1 from credit_ledger), 'credit changes inaccessible');
  perform pg_temp.ok(not exists(select 1 from change_requests), 'internal decisions inaccessible');
  perform pg_temp.ok(credit_balance('ffffffff-0000-4000-8000-0000000000e1') is null, 'balance RPC cannot bypass RLS');
  denied := false;
  begin perform student_screen('bbbbbbbb-0000-4000-8000-0000000000e1'); exception when insufficient_privilege then denied:=true; end;
  perform pg_temp.ok(denied,'student route rejects tutor');
  denied := false;
  begin perform admin_credits('bbbbbbbb-0000-4000-8000-0000000000e1'); exception when others then denied:=true; end;
  perform pg_temp.ok(denied,'admin credit route rejects tutor');
  d := tutor_cancel_class('99999999-0000-4000-8000-0000000000e4','dddddddd-0000-4000-8000-0000000000e4','synthetic QA',false);
  perform pg_temp.ok(d->>'status'='Tutor canceled late' and not(d ? 'credits_left'),'normal tutor cancellation retained');
  d := tutor_cancel_class('99999999-0000-4000-8000-0000000000e4','dddddddd-0000-4000-8000-0000000000e4','synthetic QA',false);
  perform pg_temp.ok(d->>'repeated'='true' and not(d ? 'credits_left'),'tutor cancellation replay retained');
end $test$;
reset role;
select pg_temp.ok(not(lms_tutor_cancel_decision('{"status":"No change credits left","future_credit_balance":123,"timing":"advance"}'::jsonb) ? 'future_credit_balance'),'new internal fields default to private');
-- Restoring/adding credits stays visible to the student, including history.
update enrollment_periods set credits_granted=3 where id='ffffffff-0000-4000-8000-0000000000e1';
insert into app_users(auth_user_id,role,student_id) values ('eeeeeeee-0000-4000-8000-0000000000e2','student','bbbbbbbb-0000-4000-8000-0000000000e1');
select set_config('request.jwt.claims','{"sub":"eeeeeeee-0000-4000-8000-0000000000e2","aal":"aal1"}',true);
set local role authenticated;
do $test$ declare d jsonb; begin
  d := student_screen(null);
  perform pg_temp.ok(d->'enrollment'->>'credits_left'='2' and d->'enrollment'->>'credits_granted'='3','student retains exact updated balance and grant');
  perform pg_temp.ok(jsonb_array_length(d->'credit_uses')=1 and jsonb_array_length(d->'credit_periods')=1,'student retains change history and periods');
  perform pg_temp.ok(d::text like '%No change credits left%','student retains own exhausted-credit outcome');
  perform pg_temp.ok(credit_balance('ffffffff-0000-4000-8000-0000000000e1')=2,'student balance access retained');
  perform pg_temp.ok((select count(*) from lessons)=4,'student lesson table access retained');
end $test$;
reset role;

select 'passed: cancellation boundaries, private tutor routes/errors/replays/table access, and student balances/history' as result;
rollback;
