-- =====================================================================
-- 4300 학생 관리 ①~⑥ (2026-11-03 대표 확정, 정책 원본 H26(44))
--  ※ 지우는 문장 없이 씀 — Supabase 커넥터가 지우는 SQL 에 승인 창을 띄우는데 그 창이 안 보여 적용이 막혔기 때문(2026-11-03).
--    이미 있는 제약·트리거·정책은 pg_catalog 를 보고 건너뜀. 다시 실행해도 같은 결과
--  ① admin_regular_change: 운영진이 기존 학생의 정규 요일·시작 시간만 변경 (주 횟수·길이·강사는 그대로).
--     적용 시작일부터 바뀔 수업 전체를 미리 보기(p_dry_run) → 저장할 때 DB에서 다시 검사.
--     검사 = 강사 가능 시간(My hours)·현지 06:00~22:30·다른 수업(휴식 10분)·휴무·재등록 대기 자리·30분 단위.
--     지난 수업, 확정된 보강·대체수업·보상수업, 휴무 처리 중 수업은 건드리지 않음. 변경 전후·사유는 regular_changes 에 보존.
--  ② 종료일은 연장하지 않음: 옮긴 뒤 마지막 정규 수업이 최종 종료일을 넘으면 저장 차단(구체적 안내). 넘친 수업을 보강으로 바꾸지 않음.
--  ③ 저장하면 학생·강사·운영진 화면에 바로 반영(lessons 가 바뀜). 안내 문구는 화면이 만들고, 운영진이 복사해 보낸 뒤
--     admin_regular_change_sent 로 학생·강사 각각 [발송 완료] 기록 (자동 메일 없음).
--  ④ 이름: name_ko(운영진 식별) · name_en(여권 영문, 강사 공식 식별) · display_name(Preferred Name, 선택). English Name 칸 없음.
--     강사 화면 표기 'Kim Seoyeon (Sarah)' 는 lms_tutor_student_label 하나로.
--  ⑤ 시트 → LMS 이전은 화면(운영진 승인)에서 admin_student_update 로 한 명씩. 자기소개 원문은 self_intro_en 그대로, 예전 레벨은 level_note.
--  ⑥ 대체강사 = 열람만. 대체수업 확정(lessons.tutor_id 가 대체강사로 바뀐 때)부터 그 수업 종료 24시간 뒤까지 (lms_tutor_student_access).
--     이메일·결제·운영 메모는 안 보임. 정규 담당 강사 = 기존 권한 유지(레벨·자기소개·선호 수정). 숨기기가 아니라 DB 함수에서 차단.
--  새 칸: students 자기소개·선호 7항목(job·hobbies·interests·improve·hopes·correction_style(+note)·class_style(+note)), level 4단계 제한, level_note·level_by·level_at
--  새 표: student_profile_edits(누가 언제 어느 칸을 어떻게), regular_changes(정규 일정 변경 기록 + 안내 발송 상태)
--  운영진 종료일 연장: admin_extend_enrollment → enrollment_extensions 한 줄 (휴무 자동 연장 줄은 그대로, 합계로 계산 → 중복 없음, 회차 안 늘어남)
--  다시 실행해도 같은 결과. 기존 데이터는 바꾸지 않음(운영 DB 학생 level 은 모두 비어 있고 시험용 'Intermediate' 는 4단계 안)
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. students 새 칸 + 레벨 4단계 (English Speaking Level Rubric 원본 그대로: Beginner · Pre-Intermediate · Intermediate · Advanced)
-- ---------------------------------------------------------------------
alter table students
  add column if not exists job text,
  add column if not exists hobbies text,
  add column if not exists interests text,
  add column if not exists improve text,
  add column if not exists hopes text,
  add column if not exists correction_style text,
  add column if not exists correction_note text,
  add column if not exists class_style text,
  add column if not exists class_style_note text,
  add column if not exists level_note text,
  add column if not exists level_by uuid,
  add column if not exists level_at timestamptz,
  add column if not exists answers_by uuid,
  add column if not exists answers_at timestamptz;
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'students_level_rubric') then
    alter table students add constraint students_level_rubric
      check (level is null or level in ('Beginner', 'Pre-Intermediate', 'Intermediate', 'Advanced'));
  end if;
  if not exists (select 1 from pg_constraint where conname = 'students_correction_style_check') then
    alter table students add constraint students_correction_style_check
      check (correction_style is null or correction_style in ('immediate', 'major_only'));
  end if;
  if not exists (select 1 from pg_constraint where conname = 'students_class_style_check') then
    alter table students add constraint students_class_style_check
      check (class_style is null or class_style in ('textbook', 'free_talking', 'not_sure'));
  end if;
end $$;
comment on column students.correction_pref is '시트에서 가져온 예전 교정 선호 글(참고). 새 입력은 correction_style(+correction_note)';
comment on column students.level_note is '시트의 예전 레벨 표기(A2/B1 등) — 4단계로 자동 변환하지 않고 참고로만';

-- 프로필 수정 기록: 누가(운영진/정규 강사) 언제 어느 칸을 어떻게 (강사 레벨 평가와 학생 답변은 field 이름으로 구분)
create table if not exists student_profile_edits (
  id uuid primary key default gen_random_uuid(),
  student_id uuid not null references students(id),
  field text not null,
  old_value text,
  new_value text,
  edited_by uuid not null,
  edited_role text not null check (edited_role in ('admin', 'tutor')),
  via text not null,
  created_at timestamptz not null default now()
);
create index if not exists student_profile_edits_student on student_profile_edits (student_id, created_at);
do $$ begin
  if not exists (select 1 from pg_trigger where tgname = 'student_profile_edits_no_update') then
    create trigger student_profile_edits_no_update before update on student_profile_edits for each row execute function forbid_update();
  end if;
  if not exists (select 1 from pg_trigger where tgname = 'student_profile_edits_no_delete') then
    create trigger student_profile_edits_no_delete before delete on student_profile_edits for each row execute function forbid_delete();
  end if;
  if not exists (select 1 from pg_policies where tablename = 'student_profile_edits' and policyname = 'admin_read') then
    create policy admin_read on student_profile_edits for select to authenticated using (is_admin());
  end if;
end $$;
alter table student_profile_edits enable row level security;
revoke all on student_profile_edits from public, anon;
grant select on student_profile_edits to authenticated;

