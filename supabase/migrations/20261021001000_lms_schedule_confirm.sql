-- =====================================================================
-- 신규 배정 확정 관리 (2026-10-21, 정책 원본 H22 · B01 · D-50 4번 절차)
-- 사고: 강사가 '그 일정 가능'이라고만 답했고, 운영자가 학생에게만 최종 확정을 보내고 강사에게는 안 보냄 → 학생만 기다림
--
-- 구조
--  1. 일정안(schedule_plans): 등록 하나에 버전 1, 2, … 강사·요일·시각·첫 수업일 한 벌
--     - proposed  강사에게 제안함, 답 대기. 수업은 아직 만들지 않음 (강사 '가능' 답 ≠ 확정)
--     - confirmed 운영자가 '강사 가능 → 확정'을 한 번 누름 → 같은 트랜잭션에서 정규 일정·수업 생성 + 양쪽 최종 안내 2건 생성
--     - declined / withdrawn 강사가 안 됨 / 운영자가 다른 안으로 바꿈 (지우지 않고 남김)
--  2. 최종 안내(schedule_notices): 확정된 일정안 × 받는 사람(학생·강사) = 정확히 1건씩 (unique = 중복 방지 키)
--     - 일정 확정 상태와 안내 상태는 따로. 둘 다 '보냄'이 되어야 신규 매칭 업무가 끝남 (한쪽만이면 열려 있음)
--     - 지금은 자동 발송 연결이 없음 → 운영자가 [문구 복사]를 누른 시각을 '보냄'으로 기록 (sent_via = 'copy').
--       복사 = 보냄이지 '받음·읽음'이 아님. 받음·읽음 확인 칸은 채널이 정해지면 추가 (H22 3번)
--     - 나중에 자동 발송기(이메일·캘린더·WhatsApp API 등, 채널 미결정)가 붙으면 lms_notice_result 로 결과를 기록.
--       재시도는 '보냄'이 아닌 건만 (pending·failed). 결과가 불명확(unknown)하면 자동 재시도하지 않고 운영자 확인
--  3. 확정 후 일정 변경(강사·시각·시작일)은 아직 없음 → 새 버전을 만들고 새 안내 2건을 받아야 함 (예전 안내는 새 일정의 근거가 아님).
--     그 기능을 만들 때 'superseded' 상태를 추가한다. 지금은 확정된 안이 있으면 새 확정을 거절
--
-- 미결정 (대표 질문, 코드에 기본값 넣지 않음): 발송 채널·자동화, 강사 확인 회신 의무, 경고 시각(첫 수업 몇 시간 전 등), 답 대기 경고 시각
-- 권한: 운영자(is_admin, TOTP)만. 표에는 앱 쓰기 권한 없음 — 함수로만 (POL-AC-07)
-- 다시 실행해도 같은 결과
-- =====================================================================

create table if not exists schedule_plans (
  id uuid primary key,                         -- 화면이 만든 요청 번호 (같은 제안 두 번 눌러도 1건)
  enrollment_id uuid not null references enrollments(id),
  version integer not null check (version >= 1),
  tutor_id uuid not null references tutors(id),
  slots jsonb not null,                        -- [{"weekday":2,"time":"20:00"}] 한국 시각
  start_date date not null,                    -- 첫 정규 수업일
  state text not null default 'proposed' check (state in ('proposed', 'confirmed', 'declined', 'withdrawn')),
  proposal_sent_at timestamptz,                -- 강사에게 보낼 제안 문구를 복사한 시각 (= 제안 보냄)
  confirmed_at timestamptz,                    -- 운영자가 '강사 가능 → 확정'을 누른 시각
  confirmed_by uuid,
  closed_at timestamptz,
  close_reason text,
  created_by uuid,
  created_at timestamptz not null default now(),
  unique (enrollment_id, version),
  check ((state = 'confirmed') = (confirmed_at is not null and confirmed_by is not null)),
  check ((state in ('declined', 'withdrawn')) = (closed_at is not null))
);
create unique index if not exists schedule_plans_one_open on schedule_plans (enrollment_id) where state = 'proposed';
create unique index if not exists schedule_plans_one_confirmed on schedule_plans (enrollment_id) where state = 'confirmed';

