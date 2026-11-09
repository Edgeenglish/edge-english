-- 학생 시간대 자동 확인 (정책 원본 H26(119), 대표 2026-11-09)
-- - 시간대 설정은 하나(students.timezone). 학생이 [○○ 시간으로 보기]·'내 정보'에서 바꾸면 화면·메일·카톡 안내가 모두 따름. 수업 시각은 안 바뀜
-- - [그대로]를 누르면 그 기기 시간대를 students.tz_kept_device 에 기억 → 기기 시간대가 다른 값으로 바뀔 때만 다시 물음 (마지막 답만)
-- - 바뀐 내역은 학생 변경 이력(student_profile_edits, 운영자 학생 상세 '정보 수정 기록')에만. 운영자 할 일 카드 없음
-- 데이터를 지우거나 덮어쓰는 명령 없음: 칸 하나 추가 + 이력 표의 역할 목록에 'student' 추가 + 새 함수

alter table students add column if not exists tz_kept_device text;

-- 학생 본인이 바꾼 기록도 남기도록 역할에 'student' 추가 (기존 행은 admin·tutor 그대로)
alter table student_profile_edits drop constraint if exists student_profile_edits_edited_role_check;
alter table student_profile_edits add constraint student_profile_edits_edited_role_check check (edited_role in ('admin', 'tutor', 'student'));

-- 읽기(인자 없음) · 시간대 바꾸기(p_set) · [그대로] 기억(p_keep). 학생 본인·운영자(대신) 같은 함수
create or replace function student_timezone(p_student uuid, p_set text default null, p_keep text default null)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_student uuid := lms_screen_student(p_student);
  v_admin boolean := is_admin();
  st students;
begin
  select * into st from students where id = v_student;
  if p_set is not null then
    if p_set !~ '^[A-Za-z_]+/[A-Za-z_/+-]+$' or not is_valid_timezone(p_set) then
      raise exception '알 수 없는 시간대예요: %', p_set;
    end if;
    if p_set is distinct from st.timezone then
      perform set_config('app.actor_id', auth.uid()::text, true);
      perform set_config('app.actor_via', case when v_admin then 'admin_for_student' else 'student' end, true);
      update students set timezone = p_set where id = v_student;
      perform lms_profile_edit(v_student, 'timezone', st.timezone, p_set,
                               case when v_admin then 'admin' else 'student' end, 'student_timezone');
    end if;
  elsif p_keep is not null and p_keep is distinct from st.tz_kept_device then
    perform set_config('app.actor_id', auth.uid()::text, true);
    perform set_config('app.actor_via', case when v_admin then 'admin_for_student' else 'student' end, true);
    update students set tz_kept_device = p_keep where id = v_student;
  end if;
  select * into st from students where id = v_student;
  return jsonb_build_object('timezone', coalesce(st.timezone, 'Asia/Seoul'), 'kept', st.tz_kept_device);
end $$;
revoke all on function student_timezone(uuid, text, text) from public, anon;
grant execute on function student_timezone(uuid, text, text) to authenticated;
