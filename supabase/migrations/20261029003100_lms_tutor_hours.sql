-- =====================================================================
-- 강사 본인 가능 시간 고치기 [My hours] (2026-10-29 대표 확정, 정책 원본 H26(37), 시안 docs/lms/previews/tutor-hours-drafts.html)
--  - Every week: tutor_availability (30분 칸 = 그 시각 수업 시작 가능, 강사 현지 시각). 바꾸면 **다음 주 월요일(한국 날짜)부터**
--    → 그날 이후에도 살아 있는 기존 줄은 effective_to = 그 전날로 끝내고(이미 그날부터 시작하는 줄은 지움) 새 줄을 넣음. 지난 기록은 남음
--    → 고정 수업(앞으로 남은 정규 수업)이 있는 칸은 닫을 수 없음 (운영진에게 요청)
--  - One week only: tutor_time_off kind 'block' (붙은 칸은 한 줄로 합침, 다시 열면 그 칸만 잘라 냄). 이번 주 포함 4주(강사 현지 월~일)
--    → 빈 시간만, 수업 시작 6시간 전까지. 수업·보강·보강 신청 중(강사 불가 답 제외)·대체 요청 중인 시간, 휴무('leave')는 잠김
--  - 칸: 강사 현지 22:00 시작까지 + 한국 06:00~22:30 시작 (POL-OP-02)
--  - 화면 잠금만 믿지 않고 저장 함수가 같은 판정(lms_hours_cell)으로 다시 검사. 강사 본인, 또는 운영자(TOTP)가 ?tutor= 로 같은 함수
--  - 저장 즉시 반영 + 바뀐 기록(tutor_hours_changes) → 운영자 보기 화면에 표시
-- 기존 표·데이터를 지우지 않음 (tutor_availability 는 아직 시작 안 한 줄만 지울 수 있음, audit_log 에 남음). 다시 실행해도 같은 결과
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. 한 칸짜리 줄 허용: 시작 기준이라 시작 = 끝이면 그 시각 하나만 가능
-- ---------------------------------------------------------------------
alter table tutor_availability drop constraint if exists tutor_availability_check;
do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'tutor_availability_start_le_end') then
    alter table tutor_availability add constraint tutor_availability_start_le_end check (end_local >= start_local);
  end if;
end $$;

-- ---------------------------------------------------------------------
-- 2. 바뀐 기록 (지우기·고치기 금지)
--    changes = {from, weekly_open[], weekly_close[] ('요일(0=일):HH:MI'), once_close[], once_open[] ('YYYY-MM-DDTHH:MI' 강사 현지)}
-- ---------------------------------------------------------------------
create table if not exists tutor_hours_changes (
  id uuid primary key default gen_random_uuid(),
  tutor_id uuid not null references tutors(id),
  at timestamptz not null default now(),
  actor uuid,
  by_admin boolean not null,
  changes jsonb not null
);
create index if not exists tutor_hours_changes_tutor on tutor_hours_changes (tutor_id, at);
do $$
begin
  if not exists (select 1 from pg_trigger where tgname = 'tutor_hours_changes_audit') then
    perform lms_protect('tutor_hours_changes'::regclass);
    create trigger tutor_hours_changes_no_update before update on tutor_hours_changes for each row execute function forbid_update();
    create trigger tutor_hours_changes_no_delete before delete on tutor_hours_changes for each row execute function forbid_delete();
    create policy tutor_own on tutor_hours_changes for select to authenticated using (tutor_id = my_tutor_id());
  end if;
end $$;

-- ---------------------------------------------------------------------
-- 3. 날짜·칸
-- ---------------------------------------------------------------------
-- 매주 변경이 시작되는 날: 다음 주 월요일 (한국 날짜)
create or replace function lms_next_monday() returns date
language sql stable as $$
  select d + (8 - extract(isodow from d)::int) from (select (now() at time zone 'Asia/Seoul')::date as d) x
$$;

