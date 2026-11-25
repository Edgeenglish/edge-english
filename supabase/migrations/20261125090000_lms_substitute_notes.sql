-- =====================================================================
-- 대체 강사 수업 노트 자동 만들기 (시에나 11/24 결정)
--  - 대체 수업 = 수업 강사(lessons.tutor_id)가 그 날짜의 담당 강사(정규 시간표 regular_schedules 강사,
--    없으면 lessons.original_tutor_id)와 다른 예정 수업
--  - 그런 수업이 잡히면(넣기·강사 바뀜) substitute_notes 에 '학생_대체강사' 노트 작업 1줄 (같은 학생·강사면 다시 씀)
--  - support@ 계정 Apps Script(apps-script/substitute-notes)가 10분마다 작업을 가져가 Google Docs 를 만들고
--    대체 강사 편집 · 링크 있는 누구나 보기 · 원래 노트에 대체 강사 보기(이미 권한 있으면 그대로) — 공유 알림 메일 없음
--  - 강사 화면: 그 학생의 담당 강사가 아니면 원래 노트 대신 본인 대체 노트 링크(만들어지기 전엔 없음)
--  - 학생 화면: 지금 노트 + 대체 노트 + 담당 강사 바뀌며 교체된 예전 노트 모두 (student_my_info.sub_notes)
--  - 메일: 이 migration 은 학생·강사 메일을 보내지 않음
--  - 다시 실행해도 같은 결과 (지우는 문장 없음)
-- =====================================================================

create table if not exists substitute_notes (
  id uuid primary key default gen_random_uuid(),
  student_id uuid not null references students(id),
  tutor_id uuid not null references tutors(id),
  first_lesson_id uuid references lessons(id),
  status text not null default 'pending' check (status in ('pending', 'done')),
  doc_id text,
  doc_url text,
  attempts integer not null default 0,
  last_error text,
  created_at timestamptz not null default now(),
  done_at timestamptz,
  unique (student_id, tutor_id)
);
alter table substitute_notes enable row level security;
revoke all on substitute_notes from anon, authenticated;

-- 그 날짜(한국 날짜)의 담당 강사 = 정규 시간표 강사. 그 날짜에 걸친 시간표가 없으면 그 앞의 마지막 시간표, 그것도 없으면 가장 최근 시간표
create or replace function lms_student_main_tutor(p_student uuid, p_date date)
returns uuid
language sql stable security definer set search_path = public as $$
  select rs.tutor_id from regular_schedules rs
  where rs.student_id = p_student
  order by (rs.effective_from <= p_date and (rs.effective_to is null or rs.effective_to >= p_date)) desc,
           (rs.effective_from <= p_date) desc, rs.effective_from desc, rs.created_at desc
  limit 1
$$;
revoke all on function lms_student_main_tutor(uuid, date) from public, anon, authenticated;

-- 이 수업이 대체 수업인가
create or replace function lms_lesson_is_substitute(p_lesson uuid)
returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((
    select l.tutor_id <> coalesce(lms_student_main_tutor(l.student_id, l.kst_date), l.original_tutor_id)
    from lessons l where l.id = p_lesson), false)
$$;
revoke all on function lms_lesson_is_substitute(uuid) from public, anon, authenticated;

-- 수업이 들어오거나 강사가 바뀌면 (트랜잭션 끝에 다시 읽어서) 대체 노트 작업 넣기
create or replace function lms_substitute_note_queue()
returns trigger
language plpgsql security definer set search_path = public as $$
declare
  l lessons;
begin
  select * into l from lessons where id = new.id;
  if not found or l.state <> 'scheduled' or l.voided_at is not null then return null; end if;
  if not lms_lesson_is_substitute(l.id) then return null; end if;
  insert into substitute_notes (student_id, tutor_id, first_lesson_id)
  values (l.student_id, l.tutor_id, l.id)
  on conflict (student_id, tutor_id) do nothing;
  return null;
end $$;
revoke all on function lms_substitute_note_queue() from public, anon, authenticated;

drop trigger if exists lessons_substitute_note on lessons;
create constraint trigger lessons_substitute_note
  after insert or update of tutor_id, state, voided_at on lessons
  deferrable initially deferred
  for each row when (new.state = 'scheduled' and new.voided_at is null)
  execute function lms_substitute_note_queue();

-- 강사에게 보일 노트 링크: 그 날짜 담당 강사면 학생 노트, 아니면 본인 대체 노트(만들어진 것만)
create or replace function lms_tutor_note_url(p_tutor uuid, p_student uuid, p_date date)
returns text
language sql stable security definer set search_path = public as $$
  select case
    when coalesce(lms_student_main_tutor(p_student, p_date), p_tutor) = p_tutor then (select s.class_note_url from students s where s.id = p_student)
    else (select n.doc_url from substitute_notes n where n.student_id = p_student and n.tutor_id = p_tutor and n.status = 'done')
  end
$$;
revoke all on function lms_tutor_note_url(uuid, uuid, date) from public, anon, authenticated;

