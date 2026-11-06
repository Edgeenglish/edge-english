-- =====================================================================
-- 4310 ⑤ 기존 Google Sheets 'Student Info' 이전 — 학생별 비교·승인 (H26(44) ⑤ B안)
--  - 시트는 읽기 전용: Claude 가 Google Sheets 커넥터로 강사별 Class Record 'Student Info' 탭을 읽어 이 표(sheet_student_info)에 넣는다 (시트는 절대 고치지 않음)
--  - 운영진 화면 '시트 Student Info 비교': 학생별로 시트 값 ↔ LMS 값을 나란히 보여 주고, 대표가 체크한 칸만 admin_student_update 로 반영 (기존 LMS 값 덮어쓰기 없음)
--  - 자기소개는 원문 그대로(7개로 나누지 않음), 예전 레벨(A2/B1 등)은 level_note(참고), 일정·회차·기간은 LMS 가 원본이라 참고로만 보여 줌
--  - 학생 짝: 한국 이름이 같으면 자동 제안, 아니면 운영진이 고름 (admin_sheet_row_match). 반영 끝나면 admin_sheet_row_done
--  지우는 문장 없음. 다시 실행해도 같은 결과
-- =====================================================================

create table if not exists sheet_student_info (
  id uuid primary key default gen_random_uuid(),
  sheet_name text not null,            -- 예: 'Benny_Class record'
  row_no integer not null,             -- 시트의 줄 번호 (머리글 다음부터 2)
  enrollment_status text,              -- 시트 'Enrollment' (Active/Completed)
  enrolled_classes text,
  rollover_classes text,
  student_name text,
  preferred_name text,
  residence text,
  self_intro text,
  gender_age text,
  email text,
  level text,
  class_type text,
  correction_pref text,
  class_duration text,
  days_kst text,
  time_kst text,
  days_local text,
  time_local text,
  docs_link text,
  course_period text,
  start_date text,
  end_date text,
  extended_end text,
  student_id uuid references students(id),   -- 운영진이 고른(또는 자동 제안을 확인한) LMS 학생
  matched_by uuid,
  matched_at timestamptz,
  done_at timestamptz,                 -- 반영(또는 '반영 안 함') 끝
  done_by uuid,
  done_note text,
  imported_at timestamptz not null default now(),
  unique (sheet_name, row_no)
);
alter table sheet_student_info enable row level security;
do $$ begin
  if not exists (select 1 from pg_policies where tablename = 'sheet_student_info' and policyname = 'admin_read') then
    create policy admin_read on sheet_student_info for select to authenticated using (is_admin());
  end if;
  if not exists (select 1 from pg_trigger where tgname = 'sheet_student_info_audit') then
    create trigger sheet_student_info_audit after insert or update on sheet_student_info for each row execute function write_audit();
  end if;
end $$;
revoke all on sheet_student_info from public, anon;
grant select on sheet_student_info to authenticated;

-- 운영진: 시트 줄 전체 + LMS 학생 자동 제안(한국 이름 같음 → 'name_ko', 영문 이름 포함 → 'name_en')
create or replace function admin_sheet_rows()
returns jsonb
language sql stable security definer set search_path = public as $$
  select case when not is_admin() then null else coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', r.id, 'sheet', r.sheet_name, 'row_no', r.row_no, 'status', r.enrollment_status,
      'enrolled_classes', r.enrolled_classes, 'rollover_classes', r.rollover_classes,
      'student_name', r.student_name, 'preferred_name', r.preferred_name, 'residence', r.residence, 'self_intro', r.self_intro,
      'gender_age', r.gender_age, 'email', r.email, 'level', r.level, 'class_type', r.class_type, 'correction_pref', r.correction_pref,
      'class_duration', r.class_duration, 'days_kst', r.days_kst, 'time_kst', r.time_kst, 'days_local', r.days_local, 'time_local', r.time_local,
      'docs_link', r.docs_link, 'course_period', r.course_period, 'start_date', r.start_date, 'end_date', r.end_date, 'extended_end', r.extended_end,
      'student_id', r.student_id, 'matched_at', r.matched_at, 'done_at', r.done_at, 'done_note', r.done_note, 'imported_at', r.imported_at,
      'suggest', case when r.student_id is not null then null else (
        select jsonb_build_object('student_id', s.id, 'how', m.how)
        from (
          select s2.id, 'name_ko' as how, 1 as pri from students s2 where s2.name_ko = trim(coalesce(r.student_name, ''))
          union all
          select s2.id, 'name_en', 2 from students s2
          where trim(coalesce(r.student_name, '')) <> '' and (lower(s2.name_en) = lower(trim(r.student_name))
                 or lower(replace(s2.name_en, ' ', '')) = lower(replace(regexp_replace(r.student_name, '\s*\(.*\)', ''), ' ', '')))
        ) m join students s on s.id = m.id order by m.pri limit 1) end)
      order by r.sheet_name, r.row_no)
    from sheet_student_info r), '[]'::jsonb) end
$$;
revoke all on function admin_sheet_rows() from public, anon;
grant execute on function admin_sheet_rows() to authenticated;

-- 짝 정하기 / 풀기 (p_student null 이면 풀기)
create or replace function admin_sheet_row_match(p_row uuid, p_student uuid)
returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception '운영자(추가 인증 완료)만 처리할 수 있습니다.' using errcode = '42501'; end if;
  if p_student is not null and not exists (select 1 from students where id = p_student) then raise exception '학생을 찾을 수 없습니다.'; end if;
  perform set_config('app.actor_id', auth.uid()::text, true);
  perform set_config('app.actor_via', 'admin_sheet_row_match', true);
  update sheet_student_info set student_id = p_student, matched_by = case when p_student is null then null else auth.uid() end,
         matched_at = case when p_student is null then null else now() end, done_at = null, done_by = null, done_note = null
  where id = p_row;
  if not found then raise exception '시트 줄을 찾을 수 없습니다.'; end if;
  return jsonb_build_object('ok', true);
end $$;
revoke all on function admin_sheet_row_match(uuid, uuid) from public, anon;
grant execute on function admin_sheet_row_match(uuid, uuid) to authenticated;

-- 반영 끝 표시 (실제 값 반영은 admin_student_update 로 — 체크한 칸만). p_note: '반영 3칸' / '반영 안 함' 등. p_undo 로 되돌림
create or replace function admin_sheet_row_done(p_row uuid, p_note text, p_undo boolean default false)
returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception '운영자(추가 인증 완료)만 처리할 수 있습니다.' using errcode = '42501'; end if;
  perform set_config('app.actor_id', auth.uid()::text, true);
  perform set_config('app.actor_via', 'admin_sheet_row_done', true);
  update sheet_student_info set done_at = case when p_undo then null else now() end, done_by = case when p_undo then null else auth.uid() end,
         done_note = case when p_undo then null else nullif(trim(coalesce(p_note, '')), '') end
  where id = p_row;
  if not found then raise exception '시트 줄을 찾을 수 없습니다.'; end if;
  return jsonb_build_object('ok', true);
end $$;
revoke all on function admin_sheet_row_done(uuid, text, boolean) from public, anon;
grant execute on function admin_sheet_row_done(uuid, text, boolean) to authenticated;