create table if not exists schedule_notices (
  id uuid primary key default gen_random_uuid(),
  plan_id uuid not null references schedule_plans(id),
  recipient_kind text not null check (recipient_kind in ('student', 'tutor')),
  recipient_id uuid not null,
  -- 지금: 학생 카카오톡 채널(수동), 강사 WhatsApp(수동). 자동 채널은 대표 결정 후 사용
  channel text not null check (channel in ('kakao_manual', 'whatsapp_manual', 'email', 'google_calendar', 'whatsapp_api')),
  status text not null default 'pending' check (status in ('pending', 'sent', 'failed', 'unknown')),
  sent_at timestamptz,
  sent_by uuid,                                -- 복사한 운영자 (자동 발송이면 비움)
  sent_via text check (sent_via in ('copy', 'system')),
  attempts integer not null default 0,
  last_error text,
  last_attempt_at timestamptz,
  created_at timestamptz not null default now(),
  unique (plan_id, recipient_kind),            -- 일정 버전 × 받는 사람 = 1건 (중복 안내 방지)
  check ((status = 'sent') = (sent_at is not null and sent_via is not null))
);

do $$
begin
  if not exists (select 1 from pg_trigger where tgname = 'schedule_plans_audit') then
    perform lms_protect('schedule_plans'::regclass);
    perform lms_protect('schedule_notices'::regclass);
    create trigger schedule_plans_no_delete before delete on schedule_plans for each row execute function forbid_delete();
    create trigger schedule_notices_no_delete before delete on schedule_notices for each row execute function forbid_delete();
  end if;
end $$;

-- 신규 매칭 업무는 강사 안내까지 끝나야 완료 (기존: 강사 배정 + 학생 안내만 보던 것에 추가)
do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'admin_tasks_matching_tutor_notified') then
    alter table admin_tasks add constraint admin_tasks_matching_tutor_notified
      check (status <> 'done' or kind <> 'new_student_matching' or tutor_notified_at is not null);
  end if;
end $$;

-- 일정안의 등록기간 전체 충돌 (강사 다른 수업 겹침·휴식 10분·휴무, POL-OP-21). 저장은 하지 않고 목록만
create or replace function lms_plan_conflicts(p_tutor uuid, p_slots jsonb, p_start date, p_end date, p_dur smallint)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_break interval := interval '10 minutes';   -- POL-OP-21 (코드 CONFIRMED.minBreakMin 과 같아야 함)
  d date := p_start;
  s jsonb;
  t0 timestamptz;
  t1 timestamptz;
  out jsonb := '[]'::jsonb;
begin
  while d <= p_end loop
    select x into s from jsonb_array_elements(p_slots) x where (x ->> 'weekday')::int = extract(dow from d);
    if found then
      t0 := (d + (s ->> 'time')::time) at time zone 'Asia/Seoul';
      t1 := t0 + make_interval(mins => p_dur);
      out := out || coalesce((
        select jsonb_agg(jsonb_build_object('date', d, 'time', s ->> 'time', 'reason',
                 case when l.starts_at < t1 and t0 < l.ends_at then (case when l.kind = 'regular' then 'tutor_regular' else 'tutor_makeup' end) else 'break' end,
                 'other_starts_at', l.starts_at, 'other_ends_at', l.ends_at))
        from lessons l
        where l.tutor_id = p_tutor and l.state <> 'canceled'
          and l.starts_at < t1 + v_break and t0 - v_break < l.ends_at), '[]'::jsonb);
      out := out || coalesce((
        select jsonb_agg(jsonb_build_object('date', d, 'time', s ->> 'time', 'reason', 'tutor_time_off',
                 'other_starts_at', o.starts_at, 'other_ends_at', o.ends_at))
        from tutor_time_off o where o.tutor_id = p_tutor and o.starts_at < t1 and t0 < o.ends_at), '[]'::jsonb);
    end if;
    d := d + 1;
  end loop;
  return out;
end $$;
revoke all on function lms_plan_conflicts(uuid, jsonb, date, date, smallint) from public, anon, authenticated;

-- 일정안 모양 검사 (주 횟수·요일·첫 수업일). 오류면 예외
create or replace function lms_check_plan_shape(p_enrollment uuid, p_tutor uuid, p_slots jsonb, p_start date)
returns void
language plpgsql stable security definer set search_path = public as $$
declare
  e record;
