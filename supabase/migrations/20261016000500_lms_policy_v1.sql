-- =====================================================================
-- LMS 정책 원본 v1.0 반영 (2026-10-16 대표확정, docs/lms/policy/official-source.md)
-- 어떤 Supabase에도 적용하지 않은 초안. 실제 운영 DB 적용은 대표 승인 후.
--
-- 1. 등록별 자동 적용 규칙 (POL-OP-16 — 소급 금지)
-- 2. 실제 결제 완료 시각 (POL-RN-01 — 이월은 운영자 확인 시각이 아니라 실제 결제 시각 기준)
-- 3. 공휴일 종류 (POL-CHG-07 — 법정·대체·임시공휴일만)
-- 4. 강사 노쇼 보상 수업 7일 기한 (POL-TU-03)
-- 5. 보상 적립금 단일 원장 (POL-PAY-09)
-- 6. 운영 업무: 신규 매칭 3영업일·재등록 강사 통보 확인 (POL-OP-13·14)
-- 7. 학생 장기 연기 신청 (POL-LV-01)
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. 등록별 자동 적용 규칙
-- 'policy_v1' = 정책 원본 v1.0 조건을 안내·동의받은 등록(신규·갱신)만. 기존 등록을 일괄로 바꾸지 않는다.
-- 'legacy' = 예전 계약서·예전 안내서·미확인 → 판본마다 다를 수 있는 규칙은 운영자가 확인
-- ---------------------------------------------------------------------
alter table enrollments add column policy_basis text not null default 'legacy'
  check (policy_basis in ('policy_v1', 'legacy'));

-- ---------------------------------------------------------------------
-- 2. 실제 결제 완료 시각
-- ---------------------------------------------------------------------
alter table payments add column paid_at timestamptz not null;   -- 실제 입금·결제 완료 시각 (은행 거래내역·아임웹 주문 시각)
alter table payments add column external_ref text unique;       -- 아임웹 주문번호·은행 거래 식별값 (같은 결제 두 번 기록 방지)
alter table payments add constraint payments_paid_on_matches
  check (((paid_at at time zone 'UTC') + interval '9 hours')::date = received_on);

-- ---------------------------------------------------------------------
-- 3. 공휴일 종류 (운영자 임의 추가일 없음)
-- ---------------------------------------------------------------------
alter table holidays add column kind text not null default 'legal'
  check (kind in ('legal', 'substitute', 'temporary'));         -- 법정공휴일 · 대체공휴일 · 임시공휴일

-- ---------------------------------------------------------------------
-- 4. 강사 노쇼 보상 수업 기한: 지급일(KST)부터 7일째 날까지 수업 완료 (A14)
-- 'policy_v1' 등록은 비어 있으면 자동으로 채움. 기한이 지나도 자동 소멸시키지 않음 (예외 미확정 POL-TU-10)
-- ---------------------------------------------------------------------
create or replace function compensation_set_deadline() returns trigger
language plpgsql as $$
begin
  if new.expires_on is null and (select policy_basis from enrollments where id = new.enrollment_id) = 'policy_v1' then
    new.expires_on := ((new.created_at at time zone 'UTC') + interval '9 hours')::date + 7;
  end if;
  return new;
end $$;
create trigger compensations_deadline before insert on compensations
  for each row execute function compensation_set_deadline();

-- ---------------------------------------------------------------------
-- 5. 보상 적립금 단일 원장 (아임웹 회원 적립금 병행 안 함, 유효기간 없음)
-- 사용 흐름: 예약(held, 잔액에서 빠짐) → 실제 결제 확인 후 확정(confirmed) / 미결제·취소면 복구(released)
--           확정 후 결제가 취소·환불되면 운영자가 복구(restored)
-- ---------------------------------------------------------------------
create table reward_redemptions (
  id uuid primary key default gen_random_uuid(),
  student_id uuid not null references students(id),
  enrollment_id uuid not null references enrollments(id),     -- 적립금을 쓸 등록(재등록)
  amount integer not null check (amount > 0),
  method text not null check (method in ('bank_transfer', 'card_link')),
  coupon_code text,                                           -- 카드결제 연계 방식은 미확정 (POL-PAY-10)
  status text not null default 'held' check (status in ('held', 'confirmed', 'released', 'restored')),
  payment_id uuid unique references payments(id),             -- 확정 근거. 같은 결제에 두 번 적용 불가
  note text,
  created_by uuid,
  created_at timestamptz not null default now(),
  decided_by uuid,
  decided_at timestamptz,
  check ((status in ('confirmed', 'restored')) = (payment_id is not null)),
  check (status not in ('released', 'restored') or note is not null)   -- 되돌린 이유
);
create unique index reward_redemptions_one_live on reward_redemptions (enrollment_id) where status in ('held', 'confirmed');
create trigger reward_redemptions_no_delete before delete on reward_redemptions for each row execute function forbid_delete();

