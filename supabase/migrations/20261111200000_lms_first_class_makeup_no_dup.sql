-- 첫 수업 = 정규·보강·보상수업 구분 없이 실제로 가장 먼저 하는 수업 (대표 11/12 한국 시간, 정책 원본 H26(153)).
-- 새 첫 수업이 보강·보상수업이고 그 일정을 이미 보강 확정·시간 변경 메일로 받은 사람에게는 '첫 수업 일정이 변경됐어요' 메일을 보내지 않는다(같은 일정 메일 두 번 금지).
-- 보강 수업이 새로 생길 때도(INSERT) 바로 다시 확인 (예전에는 수업 정보가 바뀔 때·15분 예약 실행 때만이라 늦게 나감).

create or replace function lms_first_class_check(p_enrollment uuid, p_now timestamptz default now(), p_tutor_now boolean default false)
returns integer language plpgsql security definer set search_path = public as $$
declare
  v_since timestamptz := (select x.updated_at from feature_flags x where x.key = 'first_class_mail_since');
  e enrollments;
  f lessons;
  st students;
  tu tutors;
  p lessons;
  v_slots jsonb;
  v_prev_slots jsonb;
  v_expected timestamptz;
  v_same boolean := true;
  v_gap boolean := false;
  v_renew boolean;
  v_every timestamptz[];
  v_version text;
  v_in_window boolean;
  v_label text;
  v_name text;
  v_n integer := 0;
  v_last_version text;
  v_last_slots jsonb;
  v_reminded boolean;
  v_id uuid;
  rk text;
  rid uuid;
  v_dup boolean;