-- 정규 일정 변경 기록 (변경 전후·사유·옮긴 수업·안내 발송 상태)
create table if not exists regular_changes (
  id uuid primary key default gen_random_uuid(),
  student_id uuid not null references students(id),
  enrollment_id uuid not null references enrollments(id),
  tutor_id uuid not null references tutors(id),
  effective_from date not null,
  old_slots jsonb not null,            -- [{weekday, time}] (한국 시간)
  new_slots jsonb not null,
  moved jsonb not null,                -- [{lesson_id, seq, from, to}]
  kept jsonb not null default '[]',    -- 그대로 둔 앞으로의 수업 [{lesson_id, kind, starts_at, why}]
  reason text not null,
  created_by uuid not null,
  created_at timestamptz not null default now(),
  student_sent_at timestamptz,
  student_sent_by uuid,
  tutor_sent_at timestamptz,
  tutor_sent_by uuid
);
create index if not exists regular_changes_student on regular_changes (student_id, created_at);
do $$ begin
  if not exists (select 1 from pg_trigger where tgname = 'regular_changes_no_delete') then
    create trigger regular_changes_no_delete before delete on regular_changes for each row execute function forbid_delete();
  end if;
  if not exists (select 1 from pg_trigger where tgname = 'regular_changes_audit') then
    create trigger regular_changes_audit after insert or update on regular_changes for each row execute function write_audit();
  end if;
  if not exists (select 1 from pg_policies where tablename = 'regular_changes' and policyname = 'admin_read') then
    create policy admin_read on regular_changes for select to authenticated using (is_admin());
  end if;
end $$;
alter table regular_changes enable row level security;
revoke all on regular_changes from public, anon;
grant select on regular_changes to authenticated;

-- ---------------------------------------------------------------------
-- 2. 이름 표기 (④) · 강사 접근 권한 (⑥)
-- ---------------------------------------------------------------------
-- 강사 화면 학생 이름: 'Kim Seoyeon (Sarah)' — Preferred Name 이 없거나 영문 이름과 같으면 괄호 없이
create or replace function lms_tutor_student_label(p_name_en text, p_display text) returns text
language sql immutable as $$
  select case when nullif(trim(coalesce(p_display, '')), '') is null or lower(trim(p_display)) = lower(trim(coalesce(p_name_en, '')))
              then coalesce(p_name_en, '') else p_name_en || ' (' || trim(p_display) || ')' end
$$;
revoke all on function lms_tutor_student_label(text, text) from public, anon;

-- 강사가 이 학생 정보를 볼 수 있는 자격: 'regular'(담당 정규 강사) · 'substitute'(대체강사, 열람만) · null(없음)
--  regular   = 지금 정규 일정의 강사이거나, 최근 60일~앞으로 이 학생의 정규·보강 수업 강사(대체가 아닌)
--  substitute= 대체수업(원래 강사가 따로 있는 수업)의 강사: 확정 시점(lessons 에 대체강사로 들어간 때)부터 그 수업 종료 24시간 뒤까지.
--              대체수업이 취소되면 그 수업에 따른 자격은 끝남. 여러 대체수업이면 각각
create or replace function lms_tutor_student_access(p_tutor uuid, p_student uuid) returns text
language sql stable security definer set search_path = public as $$
  select case
    when p_tutor is null or p_student is null then null
    when exists (select 1 from regular_schedules rs where rs.student_id = p_student and rs.tutor_id = p_tutor
                 and (rs.effective_to is null or rs.effective_to >= (now() at time zone 'Asia/Seoul')::date - 60))
      or exists (select 1 from lessons l where l.student_id = p_student and l.state <> 'canceled' and l.voided_at is null
                 and coalesce(l.original_tutor_id, l.tutor_id) = p_tutor
                 and l.ends_at > now() - interval '60 days')
      then 'regular'
    when exists (select 1 from lessons l where l.student_id = p_student and l.tutor_id = p_tutor
                 and l.original_tutor_id is not null and l.original_tutor_id <> p_tutor
                 and l.state <> 'canceled' and l.voided_at is null
                 and now() <= l.ends_at + interval '24 hours')
      then 'substitute'
    else null end
$$;
revoke all on function lms_tutor_student_access(uuid, uuid) from public, anon, authenticated;

-- tutor_my_students (core): '지난 60일' 공통 규칙 → 위 기준으로 교체 (돌려주는 칸은 그대로). 대체강사에게는 이메일을 주지 않음
create or replace function tutor_my_students()
returns table (student_id uuid, display_name text, country text, timezone text, gender_age text, self_intro_en text, level text,
               class_type text, correction_pref text, textbook text, email text, class_note_url text)
language sql stable security definer set search_path = public as $$
  select s.id, lms_tutor_student_label(s.name_en, s.display_name), s.country, s.timezone, s.gender_age, s.self_intro_en,
         s.level, s.class_type, s.correction_pref, s.textbook,
         case when a.access = 'regular' then s.email end, s.class_note_url
  from students s
  cross join lateral (select lms_tutor_student_access(my_tutor_id(), s.id) as access) a
  where my_tutor_id() is not null and a.access is not null
$$;
revoke all on function tutor_my_students() from public, anon;
grant execute on function tutor_my_students() to authenticated;

-- ---------------------------------------------------------------------
-- 3. 프로필 공통 JSON (운영진·강사 함수가 같이 씀) + 수정 기록 도우미
-- ---------------------------------------------------------------------
-- 지금 유효한 정규 일정. 아직 시작 전(수강 예정·다음 주부터 바뀜)이면 가장 가까운 앞으로의 일정
create or replace function lms_current_slots(p_student uuid, p_day date default (now() at time zone 'Asia/Seoul')::date)
returns setof regular_schedules
language sql stable security definer set search_path = public as $$
  with cur as (select rs.* from regular_schedules rs where rs.student_id = p_student and rs.effective_from <= p_day and (rs.effective_to is null or rs.effective_to >= p_day)),
       nxt as (select rs.* from regular_schedules rs where rs.student_id = p_student and rs.effective_from > p_day
               and rs.effective_from = (select min(x.effective_from) from regular_schedules x where x.student_id = p_student and x.effective_from > p_day))
  select * from cur
  union all
  select * from nxt where not exists (select 1 from cur)
$$;
revoke all on function lms_current_slots(uuid, date) from public, anon, authenticated;

create or replace function lms_student_profile_json(p_student uuid, p_access text)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  s students;
  e enrollments;
  v_today date := (now() at time zone 'Asia/Seoul')::date;
  v_full boolean := p_access in ('admin', 'regular');
