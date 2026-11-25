-- =====================================================================
-- 강사 임시 근무 지역 변경 → 대체강사 경로 A+ (정책 원본 H26(218) 보충3, 대표 11/25)
--  같은 주에 새 시간이 없는 회차에만 학생이 '대체강사와 수업' → 그 수업 시각만 tutor_time_off 를 새 종류
--  'temp_location' 으로 만들고 leave_items 로 기존 운영진 휴무 화면(대체 강사 찾기 → 확정 안내)에 올림
--  실제 휴무와 구분: 휴무 목록·통계(kind='leave' 만 셈) · 수강기간 연장(보강 선택 막음) · 학생 휴무 안내(leave_options 안 만듦)
--  대체강사를 못 구하면 운영진 [운영진 확인으로 돌리기] → 기록 철회 + 그 회차 '운영진 확인'(H26(218) 종료일 안 연장 규칙)
--  대표 11/25 답: 대체강사 요청 문구 'unavailable at this time'(임시 근무 지역만) · 학생 답은 [좋아요]만 ·
--   강사 화면 'Cover needed' / 'Cover confirmed' · 학생 화면 '🕒 대체강사 배정 중' · 학생 카톡 문구(운영진 복사용, 화면 코드)
--  메일: 학생이 고를 때는 없음. 그 뒤는 기존 대체 수업 절차와 같음 (대체강사 요청 메일 → 확정 메일)
-- =====================================================================

alter table tutor_time_off drop constraint if exists tutor_time_off_kind_check;
alter table tutor_time_off add constraint tutor_time_off_kind_check check (kind in ('block', 'leave', 'temp_location'));

alter table temp_location_moves drop constraint if exists temp_location_moves_state_check;
alter table temp_location_moves add constraint temp_location_moves_state_check
  check (state in ('proposed', 'returned', 'later', 'confirmed', 'admin', 'admin_done', 'substitute'));
alter table temp_location_moves add column if not exists leave_item_id uuid references leave_items(id);
alter table temp_location_moves add column if not exists time_off_id uuid references tutor_time_off(id);

-- 대상 회차: 'substitute'(대체강사 절차 중) 줄은 수업이 끝나기 전까지 보임 (나머지는 20261125100000 그대로)
create or replace function lms_ttl_rows(p_tutor uuid, p_student uuid)
returns table (key text, lesson_id uuid, pending_id uuid, tutor_id uuid, student_id uuid, enrollment_id uuid, location_id uuid,
               orig_starts_at timestamptz, minutes integer, state text, new_starts_at timestamptz, conflict text, batch_id uuid, move_id uuid)
