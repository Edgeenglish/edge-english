-- 강사 화면(migration 2000) 시험용 장면 (시험용 DB에서만, 두 번 실행해도 한 번만 만듦). 실제 강사·학생 이름 아님
-- 강사 Mia(시드니) — 강사 LMS 계정이 10/25에 생긴 것으로 연결(로그인용 실제 계정은 아님, 운영자 보기로 시험)
--  · 정하은(Haeun Jung) 월·수 15:00 KST 40분: 10/19·10/21 진행 기록됨, 10/26·10/28 기록할 수업, 11/2~ 예정
--  · 윤지호(Jiho Yoon) 화·목 13:00 KST 20분: 10/20 진행, 10/22 강사 취소 → 10/27 14:00 보강(기록할 수업),
--    10/27 학생 취소 → 보강 신청(학생 원하는 시간 10/30 13:00 · 11/2 15:00 — 11/2는 정하은 수업과 겹침), 10/29~ 예정
--  · 강민재(Minjae Kang) 담당 Emma, 10/30 18:00 KST 40분 수업을 Mia가 대체
do $$
declare
  t_mia uuid;
  t_emma uuid := (select id from tutors where name = 'Emma');
  v_admin uuid := (select auth_user_id from app_users where role = 'admin' order by created_at limit 1);
  s_a uuid; s_b uuid; s_c uuid;
  e_a uuid; e_b uuid; e_c uuid;
  l_c3 uuid; l_b2 uuid;
  r uuid;
  k timestamptz;