begin
  select * into e from enrollments where id = p_enrollment;
  if not found then raise exception '수강등록이 없습니다.'; end if;
  if e.status = 'pending_payment' or not exists (select 1 from payments where enrollment_id = p_enrollment) then
    raise exception '결제 확인 전에는 강사·정규 일정을 제안·확정할 수 없습니다 (POL-OP-13).';
  end if;
  if p_start is distinct from e.start_date then
    raise exception '첫 수업일(%)이 수강 시작일(%)과 다릅니다.', p_start, e.start_date;
  end if;
  if jsonb_typeof(p_slots) <> 'array' or jsonb_array_length(p_slots) <> e.weekly_count then
    raise exception '정규 시간 수(%)가 주 횟수(%)와 다릅니다.', coalesce(jsonb_array_length(p_slots), 0), e.weekly_count;
  end if;
  if (select count(distinct (x ->> 'weekday')::int) from jsonb_array_elements(p_slots) x) <> jsonb_array_length(p_slots) then
    raise exception '같은 요일에 정규 수업을 2개 넣을 수 없습니다.';
  end if;
  if not exists (select 1 from jsonb_array_elements(p_slots) x where (x ->> 'weekday')::int = extract(dow from p_start)) then
    raise exception '수강 시작일은 첫 정규 수업일이어야 합니다 (시작일 요일이 수업 요일에 없음).';
  end if;
  if not exists (select 1 from tutors where id = p_tutor and active) then raise exception '활동 중인 강사가 아닙니다.'; end if;
end $$;
revoke all on function lms_check_plan_shape(uuid, uuid, jsonb, date) from public, anon, authenticated;

-- 일정안 만들기 (proposed). 같은 등록에 답 대기 중인 안이 있으면 '다른 안으로 바꿈'으로 닫음. 충돌이 있으면 저장하지 않음
create or replace function lms_new_plan(p_plan_id uuid, p_enrollment uuid, p_tutor uuid, p_slots jsonb, p_start date, p_me uuid)
returns integer
language plpgsql security definer set search_path = public as $$
declare
  e record;
  v integer;
  conflicts jsonb;
begin
  perform lms_check_plan_shape(p_enrollment, p_tutor, p_slots, p_start);
  if exists (select 1 from schedule_plans where enrollment_id = p_enrollment and state = 'confirmed') then
    raise exception '이미 확정된 일정이 있습니다. 확정 후 변경은 일정 변경 기능으로 (아직 없음).';
  end if;
  select * into e from enrollments where id = p_enrollment;
  conflicts := lms_plan_conflicts(p_tutor, p_slots, e.start_date, e.base_end_date, e.duration_min);
  if jsonb_array_length(conflicts) > 0 then
    raise exception '일정 충돌 %건 — 저장하지 않았습니다.', jsonb_array_length(conflicts)
      using errcode = 'P0001', detail = conflicts::text, hint = 'schedule_conflict';
  end if;
  update schedule_plans set state = 'withdrawn', closed_at = now(), close_reason = '다른 안으로 바꿈'
  where enrollment_id = p_enrollment and state = 'proposed';
  select coalesce(max(version), 0) + 1 into v from schedule_plans where enrollment_id = p_enrollment;
  insert into schedule_plans (id, enrollment_id, version, tutor_id, slots, start_date, created_by)
  values (p_plan_id, p_enrollment, v, p_tutor, p_slots, p_start, p_me);
  return v;
end $$;
revoke all on function lms_new_plan(uuid, uuid, uuid, jsonb, date, uuid) from public, anon, authenticated;

-- 확정 (내부): 정규 일정·수업 + 양쪽 최종 안내 2건을 한 트랜잭션으로. 이미 확정이면 그대로 돌려줌
create or replace function lms_confirm_plan(p_plan_id uuid, p_me uuid)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  pl record;
  e record;
  conflicts jsonb;
  s jsonb;
  d date;
  n integer := 0;
  t0 timestamptz;
