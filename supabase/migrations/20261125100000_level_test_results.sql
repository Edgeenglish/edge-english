-- 홈페이지 무료 레벨테스트 결과 저장 (정책 원본 H26 11/25 '레벨테스트' 항목 ⑨⑪)
-- 결과는 가입 없이 화면에서 바로 보여 주고(브라우저에만 보관), 로그인(가입)하면 그 계정에 붙여 언제든 다시 본다.
-- 학생·강사로 연결 안 된 가입 회원도 저장된다 (auth 계정 기준). 보유 기간 = 회원 탈퇴 때까지(대표 11/25, 계정을 지우면 함께 지워짐 — on delete cascade).

create table if not exists level_test_results (
  id uuid primary key default gen_random_uuid(),
  auth_user_id uuid not null references auth.users(id) on delete cascade,
  version text not null default 'v1',               -- 문제 판본 (문제를 바꾸면 v2)
  picks smallint[] not null check (cardinality(picks) = 20),
  score smallint not null check (score between 0 and 20),
  level text not null check (level in ('입문', '초급', '중급', '고급')),
  taken_at timestamptz not null,                    -- 테스트를 끝낸 시각 (브라우저 기준, 같은 결과 두 번 저장 막기)
  created_at timestamptz not null default now(),
  unique (auth_user_id, taken_at)
);
alter table level_test_results enable row level security; -- 직접 읽기·쓰기 없음, 아래 함수로만

-- 로그인한 본인 계정에 결과 붙이기 (다시 불러도 1건)
create or replace function level_test_save(p_picks smallint[], p_score int, p_level text, p_taken_at timestamptz)
returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_id uuid;
begin
  if auth.uid() is null then raise exception 'login required'; end if;
  if p_taken_at > now() + interval '1 day' or p_taken_at < now() - interval '1 year' then raise exception 'bad time'; end if;
  insert into level_test_results (auth_user_id, picks, score, level, taken_at)
  values (auth.uid(), p_picks, p_score, p_level, p_taken_at)
  on conflict (auth_user_id, taken_at) do nothing
  returning id into v_id;
  if v_id is null then
    select id into v_id from level_test_results where auth_user_id = auth.uid() and taken_at = p_taken_at;
  end if;
  return v_id;
end $$;
revoke all on function level_test_save(smallint[], int, text, timestamptz) from public, anon;
grant execute on function level_test_save(smallint[], int, text, timestamptz) to authenticated;

-- 내 레벨테스트 결과 (새것 먼저). p_student = 운영자 보기(학생 화면 대신 보기)
create or replace function level_test_mine(p_student uuid default null)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_user uuid := auth.uid();
begin
  if v_user is null then raise exception 'login required'; end if;
  if p_student is not null then
    select au.auth_user_id into v_user from app_users au where au.student_id = lms_screen_student(p_student);
    if v_user is null then return '[]'::jsonb; end if;
  end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object('id', r.id, 'picks', r.picks, 'score', r.score, 'level', r.level, 'taken_at', r.taken_at) order by r.taken_at desc)
    from level_test_results r
    where r.auth_user_id = v_user and r.version = 'v1'
  ), '[]'::jsonb);
end $$;
revoke all on function level_test_mine(uuid) from public, anon;
grant execute on function level_test_mine(uuid) to authenticated;
