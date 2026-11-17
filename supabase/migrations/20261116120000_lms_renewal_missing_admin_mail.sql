-- =====================================================================
-- 재등록 누락 확인 메일 (운영진 support@ 만, 대표 11/16 결정 · 2번 설계)
--  - 대상: 마지막 수강권(수강 종료 처리 안 한 것)의 종료일 뒤 '첫 정규 수업'에 다음 수강권이 없는 학생
--    (종료일이 아직 안 지났어도 첫 정규 수업 날짜가 종료일 뒤면 대상)
--  - 그 첫 정규 수업 24시간 전·12시간 전 2통. 12시간 안에 처음 잡히면 12시간 전 1통만
--  - 안 보냄: 체험용 계정 · 수강 종료 처리(completed) · 그 시각에 이미 예정 수업 있음 · 첫 정규 수업이 지남
--  - 학생·강사에게는 안 보냄. 같은 수강권·같은 단계는 한 번만 (dedupe_key)
--  - 예약 실행: 기존 lms-renewal-mail (10분마다) 에 붙임
-- =====================================================================

create or replace function lms_renewal_missing_due(p_now timestamptz default now())
returns table (enrollment_id uuid, student_id uuid, tutor_id uuid, starts_at timestamptz, duration_min int, stage text)
language sql stable security definer set search_path = public as $$
  with last_e as (
    select distinct on (e.student_id) e.*
    from enrollments e
    where e.status in ('confirmed', 'active', 'completed')
    order by e.student_id, e.final_end_date desc, e.start_date desc
  ), first_slot as (
    select distinct on (le.id) le.id as enrollment_id, le.student_id, r.tutor_id, r.duration_min::int as duration_min,
           ((d.d + r.start_time_kst) at time zone 'Asia/Seoul') as starts_at
    from last_e le
    join students s on s.id = le.student_id and not s.is_trial_account
    cross join lateral generate_series(le.final_end_date + 1, le.final_end_date + 14, interval '1 day') as g(x)
    cross join lateral (select g.x::date as d) d
    join regular_schedules r on r.student_id = le.student_id
      and r.weekday = extract(dow from d.d)::int
      and d.d >= r.effective_from and (r.effective_to is null or d.d <= r.effective_to)
    where le.status <> 'completed'
    order by le.id, starts_at
  )
  select f.enrollment_id, f.student_id, f.tutor_id, f.starts_at, f.duration_min,
         case when f.starts_at - p_now <= interval '12 hours' then 'h12' else 'h24' end
  from first_slot f
  where f.starts_at > p_now and f.starts_at - p_now <= interval '24 hours'
    and not exists (select 1 from lessons l where l.student_id = f.student_id and l.starts_at = f.starts_at
                    and l.voided_at is null and l.state <> 'canceled')
    and not exists (select 1 from notifications x where x.dedupe_key = 'renewal_missing:' || f.enrollment_id || ':'
                    || case when f.starts_at - p_now <= interval '12 hours' then 'h12' else 'h24' end)
$$;
revoke all on function lms_renewal_missing_due(timestamptz) from public, anon, authenticated;

create or replace function lms_renewal_missing_mail(p_enrollment uuid, p_tutor uuid, p_starts timestamptz, p_min int, p_stage text)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  v_live boolean := coalesce((select x.enabled from feature_flags x where x.key = 'send_emails'), false);
  e enrollments;
  st students;
  v_tutor text;
  v_end text;
  v_subject text;
  v_text text;
  v_html text;
  v_id uuid;
begin
  select * into e from enrollments where id = p_enrollment;
  select * into st from students where id = e.student_id;
  select t.name into v_tutor from tutors t where t.id = p_tutor;
  v_end := to_char(e.final_end_date, 'FMMM/FMDD') || '('
    || (array['일','월','화','수','목','금','토'])[extract(dow from e.final_end_date)::int + 1] || ')';
  v_subject := case when v_live then '' else '[시험 · ' || st.code || '] ' end
    || '[재등록 누락 확인' || case when p_stage = 'h12' then ' · 2번째' else '' end || '] '
    || st.name_ko || ' (' || st.code || ') · ' || lms_kst_short(p_starts) || ' 한국 시간 정규 수업';
  v_text := '학생: ' || st.name_ko || ' (' || st.code || ')' || E'\n'
    || '수강 종료일: ' || v_end || E'\n'
    || '다음 수강권: 없음' || E'\n'
    || '다음 정규 수업: ' || lms_kst_short(p_starts) || ' 한국 시간 · ' || p_min || '분' || coalesce(' · ' || v_tutor, '') || E'\n'
    || '재등록 등록 또는 수강 종료 처리를 해 주세요.';
  v_html := '<div style="font-family:sans-serif;font-size:15px;line-height:1.6;color:#1d1b2a;max-width:480px"><p>'
    || replace(lms_html(v_text), E'\n', '<br>') || '</p></div>';
  insert into notifications (recipient_kind, recipient_id, email, locale, template, payload, dedupe_key)
  values ('admin', null, 'support@edgeenglish.kr', 'ko', 'renewal_missing_admin',
          jsonb_build_object('intended_email', 'support@edgeenglish.kr', 'subject', v_subject, 'html', v_html, 'text', v_text,
                             'enrollment_id', e.id, 'stage', p_stage, 'class_starts_at', p_starts),
          'renewal_missing:' || e.id || ':' || p_stage)
  on conflict (dedupe_key) do nothing
  returning id into v_id;
  if v_id is not null then perform lms_mail_dispatch(v_id); end if;
  return v_id;
end $$;
revoke all on function lms_renewal_missing_mail(uuid, uuid, timestamptz, int, text) from public, anon, authenticated;

create or replace function lms_renewal_missing_run(p_now timestamptz default now()) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  x record;
  v_n integer := 0;
begin
  for x in select * from lms_renewal_missing_due(p_now) loop
    if lms_renewal_missing_mail(x.enrollment_id, x.tutor_id, x.starts_at, x.duration_min, x.stage) is not null then v_n := v_n + 1; end if;
  end loop;
  return jsonb_build_object('sent', v_n);
end $$;
revoke all on function lms_renewal_missing_run(timestamptz) from public, anon, authenticated;

-- 기존 예약 실행에 붙임 (10분마다: 재등록 안내 → 재등록 누락 확인 → 메일 대기열 보내기)
do $$
begin
  if to_regnamespace('cron') is not null then
    perform cron.schedule('lms-renewal-mail', '*/10 * * * *',
      'select lms_renewal_mail_run(); select lms_renewal_missing_run(); select lms_mail_run();');
  end if;
end $$;
