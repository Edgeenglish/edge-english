-- 강사 해외 이동 기간 (임시 체류 지역) — 정책 원본 H26(173), 시안 8차 (docs/lms/previews/tutor-travel-location.html), 대표 11/14
--  · Regular Working Hours [Add Temporary Location]: 도시(→ 시간대 자동)·시작일·종료일(선택)
--  · 이동 기간마다 매주 시간표 따로 (tutor_availability.location_id). 이동 중에는 Regular 시간표가 적용되지 않고 그 기간 시간만
--  · 종료일이 있으면 다음 날부터 Regular 자동 복귀, 없으면 복귀 안 함 ([Set end date] 로 나중에)
--  · 수업 시작은 그 지역 현지 06:00~22:30 (POL-OP-02 그대로, 1-나 철회)
--  · Calendar & One-Time Changes [Set Multiple Days]: 날짜 범위 + 현지 시간 → 되는 날만 열기, 막힌 날은 이유
--  · 이미 잡힌 수업·학생 일정은 바뀌지 않음. 운영진 대신 입력 = 같은 함수, 이력 by_admin
--  · 날짜는 그 지역 현지 날짜. 어떤 시각이 이동 기간인지는 '그 시각의 이동 지역 현지 날짜'가 기간 안인지로 정함

create table if not exists tutor_locations (
  id uuid primary key default gen_random_uuid(),
  tutor_id uuid not null references tutors(id),
  city text not null check (btrim(city) <> ''),
  country text not null default '',
  timezone text not null check (is_valid_timezone(timezone)),
  starts_on date not null,                 -- 그 지역 현지 날짜 (첫날)
  ends_on date,                            -- 마지막 날 (포함). null = 종료일 없음 (Regular 자동 복귀 안 함)
  created_by uuid,
  created_at timestamptz not null default now(),
  check (ends_on is null or ends_on >= starts_on)
);
create index if not exists tutor_locations_tutor on tutor_locations (tutor_id, starts_on);
alter table tutor_locations enable row level security;
revoke all on table tutor_locations from anon, authenticated;

-- 매주 시간 줄: location_id 비어 있음 = Regular, 있음 = 그 이동 기간 시간표
alter table tutor_availability add column if not exists location_id uuid references tutor_locations(id);
create index if not exists tutor_availability_location on tutor_availability (location_id) where location_id is not null;

-- 그 날짜(현지)의 이동 기간 시간대 → 없으면 강사 시간대
create or replace function lms_tutor_tz_on(p_tutor uuid, p_day date) returns text
language sql stable security definer set search_path = public as $$
  select coalesce((select l.timezone from tutor_locations l
                   where l.tutor_id = p_tutor and l.starts_on <= p_day and (l.ends_on is null or l.ends_on >= p_day)
                   order by l.starts_on desc limit 1),
                  (select timezone from tutors where id = p_tutor))
$$;

-- 그 시각이 속한 이동 기간 (없으면 null = Regular)
create or replace function lms_tutor_location_at(p_tutor uuid, p_at timestamptz) returns uuid
language sql stable security definer set search_path = public as $$
  select l.id from tutor_locations l
  where l.tutor_id = p_tutor and l.starts_on <= (p_at at time zone l.timezone)::date
    and (l.ends_on is null or l.ends_on >= (p_at at time zone l.timezone)::date)
  order by l.starts_on desc limit 1
$$;

create or replace function lms_tutor_tz_at(p_tutor uuid, p_at timestamptz) returns text
language sql stable security definer set search_path = public as $$
  select coalesce((select timezone from tutor_locations where id = lms_tutor_location_at(p_tutor, p_at)),
                  (select timezone from tutors where id = p_tutor))
$$;

revoke all on function lms_tutor_tz_on(uuid, date) from public, anon, authenticated;
revoke all on function lms_tutor_location_at(uuid, timestamptz) from public, anon, authenticated;
revoke all on function lms_tutor_tz_at(uuid, timestamptz) from public, anon, authenticated;

-- 수업 시작 가능 시각: 그 시각에 있는 지역 현지 06:00~22:30
create or replace function public.lms_tutor_start_ok(p_tutor uuid, p_start timestamptz)
 returns boolean language sql stable security definer set search_path to 'public' as $function$
  select coalesce((p_start at time zone lms_tutor_tz_at(p_tutor, p_start))::time between time '06:00' and time '22:30', false)
$function$;

-- 매주 시간: 이동 기간이면 그 기간 시간표만, 아니면 Regular 줄만
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
                     and extract(dow from (p_start at time zone a.timezone)) = a.weekday
                     and (p_start at time zone a.timezone)::time between a.start_local and a.end_local)
         end
  from (select lms_tutor_location_at(p_tutor, p_start) loc) x
$function$;

-- Regular 격자의 열린 칸: Regular 줄만
create or replace function public.lms_weekly_open(p_tutor uuid, p_tz text, p_from date, p_times time without time zone[])
 returns setof text language sql stable security definer set search_path to 'public' as $function$
  select extract(dow from ld)::int || ':' || to_char(tm, 'HH24:MI')
  from generate_series(p_from, p_from + 6, interval '1 day') g(ld0)
  cross join lateral (select g.ld0::date as ld) d
  cross join unnest(p_times) tm
  where not exists (select 1 from tutor_availability a where a.tutor_id = p_tutor and a.location_id is null)
     or exists (select 1 from tutor_availability a
                where a.tutor_id = p_tutor and a.location_id is null
                  and a.effective_from <= p_from and (a.effective_to is null or a.effective_to >= p_from)
                  and extract(dow from (((ld + tm) at time zone p_tz) at time zone a.timezone)) = a.weekday
                  and ((((ld + tm) at time zone p_tz) at time zone a.timezone))::time between a.start_local and a.end_local)
