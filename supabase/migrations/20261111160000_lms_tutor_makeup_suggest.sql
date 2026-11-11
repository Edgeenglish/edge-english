-- H26(134) 강사가 학생이 고른 보강 시간이 모두 안 될 때: 강사가 가능 시간에서 1~2개 골라 제안 → 학생이 하나 고르면 바로 확정.
-- 강사가 먼저 고른 시간이라 D-43('학생 선택만으로 확정 금지')의 예외 (대표 11/11 확정). 재승인 단계 없음.
--  상태 (모두 같은 DB 값으로 판단, makeup_stage):
--   requested + 강사 답 없음            → 'tutor'  (강사 답 필요)
--   countered + 유효한 제안 시간 남음    → 'student' (학생 선택 대기)
--   countered + 학생 '모두 안 돼요' / 제안 시간이 다 지났거나 막힘 → 'admin' (운영진 조율 필요, 학생 재촉 메일 없음)
--   requested + 강사가 모두 불가 + 메모  → 'admin' (예전과 같음)
--  1. makeup_requests.student_declined_at: 학생이 [제안한 시간이 모두 안 돼요]를 누른 시각
--  2. lms_makeup_slot_ok: 확정 함수(lms_makeup_book)와 같은 검사로 지금도 되는 시간인지
--  3. makeup_stage(makeup_requests): 화면 3곳(학생·강사·운영진)이 함께 쓰는 상태 (PostgREST 계산 칸)
--  4. tutor_makeup_suggest_options / tutor_makeup_suggest: 학생 보강 달력과 같은 함수(lms_makeup_options)로 고를 시간·검사
--  5. lms_makeup_suggested_mail: 학생에게 '[엣지영어] 강사님이 보강 시간을 제안했어요' (운영진은 lms_mail_dispatch 숨은참조), 신청 1건에 1통
--  6. student_makeup_pick: 누르는 순간 다시 검사 → lms_makeup_book (잠금으로 두 번 확정 막음, 같은 시간 다시 누르면 같은 결과)
--  7. student_makeup_decline_suggestion: '모두 안 돼요' → 운영진 조율
--  8. lms_makeup_book: 제안 시간은 학생이 원한 시간으로 검사(쉬는 시간 예외 같게), 학생이 직접 고른 확정은 학생 카톡 복사 카드 안 만듦(메일은 그대로)
--  9. lms_makeup_expire_run: 강사가 제안한 신청(countered)은 자동 만료하지 않음 (운영진 조율로)
-- 10. student_makeup_suggestions / tutor_makeup_suggestions: 화면용 읽기 (tutor_screen·student_screen 은 그대로)
-- 새 숫자: 제안 개수 최대 2 (대표 11/11 확정)

alter table makeup_requests add column if not exists student_declined_at timestamptz;
alter table makeup_requests add column if not exists suggested_at timestamptz;   -- 강사가 시간을 제안한 시각 (확정 뒤에도 '강사 제안' 신청인지 알 수 있게)

create or replace function lms_makeup_slot_ok(p_request uuid, p_start timestamptz)
returns boolean
language plpgsql stable security definer set search_path = public as $$
declare
  r makeup_requests;
  s record;
  c record;
  e enrollments;
  v_end timestamptz;
begin
  select * into r from makeup_requests where id = p_request;
  if not found or p_start <= now() then return false; end if;
  if r.compensation_id is not null then
    select * into c from lms_comp_source(r.compensation_id);
    select * into e from enrollments where id = c.enrollment_id;
    if p_start >= ((c.use_until + 1)::timestamp at time zone 'Asia/Seoul') then return false; end if;
  else
    select * into s from lms_makeup_source(r.source_lesson_id, r.migrated_item_id);
    select * into e from enrollments where id = s.enrollment_id;
    if not s.tutor_leave and p_start >= ((e.final_end_date + 1)::timestamp at time zone 'Asia/Seoul') then return false; end if;
  end if;
  v_end := p_start + make_interval(mins => e.duration_min);
  if lms_makeup_conflict(r.tutor_id, r.student_id, p_start, v_end, true) is not null then return false; end if;
  return not exists (select 1 from lessons l where l.student_id = r.student_id and l.state <> 'canceled'
                     and l.starts_at < v_end and p_start < l.ends_at);
