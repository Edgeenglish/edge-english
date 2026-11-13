-- 학생 지각 알림 (대표 2026-11-13 확정):
--  - 학생이 홈 '다음 수업'에서 [늦게 참여해요] → 지각 시간(5·10·15·20분 이상) + 이유(선택, 4가지) → 담당 강사 Updates + 강사 이메일 1통
--  - 수업 시작 2시간 전부터 그 수업이 끝나기 전까지만. 수업 시간·수업 상태·수강권은 바꾸지 않는 통보
--  - 한 수업에 한 번만 (다시 눌러도 같은 결과, 메일 1통)
-- 표 1개 + tutor_updates 종류 1개 추가 + 함수 2개. 기존 데이터를 바꾸지 않음. 다시 실행해도 같은 결과

alter table tutor_updates drop constraint if exists tutor_updates_kind_check;
alter table tutor_updates add constraint tutor_updates_kind_check
  check (kind in ('new_student', 'renewal', 'schedule_change', 'class_moved', 'student_late'));

create table if not exists student_late_notices (
  id uuid primary key default gen_random_uuid(),
  lesson_id uuid not null unique references lessons(id),
  student_id uuid not null references students(id),
  tutor_id uuid not null references tutors(id),
  minutes integer not null check (minutes in (5, 10, 15, 20)),  -- 20 = '20분 이상'
  reason text check (reason in ('work_late', 'traffic', 'transit', 'unexpected')),
  created_by uuid,
  created_at timestamptz not null default now()
);
do $$ begin
  if not exists (select 1 from pg_trigger where tgname = 'student_late_notices_no_delete') then
    perform lms_protect('public.student_late_notices');
    create trigger student_late_notices_no_delete before delete on student_late_notices for each row execute function forbid_delete();
  end if;
end $$;

-- 보내기: 학생 본인 / 운영자(대신 입력, lms_screen_student 와 같은 검사). 이미 보냈으면 repeated
create or replace function student_late_notice(p_student uuid, p_lesson uuid, p_minutes integer, p_reason text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_student uuid := lms_screen_student(p_student);
  l lessons;
  st students;
  v_reason text;
  v_x text;
  v_paras text[];
begin
  select * into l from lessons where id = p_lesson;
  if not found or l.student_id <> v_student then raise exception '본인 수업만 알릴 수 있습니다.' using errcode = '42501'; end if;
  if p_minutes not in (5, 10, 15, 20) then raise exception '지각 시간을 골라 주세요.'; end if;
  if p_reason is not null and p_reason not in ('work_late', 'traffic', 'transit', 'unexpected') then raise exception '이유를 다시 골라 주세요.'; end if;
  if exists (select 1 from student_late_notices where lesson_id = p_lesson) then return jsonb_build_object('repeated', true); end if;
  if l.state <> 'scheduled' or l.voided_at is not null or l.tutor_id is null
     or now() < l.starts_at - interval '2 hours' or now() >= l.ends_at then
    raise exception '지금은 지각을 알릴 수 없는 수업이에요.' using hint = 'not_eligible';
  end if;
  perform set_config('app.actor_id', coalesce(auth.uid()::text, ''), true);
  perform set_config('app.actor_via', 'student_late_notice', true);
  insert into student_late_notices (lesson_id, student_id, tutor_id, minutes, reason, created_by)
  values (p_lesson, v_student, l.tutor_id, p_minutes, p_reason, auth.uid());
  select * into st from students where id = v_student;
  v_reason := case p_reason when 'work_late' then 'Work is running late.' when 'traffic' then 'I''m stuck in traffic.'
                            when 'transit' then 'Public transportation is delayed.' when 'unexpected' then 'Something unexpected came up.' end;
  v_x := case when p_minutes = 20 then '20 or more' else p_minutes::text end;
  -- 굵게는 *…* (대표 11/13): 지각 분, 'Please join… end time' 까지만. 마지막 문장은 한 줄 띄움(문단 따로)
  v_paras := array[
    'Student Running Late – ' || lms_student_en(st),
    lms_student_en(st) || ' has reported that they may be approximately *' || v_x || '* minutes late.'
      || case when v_reason is null then '' else E'\nReason: ' || v_reason end,
    '*Please join the class on time and stay until the scheduled end time*, as the student may arrive earlier than expected.'];
  perform lms_tutor_update_add(l.tutor_id, v_student, 'student_late',
    jsonb_build_object('to', l.starts_at, 'minutes', p_minutes, 'reason', p_reason),
    l.ends_at, 'student_late:' || p_lesson,
    'Student Running Late – ' || lms_student_en(st), v_paras);
  return jsonb_build_object('repeated', false);
end $$;
revoke all on function student_late_notice(uuid, uuid, integer, text) from public, anon;
grant execute on function student_late_notice(uuid, uuid, integer, text) to authenticated;

-- 읽기: 이 학생이 지각을 알린 (아직 끝나지 않은) 수업
create or replace function student_late_notices(p_student uuid default null) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_student uuid := lms_screen_student(p_student);
begin
  return coalesce((select jsonb_agg(jsonb_build_object('lesson_id', n.lesson_id, 'minutes', n.minutes, 'reason', n.reason) order by n.created_at)
                   from student_late_notices n join lessons l on l.id = n.lesson_id
                   where n.student_id = v_student and l.ends_at > now()), '[]'::jsonb);
end $$;
revoke all on function student_late_notices(uuid) from public, anon;
grant execute on function student_late_notices(uuid) to authenticated;