$function$;

-- Regular 저장: 이동 기간 줄은 건드리지 않음 (location_id is null 만 바꿈). 나머지는 20261110114500 판 그대로
create or replace function public.tutor_hours_save(p_tutor uuid, p_weekly text[], p_close text[], p_open text[])
 returns jsonb language plpgsql security definer set search_path to 'public' as $function$
declare
  v_tutor uuid := lms_screen_tutor(p_tutor);
  v_tz text;
  v_from date;
  v_mon date;
  v_times time[];
  v_old text[];
  v_new text[];
  v_add text[] := '{}';
  v_del text[] := '{}';
  k text;
  w record;
  v_ld date;
  v_tm time;
  v_at timestamptz;
  v_end timestamptz;
  v_s timestamptz;
  v_e timestamptz;
  o record;
  v_changes jsonb;
begin
  select timezone into v_tz from tutors where id = v_tutor;
  v_mon := lms_local_monday(v_tz);
  v_from := v_mon + 7;
  v_times := array(select lms_hours_times(v_tz, v_mon));
  perform set_config('app.actor_id', coalesce(auth.uid()::text, ''), true);
  perform set_config('app.actor_via', case when is_admin() then 'admin_tutor_hours' else 'tutor_hours' end, true);

  if p_weekly is not null then
    foreach k in array p_weekly loop
      if k !~ '^[0-6]:\d\d:\d\d$' or not (substr(k, 3)::time = any (v_times)) then raise exception 'Invalid time: %', k; end if;
    end loop;
    v_old := array(select lms_weekly_open(v_tutor, v_tz, v_from, v_times));
    v_new := array(select distinct x from unnest(p_weekly) x);
    v_add := array(select x from unnest(v_new) x where not (x = any (v_old)) order by 1);
    v_del := array(select x from unnest(v_old) x where not (x = any (v_new)) order by 1);
    for w in select * from lms_weekly_classes(v_tutor, v_tz, v_from) loop
      foreach k in array v_del loop
        v_tm := substr(k, 3)::time;
        if split_part(k, ':', 1)::int = w.d and v_tm < w.start_local + make_interval(mins => w.minutes) and w.start_local < v_tm + interval '30 minutes' then
          raise exception 'Every % % has a weekly class with %. Please ask the Edge English team to change it.',
            to_char(date '2026-11-01' + w.d, 'FMDay'), to_char(w.start_local, 'FMHH24:MI'), w.student;
        end if;
      end loop;
    end loop;
    if cardinality(v_add) + cardinality(v_del) > 0 then
      delete from tutor_availability where tutor_id = v_tutor and location_id is null and effective_from >= v_from;
      update tutor_availability set effective_to = v_from - 1
      where tutor_id = v_tutor and location_id is null and effective_from < v_from and (effective_to is null or effective_to >= v_from);
      insert into tutor_availability (tutor_id, weekday, start_local, end_local, timezone, effective_from)
      select v_tutor, d, min(tm), max(tm), v_tz, v_from
      from (select d, tm, (extract(epoch from tm)::int / 1800) - row_number() over (partition by d order by tm) grp
            from (select split_part(x, ':', 1)::int d, substr(x, 3)::time tm from unnest(v_new) x) a) b
      group by d, grp;
    end if;
  end if;

  foreach k in array coalesce(p_open, '{}') || coalesce(p_close, '{}') loop
    if k !~ '^\d{4}-\d\d-\d\dT\d\d:\d\d$' then raise exception 'Invalid time: %', k; end if;
    v_ld := left(k, 10)::date;
    v_tm := right(k, 5)::time;
    if v_ld < v_mon or v_ld > v_mon + 27 or not (v_tm = any (v_times)) then raise exception 'Invalid time: %', k; end if;
  end loop;
  foreach k in array coalesce(p_open, '{}') loop
    v_at := (left(k, 10)::date + right(k, 5)::time) at time zone v_tz;
    v_end := v_at + interval '30 minutes';
    if lms_hours_cell(v_tutor, v_at) <> 'b' then raise exception '% % can''t be opened here.', left(k, 10), right(k, 5); end if;
    for o in select * from tutor_time_off where tutor_id = v_tutor and kind = 'block' and starts_at < v_end and v_at < ends_at loop
      delete from tutor_time_off where id = o.id;
      if o.starts_at < v_at then
        insert into tutor_time_off (tutor_id, starts_at, ends_at, kind, reason, created_by) values (v_tutor, o.starts_at, v_at, 'block', o.reason, auth.uid());
      end if;
      if v_end < o.ends_at then
        insert into tutor_time_off (tutor_id, starts_at, ends_at, kind, reason, created_by) values (v_tutor, v_end, o.ends_at, 'block', o.reason, auth.uid());
      end if;
    end loop;
  end loop;
  foreach k in array coalesce(p_close, '{}') loop
    v_at := (left(k, 10)::date + right(k, 5)::time) at time zone v_tz;
    if lms_hours_cell(v_tutor, v_at) <> 'o' then raise exception '% % can''t be closed here.', left(k, 10), right(k, 5); end if;
    v_s := v_at;
    v_e := v_at + interval '30 minutes';
    for o in select * from tutor_time_off where tutor_id = v_tutor and kind = 'block' and starts_at <= v_e and v_s <= ends_at loop
      v_s := least(v_s, o.starts_at);
      v_e := greatest(v_e, o.ends_at);
      delete from tutor_time_off where id = o.id;
    end loop;
    insert into tutor_time_off (tutor_id, starts_at, ends_at, kind, reason, created_by)
    values (v_tutor, v_s, v_e, 'block', 'Unavailable this week (My hours)', auth.uid());
  end loop;

  v_changes := jsonb_build_object('from', v_from, 'weekly_open', to_jsonb(v_add), 'weekly_close', to_jsonb(v_del),
    'once_close', to_jsonb(array(select distinct x from unnest(coalesce(p_close, '{}')) x order by 1)),
    'once_open', to_jsonb(array(select distinct x from unnest(coalesce(p_open, '{}')) x order by 1)));
  if cardinality(v_add) + cardinality(v_del) + cardinality(coalesce(p_close, '{}')) + cardinality(coalesce(p_open, '{}')) > 0 then
    insert into tutor_hours_changes (tutor_id, actor, by_admin, changes) values (v_tutor, auth.uid(), is_admin(), v_changes);
  end if;
  return v_changes;
