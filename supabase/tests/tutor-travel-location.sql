-- 강사 해외 이동 기간 시험 (H26(173), 시안 8차). 가짜 데이터만, 끝에 전부 되돌림(rollback)
begin;
create or replace function pg_temp.ok(c boolean, msg text) returns void language plpgsql as $$
begin if not coalesce(c, false) then raise exception '실패: %', msg; end if; raise notice '통과: %', msg; end $$;
create or replace function pg_temp.fails(sql text, msg text) returns void language plpgsql as $$
begin
  begin execute sql; exception when others then raise notice '통과: % (%)', msg, sqlerrm; return; end;
  raise exception '실패(막혀야 함): %', msg;
end $$;

-- Ben(평소 Sydney) · Olivia(다른 강사). 날짜 D = Buenos Aires 오늘 + 20일 (이동 기간 D ~ D+30)
insert into tutors (id, name, country, timezone, email) values
  ('aaaaaaaa-0000-4000-8000-0000000000f1', 'Ben', 'Australia', 'Australia/Sydney', 'ben@example.invalid'),
  ('aaaaaaaa-0000-4000-8000-0000000000f2', 'Olivia', 'Australia', 'Australia/Sydney', 'olivia@example.invalid');
insert into students (id, name_ko, name_en, timezone, email) values
  ('bbbbbbbb-0000-4000-8000-0000000000f1', '박서연', 'Seoyeon', 'Asia/Seoul', 'f1@example.invalid');
insert into enrollments (id, student_id, seq, contract_version, weeks, weekly_count, duration_min, start_date, base_end_date, lessons_purchased, status) values
  ('cccccccc-0000-4000-8000-0000000000f1', 'bbbbbbbb-0000-4000-8000-0000000000f1', 1, 'SC2', 12, 3, 40, current_date - 7, current_date + 76, 36, 'active');
create temp table d as select ((now() at time zone 'America/Argentina/Buenos_Aires')::date + 20) as d;
grant select on d to authenticated;
create temp table v (k text primary key, u uuid);
grant all on v to authenticated;
-- Regular: 매일 Sydney 09:00~17:30 시작 가능
insert into tutor_availability (tutor_id, weekday, start_local, end_local, timezone, effective_from)
select 'aaaaaaaa-0000-4000-8000-0000000000f1', w, '09:00', '17:30', 'Australia/Sydney', current_date - 30 from generate_series(0, 6) w;
-- 이동 기간 중 수업 하나: BA D+3 09:00 (40분)
insert into lessons (id, enrollment_id, student_id, tutor_id, kind, seq, starts_at, ends_at, state)
select 'dddddddd-0000-4000-8000-0000000000f1', 'cccccccc-0000-4000-8000-0000000000f1', 'bbbbbbbb-0000-4000-8000-0000000000f1', 'aaaaaaaa-0000-4000-8000-0000000000f1', 'regular', 1,
       ((d + 3) + time '09:00') at time zone 'America/Argentina/Buenos_Aires', ((d + 3) + time '09:40') at time zone 'America/Argentina/Buenos_Aires', 'scheduled' from d;
insert into app_users (auth_user_id, role, tutor_id) values
  ('eeeeeeee-0000-4000-8000-0000000000f1', 'tutor', 'aaaaaaaa-0000-4000-8000-0000000000f1'),
  ('eeeeeeee-0000-4000-8000-0000000000f2', 'tutor', 'aaaaaaaa-0000-4000-8000-0000000000f2');
insert into app_users (auth_user_id, role, admin_level) values ('eeeeeeee-0000-4000-8000-0000000000f9', 'admin', 'owner');

-- 이동 전: BA D+2 16:00 = Sydney 다음 날 새벽 → Regular 로는 닫힘 / Sydney 10:00 은 열림
select pg_temp.ok(not lms_tutor_available('aaaaaaaa-0000-4000-8000-0000000000f1', ((select d + 2 from d) + time '16:00') at time zone 'America/Argentina/Buenos_Aires'), '이동 등록 전: BA 오후 4시(= Sydney 새벽)는 닫힘');