begin
  select * into pl from schedule_plans where id = p_plan_id for update;
  if not found then raise exception '일정안이 없습니다.'; end if;
  if pl.state = 'confirmed' then
    return jsonb_build_object('plan_id', pl.id, 'version', pl.version, 'state', 'confirmed', 'repeated', true,
                              'lessons', (select count(*) from lessons where enrollment_id = pl.enrollment_id and kind = 'regular'));
  end if;
  if pl.state <> 'proposed' then raise exception '닫힌 일정안(%)은 확정할 수 없습니다.', pl.state; end if;
  perform lms_check_plan_shape(pl.enrollment_id, pl.tutor_id, pl.slots, pl.start_date);
  select * into e from enrollments where id = pl.enrollment_id;

  -- 제안 뒤에 다른 수업·휴무가 생겼을 수 있어 다시 검사
  conflicts := lms_plan_conflicts(pl.tutor_id, pl.slots, e.start_date, e.base_end_date, e.duration_min);
  if jsonb_array_length(conflicts) > 0 then
    raise exception '일정 충돌 %건 — 확정하지 않았습니다.', jsonb_array_length(conflicts)
      using errcode = 'P0001', detail = conflicts::text, hint = 'schedule_conflict';
  end if;

  for s in select * from jsonb_array_elements(pl.slots) loop
    insert into regular_schedules (student_id, tutor_id, weekday, start_time_kst, duration_min, effective_from)
    values (e.student_id, pl.tutor_id, (s ->> 'weekday')::smallint, (s ->> 'time')::time, e.duration_min, e.start_date);
  end loop;
  d := e.start_date;
  while d <= e.base_end_date loop
    select x into s from jsonb_array_elements(pl.slots) x where (x ->> 'weekday')::int = extract(dow from d);
    if found then
      n := n + 1;
      t0 := (d + (s ->> 'time')::time) at time zone 'Asia/Seoul';
      insert into lessons (enrollment_id, student_id, tutor_id, kind, seq, starts_at, ends_at, created_by)
      values (e.id, e.student_id, pl.tutor_id, 'regular', n, t0, t0 + make_interval(mins => e.duration_min), p_me);
    end if;
    d := d + 1;
  end loop;
  if n <> e.lessons_purchased then
    raise exception '만들어진 정규 수업 수(%)가 등록 회차(%)와 다릅니다.', n, e.lessons_purchased;
  end if;

  update schedule_plans set state = 'confirmed', confirmed_at = now(), confirmed_by = p_me where id = pl.id;
  insert into schedule_notices (plan_id, recipient_kind, recipient_id, channel) values
    (pl.id, 'tutor', pl.tutor_id, 'whatsapp_manual'),
    (pl.id, 'student', e.student_id, 'kakao_manual')
  on conflict (plan_id, recipient_kind) do nothing;
  update admin_tasks set tutor_id = pl.tutor_id, tutor_assigned_at = now()
  where kind = 'new_student_matching' and enrollment_id = e.id and status = 'open';

  return jsonb_build_object('plan_id', pl.id, 'version', pl.version, 'state', 'confirmed', 'lessons', n);
end $$;
revoke all on function lms_confirm_plan(uuid, uuid) from public, anon, authenticated;

-- 안내 '보냄'을 신규 매칭 업무에 옮김. 양쪽 모두 '보냄'이면 업무 완료 (사람이 따로 닫지 않음)
create or replace function lms_finish_matching(p_plan_id uuid, p_me uuid)
returns boolean
language plpgsql security definer set search_path = public as $$
declare
  pl record;
  st timestamptz;
  tt timestamptz;
begin
  select * into pl from schedule_plans where id = p_plan_id;
  if pl.state is distinct from 'confirmed' then return false; end if;
  select sent_at into st from schedule_notices where plan_id = p_plan_id and recipient_kind = 'student' and status = 'sent';
  select sent_at into tt from schedule_notices where plan_id = p_plan_id and recipient_kind = 'tutor' and status = 'sent';
  -- 보낸 쪽은 바로 기록 (화면에 남은 쪽만 보이게), 둘 다 보냈을 때만 완료
  update admin_tasks set student_notified_at = st, tutor_notified_at = tt,
         status = case when st is not null and tt is not null then 'done' else status end,
         done_at = case when st is not null and tt is not null then now() end,
         done_by = case when st is not null and tt is not null then p_me end
  where kind = 'new_student_matching' and enrollment_id = pl.enrollment_id and status = 'open';
  return st is not null and tt is not null;
end $$;
revoke all on function lms_finish_matching(uuid, uuid) from public, anon, authenticated;