end $function$;

-- 이동 기간 한 줄 (화면용)
create or replace function lms_tutor_location_json(l tutor_locations) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object('id', l.id, 'city', l.city, 'country', l.country, 'timezone', l.timezone,
    'from', l.starts_on, 'to', l.ends_on,
    -- 격자 첫 주 월요일 (기간 첫날과 그 지역 오늘 중 늦은 날이 든 주)
    'monday', m.mon,
    'weekly_open', to_jsonb(array(
      select distinct a.weekday || ':' || to_char(tm, 'HH24:MI')
      from tutor_availability a cross join unnest(array(select lms_hours_times(l.timezone, m.mon))) tm
      where a.location_id = l.id and tm between a.start_local and a.end_local order by 1)),
    'weekly_classes', coalesce((select jsonb_agg(jsonb_build_object('d', w.d, 'time', to_char(w.start_local, 'HH24:MI'), 'min', w.minutes, 'student', w.student))
                                from lms_weekly_classes(l.tutor_id, l.timezone, m.mon) w), '[]'::jsonb))
  from (select d - (extract(isodow from d)::int - 1) mon
        from (select greatest(l.starts_on, (now() at time zone l.timezone)::date) d) z) m
$$;
revoke all on function lms_tutor_location_json(tutor_locations) from public, anon, authenticated;

-- 아직 안 끝난 이동 기간 (그 지역 오늘 기준)
create or replace function lms_tutor_locations_live(p_tutor uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(lms_tutor_location_json(l) order by l.starts_on), '[]'::jsonb)
  from tutor_locations l
  where l.tutor_id = p_tutor and (l.ends_on is null or l.ends_on >= (now() at time zone l.timezone)::date)
$$;
revoke all on function lms_tutor_locations_live(uuid) from public, anon, authenticated;

-- Regular Working Hours 자료: 기존 + 평소 나라(home)·이동 기간(locations)
create or replace function public.tutor_hours(p_tutor uuid)
 returns jsonb language plpgsql stable security definer set search_path to 'public' as $function$
declare
  v_tutor uuid := lms_screen_tutor(p_tutor);
  t tutors;
  v_from date;
  v_mon date;
  v_times time[];
begin
  select * into t from tutors where id = v_tutor;
  v_mon := lms_local_monday(t.timezone);
  v_from := v_mon + 7;
  v_times := array(select lms_hours_times(t.timezone, v_mon));
  return jsonb_build_object(
    'tutor', jsonb_build_object('id', t.id, 'name', t.name, 'timezone', t.timezone, 'country', t.country),
    'from', v_from,
    'monday', v_mon,
    'times', to_jsonb(array(select to_char(x, 'HH24:MI') from unnest(v_times) x)),
    'weekly_open', to_jsonb(array(select lms_weekly_open(v_tutor, t.timezone, v_from, v_times))),
    'weekly_classes', coalesce((select jsonb_agg(jsonb_build_object('d', w.d, 'time', to_char(w.start_local, 'HH24:MI'), 'min', w.minutes, 'student', w.student))
                                from lms_weekly_classes(v_tutor, t.timezone, v_from) w), '[]'::jsonb),
    'cells', coalesce((select jsonb_object_agg(k, c) from (
        select to_char(ld + tm, 'YYYY-MM-DD"T"HH24:MI') k, lms_hours_cell(v_tutor, (ld + tm) at time zone t.timezone) c
        from generate_series(v_mon, v_mon + 27, interval '1 day') g cross join lateral (select g::date ld) d cross join unnest(v_times) tm) z
      where c <> 'o'), '{}'::jsonb),
    'lessons', coalesce((select jsonb_agg(jsonb_build_object(
        'start', to_char(l.starts_at at time zone t.timezone, 'YYYY-MM-DD"T"HH24:MI'),
        'min', (extract(epoch from l.ends_at - l.starts_at) / 60)::int,
        'student', coalesce(s.display_name, s.name_en), 'makeup', l.kind <> 'regular') order by l.starts_at)
      from lessons l join students s on s.id = l.student_id
      where l.tutor_id = v_tutor and l.state <> 'canceled' and l.voided_at is null
        and l.ends_at > (v_mon::timestamp at time zone t.timezone) and l.starts_at < ((v_mon + 28)::timestamp at time zone t.timezone)), '[]'::jsonb),
    'locations', lms_tutor_locations_live(v_tutor),
    'history', case when is_admin() then coalesce((select jsonb_agg(jsonb_build_object('at', h.at, 'by_admin', h.by_admin, 'changes', h.changes) order by h.at desc)
                                                    from tutor_hours_changes h where h.tutor_id = v_tutor), '[]'::jsonb) end);
