-- H26(150) 카카오·네이버 첫 로그인 '이미 회원이에요':
-- 방금 카카오·네이버로 새로 생긴 로그인 계정을 지워야 기존 계정에 그 카카오·네이버를 연결(linkIdentity)할 수 있다
-- (한 카카오 계정은 로그인 계정 하나에만 붙음).
-- 지우는 것은 '부른 사람 본인' 계정뿐이고, 아래를 모두 만족할 때만:
--   · 엣지영어 회원 연결(app_users)이 없음 = 학생·강사·운영자 기록과 연결된 적 없음
--   · 이메일·비밀번호 로그인 방법이 없음 = 카카오·네이버로만 생긴 계정
-- 기존 회원 계정·수강 기록은 이 함수로 절대 지워지지 않는다.
create or replace function public.lms_discard_new_social_account()
returns boolean
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then
    return false;
  end if;
  if exists (select 1 from public.app_users where auth_user_id = v_uid) then
    return false;
  end if;
  if exists (select 1 from auth.identities where user_id = v_uid and provider = 'email') then
    return false;
  end if;
  if not exists (select 1 from auth.identities where user_id = v_uid) then
    return false;
  end if;
  delete from auth.users where id = v_uid;
  return true;
end;
$$;

revoke all on function public.lms_discard_new_social_account() from public, anon;
grant execute on function public.lms_discard_new_social_account() to authenticated;
