-- =====================================================================
-- 대체 수업 강사 메일 5가지 (대표 11/17 '해', 문구 대화에서 확정)
--  ① 요청: 단수·복수 제목·본문, 정규 근무시간 밖 수업이 있을 때만 표시 + 한 문장 (lms_cover_mail_run 첫 메일 부분만)
--  ② 답변 접수: 강사가 강사 화면에서 답했거나 운영자가 대신 기록했을 때 1통 (가능·불가 목록, 체크 안 한 날짜는 안 넣음)
--  ③-가 확정: 확정된 수업만 (lms_sub_confirmed_mail 문구 교체)
--  ③-나 요청 종료: 확정 전에 학생이 기존 강사를 골랐거나 운영자가 다시 고름 → 요청받은 강사에게 (15분마다 묶어서, 같은 강사 한 통)
--  ③-다 확정 후 취소: 확정된 대체 수업이 다시 바뀜 → 메일 + 강사 Updates 'Cover class canceled'
-- 표 1개(lms_cover_closures) + 함수·트리거 추가, 함수 4개 본문 교체. 기존 데이터는 안 바뀜. 다시 실행해도 같은 결과
-- =====================================================================

-- ---------- 요청 종료·취소 기록 (③-나·③-다) ----------
create table if not exists lms_cover_closures (
  id uuid primary key default gen_random_uuid(),
  item_id uuid not null,
  tutor_id uuid not null,
  student_id uuid not null,
  starts_at timestamptz not null,
  ends_at timestamptz not null,
  reason text not null check (reason in ('ended', 'canceled')),
  created_at timestamptz not null default now(),
  mailed_at timestamptz
);
alter table lms_cover_closures enable row level security;
revoke all on lms_cover_closures from anon, authenticated;
create index if not exists lms_cover_closures_open on lms_cover_closures (tutor_id) where mailed_at is null;

-- 요청받은(또는 확정된) 대체강사가 빠지는 순간을 기록. 강사가 직접 '불가'로 답한 경우는 기록 안 함
create or replace function leave_items_cover_closure() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if old.choice = 'substitute' and old.sub_tutor_id is not null and old.sub_stage in ('asked', 'tutor_ok', 'confirmed')
     and old.starts_at > now()
     and (new.choice is distinct from 'substitute' or new.sub_tutor_id is distinct from old.sub_tutor_id or new.sub_stage is null)
     and not (old.sub_tutor_id = any(coalesce(new.sub_declined, '{}'))) then
    if old.sub_stage = 'confirmed' or old.ask_mailed_at is not null
       or exists (select 1 from lesson_notices n where n.leave_item_id = old.id and n.event = 'sub_ask' and n.recipient_id = old.sub_tutor_id and n.status = 'sent') then
      insert into lms_cover_closures (item_id, tutor_id, student_id, starts_at, ends_at, reason)
      values (old.id, old.sub_tutor_id, old.student_id, old.starts_at, old.ends_at, case when old.sub_stage = 'confirmed' then 'canceled' else 'ended' end);
    end if;
  end if;
  return null;
end $$;
revoke all on function leave_items_cover_closure() from public, anon, authenticated;
drop trigger if exists leave_items_cover_closure on leave_items;
create trigger leave_items_cover_closure after update on leave_items for each row execute function leave_items_cover_closure();

-- 종료·취소 메일: 같은 강사·같은 종류는 한 통으로 묶어 15분마다 (기존 To do 메일 예약 실행에 붙임)
create or replace function lms_cover_close_mail_run(p_now timestamptz default now(), p_dry boolean default false)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  g record;
  tu tutors;
  v_ids uuid[];
  v_cnt int;
  v_min timestamptz;
  v_first uuid;
  v_list text;
  v_subject text;
  v_paras text[];
  v_id uuid;
  v_key text;
  v_sent int := 0;
  v_out jsonb := '[]'::jsonb;
