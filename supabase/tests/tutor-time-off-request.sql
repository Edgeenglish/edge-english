-- 강사 휴무 신청 시험 (H26(137), 대표 11/13 확정). 가짜 데이터만, 끝에 전부 되돌림(rollback)
begin;
create or replace function pg_temp.ok(c boolean, msg text) returns void language plpgsql as $$
begin if not coalesce(c, false) then raise exception '실패: %', msg; end if; raise notice '통과: %', msg; end $$;
create or replace function pg_temp.fails(sql text, msg text) returns void language plpgsql as $$
begin
  begin execute sql; exception when others then raise notice '통과: %', msg; return; end;
  raise exception '실패(막혀야 함): %', msg;
end $$;

-- Emma(Manila, 한국보다 1시간 늦음) · James(다른 강사)
insert into tutors (id, name, country, timezone, email) values
  ('aaaaaaaa-0000-4000-8000-0000000000c1', 'Emma', 'Philippines', 'Asia/Manila', 'emma2@example.invalid'),
  ('aaaaaaaa-0000-4000-8000-0000000000c2', 'James', 'Philippines', 'Asia/Manila', 'james2@example.invalid');
insert into students (id, name_ko, name_en, timezone, email) values
  ('bbbbbbbb-0000-4000-8000-0000000000c1', '김하준', 'Hajun', 'Asia/Seoul', 'c1@example.invalid');
insert into enrollments (id, student_id, seq, contract_version, weeks, weekly_count, duration_min, start_date, base_end_date, lessons_purchased, status) values
  ('cccccccc-0000-4000-8000-0000000000c1', 'bbbbbbbb-0000-4000-8000-0000000000c1', 1, 'SC2', 12, 3, 40, current_date - 7, current_date + 76, 36, 'active');
-- 날짜 기준: Manila 오늘 + 20일 = D. 휴무 신청 D ~ D+2 (현지)
create temp table d as select ((now() at time zone 'Asia/Manila')::date + 20) as d;
grant select on d to authenticated;
create temp table rq (name text, id uuid);
grant all on rq to authenticated;
-- 수업: ① D 00:30 Manila (= 한국 D 01:30) 안 ② D+2 23:30 Manila (= 한국 D+3 00:30) 안 ③ D-1 23:30 Manila (= 한국 D 00:30) 밖 ④ D+3 00:30 Manila 밖
insert into lessons (id, enrollment_id, student_id, tutor_id, kind, seq, starts_at, ends_at, state)
select x.id::uuid, 'cccccccc-0000-4000-8000-0000000000c1', 'bbbbbbbb-0000-4000-8000-0000000000c1', 'aaaaaaaa-0000-4000-8000-0000000000c1', 'regular', x.seq,
       ((d.d + x.off)::timestamp + x.t) at time zone 'Asia/Manila', ((d.d + x.off)::timestamp + x.t + interval '40 minutes') at time zone 'Asia/Manila', 'scheduled'
from d, (values ('dddddddd-0000-4000-8000-0000000000c1', 1, 0, interval '30 minutes'),
                ('dddddddd-0000-4000-8000-0000000000c2', 2, 2, interval '23 hours 30 minutes'),
                ('dddddddd-0000-4000-8000-0000000000c3', 3, -1, interval '23 hours 10 minutes'),
                ('dddddddd-0000-4000-8000-0000000000c4', 4, 3, interval '30 minutes')) x(id, seq, off, t);
insert into app_users (auth_user_id, role, tutor_id) values
  ('eeeeeeee-0000-4000-8000-0000000000c1', 'tutor', 'aaaaaaaa-0000-4000-8000-0000000000c1'),
  ('eeeeeeee-0000-4000-8000-0000000000c2', 'tutor', 'aaaaaaaa-0000-4000-8000-0000000000c2');
insert into app_users (auth_user_id, role, admin_level) values ('eeeeeeee-0000-4000-8000-0000000000c9', 'admin', 'owner');

-- ── 강사 Emma ──
select set_config('request.jwt.claims', '{"sub":"eeeeeeee-0000-4000-8000-0000000000c1","aal":"aal1"}', true);
set local role authenticated;
select pg_temp.ok((tutor_time_off_preview(null, (select d from d), (select d + 2 from d)) -> 'classes') @> '[]'::jsonb
  and jsonb_array_length(tutor_time_off_preview(null, (select d from d), (select d + 2 from d)) -> 'classes') = 2, '미리 보기: 현지 3일 안 수업 2개만 (경계 밖 2개 제외)');
