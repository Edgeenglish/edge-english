-- 수업 변경 화면 시험(B)용 가상 학생·가상 강사 (시험용 DB에서만, 두 번 실행해도 한 번만 만듦)
-- 가상강사 Change(마닐라) · 가상변경 / Virtual Change · 4주 주2회 50분 · 2026-10-20 ~ 11-16 · 변경권 2
-- 수업: 10/26(월) 23:30 · 10/29(목) 10:00 · 11/3(화) 10:00 · 11/5(목) 10:00 (한국 시각)
do $$
declare
  t uuid;
  s uuid;
  e uuid;
begin
  if (select name from lms_backup.project) is distinct from 'edgeenglish-lms-test' then
    raise notice '시험용 DB가 아니라서 아무것도 하지 않았어요.';
    return;
  end if;
  if exists (select 1 from students where name_ko = '가상변경') then
    raise notice '이미 있어요 (그대로 둠).';
    return;
  end if;
  insert into tutors (name, country, timezone) values ('가상강사 Change', 'Philippines', 'Asia/Manila') returning id into t;
  insert into students (name_ko, name_en) values ('가상변경', 'Virtual Change') returning id into s;
  insert into enrollments (student_id, seq, weeks, weekly_count, duration_min, start_date, base_end_date, lessons_purchased, status)
  values (s, 1, 4, 2, 50, '2026-10-20', '2026-11-16', 8, 'active') returning id into e;
  insert into enrollment_periods (enrollment_id, idx, start_date, end_date, credits_granted) values (e, 1, '2026-10-20', '2026-11-16', 2);
  insert into lessons (enrollment_id, student_id, tutor_id, kind, seq, starts_at, ends_at)
  select e, s, t, 'regular', n, at, at + interval '50 minutes'
  from (values (1, timestamptz '2026-10-26 23:30+09'), (2, timestamptz '2026-10-29 10:00+09'),
               (3, timestamptz '2026-11-03 10:00+09'), (4, timestamptz '2026-11-05 10:00+09')) v(n, at);
  raise notice '가상변경 학생과 수업 4개를 만들었어요.';
end $$;
select s.code as 학생_번호, s.name_ko as 이름, count(l.id) as 수업_수
from students s left join lessons l on l.student_id = s.id where s.name_ko = '가상변경' group by s.code, s.name_ko;
