-- 2026-11-17 대표 승인: 대체강사 귀책 보강은 원래/대체강사 선택.
-- 추가 무료 보상수업은 귀책 강사 고정. 기존 신청/확정/정산 데이터는 변경하지 않음.
-- 기존 RPC 유지; 신규 학생 RPC도 운영자 대신 입력과 동일한 검사를 사용.
create or replace function lms_makeup_tutors(p_lesson uuid, p_item uuid, p_comp uuid)
returns jsonb language sql stable security definer set search_path = public as $$
  with source as (
    select l.tutor_id, case when l.class_status in ('Tutor canceled in advance', 'Tutor canceled late', 'Tutor no-show')
      then l.original_tutor_id end as original_id
    from lessons l where p_comp is null and p_item is null and l.id = p_lesson
    union all
    select coalesce(l.original_tutor_id, l.tutor_id), null::uuid
    from migrated_items m cross join lateral (
      select x.tutor_id, x.original_tutor_id from lessons x
      where x.enrollment_id=m.enrollment_id and x.voided_at is null order by x.starts_at desc limit 1
    ) l where p_comp is null and p_lesson is null and m.id=p_item
    union all
    select l.tutor_id, null::uuid from compensations c join lessons l on l.id=c.source_lesson_id where c.id=p_comp
  ), choices as (
    select tutor_id as id, case when original_id is not null and original_id<>tutor_id then 'substitute' else 'assigned' end as role, 1 as ord from source
    union all
    select original_id, 'original', 0 from source where original_id is not null and original_id<>tutor_id
  )
  select coalesce(jsonb_agg(jsonb_build_object('id', t.id, 'name', t.name, 'role', c.role) order by c.ord), '[]'::jsonb)
  from choices c join tutors t on t.id=c.id;
$$;
revoke all on function lms_makeup_tutors(uuid,uuid,uuid) from public,anon,authenticated;

create or replace function lms_makeup_pick_tutor(p_lesson uuid, p_item uuid, p_comp uuid, p_tutor uuid)
returns uuid language plpgsql stable security definer set search_path = public as $$
declare s record; v_tutor uuid;
begin
  if p_comp is not null then select * into s from lms_comp_source(p_comp);
  else select * into s from lms_makeup_source(p_lesson,p_item); end if;
  v_tutor := coalesce(p_tutor,s.tutor_id);
  if v_tutor is null or not exists (select 1 from jsonb_array_elements(lms_makeup_tutors(p_lesson,p_item,p_comp)) x where (x->>'id')::uuid=v_tutor) then
    raise exception '이 수업의 보강을 신청할 수 있는 강사가 아닙니다.' using errcode='22023';
  end if;
  return v_tutor;
end $$;
revoke all on function lms_makeup_pick_tutor(uuid,uuid,uuid,uuid) from public,anon,authenticated;
CREATE OR REPLACE FUNCTION public.lms_makeup_options_for_tutor(p_lesson uuid, p_item uuid, p_comp uuid, p_tutor uuid)
 RETURNS TABLE(section text, starts_at timestamp with time zone, ends_at timestamp with time zone)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  s record;
  e enrollments;
  v_leave boolean;
  v_back date;
  v_until date;
  v_today date := (now() at time zone 'Asia/Seoul')::date;