create table reward_ledger (
  id uuid primary key default gen_random_uuid(),
  student_id uuid not null references students(id),
  kind text not null check (kind in ('grant_tutor_late_cancel', 'grant_admin', 'hold', 'release', 'refund_restore', 'admin_adjust')),
  amount integer not null check (amount <> 0),                -- +적립 / −사용(예약)
  lesson_id uuid references lessons(id),                      -- 강사 늦은 취소 지급의 근거 수업
  redemption_id uuid references reward_redemptions(id),
  note text,
  created_by uuid,
  created_at timestamptz not null default now(),
  check (kind <> 'grant_tutor_late_cancel' or (lesson_id is not null and amount > 0)),
  check (kind not in ('hold', 'release', 'refund_restore') or redemption_id is not null),
  check (kind <> 'hold' or amount < 0),
  check (kind not in ('grant_admin', 'release', 'refund_restore') or amount > 0),
  check (kind not in ('grant_admin', 'admin_adjust') or note is not null)
);
create unique index reward_ledger_one_grant_per_lesson on reward_ledger (lesson_id) where kind = 'grant_tutor_late_cancel';  -- 중복 지급 방지
create unique index reward_ledger_once_per_redemption on reward_ledger (redemption_id, kind) where redemption_id is not null;
create trigger reward_ledger_no_update before update on reward_ledger for each row execute function forbid_update();
create trigger reward_ledger_no_delete before delete on reward_ledger for each row execute function forbid_delete();

create or replace function reward_balance(p_student uuid) returns integer
language sql stable as $$
  select coalesce(sum(amount), 0)::int from reward_ledger where student_id = p_student
$$;

-- 원장 한 줄을 넣기 전 검사: 학생 행을 잠가 동시에 눌러도 순서대로, 잔액 0 미만 금지, 근거 확인
create or replace function reward_ledger_guard() returns trigger
language plpgsql as $$
declare
  l record;
  r record;
begin
  perform 1 from students where id = new.student_id for update;
  if new.kind = 'grant_tutor_late_cancel' then
    select ls.student_id, ls.class_status, e.policy_basis into l
      from lessons ls join enrollments e on e.id = ls.enrollment_id where ls.id = new.lesson_id;
    if l.student_id is distinct from new.student_id then raise exception '다른 학생의 수업으로 적립할 수 없습니다.'; end if;
    if l.class_status is distinct from 'Tutor canceled late' then raise exception '강사 6시간 미만 취소 수업에만 자동 적립합니다.'; end if;
    -- 기존 등록(legacy)에 새 보상을 줄지는 대표 결정 대기 (POL-OP-17) → 운영자 지급(grant_admin, 사유 필수)으로만
    if l.policy_basis <> 'policy_v1' then raise exception '정책 원본 적용 등록이 아니라 자동 적립하지 않습니다. 운영자 지급으로 처리하세요.'; end if;
  end if;
  if new.redemption_id is not null then
    select * into r from reward_redemptions where id = new.redemption_id;
    if r.student_id <> new.student_id then raise exception '다른 학생의 사용 요청입니다.'; end if;
    if new.kind in ('hold', 'release', 'refund_restore') and abs(new.amount) <> r.amount then
      raise exception '사용 요청 금액과 다릅니다.';
    end if;
  end if;
  if reward_balance(new.student_id) + new.amount < 0 then raise exception '적립금 잔액이 부족합니다.'; end if;
  return new;
end $$;
create trigger reward_ledger_guard before insert on reward_ledger for each row execute function reward_ledger_guard();

-- 사용 요청 상태는 정해진 순서로만: held → confirmed / released, confirmed → restored
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
  if new.status = 'confirmed'
     and (select enrollment_id from payments where id = new.payment_id) is distinct from new.enrollment_id then
    raise exception '이 등록의 결제 기록으로만 확정할 수 있습니다.';
  end if;
  if new.decided_at is null then new.decided_at := now(); end if;
  return new;
end $$;
create trigger reward_redemptions_check before insert or update on reward_redemptions
  for each row execute function reward_redemption_check();

-- 원장 기록은 상태와 함께 자동 (예약 = −금액, 복구 = +금액, 확정은 원장 변화 없음)
create or replace function reward_redemption_ledger() returns trigger
language plpgsql as $$
begin
  if tg_op = 'INSERT' then
    insert into reward_ledger (student_id, kind, amount, redemption_id, created_by)
    values (new.student_id, 'hold', -new.amount, new.id, new.created_by);
  elsif new.status <> old.status and new.status in ('released', 'restored') then
    insert into reward_ledger (student_id, kind, amount, redemption_id, note, created_by)
    values (new.student_id, case new.status when 'released' then 'release' else 'refund_restore' end,
            new.amount, new.id, new.note, new.decided_by);
  end if;
  return null;