-- ── 강사 Ben ──
select set_config('request.jwt.claims', '{"sub":"eeeeeeee-0000-4000-8000-0000000000f1","aal":"aal1"}', true);
set local role authenticated;
select pg_temp.fails($$select tutor_location_save(null, null, 'Buenos Aires', 'Argentina', 'America/Argentina/Buenos_Aires', (select d - 30 from d), null)$$, '지난 날짜로 시작 못 함');
select pg_temp.fails($$select tutor_location_save(null, null, 'Buenos Aires', 'Argentina', 'America/Argentina/Buenos_Aires', (select d from d), (select d - 1 from d))$$, '종료일이 시작일보다 앞이면 못 함');
select pg_temp.fails($$select tutor_location_save(null, null, 'Buenos Aires', 'Argentina', 'Mars/Base', (select d from d), null)$$, '없는 시간대는 못 함');
select pg_temp.fails($$select tutor_location_save(null, null, '  ', 'Argentina', 'America/Argentina/Buenos_Aires', (select d from d), null)$$, '도시 없으면 못 함');
insert into v select 'loc', (tutor_location_save(null, null, 'Buenos Aires', 'Argentina', 'America/Argentina/Buenos_Aires', (select d from d), null) ->> 'id')::uuid;
select pg_temp.ok((select u from v where k = 'loc') is not null, '이동 기간 추가 (종료일 없음)');
select pg_temp.fails($$select tutor_location_save(null, null, 'New York', 'United States', 'America/New_York', (select d + 40 from d), (select d + 50 from d))$$, '종료일 없는 기간 뒤에 겹치게 못 넣음');
select pg_temp.fails($$select tutor_location_save('aaaaaaaa-0000-4000-8000-0000000000f2', null, 'Buenos Aires', 'Argentina', 'America/Argentina/Buenos_Aires', (select d from d), null)$$, '다른 강사 것은 못 넣음');
select pg_temp.ok(jsonb_array_length(tutor_hours(null) -> 'locations') = 1
  and (tutor_hours(null) -> 'locations' -> 0 ->> 'to') is null
  and jsonb_array_length(tutor_hours(null) -> 'locations' -> 0 -> 'weekly_open') = 0, 'Regular Working Hours 자료에 이동 기간 탭 1개, 시간 없음');
reset role;

-- 이동 기간에 시간이 하나도 없으면 Regular 도 적용 안 됨 (Sydney 10:00 = BA 전날 20:00 또는 21:00 → 이동 기간 날짜)
select pg_temp.ok(lms_tutor_tz_on('aaaaaaaa-0000-4000-8000-0000000000f1', (select d + 1 from d)) = 'America/Argentina/Buenos_Aires'
  and lms_tutor_tz_on('aaaaaaaa-0000-4000-8000-0000000000f1', (select d - 1 from d)) = 'Australia/Sydney', '날짜별 시간대: 이동 첫날부터 BA, 그 전 Sydney');
select pg_temp.ok(not lms_tutor_available('aaaaaaaa-0000-4000-8000-0000000000f1', ((select d + 5 from d) + time '10:00') at time zone 'Australia/Sydney'), '이동 중에는 Regular(Sydney 10:00) 시간이 열리지 않음');

set local role authenticated;
select pg_temp.fails($$select tutor_location_hours_save(null, (select u from v where k = 'loc'), array['1:23:00'])$$, '현지 23:00 시작은 못 엶 (06:00~22:30)');
select tutor_location_hours_save(null, (select u from v where k = 'loc'),
  array(select w || ':' || t from generate_series(0, 6) w, unnest(array['16:00','16:30','17:00','17:30','18:00','18:30','19:00','19:30','20:00','20:30','21:00','21:30']) t));
