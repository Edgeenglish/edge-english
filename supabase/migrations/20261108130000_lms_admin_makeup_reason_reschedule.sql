-- =====================================================================
-- 운영진 보강 바로 확정 사유 + 확정된 보강 시간 고치기 (2026-11-08 대표 결정, 시안 2차)
--  1) 운영진이 보강을 확정할 때 사유를 고름(필수) → 운영 기록(admin_makeup_logs, 운영진만 읽음)
--     사유: kakao_agreed 카톡으로 학생·강사와 이미 정함 / student_request 학생 요청 / tutor_request 강사 요청 / other 기타(직접 적기)
--  2) 이미 확정된 보강·보상수업의 시간을 고침(사유 필수) — 변경권·보상권·수업 횟수 그대로
--     사유: admin_mistake 운영진 입력 실수 정정 / student_request / tutor_request / other
--     확인 규칙은 보강 확정과 같음(강사 휴무·다른 수업·열린 시간·종료일·보상 사용 기한). 자기 자신 수업은 겹침에서 뺌
--  3) 시간을 고치면 학생·강사 양쪽에 '보강 시간 변경' 안내(event makeup_rescheduled) → 카톡·WhatsApp 안내 카드 + 자동 메일
--     자동 메일은 기존 발송 설정(feature_flags.send_emails, 숨은참조) 그대로. 아직 안 보낸 예전 확정 안내 카드는 '필요 없음'
--  4) 강사 메일 시각을 12시간 표기로 ('Fri 20 Nov 3:00 PM') — 화면 표기 통일(대표 11/8)
--  5) 메일 함수는 20261108120000(학생 메일 '노쇼' 표현 없음·source_lesson_id) 위에 '보강 시간 변경'을 더함
-- 새 숫자 없음. 다시 실행해도 같은 결과
-- =====================================================================

-- 1. 운영 기록 ---------------------------------------------------------
create table if not exists admin_makeup_logs (
  id uuid primary key default gen_random_uuid(),
  makeup_request_id uuid not null references makeup_requests(id),
  lesson_id uuid references lessons(id),
  student_id uuid not null references students(id),
  action text not null check (action in ('confirm', 'reschedule')),
  reason text not null check (reason in ('kakao_agreed', 'admin_mistake', 'student_request', 'tutor_request', 'other')),
  note text,
  old_starts_at timestamptz,
  new_starts_at timestamptz not null,
  actor uuid,
  created_at timestamptz not null default now(),
  check (reason <> 'other' or nullif(btrim(note), '') is not null)
);
create index if not exists admin_makeup_logs_student on admin_makeup_logs (student_id, created_at desc);
do $$ begin
  if not exists (select 1 from pg_policies where tablename = 'admin_makeup_logs' and policyname = 'admin_read') then
    perform lms_protect('public.admin_makeup_logs'::regclass);
  end if;
end $$;

-- 2. 안내 종류에 '보강 시간 변경' 추가 ----------------------------------
alter table lesson_notices drop constraint if exists lesson_notices_event_check;
alter table lesson_notices add constraint lesson_notices_event_check check (event in (
  'change', 'makeup_ask', 'makeup_confirmed', 'makeup_voided', 'revert', 'leave_options', 'sub_ask', 'sub_student', 'sub_confirmed',
  'makeup_rescheduled'));

-- 3. 겹침 확인에서 특정 수업(시간을 고치는 그 수업)을 뺄 수 있게 -------------
create or replace function lms_makeup_conflict(p_tutor uuid, p_student uuid, p_start timestamptz, p_end timestamptz, p_student_wants boolean, p_ignore uuid)
returns text
language plpgsql stable security definer set search_path = public as $$
declare
  v_break constant interval := interval '10 minutes';      -- POL-OP-21 (policy.ts CONFIRMED.minBreakMin)
  v_b2b_min constant integer := 20;                         -- POL-OP-21 예외 (policy.ts CONFIRMED.backToBackNoBreakDurationMin)
  v_b2b_max constant integer := 2;                          -- POL-OP-21 예외 (policy.ts CONFIRMED.backToBackNoBreakMaxLessons)
  v_new_b2b boolean := p_student_wants and p_end - p_start = make_interval(mins => v_b2b_min);
  v_near uuid[];
  v_chain integer;
