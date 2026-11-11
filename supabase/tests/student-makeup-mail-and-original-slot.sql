-- Test DB only. Each scenario rolls back all fixture changes and pg_net requests.
-- Never commit these test transactions: no email should leave the database.
begin;
do $test$
declare a uuid; student_login uuid; chosen lessons; candidate lessons; decision jsonb; canceled jsonb; requested jsonb; repeated jsonb; slots jsonb; req uuid; original_blocked boolean := false; mail_count int; mode text := 'admin';
begin
 select auth_user_id into a from app_users where role='admin' limit 1;
 perform set_config('request.jwt.claims',jsonb_build_object('sub',a,'role','authenticated','aal','aal2')::text,true);
 for candidate in select l.* from lessons l join enrollments e on e.id=l.enrollment_id
   where l.state='scheduled' and l.kind='regular' and l.starts_at>now()+interval '6 hours' and l.starts_at<now()+interval '14 days'
    and e.final_end_date>current_date order by l.starts_at
 loop
   decision := admin_change_lesson(gen_random_uuid(),candidate.id,'student',null,true);
   if (decision->>'makeup_allowed')::boolean then chosen := candidate; exit; end if;
 end loop;
 if chosen.id is null then raise exception 'No eligible fixture'; end if;
 update students set email='qa-student@example.invalid' where id=chosen.student_id;
 update tutors set email='qa-tutor@example.invalid' where id=chosen.tutor_id;
 if mode='student' then
   select auth_user_id into student_login from app_users where role='student' limit 1;
   update app_users set student_id=chosen.student_id where auth_user_id=student_login;
   perform set_config('request.jwt.claims',jsonb_build_object('sub',student_login,'role','authenticated','aal','aal1')::text,true);
   canceled := student_change_lesson(gen_random_uuid(),chosen.id,false);
 else
   canceled := admin_change_lesson(gen_random_uuid(),chosen.id,'student',null,false);
 end if;
 select count(*) into mail_count from lesson_notices where change_request_id=(canceled->>'change_request_id')::uuid and email_notification_id is not null;
 if mail_count<>2 then raise exception 'Cancel mail count: %',mail_count; end if;
 if exists(select 1 from lms_makeup_options(chosen.id,null,null) where starts_at=chosen.starts_at) then raise exception 'Original slot is offered'; end if;
 if mode='admin' then
   begin
     perform admin_makeup_request(chosen.id,null,jsonb_build_array(jsonb_build_object('starts_at',chosen.starts_at)),null,null);
   exception when raise_exception then
     original_blocked := sqlerrm like '%원래 시간%';
     if not original_blocked then raise; end if;
   end;
 else
   begin
     perform student_makeup_request(chosen.id,null,jsonb_build_array(jsonb_build_object('starts_at',chosen.starts_at)),null);
   exception when raise_exception then
     original_blocked := sqlerrm like '%보강 가능한 날짜가 아닙니다%';
     if not original_blocked then raise; end if;
   end;
 end if;
 if not original_blocked then raise exception 'Original slot accepted'; end if;
 select jsonb_agg(jsonb_build_object('starts_at',o.starts_at)) into slots from (select starts_at from lms_makeup_options(chosen.id,null,null) limit 2) o;
 if slots is null then raise exception 'No available slots for fixture'; end if;
 if mode='student' then
   requested:=student_makeup_request(chosen.id,null,slots,null);
   repeated:=student_makeup_request(chosen.id,null,slots,null);
 else
   requested:=admin_makeup_request(chosen.id,null,slots,null,null);
   repeated:=admin_makeup_request(chosen.id,null,slots,null,null);
 end if;
 req:=(requested->>'makeup_request_id')::uuid;
 select count(*) into mail_count from lesson_notices where makeup_request_id=req and event='makeup_requested' and email_notification_id is not null;
 if mail_count<>2 or not (repeated->>'repeated')::boolean then raise exception 'Request mail or dedupe failed: %',mail_count; end if;
 if exists(select 1 from makeup_requests where id=req and confirmed_lesson_id is not null) then raise exception 'Prematurely confirmed'; end if;
 if exists(select 1 from lesson_notices n join notifications nt on nt.id=n.email_notification_id where n.makeup_request_id=req and (nt.payload->>'text' not like '%LMS%' or nt.payload->>'text' not like '%KST%' and nt.payload->>'text' not like '%한국 시간%')) then raise exception 'Mail lacks link or timezone'; end if;
 perform set_config('qa.result',jsonb_build_object('path',mode,'cancel_mails',2,'request_mails',2,'dedupe',true,'original_slot_hidden',true,'original_slot_server_blocked',original_blocked,'confirmed',false,'rolled_back',true)::text,true);
