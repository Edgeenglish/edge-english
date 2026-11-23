-- =====================================================================
-- 장기 수강생 '새 4주 수강 시작 안내' 메일 (학생만, 정책 원본 H26(202) 대표 11/16 확정·문구 '넣어')
--  - 대상: 12주·24주 수강권의 두 번째 4주부터 (enrollment_periods.idx >= 2), 수강권 상태 confirmed·active, 체험용 계정 아님
--  - 보내는 때: 새 4주 시작일 오전 9시(한국 시간)부터 그날 자정 전까지만. 날짜가 지나면 보내지 않음
--  - 내용: 기간(학생 거주지 시간 · 한국 밖이면 시각까지), 변경권 = 그 기간 credits_granted, LMS 버튼
--  - 같은 4주 기간은 한 번만 (dedupe_key 'period_start:기간id'). 같은 수강권에 오늘 첫 수업 안내가 나갔으면 안 보냄
--  - 수업 알림(내 정보) 끄기와 무관. send_emails 꺼져 있으면 support@ 로만(시험 발송)
--  - 예약 실행: 기존 lms-renewal-mail (10분마다) 에 붙임
-- 기존 표·데이터를 지우지 않음. 다시 실행해도 같은 결과
-- =====================================================================

create or replace function lms_period_start_due(p_now timestamptz default now())
returns table (period_id uuid)
language sql stable security definer set search_path = public as $$
  select p.id
  from enrollment_periods p
  join enrollments e on e.id = p.enrollment_id and e.status in ('confirmed', 'active')
  join students s on s.id = e.student_id and not s.is_trial_account
  where p.idx >= 2
    and p.start_date = (p_now at time zone 'Asia/Seoul')::date
    and (p_now at time zone 'Asia/Seoul')::time >= time '09:00'
    and not exists (select 1 from notifications x where x.dedupe_key = 'period_start:' || p.id)
    and not exists (select 1 from notifications f where f.template = 'lesson_notice_first_class'
                    and f.payload ->> 'enrollment_id' = e.id::text and f.created_at > p_now - interval '24 hours')
$$;
revoke all on function lms_period_start_due(timestamptz) from public, anon, authenticated;

create or replace function lms_period_start_mail(p_period uuid) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_live boolean := coalesce((select x.enabled from feature_flags x where x.key = 'send_emails'), false);
  p enrollment_periods;
  e enrollments;
  st students;
  v_tz text;
  v_intended text;
  v_to text;
  v_from timestamptz;
  v_until timestamptz;
  v_range text;
  v_subject text;
  v_url text := lms_url() || '/student';
  v_btn text := '엣지영어 LMS 열기';
  v_zone_line text := '';
  v_foot text := '문의: 카카오톡 채널 엣지영어';
  v_p1 text;
  v_p2 text;
  v_text text;
  v_html text;
  v_id uuid;