end $$;
revoke all on function lms_makeup_slot_ok(uuid, timestamptz) from public, anon, authenticated;

create or replace function makeup_stage(r makeup_requests)
returns text
language sql stable security definer set search_path = public as $$
  select case
    when r.status not in ('requested', 'countered') then r.status
    when r.status = 'countered' then
      case when r.student_declined_at is null
                and exists (select 1 from makeup_candidates c where c.request_id = r.id and c.proposed_by = 'tutor' and lms_makeup_slot_ok(r.id, c.starts_at))
           then 'student' else 'admin' end
    when r.tutor_answered_at is null then 'tutor'
    when exists (select 1 from makeup_candidates c where c.request_id = r.id and c.proposed_by = 'student' and c.tutor_answer = 'yes') then 'admin_confirm'
    else 'admin' end
$$;
revoke all on function makeup_stage(makeup_requests) from public, anon;
grant execute on function makeup_stage(makeup_requests) to authenticated;

-- 강사가 고를 수 있는 시간 = 학생 보강 달력과 같은 시간 (휴무·다른 수업·휴식·현지 06:00~22:30·Availability·종료일), 학생이 이미 고른 시간 빼고
create or replace function tutor_makeup_suggest_options(p_request uuid)
returns table(starts_at timestamptz, ends_at timestamptz)
language plpgsql stable security definer set search_path = public as $$
declare
  r makeup_requests;
begin
  select * into r from makeup_requests where id = p_request;
  if not found then raise exception 'Make-up request not found.'; end if;
  if not (is_admin() or (my_tutor_id() is not null and r.tutor_id = my_tutor_id())) then
    raise exception 'This is not your make-up request.' using errcode = '42501';
  end if;
  if r.status <> 'requested' then return; end if;
  return query
  select o.starts_at, o.ends_at from lms_makeup_options(r.source_lesson_id, r.migrated_item_id, r.compensation_id) o
  where not exists (select 1 from makeup_candidates c where c.request_id = r.id and c.starts_at = o.starts_at)
  order by o.starts_at;
end $$;
revoke all on function tutor_makeup_suggest_options(uuid) from public, anon;
grant execute on function tutor_makeup_suggest_options(uuid) to authenticated;

-- 학생에게 제안 메일 1통 (대표 11/11 문구). 시험 DB(send_emails 꺼짐)는 support@ 로만
create or replace function lms_makeup_suggested_mail(p_request uuid)
returns void
language plpgsql security definer set search_path = public as $$
declare
  v_live boolean := coalesce((select f.enabled from feature_flags f where f.key = 'send_emails'), false);
  r makeup_requests;
  st students;
  src lessons;
  v_date date;
  v_what text;
  v_intended text;
  v_subject text;
  v_lines text[];
  v_url text;
  v_btn text;
  v_foot text := '문의: 카카오톡 채널 엣지영어';
  v_body text;
  v_html text;
  v_id uuid;