end $function$;

-- [Add Temporary Location] (p_location null) · [Set end date] (p_location = 그 기간, 종료일만 바꿈)
create or replace function tutor_location_save(p_tutor uuid, p_location uuid, p_city text, p_country text, p_timezone text, p_from date, p_to date)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_tutor uuid := lms_screen_tutor(p_tutor);
  l tutor_locations;
  v_today date;
begin
  perform set_config('app.actor_id', coalesce(auth.uid()::text, ''), true);
  perform set_config('app.actor_via', case when is_admin() then 'admin_tutor_location' else 'tutor_location' end, true);
  if p_location is null then
    if btrim(coalesce(p_city, '')) = '' or p_timezone is null or not is_valid_timezone(p_timezone) then raise exception 'Pick a city.'; end if;
    if p_from is null then raise exception 'Pick a start date.'; end if;
    v_today := (now() at time zone p_timezone)::date;
    if p_from < v_today then raise exception 'The start date has passed.'; end if;
    if p_to is not null and p_to < p_from then raise exception 'The end date must be on or after the start date.'; end if;
    if exists (select 1 from tutor_locations x where x.tutor_id = v_tutor
               and x.starts_on <= coalesce(p_to, 'infinity'::date) and p_from <= coalesce(x.ends_on, 'infinity'::date)
               and (x.ends_on is null or x.ends_on >= (now() at time zone x.timezone)::date)) then
      raise exception 'These dates overlap another temporary location.';
    end if;
    insert into tutor_locations (tutor_id, city, country, timezone, starts_on, ends_on, created_by)
    values (v_tutor, btrim(p_city), btrim(coalesce(p_country, '')), p_timezone, p_from, p_to, auth.uid()) returning * into l;
    insert into tutor_hours_changes (tutor_id, actor, by_admin, changes)
    values (v_tutor, auth.uid(), is_admin(), jsonb_build_object('from', p_from, 'weekly_open', '[]'::jsonb, 'weekly_close', '[]'::jsonb, 'once_close', '[]'::jsonb, 'once_open', '[]'::jsonb,
      'location', jsonb_build_object('action', 'add', 'city', l.city, 'country', l.country, 'timezone', l.timezone, 'from', l.starts_on, 'to', l.ends_on)));
  else
    select * into l from tutor_locations where id = p_location and tutor_id = v_tutor for update;
    if not found then raise exception 'This temporary location is gone. Please refresh.'; end if;
    v_today := (now() at time zone l.timezone)::date;
    if l.ends_on is not null and l.ends_on < v_today then raise exception 'This temporary location has ended.'; end if;
    if p_to is null then raise exception 'Pick an end date.'; end if;
    if p_to < l.starts_on then raise exception 'The end date must be on or after the start date.'; end if;
    if p_to < v_today then raise exception 'The end date has passed.'; end if;
    if exists (select 1 from tutor_locations x where x.tutor_id = v_tutor and x.id <> l.id
               and x.starts_on <= p_to and l.starts_on <= coalesce(x.ends_on, 'infinity'::date)) then
      raise exception 'These dates overlap another temporary location.';
    end if;
    update tutor_locations set ends_on = p_to where id = l.id returning * into l;
    insert into tutor_hours_changes (tutor_id, actor, by_admin, changes)
    values (v_tutor, auth.uid(), is_admin(), jsonb_build_object('from', l.starts_on, 'weekly_open', '[]'::jsonb, 'weekly_close', '[]'::jsonb, 'once_close', '[]'::jsonb, 'once_open', '[]'::jsonb,
      'location', jsonb_build_object('action', 'end', 'city', l.city, 'country', l.country, 'timezone', l.timezone, 'from', l.starts_on, 'to', l.ends_on)));
  end if;
  return lms_tutor_location_json(l);
end $$;
revoke all on function tutor_location_save(uuid, uuid, text, text, text, date, date) from public, anon;
grant execute on function tutor_location_save(uuid, uuid, text, text, text, date, date) to authenticated;

-- 이동 기간 매주 시간 저장 (그 지역 현지 '요일:HH:MM'). 바로 적용 (기간 전체), 이미 잡힌 수업은 그대로
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
    delete from tutor_availability where location_id = l.id;
    insert into tutor_availability (tutor_id, weekday, start_local, end_local, timezone, effective_from, location_id)
    select v_tutor, d, min(tm), max(tm), l.timezone, l.starts_on, l.id
    from (select d, tm, (extract(epoch from tm)::int / 1800) - row_number() over (partition by d order by tm) grp
          from (select split_part(x, ':', 1)::int d, substr(x, 3)::time tm from unnest(v_new) x) a) b
    group by d, grp;
    v_changes := jsonb_build_object('from', l.starts_on, 'weekly_open', to_jsonb(v_add), 'weekly_close', to_jsonb(v_del), 'once_close', '[]'::jsonb, 'once_open', '[]'::jsonb,
      'location', jsonb_build_object('action', 'hours', 'city', l.city, 'country', l.country, 'timezone', l.timezone, 'from', l.starts_on, 'to', l.ends_on));
    insert into tutor_hours_changes (tutor_id, actor, by_admin, changes) values (v_tutor, auth.uid(), is_admin(), v_changes);
  end if;
  return lms_tutor_location_json(l);
end $$;
revoke all on function tutor_location_hours_save(uuid, uuid, text[]) from public, anon;
grant execute on function tutor_location_hours_save(uuid, uuid, text[]) to authenticated;

