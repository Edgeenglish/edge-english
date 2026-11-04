-- =====================================================================
-- 4403. 강사 Schedule — 날짜별 막기(Block time)·열기(Make available) (2026-11-04 대표 결정, 정책 원본 H26(49)+(50),
--       시안 docs/lms/previews/tutor-schedule-drafts.html 시안 2)
--  - My hours 의 'One week only' 를 없애고 Schedule 에서 날짜별로 바꿈. 기간 = 강사 현지 오늘부터 12주(84일) 후까지 (대표 H26(50) ②)
--  - 막기: tutor_time_off kind 'block' (기존 One week only 와 같은 표) + 메모(reason, 선택, 최대 100자, 대표 H26(50) ③)
--    메모는 강사 본인·운영진만 봄. 학생 쪽 함수는 reason 을 돌려주지 않음(그대로)
--  - 그날만 열기: 새 표 tutor_open_once — 매주 닫힌 칸(회색)을 그날만 엶. lms_tutor_available 이 이 표도 봄
--    (보강 날짜·대체강사 판정에 바로 반영). 현지 06:00~22:30 시작 규칙(4200)은 그대로
--  - 그대로 지킴: 수업·보강·답 대기·휴무 칸은 못 막음, 지난 시간·6시간 안은 못 바꿈. 판정은 lms_hours_cell 하나
--  - 바뀐 기록은 tutor_hours_changes 에 (운영자 보기 '바뀐 기록')
-- 기존 표·데이터·함수 인자는 그대로 (tutor_hours·tutor_hours_save 는 Availability 화면이 계속 씀). 다시 실행해도 같은 결과
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. 그날만 연 시간 (30분 칸 = 그 시각 수업 시작 가능, [starts_at, ends_at) 안의 칸 시작)
-- ---------------------------------------------------------------------
create table if not exists tutor_open_once (
  id uuid primary key default gen_random_uuid(),
  tutor_id uuid not null references tutors(id),
  starts_at timestamptz not null,
  ends_at timestamptz not null,
  created_by uuid,
  created_at timestamptz not null default now(),
  check (ends_at > starts_at)
);
create index if not exists tutor_open_once_tutor on tutor_open_once (tutor_id, starts_at);
do $$
begin
  if not exists (select 1 from pg_trigger where tgname = 'tutor_open_once_audit') then
    perform lms_protect('tutor_open_once'::regclass);
    create policy tutor_own on tutor_open_once for select to authenticated using (tutor_id = my_tutor_id());
  end if;
end $$;

-- ---------------------------------------------------------------------
-- 2. 가능 판정: 매주 가능 시간(4200 그대로) 또는 그날만 연 시간
-- ---------------------------------------------------------------------
create or replace function lms_tutor_weekly_ok(p_tutor uuid, p_start timestamptz) returns boolean
language sql stable security definer set search_path = public as $$
  select lms_tutor_start_ok(p_tutor, p_start)
     and exists (select 1 from tutor_availability a
                 where a.tutor_id = p_tutor
                   and a.effective_from <= (p_start at time zone 'Asia/Seoul')::date
                   and (a.effective_to is null or a.effective_to >= (p_start at time zone 'Asia/Seoul')::date)
                   and extract(dow from (p_start at time zone a.timezone)) = a.weekday
                   and (p_start at time zone a.timezone)::time between a.start_local and a.end_local)
$$;
revoke all on function lms_tutor_weekly_ok(uuid, timestamptz) from public, anon, authenticated;

create or replace function lms_tutor_available(p_tutor uuid, p_start timestamptz) returns boolean
language sql stable security definer set search_path = public as $$
  select lms_tutor_weekly_ok(p_tutor, p_start)
      or (lms_tutor_start_ok(p_tutor, p_start)
          and exists (select 1 from tutor_open_once o where o.tutor_id = p_tutor and o.starts_at <= p_start and p_start < o.ends_at))
$$;
revoke all on function lms_tutor_available(uuid, timestamptz) from public, anon, authenticated;