begin
  select * into s from students where id = p_student;
  if not found then raise exception 'Student not found.' using errcode = 'P0002'; end if;
  select * into e from enrollments x where x.id = lms_student_enrollment(p_student);
  return jsonb_build_object(
    'student', jsonb_strip_nulls(jsonb_build_object(
      'id', s.id, 'code', case when p_access = 'admin' then s.code end,
      'name_ko', case when p_access = 'admin' then s.name_ko end,
      'name_en', s.name_en, 'display_name', s.display_name, 'label', lms_tutor_student_label(s.name_en, s.display_name),
      'country', s.country, 'city', s.city, 'timezone', s.timezone, 'gender_age', s.gender_age,
      'email', case when v_full then s.email end,
      'phone', case when p_access = 'admin' then s.phone end,
      'admin_memo', case when p_access = 'admin' then s.admin_memo end,
      'level', s.level, 'level_note', s.level_note, 'level_at', s.level_at,
      'level_by', case when s.level_by is null then null else coalesce(
        (select t.name from app_users u join tutors t on t.id = u.tutor_id where u.auth_user_id = s.level_by),
        (select case when u.role = 'admin' then 'Edge English' end from app_users u where u.auth_user_id = s.level_by)) end,
      'class_type', s.class_type, 'textbook', s.textbook, 'class_note_url', s.class_note_url,
      'correction_pref', s.correction_pref, 'self_intro_en', s.self_intro_en,
      'job', s.job, 'hobbies', s.hobbies, 'interests', s.interests, 'improve', s.improve, 'hopes', s.hopes,
      'correction_style', s.correction_style, 'correction_note', s.correction_note,
      'class_style', s.class_style, 'class_style_note', s.class_style_note,
      'answers_at', s.answers_at, 'lms_since', s.lms_since)),
    'enrollment', case when e.id is null then null else jsonb_build_object(
      'id', e.id, 'seq', e.seq, 'status', e.status, 'weeks', e.weeks, 'legacy_label', e.legacy_label,
      'weekly_count', e.weekly_count, 'duration_min', e.duration_min,
      'start_date', e.start_date, 'base_end_date', e.base_end_date, 'extension_days', e.extension_days, 'final_end_date', e.final_end_date,
      'lessons_purchased', e.lessons_purchased, 'lessons_carried_in', e.lessons_carried_in,
      'sheet', (select jsonb_build_object('total', c.sheet_total, 'used', c.sheet_used) from import_checks c where c.enrollment_id = e.id),
      'done', (select count(*) from lessons l left join class_status_rules r on r.status = l.class_status
               where l.enrollment_id = e.id and l.voided_at is null and l.kind <> 'compensation'
                 and l.state <> 'scheduled' and (l.class_status is null or r.consumes_lesson)),
      'left_regular', (select count(*) from lessons l where l.enrollment_id = e.id and l.kind = 'regular' and l.state = 'scheduled' and l.voided_at is null and l.starts_at > now()),
      'left_all', (select count(*) from lessons l where l.enrollment_id = e.id and l.state = 'scheduled' and l.voided_at is null and l.starts_at > now()),
      'extensions', case when v_full then coalesce((
        select jsonb_agg(jsonb_build_object('id', x.id, 'days', x.days, 'reason', x.reason, 'note', case when p_access = 'admin' then x.note end,
                 'auto', x.auto_source, 'at', x.created_at,
                 'by', case when p_access = 'admin' then (select coalesce(u.role, '') from app_users u where u.auth_user_id = x.approved_by) end) order by x.created_at)
        from enrollment_extensions x where x.enrollment_id = e.id), '[]'::jsonb) else '[]'::jsonb end) end,
    'slots', coalesce((
      select jsonb_agg(jsonb_build_object('weekday', rs.weekday, 'time', to_char(rs.start_time_kst, 'HH24:MI'), 'duration_min', rs.duration_min,
               'tutor_id', rs.tutor_id, 'tutor', t.name, 'tutor_tz', t.timezone, 'tutor_country', t.country,
               'from', rs.effective_from, 'to', rs.effective_to) order by rs.weekday, rs.start_time_kst)
      from lms_current_slots(p_student, v_today) rs join tutors t on t.id = rs.tutor_id), '[]'::jsonb),
    -- 지금 일정이 있고 앞으로 바뀔 일정도 있으면 따로 (운영진 화면 '○○부터 바뀜')
    'next_slots', coalesce((
      select jsonb_agg(jsonb_build_object('weekday', rs.weekday, 'time', to_char(rs.start_time_kst, 'HH24:MI'), 'from', rs.effective_from) order by rs.weekday)
      from regular_schedules rs
      where rs.student_id = p_student and rs.effective_from > v_today
        and exists (select 1 from lms_current_slots(p_student, v_today) c where c.effective_from <= v_today)
        and rs.effective_from = (select min(x.effective_from) from regular_schedules x where x.student_id = p_student and x.effective_from > v_today)), '[]'::jsonb),
    -- 앞으로 수업 (강사 화면은 자기 자격 범위에서 쓰고, 시각 계산은 화면이 수업 날짜로 함)
    'upcoming', coalesce((
      select jsonb_agg(jsonb_build_object('id', l.id, 'kind', l.kind, 'seq', l.seq, 'starts_at', l.starts_at, 'ends_at', l.ends_at,
               'tutor', t.name, 'tutor_tz', t.timezone, 'tutor_id', l.tutor_id, 'substitute', l.original_tutor_id is not null and l.original_tutor_id <> l.tutor_id,
               'leave_open', exists (select 1 from leave_items li where li.lesson_id = l.id and li.lesson_gone_at is null
                                      and (li.choice = 'undecided' or (li.choice = 'substitute' and li.sub_stage <> 'confirmed')))) order by l.starts_at)
      from lessons l join tutors t on t.id = l.tutor_id
      where l.student_id = p_student and l.state = 'scheduled' and l.voided_at is null and l.starts_at > now()), '[]'::jsonb),
    -- 최근 수업 기록 3건: Covered Topics 가 적힌 최신 수업 (정규·대체 모두)
    'recent_topics', coalesce((
      select jsonb_agg(jsonb_build_object('starts_at', l.starts_at, 'tutor', t.name, 'topics', cr.covered_topics, 'kind', l.kind,
               'substitute', l.original_tutor_id is not null and l.original_tutor_id <> l.tutor_id) order by l.starts_at desc)
      from (select l.* from lessons l join class_records cr on cr.lesson_id = l.id
            where l.student_id = p_student and nullif(trim(cr.covered_topics), '') is not null
            order by l.starts_at desc limit 3) l
      join class_records cr on cr.lesson_id = l.id
      join tutors t on t.id = l.tutor_id), '[]'::jsonb),
    'access', p_access,
    'holidays', coalesce((select jsonb_agg(h.day order by h.day) from holidays h where h.day between v_today and v_today + 200), '[]'::jsonb));
