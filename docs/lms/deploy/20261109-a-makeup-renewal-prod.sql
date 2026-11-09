-- =====================================================================
-- 운영 배포 A안 (대표 2026-11-09): 운영 DB 현재 판 기준, 검증된 보강·재등록 변경만
--  대상: 실제 운영용 프로젝트 mfamixejxydodclhglbc (edgeenglish-lms) — 시험용과 project id 로 구분
--  포함: 저장소 20261109050000(오늘 보강·자동 만료) + 20261109060000(만료 메일 안내 줄·강사에게 묻기 없앰·신청 취소) + 20261109070000(재등록 통보)
--  빼는 것: 20261109040000 수업 관리 2차(운영 DB 에 없음) · 20261109020000 주소 이전(11/15 예정) · 대시보드 전면 개편
--  다른 점(운영 판 기준): lms_notice_mail·lms_makeup_request_core 는 운영 DB 의 지금 본문에서 해당 부분만 바꿈(본문이 예상과 다르면 멈춤)
--   · 안내 종류 목록·메일 트리거는 운영 판(makeup_tutor_removed 없음) + makeup_expired
--  메일 발송 스위치(send_emails)는 건드리지 않음(꺼짐 그대로 → 메일은 support@ 로만)
--  한 트랜잭션: 하나라도 실패하면 아무것도 안 바뀜. 다시 실행해도 같은 결과
-- =====================================================================
begin;

-- 0. 안전장치: 운영 판인지 확인 (수업 관리 2차가 이미 들어가 있거나 본문이 다르면 멈춤)
do $chk$
begin
  if to_regprocedure('admin_lesson_add(uuid,uuid,uuid,uuid,timestamptz,text)') is not null then
    raise exception '수업 관리 2차가 이미 있는 DB입니다. 이 파일은 운영 판 전용입니다.';
  end if;
  if md5(pg_get_functiondef('lms_notice_mail(uuid)'::regprocedure)) not in ('add01762f908ffc936f15815c8e1ed99')
     and position('makeup_expired' in pg_get_functiondef('lms_notice_mail(uuid)'::regprocedure)) = 0 then
    raise exception 'lms_notice_mail 본문이 확인한 운영 판과 다릅니다. 멈춥니다.';
  end if;
end $chk$;

-- 1. 보강 가능한 날짜: 오늘부터 (20261109050000 그대로)
create or replace function lms_makeup_options(p_lesson uuid, p_item uuid, p_comp uuid default null)
returns table (section text, starts_at timestamptz, ends_at timestamptz)
language plpgsql stable security definer set search_path = public as $$
declare
  s record;
  e enrollments;
  v_leave boolean;
  v_back date;
  v_until date;
  v_today date := (now() at time zone 'Asia/Seoul')::date;
begin
  if p_comp is not null then
    select * into s from lms_comp_source(p_comp);
    select * into e from enrollments where id = s.enrollment_id;
    v_leave := false;
    v_back := v_today;
    v_until := s.use_until;
  else
    select * into s from lms_makeup_source(p_lesson, p_item);
    select * into e from enrollments where id = s.enrollment_id;
    v_leave := s.tutor_leave;
    select (o.ends_at at time zone 'Asia/Seoul')::date into v_back
    from leave_items li join tutor_time_off o on o.id = li.time_off_id
    where (li.lesson_id = p_lesson or li.migrated_item_id = p_item) limit 1;
    v_back := coalesce(v_back, v_today);
    v_until := e.final_end_date;
  end if;

  return query
  with rs as (
    select r.weekday, r.start_time_kst from regular_schedules r
    where r.student_id = s.student_id and r.tutor_id = s.tutor_id and (r.effective_to is null or r.effective_to >= v_today)
  ),
  slots as (
    select 'in_period'::text as sec, ((d::date::timestamp + make_interval(mins => n * 30)) at time zone 'Asia/Seoul') as x
    from generate_series(greatest(v_today, v_back), v_until, interval '1 day') d
    cross join generate_series(0, 47) n
    union all
    select 'after_end', ((d::date + rs.start_time_kst) at time zone 'Asia/Seoul')
    from generate_series(greatest(e.final_end_date + 1, v_back, v_today), greatest(e.final_end_date + 1, v_back, v_today) + 180, interval '1 day') d
    join rs on rs.weekday = extract(dow from d)
    where v_leave
  ),
  free as (
    select y.sec, y.x, y.x + make_interval(mins => e.duration_min) as f from slots y
    where y.x > now()
      and lms_tutor_available(s.tutor_id, y.x)
      and lms_makeup_conflict(s.tutor_id, s.student_id, y.x, y.x + make_interval(mins => e.duration_min), true) is null
      and not exists (select 1 from lessons l where l.student_id = s.student_id and l.state <> 'canceled'
                      and l.starts_at < y.x + make_interval(mins => e.duration_min) and y.x < l.ends_at)
  )
  select z.sec, z.x, z.f from (select f1.*, row_number() over (partition by f1.sec order by f1.x) as n from free f1) z
  where z.sec = 'in_period' or z.n <= 1
  order by z.x;
