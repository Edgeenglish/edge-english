-- 강사 휴무 새 화면(안 1) 시험용 두 번째 장면 (시험용 DB에서만, 두 번 실행해도 한 번만 만듦)
-- 휴무 강사 Lucas(서울): 정유진 11/09·11/11·11/13 19:00 (월·수·금) · 한도훈 11/10·11/12 21:00 (화·목) (40분)
-- 대체 가능 James(마닐라) / Sophie: 11/11 19:00 에 박서연 수업 → 정유진 3회 중 2회 가능·1회 겹침 (실제 강사·학생 이름 아님)
do $$
declare
  t_leave uuid;
  t_sophie uuid := (select id from tutors where name = 'Sophie');
  s_a uuid;
  s_b uuid;
  e_a uuid;
  e_b uuid;
begin
  if (select name from lms_backup.project) is distinct from 'edgeenglish-lms-test' then
    raise notice '시험용 DB가 아니라서 아무것도 하지 않았어요.';
    return;
  end if;
  if exists (select 1 from students where name_ko = '정유진') then
    raise notice '이미 있어요 (그대로 둠).';
    return;
  end if;
  insert into tutors (name, country, timezone) values ('Lucas', 'Korea', 'Asia/Seoul') returning id into t_leave;
  insert into students (name_ko, name_en) values ('정유진', 'Yujin Jung') returning id into s_a;
  insert into students (name_ko, name_en) values ('한도훈', 'Dohoon Han') returning id into s_b;
  insert into enrollments (student_id, seq, weeks, weekly_count, duration_min, start_date, base_end_date, lessons_purchased, status)
  values (s_a, 1, 4, 3, 40, date '2026-11-02', date '2026-11-29', 12, 'active') returning id into e_a;
  insert into enrollments (student_id, seq, weeks, weekly_count, duration_min, start_date, base_end_date, lessons_purchased, status)
  values (s_b, 1, 4, 2, 40, date '2026-11-03', date '2026-11-30', 8, 'active') returning id into e_b;
  insert into enrollment_periods (enrollment_id, idx, start_date, end_date, credits_granted)
  values (e_a, 1, date '2026-11-02', date '2026-11-29', 3), (e_b, 1, date '2026-11-03', date '2026-11-30', 2);
  insert into regular_schedules (student_id, tutor_id, weekday, start_time_kst, duration_min, effective_from) values
    (s_a, t_leave, 1, '19:00', 40, date '2026-11-02'), (s_a, t_leave, 3, '19:00', 40, date '2026-11-02'), (s_a, t_leave, 5, '19:00', 40, date '2026-11-02'),
    (s_b, t_leave, 2, '21:00', 40, date '2026-11-03'), (s_b, t_leave, 4, '21:00', 40, date '2026-11-03');
  insert into lessons (enrollment_id, student_id, tutor_id, kind, seq, starts_at, ends_at)
  select e_a, s_a, t_leave, 'regular', n, (d + time '19:00') at time zone 'Asia/Seoul', (d + time '19:40') at time zone 'Asia/Seoul'
  from (values (1, date '2026-11-09'), (2, date '2026-11-11'), (3, date '2026-11-13')) v(n, d);
  insert into lessons (enrollment_id, student_id, tutor_id, kind, seq, starts_at, ends_at)
  select e_b, s_b, t_leave, 'regular', n, (d + time '21:00') at time zone 'Asia/Seoul', (d + time '21:40') at time zone 'Asia/Seoul'
  from (values (1, date '2026-11-10'), (2, date '2026-11-12')) v(n, d);
  -- Sophie 겹침용: 박서연 11/11 19:00 Sophie 수업
  insert into lessons (enrollment_id, student_id, tutor_id, kind, seq, starts_at, ends_at)
  select l.enrollment_id, l.student_id, t_sophie, 'regular', 4, timestamp '2026-11-11 19:00' at time zone 'Asia/Seoul', timestamp '2026-11-11 19:40' at time zone 'Asia/Seoul'
  from lessons l join students s on s.id = l.student_id where s.name_ko = '박서연' limit 1;
  raise notice 'Lucas·정유진·한도훈을 만들었어요.';
end $$;
select s.name_ko as 학생, t.name as 강사, to_char(l.starts_at at time zone 'Asia/Seoul', 'MM/DD HH24:MI') as 수업_한국
from lessons l join students s on s.id = l.student_id join tutors t on t.id = l.tutor_id
where s.name_ko in ('정유진', '한도훈') or (t.name = 'Sophie' and l.starts_at >= timestamp '2026-11-09' at time zone 'Asia/Seoul') order by l.starts_at;
