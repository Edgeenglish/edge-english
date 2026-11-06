-- =====================================================================
-- 4600. 첫 수업 후 강사 To-do · 실제 Class Style (2026-11-06 대표 요청, 정책 원본 H26(67)·(68)·(71))
--  ① 첫 수업이 Held 로 기록되면 강사 Home 에 학생별 First Lesson Follow-up:
--     1 English Level · 2 Wants to Improve · 3 Class Style(교재는 조건부) · 4 Class Record(첫 수업 기록과 자동 연결)
--  ② 완료는 체크박스가 아니라 저장된 값으로 판정: level_by(평가 기록) · improve_tutor_at · tutor_class_style_at · 첫 Held 수업의 기록
--  ③ 학생의 원래 답(운영진이 입력한 job·hobbies·interests·hopes·correction·class_style 7항목)은 건드리지 않음.
--     강사가 확인한 실제 수업 방식은 새 칸(tutor_class_style·tutor_class_style_mix·tutor_materials_note)에 따로
--  ④ 교재는 students.textbook 그대로 (운영진 화면 '교재' 와 같은 칸). 교재 목록은 홈페이지 교재 데이터를 화면이 가짐
--  ⑤ 권한: 정규 담당 강사 본인 또는 운영자(TOTP, ?tutor= 강사 문맥). 대체강사는 못 씀
--  다시 실행해도 같은 결과. 지우는 문장 없음
-- =====================================================================
alter table students
  add column if not exists tutor_class_style text,              -- conversation · textbook · student_materials · mixed
  add column if not exists tutor_class_style_mix text[],        -- mixed 일 때 구성: conversation · textbook · student_materials · other
  add column if not exists tutor_materials_note text,           -- 학생 제공 자료 이름·종류 (선택)
  add column if not exists tutor_class_style_at timestamptz,    -- 강사가 확인·저장한 시각 (같은 값이어도 '확인함')
  add column if not exists tutor_class_style_by uuid,
  add column if not exists improve_tutor_at timestamptz,        -- 강사가 첫 수업에서 직접 물어 적은 시각
  add column if not exists improve_tutor_by uuid;
do $$ begin
  alter table students add constraint students_tutor_class_style_check
    check (tutor_class_style is null or tutor_class_style in ('conversation', 'textbook', 'student_materials', 'mixed'));
exception when duplicate_object then null; end $$;

-- 이 강사가 이 학생과 처음 '진행한(Held)' 수업 — 출결 규칙 outcome = held (정상·강사 지각·보강 완료·대타 진행)
create or replace function lms_first_held_lesson(p_tutor uuid, p_student uuid)
returns lessons
language sql stable security definer set search_path = public as $$
  select l.* from lessons l join class_status_rules r on r.status = l.class_status
  where l.student_id = p_student and l.tutor_id = p_tutor and l.state = 'done' and l.voided_at is null and r.outcome = 'held'
  order by l.starts_at limit 1
$$;
revoke all on function lms_first_held_lesson(uuid, uuid) from public, anon, authenticated;

-- 학생 한 명의 To-do 상태. 첫 Held 수업이 없으면 null (수업 전에는 To-do 없음)
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
  return jsonb_build_object(
    'first_lesson', jsonb_build_object('id', l.id, 'starts_at', l.starts_at, 'status', l.class_status, 'topics', cr.covered_topics, 'recorded_at', cr.first_submitted_at),
    'done', jsonb_build_object('level', d_level, 'improve', d_improve, 'style', d_style, 'record', true),
    'pending', (case when d_level then 0 else 1 end) + (case when d_improve then 0 else 1 end) + (case when d_style then 0 else 1 end));
end $$;
revoke all on function lms_first_lesson_todo(uuid, uuid) from public, anon, authenticated;

-- 강사 Home To-do: 정규 담당 학생 중 첫 Held 수업이 있고 아직 덜 한 항목이 있는 학생 (강사 본인 또는 운영자가 고른 강사)
create or replace function tutor_first_lesson_todos(p_tutor uuid default null)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  me uuid := lms_screen_tutor(p_tutor);
begin
  return coalesce((
    select jsonb_agg(jsonb_build_object('student_id', s.id, 'student', lms_tutor_student_label(s.name_en, s.display_name),
             'first_lesson_at', t.j -> 'first_lesson' -> 'starts_at', 'pending', t.j -> 'pending', 'done', t.j -> 'done')
             order by (t.j -> 'first_lesson' ->> 'starts_at')::timestamptz, s.name_en)
    from students s
    cross join lateral (select lms_first_lesson_todo(me, s.id) as j) t
    where lms_tutor_student_access(me, s.id) = 'regular' and t.j is not null and (t.j ->> 'pending')::int > 0), '[]'::jsonb);
end $$;
revoke all on function tutor_first_lesson_todos(uuid) from public, anon;
grant execute on function tutor_first_lesson_todos(uuid) to authenticated;