-- 칸 판정 (3100 과 같고 x 추가): c 수업·보강 · r 보강 신청/대체 요청 답 대기 · l 휴무 · p 6시간 안·지난 시간
--  · s 매주 닫힘 · b 막음 · x 매주 닫혔지만 그날만 엶 · o 열림
create or replace function lms_hours_cell(p_tutor uuid, p_at timestamptz) returns text
language sql stable security definer set search_path = public as $$
  select case
    when exists (select 1 from lessons x where x.tutor_id = p_tutor and x.state <> 'canceled' and x.voided_at is null
                 and x.starts_at < p_at + interval '30 minutes' and p_at < x.ends_at) then 'c'
    when exists (select 1 from makeup_candidates c join makeup_requests r on r.id = c.request_id
                 where r.tutor_id = p_tutor and r.status in ('requested', 'countered') and coalesce(c.tutor_answer, 'yes') = 'yes'
                   and c.starts_at < p_at + interval '30 minutes' and p_at < c.ends_at)
      or exists (select 1 from leave_items i where i.sub_tutor_id = p_tutor and i.sub_stage in ('asked', 'tutor_ok')
                 and i.starts_at < p_at + interval '30 minutes' and p_at < i.ends_at) then 'r'
    when exists (select 1 from tutor_time_off o where o.tutor_id = p_tutor and o.kind = 'leave'
                 and o.starts_at < p_at + interval '30 minutes' and p_at < o.ends_at) then 'l'
    when p_at < now() + interval '6 hours' then 'p'
    when not lms_tutor_available(p_tutor, p_at) then 's'
    when exists (select 1 from tutor_time_off o where o.tutor_id = p_tutor and o.kind = 'block'
                 and o.starts_at < p_at + interval '30 minutes' and p_at < o.ends_at) then 'b'
    when not lms_tutor_weekly_ok(p_tutor, p_at) then 'x'
    else 'o' end
$$;
revoke all on function lms_hours_cell(uuid, timestamptz) from public, anon, authenticated;

-- 시간대 이름 (화면 cityTime 과 같음): 'Toronto Time' · 'Korea Time (KST)'
create or replace function lms_city_time(p_tz text) returns text
language sql immutable as $$
  select case when p_tz = 'Asia/Seoul' then 'Korea Time (KST)' else replace(regexp_replace(p_tz, '^.*/', ''), '_', ' ') || ' Time' end
$$;
revoke all on function lms_city_time(text) from public, anon, authenticated;

-- 예전 One week only 로 막은 줄의 고정 글 → 화면에서는 메모 없음
create or replace function lms_block_note(p_reason text) returns text
language sql immutable as $$
  select nullif(nullif(btrim(coalesce(p_reason, '')), ''), 'Unavailable this week (My hours)')
$$;
revoke all on function lms_block_note(text) from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- 3. 화면 읽기: p_from~p_to (강사 현지 날짜, 최대 50일 — 한 달 표 6주 + 앞뒤 하루). p_cells = 칸 판정도 (Week 보기만, 오늘~12주 안 날짜만)
-- ---------------------------------------------------------------------
create or replace function tutor_schedule(p_tutor uuid, p_from date, p_to date, p_cells boolean default false)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
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
  v_last := v_today + 84;   -- 오늘부터 12주 후까지 (대표 H26(50) ②)
  v_times := array(select lms_hours_times(t.timezone, v_today));
  v_a := p_from::timestamp at time zone t.timezone;
  v_b := (p_to + 1)::timestamp at time zone t.timezone;
  return jsonb_build_object(
    'tutor', jsonb_build_object('id', t.id, 'name', t.name, 'timezone', t.timezone),
    'today', v_today,
    'last', v_last,
    'times', to_jsonb(array(select to_char(x, 'HH24:MI') from unnest(v_times) x)),
    'cells', case when p_cells then coalesce((select jsonb_object_agg(k, c) from (
        select to_char(ld + tm, 'YYYY-MM-DD"T"HH24:MI') k, lms_hours_cell(v_tutor, (ld + tm) at time zone t.timezone) c
        from generate_series(greatest(p_from, v_today), least(p_to, v_last), interval '1 day') g
        cross join lateral (select g::date ld) d cross join unnest(v_times) tm) z
      where c <> 'o'), '{}'::jsonb) end,
    'blocks', coalesce((select jsonb_agg(jsonb_build_object(
        'id', o.id, 'kind', o.kind,
        'start', to_char(o.starts_at at time zone t.timezone, 'YYYY-MM-DD"T"HH24:MI'),
        'end', to_char(o.ends_at at time zone t.timezone, 'YYYY-MM-DD"T"HH24:MI'),
        -- 휴무(leave) 사유는 운영진이 적은 글이라 강사 화면에 안 보냄
        'note', case when o.kind = 'block' then lms_block_note(o.reason) end) order by o.starts_at)
      from tutor_time_off o where o.tutor_id = v_tutor and o.starts_at < v_b and v_a < o.ends_at), '[]'::jsonb),
    'opens', coalesce((select jsonb_agg(jsonb_build_object(
        'start', to_char(o.starts_at at time zone t.timezone, 'YYYY-MM-DD"T"HH24:MI'),
        'end', to_char(o.ends_at at time zone t.timezone, 'YYYY-MM-DD"T"HH24:MI')) order by o.starts_at)
      from tutor_open_once o where o.tutor_id = v_tutor and o.starts_at < v_b and v_a < o.ends_at), '[]'::jsonb));
