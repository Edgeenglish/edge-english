-- 강사 해외 이동 기간 독립 QA(11/14) 고침 — 정책 원본 H26(176) 후속
--  ① Calendar 칸 키를 '그 날짜에 있는 지역' 현지 날짜·시각으로 (강사 평소 시간대 키는 평소 지역 서머타임 끝나는 날 같은 키가 두 시각이 됨).
--     시작 가능 칸은 그 지역 06:00~22:30 이라 서머타임 바뀌는 새벽 시각과 안 겹침
--  ② 복귀일·출발일 경계: 그 날짜 지역 시각인데 실제로는 다른 지역 날짜인 시각은 칸 'n'·저장 불가·여러 날 등록 이유 'zone' (lms_tutor_available 과 같은 판정)
--  ⑤ 여러 날 등록: 닫힌 시간에 대기 중인 보강·대체 요청이 있어도 막고 이유 r·a

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
               case when lms_tutor_tz_at(v_tutor, (ld + tm) at time zone lms_tutor_tz_on(v_tutor, ld)) <> lms_tutor_tz_on(v_tutor, ld) then 'n'
                    else lms_hours_cell(v_tutor, (ld + tm) at time zone lms_tutor_tz_on(v_tutor, ld)) end c
        from generate_series(greatest(p_from, v_today), least(p_to, v_last), interval '1 day') g
        cross join lateral (select g::date ld) d
        cross join unnest(v_times) tm) z
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
      if k !~ '^\d{4}-\d\d-\d\dT\d\d:(00|30)$' or not (right(k, 5)::time between time '06:00' and time '22:30') then raise exception 'Invalid time: %', k; end if;
      if left(k, 10)::date < v_today or left(k, 10)::date > v_last then raise exception 'You can only change times up to 12 weeks ahead.'; end if;
      v_at := (left(k, 10)::date + right(k, 5)::time) at time zone lms_tutor_tz_on(v_tutor, left(k, 10)::date);
      if lms_tutor_tz_at(v_tutor, v_at) <> lms_tutor_tz_on(v_tutor, left(k, 10)::date) then raise exception 'Invalid time: %', k; end if;
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
                from (select (left(x, 10)::date + right(x, 5)::time) at time zone lms_tutor_tz_on(v_tutor, left(x, 10)::date) a,
                             lms_hours_cell(v_tutor, (left(x, 10)::date + right(x, 5)::time) at time zone lms_tutor_tz_on(v_tutor, left(x, 10)::date)) c
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
        if lms_tutor_tz_at(v_tutor, v_at) <> v_tz then v_why := 'zone'; exit; end if;
        v_c := lms_hours_cell(v_tutor, v_at);
        -- 닫힌 칸('s')도 대기 중인 보강·대체 요청이 있으면 막음 (lms_hours_cell 은 닫힘을 먼저 돌려줌, QA 11/14)
        if v_c in ('s', 'b') then
          if exists (select 1 from makeup_candidates c join makeup_requests r on r.id = c.request_id
                     where r.tutor_id = v_tutor and r.status in ('requested', 'countered') and c.tutor_answer is null
                       and c.starts_at < v_at + interval '30 minutes' and v_at < c.ends_at)
             or exists (select 1 from leave_items i where i.sub_tutor_id = v_tutor and i.sub_stage = 'asked'
                        and i.starts_at < v_at + interval '30 minutes' and v_at < i.ends_at) then v_c := 'r';
          elsif exists (select 1 from makeup_candidates c join makeup_requests r on r.id = c.request_id
                        where r.tutor_id = v_tutor and r.status in ('requested', 'countered') and c.tutor_answer = 'yes'
                          and c.starts_at < v_at + interval '30 minutes' and v_at < c.ends_at)
             or exists (select 1 from leave_items i where i.sub_tutor_id = v_tutor and i.sub_stage = 'tutor_ok'
                        and i.starts_at < v_at + interval '30 minutes' and v_at < i.ends_at) then v_c := 'a';
          end if;
        end if;
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
