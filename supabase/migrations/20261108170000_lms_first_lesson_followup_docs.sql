-- =====================================================================
-- 4602. First Lesson Follow-up 개선 (2026-11-08 대표 승인, 시안 v3 https://claude.ai/artifact/VbbTLPge15MRpQjrce6DRx)
--  ① 4번째 항목 Class Notes(Google Docs): 강사가 만든 문서 링크를 students.class_note_url(운영자 화면 'Google Docs' 와 같은 칸)에 저장
--     - Google Docs 문서 주소(https://docs.google.com/document/…)만 받음
--     - 운영진이 이미 넣어 둔 Docs 링크가 있으면 그대로 완료 (다시 입력 없음)
--  ② To-do 는 Level · Wants to Improve · Class Style · Class Notes 4개가 모두 저장돼야 사라짐
--     (Class Record 는 To-do 가 첫 수업 기록 뒤에만 생기므로 항목에서 뺌 — JSON 'record' 는 예전 화면 호환용으로 남김)
--  ③ 예외: 기능 시작일 전 첫 수업이지만 To-do 를 띄울 학생 (대표 지시 1건 — 운영 DB 의 11/6 Maria 첫 수업 학생)
--     다른 기존 학생에게는 과거 To-do 를 만들지 않음
--  다시 실행해도 같은 결과. 지우는 문장 없음
-- =====================================================================

create table if not exists first_lesson_followup_exceptions (
  student_id uuid primary key references students(id),
  note text,
  created_at timestamptz not null default now()
);
alter table first_lesson_followup_exceptions enable row level security;
revoke all on first_lesson_followup_exceptions from anon, authenticated;

-- 운영 DB 에만 있는 학생 (STU-0013) — 시험 DB 에는 이 id 가 없어 아무것도 넣지 않음
insert into first_lesson_followup_exceptions (student_id, note)
select s.id, '대표 11/8: 11/6 Maria 첫 수업 — 기능 시작일(11/7) 전이지만 To-do 표시'
from students s where s.id = '1c9e446b-9ef4-4f83-a054-357c763fae50'
on conflict (student_id) do nothing;

create or replace function lms_is_google_doc_url(p text)
returns boolean
language sql immutable set search_path = public as $$
  select coalesce(trim(p) ~ '^https://docs\.google\.com/document/(u/[0-9]+/)?d/[A-Za-z0-9_-]{10,}', false)
$$;

-- 첫 Held 수업: 새로 시작한 학생 또는 예외 학생
create or replace function lms_first_held_lesson(p_tutor uuid, p_student uuid)
returns lessons
language sql stable security definer set search_path = public as $$
  select l.* from lessons l
  join class_status_rules r on r.status = l.class_status
  join enrollments e on e.id = l.enrollment_id
  where l.student_id = p_student and l.tutor_id = p_tutor and l.state = 'done' and l.voided_at is null and r.outcome = 'held'
    and (
      exists (select 1 from first_lesson_followup_exceptions x where x.student_id = p_student)
      or (lms_first_lesson_followup_since() is not null
        and e.start_date >= lms_first_lesson_followup_since()
        and not exists (select 1 from lessons x where x.student_id = p_student and x.state = 'done' and x.voided_at is null
                        and (x.starts_at at time zone 'Asia/Seoul')::date < lms_first_lesson_followup_since())))
  order by l.starts_at limit 1
$$;
revoke all on function lms_first_held_lesson(uuid, uuid) from public, anon, authenticated;

create or replace function lms_first_lesson_todo(p_tutor uuid, p_student uuid)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  s students;
  l lessons;
  cr class_records;
  d_level boolean;
  d_improve boolean;
  d_style boolean;
  d_docs boolean;
  v_needs_book boolean;
begin
  if p_tutor is null then return null; end if;
  select * into s from students where id = p_student;
  if not found then return null; end if;
  l := lms_first_held_lesson(p_tutor, p_student);
  if l.id is null then return null; end if;
  select * into cr from class_records where lesson_id = l.id;
  d_level := s.level is not null and s.level_by is not null;
  d_improve := nullif(trim(coalesce(s.improve, '')), '') is not null and s.improve_tutor_at is not null;
  v_needs_book := s.tutor_class_style = 'textbook' or (s.tutor_class_style = 'mixed' and 'textbook' = any(coalesce(s.tutor_class_style_mix, '{}')));
  d_style := s.tutor_class_style is not null and s.tutor_class_style_at is not null
    and (s.tutor_class_style <> 'mixed' or coalesce(array_length(s.tutor_class_style_mix, 1), 0) > 0)
    and (not v_needs_book or nullif(trim(coalesce(s.textbook, '')), '') is not null);
  d_docs := lms_is_google_doc_url(s.class_note_url);
  return jsonb_build_object(
    'first_lesson', jsonb_build_object('id', l.id, 'starts_at', l.starts_at, 'status', l.class_status, 'topics', cr.covered_topics, 'recorded_at', cr.first_submitted_at),
    'done', jsonb_build_object('level', d_level, 'improve', d_improve, 'style', d_style, 'docs', d_docs, 'record', true),
    'pending', (case when d_level then 0 else 1 end) + (case when d_improve then 0 else 1 end) + (case when d_style then 0 else 1 end) + (case when d_docs then 0 else 1 end));
end $$;
revoke all on function lms_first_lesson_todo(uuid, uuid) from public, anon, authenticated;

-- 강사 입력 저장 — p 키: level · improve · class_style · class_style_mix(배열) · textbook · materials_note · class_note_url
create or replace function tutor_first_lesson_save(p_student uuid, p jsonb, p_tutor uuid default null)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  me uuid := case when is_admin() and p_tutor is not null then lms_screen_tutor(p_tutor) else my_tutor_id() end;
  s students;
  k text;
  v text;
  v_style text;
  v_mix text[];
  v_role text := case when is_admin() and my_tutor_id() is null then 'admin' else 'tutor' end;
begin
  if not is_admin() then
    if me is null or lms_tutor_student_access(me, p_student) is distinct from 'regular' then
      raise exception 'Only the student''s regular tutor can edit this.' using errcode = '42501';
    end if;
  end if;
  select * into s from students where id = p_student for update;
  if not found then raise exception 'Student not found.' using errcode = 'P0002'; end if;
  for k in select jsonb_object_keys(coalesce(p, '{}'::jsonb)) loop
    if k not in ('level', 'improve', 'class_style', 'class_style_mix', 'textbook', 'materials_note', 'class_note_url') then
      raise exception 'Field % cannot be changed here.', k using errcode = '42501';
    end if;
  end loop;
  perform set_config('app.actor_id', auth.uid()::text, true);
  perform set_config('app.actor_via', 'tutor_first_lesson_save', true);

  -- 저장 전에 모든 값을 먼저 검사 (한 칸이 틀리면 아무것도 저장 안 함)
  if p ? 'class_note_url' and not lms_is_google_doc_url(p ->> 'class_note_url') then
    raise exception 'Paste a Google Docs link.' using errcode = '22023';
  end if;

  if p ? 'level' then
    v := nullif(trim(coalesce(p ->> 'level', '')), '');
    if v is null then raise exception 'Please choose a level.' using errcode = '22023'; end if;
    if v not in ('Beginner', 'Pre-Intermediate', 'Intermediate', 'Advanced') then raise exception 'Level must be one of the rubric levels.' using errcode = '22023'; end if;
    perform lms_profile_edit(p_student, 'level', s.level, v, v_role, 'tutor_first_lesson_save');
    update students set level = v, level_by = auth.uid(), level_at = now() where id = p_student;
  end if;

  if p ? 'improve' then
    v := nullif(trim(coalesce(p ->> 'improve', '')), '');
    if v is null then raise exception 'Please write what the student wants to improve.' using errcode = '22023'; end if;
    perform lms_profile_edit(p_student, 'improve', s.improve, v, v_role, 'tutor_first_lesson_save');
    update students set improve = v, improve_tutor_at = now(), improve_tutor_by = auth.uid() where id = p_student;
  end if;

  if p ? 'class_style' then
    v_style := nullif(trim(coalesce(p ->> 'class_style', '')), '');
    if v_style is null or v_style not in ('conversation', 'textbook', 'student_materials', 'mixed') then
      raise exception 'Please choose a class style.' using errcode = '22023';
    end if;
    v_mix := null;
    if v_style = 'mixed' then
      select array_agg(distinct x order by x) into v_mix from jsonb_array_elements_text(coalesce(p -> 'class_style_mix', '[]'::jsonb)) x;
      if coalesce(array_length(v_mix, 1), 0) = 0 then raise exception 'Choose what the mixed class includes.' using errcode = '22023'; end if;
      if exists (select 1 from unnest(v_mix) x where x not in ('conversation', 'textbook', 'student_materials', 'other')) then
        raise exception 'Unknown mix option.' using errcode = '22023';
      end if;
    end if;
    if v_style = 'textbook' or (v_style = 'mixed' and 'textbook' = any(v_mix)) then
      v := case when p ? 'textbook' then nullif(trim(coalesce(p ->> 'textbook', '')), '') else nullif(trim(coalesce(s.textbook, '')), '') end;
      if v is null then raise exception 'Please choose the textbook.' using errcode = '22023'; end if;
      perform lms_profile_edit(p_student, 'textbook', s.textbook, v, v_role, 'tutor_first_lesson_save');
      update students set textbook = v where id = p_student;
    end if;
    if v_style = 'student_materials' or (v_style = 'mixed' and 'student_materials' = any(v_mix)) then
      if p ? 'materials_note' then
        v := nullif(trim(coalesce(p ->> 'materials_note', '')), '');
        perform lms_profile_edit(p_student, 'tutor_materials_note', s.tutor_materials_note, v, v_role, 'tutor_first_lesson_save');
        update students set tutor_materials_note = v where id = p_student;
      end if;
    end if;
    perform lms_profile_edit(p_student, 'tutor_class_style', s.tutor_class_style, v_style, v_role, 'tutor_first_lesson_save');
    perform lms_profile_edit(p_student, 'tutor_class_style_mix', array_to_string(s.tutor_class_style_mix, ','), array_to_string(v_mix, ','), v_role, 'tutor_first_lesson_save');
    update students set tutor_class_style = v_style, tutor_class_style_mix = v_mix, tutor_class_style_at = now(), tutor_class_style_by = auth.uid()
    where id = p_student;
  end if;

  -- 4 Class Notes (Google Docs) — 운영자 화면 'Google Docs' 와 같은 칸
  if p ? 'class_note_url' then
    v := trim(p ->> 'class_note_url');
    perform lms_profile_edit(p_student, 'class_note_url', s.class_note_url, v, v_role, 'tutor_first_lesson_save');
    update students set class_note_url = v where id = p_student;
  end if;
  return coalesce(lms_first_lesson_todo(me, p_student), jsonb_build_object('first_lesson', null, 'done', null, 'pending', null));
end $$;
revoke all on function tutor_first_lesson_save(uuid, jsonb, uuid) from public, anon;
grant execute on function tutor_first_lesson_save(uuid, jsonb, uuid) to authenticated;