begin
  if (select name from lms_backup.project) is distinct from 'edgeenglish-lms-test' then
    raise notice '시험용 DB가 아니라서 아무것도 하지 않았어요.';
    return;
  end if;
  if exists (select 1 from tutors where name = 'Mia') then
    raise notice '이미 있어요 (그대로 둠).';
    return;
  end if;
  perform set_config('app.actor_id', v_admin::text, true);
  insert into tutors (name, country, timezone, meet_url) values ('Mia', 'Australia', 'Australia/Sydney', 'https://meet.google.com/') returning id into t_mia;
  insert into app_users (auth_user_id, role, tutor_id, created_at) values (gen_random_uuid(), 'tutor', t_mia, timestamptz '2026-10-25 00:00+09');
  insert into students (name_ko, name_en, level, class_note_url) values ('정하은', 'Haeun Jung', 'Intermediate', 'https://docs.google.com/') returning id into s_a;
  insert into students (name_ko, name_en, class_note_url) values ('윤지호', 'Jiho Yoon', 'https://docs.google.com/') returning id into s_b;
  insert into students (name_ko, name_en) values ('강민재', 'Minjae Kang') returning id into s_c;
  insert into enrollments (student_id, seq, weeks, weekly_count, duration_min, start_date, base_end_date, lessons_purchased, status)
  values (s_a, 1, 4, 2, 40, date '2026-10-19', date '2026-11-15', 8, 'active') returning id into e_a;
  insert into enrollments (student_id, seq, weeks, weekly_count, duration_min, start_date, base_end_date, lessons_purchased, status)
  values (s_b, 1, 4, 2, 20, date '2026-10-20', date '2026-11-16', 8, 'active') returning id into e_b;
  insert into enrollments (student_id, seq, weeks, weekly_count, duration_min, start_date, base_end_date, lessons_purchased, status)
  values (s_c, 1, 4, 1, 40, date '2026-10-23', date '2026-11-19', 4, 'active') returning id into e_c;
  insert into enrollment_periods (enrollment_id, idx, start_date, end_date, credits_granted) values
    (e_a, 1, date '2026-10-19', date '2026-11-15', 2), (e_b, 1, date '2026-10-20', date '2026-11-16', 2), (e_c, 1, date '2026-10-23', date '2026-11-19', 1);
  insert into regular_schedules (student_id, tutor_id, weekday, start_time_kst, duration_min, effective_from) values
    (s_a, t_mia, 1, '15:00', 40, date '2026-10-19'), (s_a, t_mia, 3, '15:00', 40, date '2026-10-19'),
    (s_b, t_mia, 2, '13:00', 20, date '2026-10-20'), (s_b, t_mia, 4, '13:00', 20, date '2026-10-20'),
    (s_c, t_emma, 5, '18:00', 40, date '2026-10-23');
  -- 정하은
  insert into lessons (enrollment_id, student_id, tutor_id, kind, seq, starts_at, ends_at, state, class_status)
  select e_a, s_a, t_mia, 'regular', n, (d + time '15:00') at time zone 'Asia/Seoul', (d + time '15:40') at time zone 'Asia/Seoul',
         case when n <= 2 then 'done' else 'scheduled' end, case when n <= 2 then 'Normal'::class_status end
  from (values (1, date '2026-10-19'), (2, date '2026-10-21'), (3, date '2026-10-26'), (4, date '2026-10-28'),
               (5, date '2026-11-02'), (6, date '2026-11-04'), (7, date '2026-11-09'), (8, date '2026-11-11')) v(n, d);
  insert into class_records (lesson_id, covered_topics, submitted_by)
  select l.id, case l.seq when 1 then 'First class, self-introduction, goals' else 'Weekend plans, hobbies' end, v_admin
  from lessons l where l.enrollment_id = e_a and l.seq <= 2;
  -- 윤지호
  insert into lessons (enrollment_id, student_id, tutor_id, kind, seq, starts_at, ends_at, state, class_status, canceled_at, cancel_reason)
  select e_b, s_b, t_mia, 'regular', n, (d + time '13:00') at time zone 'Asia/Seoul', (d + time '13:20') at time zone 'Asia/Seoul', st, cs::class_status,
         case when st = 'canceled' then now() end, case when st = 'canceled' then '시험 장면' end
  from (values (1, date '2026-10-20', 'done', 'Normal'), (2, date '2026-10-22', 'canceled', 'Tutor canceled in advance'),
               (3, date '2026-10-27', 'canceled', 'Student canceled in advance'), (4, date '2026-10-29', 'scheduled', null),
               (5, date '2026-11-03', 'scheduled', null), (6, date '2026-11-05', 'scheduled', null),
               (7, date '2026-11-10', 'scheduled', null), (8, date '2026-11-12', 'scheduled', null)) v(n, d, st, cs);
  insert into class_records (lesson_id, covered_topics, submitted_by)
  select id, 'Free talk, school life', v_admin from lessons where enrollment_id = e_b and seq = 1;
  select id into l_b2 from lessons where enrollment_id = e_b and seq = 2;
  select id into l_c3 from lessons where enrollment_id = e_b and seq = 3;
  insert into lessons (enrollment_id, student_id, tutor_id, kind, starts_at, ends_at, makeup_of)
  values (e_b, s_b, t_mia, 'makeup', timestamptz '2026-10-27 14:00+09', timestamptz '2026-10-27 14:20+09', l_b2);
  insert into makeup_requests (source_lesson_id, student_id, tutor_id, via, requested_at, requested_by)
  values (l_c3, s_b, t_mia, 'admin_on_behalf', now(), v_admin) returning id into r;
  foreach k in array array[timestamptz '2026-10-30 13:00+09', timestamptz '2026-11-02 15:00+09'] loop
    insert into makeup_candidates (request_id, starts_at, ends_at, proposed_by) values (r, k, k + interval '20 minutes', 'student');
  end loop;
  insert into lesson_notices (makeup_request_id, event, recipient_kind, recipient_id) values (r, 'makeup_ask', 'tutor', t_mia);
  -- 강민재 (담당 Emma) 10/30 수업을 Mia가 대체
  insert into lessons (enrollment_id, student_id, tutor_id, original_tutor_id, kind, seq, starts_at, ends_at)
  values (e_c, s_c, t_mia, t_emma, 'regular', 2, timestamptz '2026-10-30 18:00+09', timestamptz '2026-10-30 18:40+09');
end $$;
