-- =====================================================================
-- 운영진 대시보드 전면 개편 (5차 시안 + H26(114), 대표 2026-11-09) — 시험 DB 먼저, 운영 미반영
--  1) 공지 (announcements): 대상(학생 전체·강사 전체·학생·강사 모두) · 제목 60자 · 내용 2,000자 · 게시일 ~ 종료일(한국 날짜)
--     - 운영진: admin_announcements() 목록 · admin_announcement_save() 새 공지/수정 · admin_announcement_end() 게시 종료/되돌리기
--     - 학생·강사 홈: lms_announcements_live('student'|'tutor') — 게시 중인 공지만 (운영자는 대신 보기로 둘 다 읽음)
--     - 지우는 함수 없음 (게시 종료 = ended_at 기록, 이력 보존)
--  2) 체험용 계정 표시 (students·tutors.is_trial_account): 대시보드 숫자·명단에서 뺌, 목록에 '체험용' 표시
--     (운영: STU-0014 · Sera Kara 를 운영 반영 때 true 로 — 대표 승인 뒤)
--  기존 데이터 변경 없음. 다시 실행해도 같은 결과
-- =====================================================================

alter table students add column if not exists is_trial_account boolean not null default false;
alter table tutors add column if not exists is_trial_account boolean not null default false;
-- students 는 칸 단위 읽기 권한 (20261107030000) → 새 칸도 읽을 수 있게
grant select (is_trial_account) on students to authenticated;

create table if not exists announcements (
  id uuid primary key default gen_random_uuid(),
  audience text not null check (audience in ('student', 'tutor', 'both')),
  title text not null check (char_length(btrim(title)) between 1 and 60),
  body text not null check (char_length(btrim(body)) between 1 and 2000),
  starts_on date not null,
  ends_on date not null,
  ended_at timestamptz,
  ended_by uuid,
  created_by uuid,
  created_at timestamptz not null default now(),
  updated_by uuid,
  updated_at timestamptz not null default now(),
  constraint announcements_period check (ends_on >= starts_on)
);
alter table announcements enable row level security;
-- 표를 직접 읽고 쓰지 않음 — 아래 함수로만
revoke all on announcements from public, anon, authenticated;

create or replace function admin_announcements() returns setof announcements
language plpgsql stable security definer set search_path = public as $$
begin
  if not is_admin() then raise exception '운영자(추가 인증 완료)만 볼 수 있습니다.' using errcode = '42501'; end if;
  return query select * from announcements order by starts_on desc, created_at desc;
end $$;

create or replace function admin_announcement_save(p_id uuid, p_audience text, p_title text, p_body text, p_starts date, p_ends date)
returns uuid language plpgsql security definer set search_path = public as $$
declare v_id uuid;
begin
  if not is_admin() then raise exception '운영자(추가 인증 완료)만 저장할 수 있습니다.' using errcode = '42501'; end if;
  if p_audience is null or p_audience not in ('student', 'tutor', 'both') then raise exception '대상을 골라 주세요.'; end if;
  if coalesce(btrim(p_title), '') = '' or coalesce(btrim(p_body), '') = '' then raise exception '제목과 내용을 넣어 주세요.'; end if;
  if char_length(btrim(p_title)) > 60 then raise exception '제목은 60자까지예요.'; end if;
  if char_length(btrim(p_body)) > 2000 then raise exception '내용은 2,000자까지예요.'; end if;
  if p_starts is null or p_ends is null then raise exception '게시일과 종료일을 넣어 주세요.'; end if;
  if p_ends < p_starts then raise exception '종료일이 게시일보다 빨라요.'; end if;
  if p_id is null then
    insert into announcements (audience, title, body, starts_on, ends_on, created_by, updated_by)
    values (p_audience, btrim(p_title), btrim(p_body), p_starts, p_ends, auth.uid(), auth.uid())
    returning id into v_id;
  else
    update announcements set audience = p_audience, title = btrim(p_title), body = btrim(p_body), starts_on = p_starts, ends_on = p_ends,
           updated_by = auth.uid(), updated_at = now()
     where id = p_id and ended_at is null
    returning id into v_id;
    if v_id is null then raise exception '게시 종료한 공지는 고칠 수 없어요.'; end if;
  end if;
  return v_id;
