-- =====================================================================
-- 첫 수업 시작 전 개별 수업 날짜 변경 — 변경권 차감 없음 (2026-11-06 대표 요청, 정책 원본 H26(60)·(62))
--  - 등록을 마친 학생이 첫 수업 전에 특정 날짜를 바꾸고 싶다고 하면, 운영진이 학생 상세에서 그 수업만 옮김
--  - 조건: 그 수강권의 첫 수업(취소·무효 제외) 시작 전, 정규·예정 수업, 새 날짜는 수강 기간 안, 지난 시각 불가,
--          같은 날 이 학생 다른 수업 없음
--  - 강사 쪽 검사는 보강 확정과 같은 기준(lms_makeup_conflict 순서): 휴무 → 다른 수업(휴식 10분) → 현지 06:00~22:30
--    → 강사가 연 시간(Availability·Schedule, 막은 시간 포함) → 재등록 대기 자리. 옮기는 수업 자신은 빼고 검사
--  - 변경권·보강 기록은 만들지 않음. 기록은 prestart_moves + lessons 변경 이력(actor_via = admin_prestart_move)
--  - 날짜 순서가 바뀌면 정규 회차 번호를 날짜순으로 다시 매김 (시작 전이라 기록된 수업 없음)
--  - 기존 표·데이터를 바꾸지 않고 표 하나·함수 하나 추가. 다시 실행해도 같은 결과
-- =====================================================================

create table if not exists prestart_moves (
  id uuid primary key default gen_random_uuid(),
  lesson_id uuid not null references lessons(id),
  enrollment_id uuid not null references enrollments(id),
  student_id uuid not null references students(id),
  from_starts_at timestamptz not null,
  from_ends_at timestamptz not null,
  to_starts_at timestamptz not null,
  to_ends_at timestamptz not null,
  created_by uuid not null,
  created_at timestamptz not null default now()
);
create index if not exists prestart_moves_student on prestart_moves (student_id, created_at);
do $$ begin
  if not exists (select 1 from pg_trigger where tgname = 'prestart_moves_no_delete') then
    create trigger prestart_moves_no_delete before delete on prestart_moves for each row execute function forbid_delete();
  end if;
  if not exists (select 1 from pg_trigger where tgname = 'prestart_moves_audit') then
    create trigger prestart_moves_audit after insert or update on prestart_moves for each row execute function write_audit();
  end if;
  if not exists (select 1 from pg_policies where tablename = 'prestart_moves' and policyname = 'admin_read') then
    create policy admin_read on prestart_moves for select to authenticated using (is_admin());
  end if;
end $$;
alter table prestart_moves enable row level security;
revoke all on prestart_moves from public, anon;
grant select on prestart_moves to authenticated;

-- 수업 하나를 새 시각으로 (p_dry_run = 검사만). 문제가 있으면 오류(hint = prestart_move)로 사유를 돌려줌
create or replace function admin_prestart_move(p_lesson uuid, p_starts_at timestamptz, p_dry_run boolean default false)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_break constant interval := interval '10 minutes';   -- POL-OP-21
  l lessons;
  e enrollments;
  v_first timestamptz;
  t0 timestamptz := p_starts_at;
  t1 timestamptz;
  d date;
  v_why text;
  v_move uuid;