-- Calendar 자료: 칸 키는 그대로 강사 시간대(현지 Regular) 날짜·시각. 이동 기간이면 그 지역 06:00~22:30 이 맞는 칸이 강사 시간대로는 다른 시각이라
--  하루 48칸 전체를 보고, 시작할 수 없는 칸은 'n' 으로 돌려줌. locations = 이동 기간 (보는 시간대 고르기용)
create or replace function public.tutor_schedule(p_tutor uuid, p_from date, p_to date, p_cells boolean default false)
 returns jsonb language plpgsql stable security definer set search_path to 'public' as $function$
declare
  v_tutor uuid := lms_screen_tutor(p_tutor);
  t tutors;
  v_today date;
  v_last date;
  v_times time[];
  v_a timestamptz;
  v_b timestamptz;
begin
  if p_from is null or p_to is null or p_to < p_from or p_to - p_from > 49 then raise exception 'Invalid date range.'; end if;
  select * into t from tutors where id = v_tutor;
  v_today := (now() at time zone t.timezone)::date;
  v_last := v_today + 84;
  v_times := array(select lms_hours_times(t.timezone, v_today));
  v_a := p_from::timestamp at time zone t.timezone;
  v_b := (p_to + 1)::timestamp at time zone t.timezone;
  return jsonb_build_object(
    'tutor', jsonb_build_object('id', t.id, 'name', t.name, 'timezone', t.timezone, 'country', t.country),
    'today', v_today,
    'last', v_last,
    'times', to_jsonb(array(select to_char(x, 'HH24:MI') from unnest(v_times) x)),
    'cells', case when p_cells then coalesce((select jsonb_object_agg(k, c) from (
        select to_char(ld + tm, 'YYYY-MM-DD"T"HH24:MI') k,
               case when lms_tutor_start_ok(v_tutor, (ld + tm) at time zone t.timezone) then lms_hours_cell(v_tutor, (ld + tm) at time zone t.timezone) else 'n' end c
        from generate_series(greatest(p_from, v_today), least(p_to, v_last), interval '1 day') g
        cross join lateral (select g::date ld) d
        cross join lateral (select s::time tm from generate_series(timestamp '2000-01-01 00:00', timestamp '2000-01-01 23:30', interval '30 minutes') s) z0) z
      where c <> 'o'), '{}'::jsonb) end,
    'blocks', coalesce((select jsonb_agg(jsonb_build_object(
        'id', o.id, 'kind', o.kind,
        'start', to_char(o.starts_at at time zone t.timezone, 'YYYY-MM-DD"T"HH24:MI'),
        'end', to_char(o.ends_at at time zone t.timezone, 'YYYY-MM-DD"T"HH24:MI'),
        'note', case when o.kind = 'block' then lms_block_note(o.reason) end) order by o.starts_at)
      from tutor_time_off o where o.tutor_id = v_tutor and o.starts_at < v_b and v_a < o.ends_at), '[]'::jsonb),
    'opens', coalesce((select jsonb_agg(jsonb_build_object(
        'start', to_char(o.starts_at at time zone t.timezone, 'YYYY-MM-DD"T"HH24:MI'),
        'end', to_char(o.ends_at at time zone t.timezone, 'YYYY-MM-DD"T"HH24:MI')) order by o.starts_at)
      from tutor_open_once o where o.tutor_id = v_tutor and o.starts_at < v_b and v_a < o.ends_at), '[]'::jsonb),
    'locations', coalesce((select jsonb_agg(jsonb_build_object('id', l.id, 'city', l.city, 'country', l.country, 'timezone', l.timezone, 'from', l.starts_on, 'to', l.ends_on) order by l.starts_on)
      from tutor_locations l where l.tutor_id = v_tutor), '[]'::jsonb));
end $function$;

-- Calendar 막기·열기: 칸 키는 강사 시간대 그대로. 시작 가능 여부는 그 시각에 있는 지역 06:00~22:30 (이동 기간 반영)
create or replace function public.tutor_schedule_save(p_tutor uuid, p_action text, p_cells text[] default null::text[], p_note text default null::text, p_block uuid default null::uuid)
 returns jsonb language plpgsql security definer set search_path to 'public' as $function$
declare
  v_tutor uuid := lms_screen_tutor(p_tutor);
  v_tz text;
  v_today date;
  v_last date;
  v_note text := nullif(btrim(coalesce(p_note, '')), '');
  v_keys text[];
  k text;
  v_c text;
  v_at timestamptz;
  v_end timestamptz;
  v_cut timestamptz;
  o record;
  v_s timestamptz;
  v_e timestamptz;
  v_runs tstzrange[];
  v_xs boolean[];
  i int;
  v_changes jsonb;