select pg_temp.ok(jsonb_array_length(tutor_hours(null) -> 'locations' -> 0 -> 'weekly_open') = 84, '이동 기간 매주 시간 저장 (7일 × 12칸)');
reset role;
select pg_temp.ok(lms_tutor_available('aaaaaaaa-0000-4000-8000-0000000000f1', ((select d + 2 from d) + time '16:00') at time zone 'America/Argentina/Buenos_Aires'), '이동 중: BA 오후 4시 열림');
select pg_temp.ok(not lms_tutor_available('aaaaaaaa-0000-4000-8000-0000000000f1', ((select d + 2 from d) + time '22:00') at time zone 'America/Argentina/Buenos_Aires'), '이동 중: BA 오후 10시(그 기간 시간표 밖) 닫힘');
select pg_temp.ok(lms_tutor_available('aaaaaaaa-0000-4000-8000-0000000000f1', ((select d - 2 from d) + time '10:00') at time zone 'Australia/Sydney'), '이동 전 날짜: Regular Sydney 10:00 그대로 열림');
select pg_temp.ok((select count(*) from tutor_availability where location_id = (select u from v where k = 'loc')) = 7, '이동 기간 줄 = 요일마다 이어진 한 줄');

-- Regular 를 고쳐도 이동 기간 줄은 그대로
set local role authenticated;
select tutor_hours_save(null, array(select w || ':' || t from generate_series(0, 6) w, unnest(array['09:00','09:30','10:00']) t), '{}', '{}');
reset role;
select pg_temp.ok((select count(*) from tutor_availability where location_id = (select u from v where k = 'loc')) = 7, 'Regular 저장해도 이동 기간 줄 안 지워짐');

-- Calendar 칸: Sydney 키지만 BA 시각으로 판정 — BA 23:00 시작 = 'n', BA 16:00 = 열림(빠짐)
set local role authenticated;
select pg_temp.ok((tutor_schedule(null, (select d + 5 from d), (select d + 6 from d), true) -> 'cells' ->>
    to_char(((select d + 5 from d) + time '23:00') at time zone 'America/Argentina/Buenos_Aires' at time zone 'Australia/Sydney', 'YYYY-MM-DD"T"HH24:MI')) = 'n'
  and (tutor_schedule(null, (select d + 5 from d), (select d + 6 from d), true) -> 'cells' ->>
    to_char(((select d + 5 from d) + time '16:00') at time zone 'America/Argentina/Buenos_Aires' at time zone 'Australia/Sydney', 'YYYY-MM-DD"T"HH24:MI')) is null
  and jsonb_array_length(tutor_schedule(null, (select d from d), (select d + 1 from d), false) -> 'locations') = 1, 'Calendar 칸: BA 오후 11시 시작 못 함(n) · BA 오후 4시 열림 · 이동 기간 목록');
-- Calendar 하루 열기: BA 09:00 (Sydney 키) 열기 → 열림
select tutor_schedule_save(null, 'open', array[to_char(((select d + 6 from d) + time '09:00') at time zone 'America/Argentina/Buenos_Aires' at time zone 'Australia/Sydney', 'YYYY-MM-DD"T"HH24:MI')], null, null);
reset role;
select pg_temp.ok(lms_tutor_available('aaaaaaaa-0000-4000-8000-0000000000f1', ((select d + 6 from d) + time '09:00') at time zone 'America/Argentina/Buenos_Aires'), 'Calendar 하루 열기: BA 오전 9시(= Sydney 밤 11시 키) 열림');

-- Set Multiple Days
set local role authenticated;
select pg_temp.fails($$select tutor_schedule_multi(null, (select d - 1 from d), (select d + 1 from d), '09:00', '10:00', false)$$, '두 지역에 걸친 날짜는 한 번에 못 함');
select pg_temp.fails($$select tutor_schedule_multi(null, (select d + 2 from d), (select d + 4 from d), '23:00', '23:30', false)$$, '현지 23:00 시작 못 함');
select pg_temp.ok((select (r ->> 'ok')::int = 2 and r -> 'days' -> 1 ->> 'why' = 'c' and r -> 'days' -> 1 ->> 'class' = '09:00'
                     and r ->> 'timezone' = 'America/Argentina/Buenos_Aires'
                   from (select tutor_schedule_multi(null, (select d + 2 from d), (select d + 4 from d), '09:00', '10:30', false) r) x),
  '미리 보기: 3일 중 2일 가능, 수업 있는 날 빼고 이유(수업 09:00)');