begin
  -- 1) 강사 휴무 (열어도 소용없음)
  if exists (select 1 from tutor_time_off o where o.tutor_id = p_tutor and o.kind = 'leave' and o.starts_at < p_end and p_start < o.ends_at) then
    return '강사 휴무';
  end if;
  -- 2) 강사 다른 수업 (휴식 10분 포함, 같은 학생 20분 수업 2개까지 이어 붙이기 예외)
  if exists (select 1 from lessons x where x.tutor_id = p_tutor and x.state <> 'canceled' and x.id is distinct from p_ignore
             and x.starts_at < p_end + v_break and p_start - v_break < x.ends_at
             and (x.starts_at < p_end and p_start < x.ends_at
                  or not (v_new_b2b and x.student_id = p_student and x.ends_at - x.starts_at = make_interval(mins => v_b2b_min)))) then
    return '강사 다른 수업(휴식 10분 포함)';
  end if;
  -- 3) 강사 현지 06:00~22:30 시작만 (POL-OP-02, 4200)
  if not lms_tutor_start_ok(p_tutor, p_start) then
    return '강사 현지 06:00~22:30 밖의 시작 시각';
  end if;
  -- 4) 강사가 연 시간(매주 Availability 또는 Schedule 에서 그날만 열기)이어야 함 (QA-01, 4500). 그날만 막은 시간(block)도 여기
  if not lms_tutor_available(p_tutor, p_start)
     or exists (select 1 from tutor_time_off o where o.tutor_id = p_tutor and o.kind = 'block' and o.starts_at < p_end and p_start < o.ends_at) then
    return '강사가 열어 둔 시간이 아님(Availability·Schedule)';
  end if;
  -- 5) 이어 붙이기 규칙
  select coalesce(array_agg(x.id), '{}') into v_near from lessons x
  where x.tutor_id = p_tutor and x.state <> 'canceled' and x.id is distinct from p_ignore
    and x.starts_at < p_end + v_break and p_start - v_break < x.ends_at;
  if cardinality(v_near) = 0 then return null; end if;
  select 1 + cardinality(v_near) + count(distinct y.id) into v_chain from lessons y
  where y.tutor_id = p_tutor and y.state <> 'canceled' and y.id <> all(v_near) and y.id is distinct from p_ignore
    and not (y.starts_at < p_end + v_break and p_start - v_break < y.ends_at)
    and exists (select 1 from lessons x where x.id = any(v_near)
                and y.starts_at < x.ends_at + v_break and x.starts_at - v_break < y.ends_at);
  if v_chain > v_b2b_max then
    return format('쉬지 않고 이어 붙이는 수업(%s분 %s개까지)', v_b2b_min, v_b2b_max);
  end if;
  return null;
end $$;
revoke all on function lms_makeup_conflict(uuid, uuid, timestamptz, timestamptz, boolean, uuid) from public, anon, authenticated;

-- 예전 5칸 함수는 그대로 쓰는 곳이 많아 6칸 함수로 넘김 (동작 같음)
create or replace function lms_makeup_conflict(p_tutor uuid, p_student uuid, p_start timestamptz, p_end timestamptz, p_student_wants boolean)
returns text
language sql stable security definer set search_path = public as $$
  select lms_makeup_conflict(p_tutor, p_student, p_start, p_end, p_student_wants, null::uuid)
$$;

-- 4. 운영진 보강 확정 (사유 필수) — 예전 2칸 함수는 배포 순서 때문에 그대로 둠 ----------
create or replace function admin_makeup_confirm(p_makeup_request uuid, p_starts_at timestamptz, p_reason text, p_note text default null)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v jsonb;
  r makeup_requests;
begin
  if not is_admin() then raise exception '운영자(추가 인증 완료)만 처리할 수 있습니다.' using errcode = '42501'; end if;
  if p_reason is null or p_reason not in ('kakao_agreed', 'student_request', 'tutor_request', 'other') then
    raise exception '확정 사유를 골라 주세요.';
  end if;
  if p_reason = 'other' and nullif(btrim(p_note), '') is null then raise exception '기타 사유를 적어 주세요.'; end if;
  v := lms_makeup_book(p_makeup_request, p_starts_at, 'admin_makeup_confirm', false);
  if coalesce((v ->> 'repeated')::boolean, false) then return v; end if;
  select * into r from makeup_requests where id = p_makeup_request;
  insert into admin_makeup_logs (makeup_request_id, lesson_id, student_id, action, reason, note, new_starts_at, actor)
  values (r.id, r.confirmed_lesson_id, r.student_id, 'confirm', p_reason, nullif(btrim(p_note), ''), p_starts_at, auth.uid());
  return v;