end $$;
revoke all on function tutor_schedule(uuid, date, date, boolean) from public, anon;
grant execute on function tutor_schedule(uuid, date, date, boolean) to authenticated;

-- ---------------------------------------------------------------------
-- 4. 저장
--  p_action 'block'   p_cells(강사 현지 'YYYY-MM-DDTHH:MI') 막기 + p_note. 그날만 연 칸(x)이면 그 열기를 거둠
--           'open'    p_cells 그날만 열기 (매주 닫힌 칸 s 만)
--           'note'    p_block 메모 고치기 (비우면 메모 없음)
--           'unblock' p_block 막기 풀기 (6시간 안 부분은 그대로 둠)
-- ---------------------------------------------------------------------
create or replace function tutor_schedule_save(p_tutor uuid, p_action text, p_cells text[] default null, p_note text default null, p_block uuid default null)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_tutor uuid := lms_screen_tutor(p_tutor);
  v_tz text;
  v_today date;
  v_last date;
  v_times time[];
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
  v_times := array(select lms_hours_times(v_tz, v_today));
  perform set_config('app.actor_id', coalesce(auth.uid()::text, ''), true);
  perform set_config('app.actor_via', case when is_admin() then 'admin_tutor_schedule' else 'tutor_schedule' end, true);
  if v_note is not null and char_length(v_note) > 100 then raise exception 'Note is too long (100 characters max).'; end if;   -- 대표 H26(50) ③

  if p_action in ('block', 'open') then
    v_keys := array(select distinct x from unnest(coalesce(p_cells, '{}')) x order by 1);
    if cardinality(v_keys) = 0 then raise exception 'Pick a time.'; end if;
    foreach k in array v_keys loop
      if k !~ '^\d{4}-\d\d-\d\dT\d\d:\d\d$' or not (right(k, 5)::time = any (v_times)) then raise exception 'Invalid time: %', k; end if;
      if left(k, 10)::date < v_today or left(k, 10)::date > v_last then raise exception 'You can only change times up to 12 weeks ahead.'; end if;
      v_at := (left(k, 10)::date + right(k, 5)::time) at time zone v_tz;
      v_c := lms_hours_cell(v_tutor, v_at);
      if v_c = 'c' then
        select format('You have a class at %s %s. Classes can''t be blocked.', to_char(x.starts_at at time zone v_tz, 'HH24:MI'), lms_city_time(v_tz)) into k
        from lessons x where x.tutor_id = v_tutor and x.state <> 'canceled' and x.voided_at is null
          and x.starts_at < v_at + interval '30 minutes' and v_at < x.ends_at order by x.starts_at limit 1;
        raise exception '%', k;
      end if;
      if v_c = 'p' then raise exception 'Can''t change: less than 6 hours away.'; end if;
      if v_c = 'r' then raise exception 'A make-up or cover request is waiting for this time. Answer it first.'; end if;
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
                      where (g at time zone v_tz)::time = any (v_times));
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
end $$;
revoke all on function tutor_schedule_save(uuid, text, text[], text, uuid) from public, anon;
grant execute on function tutor_schedule_save(uuid, text, text[], text, uuid) to authenticated;