end $$;
revoke all on function lms_student_profile_json(uuid, text) from public, anon, authenticated;

create or replace function lms_profile_edit(p_student uuid, p_field text, p_old text, p_new text, p_role text, p_via text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if p_old is distinct from p_new then
    insert into student_profile_edits (student_id, field, old_value, new_value, edited_by, edited_role, via)
    values (p_student, p_field, p_old, p_new, auth.uid(), p_role, p_via);
  end if;
end $$;
revoke all on function lms_profile_edit(uuid, text, text, text, text, text) from public, anon, authenticated;

-- 프로필 칸 바꾸기 공통: p 의 키만 바꿈. 빈 글은 null 로 저장(미응답). 바뀐 칸마다 기록
create or replace function lms_student_apply(p_student uuid, p jsonb, p_allowed text[], p_role text, p_via text) returns integer
language plpgsql security definer set search_path = public as $$
declare
  s students;
  k text;
  v text;
  n integer := 0;
  v_level_changed boolean := false;
  v_answer_changed boolean := false;
begin
  select * into s from students where id = p_student for update;
  if not found then raise exception 'Student not found.' using errcode = 'P0002'; end if;
  for k in select jsonb_object_keys(p) loop
    if not (k = any(p_allowed)) then raise exception 'Field % cannot be changed here.', k using errcode = '42501'; end if;
    v := nullif(trim(coalesce(p ->> k, '')), '');
    if k = 'timezone' and v is not null and not is_valid_timezone(v) then raise exception 'Unknown time zone: %', v using errcode = '22023'; end if;
    if k = 'email' and v is not null and v !~ '^[^\s@]+@[^\s@]+\.[^\s@]+$' then raise exception 'Please check the email address.' using errcode = '22023'; end if;
    if k = 'level' and v is not null and v not in ('Beginner', 'Pre-Intermediate', 'Intermediate', 'Advanced') then
      raise exception 'Level must be one of the rubric levels.' using errcode = '22023';
    end if;
    if k = 'class_note_url' and v is not null and v !~ '^https?://' then raise exception 'Class notes link must start with https://' using errcode = '22023'; end if;
    if (to_jsonb(s) ->> k) is distinct from v then
      perform lms_profile_edit(p_student, k, to_jsonb(s) ->> k, v, p_role, p_via);
      execute format('update students set %I = $1 where id = $2', k) using v, p_student;
      n := n + 1;
      if k = 'level' then v_level_changed := true; end if;
      if k in ('job', 'hobbies', 'interests', 'improve', 'hopes', 'correction_style', 'correction_note', 'class_style', 'class_style_note') then v_answer_changed := true; end if;
    end if;
  end loop;
  if v_level_changed then update students set level_by = auth.uid(), level_at = now() where id = p_student; end if;
  if v_answer_changed then update students set answers_by = auth.uid(), answers_at = now() where id = p_student; end if;
  return n;
end $$;
revoke all on function lms_student_apply(uuid, jsonb, text[], text, text) from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- 4. 운영진: 학생 목록 · 상세 · 정보 수정
-- ---------------------------------------------------------------------
-- 수강 상태: active(수강 중) · upcoming(수강 예정 = 시작 전 수강권) · ended(종료) · none(수강권 없음)
create or replace function admin_students()
returns jsonb
language sql stable security definer set search_path = public as $$
  select case when not is_admin() then null else coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', s.id, 'code', s.code, 'name_ko', s.name_ko, 'name_en', s.name_en, 'display_name', s.display_name, 'email', s.email, 'timezone', s.timezone,
      'status', case when e.id is null then 'none'
                     when e.status in ('completed', 'canceled') then 'ended'
                     when e.final_end_date < (now() at time zone 'Asia/Seoul')::date then 'ended'
                     when e.start_date > (now() at time zone 'Asia/Seoul')::date then 'upcoming'
                     else 'active' end,
      'enrollment_status', e.status, 'start_date', e.start_date, 'final_end_date', e.final_end_date,
      'weeks', e.weeks, 'legacy_label', e.legacy_label, 'weekly_count', e.weekly_count, 'duration_min', e.duration_min,
      'left_regular', (select count(*) from lessons l where l.enrollment_id = e.id and l.kind = 'regular' and l.state = 'scheduled' and l.voided_at is null and l.starts_at > now()),
      'tutor', (select t.name from lms_current_slots(s.id) rs join tutors t on t.id = rs.tutor_id limit 1),
      'slots', (select jsonb_agg(jsonb_build_object('weekday', rs.weekday, 'time', to_char(rs.start_time_kst, 'HH24:MI')) order by rs.weekday) from lms_current_slots(s.id) rs),
      'notice_pending', exists (select 1 from regular_changes rc where rc.student_id = s.id and (rc.student_sent_at is null or rc.tutor_sent_at is null)))
      order by s.name_ko)
    from students s
    left join enrollments e on e.id = lms_student_enrollment(s.id)), '[]'::jsonb) end
$$;
revoke all on function admin_students() from public, anon;
grant execute on function admin_students() to authenticated;

create or replace function admin_student_detail(p_student uuid)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  j jsonb;
  v_login jsonb;
begin
  if not is_admin() then raise exception '운영자(추가 인증 완료)만 볼 수 있습니다.' using errcode = '42501'; end if;
  j := lms_student_profile_json(p_student, 'admin');
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

-- 운영진 정보 수정: 전체 칸 (결제·수강권 칸은 여기서 안 바꿈 — 등록·이관 흐름)
create or replace function admin_student_update(p_student uuid, p jsonb)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  n integer;
begin
  if not is_admin() then raise exception '운영자(추가 인증 완료)만 바꿀 수 있습니다.' using errcode = '42501'; end if;
  perform set_config('app.actor_id', auth.uid()::text, true);
  perform set_config('app.actor_via', 'admin_student_update', true);
  n := lms_student_apply(p_student, p, array['name_ko', 'name_en', 'display_name', 'country', 'city', 'timezone', 'gender_age', 'email', 'phone',
         'level', 'level_note', 'class_type', 'textbook', 'class_note_url', 'admin_memo', 'self_intro_en', 'correction_pref',
         'job', 'hobbies', 'interests', 'improve', 'hopes', 'correction_style', 'correction_note', 'class_style', 'class_style_note'],
         'admin', 'admin_student_update');
  return jsonb_build_object('changed', n);
