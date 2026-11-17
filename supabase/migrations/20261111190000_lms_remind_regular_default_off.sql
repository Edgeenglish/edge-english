-- 정규 수업 이메일 알림(24시간·2시간 전) 신규 학생 기본값 OFF (11/11 대표 정책 변경)
-- 기존 학생 값은 ChatGPT 가 운영·시험 DB 에서 이미 OFF 로 바꿈 → 여기서는 데이터를 건드리지 않고 기본값만 바꿈
-- 보강 알림(remind_makeup) 기본 ON·학생이 '내 정보'에서 직접 켜기(student_reminders)는 그대로
alter table students alter column remind_regular set default false;
