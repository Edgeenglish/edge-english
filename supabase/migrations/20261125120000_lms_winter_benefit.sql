-- =====================================================================
-- 12~1월 겨울 특별 혜택 (정책 원본 H26(220)·(220) 보충, 2026-11-25 대표 확정)
--  ① 대상: 시즌 수업 날짜(12/1~1/31)에 수업이 있는 학생 전원 (POL-OP-17)
--  ② '겨울 특별 변경권' 학생당 시즌 총 2회. 28일 변경권과 따로 셈. 공휴일 무료는 이 2회에서 안 빠짐
--     사용 순서: 공휴일 무료 → 겨울 무료 → 일반 변경권. 6시간 전 기준은 같음
--     → 겨울 무료로 취소한 수업 = 상태 'Student canceled in advance', 결정(decision)에 season 키, 변경권 장부에는 안 씀
--     → 사용 횟수 = 적용 중(applied)인 학생 취소 중 decision.season 인 것 (운영진이 되돌리면 자동으로 1회 돌아옴)
--  ③ 겨울 무료로 뺀 수업의 보강: 마지막 수강기간(이어진 재등록 종료일, lms_makeup_until)까지,
--     그 안에 못 넣으면 원래 종료일 + 7일까지 → 보강일까지 종료일 자동 연장 (사유 'season_benefit')
--     강사 귀책 연장과 겹치면 늦은 날 하나만 (중복 없음). 보강을 취소·변경해도 종료일 안 줄어듦
--  메일: 새 메일 없음 (취소·보강 메일은 기존 그대로). 기존 표·데이터를 지우거나 덮어쓰지 않음. 다시 실행해도 같은 결과
-- =====================================================================

-- 1. 시즌 혜택 표 -------------------------------------------------------
create table if not exists season_benefits (
  key text primary key,
  name text not null,                 -- 학생 화면 이름
  starts_on date not null,            -- 수업 날짜(한국) 기준
  ends_on date not null,
  free_changes integer not null check (free_changes > 0),
  extend_days integer not null check (extend_days >= 0),
  created_at timestamptz not null default now(),
  check (ends_on >= starts_on)
);
do $$ begin
  if not exists (select 1 from pg_policies where tablename = 'season_benefits' and policyname = 'admin_read') then
    perform lms_protect('public.season_benefits'::regclass);
  end if;
end $$;
insert into season_benefits (key, name, starts_on, ends_on, free_changes, extend_days)
values ('winter_2026', '겨울 특별 변경권', '2026-12-01', '2027-01-31', 2, 7)
on conflict (key) do nothing;

-- 연장 높이 기록 (종료일을 줄이지 않기 위해 한 번 닿은 날짜를 기억)
create table if not exists season_extension_marks (
  id uuid not null default gen_random_uuid() unique,   -- 감사 기록(audit_log row_id)용
  enrollment_id uuid not null references enrollments(id),
  season_key text not null references season_benefits(key),
  until_date date not null,
  updated_at timestamptz not null default now(),
  primary key (enrollment_id, season_key)
);
do $$ begin
  if not exists (select 1 from pg_policies where tablename = 'season_extension_marks' and policyname = 'admin_read') then
    perform lms_protect('public.season_extension_marks'::regclass);
  end if;
end $$;

alter table enrollment_extensions drop constraint if exists enrollment_extensions_auto_source_check;
alter table enrollment_extensions add constraint enrollment_extensions_auto_source_check check (auto_source in ('leave_makeup', 'fault', 'season'));
alter table enrollment_extensions drop constraint if exists enrollment_extensions_reason_check;
alter table enrollment_extensions add constraint enrollment_extensions_reason_check
  check (reason in ('student_long_term_leave', 'tutor_long_term_leave', 'admin_exception', 'correction', 'tutor_fault', 'season_benefit'));