begin
  select * into r from makeup_requests where id = p_request;
  if not found then return; end if;
  select * into st from students where id = r.student_id;
  select * into src from lessons where id = coalesce(r.source_lesson_id, (select c.source_lesson_id from compensations c where c.id = r.compensation_id));
  if src.id is null and r.migrated_item_id is not null then select original_date into v_date from migrated_items where id = r.migrated_item_id; end if;
  v_intended := lms_notice_recipient_email('student', st.id);
  if v_intended is null then return; end if;
  v_what := case when r.compensation_id is not null then '보상수업' else '보강' end;
  v_subject := '[엣지영어] 강사님이 ' || v_what || ' 시간을 제안했어요';
  if not v_live then v_subject := '[시험 · ' || st.code || '] ' || v_subject; end if;
  v_lines := array[
    '신청하신 시간에는 강사님이 수업을 진행하기 어려워 다른 시간을 제안했어요.',
    '아래 LMS에서 가능한 시간 하나를 선택하시면 ' || v_what || ' 수업이 바로 확정됩니다.',
    '원래 수업: ' || case when src.id is not null then lms_mail_ko_at(src.starts_at, st.timezone)
                         when v_date is not null then to_char(v_date, 'FMMM') || '월 ' || to_char(v_date, 'FMDD') || '일('
                              || (array['일','월','화','수','목','금','토'])[extract(dow from v_date)::int + 1] || ') [한국 날짜]'
                         else '-' end];
  select v_lines || ('제안 시간:' || E'\n' || string_agg('- ' || lms_mail_ko_at(c.starts_at, st.timezone), E'\n' order by c.starts_at))
    into v_lines from makeup_candidates c where c.request_id = r.id and c.proposed_by = 'tutor';
  v_url := lms_url() || '/student?makeup=' || r.id;   -- 바로가기: 그 신청 화면을 바로 엶
  v_btn := 'LMS에서 ' || v_what || ' 시간 선택하기';
  v_body := lms_strip_bold(array_to_string(v_lines, E'\n')) || E'\n\n' || v_btn || ': ' || v_url || E'\n' || v_foot
            || case when v_live then '' else E'\n\n(시험 발송 · 원래 받는 사람: ' || v_intended || ')' end;
  select '<div style="font-family:sans-serif;font-size:15px;line-height:1.6;color:#1d1b2a;max-width:480px">'
         || case when v_live then '' else '<p style="background:#fff4d6;color:#5c3b00;border-radius:8px;padding:8px 10px;font-size:13px;font-weight:600">시험 발송 · 원래 받는 사람: ' || lms_html(v_intended) || '</p>' end
         || string_agg('<p>' || replace(lms_bold_html(line), E'\n', '<br>') || '</p>', '' order by ord)
         || '<p><a href="' || lms_html(v_url) || '" style="display:inline-block;background:#5b3df0;color:#fff;border-radius:10px;padding:11px 18px;font-weight:700;text-decoration:none">' || lms_html(v_btn) || '</a></p><p>' || lms_html(v_foot) || '</p></div>'
    into v_html from unnest(v_lines) with ordinality as lines(line, ord);
  insert into notifications (recipient_kind, recipient_id, email, locale, template, payload, dedupe_key)
  values ('student', st.id, case when v_live then v_intended else 'support@edgeenglish.kr' end, 'ko', 'lesson_notice_makeup_suggested',
          jsonb_build_object('intended_email', v_intended, 'subject', v_subject, 'html', v_html, 'text', v_body, 'makeup_request_id', r.id),
          'makeup_suggested:' || r.id)
  on conflict (dedupe_key) do nothing
  returning id into v_id;
  if v_id is not null then perform lms_mail_dispatch(v_id); end if;
end $$;
revoke all on function lms_makeup_suggested_mail(uuid) from public, anon, authenticated;

create or replace function tutor_makeup_suggest(p_request uuid, p_times timestamptz[])
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  r makeup_requests;
  v_times timestamptz[] := array(select distinct t from unnest(coalesce(p_times, '{}'::timestamptz[])) t order by t);
  v_n integer;
  v_via text;