-- 강사 현지 이번 주 월요일
create or replace function lms_local_monday(p_tz text) returns date
language sql stable as $$
  select d - (extract(isodow from d)::int - 1) from (select (now() at time zone p_tz)::date as d) x
$$;

-- 그 주 칸 시각 (강사 현지 30분): 현지 22:00 시작까지 + 한국 06:00~22:30 시작 (POL-OP-02)
create or replace function lms_hours_times(p_tz text, p_monday date) returns setof time
language sql stable as $$
  select distinct g::time from generate_series(0, 6) d
  cross join generate_series(timestamp '2000-01-01 00:00', timestamp '2000-01-01 22:00', interval '30 minutes') g
  where ((((p_monday + d) + g::time) at time zone p_tz) at time zone 'Asia/Seoul')::time between time '06:00' and time '22:30'
  order by 1
$$;
revoke all on function lms_next_monday() from public, anon, authenticated;
revoke all on function lms_local_monday(text) from public, anon, authenticated;
revoke all on function lms_hours_times(text, date) from public, anon, authenticated;

-- 매주 가능 시간: p_from 에 살아 있는 줄 기준으로 그 주(현지 날짜 p_from~+6)의 열린 칸 '요일:HH:MI'.
-- 줄이 한 번도 없는 강사는 지금 판정(lms_tutor_available)처럼 모든 칸이 열림
create or replace function lms_weekly_open(p_tutor uuid, p_tz text, p_from date, p_times time[]) returns setof text
language sql stable security definer set search_path = public as $$
  select extract(dow from ld)::int || ':' || to_char(tm, 'HH24:MI')
  from generate_series(p_from, p_from + 6, interval '1 day') g(ld0)
  cross join lateral (select g.ld0::date as ld) d
  cross join unnest(p_times) tm
  where not exists (select 1 from tutor_availability a where a.tutor_id = p_tutor)
     or exists (select 1 from tutor_availability a
                where a.tutor_id = p_tutor
                  and a.effective_from <= p_from and (a.effective_to is null or a.effective_to >= p_from)
                  and extract(dow from (((ld + tm) at time zone p_tz) at time zone a.timezone)) = a.weekday
                  and ((((ld + tm) at time zone p_tz) at time zone a.timezone))::time between a.start_local and a.end_local)
$$;
revoke all on function lms_weekly_open(uuid, text, date, time[]) from public, anon, authenticated;

-- 고정 수업: p_from(한국 날짜 0시) 이후 남은 정규 수업의 현지 요일·시각·길이 (같은 것은 하나로)
create or replace function lms_weekly_classes(p_tutor uuid, p_tz text, p_from date)
returns table (d int, start_local time, minutes int, student text)
language sql stable security definer set search_path = public as $$
  select distinct extract(dow from l.starts_at at time zone p_tz)::int, (l.starts_at at time zone p_tz)::time,
         (extract(epoch from l.ends_at - l.starts_at) / 60)::int, coalesce(s.display_name, s.name_en)
  from lessons l join students s on s.id = l.student_id
  where l.tutor_id = p_tutor and l.kind = 'regular' and l.state = 'scheduled' and l.voided_at is null
    and l.starts_at >= (p_from::timestamp at time zone 'Asia/Seoul')
$$;
revoke all on function lms_weekly_classes(uuid, text, date) from public, anon, authenticated;

-- 그 주만 칸 판정 (30분 [p_at, p_at+30분)):
--  c 수업·보강 · r 보강 신청 중/대체 요청 중 · l 휴무 · p 6시간 안·지난 시간 · s 매주 닫힌 시간 · b 그 주만 닫음 · o 열림
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
    else 'o' end
$$;
revoke all on function lms_hours_cell(uuid, timestamptz) from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- 4. 화면 읽기
-- ---------------------------------------------------------------------
create or replace function tutor_hours(p_tutor uuid)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_tutor uuid := lms_screen_tutor(p_tutor);
  t tutors;
  v_from date := lms_next_monday();
  v_mon date;
  v_times time[];