begin
  -- 이미 지난 수업, 다시 같은 강사로 돌아온 수업은 안 보냄
  if not p_dry then
    update lms_cover_closures c set mailed_at = p_now
    where c.mailed_at is null and (c.starts_at <= p_now
      or exists (select 1 from leave_items li where li.id = c.item_id and li.sub_tutor_id = c.tutor_id and li.sub_stage in ('asked', 'tutor_ok', 'confirmed')));
  end if;
  for g in
    select c.tutor_id, c.reason from lms_cover_closures c
    where c.mailed_at is null and c.starts_at > p_now
      and not exists (select 1 from leave_items li where li.id = c.item_id and li.sub_tutor_id = c.tutor_id and li.sub_stage in ('asked', 'tutor_ok', 'confirmed'))
    group by c.tutor_id, c.reason
  loop
    select * into tu from tutors where id = g.tutor_id;
    select array_agg(q.id order by q.starts_at), count(*), min(q.created_at), (array_agg(q.student_id order by q.starts_at))[1],
           string_agg(q.line, E'\n' order by q.starts_at)
      into v_ids, v_cnt, v_min, v_first, v_list
    from (select c.id, c.starts_at, c.created_at, c.student_id,
                 '• ' || lms_mail_en_at(c.starts_at, lms_tutor_tz_at(tu.id, c.starts_at)) || ' · ' || coalesce(nullif(st.name_en, ''), st.name_ko) || ' · '
                   || round(extract(epoch from c.ends_at - c.starts_at) / 60)::int || ' min' as line
          from lms_cover_closures c join students st on st.id = c.student_id
          where c.tutor_id = g.tutor_id and c.reason = g.reason and c.mailed_at is null and c.starts_at > p_now
            and not exists (select 1 from leave_items li where li.id = c.item_id and li.sub_tutor_id = c.tutor_id and li.sub_stage in ('asked', 'tutor_ok', 'confirmed'))) q;
    if v_cnt is null or v_cnt = 0 then continue; end if;
    if g.reason = 'ended' then
      v_subject := '[Edge English] Update on your cover request';
      v_paras := array['Hi ' || tu.name || ',',
        'Thanks for considering our request! We no longer need cover for the following ' || case when v_cnt = 1 then 'class:' else 'classes:' end || E'\n' || v_list,
        'Edge English'];
    else
      v_subject := '[Edge English] ' || case when v_cnt = 1 then 'Your cover class has been canceled' else 'Your cover classes have been canceled' end;
      v_paras := array['Hi ' || tu.name || ',',
        'Sorry for the change! The following cover ' || case when v_cnt = 1 then 'class has' else 'classes have' end || ' been canceled and removed from your LMS Schedule:' || E'\n' || v_list,
        'Thank you for your understanding!' || E'\n' || 'Edge English'];
    end if;
    if p_dry then
      v_out := v_out || jsonb_build_object('kind', g.reason, 'tutor', tu.name, 'subject', v_subject, 'paras', to_jsonb(v_paras));
    else
      v_key := 'tutor_mail:cover_close:' || g.reason || ':' || g.tutor_id || ':' || md5(array_to_string(array(select z from unnest(v_ids) z order by z), ','));
      v_id := lms_tutor_mail(g.tutor_id, v_first, case when g.reason = 'ended' then 'lesson_notice_tutor_cover_closed' else 'lesson_notice_tutor_cover_canceled' end,
                             v_key, v_subject, v_paras, false);
      update lms_cover_closures set mailed_at = p_now where id = any(v_ids);
      if v_id is not null then v_sent := v_sent + 1; end if;
    end if;
  end loop;
  return jsonb_build_object('sent', v_sent, 'mails', v_out);
end $$;
revoke all on function lms_cover_close_mail_run(timestamptz, boolean) from public, anon, authenticated;

create or replace function lms_tutor_todo_mail_run(p_now timestamptz default now(), p_since timestamptz default null, p_dry boolean default false)
returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  return jsonb_build_object('cover', lms_cover_mail_run(p_now, p_since, p_dry), 'plan', lms_plan_nudge_run(p_now, p_since, p_dry), 'close', lms_cover_close_mail_run(p_now, p_dry));
end $$;
revoke all on function lms_tutor_todo_mail_run(timestamptz, timestamptz, boolean) from public, anon, authenticated;