-- 2. 판정 도우미 ---------------------------------------------------------
-- 학생이 그 시즌에 쓴 겨울 무료 변경 수 (되돌린 것은 안 셈)
create or replace function lms_season_used(p_student uuid, p_key text) returns integer
language sql stable security definer set search_path = public as $$
  select count(*)::int from change_requests c
  where c.student_id = p_student and c.status = 'applied' and c.type in ('student_cancel', 'admin_cancel')
    and c.decision->>'season' = p_key
$$;
revoke all on function lms_season_used(uuid, text) from public, anon, authenticated;

-- 그 수업이 겨울 무료 변경으로 취소된 수업이면 시즌 키
create or replace function lms_season_of_lesson(p_lesson uuid) returns text
language sql stable security definer set search_path = public as $$
  select c.decision->>'season' from change_requests c
  where c.lesson_id = p_lesson and c.status = 'applied' and c.type in ('student_cancel', 'admin_cancel')
    and c.decision->>'season' is not null
  order by c.created_at desc limit 1
$$;
revoke all on function lms_season_of_lesson(uuid) from public, anon, authenticated;

-- 보강 기한을 늘릴 수강권 = lms_makeup_until 과 같은 규칙(종료일까지 결제한 이어진 재등록이 있으면 그 수강권)
create or replace function lms_season_target(p_enrollment uuid) returns uuid
language sql stable security definer set search_path = public as $$
  select coalesce((
    select n.id from enrollments n
    where n.previous_enrollment_id = e.id and n.status in ('confirmed', 'active')
      and exists (select 1 from payments x where x.enrollment_id = n.id and x.received_on <= e.final_end_date)
    order by n.final_end_date desc limit 1), e.id)
  from enrollments e where e.id = p_enrollment
$$;
revoke all on function lms_season_target(uuid) from public, anon, authenticated;

-- 원래 종료일 = 기본 종료일 + 운영진 연장 (자동 연장 제외)
create or replace function lms_original_end(p_enrollment uuid) returns date
language sql stable security definer set search_path = public as $$
  select e.base_end_date + coalesce((select sum(x.days) from enrollment_extensions x
                                     where x.enrollment_id = e.id and x.auto_source is null), 0)::int
  from enrollments e where e.id = p_enrollment
$$;
revoke all on function lms_original_end(uuid) from public, anon, authenticated;

-- 겨울 연장이 넘을 수 없는 날 = 원래 종료일 + 7일, 다음 수강권 시작 전날까지
create or replace function lms_season_cap(p_target uuid, p_key text) returns date
language sql stable security definer set search_path = public as $$
  select least(lms_original_end(t.id) + b.extend_days,
               coalesce((select min(n.start_date) - 1 from enrollments n
                         where n.student_id = t.student_id and n.id <> t.id and n.start_date > t.start_date and n.status <> 'canceled'),
                        'infinity'::date))
  from enrollments t, season_benefits b where t.id = p_target and b.key = p_key
$$;
revoke all on function lms_season_cap(uuid, text) from public, anon, authenticated;

-- 보강 기한: 원래 수업(p_source)이 겨울 무료 변경이면 겨울 기한까지, 아니면 기존 그대로
create or replace function lms_makeup_until(p_enrollment uuid, p_source uuid) returns date
language sql stable security definer set search_path = public as $$
  select case when k is null then lms_makeup_until(p_enrollment)
              else greatest(lms_makeup_until(p_enrollment), lms_season_cap(lms_season_target(p_enrollment), k)) end
  from (select case when p_source is null then null else lms_season_of_lesson(p_source) end k) q
$$;
revoke all on function lms_makeup_until(uuid, uuid) from public, anon, authenticated;

-- 3. 수업 변경 판정: 공휴일 무료 → 겨울 무료 → 일반 변경권 -------------------------
do $$
declare
  f constant text := 'lms_change_core(text,uuid,text,text,timestamptz,boolean,uuid)';
  d text;
  d2 text;