begin
  select * into p from enrollment_periods where id = p_period;
  select * into e from enrollments where id = p.enrollment_id;
  select * into st from students where id = e.student_id;
  v_intended := lms_notice_recipient_email('student', st.id);
  if v_intended is null then return null; end if;
  v_to := case when v_live then v_intended else 'support@edgeenglish.kr' end;
  v_tz := coalesce(nullif(st.timezone, ''), 'Asia/Seoul');
  -- 기간 = 시작일 0:00 ~ 종료일 23:59 (한국 시간) → 학생 거주지 시간. 한국이면 날짜만
  v_from := p.start_date::timestamp at time zone 'Asia/Seoul';
  v_until := ((p.end_date + 1)::timestamp at time zone 'Asia/Seoul') - interval '1 minute';
  if v_tz = 'Asia/Seoul' then
    v_range := lms_mail_ko_date(v_from, v_tz) || ' ~ ' || lms_mail_ko_date(v_until, v_tz);
  else
    v_range := lms_mail_ko_date(v_from, v_tz) || ' ' || lms_mail_ko_clock(v_from, v_tz) || ' ~ '
               || lms_mail_ko_date(v_until, v_tz) || ' ' || lms_mail_ko_clock(v_until, v_tz);
    v_zone_line := '모든 시간은 ' || regexp_replace(lms_mail_ko_zone(v_tz), ' 시간$', '') || ' 시간대 기준이에요.';
  end if;
  v_subject := case when v_live then '' else '[시험 · ' || st.code || '] ' end || '[엣지영어] 새 4주 수강 시작 안내';
  v_p1 := '안녕하세요, ' || st.name_ko || '님! ☺️' || E'\n' || '오늘부터 새 4주 수강이 시작되어 변경권이 새로 채워졌어요.';
  v_p2 := '기간: ' || v_range || E'\n' || '변경권: ' || p.credits_granted || '개';
  v_text := v_p1 || E'\n\n' || v_p2 || E'\n\n' || v_btn || ': ' || v_url || E'\n\n'
            || case when v_zone_line <> '' then v_zone_line || E'\n' else '' end || v_foot
            || case when v_live then '' else E'\n\n(시험 발송 · 원래 받는 사람: ' || v_intended || ')' end;
  v_html := '<div style="font-family:sans-serif;font-size:15px;line-height:1.6;color:#1d1b2a;max-width:480px">'
            || case when v_live then '' else '<p style="background:#fff4d6;color:#5c3b00;border-radius:8px;padding:8px 10px;font-size:13px;font-weight:600">시험 발송 · 원래 받는 사람: ' || lms_html(v_intended) || '</p>' end
            || '<p>' || replace(lms_html(v_p1), E'\n', '<br>') || '</p>'
            || '<p style="font-weight:700">' || replace(lms_html(v_p2), E'\n', '<br>') || '</p>'
            || '<p><a href="' || lms_html(v_url) || '" style="display:inline-block;background:#5b3df0;color:#fff;border-radius:10px;padding:11px 18px;font-weight:700;text-decoration:none">' || lms_html(v_btn) || '</a></p>'
            || '<p style="font-size:12.5px;color:#55526a;border-top:1px solid #e6e3ef;padding-top:10px">'
            || case when v_zone_line <> '' then lms_html(v_zone_line) || '<br>' else '' end || lms_html(v_foot) || '</p></div>';
  insert into notifications (recipient_kind, recipient_id, email, locale, template, payload, dedupe_key)
  values ('student', st.id, v_to, 'ko', 'period_start',
          jsonb_build_object('intended_email', v_intended, 'subject', v_subject, 'html', v_html, 'text', v_text,
                             'enrollment_id', e.id, 'period_id', p.id, 'period_idx', p.idx, 'credits', p.credits_granted),
          'period_start:' || p.id)
  on conflict (dedupe_key) do nothing
  returning id into v_id;
  if v_id is not null then perform lms_mail_dispatch(v_id); end if;
  return v_id;
end $$;
revoke all on function lms_period_start_mail(uuid) from public, anon, authenticated;

create or replace function lms_period_start_run(p_now timestamptz default now()) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  x record;
  v_n integer := 0;
begin
  for x in select * from lms_period_start_due(p_now) loop
    if lms_period_start_mail(x.period_id) is not null then v_n := v_n + 1; end if;
  end loop;
  return jsonb_build_object('sent', v_n);
end $$;
revoke all on function lms_period_start_run(timestamptz) from public, anon, authenticated;

-- 기존 예약 실행에 붙임 (10분마다). 재등록 누락 확인(H26(201))이 이미 있는 DB면 그대로 둠
do $$
begin
  if to_regnamespace('cron') is not null then
    perform cron.schedule('lms-renewal-mail', '*/10 * * * *',
      'select lms_renewal_mail_run(); '
      || case when to_regprocedure('lms_renewal_missing_run(timestamptz)') is not null then 'select lms_renewal_missing_run(); ' else '' end
      || 'select lms_period_start_run(); select lms_mail_run();');
  end if;
end $$;
