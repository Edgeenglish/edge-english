-- =====================================================================
-- 오늘 보강 허용 · 보강 신청 자동 만료 (대표 2026-11-09 결정, 시험 DB 먼저 — 정책 원본 기록은 대표 승인 뒤)
--  1) lms_makeup_options: 오늘 시간도 보강 가능한 날짜에 (지금 이후만, 강사 일정·충돌·종료일 검사 그대로) — 일반 보강·보상수업
--     (20261108020000 그대로 + v_today + 1 → v_today. 학생 신청 검사·강사 확정이 같은 목록·같은 검사를 씀)
--     6시간 미만 시간 경고는 학생 화면에서만 (신청은 막지 않음)
--  2) lms_makeup_expire_run: 학생이 고른 시간이 모두 지나도록 확정되지 않은 신청(requested·countered)만 'expired'
--     · 일부만 지났으면 그대로 · '신청 후 n시간' 만료 없음
--     · 보강권·보상권은 그대로(확정 수업·다른 기록 안 건드림) → 학생 할 일에 다시, 강사 To-do 에서 빠짐
--     · 안 보낸 '보강 강사에게 묻기' 안내는 '필요 없음' · 운영진 알림 없음
--     · 학생 만료 메일 1회 (notifications dedupe 'makeup_expired:신청') — send_emails 꺼져 있으면 운영진 메일로만('[시험 · 학생 번호]')
--     · 15분 예약 실행(lms-makeup-nudge)에 추가. 다시 실행해도 같은 결과
--  3) student_screen: 신청 목록에 'expired'(만료)도 (20261105020000 그대로 + 상태 1개)
-- 표 구조 변경 없음 (makeup_requests.status 'expired' 는 원래 허용값)
-- =====================================================================

-- 1. 보강 가능한 날짜: 오늘부터 ---------------------------------------------------
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

-- 2. 자동 만료 ---------------------------------------------------------------------
create or replace function lms_makeup_expire_run(p_now timestamptz default now()) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  x record;
  st students;
  v_live boolean := coalesce((select f.enabled from feature_flags f where f.key = 'send_emails'), false);
  v_intended text;
  v_to text;
  v_subject text;
  v_paras text[];
  v_url text;
  v_btn text;
  v_foot text := '문의: 카카오톡 채널 엣지영어';
  v_body text;
  v_html text;
  v_id uuid;
  v_n integer := 0;
  v_mail integer := 0;