end $$;
revoke all on function admin_makeup_confirm(uuid, timestamptz, text, text) from public, anon;
grant execute on function admin_makeup_confirm(uuid, timestamptz, text, text) to authenticated;

-- 5. 운영진 바로 확정: 신청이 없을 때 신청 + 확정을 한 번에 (같은 트랜잭션) -------------
create or replace function admin_makeup_confirm_now(p_lesson uuid, p_item uuid, p_comp uuid, p_starts_at timestamptz, p_reason text, p_note text default null)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v jsonb;
begin
  if not is_admin() then raise exception '운영자(추가 인증 완료)만 처리할 수 있습니다.' using errcode = '42501'; end if;
  v := lms_makeup_request_core(p_lesson, p_item, jsonb_build_array(jsonb_build_object('starts_at', p_starts_at)), null, 'admin_on_behalf', auth.uid(), p_comp);
  return admin_makeup_confirm((v ->> 'makeup_request_id')::uuid, p_starts_at, p_reason, p_note);
end $$;
revoke all on function admin_makeup_confirm_now(uuid, uuid, uuid, timestamptz, text, text) from public, anon;
grant execute on function admin_makeup_confirm_now(uuid, uuid, uuid, timestamptz, text, text) to authenticated;

-- 6. 확정된 보강·보상수업 시간 고치기 --------------------------------------
create or replace function admin_makeup_reschedule(p_lesson uuid, p_starts_at timestamptz, p_reason text, p_note text default null)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  l lessons;
  r makeup_requests;
  v_leave boolean;
  v_until date;
  e enrollments;
  v_end timestamptz;
  v_conf text;
  v_enr uuid;
