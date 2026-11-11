-- =====================================================================
-- 학생 재등록 안내 자동 메일 3통 (정책 원본 H26(117) ①, 대표 11/11 결정 1~5 + 마지막 수업 종료 기준)
--   ① 남은 수업 2회  ② 남은 수업 1회  ③ 마지막 수업 종료 뒤 (수강기간 수업이 모두 끝났어요)
--  - 남은 수업 = 대시보드 '종료 임박'과 같은 계산(src/lms/admin/live.ts remainingOf): 지금 이후 예정 수업(정규·보강·보상·이월 모두)
--    + 날짜 미정 보강(취소 수업 보강권·노쇼·장기 휴무·시트 미예약 보강·날짜 안 잡은 보상수업)
--  - ③ = 남은 수업 0 + 끝나지 않은 수업(진행 중 포함) 없음. Class Record 기록 여부와 관계없이 마지막 수업 종료 시각이 지나면 보냄
--  - 문자 [보냄](renewal_notices) 했거나 재등록이 이미 있는 수강권, 체험용 계정, 종료일 +3일 지난 수강권은 안 보냄
--  - 수업 알림(내 정보) 끄기와 무관. 같은 수강권·같은 단계는 한 번만(dedupe_key). 뒤 단계 메일이 이미 나갔으면 앞 단계는 안 보냄
--  - 기존 자동 메일 방식 그대로: notifications 대기열 → lms_mail_dispatch → lms_mail_run. send_emails 꺼져 있으면 support@ 로만(시험 발송)
--  - 시작 조건: feature_flags 'renewal_mail_since' 줄이 있을 때만 (시험 DB 에만 넣음, 운영은 별도 승인)
--  - 문구·가격표는 재등록 안내 문자(src/lms/admin/board.ts renewalMessage · renewal-price.ts)와 같음. 가격이 바뀌면 두 곳을 같이 고칠 것
-- 기존 표·데이터를 지우지 않음. 다시 실행해도 같은 결과
-- =====================================================================

-- 수강 코스 가격표 (renewal-price.ts MONTHLY 와 같은 값). 표에 없는 코스는 null
create or replace function lms_renewal_plans(p_min int, p_weekly int) returns jsonb
language plpgsql immutable as $$
declare
  v_monthly int := (jsonb_build_object(
    '20', jsonb_build_object('2', 178000, '3', 249000, '5', 370000),
    '40', jsonb_build_object('2', 290000, '3', 420000, '5', 695000),
    '50', jsonb_build_object('1', 195000, '2', 355000, '3', 520000)) -> p_min::text ->> p_weekly::text)::int;
  v_three int;
  v_six int;
begin
  if v_monthly is null then return null; end if;
  v_three := round(v_monthly * 3 * 0.95)::int;
  v_six := round(v_monthly * 6 * 0.95)::int - 50000;
  return jsonb_build_object(
    'monthly', v_monthly,
    'three', jsonb_build_object('total', v_three, 'per_month', round(v_three / 3.0)::int, 'save', v_monthly * 3 - v_three),
    'six', jsonb_build_object('total', v_six, 'per_month', round(v_six / 6.0)::int, 'save', v_monthly * 6 - v_six));
end $$;
revoke all on function lms_renewal_plans(int, int) from public, anon, authenticated;

-- 남은 수업 (대시보드 remainingOf 와 같음)
create or replace function lms_renewal_remaining(p_enrollment uuid, p_now timestamptz default now()) returns integer
language sql stable security definer set search_path = public as $$
  select
    (select count(*) from lessons l
      where l.enrollment_id = p_enrollment and l.voided_at is null and l.state = 'scheduled' and l.starts_at > p_now)::int
    + (select count(*) from lessons l
        where l.enrollment_id = p_enrollment and l.voided_at is null and l.class_status is not null
          and (l.state = 'canceled' or l.class_status = 'Tutor no-show')
          and (lms_grants_makeup(l.class_status) or l.class_status = 'Tutor long-term leave')
          and not exists (select 1 from lessons m where m.makeup_of = l.id and m.state <> 'canceled'))::int
    + (select count(*) from migrated_items m where m.enrollment_id = p_enrollment and m.kind = 'makeup_open')::int
    + (select count(*) from compensations c where c.enrollment_id = p_enrollment and c.status = 'available')::int