begin
  perform set_config('app.actor_via', 'lms_makeup_expire_run', true);
  for x in
    update makeup_requests r set status = 'expired', decided_at = p_now
    where r.status in ('requested', 'countered')
      and exists (select 1 from makeup_candidates c where c.request_id = r.id and c.proposed_by = 'student')
      and not exists (select 1 from makeup_candidates c where c.request_id = r.id and c.proposed_by = 'student' and c.starts_at > p_now)
    returning r.id, r.student_id, r.source_lesson_id, r.migrated_item_id, r.compensation_id
  loop
    v_n := v_n + 1;
    update lesson_notices set status = 'not_needed' where makeup_request_id = x.id and status = 'pending';

    select * into st from students where id = x.student_id;
    v_intended := lms_notice_recipient_email('student', x.student_id);
    if v_intended is null then continue; end if;   -- 주소 없음: 학생 화면 '만료'만
    v_to := case when v_live then v_intended else 'support@edgeenglish.kr' end;
    v_subject := case when v_live then '' else '[시험 · ' || st.code || '] ' end
                 || '[엣지영어] ' || case when x.compensation_id is not null then '보상수업' else '보강' end || ' 신청이 만료됐어요';
    v_paras := array[
      '[엣지영어] ' || st.name_ko || '님, ' || case when x.compensation_id is not null then '보상수업' else '보강' end || ' 신청이 만료됐어요.',
      '신청한 시간: ' || (select string_agg(lms_mail_ko_at(c.starts_at, st.timezone), E'\n' order by c.starts_at)
                         from makeup_candidates c where c.request_id = x.id and c.proposed_by = 'student'),
      '강사님 확정 전에 신청한 시간이 지났어요. 아래 버튼에서 다시 신청해 주세요.'];
    v_btn := case when x.compensation_id is not null then '보상수업 날짜 고르기' else '보강 날짜 고르기' end;
    v_url := lms_url() || '/student?makeup=' || coalesce(x.compensation_id, x.source_lesson_id, x.migrated_item_id);
    v_body := lms_strip_bold(array_to_string(v_paras, E'\n\n')) || E'\n\n' || v_btn || ': ' || v_url || E'\n' || v_foot
              || case when v_live then '' else E'\n\n(시험 발송 · 원래 받는 사람: ' || v_intended || ')' end;
    v_html := '<div style="font-family:sans-serif;font-size:15px;line-height:1.6;color:#1d1b2a;max-width:480px">'
              || case when v_live then '' else '<p style="background:#fff4d6;color:#5c3b00;border-radius:8px;padding:8px 10px;font-size:13px;font-weight:600">시험 발송 · 원래 받는 사람: ' || lms_html(v_intended) || '</p>' end
              || '<p style="font-weight:700">' || lms_bold_html(v_paras[1]) || '</p>'
              || '<p>' || replace(lms_bold_html(v_paras[2]), E'\n', '<br>') || '</p>'
              || '<p>' || lms_bold_html(v_paras[3]) || '</p>'
              || '<p><a href="' || lms_html(v_url) || '" style="display:inline-block;background:#5b3df0;color:#fff;border-radius:10px;padding:11px 18px;font-weight:700;text-decoration:none">' || lms_html(v_btn) || '</a></p>'
              || '<p style="font-size:12.5px;color:#55526a;border-top:1px solid #e6e3ef;padding-top:10px">' || lms_html(v_foot) || '</p></div>';
    v_id := null;
    insert into notifications (recipient_kind, recipient_id, email, locale, template, payload, dedupe_key)
    values ('student', x.student_id, v_to, 'ko', 'lesson_notice_makeup_expired',
            jsonb_build_object('makeup_request_id', x.id, 'intended_email', v_intended, 'subject', v_subject, 'html', v_html, 'text', v_body),
            'makeup_expired:' || x.id)
    on conflict (dedupe_key) do nothing
    returning id into v_id;
    if v_id is not null then perform lms_mail_dispatch(v_id); v_mail := v_mail + 1; end if;
  end loop;
  return jsonb_build_object('expired', v_n, 'mailed', v_mail);
end $$;
revoke all on function lms_makeup_expire_run(timestamptz) from public, anon, authenticated;

-- 15분 예약 실행: 재촉 → 만료 → 메일 결과 (같은 이름이면 덮어씀, pg_cron 이 있는 곳에서만)
do $$
begin
  if to_regnamespace('cron') is not null then
    perform cron.schedule('lms-makeup-nudge', '*/15 * * * *', 'select lms_makeup_nudge_run(); select lms_makeup_expire_run(); select lms_mail_run();');
  end if;
end $$;

-- 3. 학생 화면: 만료된 신청도 신청 내역에 -------------------------------------------
create or replace function student_screen(p_student uuid)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_student uuid := lms_screen_student(p_student);
  st students;
  e enrollments;
  v_period enrollment_periods;
  v_open uuid[];
  v_today date := (now() at time zone 'Asia/Seoul')::date;