-- 강사 입력 저장 (한 번에 한 항목씩 또는 여러 항목). 같은 값을 다시 골라도 '확인함'으로 기록
--  p 키: level · improve · class_style · class_style_mix(배열) · textbook · materials_note
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
    if k not in ('level', 'improve', 'class_style', 'class_style_mix', 'textbook', 'materials_note') then
      raise exception 'Field % cannot be changed here.', k using errcode = '42501';
    end if;
  end loop;
  perform set_config('app.actor_id', auth.uid()::text, true);
  perform set_config('app.actor_via', 'tutor_first_lesson_save', true);

  -- 1 English Level: 바뀌지 않아도 평가한 사람·시각을 기록 (lms_student_apply 는 바뀔 때만 기록하므로 따로)
  if p ? 'level' then
    v := nullif(trim(coalesce(p ->> 'level', '')), '');
    if v is null then raise exception 'Please choose a level.' using errcode = '22023'; end if;
    if v not in ('Beginner', 'Pre-Intermediate', 'Intermediate', 'Advanced') then raise exception 'Level must be one of the rubric levels.' using errcode = '22023'; end if;
    perform lms_profile_edit(p_student, 'level', s.level, v, v_role, 'tutor_first_lesson_save');
    update students set level = v, level_by = auth.uid(), level_at = now() where id = p_student;
  end if;

  -- 2 Wants to improve: 강사가 첫 수업에서 직접 물어 적음 (운영진 사전 입력이 있어도 강사가 확인해 적어야 완료)
  if p ? 'improve' then
    v := nullif(trim(coalesce(p ->> 'improve', '')), '');
    if v is null then raise exception 'Please write what the student wants to improve.' using errcode = '22023'; end if;
    perform lms_profile_edit(p_student, 'improve', s.improve, v, v_role, 'tutor_first_lesson_save');
    update students set improve = v, improve_tutor_at = now(), improve_tutor_by = auth.uid() where id = p_student;
  end if;

  -- 3 Class Style (실제 수업 방식) — 학생의 원래 답 class_style·class_style_note 는 건드리지 않음
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
    -- 교재를 안 쓰는 방식으로 바꿔도 교재 칸은 지우지 않음 (나중에 다시 쓸 수 있음)
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
  return coalesce(lms_first_lesson_todo(me, p_student), jsonb_build_object('first_lesson', null, 'done', null, 'pending', null));
end $$;
revoke all on function tutor_first_lesson_save(uuid, jsonb, uuid) from public, anon;
grant execute on function tutor_first_lesson_save(uuid, jsonb, uuid) to authenticated;

-- 프로필 JSON 에 강사 확인 값 덧붙이기 (강사 화면·운영진 상세 둘 다)
create or replace function lms_followup_fields(p_student uuid)
returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_strip_nulls(jsonb_build_object(
    'tutor_class_style', s.tutor_class_style, 'tutor_class_style_mix', to_jsonb(s.tutor_class_style_mix), 'tutor_materials_note', s.tutor_materials_note,
    'tutor_class_style_at', s.tutor_class_style_at, 'improve_tutor_at', s.improve_tutor_at,
    'tutor_class_style_by', case when s.tutor_class_style_by is null then null else coalesce(
        (select t.name from app_users u join tutors t on t.id = u.tutor_id where u.auth_user_id = s.tutor_class_style_by),
        (select case when u.role = 'admin' then 'Edge English' end from app_users u where u.auth_user_id = s.tutor_class_style_by)) end))
  from students s where s.id = p_student
$$;
revoke all on function lms_followup_fields(uuid) from public, anon, authenticated;

-- 강사용 Student profile: 4500 판 그대로 + student 에 강사 확인 값 + followup(To-do 상태, 첫 Held 수업 없으면 null)
create or replace function tutor_student_profile(p_student uuid, p_tutor uuid)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  me uuid := case when is_admin() and p_tutor is not null then lms_screen_tutor(p_tutor) else my_tutor_id() end;
  v_access text;
  j jsonb;
  v_unbooked integer;