begin
  select timezone into v_tz from tutors where id = v_tutor;
  v_today := (now() at time zone v_tz)::date;
  v_last := v_today + 84;   -- 오늘부터 12주 후까지 (대표 H26(50) ②)
  perform set_config('app.actor_id', coalesce(auth.uid()::text, ''), true);
  perform set_config('app.actor_via', case when is_admin() then 'admin_tutor_schedule' else 'tutor_schedule' end, true);
  if v_note is not null and char_length(v_note) > 100 then raise exception 'Note is too long (100 characters max).'; end if;   -- 대표 H26(50) ③

  if p_action in ('block', 'open') then
    v_keys := array(select distinct x from unnest(coalesce(p_cells, '{}')) x order by 1);
    if cardinality(v_keys) = 0 then raise exception 'Pick a time.'; end if;
    foreach k in array v_keys loop
      if k !~ '^\d{4}-\d\d-\d\dT\d\d:(00|30)$' then raise exception 'Invalid time: %', k; end if;
      if left(k, 10)::date < v_today or left(k, 10)::date > v_last then raise exception 'You can only change times up to 12 weeks ahead.'; end if;
      v_at := (left(k, 10)::date + right(k, 5)::time) at time zone v_tz;
      if not lms_tutor_start_ok(v_tutor, v_at) then raise exception 'Invalid time: %', k; end if;
      v_c := lms_hours_cell(v_tutor, v_at);
      if v_c = 'c' then
        select format('You have a class at %s %s. Classes can''t be blocked.', to_char(x.starts_at at time zone lms_tutor_tz_at(v_tutor, x.starts_at), 'HH24:MI'), lms_city_time(lms_tutor_tz_at(v_tutor, x.starts_at))) into k
        from lessons x where x.tutor_id = v_tutor and x.state <> 'canceled' and x.voided_at is null
          and x.starts_at < v_at + interval '30 minutes' and v_at < x.ends_at order by x.starts_at limit 1;
        raise exception '%', k;
      end if;
      if v_c = 'p' then raise exception 'Can''t change: less than 6 hours away.'; end if;
      if v_c = 'r' then raise exception 'A make-up or cover request is waiting for this time. Answer it first.'; end if;
      if v_c = 'a' then raise exception 'Your answer has been sent for this time. Waiting for Edge English to confirm. Contact Edge English to change it.'; end if;
      if v_c = 'l' then raise exception 'This time is in your leave.'; end if;
      if p_action = 'block' and v_c not in ('o', 'x') then
        raise exception '% % is already %.', left(k, 10), right(k, 5), case v_c when 'b' then 'blocked' else 'not available' end;
      end if;
      if p_action = 'open' and v_c <> 's' then raise exception '% % is already available.', left(k, 10), right(k, 5); end if;
    end loop;

    -- 이어진 칸 = 한 줄 (메모는 줄마다 그대로, 다른 줄과 합치지 않음). 바꾸기 전에 묶음을 먼저 다 계산해 둠
    select array_agg(tstzrange(s, e) order by s), array_agg(all_x order by s) into v_runs, v_xs
    from (select min(a) s, max(a) + interval '30 minutes' e, bool_and(c = 'x') all_x
          from (select a, c, extract(epoch from a)::bigint / 1800 - row_number() over (partition by c = 'x' order by a) grp
                from (select (left(x, 10)::date + right(x, 5)::time) at time zone v_tz a, lms_hours_cell(v_tutor, (left(x, 10)::date + right(x, 5)::time) at time zone v_tz) c
                      from unnest(v_keys) x) q) z
          group by grp, (c = 'x')) w;
    for i in 1 .. cardinality(v_runs) loop
      v_s := lower(v_runs[i]);
      v_e := upper(v_runs[i]);
      if p_action = 'open' then
        -- 붙어 있는 그날만 연 줄과 합침
        v_at := v_s;
        v_end := v_e;
        for o in select * from tutor_open_once where tutor_id = v_tutor and starts_at <= v_end and v_at <= ends_at loop
          v_at := least(v_at, o.starts_at);
          v_end := greatest(v_end, o.ends_at);
          delete from tutor_open_once where id = o.id;
        end loop;
        insert into tutor_open_once (tutor_id, starts_at, ends_at, created_by) values (v_tutor, v_at, v_end, auth.uid());
      elsif v_xs[i] then
        -- 그날만 연 칸을 다시 막음 = 그 열기를 그 칸만 거둠 (매주 닫힌 시간으로 돌아감)
        for o in select * from tutor_open_once where tutor_id = v_tutor and starts_at < v_e and v_s < ends_at loop
          delete from tutor_open_once where id = o.id;
          if o.starts_at < v_s then insert into tutor_open_once (tutor_id, starts_at, ends_at, created_by) values (v_tutor, o.starts_at, v_s, o.created_by); end if;
          if v_e < o.ends_at then insert into tutor_open_once (tutor_id, starts_at, ends_at, created_by) values (v_tutor, v_e, o.ends_at, o.created_by); end if;
        end loop;
      else
        insert into tutor_time_off (tutor_id, starts_at, ends_at, kind, reason, created_by) values (v_tutor, v_s, v_e, 'block', v_note, auth.uid());
      end if;
    end loop;
    v_changes := jsonb_build_object('from', v_today, 'weekly_open', '[]'::jsonb, 'weekly_close', '[]'::jsonb,
      'once_close', case when p_action = 'block' then to_jsonb(v_keys) else '[]'::jsonb end, 'once_open', '[]'::jsonb,
      'day_open', case when p_action = 'open' then to_jsonb(v_keys) else '[]'::jsonb end, 'note', v_note);

  elsif p_action in ('note', 'unblock') then
    select * into o from tutor_time_off where id = p_block and tutor_id = v_tutor and kind = 'block';
    if not found then raise exception 'This blocked time is gone. Please refresh.'; end if;
    if o.ends_at <= now() then raise exception 'Can''t change: this time has passed.'; end if;
    if p_action = 'note' then
      update tutor_time_off set reason = v_note where id = o.id;
      v_changes := jsonb_build_object('from', v_today, 'weekly_open', '[]'::jsonb, 'weekly_close', '[]'::jsonb, 'once_close', '[]'::jsonb, 'once_open', '[]'::jsonb,
        'day_open', '[]'::jsonb, 'note', v_note,
        'note_of', to_char(o.starts_at at time zone v_tz, 'YYYY-MM-DD"T"HH24:MI') || '/' || to_char(o.ends_at at time zone v_tz, 'YYYY-MM-DD"T"HH24:MI'));
    else
      -- 6시간 안 부분은 못 바꿈 → 그 뒤 첫 30분 칸(강사 현지)부터만 풂
      v_cut := date_bin(interval '30 minutes', ((now() + interval '6 hours') at time zone v_tz) + interval '30 minutes' - interval '1 microsecond', timestamp '2000-01-01') at time zone v_tz;
      if o.ends_at <= v_cut then raise exception 'Can''t change: less than 6 hours away.'; end if;
      v_keys := array(select to_char(g at time zone v_tz, 'YYYY-MM-DD"T"HH24:MI')
                      from generate_series(greatest(o.starts_at, v_cut), o.ends_at - interval '1 second', interval '30 minutes') g
                      where lms_tutor_start_ok(v_tutor, g));
      delete from tutor_time_off where id = o.id;
      if o.starts_at < v_cut then
        insert into tutor_time_off (tutor_id, starts_at, ends_at, kind, reason, created_by) values (v_tutor, o.starts_at, v_cut, 'block', o.reason, o.created_by);
      end if;
      v_changes := jsonb_build_object('from', v_today, 'weekly_open', '[]'::jsonb, 'weekly_close', '[]'::jsonb, 'once_close', '[]'::jsonb,
        'once_open', to_jsonb(v_keys), 'day_open', '[]'::jsonb, 'note', null);
    end if;
  else
    raise exception 'Invalid action.';
  end if;

  insert into tutor_hours_changes (tutor_id, actor, by_admin, changes) values (v_tutor, auth.uid(), is_admin(), v_changes);
  return v_changes;