begin
  if not is_admin() then raise exception '운영자(추가 인증 완료)만 처리할 수 있습니다.' using errcode = '42501'; end if;
  if p_reason is null or p_reason not in ('admin_mistake', 'student_request', 'tutor_request', 'other') then
    raise exception '고치는 사유를 골라 주세요.';
  end if;
  if p_reason = 'other' and nullif(btrim(p_note), '') is null then raise exception '기타 사유를 적어 주세요.'; end if;

  select * into l from lessons where id = p_lesson for update;
  if not found then raise exception '수업이 없습니다.'; end if;
  select * into r from makeup_requests where confirmed_lesson_id = l.id and status = 'confirmed' for update;
  if not found then raise exception '운영진·강사가 확정한 보강 수업만 시간을 고칠 수 있어요.'; end if;
  if l.state <> 'scheduled' or l.voided_at is not null then raise exception '예정된 수업만 시간을 고칠 수 있어요.'; end if;
  if l.starts_at <= now() then raise exception '이미 시작한 수업은 시간을 고칠 수 없어요.'; end if;
  if p_starts_at <= now() then raise exception '지난 시간으로는 고칠 수 없어요.'; end if;
  if p_starts_at = l.starts_at then
    return jsonb_build_object('lesson_id', l.id, 'repeated', true);
  end if;
  v_end := p_starts_at + (l.ends_at - l.starts_at);

  -- 기한: 보상수업 = 사용 기한, 보강 = 수강 종료일 (시행 전 강사 휴무 보강은 기한 없음) — lms_makeup_book 과 같음
  if r.compensation_id is not null then
    -- lms_comp_source 는 '이미 날짜를 잡은 보상수업'을 막으므로 사용 기한만 같은 함수로 계산
    v_until := lms_comp_use_until((select enrollment_id from compensations where id = r.compensation_id));
    if p_starts_at >= ((v_until + 1)::timestamp at time zone 'Asia/Seoul') then
      raise exception '보상수업 사용 기한(%) 뒤의 시간입니다.', v_until using hint = 'after_end';
    end if;
    v_enr := lms_comp_lesson_enrollment(r.compensation_id, (p_starts_at at time zone 'Asia/Seoul')::date);
  else
    -- lms_makeup_source 는 '이미 보강이 잡혀 있음'을 막으므로 휴무 여부만 같은 방식으로 직접 봄
    if r.source_lesson_id is not null then
      select coalesce(x.class_status = 'Tutor long-term leave', false) and lms_fault_event(x.id) is null into v_leave
      from lessons x where x.id = r.source_lesson_id;
    else
      select coalesce(it.tutor_leave, false) into v_leave from migrated_items it where it.id = r.migrated_item_id;
    end if;
    select * into e from enrollments where id = l.enrollment_id;
    if not coalesce(v_leave, false) and p_starts_at >= ((e.final_end_date + 1)::timestamp at time zone 'Asia/Seoul') then
      raise exception '수강 종료일(%) 뒤의 시간입니다.', e.final_end_date using hint = 'after_end';
    end if;
    v_enr := l.enrollment_id;
  end if;

  v_conf := lms_makeup_conflict(l.tutor_id, l.student_id, p_starts_at, v_end, true, l.id);
  if v_conf is not null then raise exception '%', lms_conflict_message(v_conf) using hint = 'schedule_conflict', detail = lms_conflict_code(v_conf); end if;

  perform set_config('app.actor_id', me::text, true);
  perform set_config('app.actor_via', 'admin_makeup_reschedule', true);
  begin
    update lessons set starts_at = p_starts_at, ends_at = v_end, enrollment_id = v_enr where id = l.id;
  exception when exclusion_violation then
    raise exception '그 시간에 학생 또는 강사의 다른 수업이 있습니다.' using hint = 'schedule_conflict';
  end;
  if not exists (select 1 from makeup_candidates where request_id = r.id and starts_at = p_starts_at) then
    insert into makeup_candidates (request_id, starts_at, ends_at, proposed_by) values (r.id, p_starts_at, v_end, 'tutor');
  end if;

  insert into admin_makeup_logs (makeup_request_id, lesson_id, student_id, action, reason, note, old_starts_at, new_starts_at, actor)
  values (r.id, l.id, l.student_id, 'reschedule', p_reason, nullif(btrim(p_note), ''), l.starts_at, p_starts_at, me);

  -- 아직 안 보낸 예전 안내 카드는 정리하고, 바뀐 시간 안내를 양쪽에 새로 (자동 메일은 트리거)
  update lesson_notices set status = 'not_needed'
  where makeup_request_id = r.id and event in ('makeup_confirmed', 'makeup_rescheduled') and status = 'pending';
  insert into lesson_notices (makeup_request_id, event, recipient_kind, recipient_id) values (r.id, 'makeup_rescheduled', 'student', l.student_id);
  insert into lesson_notices (makeup_request_id, event, recipient_kind, recipient_id) values (r.id, 'makeup_rescheduled', 'tutor', l.tutor_id);
  return jsonb_build_object('lesson_id', l.id, 'old_starts_at', l.starts_at, 'new_starts_at', p_starts_at, 'repeated', false);
end $$;
revoke all on function admin_makeup_reschedule(uuid, timestamptz, text, text) from public, anon;
grant execute on function admin_makeup_reschedule(uuid, timestamptz, text, text) to authenticated;

-- 7. 운영 기록 읽기 (학생별, 최근 순) -------------------------------------
create or replace function admin_makeup_logs_for(p_student uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not is_admin() then raise exception '운영자(추가 인증 완료)만 처리할 수 있습니다.' using errcode = '42501'; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', g.id, 'makeup_request_id', g.makeup_request_id, 'lesson_id', g.lesson_id, 'action', g.action, 'reason', g.reason, 'note', g.note,
      'old_starts_at', g.old_starts_at, 'new_starts_at', g.new_starts_at, 'created_at', g.created_at
    ) order by g.created_at desc)
    from admin_makeup_logs g where g.student_id = p_student), '[]'::jsonb);
end $$;
revoke all on function admin_makeup_logs_for(uuid) from public, anon;
grant execute on function admin_makeup_logs_for(uuid) to authenticated;

