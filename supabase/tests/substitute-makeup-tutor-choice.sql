-- 시험 DB 전용. 합성 데이터·발송 대기열을 모두 rollback; 외부 메일 발송 없음.
begin;
do $test$
declare
  a uuid:=gen_random_uuid(); u uuid:=gen_random_uuid(); tu uuid:=gen_random_uuid();
  st uuid; other_st uuid; enr uuid; orig uuid; sub uuid; other_t uuid;
  src uuid; comp uuid; req uuid; booked uuid; slot timestamptz; opts jsonb; result jsonb; again jsonb;
  state_name text; teacher uuid; count_checks int:=0; denied boolean;
begin
  insert into tutors(name,country,timezone,email) values('Eleanor Brooks','Australia','Asia/Seoul','emma@example.invalid') returning id into orig;
  insert into tutors(name,country,timezone,email) values('Ethan Quinn','Australia','Asia/Seoul','james@example.invalid') returning id into sub;
  insert into tutors(name,country,timezone,email) values('Lucas Reed','Australia','Asia/Seoul','lucas@example.invalid') returning id into other_t;
  insert into students(name_ko,name_en,timezone,email) values('박서연','Seoyeon','Asia/Seoul','seoyeon@example.invalid') returning id into st;
  insert into students(name_ko,name_en,timezone,email) values('윤지호','Jiho','Asia/Seoul','jiho@example.invalid') returning id into other_st;
  insert into enrollments(student_id,seq,contract_version,weeks,weekly_count,duration_min,start_date,base_end_date,lessons_purchased,status)
    values(st,1,'SC2',4,3,40,current_date-24,current_date+3,12,'active') returning id into enr;
  insert into app_users(auth_user_id,role,admin_level) values(a,'admin','owner');
  insert into app_users(auth_user_id,role,student_id) values(u,'student',st);
  insert into app_users(auth_user_id,role,tutor_id) values(tu,'tutor',orig);
  insert into tutor_availability(tutor_id,weekday,start_local,end_local,timezone,effective_from)
    select t,w,case when t=orig then time '09:00' else time '14:00' end,case when t=orig then time '10:00' else time '15:00' end,'Asia/Seoul',current_date-30
    from unnest(array[orig,sub,other_t]) t cross join generate_series(0,6) w;
  foreach state_name in array array['Student canceled in advance','Student canceled in advance (public holiday)','Tutor canceled in advance','Tutor canceled late','Tutor no-show'] loop
    insert into lessons(enrollment_id,student_id,tutor_id,original_tutor_id,kind,seq,starts_at,ends_at,state,class_status,canceled_at)
      values(enr,st,sub,orig,case when state_name like 'Student%' then 'migrated_makeup' else 'regular' end,case when state_name like 'Student%' then null else count_checks+1 end,now()-interval '2 days',now()-interval '2 days'+interval '40 minutes',case when state_name='Tutor no-show' then 'done' else 'canceled' end,state_name::class_status,now()) returning id into src;
    if jsonb_array_length(lms_makeup_tutors(src,null,null))<>2 then raise exception 'Both tutors missing: %',state_name; end if;
    count_checks:=count_checks+1;
    perform set_config('request.jwt.claims',jsonb_build_object('sub',u,'aal','aal1')::text,true);
    foreach teacher in array array[orig,sub] loop
      select starts_at into slot from student_makeup_options_for_tutor(null,src,null,null,teacher) where starts_at>now()+interval '1 day' limit 1;
      if slot is null then raise exception 'Missing selected tutor availability'; end if;
      if teacher=orig and (slot at time zone 'Asia/Seoul')::time not between time '09:00' and time '10:00' then raise exception 'Wrong tutor calendar'; end if;
      if teacher=sub and (slot at time zone 'Asia/Seoul')::time not between time '14:00' and time '15:00' then raise exception 'Wrong cover calendar'; end if;
      result:=student_makeup_request_for_tutor(null,src,null,null,teacher,jsonb_build_array(jsonb_build_object('starts_at',slot)));
      req:=(result->>'makeup_request_id')::uuid;
      if not exists(select 1 from makeup_requests where id=req and tutor_id=teacher and status='requested' and confirmed_lesson_id is null) then raise exception 'Wrong request tutor/state'; end if;
      again:=student_makeup_request_for_tutor(null,src,null,null,teacher,jsonb_build_array(jsonb_build_object('starts_at',slot)));
      if not (again->>'repeated')::boolean then raise exception 'Duplicate request'; end if;
      if (select count(*) from lesson_notices where makeup_request_id=req and event='makeup_requested' and email_notification_id is not null)<>2 then raise exception 'Missing request mails'; end if;
      if not exists(select 1 from lesson_notices where makeup_request_id=req and recipient_kind='tutor' and recipient_id=teacher) then raise exception 'Wrong email recipient'; end if;
      denied:=false;
      begin
        select starts_at into slot from student_makeup_options_for_tutor(null,src,null,null,case when teacher=orig then sub else orig end) limit 1;
        perform student_makeup_request_for_tutor(null,src,null,null,case when teacher=orig then sub else orig end,jsonb_build_array(jsonb_build_object('starts_at',slot)));
      exception when raise_exception then denied:=sqlerrm like '%이미 다른 강사%'; end;
      if not denied then raise exception 'Competing tutor request accepted'; end if;
      perform student_makeup_withdraw(null,req);
      count_checks:=count_checks+5;
    end loop;
  end loop;
  -- 무료 보상수업은 노쇼 강사 고정.
  insert into compensations(student_id,enrollment_id,source_lesson_id,reason,confirmed_by) values(st,enr,src,'tutor_no_show',a) returning id into comp;
  if jsonb_array_length(lms_makeup_tutors(null,null,comp))<>1 or lms_makeup_tutors(null,null,comp)->0->>'id'<>sub::text then raise exception 'Compensation not fixed'; end if;
  denied:=false;
  begin perform student_makeup_options_for_tutor(null,null,null,comp,orig); exception when invalid_parameter_value then denied:=true; end;
  if not denied then raise exception 'Compensation original tutor allowed'; end if;
  denied:=false;
  begin perform student_makeup_options_for_tutor(null,src,null,null,other_t); exception when invalid_parameter_value then denied:=true; end;
  if not denied then raise exception 'Unrelated tutor allowed'; end if;
  denied:=false;
  begin perform student_makeup_options_for_tutor(other_st,src,null,null,orig); exception when insufficient_privilege then denied:=true; end;
  if not denied then raise exception 'Other student allowed'; end if;
  count_checks:=count_checks+4;
  -- 운영자 대신 입력도 같은 검증, 확정과 메일은 선택한 강사로 이어짐.
  perform set_config('request.jwt.claims',jsonb_build_object('sub',a,'aal','aal2')::text,true);
  select starts_at into slot from student_makeup_options_for_tutor(st,src,null,null,orig) where starts_at>now()+interval '1 day' limit 1;
  result:=student_makeup_request_for_tutor(st,src,null,null,orig,jsonb_build_array(jsonb_build_object('starts_at',slot)));
  req:=(result->>'makeup_request_id')::uuid;
  perform set_config('request.jwt.claims',jsonb_build_object('sub',tu,'aal','aal1')::text,true);
  result:=tutor_makeup_confirm(req,(select id from makeup_candidates where request_id=req limit 1));
  booked:=(select confirmed_lesson_id from makeup_requests where id=req);
  if not exists(select 1 from lessons where id=booked and tutor_id=orig and makeup_of=src and kind='makeup') then raise exception 'Booked wrong tutor'; end if;
  if (select count(*) from lesson_notices where makeup_request_id=req and event='makeup_confirmed' and email_notification_id is not null)<>2 then raise exception 'Missing confirmed mails'; end if;
  if not exists(select 1 from compensations where id=comp and status='available') then raise exception 'Ordinary makeup consumed compensation'; end if;
  count_checks:=count_checks+4;
  -- 학생 화면에 원래/대체 선택 및 보상 강사 1명이 분리되어 노출.
  perform set_config('request.jwt.claims',jsonb_build_object('sub',u,'aal','aal1')::text,true);
  result:=student_screen(null);
  if not exists(select 1 from jsonb_array_elements(result->'makeup_rights') r where r->>'comp_id'=comp::text and jsonb_array_length(r->'tutor_choices')=1) then raise exception 'Screen compensation choices'; end if;
  if not exists(select 1 from jsonb_array_elements(result->'makeup_rights') r where jsonb_array_length(r->'tutor_choices')=2) then raise exception 'Screen both choices'; end if;
  if has_function_privilege('anon','student_makeup_request_for_tutor(uuid,uuid,uuid,uuid,uuid,jsonb)','EXECUTE') or has_function_privilege('authenticated','lms_makeup_request_for_tutor(uuid,uuid,jsonb,timestamptz,text,uuid,uuid,uuid)','EXECUTE') then raise exception 'Private helper exposed'; end if;
  count_checks:=count_checks+3;
  select starts_at into slot from student_makeup_options_for_tutor(null,null,null,comp,sub) where starts_at>now()+interval '1 day' limit 1;
  result:=student_makeup_request_for_tutor(null,null,null,comp,sub,jsonb_build_array(jsonb_build_object('starts_at',slot)));
  req:=(result->>'makeup_request_id')::uuid;
  update app_users set tutor_id=sub where auth_user_id=tu;
  perform set_config('request.jwt.claims',jsonb_build_object('sub',tu,'aal','aal1')::text,true);
  result:=tutor_makeup_confirm(req,(select id from makeup_candidates where request_id=req limit 1));
  booked:=(select confirmed_lesson_id from makeup_requests where id=req);
  if not exists(select 1 from lessons where id=booked and tutor_id=sub and kind='compensation' and compensation_id=comp) then raise exception 'Compensation tutor/kind changed'; end if;
  if not exists(select 1 from compensations where id=comp and status='used' and used_lesson_id=booked) then raise exception 'Compensation usage missing'; end if;
  count_checks:=count_checks+2;
  perform set_config('qa.result',jsonb_build_object('checks',count_checks,'all_passed',true,'rolled_back',true)::text,true);
end $test$;
select current_setting('qa.result') as result;
rollback;