-- 학생에게 보일 다른 노트 목록 (대표 11/25 '학생은 대체강사 포함 자기 모든 노트를 볼 수 있어야')
--  kind sub  = 대체 강사 노트
--  kind prev = 담당 강사가 바뀌며 교체된 예전 노트 (회사 소유로 옮긴 11/16 밤 이후 교체분만 — 그 전 링크는 강사 개인 문서)
create or replace function lms_student_sub_notes(p_student uuid)
returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('kind', x.kind, 'tutor', x.tutor, 'url', x.url) order by x.at), '[]'::jsonb)
  from (
    select distinct on (y.url) y.* from (
      select n.created_at as at, 'sub'::text as kind, t.name as tutor, n.doc_url as url
      from substitute_notes n join tutors t on t.id = n.tutor_id
      where n.student_id = p_student and n.status = 'done' and n.doc_url is not null
      union all
      select e.created_at, 'prev', (select t.name from tutors t where t.id = lms_student_main_tutor(p_student, ((e.created_at at time zone 'Asia/Seoul')::date - 1))), e.old_value
      from student_profile_edits e join students s on s.id = e.student_id
      where e.student_id = p_student and e.field = 'class_note_url' and e.created_at >= '2026-11-16 15:00+00'
        and lms_is_google_doc_url(e.old_value) and e.old_value is distinct from s.class_note_url
    ) y order by y.url, y.at
  ) x
$$;
revoke all on function lms_student_sub_notes(uuid) from public, anon, authenticated;

-- 화면 함수 3개에 위 링크 넣기 (지금 DB 에 있는 정의에서 노트 부분만 바꿈 — 다른 부분은 그대로)
do $$
declare
  d text; d2 text;
begin
  -- 강사 화면 수업 줄
  d := pg_get_functiondef('tutor_screen(uuid, date, date)'::regprocedure);
  if position('lms_tutor_note_url' in d) = 0 then
    d2 := replace(d, 'then s.class_note_url end', 'then lms_tutor_note_url(v_tutor, s.id, l.kst_date) end');
    if d2 = d then raise exception 'tutor_screen: note_url 자리를 못 찾음'; end if;
    execute d2;
  end if;
  -- 강사 Students 목록
  d := pg_get_functiondef('tutor_students_list(uuid)'::regprocedure);
  if position('lms_tutor_note_url' in d) = 0 then
    d2 := replace(d, 's.class_type, s.class_note_url, a.access',
                  's.class_type, lms_tutor_note_url(lms_screen_tutor(p_tutor), s.id, (now() at time zone ''Asia/Seoul'')::date), a.access');
    if d2 = d then raise exception 'tutor_students_list: class_note_url 자리를 못 찾음'; end if;
    execute d2;
  end if;
  -- 학생 '나의 학습 정보'
  d := pg_get_functiondef('student_my_info(uuid)'::regprocedure);
  if position('sub_notes' in d) = 0 then
    d2 := replace(d, '''learned_min'', ', '''sub_notes'', lms_student_sub_notes(v_student),' || chr(10) || '    ''learned_min'', ');
    if d2 = d then raise exception 'student_my_info: learned_min 자리를 못 찾음'; end if;
    execute d2;
  end if;
end $$;

-- Apps Script 가 부르는 함수 2개 (anon 키 + 금고 토큰 notes_script_token 확인)
create or replace function lms_note_token_ok(p_token text)
returns boolean
language plpgsql stable security definer set search_path = public as $$
declare v text;
begin
  if to_regclass('vault.decrypted_secrets') is null then return false; end if;
  execute $q$select decrypted_secret from vault.decrypted_secrets where name = 'notes_script_token'$q$ into v;
  return nullif(trim(v), '') is not null and p_token = trim(v);
end $$;
revoke all on function lms_note_token_ok(text) from public, anon, authenticated;

create or replace function lms_note_jobs(p_token text)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not lms_note_token_ok(p_token) then raise exception 'Unauthorized' using errcode = '42501'; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', n.id,
      'title', coalesce(nullif(trim(s.display_name), ''), s.name_en, s.code) || '_' || t.name,
      'doc_id', n.doc_id,
      'tutor_email', lower(trim(t.email)),
      'original_doc_id', substring(s.class_note_url from '/document/d/([A-Za-z0-9_-]+)'))
      order by n.created_at)
    from substitute_notes n join students s on s.id = n.student_id join tutors t on t.id = n.tutor_id
    where n.status = 'pending' and n.attempts < 5), '[]'::jsonb);
end $$;
revoke all on function lms_note_jobs(text) from public, anon, authenticated;
grant execute on function lms_note_jobs(text) to anon;

-- 결과: 문서가 만들어졌으면 done(공유 문제는 last_error 에 남김), 못 만들었으면 시도 횟수 +1
create or replace function lms_note_job_result(p_token text, p_id uuid, p_doc_id text, p_error text)
returns boolean
language plpgsql security definer set search_path = public as $$
begin
  if not lms_note_token_ok(p_token) then raise exception 'Unauthorized' using errcode = '42501'; end if;
  if nullif(trim(coalesce(p_doc_id, '')), '') is not null then
    if p_doc_id !~ '^[A-Za-z0-9_-]{20,}$' then raise exception 'bad doc id'; end if;
    update substitute_notes set status = 'done', doc_id = p_doc_id,
           doc_url = 'https://docs.google.com/document/d/' || p_doc_id || '/edit',
           last_error = left(nullif(trim(coalesce(p_error, '')), ''), 500), done_at = now()
    where id = p_id and status = 'pending';
  else
    update substitute_notes set attempts = attempts + 1, last_error = left(coalesce(p_error, 'unknown'), 500)
    where id = p_id and status = 'pending';
  end if;
  return found;
end $$;
revoke all on function lms_note_job_result(text, uuid, text, text) from public, anon, authenticated;
grant execute on function lms_note_job_result(text, uuid, text, text) to anon;