end $function$;

-- [Set Multiple Days] 여러 날 한 번에 열기 (Days → Time → Review). 날짜·시각은 그 날짜에 있는 지역 현지.
--  한 번 부를 때 날짜들은 모두 같은 지역이어야 함 (두 지역에 걸치면 화면에서 [Split by location] 으로 나눠 부름)
--  막힌 날(수업·6시간 안·요청 대기·휴무·12주 초과·지난 날·이미 열림)은 빼고 이유를 돌려줌. p_apply = false 면 미리보기만
create or replace function tutor_schedule_multi(p_tutor uuid, p_from date, p_to date, p_start time, p_end time, p_apply boolean default false)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_tutor uuid := lms_screen_tutor(p_tutor);
  v_home text;
  v_tz text;
  v_last timestamptz;
  v_day date;
  v_tm time;
  v_at timestamptz;
  v_c text;
  v_why text;
  v_open timestamptz[];
  v_unblock timestamptz[];
  v_days jsonb := '[]'::jsonb;
  v_keys text[] := '{}';
  v_n int := 0;
  a timestamptz;
  o record;
  v_s timestamptz;
  v_e timestamptz;
begin
  perform set_config('app.actor_id', coalesce(auth.uid()::text, ''), true);
  perform set_config('app.actor_via', case when is_admin() then 'admin_tutor_schedule' else 'tutor_schedule' end, true);
  select timezone into v_home from tutors where id = v_tutor;
  if p_from is null or p_to is null or p_to < p_from or p_to - p_from > 90 then raise exception 'Pick the days.'; end if;
  if p_start is null or p_end is null or p_end <= p_start or p_start < time '06:00' or p_start > time '22:30' or p_end > time '23:00'
     or extract(minute from p_start)::int % 30 <> 0 or extract(minute from p_end)::int % 30 <> 0 then
    raise exception 'Pick a start time from 6:00 AM to 10:30 PM.';
  end if;
  v_tz := lms_tutor_tz_on(v_tutor, p_from);
  if exists (select 1 from generate_series(p_from, p_to, interval '1 day') g where lms_tutor_tz_on(v_tutor, g::date) <> v_tz) then
    raise exception 'The selected days are in two locations';
  end if;
  v_last := ((now() at time zone v_home)::date + 85)::timestamp at time zone v_home;   -- Calendar 와 같은 12주 끝

  for v_day in select g::date from generate_series(p_from, p_to, interval '1 day') g loop
    v_why := null;
    v_open := '{}';
    v_unblock := '{}';
    if (v_day + p_start) at time zone v_tz < now() then v_why := 'past';
    elsif (v_day + p_start) at time zone v_tz >= v_last then v_why := 'far';
    else
      for v_tm in select s::time from generate_series(timestamp '2000-01-01' + p_start, timestamp '2000-01-01' + p_end - interval '30 minutes', interval '30 minutes') s loop
        v_at := (v_day + v_tm) at time zone v_tz;
        v_c := lms_hours_cell(v_tutor, v_at);
        if v_c in ('c', 'p', 'r', 'a', 'l') then v_why := v_c; exit; end if;
        if v_at >= v_last then v_why := 'far'; exit; end if;
        if v_c = 's' then v_open := v_open || v_at; elsif v_c = 'b' then v_unblock := v_unblock || v_at; end if;
      end loop;
      if v_why is null and cardinality(v_open) + cardinality(v_unblock) = 0 then v_why := 'open'; end if;
    end if;

    v_days := v_days || jsonb_build_object('date', v_day, 'ok', v_why is null, 'why', v_why,
      'class', case when v_why = 'c' then (select to_char(x.starts_at at time zone v_tz, 'HH24:MI') from lessons x
          where x.tutor_id = v_tutor and x.state <> 'canceled' and x.voided_at is null
            and x.starts_at < (v_day + p_end) at time zone v_tz and (v_day + p_start) at time zone v_tz < x.ends_at order by x.starts_at limit 1) end);

    if v_why is null then
      v_n := v_n + 1;
      if p_apply then
        foreach a in array v_open loop
          v_s := a;
          v_e := a + interval '30 minutes';
          for o in select * from tutor_open_once where tutor_id = v_tutor and starts_at <= v_e and v_s <= ends_at loop
            v_s := least(v_s, o.starts_at);
            v_e := greatest(v_e, o.ends_at);
            delete from tutor_open_once where id = o.id;
          end loop;
          insert into tutor_open_once (tutor_id, starts_at, ends_at, created_by) values (v_tutor, v_s, v_e, auth.uid());
          v_keys := v_keys || to_char(a at time zone v_home, 'YYYY-MM-DD"T"HH24:MI');
        end loop;
        foreach a in array v_unblock loop
          v_e := a + interval '30 minutes';
          for o in select * from tutor_time_off where tutor_id = v_tutor and kind = 'block' and starts_at < v_e and a < ends_at loop
            delete from tutor_time_off where id = o.id;
            if o.starts_at < a then insert into tutor_time_off (tutor_id, starts_at, ends_at, kind, reason, created_by) values (v_tutor, o.starts_at, a, 'block', o.reason, o.created_by); end if;
            if v_e < o.ends_at then insert into tutor_time_off (tutor_id, starts_at, ends_at, kind, reason, created_by) values (v_tutor, v_e, o.ends_at, 'block', o.reason, o.created_by); end if;
          end loop;
          -- 막은 칸을 풀었는데 매주 시간이 닫혀 있으면 그날만 열기도
          if not lms_tutor_available(v_tutor, a) then insert into tutor_open_once (tutor_id, starts_at, ends_at, created_by) values (v_tutor, a, v_e, auth.uid()); end if;
          v_keys := v_keys || to_char(a at time zone v_home, 'YYYY-MM-DD"T"HH24:MI');
        end loop;
      end if;
    end if;
  end loop;

  if p_apply and cardinality(v_keys) > 0 then
    insert into tutor_hours_changes (tutor_id, actor, by_admin, changes)
    values (v_tutor, auth.uid(), is_admin(), jsonb_build_object('from', (now() at time zone v_home)::date, 'weekly_open', '[]'::jsonb, 'weekly_close', '[]'::jsonb,
      'once_close', '[]'::jsonb, 'once_open', '[]'::jsonb, 'day_open', to_jsonb(array(select distinct x from unnest(v_keys) x order by 1)), 'note', null));
  end if;
  return jsonb_build_object('timezone', v_tz, 'days', v_days, 'ok', v_n);