begin
  select * into r from makeup_requests where id = p_request for update;
  if not found then raise exception 'Make-up request not found.'; end if;
  if not (is_admin() or (my_tutor_id() is not null and r.tutor_id = my_tutor_id())) then
    raise exception 'This is not your make-up request.' using errcode = '42501';
  end if;
  -- 두 번 누름·다른 기기: 같은 시간이면 같은 결과
  if r.status = 'countered' then
    if v_times = array(select c.starts_at from makeup_candidates c where c.request_id = r.id and c.proposed_by = 'tutor' order by c.starts_at) then
      return jsonb_build_object('makeup_request_id', r.id, 'suggested', cardinality(v_times), 'repeated', true);
    end if;
    raise exception 'You already suggested times for this request.' using hint = 'closed';
  end if;
  if r.status <> 'requested' then
    raise exception 'This make-up request is already closed.' using hint = 'closed';
  end if;
  if cardinality(v_times) < 1 or cardinality(v_times) > 2 then
    raise exception 'Please pick 1 or 2 times.' using hint = 'count';
  end if;
  if exists (select 1 from unnest(v_times) t where t <= now()) then
    raise exception 'One of these times has already passed. Please pick again.' using hint = 'busy';
  end if;
  v_via := case when is_admin() then 'admin_makeup_suggest_as_tutor' else 'tutor_makeup_suggest' end;
  perform set_config('app.actor_id', coalesce(me::text, ''), true);
  perform set_config('app.actor_via', v_via, true);
  insert into makeup_candidates (request_id, starts_at, ends_at, proposed_by)
  select r.id, o.starts_at, o.ends_at, 'tutor'
  from lms_makeup_options(r.source_lesson_id, r.migrated_item_id, r.compensation_id) o
  where o.starts_at = any(v_times)
    and not exists (select 1 from makeup_candidates c where c.request_id = r.id and c.starts_at = o.starts_at);
  get diagnostics v_n = row_count;
  if v_n <> cardinality(v_times) then
    raise exception 'One of these times is no longer open. Please pick again.' using hint = 'busy';
  end if;
  update makeup_candidates set tutor_answer = 'no', answered_at = now(), answered_by = me
  where request_id = r.id and proposed_by = 'student' and tutor_answer is distinct from 'no';
  update makeup_requests set status = 'countered', tutor_note = null, tutor_answered_at = now(), suggested_at = now(), student_declined_at = null where id = r.id;
  update lesson_notices set status = 'not_needed' where makeup_request_id = r.id and event = 'makeup_ask' and status = 'pending';
  perform lms_makeup_suggested_mail(r.id);
  return jsonb_build_object('makeup_request_id', r.id, 'suggested', v_n, 'repeated', false);
end $$;
revoke all on function tutor_makeup_suggest(uuid, timestamptz[]) from public, anon;
grant execute on function tutor_makeup_suggest(uuid, timestamptz[]) to authenticated;

-- lms_makeup_book: 20261108010000 판 그대로 + (1) 강사 제안 시간은 학생이 원한 시간으로 검사 (2) 학생이 직접 고른 확정은 학생 카톡 복사 카드 없음
create or replace function lms_makeup_book(p_makeup_request uuid, p_starts_at timestamptz, p_via text, p_by_tutor boolean)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  r makeup_requests;
  s record;
  c record;
  e enrollments;
  v_end timestamptz;
  v_lesson uuid;
  v_conf text;
  v_enr uuid;
  v_wants boolean;
