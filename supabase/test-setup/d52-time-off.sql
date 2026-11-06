-- 화면 시험 J용: 가상강사 Alex 에 약 2주 뒤 수요일 하루 '가상 휴무 시험' (시험용 DB 전용, 여러 번 실행해도 1건)
-- 결과 줄의 날짜를 기억해 두세요 (그 날짜의 수요일 수업만 '강사 휴무'로 막혀야 정상)
insert into tutor_time_off (tutor_id, starts_at, ends_at, kind, reason)
select t.id, (d::timestamp at time zone 'Asia/Seoul'), ((d + 1)::timestamp at time zone 'Asia/Seoul'), 'leave', '가상 휴무 시험'
from tutors t,
     lateral (select (now() at time zone 'Asia/Seoul')::date as today) x,
     lateral (select x.today + ((3 - extract(dow from x.today)::int + 7) % 7) + 7 as d) w
where t.name = '가상강사 Alex' and (select name from lms_backup.project) = 'edgeenglish-lms-test'
  and not exists (select 1 from tutor_time_off o where o.tutor_id = t.id and o.reason = '가상 휴무 시험');
select o.starts_at at time zone 'Asia/Seoul' as 휴무_시작_한국, o.reason as 사유
from tutor_time_off o join tutors t on t.id = o.tutor_id where t.name = '가상강사 Alex' and o.reason = '가상 휴무 시험';