-- ---------- ② 답변 접수 ----------
create or replace function lms_cover_reply_mail(p_yes uuid[], p_no uuid[]) returns void
language plpgsql security definer set search_path = public as $$
declare
  g record;
  tu tutors;
  v_yes text;
  v_no text;
  v_paras text[];
  v_first uuid;
  v_key text;
begin
  for g in
    select x.tutor_id, array_agg(x.id) filter (where x.yes) as yes_ids, array_agg(x.id) filter (where not x.yes) as no_ids
    from (select i.id, (i.id = any(coalesce(p_yes, '{}'))) as yes,
                 (select n.recipient_id from lesson_notices n where n.leave_item_id = i.id and n.event = 'sub_ask' order by n.created_at desc, n.id desc limit 1) as tutor_id
          from leave_items i where i.id = any(coalesce(p_yes, '{}') || coalesce(p_no, '{}'))) x
    where x.tutor_id is not null
    group by x.tutor_id
  loop
    select * into tu from tutors where id = g.tutor_id;
    select string_agg(q.line, E'\n' order by q.s) into v_yes
    from (select i.starts_at as s, '• ' || lms_mail_en_at(i.starts_at, lms_tutor_tz_at(tu.id, i.starts_at)) || ' · ' || coalesce(nullif(st.name_en, ''), st.name_ko) || ' · '
                 || round(extract(epoch from i.ends_at - i.starts_at) / 60)::int || ' min' as line
          from leave_items i join students st on st.id = i.student_id where i.id = any(coalesce(g.yes_ids, '{}'))) q;
    select string_agg(q.line, E'\n' order by q.s) into v_no
    from (select i.starts_at as s, '• ' || lms_mail_en_at(i.starts_at, lms_tutor_tz_at(tu.id, i.starts_at)) || ' · ' || coalesce(nullif(st.name_en, ''), st.name_ko) || ' · '
                 || round(extract(epoch from i.ends_at - i.starts_at) / 60)::int || ' min' as line
          from leave_items i join students st on st.id = i.student_id where i.id = any(coalesce(g.no_ids, '{}'))) q;
    select i.student_id into v_first from leave_items i where i.id = any(coalesce(g.yes_ids, '{}') || coalesce(g.no_ids, '{}')) order by i.starts_at limit 1;
    v_paras := array['Hi ' || tu.name || ',', 'Thanks for letting us know!'];
    if v_yes is not null then v_paras := array_append(v_paras, 'Available:' || E'\n' || v_yes); end if;
    if v_no is not null then v_paras := array_append(v_paras, 'Unavailable:' || E'\n' || v_no); end if;
    if v_yes is not null then
      v_paras := array_append(v_paras, case when cardinality(g.yes_ids) = 1 then 'The available class isn''t confirmed yet. We''ll email you once it''s decided.'
                                            else 'The available classes aren''t confirmed yet. We''ll email you once it''s decided.' end);
    end if;
    v_paras := array_append(v_paras, 'Edge English');
    v_key := 'tutor_mail:cover_reply:' || g.tutor_id || ':' || floor(extract(epoch from clock_timestamp()) * 1000000)::bigint;
    perform lms_tutor_mail(g.tutor_id, v_first, 'lesson_notice_tutor_cover_reply', v_key, '[Edge English] We''ve received your response', v_paras, false);
  end loop;
end $$;
revoke all on function lms_cover_reply_mail(uuid[], uuid[]) from public, anon, authenticated;

-- 강사 화면 답 / 운영자 대신 기록 → ② 발송 (본문 일부만 끼워 넣음)
do $m2$
declare
  def text;
