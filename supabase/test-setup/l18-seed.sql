-- 강사 휴무 화면 시험(B)용 가상 강사·학생 (시험용 DB에서만, 두 번 실행해도 한 번만 만듦). 날짜는 실행한 날 기준
-- 가상휴무강사(서울) 수업: 가상휴무A 3·4·5일 뒤 20:00 · 가상휴무B 4일 뒤 12:00 (한국 시각, 40분)
-- 가상대체강사(마닐라)는 비어 있음 · 가상바쁜강사는 4일 뒤 20:00에 가상휴무B 수업 → 대체강사 목록에서 '겹침'으로 보임
do $$
declare
  t_leave uuid;
  t_sub uuid;
  t_busy uuid;
  s_a uuid;
  s_b uuid;
  e_a uuid;
  e_b uuid;
  d0 date := (now() at time zone 'Asia/Seoul')::date;
begin
  if (select name from lms_backup.project) is distinct from 'edgeenglish-lms-test' then
    raise notice '시험용 DB가 아니라서 아무것도 하지 않았어요.';
    return;
  end if;
  if exists (select 1 from students where name_ko = '가상휴무A') then
    raise notice '이미 있어요 (그대로 둠).';
    return;
  end if;
  insert into tutors (name, country, timezone) values ('가상휴무강사', 'Korea', 'Asia/Seoul') returning id into t_leave;
  insert into tutors (name, country, timezone) values ('가상대체강사', 'Philippines', 'Asia/Manila') returning id into t_sub;
  insert into tutors (name, country, timezone) values ('가상바쁜강사', 'Korea', 'Asia/Seoul') returning id into t_busy;
  insert into students (name_ko, name_en) values ('가상휴무A', 'Virtual Leave A') returning id into s_a;
  insert into students (name_ko, name_en) values ('가상휴무B', 'Virtual Leave B') returning id into s_b;
  insert into enrollments (student_id, seq, weeks, weekly_count, duration_min, start_date, base_end_date, lessons_purchased, status)
  values (s_a, 1, 4, 3, 40, d0 - 7, d0 - 7 + 27, 12, 'active') returning id into e_a;
  insert into enrollments (student_id, seq, weeks, weekly_count, duration_min, start_date, base_end_date, lessons_purchased, status)
  values (s_b, 1, 4, 2, 40, d0 - 7, d0 - 7 + 27, 8, 'active') returning id into e_b;
  insert into enrollment_periods (enrollment_id, idx, start_date, end_date, credits_granted)
  values (e_a, 1, d0 - 7, d0 - 7 + 27, 3), (e_b, 1, d0 - 7, d0 - 7 + 27, 2);
  insert into lessons (enrollment_id, student_id, tutor_id, kind, seq, starts_at, ends_at)
  select e_a, s_a, t_leave, 'regular', n, ((d0 + n + 2) + time '20:00') at time zone 'Asia/Seoul', ((d0 + n + 2) + time '20:40') at time zone 'Asia/Seoul'
  from generate_series(1, 3) n;
  insert into lessons (enrollment_id, student_id, tutor_id, kind, seq, starts_at, ends_at) values
    (e_b, s_b, t_leave, 'regular', 1, ((d0 + 4) + time '12:00') at time zone 'Asia/Seoul', ((d0 + 4) + time '12:40') at time zone 'Asia/Seoul'),
    (e_b, s_b, t_busy, 'regular', 2, ((d0 + 4) + time '20:00') at time zone 'Asia/Seoul', ((d0 + 4) + time '20:40') at time zone 'Asia/Seoul');
  raise notice '가상 강사 3명·학생 2명·수업 5개를 만들었어요.';
end $$;
select s.name_ko as 학생, t.name as 강사, to_char(l.starts_at at time zone 'Asia/Seoul', 'MM/DD HH24:MI') as 수업_한국
from lessons l join students s on s.id = l.student_id join tutors t on t.id = l.tutor_id
where s.name_ko in ('가상휴무A', '가상휴무B') order by l.starts_at;