begin
  if p_comp is not null then
    select * into s from lms_comp_source(p_comp);
    select * into e from enrollments where id = s.enrollment_id;
    v_leave := false;
    v_back := v_today;
    v_until := s.use_until;
  else
    select * into s from lms_makeup_source(p_lesson, p_item);
    select * into e from enrollments where id = s.enrollment_id;
    v_leave := s.tutor_leave;
    select (o.ends_at at time zone 'Asia/Seoul')::date into v_back
    from leave_items li join tutor_time_off o on o.id = li.time_off_id
    where (li.lesson_id = p_lesson or li.migrated_item_id = p_item) limit 1;
    v_back := coalesce(v_back, v_today);
    v_until := e.final_end_date;
  end if;

  s.tutor_id := lms_makeup_pick_tutor(p_lesson, p_item, p_comp, p_tutor);

  return query
  with rs as (
    select r.weekday, r.start_time_kst from regular_schedules r
    where r.student_id = s.student_id and r.tutor_id = s.tutor_id and (r.effective_to is null or r.effective_to >= v_today)
  ),
  slots as (
    select 'in_period'::text as sec, ((d::date::timestamp + make_interval(mins => n * 30)) at time zone 'Asia/Seoul') as x
    from generate_series(greatest(v_today, v_back), v_until, interval '1 day') d
    cross join generate_series(0, 47) n
    union all
    select 'after_end', ((d::date + rs.start_time_kst) at time zone 'Asia/Seoul')
    from generate_series(greatest(e.final_end_date + 1, v_back, v_today), greatest(e.final_end_date + 1, v_back, v_today) + 180, interval '1 day') d
    join rs on rs.weekday = extract(dow from d)
    where v_leave
  ),
  free as (
    select y.sec, y.x, y.x + make_interval(mins => e.duration_min) as f from slots y
    where y.x > now()
      and not exists (select 1 from lessons original where original.id = p_lesson and original.starts_at = y.x)
      and lms_tutor_available(s.tutor_id, y.x)
      and lms_makeup_conflict(s.tutor_id, s.student_id, y.x, y.x + make_interval(mins => e.duration_min), true) is null
      and not exists (select 1 from lessons l where l.student_id = s.student_id and l.state <> 'canceled'
                      and l.starts_at < y.x + make_interval(mins => e.duration_min) and y.x < l.ends_at)
  )
  select z.sec, z.x, z.f from (select f1.*, row_number() over (partition by f1.sec order by f1.x) as n from free f1) z
  where z.sec = 'in_period' or z.n <= 1
  order by z.x;
end $function$;


