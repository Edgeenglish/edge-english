-- 학생 '내 정보' 이메일 알림 설정(정규/보강 켬·끔) 저장만 — 2900 중 설정 부분 (11/11, 시험 DB 적용)
-- 수업 알림 메일 발송(2900 lms_send_lesson_reminders·예약 실행)은 넣지 않음: 대표 결정 대기(H26(86) ⑥). 이 파일로 메일은 나가지 않음
-- 메일 받는 주소 확인은 자동 안내와 같은 기준(students.email 없으면 로그인 이메일, lms_notice_recipient_email)
alter table students add column if not exists remind_regular boolean not null default true;
alter table students add column if not exists remind_makeup boolean not null default true;
create or replace function student_reminders(p_student uuid, p_regular boolean default null, p_makeup boolean default null)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_student uuid := lms_screen_student(p_student);
  st students;
begin
  if p_regular is not null or p_makeup is not null then
    perform set_config('app.actor_id', auth.uid()::text, true);
    perform set_config('app.actor_via', case when is_admin() then 'admin_for_student' else 'student' end, true);
    update students set remind_regular = coalesce(p_regular, remind_regular), remind_makeup = coalesce(p_makeup, remind_makeup)
    where id = v_student;
  end if;
  select * into st from students where id = v_student;
  return jsonb_build_object('regular', st.remind_regular, 'makeup', st.remind_makeup, 'has_email', lms_notice_recipient_email('student', v_student) is not null);
end $$;
revoke all on function student_reminders(uuid, boolean, boolean) from public, anon;
grant execute on function student_reminders(uuid, boolean, boolean) to authenticated;