end $$;
revoke all on function lms_makeup_options(uuid, uuid, uuid) from public, anon, authenticated;

-- 2. 안내 종류: 만료 (운영 판 목록 + makeup_expired)
alter table lesson_notices drop constraint if exists lesson_notices_event_check;
alter table lesson_notices add constraint lesson_notices_event_check check (event in (
  'change', 'makeup_ask', 'makeup_confirmed', 'makeup_voided', 'revert', 'leave_options', 'sub_ask', 'sub_student', 'sub_confirmed',
  'makeup_rescheduled', 'makeup_expired'));

-- 3. 신청 때 '강사에게 묻기' 안내 안 만듦 · 만료 메일 갈래 (운영 DB 지금 본문에서 해당 부분만)
do $m$
declare
  d text;
  a1 text := E'    insert into lesson_notices (makeup_request_id, event, recipient_kind, recipient_id) values (v_id, ''makeup_ask'', ''tutor'', c.tutor_id);\n';
  a2 text := E'  insert into lesson_notices (makeup_request_id, event, recipient_kind, recipient_id) values (v_id, ''makeup_ask'', ''tutor'', s.tutor_id);\n';
  anchor text := E'  select * into n from lesson_notices where id = p_notice;\n  if not found then return; end if;\n';
  br text;
begin
  d := pg_get_functiondef('lms_makeup_request_core(uuid,uuid,jsonb,timestamptz,text,uuid,uuid)'::regprocedure);
  if position('makeup_ask' in d) > 0 then
    if position(a1 in d) = 0 or position(a2 in d) = 0 then raise exception 'core 본문이 예상과 다름'; end if;
    execute replace(replace(d, a1, ''), a2, '');
  end if;

  br := $b$
  -- 보강 신청 자동 만료 → 수강생 메일 1통 (대표 11/9 문구)
  if n.event = 'makeup_expired' then
    select * into r from makeup_requests where id = n.makeup_request_id;
    if not found then return; end if;
    select * into st from students where id = r.student_id;
    v_comp := r.compensation_id is not null;
    intended_email := lms_notice_recipient_email('student', r.student_id);
    to_email := case when v_live then intended_email else 'support@edgeenglish.kr' end;
    if not v_live then v_test := '[시험 · ' || st.code || '] '; end if;
    subject := v_test || '[엣지영어] ' || case when v_comp then '보상수업' else '보강' end || ' 신청이 만료되었습니다';
    v_paras := array[
      st.name_ko || '님, 신청하신 ' || case when v_comp then '보상수업' else '보강' end || ' 시간이 강사님 확정 전에 지나 신청이 만료되었습니다.',
      case when v_comp then '보상수업을' else '보강 수업을' end || ' 받을 권리는 그대로 유지됩니다. 아래 버튼을 눌러 새로운 시간을 선택해 주세요.'];
    v_btn := case when v_comp then '보상수업' else '보강' end || ' 날짜 다시 고르기';
    v_url := v_url || '/student?makeup=' || coalesce(r.compensation_id, r.source_lesson_id, r.migrated_item_id);
    v_foot := '문의: 카카오톡 채널 엣지영어';
    body := array_to_string(v_paras, E'\n\n') || E'\n\n' || v_btn || ': ' || v_url || E'\n' || v_foot
            || case when v_live then '' else E'\n\n(시험 발송 · 원래 받는 사람: ' || coalesce(intended_email, '없음') || ')' end;
    html := '<div style="font-family:sans-serif;font-size:15px;line-height:1.6;color:#1d1b2a;max-width:480px">'
            || case when v_live then '' else '<p style="background:#fff4d6;color:#5c3b00;border-radius:8px;padding:8px 10px;font-size:13px;font-weight:600">시험 발송 · 원래 받는 사람: ' || lms_html(coalesce(intended_email, '없음')) || '</p>' end
            || '<p style="font-weight:700">' || lms_html(v_paras[1]) || '</p>'
            || '<p>' || lms_html(v_paras[2]) || '</p>'
            || '<p><a href="' || lms_html(v_url) || '" style="display:inline-block;background:#5b3df0;color:#fff;border-radius:10px;padding:11px 18px;font-weight:700;text-decoration:none">' || lms_html(v_btn) || '</a></p>'
            || '<p style="font-size:12.5px;color:#55526a;border-top:1px solid #e6e3ef;padding-top:10px">' || lms_html(v_foot) || '</p></div>';
    return next;
    return;
  end if;