begin
  select * into t from tutors where id = v_tutor;
  v_mon := lms_local_monday(t.timezone);
  v_times := array(select lms_hours_times(t.timezone, v_mon));
  return jsonb_build_object(
    'tutor', jsonb_build_object('id', t.id, 'name', t.name, 'timezone', t.timezone),
    'from', v_from,
    'monday', v_mon,
    'times', to_jsonb(array(select to_char(x, 'HH24:MI') from unnest(v_times) x)),
    'weekly_open', to_jsonb(array(select lms_weekly_open(v_tutor, t.timezone, v_from, v_times))),
    'weekly_classes', coalesce((select jsonb_agg(jsonb_build_object('d', w.d, 'time', to_char(w.start_local, 'HH24:MI'), 'min', w.minutes, 'student', w.student))
                                from lms_weekly_classes(v_tutor, t.timezone, v_from) w), '[]'::jsonb),
    -- 그 주만 4주: 열림(o)이 아닌 칸만
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
    -- 바뀐 기록: 운영자 보기에서만
    'history', case when is_admin() then coalesce((select jsonb_agg(jsonb_build_object('at', h.at, 'by_admin', h.by_admin, 'changes', h.changes) order by h.at desc)
                                                    from tutor_hours_changes h where h.tutor_id = v_tutor), '[]'::jsonb) end);
end $$;
revoke all on function tutor_hours(uuid) from public, anon;
grant execute on function tutor_hours(uuid) to authenticated;

-- ---------------------------------------------------------------------
-- 5. 저장: p_weekly = 바꾼 뒤 매주 열린 칸 전체 (안 바꾸면 null), p_close·p_open = 그 주만 닫을·다시 열 칸
-- ---------------------------------------------------------------------
create or replace function tutor_hours_save(p_tutor uuid, p_weekly text[], p_close text[], p_open text[])
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_tutor uuid := lms_screen_tutor(p_tutor);
  v_tz text;
  v_from date := lms_next_monday();
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
  v_times := array(select lms_hours_times(v_tz, v_mon));
  perform set_config('app.actor_id', coalesce(auth.uid()::text, ''), true);
  perform set_config('app.actor_via', case when is_admin() then 'admin_tutor_hours' else 'tutor_hours' end, true);

  -- 매주
  if p_weekly is not null then
    foreach k in array p_weekly loop
      if k !~ '^[0-6]:\d\d:\d\d$' or not (substr(k, 3)::time = any (v_times)) then raise exception 'Invalid time: %', k; end if;
    end loop;
    v_old := array(select lms_weekly_open(v_tutor, v_tz, v_from, v_times));
    v_new := array(select distinct x from unnest(p_weekly) x);
    v_add := array(select x from unnest(v_new) x where not (x = any (v_old)) order by 1);
    v_del := array(select x from unnest(v_old) x where not (x = any (v_new)) order by 1);
    -- 고정 수업이 걸친 칸은 닫을 수 없음
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
      delete from tutor_availability where tutor_id = v_tutor and effective_from >= v_from;
      update tutor_availability set effective_to = v_from - 1
      where tutor_id = v_tutor and effective_from < v_from and (effective_to is null or effective_to >= v_from);
      -- 이어진 칸 = 한 줄 (시작 = 처음 칸, 끝 = 마지막 칸 시각)
      insert into tutor_availability (tutor_id, weekday, start_local, end_local, timezone, effective_from)
      select v_tutor, d, min(tm), max(tm), v_tz, v_from
      from (select d, tm, (extract(epoch from tm)::int / 1800) - row_number() over (partition by d order by tm) grp
            from (select split_part(x, ':', 1)::int d, substr(x, 3)::time tm from unnest(v_new) x) a) b
      group by d, grp;
    end if;
  end if;

  -- 그 주만: 다시 열기 먼저, 그다음 닫기
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
    -- 붙어 있는 그 주만 닫은 줄과 합쳐 한 줄로
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
end $$;
revoke all on function tutor_hours_save(uuid, text[], text[], text[]) from public, anon;
grant execute on function tutor_hours_save(uuid, text[], text[], text[]) to authenticated;
