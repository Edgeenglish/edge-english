-- =====================================================================
-- 4601. 첫 수업 후 To-do 는 '앞으로 새로 시작하는 학생'에게만 (2026-11-06 대표 지시)
--  기준: feature_flags 'first_lesson_followup_since' 줄의 updated_at(이 migration 을 적용한 시각 = 기능 시작 시각, 한국 날짜).
--   (켜고 끄는 스위치가 아니라 시작일 기록용 — enabled 는 쓰지 않음, 다른 스위치처럼 false 로 둠)
--   - 그 날짜 이후에 시작한 수강권(enrollments.start_date >= 기준일)의 수업만 대상
--   - 기준일 전에 이미 진행한(done) 수업이 있는 학생(기존 학생)은 제외 → 밀린 To-do 가 한꺼번에 생기지 않음
--  기준일을 바꾸려면 그 줄의 updated_at 만 고치면 됨 (대표 결정). 다시 실행해도 같은 결과
-- =====================================================================
insert into feature_flags (key, enabled, note)
values ('first_lesson_followup_since', false, '첫 수업 후 강사 To-do 시작일 — 이 줄의 updated_at(한국 날짜) 이후 시작한 수강권·그 전에 수업한 적 없는 학생만 (스위치 아님)')
on conflict (key) do nothing;

create or replace function lms_first_lesson_followup_since()
returns date
language sql stable security definer set search_path = public as $$
  select (f.updated_at at time zone 'Asia/Seoul')::date from feature_flags f where f.key = 'first_lesson_followup_since'
$$;
revoke all on function lms_first_lesson_followup_since() from public, anon, authenticated;

-- 이 강사가 이 학생과 처음 진행한(Held) 수업 — 새로 시작한 학생만 (기준일 전 수업 이력이 있는 학생·기준일 전에 시작한 수강권은 null)
create or replace function lms_first_held_lesson(p_tutor uuid, p_student uuid)
returns lessons
language sql stable security definer set search_path = public as $$
  select l.* from lessons l
  join class_status_rules r on r.status = l.class_status
  join enrollments e on e.id = l.enrollment_id
  where l.student_id = p_student and l.tutor_id = p_tutor and l.state = 'done' and l.voided_at is null and r.outcome = 'held'
    and lms_first_lesson_followup_since() is not null
    and e.start_date >= lms_first_lesson_followup_since()
    and not exists (select 1 from lessons x where x.student_id = p_student and x.state = 'done' and x.voided_at is null
                    and (x.starts_at at time zone 'Asia/Seoul')::date < lms_first_lesson_followup_since())
  order by l.starts_at limit 1
$$;
revoke all on function lms_first_held_lesson(uuid, uuid) from public, anon, authenticated;