$b$;
  d := pg_get_functiondef('lms_notice_mail(uuid)'::regprocedure);
  if position('makeup_expired' in d) = 0 then
    if position(anchor in d) = 0 then raise exception 'lms_notice_mail 본문이 예상과 다름'; end if;
    execute replace(d, anchor, anchor || br);
  end if;
end $m$;
revoke all on function lms_makeup_request_core(uuid, uuid, jsonb, timestamptz, text, uuid, uuid) from public, anon, authenticated;
revoke all on function lms_notice_mail(uuid) from public, anon, authenticated;

create or replace function lesson_notices_email() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.event in ('makeup_confirmed', 'makeup_rescheduled', 'change', 'makeup_expired') then
    perform lms_mail_enqueue_notice(new.id);
  end if;
  return null;
end $$;
revoke all on function lesson_notices_email() from public, anon, authenticated;

-- 이미 있는 미처리 '강사에게 묻기' 안내 → 필요 없음 (배포 전 확인: 운영 0건)
update lesson_notices set status = 'not_needed' where event = 'makeup_ask' and status = 'pending';

-- 4. 자동 만료 · 학생 신청 취소 · 학생 화면 (20261109060000 그대로)
create or replace function lms_makeup_expire_run(p_now timestamptz default now()) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  x record;
  v_n integer := 0;
  v_mail integer := 0;
  v_k integer;
begin
  perform set_config('app.actor_via', 'lms_makeup_expire_run', true);
  for x in
    update makeup_requests r set status = 'expired', decided_at = p_now
    where r.status in ('requested', 'countered')
      and exists (select 1 from makeup_candidates c where c.request_id = r.id and c.proposed_by = 'student')
      and not exists (select 1 from makeup_candidates c where c.request_id = r.id and c.proposed_by = 'student' and c.starts_at > p_now)
    returning r.id, r.student_id
  loop
    v_n := v_n + 1;
    update lesson_notices set status = 'not_needed' where makeup_request_id = x.id and status = 'pending';
    -- 학생 메일 1통: 안내 줄이 생기면 트리거가 메일 큐에 (신청당 1줄 — 다시 실행해도 한 번만)
    insert into lesson_notices (makeup_request_id, event, recipient_kind, recipient_id, status)
    values (x.id, 'makeup_expired', 'student', x.student_id, 'not_needed')
    on conflict do nothing;
    get diagnostics v_k = row_count;
    v_mail := v_mail + v_k;
  end loop;
  return jsonb_build_object('expired', v_n, 'mailed', v_mail);
end $$;
revoke all on function lms_makeup_expire_run(timestamptz) from public, anon, authenticated;

