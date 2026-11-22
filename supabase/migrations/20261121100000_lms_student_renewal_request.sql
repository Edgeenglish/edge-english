-- =====================================================================
-- 학생 재등록 신청 (대표 11/21 시안 확정 · 시험 DB 먼저, 운영 미반영)
--  흐름: 1단계 기간·적립금 고르기(저장 = draft, 신청 완료 아님) → 2단계 금액·입금 정보 보고 결제 →
--        결제 방법·입금자명 적고 [재등록 신청하기] (= submitted '재등록 신청 완료 · 입금 확인 중', 적립금 예약)
--        → 운영진 [입금 확인됨] → 지금 재등록 함수(admin_renew / 일정 미정이면 admin_register_renewal)로 새 수강권
--        (= paid, 적립금 확정 · 카드결제면 예약 되돌림) · [신청 닫기] (= closed, 예약 되돌림)
--  - 신청만으로는 수강권·결제·수업을 만들지 않음. 새 수강권은 운영진 확인 때 기존 재등록 함수가 만듦
--  - 같은 수강권에 열린 신청(draft·submitted)은 1건 (두 번 눌러도·다시 열어도 같은 신청)
--  - 금액 = lms_renewal_plans (재등록 메일·화면과 같은 가격표). 표에 없는 코스는 신청 화면 대신 문의
--  - 적립금: 계좌이체에만 (카드는 아임웹 정가). 예약·확정·되돌림 = 기존 reward_redemptions (POL-PAY-09)
--  - 학생에게 보이는 '수강 종료일' = 보강·보상수업까지 포함한 마지막 수업일. 신청 가능 판정(이월·강사 시간 유지)은
--    지금처럼 수강권 기간 끝(final_end_date) 기준 (POL-RN-01·02, 대표 11/21)
--  - 재등록 안내 메일: 신청 링크로 바꾸고, 신청 완료(submitted) 뒤에는 안 보냄. 이모지 뺌, 종료일 = 마지막 수업일
--  지우는 것 없음. 다시 실행해도 같은 결과
-- =====================================================================

create table if not exists renewal_requests (
  id uuid primary key default gen_random_uuid(),
  student_id uuid not null references students(id),
  enrollment_id uuid not null references enrollments(id),       -- 재등록하는 지금 수강권
  weeks smallint not null check (weeks in (4, 12, 24)),
  duration_min smallint not null,
  weekly_count smallint not null,
  price integer not null check (price > 0),                      -- 고른 기간의 정가 (카드결제 금액)
  points integer not null default 0 check (points >= 0),        -- 쓰려는 적립금 (계좌이체에만)
  method text check (method in ('bank_transfer', 'card_link')),
  payer_name text check (char_length(payer_name) <= 50),
  status text not null default 'draft' check (status in ('draft', 'submitted', 'paid', 'closed')),
  redemption_id uuid references reward_redemptions(id),
  new_enrollment_id uuid references enrollments(id),
  submitted_at timestamptz,
  paid_at timestamptz,
  closed_at timestamptz,
  close_note text,
  created_by uuid,
  updated_by uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (points <= price),
  check (status in ('draft', 'closed') or method is not null),
  check (status <> 'submitted' or (payer_name is not null and submitted_at is not null)),
  check (status <> 'paid' or new_enrollment_id is not null)
);
create unique index if not exists renewal_requests_one_open on renewal_requests (enrollment_id) where status in ('draft', 'submitted');
create unique index if not exists renewal_requests_one_paid on renewal_requests (enrollment_id) where status = 'paid';
do $$ begin
  if not exists (select 1 from pg_trigger where tgname = 'renewal_requests_audit') then perform lms_protect('renewal_requests'::regclass); end if;
end $$;