begin
  d := pg_get_functiondef(f::regprocedure);
  if position('v_season' in d) > 0 then return; end if;
  d2 := d;
  d2 := replace(d2, 'v_cr uuid;', 'v_cr uuid;
  v_season season_benefits;
  v_season_left integer := 0;
  v_season_use boolean := false;');
  d2 := replace(d2, 'v_holiday := exists (select 1 from holidays where day = l.kst_date);',
    'v_holiday := exists (select 1 from holidays where day = l.kst_date);
  -- 겨울 특별 혜택 (H26(220)): 수업 날짜가 시즌 안이면 학생당 시즌 무료 변경
  select * into v_season from season_benefits b where l.kst_date between b.starts_on and b.ends_on order by b.starts_on limit 1;
  if v_season.key is not null and p_who = ''student'' then
    perform pg_advisory_xact_lock(hashtext(''season:'' || l.student_id::text || '':'' || v_season.key));
    v_season_left := greatest(v_season.free_changes - lms_season_used(l.student_id, v_season.key), 0);
  end if;');
  d2 := replace(d2, '  elsif v_left <= 0 then',
    '  elsif v_season_left > 0 then
    v_status := ''Student canceled in advance'';
    v_season_use := true;
    v_refs := array[''POL-CHG-01'', ''H26-220''];
  elsif v_left <= 0 then');
  d2 := replace(d2, '''makeup_until'', case when lms_grants_makeup(v_status) then e.final_end_date end',
    '''makeup_until'', case when lms_grants_makeup(v_status) then
      case when v_season_use then greatest(lms_makeup_until(e.id), lms_season_cap(lms_season_target(e.id), v_season.key)) else e.final_end_date end end');
  d2 := replace(d2, '''reward_won'', v_reward_won, ''holiday'', v_holiday);',
    '''reward_won'', v_reward_won, ''holiday'', v_holiday,
    ''season'', case when v_season_use then v_season.key end,
    ''season_left'', case when v_season.key is not null and p_who = ''student'' then v_season_left end,
    ''season_left_after'', case when v_season.key is not null and p_who = ''student'' then v_season_left - case when v_season_use then 1 else 0 end end);');
  if (length(d2) - length(d)) < 900 or position('v_season_use := true' in d2) = 0 or position('''season_left_after''' in d2) = 0
     or position('lms_season_cap(lms_season_target(e.id), v_season.key)' in d2) = 0 or position('pg_advisory_xact_lock' in d2) = 0 then
    raise exception 'lms_change_core 패치 실패';
  end if;
  execute d2;
end $$;

-- 4. 보강 날짜 찾기·신청·확정·시간 확인·운영자 보강 옮기기: 겨울 보강은 겨울 기한까지 --------------
do $$
declare
  f text;
  src text;
  d text;
  d2 text;
  pairs text[][] := array[
    array['lms_makeup_options(uuid,uuid,uuid)', 'p_lesson'],
    array['lms_makeup_options_for_tutor(uuid,uuid,uuid,uuid)', 'p_lesson'],
    array['lms_makeup_request_for_tutor(uuid,uuid,jsonb,timestamptz,text,uuid,uuid,uuid)', 'p_lesson'],
    array['lms_makeup_book(uuid,timestamptz,text,boolean)', 'r.source_lesson_id'],
    array['lms_makeup_slot_ok(uuid,timestamptz)', 'r.source_lesson_id'],
    array['admin_makeup_reschedule(uuid,timestamptz,text,text)', '(select xs.makeup_of from lessons xs where xs.id = p_lesson)']];
  i integer;
begin
  for i in 1 .. array_length(pairs, 1) loop
    f := pairs[i][1]; src := pairs[i][2];
    d := pg_get_functiondef(f::regprocedure);
    if position('lms_makeup_until(e.id, ' in d) > 0 then continue; end if;
    d2 := replace(d, 'lms_makeup_until(e.id)', 'lms_makeup_until(e.id, ' || src || ')');
    if d2 = d then raise exception '% 패치 실패', f; end if;
    execute d2;
  end loop;
end $$;

-- 5. 종료일 자동 연장 (겨울 보강) ----------------------------------------------
-- 겨울 보강 = 겨울 무료 변경으로 취소한 수업의 보강 수업
create or replace function lms_is_season_makeup(p_lesson uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from lessons x where x.id = p_lesson and x.makeup_of is not null
                 and lms_season_of_lesson(x.makeup_of) is not null)
$$;
revoke all on function lms_is_season_makeup(uuid) from public, anon, authenticated;

create or replace function lms_season_sync_student(p_student uuid) returns void
language plpgsql security definer set search_path = public as $$
declare
  v_actor uuid := coalesce(nullif(current_setting('app.actor_id', true), '')::uuid, auth.uid());
  m record;
  t enrollments;
  v_mark date;
  v_wo date;
  v_cur integer;
  v_target integer;
  v_next date;
begin
  if not exists (select 1 from change_requests c where c.student_id = p_student and c.status in ('applied', 'reverted')
                 and c.decision->>'season' is not null)
     and not exists (select 1 from season_extension_marks k join enrollments e on e.id = k.enrollment_id where e.student_id = p_student) then
    return;
  end if;
  -- 시즌·대상 수강권별로 마지막 겨울 보강일 (원래 종료일 + 7일 넘지 않음) → 높이 기록은 올리기만
  for m in
    select lms_season_target(x.enrollment_id) tid, lms_season_of_lesson(x.makeup_of) k, max(x.kst_date) last_day
    from lessons x
    where x.student_id = p_student and x.makeup_of is not null and x.voided_at is null and x.state <> 'canceled'
      and lms_season_of_lesson(x.makeup_of) is not null
    group by 1, 2
  loop
    v_mark := least(m.last_day, lms_season_cap(m.tid, m.k));
    insert into season_extension_marks (enrollment_id, season_key, until_date) values (m.tid, m.k, v_mark)
    on conflict (enrollment_id, season_key) do update set until_date = greatest(season_extension_marks.until_date, excluded.until_date),
      updated_at = case when excluded.until_date > season_extension_marks.until_date then now() else season_extension_marks.updated_at end;
  end loop;

  for t in select e.* from enrollments e where e.student_id = p_student
             and exists (select 1 from season_extension_marks k where k.enrollment_id = e.id) for update loop
    select max(k.until_date) into v_mark from season_extension_marks k where k.enrollment_id = t.id;
    select t.base_end_date + coalesce(sum(x.days) filter (where x.auto_source is distinct from 'season'), 0)::int,
           coalesce(sum(x.days) filter (where x.auto_source = 'season'), 0)::int
    into v_wo, v_cur from enrollment_extensions x where x.enrollment_id = t.id;
    -- 다른 연장으로 이미 그 날까지 늘어났으면 겨울 몫은 0 (늦은 날 하나만, 중복 없음). 종료일은 줄지 않음
    v_target := greatest(v_mark - v_wo, 0);
    select min(n.start_date) into v_next from enrollments n
    where n.student_id = t.student_id and n.id <> t.id and n.start_date > t.start_date and n.status <> 'canceled';
    if v_next is not null and v_wo + v_target >= v_next then v_target := greatest(v_next - 1 - v_wo, 0); end if;
    if v_target = v_cur then continue; end if;
    if v_actor is null then raise exception '처리한 사람을 알 수 없습니다.'; end if;
    begin
      insert into enrollment_extensions (enrollment_id, days, reason, note, approved_by, auto_source)
      values (t.id, v_target - v_cur, 'season_benefit', 'LMS 겨울 특별 혜택 보강 자동 연장 (H26(220))', v_actor, 'season');
    exception when exclusion_violation then
      raise exception '다음 수강권 기간과 겹쳐 종료일을 늘릴 수 없습니다. 보강 날짜를 다시 확인해 주세요.' using hint = 'next_enrollment';
    end;
  end loop;
end $$;
revoke all on function lms_season_sync_student(uuid) from public, anon, authenticated;

-- 강사 귀책 연장은 겨울 연장·겨울 보강을 빼고 계산 (겹치면 늦은 날 하나만 — 위 겨울 계산이 나머지만 더함)
do $$
declare
  f constant text := 'lms_fault_sync_extension(uuid)';
  d text;
  d2 text;
begin
  d := pg_get_functiondef(f::regprocedure);
  if position('lms_is_season_makeup' in d) > 0 then return; end if;
  d2 := replace(d, 'filter (where x.auto_source is distinct from ''fault'')',
                   'filter (where x.auto_source is distinct from ''fault'' and x.auto_source is distinct from ''season'')');
  d2 := replace(d2, 'where l.enrollment_id = e.id and l.voided_at is null and l.state <> ''canceled'';',
                    'where l.enrollment_id = e.id and l.voided_at is null and l.state <> ''canceled'' and not lms_is_season_makeup(l.id);');
  if position('is distinct from ''season''' in d2) = 0 or position('lms_is_season_makeup' in d2) = 0 then
    raise exception 'lms_fault_sync_extension 패치 실패';
  end if;
  execute d2;
end $$;

-- 수업 상태·날짜가 바뀔 때마다 (강사 귀책 연장 트리거 lessons_zz_ 뒤에 돎)
create or replace function lessons_season_extension() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  perform lms_season_sync_student(new.student_id);
  return null;
end $$;
revoke all on function lessons_season_extension() from public, anon, authenticated;
drop trigger if exists lessons_zzz_season_extension on lessons;
create trigger lessons_zzz_season_extension after insert or update of state, starts_at, class_status, voided_at, enrollment_id on lessons
  for each row execute function lessons_season_extension();

-- 6. 학생 화면: 겨울 특별 변경권 남은 횟수 ---------------------------------------
-- 지금 또는 앞으로의 시즌 중, 학생 수강기간이 시즌과 겹치는 것 하나 (없으면 null)
create or replace function student_season_credits(p_student uuid default null) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_student uuid := lms_screen_student(p_student);
  v_today date := (now() at time zone 'Asia/Seoul')::date;
  b season_benefits;
  v_used integer;
begin
  select s.* into b from season_benefits s
  where s.ends_on >= v_today
    and exists (select 1 from enrollments e where e.student_id = v_student and e.status not in ('canceled', 'completed')
                and e.start_date <= s.ends_on and e.final_end_date >= s.starts_on)
  order by s.starts_on limit 1;
  if b.key is null then return null; end if;
  v_used := lms_season_used(v_student, b.key);
  return jsonb_build_object('key', b.key, 'name', b.name, 'starts_on', b.starts_on, 'ends_on', b.ends_on,
                            'granted', b.free_changes, 'used', v_used, 'left', greatest(b.free_changes - v_used, 0));
end $$;
revoke all on function student_season_credits(uuid) from public, anon;
grant execute on function student_season_credits(uuid) to authenticated;

-- 7. 변경권 내역: 겨울 무료 변경 줄 ('winter') ------------------------------------
do $$
declare
  f constant text := 'student_credit_history(uuid)';
  d text;
  d2 text;
begin
  d := pg_get_functiondef(f::regprocedure);
  if position('''winter''' in d) > 0 then return; end if;
  d2 := replace(d, 'case when coalesce((c.decision->>''holiday'')::boolean, false) then ''holiday''',
                   'case when c.decision->>''season'' is not null then ''winter''
                  when coalesce((c.decision->>''holiday'')::boolean, false) then ''holiday''');
  if d2 = d then raise exception 'student_credit_history 패치 실패'; end if;
  execute d2;
end $$;