language sql stable security definer set search_path = public as $$
  with det as (
    select 'l:' || l.id as key, l.id as lesson_id, null::uuid as pending_id, l.tutor_id, l.student_id, l.enrollment_id,
           lms_tutor_location_at(l.tutor_id, l.starts_at) as location_id, l.starts_at as orig,
           (extract(epoch from l.ends_at - l.starts_at) / 60)::int as minutes
    from lessons l
    where (p_tutor is null or l.tutor_id = p_tutor) and (p_student is null or l.student_id = p_student)
      and l.kind = 'regular' and l.state = 'scheduled' and l.voided_at is null and l.original_tutor_id is null
      and l.enrollment_id is not null and l.starts_at > now()
      and lms_tutor_location_at(l.tutor_id, l.starts_at) is not null
      and not lms_tutor_available(l.tutor_id, l.starts_at)
      and not exists (select 1 from tutor_time_off o where o.tutor_id = l.tutor_id and o.starts_at < l.ends_at and l.starts_at < o.ends_at)
      and not exists (select 1 from leave_items li where li.lesson_id = l.id and li.withdrawn_at is null)
      and not exists (select 1 from temp_location_moves m where m.lesson_id = l.id)
    union all
    select 'p:' || p.id, null::uuid, p.id, p.tutor_id, p.student_id, p.enrollment_id,
           lms_tutor_location_at(p.tutor_id, (p.original_date + p.time_kst) at time zone 'Asia/Seoul'),
           (p.original_date + p.time_kst) at time zone 'Asia/Seoul', e.duration_min::int
    from plan_pending_lessons p join enrollments e on e.id = p.enrollment_id
    where (p_tutor is null or p.tutor_id = p_tutor) and (p_student is null or p.student_id = p_student)
      and p.resolved_at is null
      and not exists (select 1 from temp_location_moves m where m.pending_id = p.id)
  )
  select d.key, d.lesson_id, d.pending_id, d.tutor_id, d.student_id, d.enrollment_id, d.location_id, d.orig, d.minutes,
         null::text, null::timestamptz, null::text, null::uuid, null::uuid
  from det d where d.location_id is not null
  union all
  select 'l:' || m.lesson_id, m.lesson_id, null::uuid, m.tutor_id, m.student_id, m.enrollment_id,
         lms_tutor_location_at(l.tutor_id, l.starts_at), l.starts_at, m.minutes,
         null::text, null::timestamptz, null::text, null::uuid, m.id
  from temp_location_moves m join lessons l on l.id = m.lesson_id
  where (p_tutor is null or m.tutor_id = p_tutor) and (p_student is null or m.student_id = p_student)
    and m.state = 'confirmed' and lms_ttl_needs_move(m.lesson_id)
  union all
  select case when m.lesson_id is not null then 'l:' || m.lesson_id else 'p:' || m.pending_id end,
         m.lesson_id, m.pending_id, m.tutor_id, m.student_id, m.enrollment_id, m.location_id, m.orig_starts_at, m.minutes,
         m.state, m.new_starts_at, m.conflict, m.batch_id, m.id
  from temp_location_moves m
  where (p_tutor is null or m.tutor_id = p_tutor) and (p_student is null or m.student_id = p_student)
    and ((m.state = 'confirmed' and m.lesson_id is not null and not lms_ttl_needs_move(m.lesson_id))
         or (m.state = 'confirmed' and m.pending_id is not null
             and not (m.result_lesson_id is not null and (lms_ttl_needs_move(m.result_lesson_id)
                      or exists (select 1 from temp_location_moves m2 where m2.lesson_id = m.result_lesson_id))))
         or m.state in ('admin', 'admin_done')
         or (m.state = 'substitute' and exists (select 1 from lessons l where l.id = m.lesson_id and l.voided_at is null and l.ends_at > now()))
         or (m.state not in ('confirmed', 'admin', 'admin_done', 'substitute') and m.lesson_id is not null
             and exists (select 1 from lessons l where l.id = m.lesson_id and l.state = 'scheduled' and l.voided_at is null
                         and l.starts_at > now() and not lms_tutor_available(l.tutor_id, l.starts_at)))
         or (m.state not in ('confirmed', 'admin', 'admin_done', 'substitute') and m.pending_id is not null
             and exists (select 1 from plan_pending_lessons p where p.id = m.pending_id and p.resolved_at is null)))
$$;

-- To do 묶음: 대체강사 절차로 넘긴 회차는 '처리 끝'으로 셈 (확정·운영진 처리와 같게)
create or replace function lms_ttl_items(p_tutor uuid, p_student uuid)
returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(g order by g ->> 'first'), '[]'::jsonb) from (
    select jsonb_build_object(
             'tutor_id', r.tutor_id, 'tutor', tu.name, 'student_id', r.student_id,
             'student', lms_tutor_student_label(s.name_en, s.display_name),
             'location_id', r.location_id, 'city', loc.city, 'timezone', loc.timezone, 'from', loc.starts_on, 'to', loc.ends_on,
             'first', min(r.orig_starts_at),
             'rc_pending', exists (select 1 from regular_change_requests q where q.student_id = r.student_id and q.status = 'pending'),
             'rows', jsonb_agg(jsonb_build_object('key', r.key, 'orig', r.orig_starts_at, 'minutes', r.minutes, 'state', r.state,
                                                  'new', r.new_starts_at, 'conflict', r.conflict) order by r.orig_starts_at)) as g
    from lms_ttl_rows(p_tutor, p_student) r
    join tutors tu on tu.id = r.tutor_id
    join students s on s.id = r.student_id
    join tutor_locations loc on loc.id = r.location_id
    group by r.tutor_id, tu.name, r.student_id, s.name_en, s.display_name, r.location_id, loc.city, loc.timezone, loc.starts_on, loc.ends_on
    having bool_or(r.state is null or r.state not in ('confirmed', 'admin_done', 'substitute'))
  ) x
$$;