begin
  select * into r from makeup_requests where id = p_makeup_request for update;
  if not found then raise exception '보강 신청이 없습니다.'; end if;
  if r.status = 'confirmed' then return jsonb_build_object('makeup_request_id', r.id, 'lesson_id', r.confirmed_lesson_id, 'repeated', true); end if;
  if r.status not in ('requested', 'countered') then raise exception '이미 닫힌 보강 신청입니다.'; end if;
  if p_starts_at <= now() then raise exception '지난 시간은 보강으로 넣을 수 없습니다.'; end if;
  -- 강사가 불가라고 답한 시간 (QA-01 D, 4500)
  if exists (select 1 from makeup_candidates x where x.request_id = r.id and x.starts_at = p_starts_at and x.proposed_by = 'student' and x.tutor_answer = 'no') then
    raise exception '강사가 불가라고 답한 시간입니다. 다른 시간을 고르거나 학생에게 다시 날짜를 받아 주세요.' using hint = 'tutor_no';
  end if;
  v_wants := exists (select 1 from makeup_candidates x where x.request_id = r.id and x.starts_at = p_starts_at
                     and (x.proposed_by = 'student' or (r.status = 'countered' and x.proposed_by = 'tutor')));

  if r.compensation_id is not null then
    perform 1 from compensations where id = r.compensation_id for update;   -- 같은 보상권 두 번 쓰기 막기
    select * into c from lms_comp_source(r.compensation_id);
    if p_starts_at >= ((c.use_until + 1)::timestamp at time zone 'Asia/Seoul') then
      raise exception '보상수업 사용 기한(%) 뒤의 시간입니다.', c.use_until using hint = 'after_end';
    end if;
    select * into e from enrollments where id = c.enrollment_id;
    v_end := p_starts_at + make_interval(mins => e.duration_min);
    v_conf := lms_makeup_conflict(r.tutor_id, c.student_id, p_starts_at, v_end, v_wants);
    if v_conf is not null then raise exception '%', lms_conflict_message(v_conf) using hint = 'schedule_conflict', detail = lms_conflict_code(v_conf); end if;
    v_enr := lms_comp_lesson_enrollment(r.compensation_id, (p_starts_at at time zone 'Asia/Seoul')::date);
    perform set_config('app.actor_id', me::text, true);
    perform set_config('app.actor_via', p_via, true);
    if not exists (select 1 from makeup_candidates where request_id = r.id and starts_at = p_starts_at) then
      insert into makeup_candidates (request_id, starts_at, ends_at, proposed_by) values (r.id, p_starts_at, v_end, 'tutor');
    end if;
    begin
      insert into lessons (enrollment_id, student_id, tutor_id, kind, starts_at, ends_at, compensation_id, created_by)
      values (v_enr, c.student_id, r.tutor_id, 'compensation', p_starts_at, v_end, r.compensation_id, me)
      returning id into v_lesson;
    exception when exclusion_violation then
      raise exception '그 시간에 학생 또는 강사의 다른 수업이 있습니다.' using hint = 'schedule_conflict';
    end;
    update compensations set status = 'used', used_lesson_id = v_lesson where id = r.compensation_id;
  else
    select * into s from lms_makeup_source(r.source_lesson_id, r.migrated_item_id);
    select * into e from enrollments where id = s.enrollment_id;
    if not s.tutor_leave and p_starts_at >= ((e.final_end_date + 1)::timestamp at time zone 'Asia/Seoul') then
      raise exception '수강 종료일(%) 뒤의 시간입니다.', e.final_end_date using hint = 'after_end';
    end if;
    v_end := p_starts_at + make_interval(mins => e.duration_min);
    v_conf := lms_makeup_conflict(r.tutor_id, s.student_id, p_starts_at, v_end, v_wants);
    if v_conf is not null then raise exception '%', lms_conflict_message(v_conf) using hint = 'schedule_conflict', detail = lms_conflict_code(v_conf); end if;

    perform set_config('app.actor_id', me::text, true);
    perform set_config('app.actor_via', p_via, true);
    if not exists (select 1 from makeup_candidates where request_id = r.id and starts_at = p_starts_at) then
      insert into makeup_candidates (request_id, starts_at, ends_at, proposed_by) values (r.id, p_starts_at, v_end, 'tutor');
    end if;
    begin
      insert into lessons (enrollment_id, student_id, tutor_id, kind, starts_at, ends_at, makeup_of, created_by)
      values (s.enrollment_id, s.student_id, r.tutor_id,
              case when r.source_lesson_id is null then 'migrated_makeup' else 'makeup' end,
              p_starts_at, v_end, r.source_lesson_id, me)
      returning id into v_lesson;
    exception when exclusion_violation then
      raise exception '그 시간에 학생 또는 강사의 다른 수업이 있습니다.' using hint = 'schedule_conflict';
    end;
    if r.migrated_item_id is not null then
      update migrated_items set kind = 'makeup_booked', lesson_id = v_lesson where id = r.migrated_item_id;
      -- R-18 (4520): 이관권이 수업에 연결된 뒤 휴무 자동 연장 재계산
      perform lms_leave_sync_extension(s.enrollment_id);
    end if;
  end if;
  update makeup_requests set status = 'confirmed', confirmed_lesson_id = v_lesson, decided_at = now(), decided_by = me,
         confirmed_in_tutor_screen = p_by_tutor where id = r.id;
  update lesson_notices set status = 'not_needed' where makeup_request_id = r.id and event = 'makeup_ask' and status = 'pending';
  -- 학생·강사 확정 안내 (자동 메일은 트리거). 카톡 복사는 운영진 차례, 강사가 직접 확정했으면 WhatsApp 복사는 필요 없음
  -- 학생이 강사 제안 시간을 직접 골랐으면 학생 카톡 복사도 필요 없음 (메일은 그대로 감, H26(134))
  insert into lesson_notices (makeup_request_id, event, recipient_kind, recipient_id, status)
  values (r.id, 'makeup_confirmed', 'student', r.student_id, case when p_via like 'student_makeup_pick%' then 'not_needed' else 'pending' end);
  insert into lesson_notices (makeup_request_id, event, recipient_kind, recipient_id, status)
  values (r.id, 'makeup_confirmed', 'tutor', r.tutor_id, case when p_by_tutor then 'not_needed' else 'pending' end);
  return jsonb_build_object('makeup_request_id', r.id, 'lesson_id', v_lesson, 'repeated', false);
