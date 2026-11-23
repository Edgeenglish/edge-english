-- Temporary location 매주 시간표 적용 시점 (대표 11/15 '반영해', 정책 POL-TU-11 '매주 변경은 다음 주 월요일부터'와 통일)
--  · 처음 시간 넣기: Temporary location period 시작 전이면 시작일부터, 시작 뒤면 저장 즉시(오늘부터)
--  · 이미 넣은 시간표 고치기: 다음 월요일과 시작일 중 늦은 날부터. 그날이 종료일보다 늦으면 고칠 수 없음 (이번 주만 = Calendar & One-Time Changes)
--  · 날짜·다음 월요일 = 그 Temporary location 현지 날짜 기준
--  · 시간표를 여러 벌 보관 (tutor_availability.effective_from·effective_to, 평소 지역과 같은 방식): 적용일 전에는 고치기 전 시간표 그대로
--  · 확정 수업·대기 중인 보강·대체·신규 배정 요청은 건드리지 않음 (시간표와 따로 저장, 확정할 때 충돌 검사 그대로)

-- 그 Temporary location 시간표를 지금 고치면 언제부터 적용되는지 (null = 적용할 날이 없음 → 고칠 수 없음)
create or replace function lms_location_apply_from(l tutor_locations) returns date
language plpgsql stable security definer set search_path = public as $$
declare
  v_today date := (now() at time zone l.timezone)::date;
  v_from date;
begin
  if not exists (select 1 from tutor_availability a where a.location_id = l.id) then
    v_from := greatest(l.starts_on, v_today);                                   -- 처음: 시작일 또는 오늘
  else
    v_from := greatest(v_today + (8 - extract(isodow from v_today)::int), l.starts_on);   -- 고치기: 다음 월요일과 시작일 중 늦은 날
  end if;
  if l.ends_on is not null and v_from > l.ends_on then return null; end if;
  return v_from;
end $$;
revoke all on function lms_tutor_location_json(tutor_locations) from public, anon, authenticated;
revoke all on function lms_location_apply_from(tutor_locations) from public, anon, authenticated;

-- 매주 시간: Temporary location 이면 그 기간 시간표 중 그 날짜(그 지역 현지)에 적용되는 벌만
create or replace function public.lms_tutor_weekly_ok(p_tutor uuid, p_start timestamptz)
 returns boolean language sql stable security definer set search_path to 'public' as $function$
  select lms_tutor_start_ok(p_tutor, p_start)
     and case when x.loc is null then
           exists (select 1 from tutor_availability a
                   where a.tutor_id = p_tutor and a.location_id is null
                     and a.effective_from <= (p_start at time zone 'Asia/Seoul')::date
                     and (a.effective_to is null or a.effective_to >= (p_start at time zone 'Asia/Seoul')::date)
                     and extract(dow from (p_start at time zone a.timezone)) = a.weekday
                     and (p_start at time zone a.timezone)::time between a.start_local and a.end_local)
         else
           exists (select 1 from tutor_availability a
                   where a.tutor_id = p_tutor and a.location_id = x.loc
                     and a.effective_from <= (p_start at time zone a.timezone)::date
                     and (a.effective_to is null or a.effective_to >= (p_start at time zone a.timezone)::date)
                     and extract(dow from (p_start at time zone a.timezone)) = a.weekday
                     and (p_start at time zone a.timezone)::time between a.start_local and a.end_local)
         end
  from (select lms_tutor_location_at(p_tutor, p_start) loc) x
$function$;

-- 화면용 한 줄: weekly_open = 앞으로 적용될(가장 새) 시간표, apply_from = 지금 고치면 적용되는 날(null = 고칠 수 없음), first = 처음 넣는지
create or replace function lms_tutor_location_json(l tutor_locations) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object('id', l.id, 'city', l.city, 'country', l.country, 'timezone', l.timezone,
    'from', l.starts_on, 'to', l.ends_on,
    'monday', m.mon,
    'weekly_open', to_jsonb(array(
      select distinct a.weekday || ':' || to_char(tm, 'HH24:MI')
      from tutor_availability a cross join unnest(array(select lms_hours_times(l.timezone, m.mon))) tm
      where a.location_id = l.id and a.effective_to is null and tm between a.start_local and a.end_local order by 1)),
    'weekly_classes', coalesce((select jsonb_agg(jsonb_build_object('d', w.d, 'time', to_char(w.start_local, 'HH24:MI'), 'min', w.minutes, 'student', w.student))
                                from lms_weekly_classes(l.tutor_id, l.timezone, m.mon) w), '[]'::jsonb),
    'apply_from', lms_location_apply_from(l),
    'first', not exists (select 1 from tutor_availability a where a.location_id = l.id),
    'today', (now() at time zone l.timezone)::date)
  from (select d - (extract(isodow from d)::int - 1) mon
        from (select greatest(l.starts_on, (now() at time zone l.timezone)::date) d) z) m