-- 한 회차를 대체강사 절차로: 그 수업 시각만 '임시 근무 지역' 기록 + leave_items(미정, 학생 안내 글 없음)
--  협의 필요 회차는 원래 시각에 수업을 만든 뒤 넘김 (처리 줄은 그 수업을 가리키게 바꿈)
create or replace function lms_ttl_to_sub(p_tutor uuid, p_student uuid, p_key text, p_batch uuid, p_by text)
returns text
language plpgsql security definer set search_path = public as $$
declare
  r record;
  p plan_pending_lessons;
  l lessons;
  v_off uuid;
  v_item uuid;
begin
  select * into r from lms_ttl_rows(p_tutor, p_student) x where x.key = p_key;
  if not found then return 'gone'; end if;
  perform set_config('app.actor_via', 'ttl_substitute', true);
  if r.lesson_id is not null then
    select * into l from lessons where id = r.lesson_id for update;
    if l.state <> 'scheduled' or l.voided_at is not null or l.starts_at <= now() then return 'gone'; end if;
  else
    select * into p from plan_pending_lessons where id = r.pending_id for update;
    if p.resolved_at is not null then return 'gone'; end if;
    begin
      insert into lessons (enrollment_id, student_id, tutor_id, kind, seq, starts_at, ends_at, created_by)
      values (r.enrollment_id, r.student_id, r.tutor_id, 'regular', p.seq, r.orig_starts_at, r.orig_starts_at + make_interval(mins => r.minutes), auth.uid())
      returning * into l;
    exception when exclusion_violation or unique_violation then
      perform lms_ttl_save(to_jsonb(r), 'admin', null, 'busy', p_batch, p_by, null);
      return 'admin';
    end;
    update plan_pending_lessons set lesson_id = l.id, resolved_at = now() where id = p.id;
  end if;
  if exists (select 1 from leave_items li where li.lesson_id = l.id and li.withdrawn_at is null) then return 'gone'; end if;

  insert into tutor_time_off (tutor_id, starts_at, ends_at, kind, reason, created_by)
  values (l.tutor_id, l.starts_at, l.ends_at, 'temp_location', 'Temporary work location', auth.uid())
  returning id into v_off;
  -- 예전에 철회된 줄이 있으면 다시 씀 (수업당 1줄, 지우기 금지)
  update leave_items set time_off_id = v_off, tutor_id = l.tutor_id, student_id = l.student_id, enrollment_id = l.enrollment_id,
         starts_at = l.starts_at, ends_at = l.ends_at, choice = 'undecided', sub_tutor_id = null, sub_stage = null, sub_lesson_id = null,
         decided_at = null, decided_by = null, lesson_gone_at = null, withdrawn_at = null, ask_mailed_at = null, ask_nudged_at = null
  where lesson_id = l.id
  returning id into v_item;
  if v_item is null then
    insert into leave_items (time_off_id, tutor_id, student_id, enrollment_id, lesson_id, starts_at, ends_at, choice, created_by)
    values (v_off, l.tutor_id, l.student_id, l.enrollment_id, l.id, l.starts_at, l.ends_at, 'undecided', auth.uid())
    returning id into v_item;
  end if;

  perform lms_ttl_save(to_jsonb(r), 'substitute', null, null, p_batch, p_by, l.id);
  update temp_location_moves set lesson_id = l.id, pending_id = null, leave_item_id = v_item, time_off_id = v_off, decided_at = now()
  where (r.lesson_id is not null and lesson_id = r.lesson_id) or (r.pending_id is not null and pending_id = r.pending_id);
  return 'substitute';
end $$;

-- 신청 공통 (20261125100000 에 {key, sub:true} 추가 — 학생만, 같은 주에 고를 시간이 없는 회차만)
create or replace function lms_ttl_submit(p_tutor uuid, p_student uuid, p_items jsonb, p_by text)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  it jsonb;
  r record;
  v_batch uuid := gen_random_uuid();
  v_at timestamptz;
  c text;
  st text;
  n_ok integer := 0;
  n_admin integer := 0;
  n_sent integer := 0;
  n_sub integer := 0;
  v_weeks jsonb := '[]'::jsonb;
  v_opt jsonb;
  w record;
