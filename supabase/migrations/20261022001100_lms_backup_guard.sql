-- =====================================================================
-- 복구 안전장치 (2026-10-22, 정책 원본 H23(5) 예외: 비상 복구는 대표 승인 + 복구 직전 백업 후)
--  1. lms_backup.project: 이 DB가 어느 프로젝트인지 이름 한 줄 (시험용 edgeenglish-lms-test / 운영 edgeenglish-lms)
--     - 이름은 프로젝트마다 다르므로 이 파일이 아니라 각 프로젝트 적용 안내에서 한 번 넣는다
--     - 백업에 이름이 같이 기록되고, 복구는 ① 입력한 이름 ② 이 표의 이름 ③ 백업의 이름이 모두 같아야 실행됨
--       → 시험용·운영 DB를 헷갈리거나 다른 프로젝트 백업을 넣으려 하면 아무것도 바뀌지 않음
--  2. lms_backup.snapshots: 복구가 지금 내용을 지우기 직전에 같은 묶음 안에서 지금 상태를 통째로 저장
--     → 잘못 복구해도 그 직전으로 되돌릴 수 있음 (supabase/backup/from-snapshot.sql)
-- 앱(로그인 사용자·비로그인)은 이 영역을 전혀 못 씀: public 이 아닌 별도 영역이라 Data API 에도 안 나옴
-- 기존 표·데이터는 바꾸지 않음. 다시 실행해도 같은 결과
-- =====================================================================

create schema if not exists lms_backup;
revoke all on schema lms_backup from public;
do $$
begin
  if exists (select 1 from pg_roles where rolname = 'anon') then
    execute 'revoke all on schema lms_backup from anon, authenticated';
  end if;
end $$;

create table if not exists lms_backup.project (
  name text primary key check (name in ('edgeenglish-lms-test', 'edgeenglish-lms')),
  set_at timestamptz not null default now()
);
create unique index if not exists project_one_row on lms_backup.project ((true));

create table if not exists lms_backup.snapshots (
  id bigint generated always as identity primary key,
  taken_at timestamptz not null default now(),
  taken_by text not null default current_user,
  reason text not null,
  backup jsonb not null          -- backup.sql 결과와 같은 모양: {"_meta": …, "students": [...], …, "_sequences": {...}}
);

revoke all on all tables in schema lms_backup from public;
do $$
begin
  if exists (select 1 from pg_roles where rolname = 'anon') then
    execute 'revoke all on all tables in schema lms_backup from anon, authenticated';
  end if;
end $$;
