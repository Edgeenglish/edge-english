-- 나의 누적 학습 시간에 LMS 이전(Google 시트 Class Record) 실제 진행 수업 포함 (11/11 대표 확정)
--  - 시트 원본은 건드리지 않고, 학생별 합계만 한 줄씩 저장 (수업 기록을 새로 만들지 않음 → 기존 LMS 수업 기록과 섞이지 않음)
--  - through_date = 이 날짜 '전' 시트 기록만 합산함 (= 그 학생의 첫 LMS 수업 날짜). LMS 수업은 이 날짜부터만 더함 → 같은 수업 두 번 안 셈
--  - 한 학생에 한 줄(primary key) → 다시 넣어도 늘어나지 않음. 값 바꿀 때는 운영자가 새 집계로 고침(바꾼 기록 남김)
create table if not exists legacy_learned_minutes (
  student_id uuid primary key references students(id),
  lessons integer not null check (lessons >= 0),
  minutes integer not null check (minutes >= 0),
  through_date date not null,
  source text not null,
  created_at timestamptz not null default now()
);
alter table legacy_learned_minutes enable row level security;

create or replace function student_my_info(p_student uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_student uuid := lms_screen_student(p_student);
  st students;
  lg legacy_learned_minutes;
  v_book text; v_mat text; v_style text; v_parts text[]; v_m text;
begin
  select * into st from students where id = v_student;
  select * into lg from legacy_learned_minutes where student_id = v_student;
  v_book := case when nullif(trim(coalesce(st.textbook, '')), '') is not null then ' · ' || st.textbook else '' end;
  v_mat := case when nullif(trim(coalesce(st.tutor_materials_note, '')), '') is not null then ' · ' || st.tutor_materials_note else '' end;
  v_style := case st.tutor_class_style
    when 'conversation' then '회화'
    when 'textbook' then '교재 중심' || v_book
    when 'student_materials' then '수강생 제공 자료' || v_mat
    when 'mixed' then '혼합' end;
  if st.tutor_class_style = 'mixed' then
    v_parts := array[]::text[];
    foreach v_m in array coalesce(st.tutor_class_style_mix, array[]::text[]) loop
      v_parts := v_parts || (case v_m when 'conversation' then '회화' when 'textbook' then '교재' || v_book
                                       when 'student_materials' then '수강생 자료' || v_mat else '기타' end);
    end loop;
    v_style := '혼합: ' || array_to_string(v_parts, ' + ');
  end if;
  return jsonb_build_object(
    'level', case when st.level_by is not null then st.level end,
    'goal', case when st.improve_tutor_at is not null then nullif(trim(coalesce(st.improve, '')), '') end,
    'style', case when st.tutor_class_style_at is not null then v_style end,
    'note_url', case when lms_is_google_doc_url(st.class_note_url) then st.class_note_url end,
    'learned_min', coalesce(lg.minutes, 0) + coalesce((
      select sum(extract(epoch from (l.ends_at - l.starts_at)) / 60)::int
      from lessons l join class_status_rules r on r.status = l.class_status
      where l.student_id = v_student and l.voided_at is null and l.state = 'done' and r.outcome = 'held'
        and (lg.through_date is null or (l.starts_at at time zone 'Asia/Seoul')::date >= lg.through_date)), 0));
end $$;
revoke all on function student_my_info(uuid) from public, anon;
grant execute on function student_my_info(uuid) to authenticated;