-- ---------- 화면에서 부르는 함수 (운영자 TOTP 세션만) ----------

-- 이미 저장된 등록(결제 확인)에 일정안 제안. p = {tutor_id, slots, start_date, tutor_answer}
-- tutor_answer = 'accepted' 이면 (강사가 이미 가능하다고 답한 경우) 제안과 확정을 한 번에
create or replace function admin_propose_schedule(p_plan_id uuid, p_enrollment uuid, p jsonb)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  pl record;
  v integer;
begin
  if not is_admin() then raise exception '운영자(추가 인증 완료)만 일정을 제안할 수 있습니다.' using errcode = '42501'; end if;
  if p_plan_id is null then raise exception '요청 번호가 없습니다.'; end if;
  perform pg_advisory_xact_lock(hashtextextended(p_enrollment::text, 0));
  select * into pl from schedule_plans where id = p_plan_id;
  if found then
    if pl.enrollment_id <> p_enrollment then raise exception '요청 번호가 다른 등록에 쓰였습니다.'; end if;
    return jsonb_build_object('plan_id', pl.id, 'version', pl.version, 'state', pl.state, 'repeated', true);
  end if;
  perform set_config('app.actor_id', me::text, true);
  perform set_config('app.actor_via', 'admin_propose_schedule', true);
  v := lms_new_plan(p_plan_id, p_enrollment, nullif(p ->> 'tutor_id', '')::uuid, coalesce(p -> 'slots', '[]'::jsonb), (p ->> 'start_date')::date, me);
  if p ->> 'tutor_answer' = 'accepted' then return lms_confirm_plan(p_plan_id, me); end if;
  return jsonb_build_object('plan_id', p_plan_id, 'version', v, 'state', 'proposed');
end $$;

-- 강사가 가능하다고 답함 → 운영자가 한 번 누름 = 확정 (정규 일정·수업 + 양쪽 안내 2건). 두 번 눌러도 한 번
create or replace function admin_confirm_schedule(p_plan_id uuid)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  eid uuid;
begin
  if not is_admin() then raise exception '운영자(추가 인증 완료)만 일정을 확정할 수 있습니다.' using errcode = '42501'; end if;
  select enrollment_id into eid from schedule_plans where id = p_plan_id;
  if eid is null then raise exception '일정안이 없습니다.'; end if;
  perform pg_advisory_xact_lock(hashtextextended(eid::text, 0));
  perform set_config('app.actor_id', me::text, true);
  perform set_config('app.actor_via', 'admin_confirm_schedule', true);
  return lms_confirm_plan(p_plan_id, me);
end $$;

-- 강사가 안 된다고 함(declined) / 운영자가 이 안을 접음(withdrawn). 확정된 안은 여기서 닫지 않음
create or replace function admin_close_plan(p_plan_id uuid, p_state text, p_reason text)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  pl record;
begin
  if not is_admin() then raise exception '운영자(추가 인증 완료)만 바꿀 수 있습니다.' using errcode = '42501'; end if;
  if p_state not in ('declined', 'withdrawn') then raise exception '닫는 이유는 declined·withdrawn 만 가능합니다.'; end if;
  select * into pl from schedule_plans where id = p_plan_id for update;
  if not found then raise exception '일정안이 없습니다.'; end if;
  if pl.state = p_state then return jsonb_build_object('plan_id', pl.id, 'state', pl.state, 'repeated', true); end if;
  if pl.state <> 'proposed' then raise exception '답 대기 중인 안만 닫을 수 있습니다 (지금: %).', pl.state; end if;
  perform set_config('app.actor_id', me::text, true);
  perform set_config('app.actor_via', 'admin_close_plan', true);
  update schedule_plans set state = p_state, closed_at = now(), close_reason = nullif(trim(p_reason), '') where id = p_plan_id;
  return jsonb_build_object('plan_id', pl.id, 'state', p_state);
end $$;