create or replace function student_makeup_withdraw(p_student uuid, p_request uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_student uuid := lms_screen_student(p_student);
  r makeup_requests;
begin
  select * into r from makeup_requests where id = p_request for update;
  if not found or r.student_id <> v_student then raise exception '본인 신청만 취소할 수 있습니다.' using errcode = '42501'; end if;
  if r.status = 'withdrawn' then return jsonb_build_object('makeup_request_id', r.id, 'repeated', true); end if;
  if r.status not in ('requested', 'countered') then raise exception '이미 확정됐거나 끝난 신청이에요.'; end if;
  perform set_config('app.actor_id', coalesce(auth.uid()::text, ''), true);
  perform set_config('app.actor_via', case when is_admin() then 'student_makeup_withdraw(운영자 대신)' else 'student_makeup_withdraw' end, true);
  update makeup_requests set status = 'withdrawn', decided_at = now(), decided_by = auth.uid() where id = r.id;
  update lesson_notices set status = 'not_needed' where makeup_request_id = r.id and status = 'pending';
  return jsonb_build_object('makeup_request_id', r.id, 'repeated', false);
end $$;
revoke all on function student_makeup_withdraw(uuid, uuid) from public, anon;
grant execute on function student_makeup_withdraw(uuid, uuid) to authenticated;

-- 학생 화면: 운영 DB 지금 본문에서 신청 상태 목록만 바꿈 (실제 적용과 같음)
do $s$
declare d text; o text := $q$r.status in ('requested', 'countered', 'confirmed')$q$;
begin
  d := pg_get_functiondef('student_screen(uuid)'::regprocedure);
  if position('''withdrawn''' in d) = 0 then
    if position(o in d) = 0 then raise exception 'student_screen 본문이 예상과 다름'; end if;
    execute replace(d, o, $q$r.status in ('requested', 'countered', 'confirmed', 'expired', 'withdrawn')$q$);
  end if;
end $s$;
revoke all on function student_screen(uuid) from public, anon;
grant execute on function student_screen(uuid) to authenticated;

-- 5. 재등록 [강사에게 통보] 한 번으로 끝 (20261109070000 그대로)
do $$
declare c record;
begin
  for c in select conname from pg_constraint where conrelid = 'admin_tasks'::regclass and contype = 'c'
             and pg_get_constraintdef(oid) like '%renewal_tutor_notice%' and pg_get_constraintdef(oid) like '%tutor_acknowledged_at%'
  loop
    execute format('alter table admin_tasks drop constraint %I', c.conname);
  end loop;
  if not exists (select 1 from pg_constraint where conname = 'admin_tasks_renewal_done') then
    alter table admin_tasks add constraint admin_tasks_renewal_done
      check (status <> 'done' or kind <> 'renewal_tutor_notice'
             or (tutor_id is not null and tutor_notified_at is not null and schedule_checked_at is not null));
  end if;
end $$;

create or replace function admin_renewal_notify_tutor(p_task uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  t admin_tasks;
  pl schedule_plans;
begin
  if not is_admin() then raise exception '운영자(추가 인증 완료)만 처리할 수 있습니다.' using errcode = '42501'; end if;
  select * into t from admin_tasks where id = p_task and kind = 'renewal_tutor_notice' for update;
  if not found then raise exception '재등록 업무가 없습니다.'; end if;
  if t.status = 'done' then return jsonb_build_object('task_id', t.id, 'repeated', true); end if;
  if t.status <> 'open' then raise exception '닫힌 업무입니다.'; end if;
  select * into pl from schedule_plans where enrollment_id = t.enrollment_id and state = 'confirmed' order by confirmed_at desc limit 1;
  if not found then raise exception '새 기간 일정을 먼저 확정해 주세요.' using hint = 'schedule_first'; end if;
  if t.tutor_change_planned and pl.tutor_id is not distinct from t.tutor_id then
    raise exception '강사 변경 예정이에요. 새 강사로 일정을 먼저 확정해 주세요.' using hint = 'schedule_first';
  end if;
  perform set_config('app.actor_id', coalesce(me::text, ''), true);
  perform set_config('app.actor_via', 'admin_renewal_notify_tutor', true);
  update admin_tasks set tutor_id = pl.tutor_id, tutor_notified_at = coalesce(tutor_notified_at, now()),
         schedule_checked_at = coalesce(schedule_checked_at, pl.confirmed_at, now()),
         status = 'done', done_at = now(), done_by = me
  where id = t.id;
  return jsonb_build_object('task_id', t.id, 'repeated', false);
end $$;
revoke all on function admin_renewal_notify_tutor(uuid) from public, anon;
grant execute on function admin_renewal_notify_tutor(uuid) to authenticated;

-- 6. 15분 예약 실행: 재촉 → 만료 → 메일 결과
do $c$
begin
  if to_regnamespace('cron') is not null then
    perform cron.schedule('lms-makeup-nudge', '*/15 * * * *', 'select lms_makeup_nudge_run(); select lms_makeup_expire_run(); select lms_mail_run();');
  end if;
end $c$;

commit;
