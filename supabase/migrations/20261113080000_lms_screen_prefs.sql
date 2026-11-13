-- 화면 보기 설정을 학생·강사 계정에 저장 (대표 2026-11-13, A안):
--  - 학생·강사 본인이 누른 보기 설정(처리 내역 정렬 · 강사 KST 칸 · Paid 칸)을 계정에 저장 → 기기가 달라도 같게
--  - 운영자 보기는 그 학생·강사가 저장한 값을 읽기만 함. 운영자가 누른 것은 그 화면에서만 잠깐 바뀌고 저장하지 않음
-- 칸 1개씩 추가 + 함수 2개. 기존 데이터·표를 바꾸지 않음. 다시 실행해도 같은 결과
alter table students add column if not exists screen_prefs jsonb not null default '{}'::jsonb;
alter table tutors add column if not exists screen_prefs jsonb not null default '{}'::jsonb;

-- 읽기: 학생 본인 / 강사 본인 / 운영자(대상 지정, lms_screen_* 와 같은 검사)
create or replace function lms_screen_prefs(p_student uuid default null, p_tutor uuid default null)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v jsonb;
begin
  if auth.uid() is null then raise exception '로그인해 주세요.' using errcode = '42501'; end if;
  if p_tutor is not null or (p_student is null and my_tutor_id() is not null) then
    select t.screen_prefs into v from tutors t where t.id = lms_screen_tutor(p_tutor);
  else
    select s.screen_prefs into v from students s where s.id = lms_screen_student(p_student);
  end if;
  return coalesce(v, '{}'::jsonb);
end $$;
revoke all on function lms_screen_prefs(uuid, uuid) from public, anon;
grant execute on function lms_screen_prefs(uuid, uuid) to authenticated;

-- 저장: 로그인한 학생·강사 본인 것만. 운영자는 저장하지 않음(A안) — 아무것도 바꾸지 않고 끝
create or replace function lms_screen_pref_set(p_key text, p_value text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception '로그인해 주세요.' using errcode = '42501'; end if;
  if p_key not in ('history_order', 'tutor_kst', 'tutor_paid') then raise exception 'Unknown setting.'; end if;
  if p_value not in ('asc', 'desc', '1', '0') then raise exception 'Unknown value.'; end if;
  if my_tutor_id() is not null then
    update tutors set screen_prefs = screen_prefs || jsonb_build_object(p_key, p_value) where id = my_tutor_id();
  elsif my_student_id() is not null then
    update students set screen_prefs = screen_prefs || jsonb_build_object(p_key, p_value) where id = my_student_id();
  end if;
end $$;
revoke all on function lms_screen_pref_set(text, text) from public, anon;
grant execute on function lms_screen_pref_set(text, text) to authenticated;
