-- LMS 주소 이전 (정책 원본 H26(108), 대표 11/9): 운영 DB 메일 속 LMS 링크를 edgeenglish.kr/lms 로.
-- 시험 DB 는 그대로 lms-test 주소. 운영 DB 적용 시점 = 11/15 완전 이전 때(그 전엔 기존 학생이 Vercel 주소 사용).
-- 되돌리기: 20261108010000_lms_notice_email.sql 의 lms_url() 정의를 다시 실행.
create or replace function lms_url() returns text
language sql stable security definer set search_path = public as $$
  select case when (select name from lms_backup.project limit 1) = 'edgeenglish-lms'
              then 'https://edgeenglish.kr/lms'
              else 'https://edge-english-git-lms-test-support-2126.vercel.app/lms' end
$$;
revoke all on function lms_url() from public, anon, authenticated;