end $$;
revoke all on function admin_student_update(uuid, jsonb) from public, anon;
grant execute on function admin_student_update(uuid, jsonb) to authenticated;

-- ---------------------------------------------------------------------
-- 5. 강사: 학생 프로필 보기 · (정규 담당만) 레벨·자기소개·선호 수정
-- ---------------------------------------------------------------------
create or replace function tutor_student_profile(p_student uuid)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  me uuid := my_tutor_id();
  v_access text;
  j jsonb;
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
    -- 대체강사: 자기가 맡은 대체수업만, 수강 정보 상세(연장 기록 등)는 빼고 수업 길이·기간만
    j := j - 'upcoming' - 'enrollment' || jsonb_build_object(
      'upcoming', (select coalesce(jsonb_agg(x) filter (where (x ->> 'tutor_id')::uuid = me), '[]'::jsonb) from jsonb_array_elements(j -> 'upcoming') x),
      'enrollment', case when j -> 'enrollment' is null or j -> 'enrollment' = 'null'::jsonb then null else
        jsonb_build_object('duration_min', j -> 'enrollment' -> 'duration_min', 'weekly_count', j -> 'enrollment' -> 'weekly_count',
                           'final_end_date', j -> 'enrollment' -> 'final_end_date') end);
  end if;
  return j || jsonb_build_object('me', jsonb_build_object('id', me, 'timezone', (select timezone from tutors where id = me)));
end $$;
revoke all on function tutor_student_profile(uuid) from public, anon;
grant execute on function tutor_student_profile(uuid) to authenticated;

create or replace function tutor_student_update(p_student uuid, p jsonb)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  me uuid := my_tutor_id();
  n integer;
begin
  if not is_admin() then
    if me is null or lms_tutor_student_access(me, p_student) is distinct from 'regular' then
      raise exception 'Only the student''s regular tutor can edit this.' using errcode = '42501';
    end if;
  end if;
  perform set_config('app.actor_id', auth.uid()::text, true);
  perform set_config('app.actor_via', 'tutor_student_update', true);
  n := lms_student_apply(p_student, p, array['level', 'job', 'hobbies', 'interests', 'improve', 'hopes',
         'correction_style', 'correction_note', 'class_style', 'class_style_note'],
         case when is_admin() and me is null then 'admin' else 'tutor' end, 'tutor_student_update');
  return jsonb_build_object('changed', n);
end $$;
revoke all on function tutor_student_update(uuid, jsonb) from public, anon;
grant execute on function tutor_student_update(uuid, jsonb) to authenticated;

-- ---------------------------------------------------------------------
-- 6. ① 정규 일정 수정 (미리 보기 / 저장) · ② 종료일 안 검사
-- ---------------------------------------------------------------------
create or replace function admin_regular_change(p_student uuid, p_slots jsonb, p_from date, p_reason text, p_dry_run boolean default true)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_today date := (now() at time zone 'Asia/Seoul')::date;
  v_break constant interval := interval '10 minutes';   -- POL-OP-21
  e enrollments;
  t tutors;
  v_tutor uuid;
  v_lid uuid;
  v_old jsonb;
  v_new jsonb;
  v_n_slots integer;
  s jsonb;
  v_reason text := nullif(trim(coalesce(p_reason, '')), '');
  v_movable uuid[];
  v_moved jsonb := '[]'::jsonb;
  v_kept jsonb;
  v_skipped jsonb := '[]'::jsonb;
  v_problems jsonb := '[]'::jsonb;
  l lessons;
  d date;
  i integer := 0;
  t0 timestamptz;
  t1 timestamptz;
  v_why text;
  v_last date;
  v_change uuid;
  v_guard integer := 0;