end $$;
create trigger reward_redemptions_ledger after insert or update on reward_redemptions
  for each row execute function reward_redemption_ledger();

-- ---------------------------------------------------------------------
-- 6. 운영 업무 (관리자 '처리할 일') — 결제 확인 즉시 자동 생성, 완료 조건을 채우기 전에는 닫을 수 없음
-- - new_student_matching: 신규 학생 강사 매칭 + 학생 안내 (3영업일, POL-OP-13)
-- - renewal_tutor_notice: 재등록 사실·기간·일정 강사 통보 + 강사 확인 + 일정 조치 (POL-OP-14)
-- ---------------------------------------------------------------------

-- 영업일 = 토·일·holidays 제외. 시작 날짜 다음 날부터 셈
create or replace function add_business_days(p_from date, p_n integer) returns date
language plpgsql stable as $$
declare
  d date := p_from;
  left_days integer := p_n;
begin
  if p_n is null or p_n < 1 then raise exception '영업일 수가 올바르지 않습니다: %', p_n; end if;
  while left_days > 0 loop
    d := d + 1;
    if extract(isodow from d) < 6 and not exists (select 1 from holidays where day = d) then
      left_days := left_days - 1;
    end if;
  end loop;
  return d;
end $$;

create table admin_tasks (
  id uuid primary key default gen_random_uuid(),
  kind text not null check (kind in ('new_student_matching', 'renewal_tutor_notice')),
  enrollment_id uuid not null references enrollments(id),
  payment_id uuid references payments(id),           -- 업무를 만든 결제 확인
  tutor_id uuid references tutors(id),               -- 매칭한 강사 / 통보할 담당 강사
  due_at timestamptz,                                -- 처리 기한 (매칭: 3영업일 23:59 KST, 재등록 통보: 기준 미정 → 비워 둠)
  tutor_assigned_at timestamptz,                     -- 매칭: 강사 배정
  student_notified_at timestamptz,                   -- 매칭: 학생에게 강사·일정 안내
  tutor_notified_at timestamptz,                     -- 재등록: 강사에게 연장·기간·일정 통보
  tutor_acknowledged_at timestamptz,                 -- 재등록: 강사가 [확인] (발송 성공만으로 끝내지 않음)
  schedule_checked_at timestamptz,                   -- 재등록: 필요한 일정 조치 완료
  tutor_change_planned boolean not null default false, -- 재등록 때 강사 변경 예정 → 별도 처리 표시
  status text not null default 'open' check (status in ('open', 'done', 'canceled')),
  done_at timestamptz,
  done_by uuid,
  cancel_reason text,
  created_at timestamptz not null default now(),
  unique (kind, enrollment_id),                      -- 같은 등록에 같은 업무는 하나 (중복·누락 방지)
  check (status <> 'done' or done_at is not null),
  check (status <> 'canceled' or cancel_reason is not null),
  check (status <> 'done' or kind <> 'new_student_matching'
         or (tutor_id is not null and tutor_assigned_at is not null and student_notified_at is not null)),
  check (status <> 'done' or kind <> 'renewal_tutor_notice'
         or (tutor_id is not null and tutor_notified_at is not null and tutor_acknowledged_at is not null and schedule_checked_at is not null))
);
create trigger admin_tasks_no_delete before delete on admin_tasks for each row execute function forbid_delete();

-- 결제 확인 기록이 들어오면 업무 자동 생성 (첫 결제만, 나눠 낸 두 번째 결제는 무시)
create or replace function create_task_on_payment() returns trigger
language plpgsql as $$
declare
  e record;
  t uuid;
  kst_day date := ((new.confirmed_at at time zone 'UTC') + interval '9 hours')::date;
begin
  select id, student_id, previous_enrollment_id into e from enrollments where id = new.enrollment_id;
  if e.previous_enrollment_id is null then
    insert into admin_tasks (kind, enrollment_id, payment_id, due_at)
    values ('new_student_matching', e.id, new.id,
            (add_business_days(kst_day, 3) + interval '1 day') at time zone 'Asia/Seoul' - interval '1 microsecond')
    on conflict (kind, enrollment_id) do nothing;
  else
    select tutor_id into t from regular_schedules
      where student_id = e.student_id and (effective_to is null or effective_to >= kst_day)
      order by effective_from desc limit 1;
    insert into admin_tasks (kind, enrollment_id, payment_id, tutor_id)
    values ('renewal_tutor_notice', e.id, new.id, t)
    on conflict (kind, enrollment_id) do nothing;
  end if;
  return null;