-- 강사 제안 문구 복사 = 제안 보냄 (처음 복사한 시각만 남김)
create or replace function admin_mark_proposal_sent(p_plan_id uuid)
returns timestamptz
language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  t timestamptz;
begin
  if not is_admin() then raise exception '운영자(추가 인증 완료)만 기록할 수 있습니다.' using errcode = '42501'; end if;
  perform set_config('app.actor_id', me::text, true);
  perform set_config('app.actor_via', 'admin_mark_proposal_sent', true);
  update schedule_plans set proposal_sent_at = coalesce(proposal_sent_at, now())
  where id = p_plan_id and state = 'proposed'
  returning proposal_sent_at into t;
  if t is null then raise exception '답 대기 중인 일정안이 아닙니다.'; end if;
  return t;
end $$;

-- 최종 안내 문구 복사 = 그쪽 안내 보냄. 이미 보낸 건은 그대로(시각 안 바뀜). 양쪽 다 보내면 매칭 업무 완료
create or replace function admin_mark_notice_sent(p_notice_id uuid)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  nt record;
  done boolean;
begin
  if not is_admin() then raise exception '운영자(추가 인증 완료)만 기록할 수 있습니다.' using errcode = '42501'; end if;
  select n.*, p.state as plan_state into nt from schedule_notices n join schedule_plans p on p.id = n.plan_id where n.id = p_notice_id for update of n;
  if not found then raise exception '안내가 없습니다.'; end if;
  if nt.plan_state <> 'confirmed' then raise exception '확정된 일정의 안내가 아닙니다.'; end if;
  perform set_config('app.actor_id', me::text, true);
  perform set_config('app.actor_via', 'admin_mark_notice_sent', true);
  if nt.status <> 'sent' then
    update schedule_notices set status = 'sent', sent_at = now(), sent_by = me, sent_via = 'copy',
                                attempts = attempts + 1, last_attempt_at = now()
    where id = p_notice_id;
  end if;
  done := lms_finish_matching(nt.plan_id, me);
  return jsonb_build_object('notice_id', p_notice_id, 'status', 'sent', 'repeated', nt.status = 'sent', 'all_sent', done);
end $$;

-- 자동 발송기(서버) 결과 기록 — 채널이 정해지면 사용. 앱 사용자는 못 부름
-- 이미 'sent'인 건은 바꾸지 않음 (성공한 안내를 다시 보내거나 실패로 덮지 않음)
create or replace function lms_notice_result(p_notice_id uuid, p_status text, p_error text)
returns void
language plpgsql security definer set search_path = public as $$
declare
  nt record;
begin
  if p_status not in ('sent', 'failed', 'unknown') then raise exception '결과는 sent·failed·unknown 만 가능합니다.'; end if;
  select * into nt from schedule_notices where id = p_notice_id for update;
  if not found or nt.status = 'sent' then return; end if;
  perform set_config('app.actor_via', 'lms_notice_result', true);
  update schedule_notices
  set status = p_status, attempts = attempts + 1, last_attempt_at = now(), last_error = nullif(p_error, ''),
      sent_at = case when p_status = 'sent' then now() end, sent_via = case when p_status = 'sent' then 'system' end
  where id = p_notice_id;
  if p_status = 'sent' then perform lms_finish_matching(nt.plan_id, null); end if;
end $$;
revoke all on function lms_notice_result(uuid, text, text) from public, anon, authenticated;

revoke all on function admin_propose_schedule(uuid, uuid, jsonb), admin_confirm_schedule(uuid), admin_close_plan(uuid, text, text),
                       admin_mark_proposal_sent(uuid), admin_mark_notice_sent(uuid) from public, anon;
grant execute on function admin_propose_schedule(uuid, uuid, jsonb), admin_confirm_schedule(uuid), admin_close_plan(uuid, text, text),
                          admin_mark_proposal_sent(uuid), admin_mark_notice_sent(uuid) to authenticated;
do $$
begin
  if exists (select 1 from pg_roles where rolname = 'service_role') then
    execute 'grant execute on function lms_notice_result(uuid, text, text) to service_role';
  end if;
end $$;

-- 자동 발송기가 다시 보낼 대상: 확정된 일정의 '보냄 아님' 중 pending·failed 만 (unknown 은 운영자 확인 후)
create or replace view schedule_notice_outbox with (security_invoker = true) as
select n.* from schedule_notices n join schedule_plans p on p.id = n.plan_id
where p.state = 'confirmed' and n.status in ('pending', 'failed');
revoke all on schedule_notice_outbox from anon, authenticated;