end $$;
revoke all on function tutor_schedule_multi(uuid, date, date, time, time, boolean) from public, anon;
grant execute on function tutor_schedule_multi(uuid, date, date, time, time, boolean) to authenticated;

-- 도시 검색에 아르헨티나 추가 (places.ts) → 학생 메일 한국어 시간대 이름 표도 같게 (zone-names.test.ts 가 대조)
create or replace function lms_mail_ko_zone(p_tz text) returns text
language sql immutable as $$
  select case when coalesce(nullif(p_tz, ''), 'Asia/Seoul') = 'Asia/Seoul' then '한국'
              else case p_tz
                when 'America/New_York' then '뉴욕'
                when 'America/Detroit' then '디트로이트'
                when 'America/Chicago' then '시카고'
                when 'America/Denver' then '덴버'
                when 'America/Phoenix' then '피닉스'
                when 'America/Los_Angeles' then '로스앤젤레스'
                when 'Pacific/Honolulu' then '호놀룰루'
                when 'America/Anchorage' then '앵커리지'
                when 'America/Toronto' then '토론토'
                when 'America/Vancouver' then '밴쿠버'
                when 'America/Edmonton' then '에드먼턴'
                when 'America/Winnipeg' then '위니펙'
                when 'America/Regina' then '리자이나'
                when 'America/Halifax' then '핼리팩스'
                when 'Australia/Sydney' then '시드니'
                when 'Australia/Melbourne' then '멜버른'
                when 'Australia/Brisbane' then '브리즈번'
                when 'Australia/Perth' then '퍼스'
                when 'Australia/Adelaide' then '애들레이드'
                when 'Australia/Hobart' then '호바트'
                when 'Australia/Darwin' then '다윈'
                when 'Pacific/Auckland' then '오클랜드'
                when 'Europe/London' then '런던'
                when 'Asia/Tokyo' then '도쿄'
                when 'Asia/Shanghai' then '상하이'
                when 'Asia/Hong_Kong' then '홍콩'
                when 'Asia/Taipei' then '타이베이'
                when 'Asia/Singapore' then '싱가포르'
                when 'Asia/Ho_Chi_Minh' then '호찌민'
                when 'Asia/Bangkok' then '방콕'
                when 'Asia/Manila' then '마닐라'
                when 'Asia/Kuala_Lumpur' then '쿠알라룸푸르'
                when 'Asia/Jakarta' then '자카르타'
                when 'Asia/Makassar' then '발리'
                when 'Asia/Dubai' then '두바이'
                when 'Europe/Berlin' then '베를린'
                when 'Europe/Paris' then '파리'
                when 'Europe/Amsterdam' then '암스테르담'
                when 'Europe/Madrid' then '마드리드'
                when 'Europe/Dublin' then '더블린'
                when 'Europe/Warsaw' then '바르샤바'
                when 'America/Argentina/Buenos_Aires' then '부에노스아이레스'
                when 'America/Argentina/Mendoza' then '멘도사'
                else replace(split_part(p_tz, '/', array_length(string_to_array(p_tz, '/'), 1)), '_', ' ') end
         end || ' 시간'
$$;
revoke all on function lms_mail_ko_zone(text) from public, anon, authenticated;