select pg_temp.fails($$select tutor_time_off_request(null, (select d from d), (select d + 1 from d), 'planned', 'trip')$$, '2일 휴무는 못 신청 (3일 이상만)');
select pg_temp.fails($$select tutor_time_off_request(null, (select d from d), (select d + 2 from d), 'planned', '  ')$$, '사유 없으면 못 신청');
select pg_temp.fails($$select tutor_time_off_request(null, (select d - 21 from d), (select d - 18 from d), 'urgent', 'sick')$$, '지난 날짜는 못 신청');
select pg_temp.fails($$select tutor_time_off_request('aaaaaaaa-0000-4000-8000-0000000000c2', (select d from d), (select d + 2 from d), 'planned', 'x')$$, '다른 강사 대신 신청 못 함');
insert into rq select 'wed', tutor_time_off_request(null, (select d from d), (select d + 2 from d), 'planned', 'Family wedding');
select pg_temp.fails($$select tutor_time_off_request(null, (select d + 1 from d), (select d + 4 from d), 'planned', 'again')$$, '대기 중 신청과 겹치면 못 신청');
-- 늦은 계획 휴무(5일 뒤) → late, 급한 일은 late 아님
insert into rq select 'late', tutor_time_off_request(null, (select d - 15 from d), (select d - 13 from d), 'planned', 'Late trip');
insert into rq select 'urg', tutor_time_off_request(null, (select d + 10 from d), (select d + 12 from d), 'urgent', 'Surgery');
select pg_temp.ok(jsonb_array_length(tutor_time_off_list(null) -> 'rows') = 3, 'Home 목록에 신청 3건');
-- 철회 (두 번 눌러도 같음)
select tutor_time_off_withdraw(null, (select id from rq where name = 'urg'));
select tutor_time_off_withdraw(null, (select id from rq where name = 'urg'));
select pg_temp.ok(jsonb_array_length(tutor_time_off_list(null) -> 'rows') = 2, '철회한 신청은 목록에서 빠짐');
select pg_temp.fails($$select * from admin_time_off_requests()$$, '강사는 운영진 목록 못 봄');
select pg_temp.fails($$select * from tutor_time_off_requests$$, '표를 직접 못 읽음');
reset role;
select pg_temp.ok((select not late from tutor_time_off_requests where reason = 'Family wedding'), '20일 전 계획된 휴무 = 기한 안');
select pg_temp.ok((select late from tutor_time_off_requests where reason = 'Late trip') and not (select late from tutor_time_off_requests where reason = 'Surgery'), '14일 안 계획 휴무 = 기한 지남 · 급한 일은 기한 없음');

-- ── 다른 강사 James: Emma 신청 철회 못 함 ──
select set_config('request.jwt.claims', '{"sub":"eeeeeeee-0000-4000-8000-0000000000c2","aal":"aal1"}', true);
set local role authenticated;
select pg_temp.fails($$select tutor_time_off_withdraw(null, (select id from rq where name = 'late'))$$, '다른 강사 신청은 철회 못 함');
reset role;

-- ── 운영진 ──
select set_config('request.jwt.claims', '{"sub":"eeeeeeee-0000-4000-8000-0000000000c9","aal":"aal2"}', true);
set local role authenticated;
select pg_temp.ok((select count(*) from admin_time_off_requests()) = 2, '대시보드 대기 신청 2건');
select pg_temp.ok((select kst_from = first_day and kst_to = last_day + 1 from admin_time_off_requests() where reason = 'Family wedding'), '휴무 화면 한국 날짜 = 현지 첫날 ~ 마지막 날 다음 날 (Manila 23:30 = 한국 다음 날)');
select pg_temp.fails($$select admin_time_off_reject((select id from admin_time_off_requests() where reason = 'Late trip'), ' ')$$, '반려 사유 없으면 못 반려');
select admin_time_off_reject((select id from admin_time_off_requests() where reason = 'Late trip'), 'Two students finish that week.');
-- 휴무 화면에서 신청 그대로 저장 → 실제 시각으로 수업 2개만, 신청 승인
select pg_temp.ok((admin_leave_create('aaaaaaaa-0000-4000-8000-0000000000c1', r.kst_from, r.kst_to, r.reason, true, r.id) ->> 'lessons')::int = 2, '미리 보기(신청 시각) = 수업 2개')
from admin_time_off_requests() r where r.reason = 'Family wedding';
select pg_temp.ok((admin_leave_create('aaaaaaaa-0000-4000-8000-0000000000c1', r.kst_from, r.kst_to, null, true) ->> 'lessons')::int = 4, '같은 한국 날짜로 그냥 넣으면 경계 밖 수업 2개까지 4개 (그래서 신청 시각을 씀)')
from admin_time_off_requests() r where r.reason = 'Family wedding';
select admin_leave_create('aaaaaaaa-0000-4000-8000-0000000000c1', r.kst_from, r.kst_to, r.reason, false, r.id) from admin_time_off_requests() r where r.reason = 'Family wedding';
select pg_temp.ok((select count(*) from admin_time_off_requests()) = 0, '처리 끝나면 대시보드에서 빠짐');
select pg_temp.fails($$select admin_leave_create('aaaaaaaa-0000-4000-8000-0000000000c1', current_date + 40, current_date + 42, null, false, (select id from rq where name = 'wed'))$$, '이미 승인된 신청으로 다시 저장 못 함');
reset role;
select pg_temp.ok((select status = 'approved' and time_off_id is not null from tutor_time_off_requests where reason = 'Family wedding'), '저장하면 신청 자동 승인');
select pg_temp.ok((select count(*) from leave_items i join tutor_time_off_requests r on r.time_off_id = i.time_off_id where r.reason = 'Family wedding') = 2
  and not exists (select 1 from leave_items where lesson_id in ('dddddddd-0000-4000-8000-0000000000c3', 'dddddddd-0000-4000-8000-0000000000c4')), '휴무 줄 = 경계 안 수업 2개만');

-- ── Emma 화면: 승인·반려 표시, 올해 기록 ──
select set_config('request.jwt.claims', '{"sub":"eeeeeeee-0000-4000-8000-0000000000c1","aal":"aal1"}', true);
set local role authenticated;
select pg_temp.ok((select count(*) from jsonb_array_elements(tutor_time_off_list(null) -> 'rows') x where x ->> 'status' = 'approved') = 1
  and (select x ->> 'reject_reason' from jsonb_array_elements(tutor_time_off_list(null) -> 'rows') x where x ->> 'status' = 'rejected') = 'Two students finish that week.', 'Home: 승인 1 · 반려 사유 보임');
select pg_temp.ok(jsonb_array_length(tutor_time_off_list(null) -> 'year') >= 1, '올해 기록에 승인된 휴무');
select pg_temp.fails($$select tutor_time_off_withdraw(null, (select id from rq where name = 'wed'))$$, '승인된 신청은 철회 못 함');
reset role;
rollback;