revoke all on function lms_makeup_options_for_tutor(uuid,uuid,uuid,uuid) from public,anon,authenticated;
CREATE OR REPLACE FUNCTION public.lms_makeup_request_for_tutor(p_lesson uuid, p_item uuid, p_slots jsonb, p_requested_at timestamp with time zone, p_via text, p_actor uuid, p_comp uuid, p_tutor uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  s record;
  c record;
  e enrollments;
  v_id uuid;
  x jsonb;
  t timestamptz;
  v_tutor uuid;
begin
  -- 같은 보강권 동시 신청을 직렬화 (기존 RPC도 아래 래퍼 경유).
  perform pg_advisory_xact_lock(hashtextextended('makeup:' || coalesce(p_comp,p_lesson,p_item)::text,0));
  v_tutor := lms_makeup_pick_tutor(p_lesson,p_item,p_comp,p_tutor);
  if jsonb_typeof(p_slots) <> 'array' or jsonb_array_length(p_slots) = 0 then raise exception '보강 시간을 하나 이상 넣어 주세요.'; end if;
  if p_lesson is not null and exists (
    select 1 from jsonb_array_elements(p_slots) slot
    join lessons original on original.id = p_lesson
      and original.starts_at = (slot ->> 'starts_at')::timestamptz
  ) then raise exception '취소한 수업의 원래 시간은 보강으로 신청할 수 없습니다.' using hint = 'original_slot'; end if;
  perform set_config('app.actor_id', coalesce(p_actor::text, ''), true);
  perform set_config('app.actor_via', 'lms_makeup_request_core', true);
  if p_comp is not null then
    perform 1 from compensations where id = p_comp for update;
    select * into c from lms_comp_source(p_comp);
    select * into e from enrollments where id = c.enrollment_id;
    select id into v_id from makeup_requests where status in ('requested', 'countered') and compensation_id = p_comp;
    if found then
    if (select tutor_id from makeup_requests where id=v_id) <> v_tutor then
      raise exception '이미 다른 강사에게 신청한 보강입니다. 기존 신청을 취소한 뒤 다시 신청해 주세요.' using hint='makeup_already_requested';
    end if;
    return jsonb_build_object('makeup_request_id', v_id, 'repeated', true);
  end if;
    insert into makeup_requests (source_lesson_id, compensation_id, student_id, tutor_id, via, requested_at, requested_by)
    values (c.source_lesson_id, p_comp, c.student_id, c.tutor_id, p_via, coalesce(p_requested_at, now()), p_actor)
    returning id into v_id;
    for x in select * from jsonb_array_elements(p_slots) loop
      t := (x ->> 'starts_at')::timestamptz;
      if t <= now() then raise exception '지난 시간은 보강으로 넣을 수 없습니다.'; end if;
      if t >= ((c.use_until + 1)::timestamp at time zone 'Asia/Seoul') then
        raise exception '보상수업 사용 기한(%) 뒤의 시간입니다.', c.use_until using hint = 'after_end';
      end if;
      insert into makeup_candidates (request_id, starts_at, ends_at, proposed_by)
      values (v_id, t, t + make_interval(mins => e.duration_min), 'student');
    end loop;
    insert into lesson_notices (makeup_request_id, event, recipient_kind, recipient_id, status)
      select v_id, 'makeup_requested', kind, id, 'not_needed'
      from (select 'student'::text as kind, student_id as id from makeup_requests where id = v_id
            union all select 'tutor', tutor_id from makeup_requests where id = v_id) recipients;
    return jsonb_build_object('makeup_request_id', v_id, 'repeated', false);
  end if;
  select * into s from lms_makeup_source(p_lesson, p_item);
  s.tutor_id := v_tutor;
  select * into e from enrollments where id = s.enrollment_id;
  select id into v_id from makeup_requests
  where status in ('requested', 'countered') and compensation_id is null and (source_lesson_id = p_lesson or migrated_item_id = p_item);
  if found then
    if (select tutor_id from makeup_requests where id=v_id) <> v_tutor then
      raise exception '이미 다른 강사에게 신청한 보강입니다. 기존 신청을 취소한 뒤 다시 신청해 주세요.' using hint='makeup_already_requested';
    end if;
    return jsonb_build_object('makeup_request_id', v_id, 'repeated', true);
  end if;
  insert into makeup_requests (source_lesson_id, migrated_item_id, student_id, tutor_id, via, requested_at, requested_by)
  values (p_lesson, p_item, s.student_id, s.tutor_id, p_via, coalesce(p_requested_at, now()), p_actor)
  returning id into v_id;
  for x in select * from jsonb_array_elements(p_slots) loop
    t := (x ->> 'starts_at')::timestamptz;
    if t <= now() then raise exception '지난 시간은 보강으로 넣을 수 없습니다.'; end if;
    if not s.tutor_leave and t >= ((e.final_end_date + 1)::timestamp at time zone 'Asia/Seoul') then
      raise exception '수강 종료일(%) 뒤의 시간입니다.', e.final_end_date using hint = 'after_end';
    end if;
    insert into makeup_candidates (request_id, starts_at, ends_at, proposed_by)
    values (v_id, t, t + make_interval(mins => e.duration_min), 'student');
  end loop;
  insert into lesson_notices (makeup_request_id, event, recipient_kind, recipient_id, status)
      select v_id, 'makeup_requested', kind, id, 'not_needed'
      from (select 'student'::text as kind, student_id as id from makeup_requests where id = v_id
            union all select 'tutor', tutor_id from makeup_requests where id = v_id) recipients;
    return jsonb_build_object('makeup_request_id', v_id, 'repeated', false);
end $function$;


revoke all on function lms_makeup_request_for_tutor(uuid,uuid,jsonb,timestamptz,text,uuid,uuid,uuid) from public,anon,authenticated;

create or replace function lms_makeup_request_core(p_lesson uuid,p_item uuid,p_slots jsonb,p_requested_at timestamptz,p_via text,p_actor uuid,p_comp uuid default null)
returns jsonb language sql security definer set search_path=public as $$
  select lms_makeup_request_for_tutor(p_lesson,p_item,p_slots,p_requested_at,p_via,p_actor,p_comp,null);
$$;
revoke all on function lms_makeup_request_core(uuid,uuid,jsonb,timestamptz,text,uuid,uuid) from public,anon,authenticated;

create or replace function student_makeup_options_for_tutor(p_student uuid,p_lesson uuid,p_item uuid,p_comp uuid,p_tutor uuid)
returns table(section text,starts_at timestamptz,ends_at timestamptz)
language plpgsql stable security definer set search_path=public as $$
declare v_student uuid := lms_screen_student(p_student); s record;
begin
  if p_comp is not null then select * into s from lms_comp_source(p_comp);
  else select * into s from lms_makeup_source(p_lesson,p_item); end if;
  if s.student_id is distinct from v_student then raise exception '본인 수업만 볼 수 있습니다.' using errcode='42501'; end if;
  return query select * from lms_makeup_options_for_tutor(p_lesson,p_item,p_comp,p_tutor);
end $$;
revoke all on function student_makeup_options_for_tutor(uuid,uuid,uuid,uuid,uuid) from public,anon;
grant execute on function student_makeup_options_for_tutor(uuid,uuid,uuid,uuid,uuid) to authenticated;

create or replace function student_makeup_request_for_tutor(p_student uuid,p_lesson uuid,p_item uuid,p_comp uuid,p_tutor uuid,p_slots jsonb)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_student uuid := lms_screen_student(p_student); s record; x jsonb;
begin
  if p_comp is not null then select * into s from lms_comp_source(p_comp);
  else select * into s from lms_makeup_source(p_lesson,p_item); end if;
  if s.student_id is distinct from v_student then raise exception '본인 수업만 보강 신청할 수 있습니다.' using errcode='42501'; end if;
  if p_slots is null or jsonb_typeof(p_slots)<>'array' or jsonb_array_length(p_slots) not between 1 and 2 then
    raise exception '보강 날짜를 1~2개 골라 주세요.';
  end if;
  perform pg_advisory_xact_lock(hashtextextended('makeup:' || coalesce(p_comp,p_lesson,p_item)::text,0));
  perform lms_makeup_pick_tutor(p_lesson,p_item,p_comp,p_tutor);
  for x in select * from jsonb_array_elements(p_slots) loop
    if not exists (select 1 from lms_makeup_options_for_tutor(p_lesson,p_item,p_comp,p_tutor) o where o.starts_at=(x->>'starts_at')::timestamptz) then
      raise exception '보강 가능한 날짜가 아닙니다. 화면을 새로 열어 다시 골라 주세요.' using hint='not_an_option';
    end if;
  end loop;
  return lms_makeup_request_for_tutor(p_lesson,p_item,p_slots,now(),case when is_admin() then 'admin_on_behalf' else 'student_app' end,auth.uid(),p_comp,p_tutor);
end $$;
revoke all on function student_makeup_request_for_tutor(uuid,uuid,uuid,uuid,uuid,jsonb) from public,anon;
grant execute on function student_makeup_request_for_tutor(uuid,uuid,uuid,uuid,uuid,jsonb) to authenticated;

-- Preserve concurrent student_screen changes; enrich only the existing rights array.
do $patch$
declare d text; old text := $old$select jsonb_agg(r order by r ->> 'original_at', r ->> 'comp_id' nulls first) from ($old$;
 new text := $new$select jsonb_agg(r || jsonb_build_object('tutor_choices', lms_makeup_tutors((r->>'lesson_id')::uuid,(r->>'item_id')::uuid,(r->>'comp_id')::uuid)) order by r ->> 'original_at', r ->> 'comp_id' nulls first) from ($new$;
begin
  select pg_get_functiondef('student_screen(uuid)'::regprocedure) into d;
  if position(new in d)>0 then return; end if;
  if position(old in d)=0 then raise exception 'student_screen makeup rights changed; review before applying'; end if;
  execute replace(d,old,new);
end $patch$;
notify pgrst, 'reload schema';