$$;
revoke all on function lms_renewal_remaining(uuid, timestamptz) from public, anon, authenticated;

-- 메일 1통 만들기 (p_stage: 'two' | 'one' | 'ended')
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
  v_plans jsonb;
  v_first text;
  v_second text;
  v_subject text;
  v_zone_line text := '';
  v_foot text := '문의: 카카오톡 채널 엣지영어';
  v_card text := 'https://tangerineenglish.imweb.me/?idx=11';
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
  -- 종료일 23:59 KST 를 학생 거주지 시간으로 (한국이면 날짜만)
  v_end := ((e.final_end_date + 1)::timestamp at time zone 'Asia/Seoul') - interval '1 minute';
  v_end_text := lms_mail_ko_date(v_end, v_tz) || case when v_tz = 'Asia/Seoul' then '' else ' ' || lms_mail_ko_clock(v_end, v_tz) || '까지' end;
  if v_tz <> 'Asia/Seoul' then
    v_zone_line := '모든 시간은 ' || regexp_replace(lms_mail_ko_zone(v_tz), ' 시간$', '') || ' 시간대 기준이에요.';
  end if;
  v_plans := lms_renewal_plans(e.duration_min, e.weekly_count);
  v_first := '안녕하세요 ' || st.name_ko || '님☺️' || E'\n'
    || case p_stage
         when 'ended' then '엣지영어 수강기간 수업이 모두 끝났어요!'
         else '엣지영어 수업이 ' || (case p_stage when 'one' then 1 else 2 end) || '회 남았어요!' end
    || ' (종료일: ' || v_end_text || ')';
  v_second := case p_stage
    when 'ended' then '종료일까지 재등록 결제를 마치시면' || E'\n' || '지금 수업 요일·시간이 그대로 유지돼요.'
    else '지금 재등록하시면' || E'\n' || '잔여 수업이 있다면 다음 수강 기간으로 이월되고, 기존 수업 요일·시간도 그대로 유지돼요.' end;
  v_subject := case when v_live then '' else '[시험 · ' || st.code || '] ' end
    || '[엣지영어] ' || case p_stage when 'ended' then '수강기간 수업이 모두 끝났어요' when 'one' then '수업이 1회 남았어요' else '수업이 2회 남았어요' end;
  v_paras := array[v_first, v_second];
  -- 가격표에 없는 코스는 코스·가격 부분을 뺌 (가격을 짐작하지 않음)
  if v_plans is not null then
    v_paras := v_paras || array[
      '**현재 수강 코스: ' || e.duration_min || '분 주 ' || e.weekly_count || '회 (월 ' || (e.weekly_count * 4) || '회)**',
      '📍 1개월 (4주): ' || to_char((v_plans ->> 'monthly')::int, 'FM999,999,999') || '원',
      '💜 **3개월 (12주) | 5% 할인**' || E'\n' || to_char((v_plans #>> '{three,total}')::int, 'FM999,999,999') || '원 (월 '
        || to_char((v_plans #>> '{three,per_month}')::int, 'FM999,999,999') || '원)' || E'\n→ '
        || to_char((v_plans #>> '{three,save}')::int, 'FM999,999,999') || '원 절약!',
      '🔥 **6개월 (24주) | 최대 혜택**' || E'\n' || to_char((v_plans #>> '{six,total}')::int, 'FM999,999,999') || '원 (월 약 '
        || to_char((v_plans #>> '{six,per_month}')::int, 'FM999,999,999') || '원)' || E'\n→ '
        || to_char((v_plans #>> '{six,save}')::int, 'FM999,999,999') || '원 절약 + Ebook 패키지 무료!'];
  end if;
  v_paras := v_paras || array[
    '💳 결제 안내' || E'\n' || '계좌이체' || E'\n' || '카카오뱅크 3333-27-7626253' || E'\n' || '이진솔(탠저린 영어)' || E'\n\n' || '카드결제' || E'\n' || v_card,
    '문의사항 있으시면 편하게 답장 주세요! ☺️'];
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

-- 지금 보낼 재등록 안내 메일 (대시보드 '종료 임박' 카드와 같은 대상)
create or replace function lms_renewal_mail_due(p_now timestamptz default now())
returns table (enrollment_id uuid, stage text, lessons_left int)
language sql stable security definer set search_path = public as $$
  select c.id, case when c.n = 0 then 'ended' when c.n = 1 then 'one' else 'two' end, c.n
  from (
    select e.id, lms_renewal_remaining(e.id, p_now) as n
    from enrollments e
    join students s on s.id = e.student_id
    where e.status in ('confirmed', 'active') and not s.is_trial_account
      -- 종료일 +3일 뒤에는 안 보냄 (한국 날짜, 대시보드와 같음)
      and ((p_now at time zone 'Asia/Seoul')::date) < e.final_end_date + 3
      -- 문자 [보냄] 했거나 재등록이 이미 있으면 안 보냄
      and not exists (select 1 from renewal_notices rn where rn.enrollment_id = e.id)
      and not exists (select 1 from enrollments n where n.student_id = e.student_id and n.id <> e.id
                      and n.status in ('confirmed', 'active', 'completed') and (n.previous_enrollment_id = e.id or n.start_date > e.start_date))
      and exists (select 1 from lessons l where l.enrollment_id = e.id and l.voided_at is null and l.state <> 'canceled')
  ) c
  where c.n <= 2
    -- ③ 은 끝나지 않은 수업(진행 중 포함)이 하나도 없을 때만. Class Record 기록은 보지 않음
    and (c.n > 0 or not exists (select 1 from lessons l where l.enrollment_id = c.id and l.voided_at is null and l.state = 'scheduled' and l.ends_at > p_now))
    -- 같은 단계는 한 번만, 뒤 단계 메일이 이미 나갔으면 앞 단계는 보내지 않음
    and not exists (select 1 from notifications x where x.dedupe_key = 'renewal_mail:' || c.id || ':'
                    || case when c.n = 0 then 'ended' when c.n = 1 then 'one' else 'two' end)
    and not (c.n = 2 and exists (select 1 from notifications x where x.dedupe_key in ('renewal_mail:' || c.id || ':one', 'renewal_mail:' || c.id || ':ended')))
    and not (c.n = 1 and exists (select 1 from notifications x where x.dedupe_key = 'renewal_mail:' || c.id || ':ended'))
$$;
revoke all on function lms_renewal_mail_due(timestamptz) from public, anon, authenticated;

create or replace function lms_renewal_mail_run(p_now timestamptz default now()) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  x record;
  v_n integer := 0;
begin
  if not exists (select 1 from feature_flags f where f.key = 'renewal_mail_since') then return jsonb_build_object('sent', 0); end if;
  for x in select * from lms_renewal_mail_due(p_now) loop
    if lms_renewal_mail(x.enrollment_id, x.stage, x.lessons_left) is not null then v_n := v_n + 1; end if;
  end loop;
  return jsonb_build_object('sent', v_n);
end $$;
revoke all on function lms_renewal_mail_run(timestamptz) from public, anon, authenticated;

-- 10분마다 (pg_cron 이 있는 Supabase 에서만). 메일 대기열 보내기도 같이
do $$
begin
  if to_regnamespace('cron') is not null then
    perform cron.schedule('lms-renewal-mail', '*/10 * * * *', 'select lms_renewal_mail_run(); select lms_mail_run();');
  end if;
end $$;