begin
  perform pg_advisory_xact_lock(hashtextextended('ttl:' || p_tutor, 0));
  if exists (select 1 from regular_change_requests q where q.student_id = p_student and q.status = 'pending') then
    raise exception '%', case when p_by = 'tutor' then 'The student has a pending regular schedule change. Please try again after it is processed.'
                              else '정규 시간 변경 신청이 처리된 뒤에 고를 수 있어요.' end using hint = 'ttl';
  end if;
  if exists (select 1 from temp_location_moves m where m.tutor_id = p_tutor and m.student_id = p_student and m.state = 'proposed') then
    raise exception '%', case when p_by = 'tutor' then 'Waiting for the student to confirm your last request.'
                              else '선생님이 신청한 수업 시간을 먼저 확인해 주세요.' end using hint = 'ttl';
  end if;
  if jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then
    raise exception '%', case when p_by = 'tutor' then 'Choose at least one class.' else '고른 수업이 없어요.' end using hint = 'ttl';
  end if;
  if exists (select 1 from jsonb_array_elements(p_items) x where (x ->> 'sub')::boolean is true) then
    if p_by <> 'student' then raise exception 'Only the student can choose a cover tutor.' using hint = 'ttl'; end if;
    v_opt := lms_ttl_options(p_tutor, p_student);
  end if;
  for it in select * from jsonb_array_elements(p_items) loop
    select * into r from lms_ttl_rows(p_tutor, p_student) x where x.key = it ->> 'key';
    if not found or not (r.state is null or r.state in ('later', 'returned')) then
      raise exception '%', case when p_by = 'tutor' then 'This class was already handled. Please reopen the list.'
                                else '이미 처리된 수업이 있어요. 창을 닫고 다시 열어 주세요.' end using hint = 'ttl';
    end if;
    if (it ->> 'later')::boolean is true then
      perform lms_ttl_save(to_jsonb(r), 'later', null, null, v_batch, p_by, null);
      continue;
    end if;
    if (it ->> 'sub')::boolean is true then
      if not exists (select 1 from jsonb_array_elements(v_opt -> 'rows') o
                     where o ->> 'key' = r.key and jsonb_array_length(coalesce(o -> 'cands', '[]'::jsonb)) = 0) then
        raise exception '같은 주에 고를 수 있는 시간이 생겼어요. 창을 닫고 다시 열어 주세요.' using hint = 'ttl';
      end if;
      st := lms_ttl_to_sub(p_tutor, p_student, r.key, v_batch, p_by);
      if st = 'substitute' then n_sub := n_sub + 1; elsif st = 'admin' then n_admin := n_admin + 1; end if;
      continue;
    end if;
    v_at := case when (it ->> 'admin')::boolean is true then null else (it ->> 'at')::timestamptz end;
    if v_at is null and (it ->> 'admin')::boolean is not true then
      raise exception '%', case when p_by = 'tutor' then 'Choose a time for every class.' else '시간을 고르지 않은 수업이 있어요.' end using hint = 'ttl';
    end if;
    if p_by = 'tutor' then
      if v_at is not null then
        c := lms_ttl_conflict(r.tutor_id, r.student_id, r.enrollment_id, r.location_id, r.lesson_id, r.orig_starts_at, r.minutes, v_at);
        if c is not null or not lms_tutor_available(r.tutor_id, v_at) then
          raise exception 'One of the times is no longer available (%). Please reopen the list.', coalesce(c, 'hours') using hint = 'ttl';
        end if;
      end if;
      perform lms_ttl_save(to_jsonb(r), 'proposed', v_at, null, v_batch, p_by, null);
      n_sent := n_sent + 1;
    else
      st := lms_ttl_confirm_one(p_tutor, p_student, r.key, v_at, v_batch, p_by);
      if st = 'confirmed' then n_ok := n_ok + 1; else n_admin := n_admin + 1; end if;
      v_weeks := v_weeks || jsonb_build_object('e', r.enrollment_id, 'w', lms_rc_monday((r.orig_starts_at at time zone 'Asia/Seoul')::date));
    end if;
  end loop;
  for w in select distinct (x ->> 'e')::uuid e, (x ->> 'w')::date wk from jsonb_array_elements(v_weeks) x loop
    perform lms_ttl_reseq(w.e, w.wk);
  end loop;
  if p_by = 'tutor' then perform lms_ttl_proposed_mail(p_tutor, p_student, v_batch);
  else perform lms_ttl_confirmed_mail(v_batch); end if;
  return jsonb_build_object('ok', n_ok, 'admin', n_admin, 'sent', n_sent, 'sub', n_sub, 'batch', v_batch,
    'left', (select count(*) from lms_ttl_rows(p_tutor, p_student) x where x.state is null or x.state in ('later', 'returned')));
