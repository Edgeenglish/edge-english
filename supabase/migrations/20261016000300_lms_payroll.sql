-- =====================================================================
-- LMS 6단계: 강사 계약 조건 · 정산 (초안 v0.2)
-- 급여 기준이 확정(D-13~15, D-17)되기 전에는 적용하지 않는다.
-- =====================================================================

-- 강사별 계약 조건 (CF-08: 판본마다 기본 시급이 다름 — TC1 $14, TC2·TC3 $11)
create table tutor_contracts (
  id uuid primary key default gen_random_uuid(),
  tutor_id uuid not null references tutors(id),
  terms_version text not null references terms_versions(code)
    check (terms_audience(terms_version) = 'tutor'),
  signed_on date not null,
  base_rate_usd numeric(6, 2) not null check (base_rate_usd > 0),
  max_rate_usd numeric(6, 2) not null,
  valid_to date,
  note text,
  check (max_rate_usd >= base_rate_usd),
  exclude using gist (tutor_id with =, daterange(signed_on, valid_to, '[]') with &&)
);

-- 승인된 인센티브 규칙 (승인 전에는 행이 없어 계산 자체가 안 됨)
create table pay_policies (
  id uuid primary key default gen_random_uuid(),
  effective_from date not null unique,
  rules jsonb not null,                    -- 인센티브 조건·가산액 (register.md POL-WG-02 의 승인된 값)
  policy_refs text[] not null,
  approved_by uuid not null,
  approved_at timestamptz not null default now()
);

create table payroll_runs (
  id uuid primary key default gen_random_uuid(),
  tutor_id uuid not null references tutors(id),
  month date not null check (extract(day from month) = 1),
  contract_id uuid references tutor_contracts(id),
  policy_id uuid references pay_policies(id),
  status text not null default 'draft' check (status in ('draft', 'approved', 'paid')),
  computed jsonb,                          -- 자동 계산 결과 (참고용)
  final_amount_usd numeric(8, 2),          -- 운영자가 확인·승인한 최종 금액
  approved_by uuid,
  approved_at timestamptz,
  paid_at timestamptz,
  unique (tutor_id, month),
  check (status = 'draft' or (final_amount_usd is not null and approved_by is not null))
);

create table payroll_items (
  id uuid primary key default gen_random_uuid(),
  run_id uuid not null references payroll_runs(id),
  lesson_id uuid not null unique references lessons(id),   -- 같은 수업 두 번 정산 방지
  minutes integer not null check (minutes > 0),
  payable boolean not null,                -- 상태매핑표 + 수업 종류(보상 수업은 미지급, POL-WG-08)
  note text
);

select lms_protect(t::regclass) from unnest(array['tutor_contracts', 'pay_policies', 'payroll_runs', 'payroll_items']) as t;

create policy tutor_own on payroll_runs for select to authenticated using (tutor_id = my_tutor_id() and status <> 'draft');
create policy tutor_own on tutor_contracts for select to authenticated using (tutor_id = my_tutor_id());