end $$;
revoke all on function lms_makeup_book(uuid, timestamptz, text, boolean) from public, anon, authenticated;

create or replace function student_makeup_pick(p_student uuid, p_request uuid, p_candidate uuid)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_student uuid := lms_screen_student(p_student);
  r makeup_requests;
  c makeup_candidates;
  v_via text := case when is_admin() then 'student_makeup_pick(운영자 대신)' else 'student_makeup_pick' end;
  v_hint text;
  v_msg text;
begin
  select * into r from makeup_requests where id = p_request for update;
  if not found or r.student_id <> v_student then raise exception '본인 신청만 고를 수 있어요.' using errcode = '42501'; end if;
  select * into c from makeup_candidates where id = p_candidate and request_id = r.id and proposed_by = 'tutor';
  if not found then raise exception '이 시간은 이제 선택할 수 없어요.' using hint = 'busy'; end if;
  -- 두 번 누름·다른 기기: 같은 시간으로 이미 확정됐으면 같은 결과
  if r.status = 'confirmed' then
    if exists (select 1 from lessons l where l.id = r.confirmed_lesson_id and l.starts_at = c.starts_at) then
      return jsonb_build_object('makeup_request_id', r.id, 'lesson_id', r.confirmed_lesson_id, 'repeated', true);
    end if;
    raise exception '이미 다른 시간으로 확정됐어요.' using hint = 'closed';
  end if;
  if r.status <> 'countered' or r.student_declined_at is not null then
    raise exception '이미 끝난 신청이에요. 새로고침해 주세요.' using hint = 'closed';
  end if;
  if not lms_makeup_slot_ok(r.id, c.starts_at) then
    raise exception '이 시간은 이제 선택할 수 없어요.' using hint = 'busy';
  end if;
  perform set_config('app.actor_id', coalesce(auth.uid()::text, ''), true);
  perform set_config('app.actor_via', v_via, true);
  begin
    return lms_makeup_book(r.id, c.starts_at, v_via, false);
  exception when raise_exception then
    get stacked diagnostics v_hint = pg_exception_hint, v_msg = message_text;
    if v_hint in ('schedule_conflict', 'after_end', 'tutor_no') then
      raise exception '이 시간은 이제 선택할 수 없어요.' using hint = 'busy';
    end if;
    raise exception '%', v_msg using hint = coalesce(v_hint, '');
  end;
end $$;
revoke all on function student_makeup_pick(uuid, uuid, uuid) from public, anon;
grant execute on function student_makeup_pick(uuid, uuid, uuid) to authenticated;

create or replace function student_makeup_decline_suggestion(p_student uuid, p_request uuid)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_student uuid := lms_screen_student(p_student);
  r makeup_requests;
