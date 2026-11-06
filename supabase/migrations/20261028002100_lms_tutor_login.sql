-- =====================================================================
-- 강사 로그인 계정 만들기 (2026-10-28 대표: 'Claude가 해, 내 손 안 거치게')
--  - 대표(owner, TOTP 완료)가 강사 화면 '운영자 보기'에서 이메일만 넣으면
--    로그인 계정(auth.users, 이메일 확인됨) + 강사 연결(app_users) + tutors.email 을 한 번에 만든다
--  - 비밀번호 없음: 강사는 이메일 6자리 코드로 로그인 (POL-AC-03). 초대 메일 기능은 쓰지 않음(supabase-test-setup ⑥)
--  - 이미 같은 이메일 계정이 있으면 새로 만들지 않고 연결만. 다른 학생·강사·운영자에 연결된 계정이면 거절
--  - 강사 1명 = 계정 1개 (app_users.tutor_id unique). 이미 연결된 강사면 그대로 돌려줌(다시 눌러도 안전)
-- 기존 표·데이터를 지우지 않음. 다시 실행해도 같은 결과
-- =====================================================================

create or replace function admin_tutor_login(p_tutor uuid, p_email text)
returns table (tutor_name text, email text, created boolean)
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_email text := lower(trim(coalesce(p_email, '')));
  v_name text;
  v_linked uuid;
  v_uid uuid;
  v_role text;
  v_new boolean := false;
begin
  if not is_owner() then raise exception '대표 계정(추가 인증 완료)만 강사 로그인 계정을 만들 수 있습니다.' using errcode = '42501'; end if;
  if v_email !~ '^[^\s@]+@[^\s@]+\.[^\s@]+$' then raise exception '이메일 주소를 다시 확인해 주세요.' using errcode = '22023'; end if;
  select t.name into v_name from tutors t where t.id = p_tutor for update;
  if v_name is null then raise exception '강사를 찾을 수 없습니다.' using errcode = 'P0002'; end if;

  -- 이미 연결된 강사: 같은 이메일이면 그대로, 다르면 거절 (계정 바꾸기는 대표 확인 뒤 따로)
  select u.auth_user_id into v_linked from app_users u where u.tutor_id = p_tutor;
  if v_linked is not null then
    if (select lower(a.email) from auth.users a where a.id = v_linked) = v_email then
      return query select v_name, v_email, false; return;
    end if;
    raise exception '% 강사는 이미 다른 이메일로 연결돼 있습니다.', v_name using errcode = '23505';
  end if;

  select a.id into v_uid from auth.users a where lower(a.email) = v_email;
  if v_uid is not null then
    select u.role into v_role from app_users u where u.auth_user_id = v_uid;
    if v_role is not null then raise exception '이 이메일은 이미 다른 사람(%)에 연결돼 있습니다.', v_role using errcode = '23505'; end if;
    update auth.users set email_confirmed_at = coalesce(email_confirmed_at, now()) where id = v_uid;
  else
    v_uid := gen_random_uuid();
    v_new := true;
    -- 대시보드 'Add user · Auto Confirm' 과 같은 모양. 토큰 칸은 null 이면 로그인 서버가 읽다 실패하므로 빈 글자
    insert into auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
      raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
      confirmation_token, recovery_token, email_change_token_new, email_change, email_change_token_current,
      phone_change, phone_change_token, reauthentication_token, is_sso_user, is_anonymous)
    values ('00000000-0000-0000-0000-000000000000', v_uid, 'authenticated', 'authenticated', v_email,
      crypt(gen_random_uuid()::text, gen_salt('bf')), now(),
      '{"provider":"email","providers":["email"]}', '{}', now(), now(),
      '', '', '', '', '', '', '', '', false, false);
    insert into auth.identities (id, user_id, provider_id, provider, identity_data, created_at, updated_at)
    values (gen_random_uuid(), v_uid, v_uid::text, 'email',
      jsonb_build_object('sub', v_uid::text, 'email', v_email, 'email_verified', true, 'phone_verified', false), now(), now());
  end if;

  insert into app_users (auth_user_id, role, tutor_id) values (v_uid, 'tutor', p_tutor);
  update tutors t set email = v_email where t.id = p_tutor and t.email is distinct from v_email;
  return query select v_name, v_email, v_new;
end $$;
revoke all on function admin_tutor_login(uuid, text) from public, anon;
grant execute on function admin_tutor_login(uuid, text) to authenticated;
