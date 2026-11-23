-- H26(150) 카카오·네이버 이메일이 기존 계정과 같지만 '인증 안 됨'일 때:
-- Supabase 는 자동 연결하지 않고 이메일 없는 빈 로그인 계정(그 카카오·네이버만 붙은)을 만든 뒤 로그인을 거절한다.
-- 그 빈 계정이 카카오·네이버를 붙잡고 있어 기존 계정에 연결(linkIdentity)이 'already linked to another user' 로 막힌다.
-- 기존 계정으로 로그인한 본인이 연결 직전에 부르면, 아래를 모두 만족하는 빈 계정만 지운다:
--   · 로그인 방법이 그 공급자(카카오 또는 네이버) 하나뿐 (이메일·비밀번호 없음)
--   · 엣지영어 회원 연결(app_users) 없음, 이메일 확인 안 됨
--   · 그 공급자가 준 이메일이 부른 사람의 이메일과 같음 (= 본인 이메일로 시도했던 계정)
-- 다른 사람 계정·회원 계정·수강 기록은 지워지지 않는다. 지운 수를 돌려준다.
create or replace function public.lms_discard_unverified_social_orphan(p_provider text)
returns integer
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  v_uid uuid := auth.uid();
  v_email text;
  v_n integer;
begin
  if v_uid is null or p_provider not in ('kakao', 'custom:naver') then
    return 0;
  end if;
  select lower(email) into v_email from auth.users where id = v_uid and email_confirmed_at is not null;
  if v_email is null then
    return 0;
  end if;
  with orphan as (
    select u.id
      from auth.users u
      join auth.identities i on i.user_id = u.id and i.provider = p_provider
     where u.id <> v_uid
       and u.email_confirmed_at is null
       and lower(coalesce(i.identity_data->>'email', '')) = v_email
       and not exists (select 1 from public.app_users a where a.auth_user_id = u.id)
       and not exists (select 1 from auth.identities j where j.user_id = u.id and j.provider <> p_provider)
  )
  delete from auth.users where id in (select id from orphan);
  get diagnostics v_n = row_count;
  return v_n;
end;
$$;

revoke all on function public.lms_discard_unverified_social_orphan(text) from public, anon;
grant execute on function public.lms_discard_unverified_social_orphan(text) to authenticated;