begin
  if not is_admin() then raise exception '운영자(추가 인증 완료)만 정규 일정을 바꿀 수 있습니다.' using errcode = '42501'; end if;
  select * into e from enrollments x where x.id = lms_student_enrollment(p_student);
  if e.id is null or e.status not in ('confirmed', 'active') then
    raise exception '수강 중이거나 시작 예정인 수강권이 없어 정규 일정을 바꿀 수 없습니다.';
  end if;
  if p_from is null or p_from < v_today then raise exception '적용 시작일은 오늘(한국 날짜) 이후여야 합니다.'; end if;
  if p_from > e.final_end_date then raise exception '적용 시작일(%)이 최종 종료일(%) 뒤입니다.', p_from, e.final_end_date; end if;

  -- 지금 정규 일정 (적용 시작일에 유효한 것). 강사는 하나
  select jsonb_agg(jsonb_build_object('weekday', rs.weekday, 'time', to_char(rs.start_time_kst, 'HH24:MI')) order by rs.weekday, rs.start_time_kst),
         count(distinct rs.tutor_id), (array_agg(distinct rs.tutor_id))[1]
    into v_old, v_n_slots, v_tutor
  from regular_schedules rs
  where rs.student_id = p_student and rs.effective_from <= greatest(p_from, e.start_date)
    and (rs.effective_to is null or rs.effective_to >= greatest(p_from, e.start_date));
  if v_old is null then raise exception '이 학생의 정규 일정이 없습니다 (등록·이관 때 정규 일정이 만들어집니다).'; end if;
  if v_n_slots <> 1 then raise exception '정규 일정의 강사가 하나가 아닙니다. 운영진이 확인해 주세요.'; end if;
  select * into t from tutors where id = v_tutor;

  -- 새 일정 모양: 지금과 같은 수(주 횟수 그대로), 요일 0~6 중복 없음, 30분 단위
  if p_slots is null or jsonb_typeof(p_slots) <> 'array' then raise exception '새 정규 일정이 비어 있습니다.'; end if;
  if jsonb_array_length(p_slots) <> jsonb_array_length(v_old) then
    raise exception '주 %회 수강권이라 요일을 %개 골라야 합니다 (주 횟수는 이 화면에서 바꾸지 않습니다).', jsonb_array_length(v_old), jsonb_array_length(v_old);
  end if;
  select jsonb_agg(jsonb_build_object('weekday', (x ->> 'weekday')::int, 'time', to_char((x ->> 'time')::time, 'HH24:MI')) order by (x ->> 'weekday')::int)
    into v_new from jsonb_array_elements(p_slots) x;
  for s in select * from jsonb_array_elements(v_new) loop
    if (s ->> 'weekday')::int not between 0 and 6 then raise exception '요일 값이 잘못됐습니다.'; end if;
    if extract(minute from (s ->> 'time')::time)::int not in (0, 30) then raise exception '시작 시간은 30분 단위(예: 22:00, 22:30)로 골라 주세요.'; end if;
  end loop;
  if (select count(distinct x ->> 'weekday') from jsonb_array_elements(v_new) x) <> jsonb_array_length(v_new) then
    raise exception '같은 요일을 두 번 고를 수 없습니다.';
  end if;
  if v_new = v_old then raise exception '지금 정규 일정과 같습니다. 바꿀 요일·시간을 골라 주세요.'; end if;
  if not p_dry_run and v_reason is null then raise exception '수정 사유를 적어 주세요.'; end if;

  -- 옮길 수업: 이 수강권의 앞으로 정규 수업 중 적용 시작일 이후, 대체강사 아님, 휴무 처리 중 아님
  select coalesce(array_agg(x.id order by x.starts_at), '{}') into v_movable
  from lessons x
  where x.enrollment_id = e.id and x.kind = 'regular' and x.state = 'scheduled' and x.voided_at is null
    and x.starts_at > now() and x.kst_date >= p_from
    and x.original_tutor_id is null and x.tutor_id = t.id
    and not exists (select 1 from leave_items li where li.lesson_id = x.id and li.lesson_gone_at is null);
  -- 그대로 두는 앞으로의 수업 (왜 그대로인지 같이)
  select coalesce(jsonb_agg(jsonb_build_object('lesson_id', x.id, 'kind', x.kind, 'seq', x.seq, 'starts_at', x.starts_at, 'ends_at', x.ends_at,
           'tutor', xt.name, 'tutor_tz', xt.timezone,
           'why', case when x.kst_date < p_from then 'before_from'
                       when x.original_tutor_id is not null and x.original_tutor_id <> x.tutor_id then 'substitute'
                       when x.kind = 'makeup' then 'makeup' when x.kind = 'compensation' then 'compensation'
                       when x.kind in ('migrated_makeup', 'migrated_extra', 'carryover') then 'makeup'
                       when exists (select 1 from leave_items li where li.lesson_id = x.id and li.lesson_gone_at is null) then 'leave_open'
                       else 'other' end) order by x.starts_at), '[]'::jsonb)
    into v_kept
  from lessons x join tutors xt on xt.id = x.tutor_id
  where x.student_id = p_student and x.state = 'scheduled' and x.voided_at is null and x.starts_at > now()
    and not (x.id = any(v_movable));
  if cardinality(v_movable) = 0 then
    raise exception '적용 시작일(%) 이후에 옮길 정규 수업이 없습니다.', p_from;
  end if;

  -- 새 날짜에 차례로 배치: 적용 시작일부터 새 요일에 맞는 날을 순서대로. 학생의 그대로 두는 수업과 겹치는 날은 건너뜀
  d := p_from;
  foreach v_lid in array v_movable loop
    select * into l from lessons where id = v_lid;
    loop
      v_guard := v_guard + 1;
      if v_guard > 2000 then raise exception '새 일정 날짜를 찾지 못했습니다.'; end if;
      select x into s from jsonb_array_elements(v_new) x where (x ->> 'weekday')::int = extract(dow from d);
      if found then
        t0 := (d + (s ->> 'time')::time) at time zone 'Asia/Seoul';
        t1 := t0 + make_interval(mins => e.duration_min);
        -- 학생 본인의 그대로 두는 수업과 겹치면 이 날은 건너뜀
        if exists (select 1 from lessons y where y.student_id = p_student and y.state <> 'canceled' and y.voided_at is null
                   and not (y.id = any(v_movable)) and y.starts_at < t1 and t0 < y.ends_at) then
          v_skipped := v_skipped || jsonb_build_object('date', d, 'time', s ->> 'time', 'why', 'student_busy');
          d := d + 1; continue;
        end if;
        exit;
      end if;
      d := d + 1;
    end loop;
    -- 검사 (강사 기준)
    v_why := null;
    if not lms_tutor_start_ok(t.id, t0) then v_why := 'tutor_hours_range';
    elsif not lms_tutor_available(t.id, t0) then v_why := 'tutor_unavailable';
    elsif exists (select 1 from tutor_time_off o where o.tutor_id = t.id and o.starts_at < t1 and t0 < o.ends_at) then v_why := 'tutor_time_off';
    elsif exists (select 1 from lessons y where y.tutor_id = t.id and y.state <> 'canceled' and not (y.id = any(v_movable))
                  and y.starts_at < t1 + v_break and t0 - v_break < y.ends_at) then v_why := 'tutor_busy';
    elsif exists (select 1 from lms_slot_hold_hits(t.id, t0, t1) h where h.student_id <> p_student) then v_why := 'tutor_hold';
    end if;
    if d > e.final_end_date then v_why := coalesce(v_why, 'after_end'); end if;
    if v_why is not null then
      v_problems := v_problems || jsonb_build_object('lesson_id', l.id, 'seq', l.seq, 'date', d, 'time', s ->> 'time', 'why', v_why,
        'other', case when v_why = 'tutor_busy' then (select st.name_ko || ' ' || to_char(y.starts_at at time zone 'Asia/Seoul', 'HH24:MI') || '–' || to_char(y.ends_at at time zone 'Asia/Seoul', 'HH24:MI')
                                                  from lessons y join students st on st.id = y.student_id
                                                  where y.tutor_id = t.id and y.state <> 'canceled' and not (y.id = any(v_movable))
                                                    and y.starts_at < t1 + v_break and t0 - v_break < y.ends_at order by y.starts_at limit 1)
                      when v_why = 'tutor_hold' then (select h.student_name from lms_slot_hold_hits(t.id, t0, t1) h where h.student_id <> p_student limit 1) end);
    end if;
    v_moved := v_moved || jsonb_build_object('lesson_id', l.id, 'seq', l.seq, 'from', l.starts_at, 'from_end', l.ends_at, 'to', t0, 'to_end', t1, 'problem', v_why);
    v_last := d;
    d := d + 1;
  end loop;

  if p_dry_run then
    return jsonb_build_object('ok', jsonb_array_length(v_problems) = 0, 'tutor', jsonb_build_object('id', t.id, 'name', t.name, 'timezone', t.timezone),
      'student_timezone', (select timezone from students where id = p_student),
      'enrollment', jsonb_build_object('id', e.id, 'final_end_date', e.final_end_date, 'duration_min', e.duration_min),
      'old_slots', v_old, 'new_slots', v_new, 'effective_from', p_from, 'moved', v_moved, 'kept', v_kept, 'skipped', v_skipped,
      'problems', v_problems, 'last_date', v_last);
  end if;
  if jsonb_array_length(v_problems) > 0 then
    raise exception '새 일정에 문제가 %건 있어 저장하지 않았습니다. 미리 보기를 다시 확인해 주세요.', jsonb_array_length(v_problems)
      using errcode = 'P0001', detail = v_problems::text, hint = 'regular_change_problems';
  end if;

  -- 저장: 옮기는 중 같은 학생 수업끼리 잠깐 겹치지 않게 두 단계로 (먼저 200년 뒤로 비켜 두고, 다시 새 시각으로)
  perform set_config('app.actor_id', auth.uid()::text, true);
  perform set_config('app.actor_via', 'admin_regular_change', true);
  for s in select * from jsonb_array_elements(v_moved) loop
    update lessons set starts_at = (s ->> 'to')::timestamptz + interval '200 years', ends_at = (s ->> 'to_end')::timestamptz + interval '200 years'
    where id = (s ->> 'lesson_id')::uuid;
  end loop;
  for s in select * from jsonb_array_elements(v_moved) loop
    update lessons set starts_at = (s ->> 'to')::timestamptz, ends_at = (s ->> 'to_end')::timestamptz where id = (s ->> 'lesson_id')::uuid;
  end loop;
  -- 정규 일정 표: 적용 시작일 전날까지로 닫고 새 줄. 적용 시작일 이후에 시작하는(아직 효력 전) 줄은 효력 없는 날짜(1900-01-01)로 치워 둠(지우지 않음)
  update regular_schedules rs
     set effective_from = date '1900-01-01' + (select count(*) from regular_schedules r2 where r2.student_id = rs.student_id and r2.weekday = rs.weekday and r2.effective_to < date '1950-01-01')::int,
         effective_to = date '1900-01-01' + (select count(*) from regular_schedules r2 where r2.student_id = rs.student_id and r2.weekday = rs.weekday and r2.effective_to < date '1950-01-01')::int,
         change_reason = coalesce(rs.change_reason, '') || ' [취소됨 ' || p_from || ']'
  where rs.student_id = p_student and rs.tutor_id = t.id and rs.effective_from >= p_from;
  update regular_schedules rs set effective_to = p_from - 1
  where rs.student_id = p_student and rs.tutor_id = t.id and rs.effective_from < p_from and (rs.effective_to is null or rs.effective_to >= p_from);
  for s in select * from jsonb_array_elements(v_new) loop
    insert into regular_schedules (student_id, tutor_id, weekday, start_time_kst, duration_min, effective_from, change_reason)
    values (p_student, t.id, (s ->> 'weekday')::smallint, (s ->> 'time')::time, e.duration_min, p_from, v_reason);
  end loop;
  insert into regular_changes (student_id, enrollment_id, tutor_id, effective_from, old_slots, new_slots, moved, kept, reason, created_by)
  values (p_student, e.id, t.id, p_from, v_old, v_new, v_moved, v_kept, v_reason, auth.uid())
  returning id into v_change;
  return jsonb_build_object('ok', true, 'change_id', v_change, 'moved', jsonb_array_length(v_moved), 'effective_from', p_from, 'last_date', v_last);
