-- 대표 로그인 계정을 운영자(대표)로 연결. 먼저 Authentication → Users → Add user → Create new user 로
-- support@edgeenglish.kr 계정을 만든 뒤 실행 (Auto Confirm User 체크). 여러 번 실행해도 한 번만 들어감
-- 정상 결과: support@edgeenglish.kr · admin · owner 한 줄 (0줄이면 계정을 아직 안 만든 것)
insert into app_users (auth_user_id, role, admin_level)
select id, 'admin', 'owner' from auth.users where lower(email) = 'support@edgeenglish.kr'
on conflict (auth_user_id) do nothing;
select u.email as 이메일, a.role as 역할, a.admin_level as 단계
from app_users a join auth.users u on u.id = a.auth_user_id order by u.email;
