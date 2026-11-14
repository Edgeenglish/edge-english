-- 신규 학생 수업 리마인더 기본값: 정규 끔, 보강 켬 (대표 11/14, 정책 원본 H26(174))
-- 기존 학생 설정은 바꾸지 않음. 학생은 내 정보 › 이메일 알림 설정에서 직접 켜고 끌 수 있음
alter table students alter column remind_regular set default false;