-- 운영자 화면: 손이 필요한 일정안만 — 강사 답 대기 / 확정했지만 한쪽이라도 안내 안 됨.
-- 경고 시각(첫 수업 몇 시간 전 등)은 미결정 → 숫자(hours_to_first_lesson)만 주고 화면 규칙이 판단
create or replace view schedule_plan_board with (security_invoker = true) as
select p.id as plan_id, p.enrollment_id, p.version, p.state, p.tutor_id, t.name as tutor_name,
       e.student_id, s.name_ko as student_name, s.code as student_code,
       p.slots, p.start_date, p.proposal_sent_at, p.confirmed_at, p.created_at,
       coalesce(
         (select min(l.starts_at) from lessons l where l.enrollment_id = p.enrollment_id and l.kind = 'regular' and l.state <> 'canceled'),
         (select (p.start_date + (x ->> 'time')::time) at time zone 'Asia/Seoul' from jsonb_array_elements(p.slots) x
           where (x ->> 'weekday')::int = extract(dow from p.start_date) limit 1)) as first_lesson_at,
       sn.id as student_notice_id, sn.status as student_notice_status, sn.sent_at as student_notice_sent_at,
       tn.id as tutor_notice_id, tn.status as tutor_notice_status, tn.sent_at as tutor_notice_sent_at
from schedule_plans p
join enrollments e on e.id = p.enrollment_id
join students s on s.id = e.student_id
join tutors t on t.id = p.tutor_id
left join schedule_notices sn on sn.plan_id = p.id and sn.recipient_kind = 'student'
left join schedule_notices tn on tn.plan_id = p.id and tn.recipient_kind = 'tutor'
where p.state = 'proposed'
   or (p.state = 'confirmed' and (sn.status is distinct from 'sent' or tn.status is distinct from 'sent'));
revoke all on schedule_plan_board from anon, authenticated;
grant select on schedule_plan_board to authenticated;   -- security_invoker: 보이는 행은 각 표의 RLS 대로 (운영자만)

-- 신규 매칭 업무의 남은 단계에 '강사에게 최종 안내' 추가 (열은 그대로)
create or replace view admin_task_board with (security_invoker = true) as
select t.*,
       case when t.due_at is not null and now() > t.due_at then 'overdue'
            when t.due_at is not null and now() > t.due_at - interval '24 hours' then 'due_soon'
            else 'open' end as urgency,
       case t.kind
         when 'new_student_matching' then
           array_remove(array[case when t.tutor_assigned_at is null then 'assign_tutor' end,
                              case when t.tutor_notified_at is null then 'notify_tutor' end,
                              case when t.student_notified_at is null then 'notify_student' end], null)
         else
           array_remove(array[case when t.tutor_id is null then 'set_tutor' end,
                              case when t.tutor_change_planned then 'tutor_change' end,
                              case when t.tutor_notified_at is null then 'notify_tutor' end,
                              case when t.tutor_acknowledged_at is null then 'tutor_ack' end,
                              case when t.schedule_checked_at is null then 'check_schedule' end], null)
       end as missing_steps
from admin_tasks t
where t.status = 'open';

-- ---------- 신규 학생 등록 함수 갱신: 강사·시간을 고르면 '일정안'으로 저장 ----------
-- 강사가 이미 가능하다고 답했으면 p.tutor_answer = 'accepted' → 같은 저장에서 확정까지 (운영자 동작 1번)
-- 그렇지 않으면 학생·수강권·결제 + 제안(답 대기)만. 수업은 확정 때 생김 (강사 '가능' 답 전 확정 금지, D-50·H22)
create or replace function admin_register_student(p_request_id uuid, p jsonb)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  prev jsonb;
  st jsonb := p -> 'student';
  co jsonb := p -> 'course';
  pay jsonb := p -> 'payment';
  slots jsonb := coalesce(p -> 'slots', '[]'::jsonb);
  v_tutor uuid := nullif(p ->> 'tutor_id', '')::uuid;
  v_weeks smallint := (co ->> 'weeks')::smallint;
  v_weekly smallint := (co ->> 'weekly_count')::smallint;
  v_dur smallint := (co ->> 'duration_min')::smallint;
  v_start date := (co ->> 'start_date')::date;
  v_end date;
  v_paid boolean := jsonb_typeof(p -> 'payment') = 'object';
  sid uuid;
  scode text;
  eid uuid;
  plan_id uuid;
  conf jsonb;
  res jsonb;