begin
  if is_admin() then
    v_access := 'regular';   -- 운영자가 강사 화면을 대신 볼 때(?tutor=)는 담당 강사와 같은 범위
  else
    if me is null then raise exception 'Please sign in with your tutor account.' using errcode = '42501'; end if;
    v_access := lms_tutor_student_access(me, p_student);
    if v_access is null then raise exception 'This student is not assigned to you.' using errcode = '42501'; end if;
  end if;
  j := lms_student_profile_json(p_student, v_access);
  if v_access = 'substitute' then
    j := j - 'upcoming' - 'enrollment' || jsonb_build_object(
      'upcoming', (select coalesce(jsonb_agg(x) filter (where (x ->> 'tutor_id')::uuid = me), '[]'::jsonb) from jsonb_array_elements(j -> 'upcoming') x),
      'enrollment', case when j -> 'enrollment' is null or j -> 'enrollment' = 'null'::jsonb then null else
        jsonb_build_object('duration_min', j -> 'enrollment' -> 'duration_min', 'weekly_count', j -> 'enrollment' -> 'weekly_count',
                           'final_end_date', j -> 'enrollment' -> 'final_end_date') end);
  elsif j -> 'enrollment' is not null and j -> 'enrollment' <> 'null'::jsonb then
    -- 날짜 안 잡은 보강권(취소 수업·시트 미예약 보강·보상권) — student_screen makeup_rights 와 같은 기준 (4500)
    select count(*) into v_unbooked from (
      select 1 from lessons l where l.enrollment_id = (j -> 'enrollment' ->> 'id')::uuid and l.voided_at is null
        and (lms_grants_makeup(l.class_status) or l.class_status = 'Tutor long-term leave')
        and not exists (select 1 from lessons x where x.makeup_of = l.id and x.voided_at is null)
      union all
      select 1 from migrated_items m where m.enrollment_id = (j -> 'enrollment' ->> 'id')::uuid and m.kind = 'makeup_open'
      union all
      select 1 from compensations c where c.enrollment_id = (j -> 'enrollment' ->> 'id')::uuid and c.status = 'available'
        and lms_comp_use_until(c.enrollment_id) >= (now() at time zone 'Asia/Seoul')::date) q;
    j := jsonb_set(j, '{enrollment,left_unbooked}', to_jsonb(coalesce(v_unbooked, 0)));
  end if;
  j := jsonb_set(j, '{student}', (j -> 'student') || lms_followup_fields(p_student));
  return j || jsonb_build_object('me', jsonb_build_object('id', me, 'timezone', (select timezone from tutors where id = me)),
                                 'followup', case when v_access = 'regular' then lms_first_lesson_todo(me, p_student) end);
end $$;
revoke all on function tutor_student_profile(uuid, uuid) from public, anon;
grant execute on function tutor_student_profile(uuid, uuid) to authenticated;

-- 운영진 학생 상세: 4300 판 그대로 + student 에 강사 확인 값
create or replace function admin_student_detail(p_student uuid)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  j jsonb;
  v_login jsonb;
begin
  if not is_admin() then raise exception '운영자(추가 인증 완료)만 볼 수 있습니다.' using errcode = '42501'; end if;
  j := lms_student_profile_json(p_student, 'admin');
  j := jsonb_set(j, '{student}', (j -> 'student') || lms_followup_fields(p_student));
  if to_regclass('auth.users') is not null then
    execute 'select jsonb_build_object(''email'', a.email) from app_users u join auth.users a on a.id = u.auth_user_id where u.student_id = $1 limit 1' into v_login using p_student;
  end if;
  return j || jsonb_build_object(
    'enrollments', coalesce((
      select jsonb_agg(jsonb_build_object('id', e.id, 'seq', e.seq, 'status', e.status, 'weeks', e.weeks, 'legacy_label', e.legacy_label,
               'weekly_count', e.weekly_count, 'duration_min', e.duration_min, 'start_date', e.start_date, 'final_end_date', e.final_end_date,
               'lessons_purchased', e.lessons_purchased, 'lessons_carried_in', e.lessons_carried_in, 'amount_due', e.amount_due,
               'payments', coalesce((select jsonb_agg(jsonb_build_object('on', p.received_on, 'method', p.method, 'amount', p.amount_received,
                                       'confirmed', p.confirmed_at is not null) order by p.received_on) from payments p where p.enrollment_id = e.id), '[]'::jsonb))
               order by e.seq desc)
      from enrollments e where e.student_id = p_student), '[]'::jsonb),
    'changes', coalesce((
      select jsonb_agg(jsonb_build_object('id', rc.id, 'effective_from', rc.effective_from, 'old_slots', rc.old_slots, 'new_slots', rc.new_slots,
               'moved', rc.moved, 'kept', rc.kept, 'reason', rc.reason, 'at', rc.created_at, 'tutor', t.name, 'tutor_tz', t.timezone,
               'student_sent_at', rc.student_sent_at, 'tutor_sent_at', rc.tutor_sent_at) order by rc.created_at desc)
      from regular_changes rc join tutors t on t.id = rc.tutor_id where rc.student_id = p_student), '[]'::jsonb),
    'edits', coalesce((
      select jsonb_agg(jsonb_build_object('field', x.field, 'old', x.old_value, 'new', x.new_value, 'role', x.edited_role, 'at', x.created_at,
               'by', coalesce((select t.name from app_users u join tutors t on t.id = u.tutor_id where u.auth_user_id = x.edited_by), '운영진')) order by x.created_at desc)
      from (select * from student_profile_edits where student_id = p_student order by created_at desc limit 50) x), '[]'::jsonb),
    'recent', coalesce((
      select jsonb_agg(jsonb_build_object('id', l.id, 'kind', l.kind, 'starts_at', l.starts_at, 'state', l.state, 'class_status', l.class_status,
               'tutor', t.name, 'tutor_tz', t.timezone) order by l.starts_at desc)
      from (select * from lessons where student_id = p_student and starts_at <= now() and voided_at is null order by starts_at desc limit 5) l
      join tutors t on t.id = l.tutor_id), '[]'::jsonb),
    'login', v_login);
end $$;
revoke all on function admin_student_detail(uuid) from public, anon;
grant execute on function admin_student_detail(uuid) to authenticated;
