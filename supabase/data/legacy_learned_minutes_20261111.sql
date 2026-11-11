-- 누적 학습 시간: LMS 이전 시트(강사 Class Record) 실제 진행 수업 합계 — 운영 학생 번호 기준 (2026-11-11 집계)
-- 집계 규칙: Class Status = Normal · Make-up completed · Tutor Late - Student Present · Covered by another tutor 만 (취소·노쇼·휴무 제외),
--   같은 학생·같은 한국 날짜·같은 시작 시각은 한 번만, 각 학생의 첫 LMS 수업 날짜(through_date) '전' 기록만.
--   Olivia 시트 10/20~10/30 줄: 숨겨진 열이라 시각·길이가 비어 있던 것을 11/11 학생 수강 현황 시트 기준으로 채운 뒤 합산
-- 넣기만(on conflict do nothing): 다시 실행해도 늘지 않음. 운영 DB 적용은 대표 승인 뒤에만
-- (시험 DB 는 학생 번호만 같은 가상 학생이라 화면 확인용으로만 넣음)
insert into legacy_learned_minutes (student_id, lessons, minutes, through_date, source)
select s.id, v.lessons, v.minutes, v.through_date::date, '시트 Class Record 집계 2026-11-11 (진행 수업만, 같은 학생·날짜·시각은 한 번, Olivia 10/20~ 시각·길이 학생 시트로 채움)'
from (values
  ('STU-0001', 8, 320, '2026-10-27'),
  ('STU-0002', 29, 580, '2026-10-28'),
  ('STU-0003', 2, 80, '2026-10-28'),
  ('STU-0004', 30, 1200, '2026-10-28'),
  ('STU-0005', 34, 680, '2026-11-09'),
  ('STU-0006', 47, 1880, '2026-11-12'),
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