begin
  select * into st from students where id = v_student;
  select * into e from enrollments where id = lms_student_enrollment(v_student);
  select * into v_period from enrollment_periods p
  where p.enrollment_id = e.id and p.start_date <= v_today order by p.idx desc limit 1;
  v_open := array(select x.id from enrollments x where x.student_id = v_student and (x.status in ('active', 'confirmed') or x.id = e.id));
  return jsonb_build_object(
    'student', jsonb_build_object('id', st.id, 'code', st.code, 'name_ko', st.name_ko, 'timezone', st.timezone),
    'enrollment', case when e.id is null then null else jsonb_build_object(
      'id', e.id, 'weeks', e.weeks, 'legacy_label', e.legacy_label, 'weekly_count', e.weekly_count, 'duration_min', e.duration_min,
      'start_date', e.start_date, 'final_end_date', e.final_end_date, 'status', e.status,
      'next_regular_from', lms_next_regular_from(e.id),
      'lessons_total', coalesce((select c.sheet_total from import_checks c where c.enrollment_id = e.id), e.lessons_purchased + e.lessons_carried_in),
      'credits_left', case when v_period.id is null then 0 else credit_balance(v_period.id) end,
      'credits_granted', coalesce(v_period.credits_granted, 0),
      'confirmed_on', (select min((p.confirmed_at at time zone 'Asia/Seoul')::date) from payments p where p.enrollment_id = e.id and p.confirmed_at is not null),
      'renewal_paid', exists (select 1 from enrollments n where n.previous_enrollment_id = e.id and n.status in ('confirmed', 'active'))) end,
    'lessons', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', l.id, 'kind', l.kind, 'starts_at', l.starts_at, 'ends_at', l.ends_at, 'state', l.state, 'class_status', l.class_status,
        'tutor', t.name, 'meet_url', t.meet_url, 'makeup_of', l.makeup_of, 'leave_postponed', lms_is_leave_postponed(l.id),
        'substitute', l.original_tutor_id is not null,
        'leave_open', exists (select 1 from leave_items li where li.lesson_id = l.id and li.lesson_gone_at is null
                              and (li.choice = 'undecided' or (li.choice = 'substitute' and li.sub_stage <> 'confirmed')))) order by l.starts_at)
      from lessons l join tutors t on t.id = l.tutor_id
      where l.enrollment_id = any(v_open) and l.voided_at is null), '[]'::jsonb),
    -- 보강을 받을 수 있는데 아직 날짜가 없는 것 (취소한 수업 · 시트에서 넘어온 날짜 미정 보강 · 강사 노쇼 무료 보상수업)
    -- QA-13 (4500): 보강 수업이 잡힌 뒤 취소(voided 아님)된 원래 수업은 다시 권리가 되지 않음 — 권리는 그 보강 수업의 결과를 따름
    'makeup_rights', coalesce((
      select jsonb_agg(r order by r ->> 'original_at', r ->> 'comp_id' nulls first) from (
        select jsonb_build_object('lesson_id', l.id, 'item_id', null, 'original_at', l.starts_at,
                 'tutor_leave', l.class_status = 'Tutor long-term leave') as r
        from lessons l
        where l.enrollment_id = any(v_open) and l.voided_at is null and (lms_grants_makeup(l.class_status) or l.class_status = 'Tutor long-term leave')
          and not exists (select 1 from lessons x where x.makeup_of = l.id and x.voided_at is null)
        union all
        select jsonb_build_object('lesson_id', null, 'item_id', m.id,
                 'original_at', coalesce((select li.starts_at from leave_items li where li.migrated_item_id = m.id order by li.starts_at limit 1),
                                         m.original_date::timestamp at time zone 'Asia/Seoul'),
                 'time_known', exists (select 1 from leave_items li where li.migrated_item_id = m.id),
                 'tutor_leave', coalesce(m.tutor_leave, false))
        from migrated_items m where m.enrollment_id = any(v_open) and m.kind = 'makeup_open'
          and not exists (select 1 from leave_items li where li.migrated_item_id = m.id and li.lesson_gone_at is null
                          and li.choice in ('undecided', 'substitute'))
        union all
        select jsonb_build_object('lesson_id', null, 'item_id', null, 'comp_id', c.id, 'original_at', src.starts_at,
                 'tutor', t.name, 'use_until', lms_comp_use_until(c.enrollment_id), 'tutor_leave', false)
        from compensations c
        join lessons src on src.id = c.source_lesson_id
        join tutors t on t.id = src.tutor_id
        where c.student_id = v_student and c.status = 'available' and lms_comp_use_until(c.enrollment_id) >= v_today) q), '[]'::jsonb),
    'leave_pending', coalesce((
      select jsonb_agg(jsonb_build_object('id', li.id, 'starts_at', li.starts_at, 'ends_at', li.ends_at) order by li.starts_at)
      from leave_items li
      where li.student_id = v_student and li.lesson_id is null and li.lesson_gone_at is null and li.starts_at > now()
        and (li.choice = 'undecided' or (li.choice = 'substitute' and li.sub_stage <> 'confirmed'))), '[]'::jsonb),
    -- 신청 내역 (4100 + 4500: 확정 수업 상태 · 강사가 모든 후보에 불가 답)
    'makeup_requests', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', r.id, 'status', r.status, 'lesson_id', r.source_lesson_id, 'item_id', r.migrated_item_id, 'comp_id', r.compensation_id,
        'requested_at', r.requested_at, 'confirmed_lesson_id', r.confirmed_lesson_id, 'tutor_answered_at', r.tutor_answered_at,
        'confirmed_state', cl.state,
        'tutor_declined_all', r.tutor_answered_at is not null
          and not exists (select 1 from makeup_candidates c where c.request_id = r.id and c.proposed_by = 'student' and c.tutor_answer = 'yes'),
        'original_at', coalesce(src.starts_at, (select m.original_date::timestamp at time zone 'Asia/Seoul' from migrated_items m where m.id = r.migrated_item_id)),
        'original_time_known', src.id is not null,
        'original_tutor', srct.name,
        'tutor', rt.name,
        'confirmed_at', cl.starts_at,
        'tutor_leave', coalesce(src.class_status = 'Tutor long-term leave',
                                (select m.tutor_leave from migrated_items m where m.id = r.migrated_item_id), false),
        'candidates', (select coalesce(jsonb_agg(c.starts_at order by c.starts_at), '[]'::jsonb) from makeup_candidates c where c.request_id = r.id and c.proposed_by = 'student'))
        order by r.requested_at desc)
      from makeup_requests r
      left join lessons src on src.id = r.source_lesson_id
      left join tutors srct on srct.id = src.tutor_id
      left join tutors rt on rt.id = r.tutor_id
      left join lessons cl on cl.id = r.confirmed_lesson_id
      where r.student_id = v_student and r.status in ('requested', 'countered', 'confirmed', 'expired')
        and r.requested_at > now() - interval '60 days'), '[]'::jsonb),
    'leave', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', li.id, 'starts_at', li.starts_at, 'choice', li.choice, 'stage', li.sub_stage, 'sub_tutor', sub.name, 'sub_meet_url', sub.meet_url,
        'lesson_id', li.lesson_id, 'item_id', li.migrated_item_id,
        'off_from', o.starts_at, 'off_to', o.ends_at) order by li.starts_at)
      from leave_items li
      join tutor_time_off o on o.id = li.time_off_id
      left join tutors sub on sub.id = li.sub_tutor_id
      where li.student_id = v_student and li.starts_at > now() and li.lesson_gone_at is null
        and ((li.choice = 'substitute' and li.sub_stage in ('tutor_ok', 'confirmed')) or li.choice = 'wait')), '[]'::jsonb),
    'credit_period', case when v_period.id is null then null else jsonb_build_object('start', v_period.start_date, 'end', v_period.end_date) end,
    -- R-12 (4520): 모든 기간의 잔여 — 미래 수업 취소 미리 보기는 그 수업 날짜가 속한 기간으로
    'credit_periods', coalesce((
      select jsonb_agg(jsonb_build_object('idx', p.idx, 'start', p.start_date, 'end', p.end_date, 'granted', p.credits_granted, 'left', credit_balance(p.id)) order by p.idx)
      from enrollment_periods p where p.enrollment_id = e.id), '[]'::jsonb),
    'credit_uses', coalesce((
      select jsonb_agg(jsonb_build_object('at', c.created_at, 'reason', c.reason, 'delta', c.delta, 'note', c.note, 'lesson_at', l.starts_at) order by c.created_at)
      from credit_ledger c left join lessons l on l.id = c.lesson_id where c.period_id = v_period.id), '[]'::jsonb),
    'holidays', coalesce((select jsonb_agg(h.day order by h.day) from holidays h
      where h.day between v_today and v_today + 200), '[]'::jsonb),
    'points', coalesce((
      select jsonb_agg(jsonb_build_object('id', g.id, 'on', (g.created_at at time zone 'Asia/Seoul')::date, 'kind', g.kind, 'amount', g.amount, 'note', g.note)
        order by g.created_at)
      from reward_ledger g where g.student_id = v_student), '[]'::jsonb));
end $$;

revoke all on function student_screen(uuid) from public, anon;
grant execute on function student_screen(uuid) to authenticated;