-- 적립금 확정: 재등록 신청은 '지금 수강권'에 예약하고, 확정 근거 결제는 새 수강권(그 다음 수강권)의 결제 → 그 경우도 허용
create or replace function reward_redemption_check() returns trigger
language plpgsql as $$
begin
  if tg_op = 'INSERT' then
    if new.status <> 'held' then raise exception '사용 요청은 예약(held)으로 시작합니다.'; end if;
    if (select student_id from enrollments where id = new.enrollment_id) <> new.student_id then
      raise exception '다른 학생의 등록에는 적립금을 쓸 수 없습니다.';
    end if;
    return new;
  end if;
  if (old.student_id, old.enrollment_id, old.amount, old.method, old.created_at)
     is distinct from (new.student_id, new.enrollment_id, new.amount, new.method, new.created_at) then
    raise exception '사용 요청의 학생·등록·금액은 바꿀 수 없습니다. 되돌린 뒤 새로 만드세요.';
  end if;
  if old.status in ('released', 'restored') then raise exception '끝난 사용 요청은 바꿀 수 없습니다.'; end if;
  if old.status = new.status then return new; end if;
  if not ((old.status = 'held' and new.status in ('confirmed', 'released')) or (old.status = 'confirmed' and new.status = 'restored')) then
    raise exception '사용 요청 상태를 % → % 로 바꿀 수 없습니다.', old.status, new.status;
  end if;
  if new.status = 'confirmed' and not exists (
       select 1 from payments p join enrollments e on e.id = p.enrollment_id
       where p.id = new.payment_id and (e.id = new.enrollment_id or e.previous_enrollment_id = new.enrollment_id)) then
    raise exception '이 등록(또는 그 재등록)의 결제 기록으로만 확정할 수 있습니다.';
  end if;
  if new.decided_at is null then new.decided_at := now(); end if;
  return new;
end $$;

-- 재등록할 수강권: 가장 최근 수강권. 그것이 이미 재등록(시작 전 다음 수강권)이면 state = renewed
create or replace function lms_renewal_target(p_student uuid, out enrollment_id uuid, out state text)
language plpgsql stable security definer set search_path = public as $$
declare
  last enrollments;
  today date := (now() at time zone 'Asia/Seoul')::date;
begin
  select * into last from enrollments e where e.student_id = p_student and e.status <> 'canceled' order by e.seq desc limit 1;
  if not found or (select is_trial_account from students where id = p_student) then state := 'none'; return; end if;
  if last.previous_enrollment_id is not null and last.start_date > today and last.status in ('confirmed', 'active')
     and exists (select 1 from payments p where p.enrollment_id = last.id) then
    enrollment_id := last.id; state := 'renewed'; return;
  end if;
  if last.status not in ('confirmed', 'active') then state := 'none'; return; end if;
  enrollment_id := last.id;
  state := case when today > last.final_end_date then 'late' else 'open' end;
end $$;
revoke all on function lms_renewal_target(uuid) from public, anon, authenticated;

-- 마지막 수업 시작 시각 (취소·무효 아닌 정규·보강·보상 모두). 없으면 null
create or replace function lms_last_lesson_at(p_enrollment uuid) returns timestamptz
language sql stable security definer set search_path = public as $$
  select max(l.starts_at) from lessons l where l.enrollment_id = p_enrollment and l.voided_at is null and l.state <> 'canceled'
$$;
revoke all on function lms_last_lesson_at(uuid) from public, anon, authenticated;