begin
  def := pg_get_functiondef('tutor_sub_answer(uuid[],uuid[])'::regprocedure);
  if position('lms_cover_reply_mail' in def) = 0 then
    if position($a$  return jsonb_build_object('changed', v_changed, 'yes', cardinality(v_yes));$a$ in def) = 0 then raise exception 'tutor_sub_answer 모양이 달라 바꾸지 못했어요'; end if;
    def := replace(def, $a$  return jsonb_build_object('changed', v_changed, 'yes', cardinality(v_yes));$a$,
      $b$  if v_changed > 0 then
    perform lms_cover_reply_mail(v_yes, (select array_agg(z) from unnest(coalesce(p_items, '{}')) z where z <> all(v_yes)));
  end if;
  return jsonb_build_object('changed', v_changed, 'yes', cardinality(v_yes));$b$);
    execute def;
  end if;

  def := pg_get_functiondef('admin_leave_sub_ok(uuid[])'::regprocedure);
  if position('lms_cover_reply_mail' in def) = 0 then
    if position('  v_changed integer := 0;' in def) = 0 or position('    v_changed := v_changed + 1;' in def) = 0 or position($a$  return jsonb_build_object('changed', v_changed);$a$ in def) = 0 then
      raise exception 'admin_leave_sub_ok 모양이 달라 바꾸지 못했어요';
    end if;
    def := replace(def, '  v_changed integer := 0;', E'  v_changed integer := 0;\n  v_ok uuid[] := ''{}'';');
    def := replace(def, '    v_changed := v_changed + 1;', E'    v_changed := v_changed + 1;\n    v_ok := v_ok || it.id;');
    def := replace(def, $a$  return jsonb_build_object('changed', v_changed);$a$,
      $b$  if v_changed > 0 then perform lms_cover_reply_mail(v_ok, '{}'); end if;
  return jsonb_build_object('changed', v_changed);$b$);
    execute def;
  end if;
end $m2$;

-- ---------- ③-가 확정 (확정된 수업만) ----------
create or replace function lms_sub_confirmed_mail() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  n lesson_notices;
  st students;
  tu tutors;
  v_ids uuid[];
  v_cnt integer;
  v_list text;
  v_mail uuid;
  v_name text;
  v_paras text[];
begin
  select * into n from lesson_notices where id = new.id;
  if n.event <> 'sub_confirmed' or n.recipient_kind <> 'tutor' or n.email_notification_id is not null or n.email_status is not null then return null; end if;
  select s.* into st from leave_items li join students s on s.id = li.student_id where li.id = n.leave_item_id;
  select * into tu from tutors where id = n.recipient_id;
  v_name := lms_student_en(st);
  select array_agg(ln.id order by l.starts_at), count(*),
         string_agg('• ' || lms_mail_en_at(l.starts_at, lms_tutor_tz_at(tu.id, l.starts_at)) || ' · ' || v_name || ' · ' || round(extract(epoch from l.ends_at - l.starts_at) / 60)::int || ' min', E'\n' order by l.starts_at)
    into v_ids, v_cnt, v_list
  from lesson_notices ln
  join leave_items li on li.id = ln.leave_item_id and li.student_id = st.id and li.sub_stage = 'confirmed'
  join lessons l on l.id = li.sub_lesson_id and l.tutor_id = n.recipient_id
  where ln.event = 'sub_confirmed' and ln.recipient_kind = 'tutor' and ln.recipient_id = n.recipient_id
    and ln.created_at = n.created_at and ln.email_notification_id is null and ln.email_status is null;
  if v_cnt is null or v_cnt = 0 then return null; end if;
  v_paras := array['Hi ' || tu.name || ',',
    'Thank you for helping out! ' || case when v_cnt = 1 then 'This class is confirmed:' else 'These classes are confirmed:' end || E'\n' || v_list,
    'You can find ' || case when v_cnt = 1 then 'it' else 'them' end || ' in your LMS Schedule. Please use your usual Google Meet link.',
    'Thanks again!' || E'\n' || 'Edge English'];
  v_mail := lms_tutor_mail(n.recipient_id, st.id, 'lesson_notice_sub_confirmed', 'tutor_mail:cover:' || v_ids[1],
    '[Edge English] ' || case when v_cnt = 1 then 'Your cover class is confirmed' else 'Your cover classes are confirmed' end, v_paras, false);
  if v_mail is null then
    update lesson_notices set email_status = 'no_address', email_queued_at = now(), email_error = '강사 이메일이 없어요' where id = any(v_ids);
  else
    update lesson_notices ln set email_status = 'queued', email_queued_at = now(), email_notification_id = v_mail,
           email_to = x.email, email_intended = x.payload ->> 'intended_email'
    from notifications x where x.id = v_mail and ln.id = any(v_ids);
  end if;
  return null;