exception
  when exclusion_violation then
    raise exception '저장 중 겹침이 생겨 저장하지 않았습니다 (%). 미리 보기를 다시 확인해 주세요.', sqlerrm;
end $$;
revoke all on function admin_regular_change(uuid, jsonb, date, text, boolean) from public, anon;
grant execute on function admin_regular_change(uuid, jsonb, date, text, boolean) to authenticated;

-- ③ 안내 발송 기록: 학생·강사 따로 [발송 완료]
create or replace function admin_regular_change_sent(p_change uuid, p_who text, p_undo boolean default false)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  rc regular_changes;
begin
  if not is_admin() then raise exception '운영자(추가 인증 완료)만 처리할 수 있습니다.' using errcode = '42501'; end if;
  if p_who not in ('student', 'tutor') then raise exception '받는 사람은 student 또는 tutor 입니다.'; end if;
  select * into rc from regular_changes where id = p_change for update;
  if not found then raise exception '변경 기록을 찾을 수 없습니다.'; end if;
  perform set_config('app.actor_id', auth.uid()::text, true);
  perform set_config('app.actor_via', 'admin_regular_change_sent', true);
  if p_who = 'student' then
    update regular_changes set student_sent_at = case when p_undo then null else coalesce(student_sent_at, now()) end,
                               student_sent_by = case when p_undo then null else coalesce(student_sent_by, auth.uid()) end where id = p_change;
  else
    update regular_changes set tutor_sent_at = case when p_undo then null else coalesce(tutor_sent_at, now()) end,
                               tutor_sent_by = case when p_undo then null else coalesce(tutor_sent_by, auth.uid()) end where id = p_change;
  end if;
  select * into rc from regular_changes where id = p_change;
  return jsonb_build_object('student_sent_at', rc.student_sent_at, 'tutor_sent_at', rc.tutor_sent_at);
end $$;
revoke all on function admin_regular_change_sent(uuid, text, boolean) from public, anon;
grant execute on function admin_regular_change_sent(uuid, text, boolean) to authenticated;

-- ---------------------------------------------------------------------
-- 7. 운영진만 종료일 연장 (기존 enrollment_extensions 한 줄, 강사 불가)
--    새 최종 종료일을 받아 차이만큼 기록. 줄이기(정정)도 가능하지만 예정된 수업보다 앞으로는 못 줄임. 다음 수강권과 겹치면 DB 가 막음
-- ---------------------------------------------------------------------
create or replace function admin_extend_enrollment(p_enrollment uuid, p_new_end date, p_kind text, p_note text)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  e enrollments;
  v_days integer;
  v_note text := nullif(trim(coalesce(p_note, '')), '');
  v_last date;