create or replace function lms_renewal_price(p_min int, p_weekly int, p_weeks int) returns integer
language sql immutable as $$
  select case p_weeks when 4 then (lms_renewal_plans(p_min, p_weekly) ->> 'monthly')::int
                      when 12 then (lms_renewal_plans(p_min, p_weekly) #>> '{three,total}')::int
                      when 24 then (lms_renewal_plans(p_min, p_weekly) #>> '{six,total}')::int end
$$;
revoke all on function lms_renewal_price(int, int, int) from public, anon, authenticated;

create or replace function lms_renewal_request_json(r renewal_requests) returns jsonb
language sql stable security definer set search_path = public as $$
  select case when r.id is null then null else jsonb_build_object(
    'id', r.id, 'status', r.status, 'weeks', r.weeks, 'price', r.price, 'points', r.points,
    'method', r.method, 'payer_name', r.payer_name, 'submitted_at', r.submitted_at, 'paid_at', r.paid_at,
    'created_at', r.created_at, 'updated_at', r.updated_at) end
$$;
revoke all on function lms_renewal_request_json(renewal_requests) from public, anon, authenticated;

-- 학생 재등록 화면 바탕 (학생 본인 · 운영자 보기)
create or replace function student_renewal_info(p_student uuid)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_student uuid := lms_screen_student(p_student);
  t record;
  e enrollments;
  r renewal_requests;
  nx enrollments;
begin
  select * into t from lms_renewal_target(v_student);
  if t.state = 'none' then return jsonb_build_object('state', 'none'); end if;
  select * into e from enrollments where id = t.enrollment_id;
  if t.state = 'renewed' then
    nx := e;
    select * into e from enrollments where id = nx.previous_enrollment_id;
  end if;
  select * into r from renewal_requests x where x.enrollment_id = e.id and x.status <> 'closed' order by x.created_at desc limit 1;
  return jsonb_build_object(
    'state', t.state,
    'enrollment_id', e.id, 'duration_min', e.duration_min, 'weekly_count', e.weekly_count,
    'last_lesson_at', lms_last_lesson_at(e.id), 'final_end_date', e.final_end_date,
    'plans', lms_renewal_plans(e.duration_min, e.weekly_count),
    'points_balance', reward_balance(v_student),
    'request', lms_renewal_request_json(r),
    'next', case when nx.id is null then null else jsonb_build_object('weeks', nx.weeks, 'start_date', nx.start_date, 'final_end_date', nx.final_end_date) end);
end $$;
revoke all on function student_renewal_info(uuid) from public, anon;
grant execute on function student_renewal_info(uuid) to authenticated;

-- 1단계 저장 [다음] / 2단계에서 [‹ 기간·적립금 바꾸기] 뒤 다시 저장: 열린 신청 1건을 만들거나 고침 (신청 완료 전만)
create or replace function student_renewal_save(p_student uuid, p_weeks int, p_points int)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_student uuid := lms_screen_student(p_student);
  t record;
  e enrollments;
  v_price int;
  v_bal int;
  r renewal_requests;
begin
  select * into t from lms_renewal_target(v_student);
  if t.state = 'renewed' then raise exception '이미 재등록됐어요.'; end if;
  if t.state = 'late' then raise exception '수강 종료일이 지나 카카오톡으로 문의해 주세요.'; end if;
  if t.state <> 'open' then raise exception '재등록할 수강권이 없어요.'; end if;
  select * into e from enrollments where id = t.enrollment_id for update;
  if p_weeks not in (4, 12, 24) then raise exception '수강 기간을 골라 주세요.' using hint = 'weeks'; end if;
  v_price := lms_renewal_price(e.duration_min, e.weekly_count, p_weeks);
  if v_price is null then raise exception '이 수업은 카카오톡으로 문의해 주세요.'; end if;
  v_bal := reward_balance(v_student);
  if p_points is null or p_points < 0 then raise exception '적립금은 0원 이상 넣어 주세요.' using hint = 'points'; end if;
  if p_points > least(v_bal, v_price) then
    raise exception '적립금은 최대 %원까지 쓸 수 있어요.', to_char(least(v_bal, v_price), 'FM999,999,999') using hint = 'points';
  end if;
  select * into r from renewal_requests x where x.enrollment_id = e.id and x.status in ('draft', 'submitted');
  if found and r.status = 'submitted' then raise exception '이미 재등록 신청을 완료했어요. 바꾸려면 카카오톡으로 문의해 주세요.'; end if;
  if found then
    update renewal_requests set weeks = p_weeks, price = v_price, points = p_points,
      duration_min = e.duration_min, weekly_count = e.weekly_count, updated_at = now(), updated_by = auth.uid()
    where id = r.id returning * into r;
  else
    insert into renewal_requests (student_id, enrollment_id, weeks, duration_min, weekly_count, price, points, created_by, updated_by)
    values (v_student, e.id, p_weeks, e.duration_min, e.weekly_count, v_price, p_points, auth.uid(), auth.uid())
    returning * into r;
  end if;
  return lms_renewal_request_json(r);
end $$;
revoke all on function student_renewal_save(uuid, int, int) from public, anon;
grant execute on function student_renewal_save(uuid, int, int) to authenticated;

-- 2단계 [재등록 신청하기]: 결제 방법·입금자명 → 신청 완료(입금 확인 중). 계좌이체 + 적립금이면 이때 예약
create or replace function student_renewal_submit(p_student uuid, p_request uuid, p_method text, p_payer text)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_student uuid := lms_screen_student(p_student);
  r renewal_requests;
  v_payer text := nullif(btrim(coalesce(p_payer, '')), '');
  v_bal int;
  v_red uuid;
  v_points int;
begin
  select * into r from renewal_requests where id = p_request and student_id = v_student for update;
  if not found then raise exception '신청을 찾을 수 없어요. 처음부터 다시 해 주세요.'; end if;
  if r.status = 'submitted' then return lms_renewal_request_json(r); end if;   -- 두 번 눌러도 1번
  if r.status <> 'draft' then raise exception '이미 처리된 신청이에요.'; end if;
  if (select state from lms_renewal_target(v_student)) <> 'open' then raise exception '수강 종료일이 지나 카카오톡으로 문의해 주세요.'; end if;
  if p_method not in ('bank_transfer', 'card_link') then raise exception '결제 방법을 골라 주세요.' using hint = 'method'; end if;
  if v_payer is null then
    raise exception '%을 적어 주세요.', case p_method when 'card_link' then '결제자명' else '입금자명' end using hint = 'payer';
  end if;
  if char_length(v_payer) > 50 then raise exception '이름은 50자까지 적을 수 있어요.' using hint = 'payer'; end if;
  -- 적립금은 계좌이체에만. 제출하는 순간 다시 확인하고 예약 (그사이 다른 곳에서 쓰였으면 막음)
  v_points := case when p_method = 'bank_transfer' then r.points else 0 end;
  if v_points > 0 then
    v_bal := reward_balance(v_student);
    if v_points > v_bal then
      raise exception '지금 쓸 수 있는 적립금은 %원이에요. 기간·적립금을 다시 골라 주세요.', to_char(v_bal, 'FM999,999,999') using hint = 'points';
    end if;
    insert into reward_redemptions (student_id, enrollment_id, amount, method, note, created_by)
    values (v_student, r.enrollment_id, v_points, 'bank_transfer', '재등록 신청', auth.uid())
    returning id into v_red;
  end if;
  update renewal_requests set method = p_method, payer_name = v_payer, points = v_points, redemption_id = v_red,
    status = 'submitted', submitted_at = now(), updated_at = now(), updated_by = auth.uid()
  where id = r.id returning * into r;
  return lms_renewal_request_json(r);
end $$;
revoke all on function student_renewal_submit(uuid, uuid, text, text) from public, anon;
grant execute on function student_renewal_submit(uuid, uuid, text, text) to authenticated;

-- 운영진: 열린 재등록 신청 (대시보드·학생 상세). 신청 완료 + 2단계까지 보고 제출 안 한 것
create or replace function admin_renewal_requests()
returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not is_admin() then raise exception '운영자(추가 인증 완료)만 볼 수 있습니다.' using errcode = '42501'; end if;
  return coalesce((
    select jsonb_agg(lms_renewal_request_json(r) || jsonb_build_object(
             'student_id', s.id, 'student_code', s.code, 'student_name', s.name_ko,
             'duration_min', r.duration_min, 'weekly_count', r.weekly_count,
             'final_end_date', e.final_end_date, 'last_lesson_at', lms_last_lesson_at(e.id))
           order by (r.status = 'submitted') desc, coalesce(r.submitted_at, r.updated_at))
    from renewal_requests r join students s on s.id = r.student_id join enrollments e on e.id = r.enrollment_id
    where r.status in ('draft', 'submitted')), '[]'::jsonb);
end $$;
revoke all on function admin_renewal_requests() from public, anon;
grant execute on function admin_renewal_requests() to authenticated;

-- 운영진 [신청 닫기]: 재등록 안 함 등. 기록은 남기고 적립금 예약은 되돌림
create or replace function admin_renewal_request_close(p_request uuid, p_note text default null)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  r renewal_requests;
  v_note text := coalesce(nullif(btrim(coalesce(p_note, '')), ''), '재등록 신청 닫음');
begin
  if not is_admin() then raise exception '운영자(추가 인증 완료)만 처리할 수 있습니다.' using errcode = '42501'; end if;
  select * into r from renewal_requests where id = p_request for update;
  if not found then raise exception '신청을 찾을 수 없습니다.'; end if;
  if r.status = 'closed' then return lms_renewal_request_json(r); end if;
  if r.status = 'paid' then raise exception '입금 확인된 신청은 닫을 수 없습니다.'; end if;
  if r.redemption_id is not null then
    update reward_redemptions set status = 'released', note = v_note, decided_by = auth.uid()
    where id = r.redemption_id and status = 'held';
  end if;
  update renewal_requests set status = 'closed', closed_at = now(), close_note = v_note, updated_at = now(), updated_by = auth.uid()
  where id = r.id returning * into r;
  return lms_renewal_request_json(r);
end $$;
revoke all on function admin_renewal_request_close(uuid, text) from public, anon;
grant execute on function admin_renewal_request_close(uuid, text) to authenticated;

-- 운영진 [입금 확인됨] → 창에서 [저장]: 지금 재등록 함수로 새 수강권(+정규 일정) → 신청 paid, 적립금 확정/되돌림
--  p = admin_renew 의 p (+ no_schedule: true 면 정규 일정 없이 admin_register_renewal = '일정 미정')
create or replace function admin_renewal_request_confirm(p_request uuid, p_request_id uuid, p jsonb)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  r renewal_requests;
  res jsonb;
  v_enr uuid;
  v_pay uuid;
  v_method text := p #>> '{payment,method}';
begin
  if not is_admin() then raise exception '운영자(추가 인증 완료)만 처리할 수 있습니다.' using errcode = '42501'; end if;
  select * into r from renewal_requests where id = p_request for update;
  if not found then raise exception '신청을 찾을 수 없습니다.'; end if;
  if (select code from students where id = r.student_id) is distinct from p ->> 'student_code' then
    raise exception '다른 학생의 신청입니다.';
  end if;
  if r.status = 'paid' then
    return jsonb_build_object('enrollment_id', r.new_enrollment_id, 'renewal_request', r.id, 'repeated', true);
  end if;
  if r.status not in ('draft', 'submitted') then raise exception '닫힌 신청입니다.'; end if;
  if coalesce((p ->> 'no_schedule')::boolean, false) then
    res := admin_register_renewal(p_request_id, p);
  else
    res := admin_renew(p_request_id, p);
  end if;
  v_enr := (res ->> 'enrollment_id')::uuid;
  select id into v_pay from payments where enrollment_id = v_enr order by confirmed_at desc limit 1;
  if r.redemption_id is not null then
    if v_method = 'bank_transfer' then
      update reward_redemptions set status = 'confirmed', payment_id = v_pay, decided_by = auth.uid()
      where id = r.redemption_id and status = 'held';
    else
      update reward_redemptions set status = 'released', note = '카드결제로 입금 확인 — 적립금 미사용', decided_by = auth.uid()
      where id = r.redemption_id and status = 'held';
    end if;
  end if;
  update renewal_requests set status = 'paid', paid_at = now(), new_enrollment_id = v_enr, method = coalesce(v_method, method),
    payer_name = coalesce(payer_name, nullif(btrim(coalesce(p #>> '{payment,payer_name}', '')), '')),
    points = case when v_method = 'bank_transfer' then points else 0 end, updated_at = now(), updated_by = auth.uid()
  where id = r.id;
  return res || jsonb_build_object('renewal_request', r.id);
end $$;
revoke all on function admin_renewal_request_confirm(uuid, uuid, jsonb) from public, anon;
grant execute on function admin_renewal_request_confirm(uuid, uuid, jsonb) to authenticated;

-- ---------- 재등록 안내 자동 메일 ----------
-- 신청 완료(입금 확인 중)한 수강권에는 안 보냄. 나머지 조건은 그대로 (20261111230000)
create or replace function lms_renewal_mail_due(p_now timestamptz default now())
returns table (enrollment_id uuid, stage text, lessons_left int)
language sql stable security definer set search_path = public as $$
  with c as (
    select e.id, e.final_end_date, lms_renewal_remaining(e.id, p_now) as n
    from enrollments e
    join students s on s.id = e.student_id
    where e.status in ('confirmed', 'active') and not s.is_trial_account
      -- 종료일 +3일 뒤에는 안 보냄 (한국 날짜, 대시보드와 같음)
      and ((p_now at time zone 'Asia/Seoul')::date) < e.final_end_date + 3
      -- 재등록이 이미 있으면 안 보냄
      and not exists (select 1 from enrollments n2 where n2.student_id = e.student_id and n2.id <> e.id
                      and n2.status in ('confirmed', 'active', 'completed') and (n2.previous_enrollment_id = e.id or n2.start_date > e.start_date))
      -- 재등록 신청을 완료했으면(입금 확인 중) 안 보냄 (대표 11/21)
      and not exists (select 1 from renewal_requests rr where rr.enrollment_id = e.id and rr.status in ('submitted', 'paid'))
      and exists (select 1 from lessons l where l.enrollment_id = e.id and l.voided_at is null and l.state <> 'canceled')
  ), st as (
    select c.id, c.final_end_date, 'week'::text as stage, c.n from c
      where c.n >= 1 and ((p_now at time zone 'Asia/Seoul')::date) >= c.final_end_date - 7
    union all
    select c.id, c.final_end_date, 'two', c.n from c where c.n between 1 and 2
    union all
    -- ended 는 끝나지 않은 수업(진행 중 포함)이 하나도 없을 때만. Class Record 기록은 보지 않음
    select c.id, c.final_end_date, 'ended', c.n from c
      where c.n = 0 and not exists (select 1 from lessons l where l.enrollment_id = c.id and l.voided_at is null and l.state = 'scheduled' and l.ends_at > p_now)
  )
  select st.id, st.stage, st.n
  from st
  where not exists (select 1 from notifications x where x.dedupe_key = 'renewal_mail:' || st.id || ':' || st.stage)
    and not (st.stage = 'two' and exists (select 1 from notifications x where x.dedupe_key in ('renewal_mail:' || st.id || ':one', 'renewal_mail:' || st.id || ':ended')))
    and not (st.stage = 'week' and exists (select 1 from notifications x where x.dedupe_key in ('renewal_mail:' || st.id || ':two', 'renewal_mail:' || st.id || ':one', 'renewal_mail:' || st.id || ':ended')))
    and not exists (
      select 1 from renewal_notices rn where rn.enrollment_id = st.id and (
           (st.stage = 'week' and ((rn.sent_at at time zone 'Asia/Seoul')::date) >= st.final_end_date - 7)
        or (st.stage = 'two' and lms_renewal_remaining(st.id, rn.sent_at) <= 2)
        or (st.stage = 'ended' and lms_renewal_remaining(st.id, rn.sent_at) = 0)))
$$;
revoke all on function lms_renewal_mail_due(timestamptz) from public, anon, authenticated;

-- 메일 문구 (대표 11/21 확정): 기간 줄 이모지 뺌, '결제 안내'(계좌·카드) 문단 → 재등록 신청 링크,
-- 세 메일 모두 '종료일' = 마지막 수업일(보강·보상 포함, 학생 거주지 날짜). 나머지 문구·※ 안내는 그대로
create or replace function lms_renewal_mail(p_enrollment uuid, p_stage text, p_left int) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_live boolean := coalesce((select x.enabled from feature_flags x where x.key = 'send_emails'), false);
  e enrollments;
  st students;
  v_tz text;
  v_intended text;
  v_to text;
  v_end timestamptz;
  v_end_text text;
  v_last timestamptz;
  v_plans jsonb;
  v_first text;
  v_second text;
  v_subject text;
  v_zone_line text := '';
  v_foot text := '문의: 카카오톡 채널 엣지영어';
  v_paras text[];
  p text;
  v_text text;
  v_html text := '';
  v_id uuid;
begin
  select * into e from enrollments where id = p_enrollment;
  select * into st from students where id = e.student_id;
  v_intended := lms_notice_recipient_email('student', st.id);
  if v_intended is null then return null; end if;
  v_to := case when v_live then v_intended else 'support@edgeenglish.kr' end;
  v_tz := coalesce(nullif(st.timezone, ''), 'Asia/Seoul');
  if v_tz <> 'Asia/Seoul' then
    v_zone_line := '모든 시간은 ' || regexp_replace(lms_mail_ko_zone(v_tz), ' 시간$', '') || ' 시간대 기준이에요.';
  end if;
  -- 종료일 = 실제 마지막 수업일 (취소·무효 아닌 수업 중 가장 늦은 날, 학생 거주지 날짜). 수업이 없으면 수강권 기간 끝
  v_last := lms_last_lesson_at(e.id);
  v_end := ((e.final_end_date + 1)::timestamp at time zone 'Asia/Seoul') - interval '1 minute';
  v_end_text := lms_mail_ko_date(coalesce(v_last, v_end), v_tz);
  v_plans := lms_renewal_plans(e.duration_min, e.weekly_count);
  v_first := case p_stage
    when 'week' then '안녕하세요 ' || st.name_ko || '님, 벌써 수강기간이 거의 끝나가서 연락드려요☺️ (종료일: ' || v_end_text || ')'
    else '안녕하세요 ' || st.name_ko || '님☺️' || E'\n'
      || case p_stage when 'ended' then '엣지영어 수강기간 수업이 모두 끝났어요!' else '엣지영어 수업이 2회 남았어요!' end
      || ' (종료일: ' || v_end_text || ')' end;
  v_second := case p_stage
    when 'ended' then '종료일까지 재등록 결제를 마치시면' || E'\n' || '지금 수업 요일·시간이 그대로 유지돼요.'
    else '지금 재등록하시면' || E'\n' || '잔여 수업이 있다면 다음 수강 기간으로 이월되고, 기존 수업 요일·시간도 그대로 유지돼요.' end;
  v_subject := case when v_live then '' else '[시험 · ' || st.code || '] ' end
    || '[엣지영어] ' || case p_stage when 'ended' then '수강기간 수업이 모두 끝났어요' when 'week' then '수강기간이 1주일 남았어요' else '수업이 2회 남았어요' end;
  v_paras := array[v_first, v_second];
  -- 가격표에 없는 코스는 코스·가격 부분을 뺌 (가격을 짐작하지 않음)
  if v_plans is not null then
    v_paras := v_paras || array[
      '**현재 수강 코스: ' || e.duration_min || '분 주 ' || e.weekly_count || '회 (월 ' || (e.weekly_count * 4) || '회)**',
      '**1개월 (4주)**' || E'\n' || to_char((v_plans ->> 'monthly')::int, 'FM999,999,999') || '원',
      '**3개월 (12주) | 5% 할인**' || E'\n' || to_char((v_plans #>> '{three,total}')::int, 'FM999,999,999') || '원 (월 '
        || to_char((v_plans #>> '{three,per_month}')::int, 'FM999,999,999') || '원)' || E'\n→ '
        || to_char((v_plans #>> '{three,save}')::int, 'FM999,999,999') || '원 절약!',
      '**6개월 (24주) | 최대 혜택**' || E'\n' || to_char((v_plans #>> '{six,total}')::int, 'FM999,999,999') || '원 (월 약 '
        || to_char((v_plans #>> '{six,per_month}')::int, 'FM999,999,999') || '원)' || E'\n→ '
        || to_char((v_plans #>> '{six,save}')::int, 'FM999,999,999') || '원 절약 + Ebook 패키지 무료!'];
  end if;
  v_paras := v_paras || array[
    '**재등록 신청하기**' || E'\n' || lms_url() || '/student/renew' || E'\n' || '수강 기간을 고르고 신청하시면 금액과 입금 정보가 바로 나와요.',
    '문의사항 있으시면 편하게 답장 주세요! ☺️',
    '※수업은 결제 완료 순서대로 확정되며, 결제 지연 시 강사 스케줄이 변동될 수 있습니다. 원하시는 강사님과 시간으로 진행을 원하시면 종료일 내에 등록해주세요. 감사합니다.'];
  v_text := '';
  foreach p in array v_paras loop
    v_text := v_text || replace(p, '**', '') || E'\n\n';
    v_html := v_html || '<p>'
      || regexp_replace(regexp_replace(replace(lms_html(p), E'\n', '<br>'), '\*\*(.+?)\*\*', '<b>\1</b>', 'g'),
                        '(https://[^\s<]+)', '<a href="\1">\1</a>', 'g')
      || '</p>';
  end loop;
  v_text := v_text || case when v_zone_line <> '' then v_zone_line || E'\n' else '' end || v_foot
    || case when v_live then '' else E'\n\n(시험 발송 · 원래 받는 사람: ' || v_intended || ')' end;
  v_html := '<div style="font-family:sans-serif;font-size:15px;line-height:1.6;color:#1d1b2a;max-width:480px">'
    || case when v_live then '' else '<p style="background:#fff4d6;color:#5c3b00;border-radius:8px;padding:8px 10px;font-size:13px;font-weight:600">시험 발송 · 원래 받는 사람: ' || lms_html(v_intended) || '</p>' end
    || v_html
    || '<p style="font-size:12.5px;color:#55526a;border-top:1px solid #e6e3ef;padding-top:10px">'
    || case when v_zone_line <> '' then lms_html(v_zone_line) || '<br>' else '' end || lms_html(v_foot) || '</p></div>';
  insert into notifications (recipient_kind, recipient_id, email, locale, template, payload, dedupe_key)
  values ('student', st.id, v_to, 'ko', 'renewal_' || p_stage,
          jsonb_build_object('intended_email', v_intended, 'subject', v_subject, 'html', v_html, 'text', v_text,
                             'enrollment_id', e.id, 'stage', p_stage, 'lessons_left', p_left),
          'renewal_mail:' || e.id || ':' || p_stage)
  on conflict (dedupe_key) do nothing
  returning id into v_id;
  if v_id is not null then perform lms_mail_dispatch(v_id); end if;
  return v_id;
end $$;
revoke all on function lms_renewal_mail(uuid, text, int) from public, anon, authenticated;