begin
  if not is_admin() then
    raise exception '운영자(추가 인증 완료)만 학생을 등록할 수 있습니다.' using errcode = '42501';
  end if;
  if p_request_id is null then raise exception '요청 번호가 없습니다.'; end if;

  -- 같은 요청이 동시에 두 번 와도 하나씩 처리 → 두 번째는 첫 결과를 받음
  perform pg_advisory_xact_lock(hashtextextended(p_request_id::text, 0));
  select result into prev from registration_requests where id = p_request_id;
  if found then return prev || '{"repeated": true}'::jsonb; end if;

  perform set_config('app.actor_id', me::text, true);
  perform set_config('app.actor_via', 'admin_register_student', true);

  if v_weeks is null or v_weeks not in (4, 12, 24) then raise exception '수강 기간은 4·12·24주만 가능합니다.'; end if;
  if v_start is null then raise exception '첫 수업일(수강 시작일)이 없습니다.'; end if;
  v_end := v_start + (v_weeks / 4 * 28 - 1);

  if not v_paid and (v_tutor is not null or jsonb_array_length(slots) > 0) then
    raise exception '결제 확인 전에는 강사·정규 일정을 확정할 수 없습니다 (POL-OP-13).';
  end if;
  if v_tutor is null and jsonb_array_length(slots) > 0 then
    raise exception '정규 시간을 정하려면 강사도 정해야 합니다.';
  end if;

  -- 학생 (항상 새 학생 번호. 같은 이메일이 있어도 연결·병합하지 않음)
  insert into students (name_ko, name_en, email, phone, country, city, timezone, admin_memo)
  values (st ->> 'name_ko', st ->> 'name_en', nullif(lower(trim(st ->> 'email')), ''), nullif(st ->> 'phone', ''),
          nullif(st ->> 'country', ''), nullif(st ->> 'city', ''), st ->> 'timezone', nullif(st ->> 'admin_memo', ''))
  returning id, code into sid, scode;

  insert into enrollments (student_id, seq, weeks, weekly_count, duration_min, start_date, base_end_date,
                           lessons_purchased, amount_due, status, created_by)
  values (sid, 1, v_weeks, v_weekly, v_dur, v_start, v_end, v_weekly * v_weeks,
          nullif(co ->> 'amount_due', '')::integer, case when v_paid then 'confirmed' else 'pending_payment' end, me)
  returning id into eid;

  if v_paid then
    -- paid_at = 실제 입금·결제 완료 시각 (은행 거래내역·아임웹 주문 시각), external_ref = 아임웹 주문번호 등 (같은 결제 두 번 기록 방지)
    insert into payments (enrollment_id, method, payer_name, amount_received, paid_at, received_on, external_ref, confirmed_by)
    values (eid, pay ->> 'method', nullif(pay ->> 'payer_name', ''), (pay ->> 'amount')::integer, (pay ->> 'paid_at')::timestamptz,
            (((pay ->> 'paid_at')::timestamptz at time zone 'UTC') + interval '9 hours')::date, nullif(pay ->> 'external_ref', ''), me);
  end if;

  if v_tutor is not null then
    plan_id := gen_random_uuid();
    perform lms_new_plan(plan_id, eid, v_tutor, slots, v_start, me);   -- 충돌이면 여기서 오류 → 아무것도 저장 안 됨
    if p ->> 'tutor_answer' = 'accepted' then conf := lms_confirm_plan(plan_id, me); end if;
  end if;

  res := jsonb_build_object('student_id', sid, 'student_code', scode, 'enrollment_id', eid,
                            'status', case when v_paid then 'confirmed' else 'pending_payment' end,
                            'plan_id', plan_id,
                            'plan_state', case when plan_id is null then null when conf is null then 'proposed' else 'confirmed' end,
                            'lessons', coalesce((conf ->> 'lessons')::int, 0), 'start_date', v_start, 'end_date', v_end);
  insert into registration_requests (id, created_by, student_id, enrollment_id, result)
  values (p_request_id, me, sid, eid, res);
  return res;
end $$;

revoke all on function admin_register_student(uuid, jsonb) from public, anon;
grant execute on function admin_register_student(uuid, jsonb) to authenticated;
