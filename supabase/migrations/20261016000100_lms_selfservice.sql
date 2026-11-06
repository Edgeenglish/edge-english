-- =====================================================================
-- LMS 4단계: 강사 가능 시간 · 학생 보강 신청 (초안 v0.2)
-- 4단계 시작 전에는 적용하지 않는다. 3단계까지는 운영자가 보강을 lessons 에 직접 넣는다.
-- =====================================================================

-- 주간 수업 가능 시간 (강사 현지 시각 + 시간대 → 서머타임이 바뀌어도 강사 기준 유지)
create table tutor_availability (
  id uuid primary key default gen_random_uuid(),
  tutor_id uuid not null references tutors(id),
  weekday smallint not null check (weekday between 0 and 6),
  start_local time not null,
  end_local time not null,
  timezone text not null check (is_valid_timezone(timezone)),
  effective_from date not null default current_date,
  effective_to date,
  check (end_local > start_local)
);

-- 보강 신청: 진행 상태만 (결과는 확정 시 만들어지는 lessons 행)
create table makeup_requests (
  id uuid primary key default gen_random_uuid(),
  source_lesson_id uuid not null references lessons(id),
  student_id uuid not null references students(id),
  tutor_id uuid not null references tutors(id),
  status text not null default 'requested'
    check (status in ('requested', 'countered', 'confirmed', 'declined', 'expired', 'withdrawn')),
  confirmed_lesson_id uuid unique references lessons(id),
  tutor_note text,
  remind_at timestamptz,                   -- 강사 무응답 재알림 시각 (기준 시간은 미확정 D-11)
  created_at timestamptz not null default now(),
  decided_at timestamptz,
  check ((status = 'confirmed') = (confirmed_lesson_id is not null))
);
create unique index makeup_requests_one_open on makeup_requests (source_lesson_id)
  where status in ('requested', 'countered');

create table makeup_candidates (
  id uuid primary key default gen_random_uuid(),
  request_id uuid not null references makeup_requests(id),
  starts_at timestamptz not null,
  ends_at timestamptz not null,
  proposed_by text not null check (proposed_by in ('student', 'tutor')),
  check (ends_at > starts_at)
);

select lms_protect(t::regclass) from unnest(array['tutor_availability', 'makeup_requests', 'makeup_candidates']) as t;

create policy tutor_own on tutor_availability for select to authenticated using (tutor_id = my_tutor_id());
create policy student_own on makeup_requests for select to authenticated using (student_id = my_student_id());
create policy tutor_own on makeup_requests for select to authenticated using (tutor_id = my_tutor_id());
create policy own on makeup_candidates for select to authenticated
  using (exists (select 1 from makeup_requests r where r.id = request_id
                 and (r.student_id = my_student_id() or r.tutor_id = my_tutor_id())));
