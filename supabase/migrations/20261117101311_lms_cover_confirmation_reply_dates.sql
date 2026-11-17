-- 2026-11-17: 확정 메일에 같은 답변 묶음의 불가 날짜와 아직 확정 전 날짜를 구분.
-- 발송 대상/숨은참조/중복 방지/최종 확정 시점은 기존대로 유지.
alter table lesson_notices add column if not exists cover_answer jsonb;
CREATE OR REPLACE FUNCTION public.tutor_sub_answer(p_items uuid[], p_yes uuid[])
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  me uuid := auth.uid();
  it leave_items;
  v_yes uuid[] := coalesce(p_yes, '{}');
  v_changed integer := 0;
  v_reply_group uuid := gen_random_uuid();
begin
  if exists (select 1 from unnest(v_yes) y where y <> all(coalesce(p_items, '{}'))) then
    raise exception 'Unknown class in your answer. Please reload the page.';
  end if;
  perform set_config('app.actor_id', me::text, true);
  perform set_config('app.actor_via', case when is_admin() then 'admin_sub_answer' else 'tutor_sub_answer' end, true);
  for it in select * from leave_items where id = any(p_items) order by starts_at for update loop
    if not (is_admin() or (my_tutor_id() is not null and it.sub_tutor_id = my_tutor_id())) then
      raise exception 'This is not your cover request.' using errcode = '42501';
    end if;
    if it.choice <> 'substitute' or it.sub_stage <> 'asked' then
      raise exception 'This cover request is already closed. Please reload the page.' using hint = 'closed';
    end if;
    -- 최신 문의 안내에 답변과 당시 날짜를 보존. 나중에 강사가 바뀌어도 답변이 섞이지 않음.
    update lesson_notices set cover_answer=jsonb_build_object(
      'group',v_reply_group,'yes',it.id=any(v_yes),'at',now(),'starts_at',it.starts_at,'ends_at',it.ends_at)
    where id=(select ln.id from lesson_notices ln where ln.leave_item_id=it.id and ln.event='sub_ask'
      and ln.recipient_id=it.sub_tutor_id order by ln.created_at desc,ln.id desc limit 1);
    -- 강사가 화면에서 답했으면 WhatsApp으로 물어볼 글은 보낼 필요 없음 (이미 보냈으면 그대로)
    update lesson_notices set status = 'not_needed' where leave_item_id = it.id and event = 'sub_ask' and status = 'pending';
    if it.id = any(v_yes) then
      if it.starts_at <= now() then raise exception 'This class has already started.'; end if;
      update leave_items set sub_stage = 'tutor_ok' where id = it.id;
      update lesson_notices set status = 'not_needed', sent_at = null, sent_by = null
      where leave_item_id = it.id and event = 'sub_student' and status = 'sent';
      insert into lesson_notices (leave_item_id, event, recipient_kind, recipient_id) values (it.id, 'sub_student', 'student', it.student_id);
    else
      update leave_items set choice = 'undecided', sub_tutor_id = null, sub_stage = null, sub_lesson_id = null, decided_at = null, decided_by = null,
                             sub_declined = case when it.sub_tutor_id = any(sub_declined) then sub_declined else sub_declined || it.sub_tutor_id end
      where id = it.id;
    end if;
    v_changed := v_changed + 1;
  end loop;
  return jsonb_build_object('changed', v_changed, 'yes', cardinality(v_yes));
end $function$;

CREATE OR REPLACE FUNCTION public.lms_sub_confirmed_mail()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  n lesson_notices;
  st students;
  tu tutors;
  v_ids uuid[];
  v_first timestamptz;
  v_min integer;
  v_list text;
  v_cnt integer;
  v_mail uuid;
  v_name text;
  v_unavailable text;
  v_pending text;
  v_paras text[];
