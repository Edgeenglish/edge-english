-- 시험 DB만. 실제 함수·메일 생성까지 확인 후 모두 rollback (발송 없음).
begin;
do $test$
declare a uuid:=gen_random_uuid(); u uuid:=gen_random_uuid(); orig uuid; sub uuid; st uuid; enr uuid; off_id uuid;
  lid uuid; li uuid; items uuid[]:='{}'; t timestamptz; n int; r jsonb; body text; mail_id uuid; replies int;
begin
  insert into tutors(name,country,timezone,email) values('Eleanor Brooks','Australia','Asia/Seoul','eleanor@example.invalid') returning id into orig;
  insert into tutors(name,country,timezone,email) values('Ethan Quinn','Australia','Asia/Seoul','ethan@example.invalid') returning id into sub;
  update tutors set meet_url='https://meet.google.com/abc-defg-hij' where id=sub;
  insert into students(name_ko,name_en,timezone,email) values('박서연','Seoyeon','Asia/Seoul','seoyeon@example.invalid') returning id into st;
  insert into enrollments(student_id,seq,contract_version,weeks,weekly_count,duration_min,start_date,base_end_date,lessons_purchased,status)
    values(st,1,'SC2',4,3,40,current_date-20,current_date+7,12,'active') returning id into enr;
  insert into app_users(auth_user_id,role,admin_level) values(a,'admin','owner');
  insert into app_users(auth_user_id,role,tutor_id) values(u,'tutor',sub);
  insert into tutor_availability(tutor_id,weekday,start_local,end_local,timezone,effective_from)
    select sub,w,'09:00','17:00','Asia/Seoul',current_date-30 from generate_series(0,6) w;
  insert into tutor_time_off(tutor_id,starts_at,ends_at,kind,reason) values(orig,current_date,current_date+8,'leave','personal') returning id into off_id;
  for n in 1..3 loop
    t:=(current_date+n+time '10:00') at time zone 'Asia/Seoul';
    insert into lessons(enrollment_id,student_id,tutor_id,kind,seq,starts_at,ends_at,state)
      values(enr,st,orig,'regular',n,t,t+interval '40 minutes','scheduled') returning id into lid;
    insert into leave_items(time_off_id,tutor_id,student_id,enrollment_id,lesson_id,starts_at,ends_at)
      values(off_id,orig,st,enr,lid,t,t+interval '40 minutes') returning id into li;
    items:=array_append(items,li);
  end loop;
  perform set_config('request.jwt.claims',jsonb_build_object('sub',a,'aal','aal2')::text,true);
  perform admin_leave_choose(items,'substitute',sub);
  perform lms_cover_mail_run(now(),now()-interval '1 minute',false);
  if (select count(distinct email_notification_id) from lesson_notices where leave_item_id=any(items) and event='sub_ask')<>1 then raise exception 'Request not grouped into one mail'; end if;
  perform set_config('request.jwt.claims',jsonb_build_object('sub',u,'aal','aal1')::text,true);
  r:=tutor_sub_answer(items,array[items[1],items[3]]);
  if (r->>'yes')::int<>2 then raise exception 'Mixed reply failed'; end if;
  select count(*) into replies from lesson_notices where leave_item_id=any(items) and event='sub_ask' and cover_answer is not null;
  if replies<>3 then raise exception 'Reply snapshot missing'; end if;
  if exists(select 1 from lesson_notices where leave_item_id=any(items) and event='sub_confirmed') then raise exception 'Accepted was prematurely confirmed'; end if;
  perform set_config('request.jwt.claims',jsonb_build_object('sub',a,'aal','aal2')::text,true);
  perform admin_leave_student_ok(array[items[1]]);
  set constraints lesson_notices_sub_confirmed_mail immediate;
  select email_notification_id into mail_id from lesson_notices where leave_item_id=items[1] and event='sub_confirmed' and recipient_kind='tutor';
  select payload->>'text' into body from notifications where id=mail_id;
  if body is null or body not like '%Confirmed:%' or body not like '%You marked unavailable:%' or body not like '%Available - awaiting final confirmation:%' then raise exception 'Reply sections missing'; end if;
  for n in 1..3 loop
    t:=(current_date+n+time '10:00') at time zone 'Asia/Seoul';
    if position(lms_strip_bold(lms_mail_en_at(t,lms_tutor_tz_at(sub,t))) in body)=0 then raise exception 'Reply date missing: %',n; end if;
  end loop;
  if not exists(select 1 from notifications where id=mail_id and recipient_kind='tutor' and recipient_id=sub) then raise exception 'Wrong mail recipient'; end if;
  if (select count(*) from notifications where template='lesson_notice_sub_confirmed' and recipient_id=sub)<>1 then raise exception 'Duplicate confirmation'; end if;
  -- 같은 확정 요청 재실행은 새 알림을 만들지 않음.
  perform admin_leave_student_ok(array[items[1]]);
  if (select count(*) from notifications where template='lesson_notice_sub_confirmed' and recipient_id=sub)<>1 then raise exception 'Repeated confirmation sent twice'; end if;
  if position('email_bcc_ops_stop' in pg_get_functiondef('lms_mail_dispatch(uuid)'::regprocedure))=0 then raise exception 'BCC dispatch not wired'; end if;
  perform set_config('qa.result',jsonb_build_object('request_mail',true,'mixed_reply',true,'reply_dates_preserved',true,'confirmed_vs_pending',true,'no_duplicate',true,'bcc_dispatch',true,'rolled_back',true)::text,true);
end $test$;
select current_setting('qa.result') as result;
rollback;