reset role;
select pg_temp.ok(not lms_tutor_available('aaaaaaaa-0000-4000-8000-0000000000f1', ((select d + 2 from d) + time '09:00') at time zone 'America/Argentina/Buenos_Aires'), '미리 보기는 저장 안 함');
set local role authenticated;
select pg_temp.ok((tutor_schedule_multi(null, (select d + 2 from d), (select d + 4 from d), '09:00', '10:30', true) ->> 'ok')::int = 2, '적용: 2일');
reset role;
select pg_temp.ok(lms_tutor_available('aaaaaaaa-0000-4000-8000-0000000000f1', ((select d + 2 from d) + time '09:00') at time zone 'America/Argentina/Buenos_Aires')
  and lms_tutor_available('aaaaaaaa-0000-4000-8000-0000000000f1', ((select d + 4 from d) + time '10:00') at time zone 'America/Argentina/Buenos_Aires')
  and not lms_tutor_available('aaaaaaaa-0000-4000-8000-0000000000f1', ((select d + 4 from d) + time '10:30') at time zone 'America/Argentina/Buenos_Aires'), '적용 뒤 BA 9:00~10:00 시작 열림, 10:30 은 닫힘');
set local role authenticated;
select pg_temp.ok((select r -> 'days' -> 0 ->> 'why' = 'open' from (select tutor_schedule_multi(null, (select d + 2 from d), (select d + 2 from d), '09:00', '10:30', false) r) x), '이미 열린 날은 이유 open');
select pg_temp.ok((select r -> 'days' -> 0 ->> 'why' = 'far' from (select tutor_schedule_multi(null, (select d + 80 from d), (select d + 80 from d), '09:00', '10:00', false) r) x), '12주 넘는 날은 이유 far');

-- Set end date
select pg_temp.fails($$select tutor_location_save(null, (select u from v where k = 'loc'), null, null, null, null, (select d - 1 from d))$$, '종료일이 시작일보다 앞이면 못 함');
select pg_temp.ok((tutor_location_save(null, (select u from v where k = 'loc'), null, null, null, null, (select d + 30 from d)) ->> 'to')::date = (select d + 30 from d), '종료일 넣기');
reset role;
select pg_temp.ok(lms_tutor_available('aaaaaaaa-0000-4000-8000-0000000000f1', ((select d + 33 from d) + time '09:30') at time zone 'Australia/Sydney')
  and not lms_tutor_available('aaaaaaaa-0000-4000-8000-0000000000f1', ((select d + 33 from d) + time '16:00') at time zone 'America/Argentina/Buenos_Aires'), '종료일 다음부터 Regular 자동 복귀');
select pg_temp.ok((select count(*) from tutor_hours_changes where tutor_id = 'aaaaaaaa-0000-4000-8000-0000000000f1' and changes ? 'location' and not by_admin) = 3, '이력: 추가·시간·종료일 3건 (강사 본인)');

-- ── 다른 강사 Olivia: Ben 의 기간 못 건드림 ──
select set_config('request.jwt.claims', '{"sub":"eeeeeeee-0000-4000-8000-0000000000f2","aal":"aal1"}', true);
set local role authenticated;
select pg_temp.fails($$select tutor_location_hours_save(null, (select u from v where k = 'loc'), array['1:16:00'])$$, '다른 강사의 이동 기간 시간 못 바꿈');
select pg_temp.fails($$select tutor_location_save(null, (select u from v where k = 'loc'), null, null, null, null, (select d + 10 from d))$$, '다른 강사의 종료일 못 바꿈');
reset role;

-- ── 운영자 대신 ──
select set_config('request.jwt.claims', '{"sub":"eeeeeeee-0000-4000-8000-0000000000f9","aal":"aal2"}', true);
set local role authenticated;
select tutor_location_save('aaaaaaaa-0000-4000-8000-0000000000f1', null, 'New York', 'United States', 'America/New_York', (select d + 40 from d), (select d + 60 from d));
reset role;
select pg_temp.ok((select by_admin from tutor_hours_changes where tutor_id = 'aaaaaaaa-0000-4000-8000-0000000000f1' and changes -> 'location' ->> 'city' = 'New York'), '운영자 대신 추가 → 이력 운영자');
select pg_temp.ok(lms_tutor_tz_on('aaaaaaaa-0000-4000-8000-0000000000f1', (select d + 45 from d)) = 'America/New_York', '두 번째 이동 기간 시간대');
rollback;