end $$;
revoke all on function lms_sub_confirmed_mail() from public, anon, authenticated;

-- ---------- ① 요청 (첫 메일 부분만 교체, 재촉은 그대로) ----------
do $m1$
declare
  def text := pg_get_functiondef('lms_cover_mail_run(timestamptz,timestamptz,boolean)'::regprocedure);
  s1 text := $s$v_subject := '[Edge English] Substitute request - please reply in the LMS';$s$;
  p1 int := position(s1 in def);
  p2 int;
  nb text;
begin
  if position('Could you help with' in def) > 0 then return; end if;
  if p1 = 0 then raise exception '대체 수업 요청 메일 함수 모양이 달라 바꾸지 못했어요'; end if;
  p2 := position('    if p_dry then' in substr(def, p1)) + p1 - 1;
  nb := $nb$v_subject := '[Edge English] ' || case when cardinality(v_ids) = 1 then 'Could you help with this cover class?' else 'Could you help with these cover classes?' end;
    v_marked := (length(v_list) - length(replace(v_list, '(outside your regular working hours)', ''))) / length('(outside your regular working hours)');
    v_paras := array['Hi ' || tu.name || ',',
      'One of our tutors is on leave. ' || case when cardinality(v_ids) = 1 then 'Would you be able to help us cover the class below? It''s not confirmed yet.'
        else 'Would you be able to help us cover any of the classes below? These are not confirmed yet.' end || E'\n' || v_list];
    if v_marked = 1 then
      v_paras := array_append(v_paras, 'We know the marked class is outside your regular working hours, but we''d be grateful if you''re free. No worries if not!');
    elsif v_marked > 1 then
      v_paras := array_append(v_paras, 'We know the marked classes are outside your regular working hours, but we''d be grateful if you could cover any of them. No worries if not!');
    end if;
    v_paras := array_append(v_paras, case when cardinality(v_ids) = 1
      then 'On your LMS Home, open "Cover requests" under "To do", select the class if you can teach it, and tap "Send answer". If not, tap "None of these work".'
      else 'On your LMS Home, open "Cover requests" under "To do", select the classes you can teach, and tap "Send answer". If none work, tap "None of these work".' end);
    v_paras := array_append(v_paras, 'Thank you so much!' || E'\n' || 'Edge English');
$nb$;
  def := substr(def, 1, p1 - 1) || nb || substr(def, p2);
  def := replace(def, '  v_paras text[];', E'  v_paras text[];\n  v_marked int;');
  def := replace(def, $r1$'lesson_notice_tutor_cover_ask', v_key, v_subject, v_paras, true)$r1$, $r2$'lesson_notice_tutor_cover_ask', v_key, v_subject, v_paras, false)$r2$);
  execute def;
end $m1$;

-- ---------- ③-다 강사 Updates: 확정된 대체 수업이 취소됨 ----------
do $m3$
declare
  def text := pg_get_functiondef('tutor_updates_feed(uuid)'::regprocedure);
  a text := E'\n  ) q), ''[]''::jsonb);';
begin
  if position('cover_canceled' in def) > 0 then return; end if;
  if position(a in def) = 0 then raise exception 'tutor_updates_feed 모양이 달라 바꾸지 못했어요'; end if;
  def := replace(def, a, $b$
    union all
    -- 확정된 대체 수업이 취소됨(운영자가 다시 고름): 그 수업이 끝날 때까지
    select jsonb_build_object('id', c.id, 'kind', 'cover_canceled', 'student', lms_tutor_student_label(s.name_en, s.display_name), 'student_id', s.id,
             'at', c.starts_at, 'info', jsonb_build_object('times', jsonb_build_array(c.starts_at)))
    from lms_cover_closures c join students s on s.id = c.student_id
    where c.tutor_id = me and c.reason = 'canceled' and c.ends_at > now()
      and not exists (select 1 from leave_items li where li.id = c.item_id and li.sub_tutor_id = me and li.sub_stage = 'confirmed')
  ) q), '[]'::jsonb);$b$);
  execute def;
end $m3$;
