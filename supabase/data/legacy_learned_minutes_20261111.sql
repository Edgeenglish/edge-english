-- 누적 학습 시간: LMS 이전 시트(강사 Class Record) 실제 진행 수업 합계 — 운영 학생 번호 기준 (2026-11-11 집계)
-- 집계 규칙: Class Status = Normal · Make-up completed · Tutor Late - Student Present · Covered by another tutor 만 (취소·노쇼·휴무 제외),
--   같은 학생·같은 한국 날짜·같은 시작 시각은 한 번만, 각 학생의 첫 LMS 수업 날짜(through_date) '전' 기록만.
--   Olivia 시트 10/20~10/30 줄은 시각·수업 길이가 비어 있어 넣지 않음(추측 안 함): 0001·0002·0003·0004 각 2회, 0005 6회, 0006 4회
-- 넣기만(on conflict do nothing): 다시 실행해도 늘지 않음. 운영 DB 적용은 대표 승인 뒤에만
-- (시험 DB 는 학생 번호만 같은 가상 학생이라 화면 확인용으로만 넣음)
insert into legacy_learned_minutes (student_id, lessons, minutes, through_date, source)
select s.id, v.lessons, v.minutes, v.through_date::date, '시트 Class Record 집계 2026-11-11 (진행 수업만, 같은 학생·날짜·시각은 한 번, 시간 빈 줄 제외)'
from (values
  ('STU-0001', 6, 240, '2026-10-27'),
  ('STU-0002', 27, 540, '2026-10-28'),
  ('STU-0003', 0, 0, '2026-10-28'),
  ('STU-0004', 28, 1120, '2026-10-28'),
  ('STU-0005', 28, 560, '2026-11-09'),
  ('STU-0006', 43, 1720, '2026-11-12'),
  ('STU-0007', 12, 480, '2026-11-04'),
  ('STU-0008', 19, 700, '2026-11-05'),
  ('STU-0009', 4, 160, '2026-11-04'),
  ('STU-0010', 5, 200, '2026-11-02'),
  ('STU-0011', 34, 1700, '2026-11-02'),
  ('STU-0012', 0, 0, '2026-11-12'),
  ('STU-0013', 1, 20, '2026-11-06'),
  ('STU-0014', 0, 0, '2026-11-10')
) as v(code, lessons, minutes, through_date)
join students s on s.code = v.code
on conflict (student_id) do nothing;