$$;
revoke all on function lms_tutor_location_json(tutor_locations) from public, anon, authenticated;

-- 매주 시간 저장: 적용일(lms_location_apply_from)부터 새 벌, 그 전은 고치기 전 벌 그대로
create or replace function tutor_location_hours_save(p_tutor uuid, p_location uuid, p_weekly text[])
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_tutor uuid := lms_screen_tutor(p_tutor);
  l tutor_locations;
  v_times time[];
  v_old text[];
  v_new text[];
  v_add text[];
  v_del text[];
  v_from date;
  k text;
  v_changes jsonb;
begin
  perform set_config('app.actor_id', coalesce(auth.uid()::text, ''), true);
  perform set_config('app.actor_via', case when is_admin() then 'admin_tutor_hours' else 'tutor_hours' end, true);
  select * into l from tutor_locations where id = p_location and tutor_id = v_tutor for update;
  if not found then raise exception 'This temporary location is gone. Please refresh.'; end if;
  if l.ends_on is not null and l.ends_on < (now() at time zone l.timezone)::date then raise exception 'This temporary location has ended.'; end if;
  v_times := array(select lms_hours_times(l.timezone, l.starts_on));
  foreach k in array coalesce(p_weekly, '{}') loop
    if k !~ '^[0-6]:\d\d:\d\d$' or not (substr(k, 3)::time = any (v_times)) then raise exception 'Invalid time: %', k; end if;
  end loop;
  v_old := array(select jsonb_array_elements_text(lms_tutor_location_json(l) -> 'weekly_open'));
  v_new := array(select distinct x from unnest(coalesce(p_weekly, '{}')) x);
  v_add := array(select x from unnest(v_new) x where not (x = any (v_old)) order by 1);
  v_del := array(select x from unnest(v_old) x where not (x = any (v_new)) order by 1);
  if cardinality(v_add) + cardinality(v_del) > 0 then
    v_from := lms_location_apply_from(l);
    if v_from is null then
      raise exception 'This period ends before weekly changes can apply. For one-time changes, use Calendar & One-Time Changes.';
    end if;
    delete from tutor_availability where location_id = l.id and effective_from >= v_from;
    update tutor_availability set effective_to = v_from - 1
    where location_id = l.id and effective_from < v_from and (effective_to is null or effective_to >= v_from);
    insert into tutor_availability (tutor_id, weekday, start_local, end_local, timezone, effective_from, location_id)
    select v_tutor, d, min(tm), max(tm), l.timezone, v_from, l.id
    from (select d, tm, (extract(epoch from tm)::int / 1800) - row_number() over (partition by d order by tm) grp
          from (select split_part(x, ':', 1)::int d, substr(x, 3)::time tm from unnest(v_new) x) a) b
    group by d, grp;
    v_changes := jsonb_build_object('from', v_from, 'weekly_open', to_jsonb(v_add), 'weekly_close', to_jsonb(v_del), 'once_close', '[]'::jsonb, 'once_open', '[]'::jsonb,
      'location', jsonb_build_object('action', 'hours', 'city', l.city, 'country', l.country, 'timezone', l.timezone, 'from', l.starts_on, 'to', l.ends_on));
    insert into tutor_hours_changes (tutor_id, actor, by_admin, changes) values (v_tutor, auth.uid(), is_admin(), v_changes);
  end if;
  return lms_tutor_location_json(l);
end $$;
revoke all on function tutor_location_hours_save(uuid, uuid, text[]) from public, anon;
grant execute on function tutor_location_hours_save(uuid, uuid, text[]) to authenticated;