begin
  select * into r from makeup_requests where id = p_request for update;
  if not found or r.student_id <> v_student then raise exception '본인 신청만 처리할 수 있어요.' using errcode = '42501'; end if;
  if r.status = 'countered' and r.student_declined_at is not null then return jsonb_build_object('makeup_request_id', r.id, 'repeated', true); end if;
  if r.status <> 'countered' then raise exception '이미 확정됐거나 끝난 신청이에요. 새로고침해 주세요.' using hint = 'closed'; end if;
  perform set_config('app.actor_id', coalesce(auth.uid()::text, ''), true);
  perform set_config('app.actor_via', case when is_admin() then 'student_makeup_decline(운영자 대신)' else 'student_makeup_decline' end, true);
  update makeup_requests set student_declined_at = now() where id = r.id;
  return jsonb_build_object('makeup_request_id', r.id, 'repeated', false);
end $$;
revoke all on function student_makeup_decline_suggestion(uuid, uuid) from public, anon;
grant execute on function student_makeup_decline_suggestion(uuid, uuid) to authenticated;

-- 강사가 제안한 신청은 학생 시간이 다 지나도 만료하지 않음 (제안 시간이 다 지나면 운영진 조율, 대표 11/11)
create or replace function lms_makeup_expire_run(p_now timestamptz default now())
returns jsonb
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
    where r.status = 'requested'
      and exists (select 1 from makeup_candidates c where c.request_id = r.id and c.proposed_by = 'student')
      and not exists (select 1 from makeup_candidates c where c.request_id = r.id and c.proposed_by = 'student' and c.starts_at > p_now)
    returning r.id, r.student_id
  loop
    v_n := v_n + 1;
    update lesson_notices set status = 'not_needed' where makeup_request_id = x.id and status = 'pending';
    insert into lesson_notices (makeup_request_id, event, recipient_kind, recipient_id, status)
    values (x.id, 'makeup_expired', 'student', x.student_id, 'not_needed')
    on conflict do nothing;
    get diagnostics v_k = row_count;
    v_mail := v_mail + v_k;
  end loop;
  return jsonb_build_object('expired', v_n, 'mailed', v_mail);
end $$;

-- 화면용 읽기: 강사가 제안한 신청(countered)의 상태와 제안 시간 (지금도 되는지 ok)
create or replace function student_makeup_suggestions(p_student uuid)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_student uuid := lms_screen_student(p_student);
begin
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', r.id, 'stage', makeup_stage(r), 'declined', r.student_declined_at is not null,
      'suggested', (select coalesce(jsonb_agg(jsonb_build_object('id', c.id, 'starts_at', c.starts_at, 'ends_at', c.ends_at,
                                                                 'ok', lms_makeup_slot_ok(r.id, c.starts_at)) order by c.starts_at), '[]'::jsonb)
                    from makeup_candidates c where c.request_id = r.id and c.proposed_by = 'tutor')))
    from makeup_requests r where r.student_id = v_student and r.suggested_at is not null
      and (r.status = 'countered' or (r.status = 'confirmed' and r.suggested_at > now() - interval '60 days'))), '[]'::jsonb);
end $$;
revoke all on function student_makeup_suggestions(uuid) from public, anon;
grant execute on function student_makeup_suggestions(uuid) to authenticated;

create or replace function tutor_makeup_suggestions(p_tutor uuid)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_tutor uuid := lms_screen_tutor(p_tutor);
begin
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', r.id, 'stage', makeup_stage(r), 'declined', r.student_declined_at is not null,
      'suggested', (select coalesce(jsonb_agg(jsonb_build_object('starts_at', c.starts_at, 'ends_at', c.ends_at,
                                                                 'ok', lms_makeup_slot_ok(r.id, c.starts_at)) order by c.starts_at), '[]'::jsonb)
                    from makeup_candidates c where c.request_id = r.id and c.proposed_by = 'tutor')))
    from makeup_requests r where r.tutor_id = v_tutor and r.status = 'countered'), '[]'::jsonb);
end $$;
revoke all on function tutor_makeup_suggestions(uuid) from public, anon;
grant execute on function tutor_makeup_suggestions(uuid) to authenticated;