-- 8. 강사 메일 시각 12시간 표기: 'Fri 20 Nov 3:00 PM' -----------------------
create or replace function lms_mail_en_when(p_at timestamptz, p_tz text) returns text
language sql stable as $$
  select (array['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'])[extract(dow from x)::int + 1] || ' ' || extract(day from x)::int || ' '
         || (array['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'])[extract(month from x)::int] || ' '
         || (case when extract(hour from x)::int % 12 = 0 then 12 else extract(hour from x)::int % 12 end) || ':' || to_char(x, 'MI')
         || case when extract(hour from x) < 12 then ' AM' else ' PM' end
  from (select p_at at time zone coalesce(nullif(p_tz, ''), 'Asia/Seoul') as x) q
$$;
revoke all on function lms_mail_en_when(timestamptz, text) from public, anon, authenticated;

-- 9. 메일: '보강 시간 변경' 도 같은 틀로 (제목·첫 줄만 다르고 '이전 시간' 줄 추가) ------------
create or replace function lms_notice_mail(p_notice uuid)
returns table (intended_email text, to_email text, subject text, html text, body text)
language plpgsql stable security definer set search_path = public as $$
declare
  n lesson_notices;
  r makeup_requests;
  l lessons;
  st students;
  tu tutors;
  src lessons;
  v_live boolean := coalesce((select f.enabled from feature_flags f where f.key = 'send_emails'), false);
  v_comp boolean;
  v_fix boolean;
  v_old timestamptz;
  v_origin_date date;
  v_minutes integer;
  v_origin text;
  v_when text;
  v_lines text[];
  v_url text := lms_url();
  v_btn text;
  v_foot text;
  v_test text := '';