begin
  if not is_admin() then raise exception '운영자(추가 인증 완료)만 수업 날짜를 바꿀 수 있습니다.' using errcode = '42501'; end if;
  select * into l from lessons where id = p_lesson for update;
  if not found then raise exception '수업이 없습니다.'; end if;
  if l.kind <> 'regular' or l.state <> 'scheduled' or l.voided_at is not null then
    raise exception '예정된 정규 수업만 바꿀 수 있습니다.';
  end if;
  select * into e from enrollments where id = l.enrollment_id;
  if e.status not in ('confirmed', 'active') then raise exception '결제 확인된 수강권의 수업만 바꿀 수 있습니다.'; end if;
  perform pg_advisory_xact_lock(hashtextextended(e.id::text, 0));
  select min(x.starts_at) into v_first from lessons x where x.enrollment_id = e.id and x.state <> 'canceled' and x.voided_at is null;
  if now() >= v_first then
    raise exception '첫 수업이 이미 시작됐습니다. 시작 뒤 변경은 수업 변경(변경권)으로 처리해 주세요.' using hint = 'prestart_move';
  end if;
  if t0 is null or t0 <= now() then raise exception '지난 시각으로는 옮길 수 없습니다.' using hint = 'prestart_move'; end if;
  t1 := t0 + (l.ends_at - l.starts_at);
  d := (t0 at time zone 'Asia/Seoul')::date;
  if t0 = l.starts_at then raise exception '지금 시각과 같습니다.' using hint = 'prestart_move'; end if;
  if d < e.start_date or d > e.final_end_date then
    raise exception '수강 기간(% ~ %) 밖 날짜입니다.', to_char(e.start_date, 'FMMM/FMDD'), to_char(e.final_end_date, 'FMMM/FMDD') using hint = 'prestart_move';
  end if;
  if exists (select 1 from lessons y where y.student_id = l.student_id and y.id <> l.id and y.state <> 'canceled' and y.voided_at is null
             and (y.starts_at at time zone 'Asia/Seoul')::date = d) then
    raise exception '그날 이 학생 수업이 이미 있습니다.' using hint = 'prestart_move';
  end if;

  -- 강사 쪽 (보강 확정과 같은 순서, 옮기는 수업 자신은 제외)
  if exists (select 1 from tutor_time_off o where o.tutor_id = l.tutor_id and o.kind = 'leave' and o.starts_at < t1 and t0 < o.ends_at) then
    v_why := '그 시간은 강사 휴무입니다.';
  elsif exists (select 1 from lessons x where x.tutor_id = l.tutor_id and x.id <> l.id and x.state <> 'canceled'
                and x.starts_at < t1 + v_break and t0 - v_break < x.ends_at) then
    v_why := '그 시간은 강사의 다른 수업과 겹칩니다 (앞뒤 휴식 10분 포함).';
  elsif not lms_tutor_start_ok(l.tutor_id, t0) then
    v_why := '강사 현지 06:00~22:30 에 시작하는 시간만 예약할 수 있습니다.';
  elsif not lms_tutor_available(l.tutor_id, t0)
        or exists (select 1 from tutor_time_off o where o.tutor_id = l.tutor_id and o.kind = 'block' and o.starts_at < t1 and t0 < o.ends_at) then
    v_why := '강사가 열어 둔 시간이 아닙니다 (Availability·Schedule).';
  elsif exists (select 1 from lms_slot_hold_hits(l.tutor_id, t0, t1) h where h.student_id <> l.student_id) then
    v_why := '재등록 대기 중인 다른 학생의 고정 시간입니다.';
  end if;
  if v_why is not null then raise exception '%', v_why using hint = 'prestart_move'; end if;

  if p_dry_run then
    return jsonb_build_object('ok', true, 'lesson_id', l.id, 'seq', l.seq, 'from', l.starts_at, 'to', t0);
  end if;

  perform set_config('app.actor_id', auth.uid()::text, true);
  perform set_config('app.actor_via', 'admin_prestart_move', true);
  update lessons set starts_at = t0, ends_at = t1 where id = l.id;
  -- 정규 회차 번호를 날짜순으로 (고유 번호라 두 단계로)
  update lessons set seq = seq + 100000 where enrollment_id = e.id and kind = 'regular';
  update lessons x set seq = r.n
  from (select id, row_number() over (order by starts_at, id) as n from lessons where enrollment_id = e.id and kind = 'regular') r
  where x.id = r.id;
  insert into prestart_moves (lesson_id, enrollment_id, student_id, from_starts_at, from_ends_at, to_starts_at, to_ends_at, created_by)
  values (l.id, e.id, l.student_id, l.starts_at, l.ends_at, t0, t1, auth.uid())
  returning id into v_move;
  return jsonb_build_object('ok', true, 'move_id', v_move, 'lesson_id', l.id, 'from', l.starts_at, 'to', t0,
                            'seq', (select seq from lessons where id = l.id));
exception
  when exclusion_violation then
    raise exception '그 시간에 이 학생 또는 강사의 다른 수업이 있어 저장하지 않았습니다.' using hint = 'prestart_move';
end $$;
revoke all on function admin_prestart_move(uuid, timestamptz, boolean) from public, anon;
grant execute on function admin_prestart_move(uuid, timestamptz, boolean) to authenticated;
