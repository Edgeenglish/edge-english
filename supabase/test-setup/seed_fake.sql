-- =====================================================================
-- 시험용 Supabase 전용 가상 데이터 (실제 학생·강사 정보 아님)
-- 이름은 모두 '가상'으로 시작. 실제 운영 프로젝트에는 절대 넣지 않는다.
-- 날짜는 넣는 시점(now) 기준으로 만들어, 대시보드에서 '기한 초과·임박·여유'가 모두 보이게 함
-- 여러 번 실행해도 같은 데이터가 두 번 들어가지 않음 (고정 ID + on conflict do nothing)
-- =====================================================================
begin;   -- 중간에 오류가 나면 전부 취소 (반쯤 들어간 상태가 남지 않음)
set local app.actor_via = 'seed_fake';

insert into tutors (id, name, country, timezone) values
  ('00000000-7e57-0000-0000-00000000a001', '가상강사 Alex', 'Australia', 'Australia/Sydney'),
  ('00000000-7e57-0000-0000-00000000a002', '가상강사 Blair', 'Canada', 'America/Toronto')
on conflict do nothing;

insert into students (id, code, name_ko, name_en, email, timezone) values
  ('00000000-7e57-0000-0000-00000000b001', 'STU-9001', '가상학생일', 'Fake One', 'fake1@example.com', 'Asia/Seoul'),
  ('00000000-7e57-0000-0000-00000000b002', 'STU-9002', '가상학생이', 'Fake Two', 'fake2@example.com', 'Asia/Seoul'),
  ('00000000-7e57-0000-0000-00000000b003', 'STU-9003', '가상학생삼', 'Fake Three', 'fake3@example.com', 'Australia/Brisbane'),
  ('00000000-7e57-0000-0000-00000000b004', 'STU-9004', '가상학생사', 'Fake Four', 'fake4@example.com', 'Asia/Seoul')
on conflict do nothing;

-- 신규 학생 3명 (매칭 대기: 기한 초과 · 임박 · 여유), 재등록 1명
do $$
declare
  today date := ((now() at time zone 'UTC') + interval '9 hours')::date;
  -- 가상학생사: 이전 기간이 오늘 끝나고 오늘 재등록 결제(기한 안) → 새 28일은 종료 뒤 처음 오는 정규 수업일(화·목)부터
  -- (POL-RN-07, 정책 원본 A25 — 종료 다음 날 무조건 아님)
  renew_start date := (select min(d)::date from generate_series(today + 1, today + 7, interval '1 day') d
                       where extract(dow from d) in (2, 4));
begin
  insert into enrollments (id, student_id, seq, weeks, weekly_count, duration_min, start_date, base_end_date, lessons_purchased, status, policy_basis)
  values
    ('00000000-7e57-0000-0000-00000000c001', '00000000-7e57-0000-0000-00000000b001', 1, 4, 2, 50, today + 7, today + 34, 8, 'confirmed', 'policy_v1'),
    ('00000000-7e57-0000-0000-00000000c002', '00000000-7e57-0000-0000-00000000b002', 1, 24, 3, 40, today + 5, today + 172, 72, 'confirmed', 'policy_v1'),
    ('00000000-7e57-0000-0000-00000000c003', '00000000-7e57-0000-0000-00000000b003', 1, 12, 1, 50, today + 10, today + 93, 12, 'confirmed', 'policy_v1'),
    ('00000000-7e57-0000-0000-00000000c004', '00000000-7e57-0000-0000-00000000b004', 1, 4, 2, 50, today - 27, today, 8, 'active', 'legacy')
  on conflict do nothing;
  insert into regular_schedules (student_id, tutor_id, weekday, start_time_kst, duration_min, effective_from)
  select '00000000-7e57-0000-0000-00000000b004', '00000000-7e57-0000-0000-00000000a002', w, '20:00', 50, today - 27
  from unnest(array[2, 4]) w   -- 화·목 (주 2회)
  where not exists (select 1 from regular_schedules where student_id = '00000000-7e57-0000-0000-00000000b004' and weekday = w);
  insert into enrollments (id, student_id, seq, previous_enrollment_id, weeks, weekly_count, duration_min, start_date, base_end_date, lessons_purchased, status, policy_basis)
  values ('00000000-7e57-0000-0000-00000000c005', '00000000-7e57-0000-0000-00000000b004', 2, '00000000-7e57-0000-0000-00000000c004',
          4, 2, 50, renew_start, renew_start + 27, 8, 'confirmed', 'policy_v1')
  on conflict do nothing;

  -- 결제 확인 → 업무 자동 생성 (트리거). 확인 시각을 달리 해 기한 상태가 다르게 보이게
  insert into payments (id, enrollment_id, method, amount_received, received_on, paid_at, confirmed_by, confirmed_at, external_ref)
  values
    ('00000000-7e57-0000-0000-00000000d001', '00000000-7e57-0000-0000-00000000c001', 'bank_transfer', 100000,
     (((now() - interval '8 days') at time zone 'UTC') + interval '9 hours')::date, now() - interval '8 days',
     '00000000-7e57-0000-0000-0000000000ad', now() - interval '8 days', 'FAKE-1'),
    ('00000000-7e57-0000-0000-00000000d002', '00000000-7e57-0000-0000-00000000c002', 'card_link', 1000000,
     (((now() - interval '3 days') at time zone 'UTC') + interval '9 hours')::date, now() - interval '3 days',
     '00000000-7e57-0000-0000-0000000000ad', now() - interval '3 days', 'FAKE-2'),
    ('00000000-7e57-0000-0000-00000000d003', '00000000-7e57-0000-0000-00000000c003', 'card_link', 300000,
     ((now() at time zone 'UTC') + interval '9 hours')::date, now(), '00000000-7e57-0000-0000-0000000000ad', now(), 'FAKE-3'),
    ('00000000-7e57-0000-0000-00000000d005', '00000000-7e57-0000-0000-00000000c005', 'bank_transfer', 100000,
     ((now() at time zone 'UTC') + interval '9 hours')::date, now(), '00000000-7e57-0000-0000-0000000000ad', now(), 'FAKE-5')
  on conflict do nothing;
end $$;

-- 재등록 통보: 강사에게 보냈지만 아직 확인 안 함
update admin_tasks set tutor_notified_at = coalesce(tutor_notified_at, now())
where kind = 'renewal_tutor_notice' and enrollment_id = '00000000-7e57-0000-0000-00000000c005';

commit;