end $$;
create trigger payments_create_task after insert on payments for each row execute function create_task_on_payment();

-- 관리자 화면용: 열린 업무와 급한 정도 (overdue 기한 초과 · due_soon 24시간 안 · open)
create view admin_task_board with (security_invoker = true) as
select t.*,
       case when t.due_at is not null and now() > t.due_at then 'overdue'
            when t.due_at is not null and now() > t.due_at - interval '24 hours' then 'due_soon'
            else 'open' end as urgency,
       case t.kind
         when 'new_student_matching' then
           array_remove(array[case when t.tutor_assigned_at is null then 'assign_tutor' end,
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
revoke all on admin_task_board from anon, authenticated;
grant select on admin_task_board to authenticated;   -- security_invoker: 실제로 보이는 행은 admin_tasks 의 RLS 대로

-- ---------------------------------------------------------------------
-- 7. 학생 장기 연기 신청 (24주만, 총 14일, 7일 단위 최대 2회 — 'policy_v1' 등록)
-- 기한(시작 4일 전)·사유 검사는 서버 규칙(leave.ts evaluateLongLeaveRequest)이 하고, DB는 한도를 마지막으로 지킴.
-- 승인되면 서버가 enrollment_extensions(student_long_term_leave)를 함께 기록
-- ---------------------------------------------------------------------
create table long_leave_requests (
  id uuid primary key default gen_random_uuid(),
  enrollment_id uuid not null references enrollments(id),
  change_request_id uuid unique references change_requests(id),
  leave_start date not null,
  days integer not null check (days in (7, 14)),
  reason_kind text not null check (reason_kind in ('health', 'family_emergency', 'business_trip', 'other_special')),
  evidence_note text,                       -- 증빙 확인 메모 (진단서 등 파일 자체는 비공개 저장소, 이름·병명은 적지 않음)
  status text not null default 'pending' check (status in ('pending', 'approved', 'rejected', 'withdrawn')),
  extension_id uuid unique references enrollment_extensions(id),
  decided_by uuid,
  decided_at timestamptz,
  created_at timestamptz not null default now(),
  check ((status = 'approved') = (extension_id is not null)),
  check (status <> 'approved' or evidence_note is not null)
);
create trigger long_leave_requests_no_delete before delete on long_leave_requests for each row execute function forbid_delete();

create or replace function long_leave_guard() returns trigger
language plpgsql as $$
declare
  e record;
  used_days integer;
  used_count integer;
begin
  select * into e from enrollments where id = new.enrollment_id for update;
  if e.policy_basis <> 'policy_v1' then
    raise exception '정책 원본 적용 등록이 아니라 장기 연기를 자동 접수하지 않습니다. 계약 조건을 확인해 운영자가 처리하세요.';
  end if;
  if e.weeks is distinct from 24 then raise exception '장기 연기는 24주 수강권만 가능합니다.'; end if;
  if new.leave_start < e.start_date or new.leave_start > e.final_end_date then
    raise exception '연기 시작일은 수강기간 안이어야 합니다.';
  end if;
  if new.status in ('pending', 'approved') then
    select coalesce(sum(days), 0), count(*) into used_days, used_count from long_leave_requests
      where enrollment_id = new.enrollment_id and status in ('pending', 'approved') and id <> new.id;
    if used_count + 1 > 2 or used_days + new.days > 14 then
      raise exception '장기 연기는 수강기간 동안 최대 14일(2회)까지입니다.';
    end if;
  end if;
  return new;
end $$;
create trigger long_leave_requests_guard before insert or update on long_leave_requests
  for each row execute function long_leave_guard();

-- ---------------------------------------------------------------------
-- 보호 적용 · 읽기 권한
-- ---------------------------------------------------------------------
select lms_protect(t::regclass) from unnest(array['reward_redemptions', 'reward_ledger', 'admin_tasks', 'long_leave_requests']) as t;

create policy student_own on reward_ledger for select to authenticated using (student_id = my_student_id());
create policy student_own on reward_redemptions for select to authenticated using (student_id = my_student_id());
create policy student_own on long_leave_requests for select to authenticated
  using (exists (select 1 from enrollments e where e.id = enrollment_id and e.student_id = my_student_id()));
-- 강사는 본인에게 온 재등록 통보만 (매칭 업무·학생 결제 정보는 보이지 않음)
create policy tutor_own on admin_tasks for select to authenticated
  using (kind = 'renewal_tutor_notice' and tutor_id = my_tutor_id());