end $$;

-- 게시 종료 (p_end=false 면 되돌리기). 이미 같은 상태면 그대로
create or replace function admin_announcement_end(p_id uuid, p_end boolean default true)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception '운영자(추가 인증 완료)만 저장할 수 있습니다.' using errcode = '42501'; end if;
  if not exists (select 1 from announcements where id = p_id) then raise exception '공지가 없어요.'; end if;
  if p_end then
    update announcements set ended_at = now(), ended_by = auth.uid() where id = p_id and ended_at is null;
  else
    update announcements set ended_at = null, ended_by = null where id = p_id;
  end if;
end $$;

-- 홈에 보이는 공지: 오늘(한국 날짜)이 게시일~종료일 안이고 게시 종료 안 한 것
create or replace function lms_announcements_live(p_for text)
returns table (id uuid, title text, body text, starts_on date, ends_on date)
language plpgsql stable security definer set search_path = public as $$
declare v_today date := (now() at time zone 'Asia/Seoul')::date;
begin
  if p_for not in ('student', 'tutor') then raise exception '대상이 잘못됐어요.'; end if;
  if not (is_admin() or my_role() = p_for) then raise exception '볼 수 없어요.' using errcode = '42501'; end if;
  return query select a.id, a.title, a.body, a.starts_on, a.ends_on from announcements a
   where a.ended_at is null and a.starts_on <= v_today and a.ends_on >= v_today and a.audience in (p_for, 'both')
   order by a.starts_on desc, a.created_at desc;
end $$;

revoke all on function admin_announcements() from public, anon;
revoke all on function admin_announcement_save(uuid, text, text, text, date, date) from public, anon;
revoke all on function admin_announcement_end(uuid, boolean) from public, anon;
revoke all on function lms_announcements_live(text) from public, anon;
grant execute on function admin_announcements() to authenticated;
grant execute on function admin_announcement_save(uuid, text, text, text, date, date) to authenticated;
grant execute on function admin_announcement_end(uuid, boolean) to authenticated;
grant execute on function lms_announcements_live(text) to authenticated;

-- 3) 예외 연장 검토 [연장 안 함] (카드 닫기 대신 결정 기록): admin_set_task_closed 가 extension_review 를 받게
--    (이전 목록에 없어 예외 연장 검토 [카드 닫기]가 저장되지 않던 것도 같이 고침). 처리 내역에서 다시 열 수 있음
create or replace function public.admin_set_task_closed(p_kind text, p_id text, p_signature text, p_closed boolean)
returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null or not is_admin() then
    raise exception '추가 인증을 완료한 운영자만 처리할 수 있습니다.' using errcode = '42501';
  end if;
  if p_kind not in ('new_student_matching', 'renewal_tutor_notice', 'long_leave_request', 'no_show_report', 'ending_soon', 'makeup_unrequested', 'auto_failure', 'import_check', 'lesson_change', 'tutor_leave', 'class_record_missing', 'extension_review')
    or p_id is null or p_id = '' or p_signature is null or p_signature = '' or p_closed is null then
    raise exception '업무 정보가 올바르지 않습니다.';
  end if;
  perform set_config('app.actor_id', auth.uid()::text, true);
  perform set_config('app.actor_via', 'admin_set_task_closed', true);
  insert into public.admin_task_closures(task_kind, task_id, signature, closed, closed_at, closed_by)
  values (p_kind, p_id, p_signature, p_closed, now(), auth.uid())
  on conflict(task_kind, task_id) do update
  set signature = excluded.signature, closed = excluded.closed, closed_at = excluded.closed_at, closed_by = excluded.closed_by;
end $$;
revoke all on function public.admin_set_task_closed(text, text, text, boolean) from public, anon;
grant execute on function public.admin_set_task_closed(text, text, text, boolean) to authenticated;