end $test$;
select current_setting('qa.result') as checks;
rollback;

begin;
do $test$
declare a uuid; student_login uuid; chosen lessons; candidate lessons; decision jsonb; canceled jsonb; requested jsonb; repeated jsonb; slots jsonb; req uuid; original_blocked boolean := false; mail_count int; mode text := 'student';
begin
 select auth_user_id into a from app_users where role='admin' limit 1;
 perform set_config('request.jwt.claims',jsonb_build_object('sub',a,'role','authenticated','aal','aal2')::text,true);
 for candidate in select l.* from lessons l join enrollments e on e.id=l.enrollment_id
   where l.state='scheduled' and l.kind='regular' and l.starts_at>now()+interval '6 hours' and l.starts_at<now()+interval '14 days'
    and e.final_end_date>current_date order by l.starts_at
 loop
   decision := admin_change_lesson(gen_random_uuid(),candidate.id,'student',null,true);
   if (decision->>'makeup_allowed')::boolean then chosen := candidate; exit; end if;
 end loop;
 if chosen.id is null then raise exception 'No eligible fixture'; end if;
 update students set email='qa-student@example.invalid' where id=chosen.student_id;
 update tutors set email='qa-tutor@example.invalid' where id=chosen.tutor_id;
 if mode='student' then
   select auth_user_id into student_login from app_users where role='student' limit 1;
   update app_users set student_id=chosen.student_id where auth_user_id=student_login;
   perform set_config('request.jwt.claims',jsonb_build_object('sub',student_login,'role','authenticated','aal','aal1')::text,true);
   canceled := student_change_lesson(gen_random_uuid(),chosen.id,false);
 else
   canceled := admin_change_lesson(gen_random_uuid(),chosen.id,'student',null,false);
 end if;
 select count(*) into mail_count from lesson_notices where change_request_id=(canceled->>'change_request_id')::uuid and email_notification_id is not null;
 if mail_count<>2 then raise exception 'Cancel mail count: %',mail_count; end if;
 if exists(select 1 from lms_makeup_options(chosen.id,null,null) where starts_at=chosen.starts_at) then raise exception 'Original slot is offered'; end if;
 if mode='admin' then
   begin
     perform admin_makeup_request(chosen.id,null,jsonb_build_array(jsonb_build_object('starts_at',chosen.starts_at)),null,null);
   exception when raise_exception then
     original_blocked := sqlerrm like '%원래 시간%';
     if not original_blocked then raise; end if;
   end;
 else
   begin
     perform student_makeup_request(chosen.id,null,jsonb_build_array(jsonb_build_object('starts_at',chosen.starts_at)),null);
   exception when raise_exception then
     original_blocked := sqlerrm like '%보강 가능한 날짜가 아닙니다%';
     if not original_blocked then raise; end if;
   end;
 end if;
 if not original_blocked then raise exception 'Original slot accepted'; end if;
 select jsonb_agg(jsonb_build_object('starts_at',o.starts_at)) into slots from (select starts_at from lms_makeup_options(chosen.id,null,null) limit 2) o;
 if slots is null then raise exception 'No available slots for fixture'; end if;
 if mode='student' then
   requested:=student_makeup_request(chosen.id,null,slots,null);
   repeated:=student_makeup_request(chosen.id,null,slots,null);
 else
   requested:=admin_makeup_request(chosen.id,null,slots,null,null);
   repeated:=admin_makeup_request(chosen.id,null,slots,null,null);
 end if;
 req:=(requested->>'makeup_request_id')::uuid;
 select count(*) into mail_count from lesson_notices where makeup_request_id=req and event='makeup_requested' and email_notification_id is not null;
 if mail_count<>2 or not (repeated->>'repeated')::boolean then raise exception 'Request mail or dedupe failed: %',mail_count; end if;
 if exists(select 1 from makeup_requests where id=req and confirmed_lesson_id is not null) then raise exception 'Prematurely confirmed'; end if;
 if exists(select 1 from lesson_notices n join notifications nt on nt.id=n.email_notification_id where n.makeup_request_id=req and (nt.payload->>'text' not like '%LMS%' or nt.payload->>'text' not like '%KST%' and nt.payload->>'text' not like '%한국 시간%')) then raise exception 'Mail lacks link or timezone'; end if;
 perform set_config('qa.result',jsonb_build_object('path',mode,'cancel_mails',2,'request_mails',2,'dedupe',true,'original_slot_hidden',true,'original_slot_server_blocked',original_blocked,'confirmed',false,'rolled_back',true)::text,true);
end $test$;
select current_setting('qa.result') as checks;
rollback;