end $$;

-- 대체강사를 못 구함 / 학생이 운영진에게 문의 → 운영진이 [운영진 확인으로 돌리기]: 기록 철회 + 그 회차 '운영진 확인'
--  확정된 대체 수업은 먼저 휴무 화면 [다시 고르기]로 되돌린 뒤. 대체강사에게 요청 메일이 이미 갔으면 기존과 같이 '요청 끝' 메일이 감
create or replace function admin_ttl_sub_back(p_item uuid)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  it leave_items;
  o tutor_time_off;
begin
  if not is_admin() then raise exception '운영자(추가 인증 완료)만 처리할 수 있습니다.' using errcode = '42501'; end if;
  select * into it from leave_items where id = p_item for update;
  if not found then raise exception '수업이 없습니다.'; end if;
  select * into o from tutor_time_off where id = it.time_off_id for update;
  if o.kind is distinct from 'temp_location' or it.withdrawn_at is not null then raise exception '임시 근무 지역 대체 수업이 아닙니다.'; end if;
  if it.sub_stage = 'confirmed' then raise exception '확정된 대체 수업은 [다시 고르기]로 먼저 되돌려 주세요.'; end if;
  perform pg_advisory_xact_lock(hashtextextended('ttl:' || it.tutor_id, 0));
  perform set_config('app.actor_id', me::text, true);
  perform set_config('app.actor_via', 'admin_ttl_sub_back', true);
  update lesson_notices set status = 'not_needed' where leave_item_id = it.id and status = 'pending';
  update leave_items set choice = 'undecided', sub_tutor_id = null, sub_stage = null, sub_lesson_id = null,
         decided_at = null, decided_by = null, withdrawn_at = now()
  where id = it.id;
  update tutor_time_off
  set withdrawn_range = tstzrange(starts_at, ends_at), starts_at = timestamptz '1900-01-01 00:00:00+09', ends_at = timestamptz '1900-01-01 00:00:01+09',
      withdrawn_at = now(), withdrawn_by = me, withdraw_note = '대체강사 없음 → 운영진 확인'
  where id = o.id;
  update temp_location_moves set state = 'admin', conflict = 'no_sub', by_kind = 'admin', decided_at = now(), orig_starts_at = it.starts_at
  where leave_item_id = it.id;
  return jsonb_build_object('state', 'admin');
end $$;

revoke all on function lms_ttl_to_sub(uuid, uuid, text, uuid, text), lms_ttl_rows(uuid, uuid), lms_ttl_items(uuid, uuid),
  lms_ttl_submit(uuid, uuid, jsonb, text) from public, anon, authenticated;
grant execute on function admin_ttl_sub_back(uuid) to authenticated;

-- ---------------------------------------------------------------------
-- 기존 함수는 지금 DB 정의에 몇 군데만 끼워 넣음 (다른 세션 변경을 덮어쓰지 않게). 끼울 곳이 없으면 멈춤
-- ---------------------------------------------------------------------
do $$
declare
  d text;
  n text;
  v_ttl text := 'exists (select 1 from leave_items tli join tutor_time_off tto on tto.id = tli.time_off_id where tli.lesson_id = l.id and tli.withdrawn_at is null and tto.kind = ''temp_location'')';