begin
  if v_since is null then return 0; end if;
  select * into e from enrollments where id = p_enrollment;
  if not found or e.status not in ('confirmed', 'active') or e.created_at < v_since then return 0; end if;
  select * into f from lessons where enrollment_id = e.id and voided_at is null and state <> 'canceled' order by starts_at limit 1;
  if not found or f.starts_at <= p_now then return 0; end if;   -- 첫 수업이 시작됨(또는 수업 없음) → 끝
  select * into st from students where id = e.student_id;
  select * into tu from tutors where id = f.tutor_id;
  v_slots := lms_slots_on(st.id, greatest(e.start_date, (f.starts_at at time zone 'Asia/Seoul')::date));
  v_renew := e.previous_enrollment_id is not null;
  if v_renew then
    select * into p from lessons where enrollment_id = e.previous_enrollment_id and kind = 'regular' and voided_at is null and state <> 'canceled'
    order by starts_at desc limit 1;
    if p.id is not null then
      v_prev_slots := lms_slots_on(st.id, (p.starts_at at time zone 'Asia/Seoul')::date);
      v_same := v_prev_slots = v_slots;
      -- 이전 고정 일정대로 계속했다면 나왔을 다음 수업
      select min(t) into v_expected from unnest(lms_slot_times(v_prev_slots, (p.starts_at at time zone 'Asia/Seoul')::date + 1)) t;
      v_gap := v_expected is distinct from f.starts_at;
      if v_same and not v_gap then return 0; end if;            -- 같은 요일·시간 그대로 공백 없이 이어짐 → 안 보냄
    end if;
  end if;
  v_every := lms_slot_times(v_slots, (f.starts_at at time zone 'Asia/Seoul')::date);
  if v_every is null then v_every := array[f.starts_at]; end if;
  v_version := md5(f.id::text || f.starts_at::text || f.tutor_id::text || v_slots::text);
  v_in_window := p_now >= f.starts_at - interval '24 hours';
  v_name := lms_student_en(st);

  for rk, rid in select * from (values ('student', st.id), ('tutor', f.tutor_id)) v(k, i) loop
    v_last_version := null; v_last_slots := null;
    select x.payload ->> 'version', x.payload -> 'slots' into v_last_version, v_last_slots
    from notifications x where x.recipient_kind = rk and x.recipient_id = rid and x.template in ('lesson_notice_first_class', 'lesson_notice_tutor_first_class')
      and x.payload ->> 'enrollment_id' = e.id::text and (x.status <> 'canceled' or x.payload ->> 'stage' = 'skipped')
    order by x.created_at desc limit 1;
    v_reminded := exists (select 1 from notifications x where x.recipient_kind = rk and x.recipient_id = rid
      and x.template in ('lesson_notice_first_class', 'lesson_notice_tutor_first_class') and x.payload ->> 'enrollment_id' = e.id::text
      and x.payload ->> 'stage' = 'reminder' and x.status <> 'canceled');
    v_id := null;
    if not v_reminded and v_in_window then
      -- 첫 안내 (24시간 전 / 그 안에 확정되면 바로)
      v_label := case when v_renew and not v_same then '새로 정한 수업 일정' else '정규 수업' end;
      if rk = 'student' then
        v_id := lms_first_class_mail_student(e, f, v_every, v_label, false, 'first_class:' || e.id || ':student:reminder:' || v_version, v_version, v_slots);
      else
        v_id := lms_tutor_first_class_mail(e, f, v_every, false, 'first_class:' || e.id || ':' || rid || ':reminder:' || v_version, v_version, v_slots, 'reminder');
      end if;
    elsif (v_reminded and v_last_version is distinct from v_version)
          or (rk = 'tutor' and p_tutor_now and v_last_version is distinct from v_version) then
      -- 보낸 뒤 바뀜 → 바로 변경 안내 (강사는 첫 수업 날짜가 바뀌면 24시간 전이 아니어도 바로, H26(127))
      -- 새 첫 수업이 보강·보상수업이고 그 시각을 이미 보강 확정·시간 변경 메일로 받았으면 변경 메일은 생략 (대표 11/12 H26(153): 수업은 다 같은 수업, 같은 일정 메일 두 번 금지)
      v_dup := f.kind <> 'regular' and exists (
        select 1 from lesson_notices ln join makeup_requests mr on mr.id = ln.makeup_request_id
        where mr.confirmed_lesson_id = f.id and ln.event in ('makeup_confirmed', 'makeup_rescheduled')
          and ln.recipient_kind = rk and ln.recipient_id = rid);
      if v_dup then
        insert into notifications (recipient_kind, recipient_id, email, locale, template, payload, dedupe_key, status, last_error)
        values (rk, rid, coalesce(lms_notice_recipient_email(rk, rid), 'support@edgeenglish.kr'), case when rk = 'student' then 'ko' else 'en' end,
                case when rk = 'student' then 'lesson_notice_first_class' else 'lesson_notice_tutor_first_class' end,
                jsonb_build_object('enrollment_id', e.id, 'version', v_version, 'slots', v_slots, 'stage', 'skipped', 'reason', 'makeup_mail_already_sent'),
                'first_class:' || e.id || ':' || rid || ':skipped:' || v_version, 'canceled', '보강 확정 메일로 이미 안내됨 — 첫 수업 변경 메일 생략')
        on conflict (dedupe_key) do nothing;
        continue;
      end if;
      v_label := case when v_last_slots is not null and v_last_slots <> v_slots then '새로 정한 수업 일정'
                      when v_last_slots is null and v_renew and not v_same then '새로 정한 수업 일정' else '정규 수업' end;
      if rk = 'student' then
        v_id := lms_first_class_mail_student(e, f, v_every, v_label, true, 'first_class:' || e.id || ':student:change:' || v_version, v_version, v_slots);
      else
        v_id := lms_tutor_first_class_mail(e, f, v_every, true, 'first_class:' || e.id || ':' || rid || ':change:' || v_version, v_version, v_slots, 'change');
      end if;
    end if;
    if v_id is not null then v_n := v_n + 1; end if;
  end loop;
  return v_n;
end $$;

create or replace function lms_lessons_first_class_recheck() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.enrollment_id is not null and (tg_op = 'INSERT' or new.starts_at is distinct from old.starts_at or new.state is distinct from old.state
       or new.tutor_id is distinct from old.tutor_id or new.voided_at is distinct from old.voided_at) then
    perform lms_first_class_check(new.enrollment_id);
  end if;
  return null;
end $$;
drop trigger if exists lessons_first_class_recheck on lessons;
create constraint trigger lessons_first_class_recheck after insert or update on lessons
  deferrable initially deferred for each row execute function lms_lessons_first_class_recheck();
revoke all on function lms_first_class_check(uuid, timestamptz, boolean) from public, anon, authenticated;
revoke all on function lms_lessons_first_class_recheck() from public, anon, authenticated;

-- 운영자 일정안 표(schedule_plan_board)의 첫 수업 시각도 수업 종류 구분 없이 (H26(153)). 열은 그대로.
create or replace view schedule_plan_board with (security_invoker = true) as
select p.id as plan_id, p.enrollment_id, p.version, p.state, p.tutor_id, t.name as tutor_name,
       e.student_id, s.name_ko as student_name, s.code as student_code,
       p.slots, p.start_date, p.proposal_sent_at, p.confirmed_at, p.created_at,
       coalesce(
         (select min(l.starts_at) from lessons l where l.enrollment_id = p.enrollment_id and l.voided_at is null and l.state <> 'canceled'),
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
