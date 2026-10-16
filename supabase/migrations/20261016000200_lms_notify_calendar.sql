-- =====================================================================
-- LMS 5단계: 알림 · Google 캘린더 반영 (초안 v0.2)
-- 실제 발송·캘린더 쓰기는 feature_flags(send_emails, calendar_write)를 운영자가 켜야 동작
-- =====================================================================

create table notifications (
  id uuid primary key default gen_random_uuid(),
  recipient_kind text not null check (recipient_kind in ('student', 'tutor', 'admin')),
  recipient_id uuid,
  email text not null,
  locale text not null check (locale in ('ko', 'en')),
  template text not null,
  payload jsonb not null default '{}',
  dedupe_key text not null unique,         -- 같은 알림 두 번 안 보냄
  send_after timestamptz not null default now(),
  status text not null default 'queued' check (status in ('queued', 'sent', 'failed', 'canceled')),
  attempts integer not null default 0,
  last_error text,
  sent_at timestamptz,
  created_at timestamptz not null default now()
);
create index notifications_due on notifications (send_after) where status = 'queued';

-- DB 수업 → 강사 Google 캘린더 반영 상태 (DB가 원본, 캘린더는 복사본)
create table calendar_sync (
  lesson_id uuid primary key references lessons(id),
  calendar_id text not null,
  google_event_id text,                    -- 수업 id로 만든 고정 id → 재시도해도 중복 일정 안 생김
  desired_version integer not null default 1,
  synced_version integer not null default 0,
  attempts integer not null default 0,
  last_error text,
  last_synced_at timestamptz
);
create index calendar_sync_pending on calendar_sync (lesson_id) where synced_version < desired_version;

-- 수업이 바뀌면 같은 트랜잭션에서 반영 대기열에 올림 (수업 변경과 함께 저장되거나 함께 취소)
create or replace function enqueue_calendar_sync() returns trigger
language plpgsql as $$
declare
  cal text;
begin
  select google_calendar_id into cal from tutors where id = new.tutor_id;
  if cal is null then return new; end if;
  insert into calendar_sync (lesson_id, calendar_id) values (new.id, cal)
  on conflict (lesson_id) do update
    set desired_version = calendar_sync.desired_version + 1, calendar_id = excluded.calendar_id;
  return new;
end $$;
create trigger lessons_calendar_sync after insert or update of starts_at, ends_at, state, tutor_id on lessons
  for each row execute function enqueue_calendar_sync();

select lms_protect(t::regclass) from unnest(array['notifications', 'calendar_sync']) as t;