begin
  -- 강사 화면: 임시 근무 지역 대체 수업 표시 ('Cover needed' / 'Cover confirmed')
  d := pg_get_functiondef('tutor_screen'::regproc);
  if position('ttl_cover' in d) = 0 then
    n := replace(d, $x$'leave_open', l.state = 'scheduled' and exists (select 1 from leave_items li where li.lesson_id = l.id and li.lesson_gone_at is null$x$,
                 $x$'ttl_cover', $x$ || v_ttl || $x$,
        'leave_open', l.state = 'scheduled' and exists (select 1 from leave_items li where li.lesson_id = l.id and li.lesson_gone_at is null$x$);
    n := replace(n, $x$'covering', false, 'covered_by_other', true,$x$, $x$'covering', false, 'covered_by_other', true, 'ttl_cover', $x$ || v_ttl || ',');
    if (length(n) - length(replace(n, 'ttl_cover', ''))) / length('ttl_cover') <> 2 then raise exception 'tutor_screen: 끼울 곳을 못 찾음'; end if;
    execute n;
  end if;

  -- 학생 화면: 수업 '🕒 대체강사 배정 중' · 대체강사 확인 창을 휴무 안내와 나눔
  d := pg_get_functiondef('student_screen'::regproc);
  if position('ttl_cover' in d) = 0 then
    n := replace(d, $x$'leave_open', exists (select 1 from leave_items li where li.lesson_id = l.id and li.lesson_gone_at is null$x$,
                 $x$'ttl_cover', $x$ || v_ttl || $x$,
        'leave_open', exists (select 1 from leave_items li where li.lesson_id = l.id and li.lesson_gone_at is null$x$);
    n := replace(n, $x$'off_from', o.starts_at, 'off_to', o.ends_at)$x$, $x$'off_from', o.starts_at, 'off_to', o.ends_at, 'off_kind', o.kind)$x$);
    if position('ttl_cover' in n) = 0 or position('off_kind' in n) = 0 then raise exception 'student_screen: 끼울 곳을 못 찾음'; end if;
    execute n;
  end if;

  -- 강사 일정 화면: 임시 근무 지역 기록은 막은 시간처럼 그리지 않음 (근무 시간 밖이라 이미 빈 칸, 수업 줄에 'Cover needed')
  d := pg_get_functiondef('tutor_schedule'::regproc);
  if position('temp_location' in d) = 0 then
    n := replace(d, $x$from tutor_time_off o where o.tutor_id = v_tutor and o.starts_at < v_b and v_a < o.ends_at)$x$,
                 $x$from tutor_time_off o where o.tutor_id = v_tutor and o.kind <> 'temp_location' and o.starts_at < v_b and v_a < o.ends_at)$x$);
    if n = d then raise exception 'tutor_schedule: 끼울 곳을 못 찾음'; end if;
    execute n;
  end if;

  -- 대체강사 요청 메일: 임시 근무 지역만인 묶음은 'unavailable at this time' (대표 11/25 '넣어')
  d := pg_get_functiondef('lms_cover_mail_run'::regproc);
  if position('unavailable at this time' in d) = 0 then
    n := replace(d, $x$'One of our tutors is on leave. ' ||$x$,
                 $x$case when exists (select 1 from leave_items i2 join tutor_time_off t2 on t2.id = i2.time_off_id where i2.id = any(v_ids) and t2.kind = 'leave')
             then 'One of our tutors is on leave. ' else 'One of our tutors is unavailable at this time. ' end ||$x$);
    if n = d then raise exception 'lms_cover_mail_run: 끼울 곳을 못 찾음'; end if;
    execute n;
  end if;

  -- 임시 근무 지역 회차는 '기존 강사와 보강'(= 휴무 보강 + 수강기간 자동 연장)으로 못 바꿈 → 운영진 확인으로 돌리기
  d := pg_get_functiondef('lms_leave_choose_core'::regproc);
  if position('temp_location' in d) = 0 then
    n := replace(d, $x$raise exception '휴무인 강사는 대체강사가 될 수 없습니다.'; end if;$x$,
                 $x$raise exception '휴무인 강사는 대체강사가 될 수 없습니다.'; end if;
    if p_choice = 'wait' and exists (select 1 from tutor_time_off t where t.id = it.time_off_id and t.kind = 'temp_location') then
      raise exception '임시 근무 지역 수업은 보강으로 바꿀 수 없어요. [운영진 확인으로 돌리기]를 눌러 주세요.';
    end if;$x$);
    if n = d then raise exception 'lms_leave_choose_core: 끼울 곳을 못 찾음'; end if;
    execute n;
  end if;
  d := pg_get_functiondef('student_leave_answer'::regproc);
  if position('temp_location' in d) = 0 then
    n := replace(d, $x$  if p_answer = 'ok' then$x$,
                 $x$  if p_answer = 'makeup' and exists (select 1 from leave_items i join tutor_time_off t on t.id = i.time_off_id
                                        where i.id = any(p_items) and t.kind = 'temp_location') then
    raise exception '운영진에게 문의해 주세요.' using hint = 'not_open';
  end if;
  if p_answer = 'ok' then$x$);
    if n = d then raise exception 'student_leave_answer: 끼울 곳을 못 찾음'; end if;
    execute n;
  end if;
end $$;