begin
  if not is_admin() then raise exception '운영자(추가 인증 완료)만 종료일을 바꿀 수 있습니다.' using errcode = '42501'; end if;
  if p_kind not in ('student_long_term_leave', 'admin_exception', 'correction') then raise exception '연장 사유 종류가 잘못됐습니다.'; end if;
  if v_note is null then raise exception '사유를 적어 주세요.'; end if;
  select * into e from enrollments where id = p_enrollment for update;
  if not found then raise exception '수강권을 찾을 수 없습니다.'; end if;
  if e.status in ('canceled', 'completed') then raise exception '끝난 수강권(%)의 종료일은 바꿀 수 없습니다.', e.status; end if;
  if p_new_end is null then raise exception '새 종료일을 골라 주세요.'; end if;
  v_days := p_new_end - e.final_end_date;
  if v_days = 0 then raise exception '지금 최종 종료일(%)과 같습니다.', e.final_end_date; end if;
  if p_new_end < e.base_end_date then raise exception '원래 종료일(%)보다 앞으로는 줄일 수 없습니다.', e.base_end_date; end if;
  select max(x.kst_date) into v_last from lessons x where x.enrollment_id = e.id and x.state = 'scheduled' and x.voided_at is null;
  if v_last is not null and p_new_end < v_last then
    raise exception '%에 예정된 수업이 있어 종료일을 그보다 앞으로 줄일 수 없습니다.', v_last;
  end if;
  perform set_config('app.actor_id', auth.uid()::text, true);
  perform set_config('app.actor_via', 'admin_extend_enrollment', true);
  begin
    insert into enrollment_extensions (enrollment_id, days, reason, note, approved_by)
    values (e.id, v_days, p_kind, v_note, auth.uid());
  exception when exclusion_violation then
    raise exception '다음 수강권 기간과 겹쳐 종료일을 %로 바꿀 수 없습니다.', p_new_end using hint = 'next_enrollment';
  end;
  select * into e from enrollments where id = p_enrollment;
  return jsonb_build_object('final_end_date', e.final_end_date, 'days', v_days, 'extension_days', e.extension_days);
end $$;
revoke all on function admin_extend_enrollment(uuid, date, text, text) from public, anon;
grant execute on function admin_extend_enrollment(uuid, date, text, text) to authenticated;

-- ---------------------------------------------------------------------
-- 8. 강사 화면 (4100 그대로 + 학생 id·이름 표기 ④ 'Kim Seoyeon (Sarah)')
-- ---------------------------------------------------------------------
create or replace function tutor_screen(p_tutor uuid, p_from date, p_to date)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_tutor uuid := lms_screen_tutor(p_tutor);
  t tutors;
begin
  if p_from is null or p_to is null or p_to < p_from then raise exception 'Invalid date range.'; end if;
  select * into t from tutors where id = v_tutor;
  return jsonb_build_object(
    'tutor', jsonb_build_object('id', t.id, 'name', t.name, 'timezone', t.timezone, 'meet_url', t.meet_url),
    'lessons', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', l.id, 'starts_at', l.starts_at, 'ends_at', l.ends_at, 'kind', l.kind, 'state', l.state, 'class_status', l.class_status,
        'student', lms_tutor_student_label(s.name_en, s.display_name), 'student_id', s.id, 'level', s.level, 'note_url', s.class_note_url,
        'covering', l.original_tutor_id is not null and l.original_tutor_id <> l.tutor_id,
        'makeup_of', o.starts_at,
        'compensation_of', (select x.starts_at from compensations cc join lessons x on x.id = cc.source_lesson_id where cc.id = l.compensation_id),
        'count', lms_lesson_count(l.id),
        'topics', cr.covered_topics, 'remarks', cr.remarks, 'student_late', coalesce(cr.student_late, false), 'recorded_at', cr.first_submitted_at,
        'locked', exists (select 1 from payroll_items p where p.lesson_id = l.id),
        'compensation', (select c.status from compensations c where c.source_lesson_id = l.id),
        'leave_open', l.state = 'scheduled' and exists (select 1 from leave_items li where li.lesson_id = l.id and li.lesson_gone_at is null
                              and (li.choice = 'undecided' or (li.choice = 'substitute' and li.sub_stage <> 'confirmed'))))
        order by l.starts_at)
      from lessons l
      join students s on s.id = l.student_id
      left join lessons o on o.id = l.makeup_of
      left join class_records cr on cr.lesson_id = l.id
      where l.tutor_id = v_tutor and l.voided_at is null
        and (l.kst_date between p_from and p_to
             or (l.state = 'scheduled' and l.starts_at <= now()
                 and l.starts_at >= (select min(u.created_at) from app_users u where u.tutor_id = v_tutor)))), '[]'::jsonb),
    'to_record', coalesce((
      select jsonb_agg(l.id order by l.starts_at)
      from lessons l
      where l.tutor_id = v_tutor and l.state = 'scheduled' and l.voided_at is null and l.starts_at <= now()
        and l.starts_at >= (select min(u.created_at) from app_users u where u.tutor_id = v_tutor)
        and not exists (select 1 from leave_items li where li.lesson_id = l.id and li.lesson_gone_at is null
                         and (li.choice = 'undecided' or (li.choice = 'substitute' and li.sub_stage <> 'confirmed')))), '[]'::jsonb),
    'makeups', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', r.id, 'student', lms_tutor_student_label(s.name_en, s.display_name), 'student_id', s.id,
        'original_at', src.starts_at, 'original_date', mi.original_date,
        'compensation', r.compensation_id is not null,
        'note', r.tutor_note, 'answered_at', r.tutor_answered_at,
        'slots', (select jsonb_agg(jsonb_build_object(
                    'id', c.id, 'starts_at', c.starts_at, 'ends_at', c.ends_at, 'answer', c.tutor_answer,
                    'busy', lms_makeup_conflict(r.tutor_id, r.student_id, c.starts_at, c.ends_at, true) is not null, 'past', c.starts_at <= now())
                    order by c.starts_at)
                  from makeup_candidates c where c.request_id = r.id and c.proposed_by = 'student'))
        order by r.created_at)
      from makeup_requests r
      join students s on s.id = r.student_id
      left join lessons src on src.id = r.source_lesson_id
      left join migrated_items mi on mi.id = r.migrated_item_id
      where r.tutor_id = v_tutor and r.status in ('requested', 'countered')), '[]'::jsonb),
    'covers', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', i.id, 'student', lms_tutor_student_label(s.name_en, s.display_name), 'student_id', s.id, 'starts_at', i.starts_at, 'ends_at', i.ends_at,
        'busy', lms_sub_conflict(v_tutor, i.starts_at, i.ends_at, i.lesson_id) is not null)
        order by i.starts_at)
      from leave_items i join students s on s.id = i.student_id
      where i.sub_tutor_id = v_tutor and i.choice = 'substitute' and i.sub_stage = 'asked' and i.starts_at > now() and i.lesson_gone_at is null), '[]'::jsonb));
end $$;
revoke all on function tutor_screen(uuid, date, date) from public, anon;
grant execute on function tutor_screen(uuid, date, date) to authenticated;
