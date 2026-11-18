-- 학생 지각 알림 강사 메일에 수업 시간 줄 (대표 11/18 '시스템에 넣어', H26(216))
-- 'Class: Thu, 19 Nov 1:30 AM *Manila Time* / 2:30 AM *KST*' — 강사 거주지 시간 먼저, 한국 시간 뒤 (lms_mail_en_at). 나머지는 그대로
-- 되돌리기: 20261113120000 의 student_late_notice 정의 다시 실행
create or replace function student_late_notice(p_student uuid, p_lesson uuid, p_minutes integer, p_reason text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_student uuid := lms_screen_student(p_student);
  l lessons;
  st students;
  v_tz text;
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
  select coalesce(nullif(t.timezone, ''), 'Asia/Seoul') into v_tz from tutors t where t.id = l.tutor_id;
  v_reason := case p_reason when 'work_late' then 'Work is running late.' when 'traffic' then 'I''m stuck in traffic.'
                            when 'transit' then 'Public transportation is delayed.' when 'unexpected' then 'Something unexpected came up.' end;
  v_x := case when p_minutes = 20 then '20 or more' else p_minutes::text end;
  v_paras := array[
    'Student Running Late – ' || lms_student_en(st),
    lms_student_en(st) || ' has reported that they may be approximately *' || v_x || '* minutes late.'
      || E'\nClass: ' || lms_mail_en_at(l.starts_at, coalesce(v_tz, 'Asia/Seoul'))
      || case when v_reason is null then '' else E'\nReason: ' || v_reason end,
    '*Please join the class on time and stay until the scheduled end time*, as the student may arrive earlier than expected.'];
  perform lms_tutor_update_add(l.tutor_id, v_student, 'student_late',
    jsonb_build_object('to', l.starts_at, 'minutes', p_minutes, 'reason', p_reason),
    l.ends_at, 'student_late:' || p_lesson,
    'Student Running Late – ' || lms_student_en(st), v_paras);
  return jsonb_build_object('repeated', false);
end $$;