begin
  select * into n from lesson_notices where id = p_notice;
  if not found or n.event not in ('makeup_confirmed', 'makeup_rescheduled') or n.makeup_request_id is null then return; end if;
  select * into r from makeup_requests where id = n.makeup_request_id;
  if r.confirmed_lesson_id is null then return; end if;
  select * into l from lessons where id = r.confirmed_lesson_id;
  select * into st from students where id = l.student_id;
  select * into tu from tutors where id = l.tutor_id;
  v_comp := r.compensation_id is not null;
  v_fix := n.event = 'makeup_rescheduled';
  if v_fix then
    select g.old_starts_at into v_old from admin_makeup_logs g
    where g.makeup_request_id = r.id and g.action = 'reschedule' and g.created_at <= n.created_at
    order by g.created_at desc limit 1;
  end if;
  v_minutes := round(extract(epoch from l.ends_at - l.starts_at) / 60)::int;
  if r.source_lesson_id is not null then select * into src from lessons where id = r.source_lesson_id; end if;
  if v_comp and src.id is null then
    select x.* into src from compensations c join lessons x on x.id = c.source_lesson_id where c.id = r.compensation_id;
  end if;
  if src.id is null and r.migrated_item_id is not null then select original_date into v_origin_date from migrated_items where id = r.migrated_item_id; end if;

  intended_email := lms_notice_recipient_email(n.recipient_kind, n.recipient_id);
  to_email := case when v_live then intended_email else 'support@edgeenglish.kr' end;
  if not v_live then v_test := '[시험 · ' || st.code || '] '; end if;

  if n.recipient_kind = 'student' then
    v_when := lms_mail_ko_at(l.starts_at, st.timezone);
    v_origin := case when src.id is not null then lms_mail_ko_at(src.starts_at, st.timezone)
                     when v_origin_date is not null then extract(month from v_origin_date)::int || '월 ' || extract(day from v_origin_date)::int || '일'
                     else '시트 기록 보강' end;
    subject := v_test || '[엣지영어] '
               || case when v_fix then case when v_comp then '무료 보상수업 시간이 바뀌었어요' else '보강 시간이 바뀌었어요' end
                       else case when v_comp then '무료 보상수업이 확정됐어요' else '보강이 확정됐어요' end end
               || ' · ' || lms_mail_ko_when(l.starts_at, st.timezone) || ' (' || lms_mail_ko_zone(st.timezone) || ')';
    v_lines := array[
      '[엣지영어] ' || st.name_ko || '님, ' || case when v_fix then case when v_comp then '무료 보상수업 시간이 바뀌었어요' else '보강 시간이 바뀌었어요' end
                                   else case when v_comp then '무료 보상수업이 확정됐어요' else '보강이 확정됐어요' end end,
      case when v_comp then '강사 사정으로 진행하지 못한 수업: ' else '원래 수업: ' end || v_origin,
      case when v_fix then '바뀐 시간: ' when v_comp then '보상수업: ' else '보강 수업: ' end || v_when || ' · ' || v_minutes || '분',
      '강사: ' || tu.name];
    if v_fix and v_old is not null then v_lines := v_lines || ('이전 시간: ' || lms_mail_ko_at(v_old, st.timezone) || ' (취소)'); end if;
    v_btn := 'LMS에서 일정 보기';
    v_foot := '문의: 카카오톡 채널 엣지영어';
    v_url := v_url || '/student';
  else
    v_when := lms_mail_en_at(l.starts_at, tu.timezone);
    v_origin := case when src.id is not null then lms_mail_en_at(src.starts_at, tu.timezone)
                     when v_origin_date is not null then to_char(v_origin_date, 'YYYY-MM-DD') else 'earlier class' end;
    subject := v_test || case when v_fix then 'TIME CHANGED ' else 'CONFIRMED ' end
               || case when v_comp then 'compensation class' else 'make-up' end || ' - ' || coalesce(nullif(st.name_en, ''), st.name_ko)
               || ' · ' || lms_mail_en_when(l.starts_at, tu.timezone) || ' ' || lms_mail_en_zone(tu.timezone);
    v_lines := array[
      case when v_fix then 'TIME CHANGED ' else 'CONFIRMED ' end || case when v_comp then 'compensation class' else 'make-up' end
        || ' - ' || coalesce(nullif(st.name_en, ''), st.name_ko) || ' (' || v_minutes || ' min)',
      'Original class: ' || v_origin,
      case when v_fix then 'New time: ' when v_comp then 'Compensation class: ' else 'Make-up: ' end || v_when,
      case when v_fix then 'Please update your schedule. Thank you!' else 'Please add it to your schedule. Thank you!' end];
    if v_fix and v_old is not null then v_lines := v_lines || ('Previous time (canceled): ' || lms_mail_en_at(v_old, tu.timezone)); end if;
    v_btn := 'Open Edge English LMS';
    v_foot := 'Reply to this email or message us on WhatsApp if you have a question.';
    v_url := v_url || '/tutor';
  end if;

  body := array_to_string(v_lines, E'\n') || E'\n\n' || v_btn || ': ' || v_url || E'\n' || v_foot
          || case when v_live then '' else E'\n\n(시험 발송 · 원래 받는 사람: ' || coalesce(intended_email, '없음') || ')' end;
  html := '<div style="font-family:sans-serif;font-size:15px;line-height:1.6;color:#1d1b2a;max-width:480px">'
          || case when v_live then '' else '<p style="background:#fff4d6;color:#5c3b00;border-radius:8px;padding:8px 10px;font-size:13px;font-weight:600">시험 발송 · 원래 받는 사람: ' || lms_html(coalesce(intended_email, '없음')) || '</p>' end
          || '<p style="font-weight:700">' || lms_html(v_lines[1]) || '</p>'
          || '<p>' || lms_html(v_lines[2]) || '<br><b>' || lms_html(v_lines[3]) || '</b><br>'
          || case when cardinality(v_lines) >= 5 then '<span style="color:#55526a;text-decoration:line-through">' || lms_html(v_lines[5]) || '</span><br>' else '' end
          || lms_html(v_lines[4]) || '</p>'
          || '<p><a href="' || lms_html(v_url) || '" style="display:inline-block;background:#5b3df0;color:#fff;border-radius:10px;padding:11px 18px;font-weight:700;text-decoration:none">' || lms_html(v_btn) || '</a></p>'
          || '<p style="font-size:12.5px;color:#55526a;border-top:1px solid #e6e3ef;padding-top:10px">' || lms_html(v_foot) || '</p></div>';
  return next;
end $$;
revoke all on function lms_notice_mail(uuid) from public, anon, authenticated;

-- 10. 메일 큐 트리거: 보강 확정 + 보강 시간 변경 ---------------------------
create or replace function lesson_notices_email() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.event in ('makeup_confirmed', 'makeup_rescheduled') then perform lms_mail_enqueue_notice(new.id); end if;
  return null;
end $$;
revoke all on function lesson_notices_email() from public, anon, authenticated;