begin
  select * into n from lesson_notices where id = new.id;
  if n.event <> 'sub_confirmed' or n.recipient_kind <> 'tutor' or n.email_notification_id is not null or n.email_status is not null then return null; end if;
  select s.* into st from leave_items li join students s on s.id = li.student_id where li.id = n.leave_item_id;
  select * into tu from tutors where id = n.recipient_id;
  select array_agg(ln.id order by l.starts_at), min(l.starts_at), min(round(extract(epoch from l.ends_at - l.starts_at) / 60)::int), count(*),
         string_agg(lms_mail_en_at(l.starts_at, lms_tutor_tz_at(tu.id, l.starts_at)), E'\n' order by l.starts_at)
    into v_ids, v_first, v_min, v_cnt, v_list
  from lesson_notices ln
  join leave_items li on li.id = ln.leave_item_id and li.student_id = st.id and li.sub_stage = 'confirmed'
  join lessons l on l.id = li.sub_lesson_id and l.tutor_id = n.recipient_id
  where ln.event = 'sub_confirmed' and ln.recipient_kind = 'tutor' and ln.recipient_id = n.recipient_id
    and ln.created_at = n.created_at and ln.email_notification_id is null and ln.email_status is null;
  if v_cnt is null or v_cnt = 0 then return null; end if;
  select string_agg(i || ') ' || line, E'\n' order by i) into v_list
  from unnest(string_to_array(v_list, E'\n')) with ordinality as a(line, i);
  -- 확정 대상과 같은 문의·답변 묶음만. 다른 학생·강사의 답변은 포함하지 않음.
  with latest as (
    select distinct on (a.leave_item_id) a.*, li.student_id, li.starts_at,li.sub_stage,li.sub_tutor_id,li.sub_declined
    from lesson_notices a join leave_items li on li.id=a.leave_item_id
    where a.event='sub_ask' and a.recipient_id=n.recipient_id and li.student_id=st.id
    order by a.leave_item_id,a.created_at desc,a.id desc
  ), selected as (
    select a.* from latest a where a.leave_item_id in (select leave_item_id from lesson_notices where id=any(v_ids))
  ), replies as (
    select a.* from latest a where exists (
      select 1 from selected c where
        (a.cover_answer->>'group' is not null and a.cover_answer->>'group'=c.cover_answer->>'group')
        or (a.cover_answer is null and c.cover_answer is null and a.created_at=c.created_at)
    )
  )
  select
    string_agg(lms_mail_en_at(coalesce((a.cover_answer->>'starts_at')::timestamptz,a.starts_at),
      lms_tutor_tz_at(tu.id,coalesce((a.cover_answer->>'starts_at')::timestamptz,a.starts_at))), E'\\n' order by a.starts_at)
      filter (where (a.cover_answer->>'yes')::boolean=false or (a.cover_answer is null and n.recipient_id=any(a.sub_declined))),
    string_agg(lms_mail_en_at(a.starts_at,lms_tutor_tz_at(tu.id,a.starts_at)), E'\\n' order by a.starts_at)
      filter (where a.sub_tutor_id=n.recipient_id and a.sub_stage='tutor_ok'
        and ((a.cover_answer->>'yes')::boolean=true or a.cover_answer is null))
  into v_unavailable,v_pending from replies a;
  v_paras:=array['CONFIRMED cover classes - ' || lms_student_en(st) || ' (' || v_min || ' min)',
    'Confirmed:' || E'\\n' || v_list];
  if v_unavailable is not null then v_paras:=v_paras || ('You marked unavailable:' || E'\\n' || v_unavailable); end if;
  if v_pending is not null then v_paras:=v_paras || ('Available - awaiting final confirmation:' || E'\\n' || v_pending); end if;
  v_paras:=array_append(v_paras, 'Only the confirmed classes above are booked in your LMS schedule. Thank you!');
  v_name := lms_student_en(st);
  v_mail := lms_tutor_mail(n.recipient_id, st.id, 'lesson_notice_sub_confirmed', 'tutor_mail:cover:' || v_ids[1],
    '[Edge English] CONFIRMED cover classes - ' || v_name || ' · from ' || lms_mail_en_date(v_first, lms_tutor_tz_at(tu.id, v_first)),
    v_paras);
  if v_mail is null then
    update lesson_notices set email_status = 'no_address', email_queued_at = now(), email_error = '강사 이메일이 없어요' where id = any(v_ids);
  else
    update lesson_notices ln set email_status = 'queued', email_queued_at = now(), email_notification_id = v_mail,
           email_to = x.email, email_intended = x.payload ->> 'intended_email'
    from notifications x where x.id = v_mail and ln.id = any(v_ids);
  end if;
  return null;
end $function$;


notify pgrst, 'reload schema';
