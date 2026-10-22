-- =====================================================================
-- 시험용 Supabase 로그인 사용자 권한 점검 (가상 계정 · 실행 후 전부 되돌림)
--
-- 사용: Supabase → edgeenglish-lms-test → SQL Editor → 이 파일 전체 붙여 넣기 → Run
--   - 끝에 일부러 오류를 내서 이 파일이 넣은 가상 데이터를 **전부 되돌린다** (DB에 아무것도 남지 않음).
--     그래서 결과는 빨간 오류 칸에 'AUTHZ-PROBE 결과: …' 로 나온다. 오류처럼 보여도 정상이다.
--   - 실제 운영 프로젝트에서는 실행하지 않는다 (가상 학생·강사를 잠깐 넣었다가 지운다).
--   - 로컬 검증: bash supabase/tests/run.sh 가 같은 파일을 Supabase 기본 권한을 흉내 낸 임시 DB에서 실행한다.
--
-- 가상 계정 (Supabase 로그인 계정은 만들지 않고, 로그인했다고 가정한 상태를 DB 안에서 흉내 냄)
--   미등록: 로그인은 했지만 app_users 에 없는 사람 (회원가입이 열려 있을 때 생길 수 있는 계정)
--   학생 A·B, 강사 X(학생 A 담당)·Y(학생 B 담당), 운영자(대표, TOTP 완료 aal2),
--   운영자(TOTP 전): 같은 대표 계정이 이메일 코드만 통과한 상태(aal1) → 아무것도 못 봐야 함 (POL-AC-05)
--   운영직원(TOTP 완료): 운영자지만 대표 전용 권한(is_owner) 없음 (POL-AC-07)
--
-- 확인하는 것
--   1. 권한 표: 앱 사용자(anon·authenticated)가 어떤 표에도 쓰기(추가·수정·삭제·비우기) 권한이 없는지,
--      모든 표에 RLS가 켜져 있는지, 보기(view)가 RLS를 따르는지, 운영자용 함수가 숨어 있지 않은지
--   2. 보이는 행: 사람마다 모든 표·보기를 직접 읽어서, 본인 것이 아닌 행·볼 수 없는 표가 보이면 실패
--   3. 쓰기 시도: 본인을 운영자로 올리기, 다른 학생 수정·삭제, 결제·적립금 직접 넣기 등 → 모두 거절돼야 함
--   4. 함수: 다른 학생 번호로 잔액 조회, 대신 동의, 담당 아닌 학생·강사 조회 → 막혀야 함
-- =====================================================================
do $probe$
declare
  -- 가상 ID (실제 데이터와 겹치지 않는 고정값)
  t_x  uuid := 'a17e5700-0000-4000-8000-0000000000a1';
  t_y  uuid := 'a17e5700-0000-4000-8000-0000000000a2';
  s_a  uuid := 'a17e5700-0000-4000-8000-0000000000b1';
  s_b  uuid := 'a17e5700-0000-4000-8000-0000000000b2';
  e_a  uuid := 'a17e5700-0000-4000-8000-0000000000c1';
  e_b  uuid := 'a17e5700-0000-4000-8000-0000000000c2';
  e_b2 uuid := 'a17e5700-0000-4000-8000-0000000000c3';
  p_a  uuid := 'a17e5700-0000-4000-8000-0000000000d1';
  p_b  uuid := 'a17e5700-0000-4000-8000-0000000000d2';
  l_a1 uuid := 'a17e5700-0000-4000-8000-000000000011';
  l_a2 uuid := 'a17e5700-0000-4000-8000-000000000012';
  l_b1 uuid := 'a17e5700-0000-4000-8000-000000000021';
  l_b2 uuid := 'a17e5700-0000-4000-8000-000000000022';
  doc  uuid := 'a17e5700-0000-4000-8000-0000000000e0';
  cr_b uuid := 'a17e5700-0000-4000-8000-0000000000e2';
  u_none  uuid := 'a17e5700-0000-4000-8000-0000000000f0';
  u_a     uuid := 'a17e5700-0000-4000-8000-0000000000f1';
  u_b     uuid := 'a17e5700-0000-4000-8000-0000000000f2';
  u_x     uuid := 'a17e5700-0000-4000-8000-0000000000f3';
  u_y     uuid := 'a17e5700-0000-4000-8000-0000000000f4';
  u_admin uuid := 'a17e5700-0000-4000-8000-0000000000f9';
  u_staff uuid := 'a17e5700-0000-4000-8000-0000000000f8';

  -- 공용 기준표: 로그인한 누구에게나 보여도 되는 것 (판본 목록·상태값·공휴일·게시된 안내 문서)
  reference_rels text[] := array['terms_versions', 'class_status_rules', 'holidays', 'terms_documents'];
  -- 학생에게 RLS로 본인 행이 열려 있는 표 (그 밖의 표는 한 줄도 보이면 안 됨)
  student_rels text[] := array['students', 'enrollments', 'enrollment_periods', 'lessons', 'change_requests', 'compensations',
    'credit_ledger', 'terms_deliveries', 'makeup_requests', 'makeup_candidates', 'consent_requests', 'consent_events',
    'consent_status', 'reward_ledger', 'reward_redemptions', 'long_leave_requests'];
  -- 강사에게 RLS로 본인 행이 열려 있는 표 (결제·적립금·변경권·학생 원본·동의 기록은 없음)
  tutor_rels text[] := array['tutors', 'lessons', 'class_records', 'tutor_time_off', 'terms_deliveries', 'tutor_availability',
    'makeup_requests', 'makeup_candidates', 'payroll_runs', 'tutor_contracts', 'admin_tasks', 'admin_task_board'];
  -- RLS 판단에 쓰이거나 화면에서 부르는 SECURITY DEFINER 함수 (이 밖의 것이 생기면 검토 필요)
  -- 내부 함수가 데이터를 읽지 않는 것을 검토한 확장 (이 밖의 확장 함수가 앱 사용자에게 열려 있으면 실패)
  reviewed_ext text[] := array['btree_gist'];
  definer_ok text[] := array['my_student_id', 'my_tutor_id', 'is_admin', 'is_owner', 'my_role', 'tutor_my_students', 'student_my_tutors', 'consent_record',
                          'admin_register_student', 'admin_students_with_email', 'admin_import_existing_student',
                          'admin_propose_schedule', 'admin_confirm_schedule', 'admin_close_plan', 'admin_mark_proposal_sent', 'admin_mark_notice_sent'];

  personas text[] := array['미등록', '학생A', '학생B', '강사X', '강사Y', '운영자', '운영자(TOTP 전)', '운영직원'];
  persona_uid uuid[];
  email_a text;
  persona_owner text[] := array[null, 'A', 'B', 'X', 'Y', null, null, null];
  persona_aal text[] := array['aal1', 'aal1', 'aal1', 'aal1', 'aal1', 'aal2', 'aal1', 'aal2'];

  rels text[];
  r text;
  i int;
  n bigint;
  total bigint;
  bad bigint;
  v text;
  passes int := 0;
  fails text[] := '{}';
  infos text[] := '{}';
  stmt text;
  writes text[];
  ok boolean;
begin
  set local app.actor_via = 'authz_probe';
  persona_uid := array[u_none, u_a, u_b, u_x, u_y, u_admin, u_admin, u_staff];

  -- -------------------------------------------------------------------
  -- 0. 가상 데이터 (끝에서 전부 되돌림)
  -- -------------------------------------------------------------------
  insert into tutors (id, name, country, timezone) values
    (t_x, '점검가상강사X', 'Australia', 'Australia/Sydney'), (t_y, '점검가상강사Y', 'Canada', 'America/Toronto');
  insert into students (id, code, name_ko, name_en, email, phone, admin_memo) values
    (s_a, 'STU-9801', '점검가상학생A', 'Probe A', 'probe-a@example.com', '010-0000-0001', '운영 메모 A'),
    (s_b, 'STU-9802', '점검가상학생B', 'Probe B', 'probe-b@example.com', '010-0000-0002', '운영 메모 B');
  insert into app_users (auth_user_id, role, student_id) values (u_a, 'student', s_a), (u_b, 'student', s_b);
  insert into app_users (auth_user_id, role, tutor_id) values (u_x, 'tutor', t_x), (u_y, 'tutor', t_y);
  insert into app_users (auth_user_id, role, admin_level) values (u_admin, 'admin', 'owner'), (u_staff, 'admin', 'staff');

  -- 학생 A: 24주 주1회 (장기 연기 가능), 학생 B: 4주 주2회 + 기한 안 재등록
  insert into enrollments (id, student_id, seq, weeks, weekly_count, duration_min, start_date, base_end_date, lessons_purchased, status, policy_basis) values
    (e_a, s_a, 1, 24, 1, 50, '2031-03-04', date '2031-03-04' + 167, 24, 'active', 'policy_v1'),
    (e_b, s_b, 1, 4, 2, 50, '2031-03-04', date '2031-03-04' + 27, 8, 'active', 'policy_v1');
  insert into enrollments (id, student_id, seq, previous_enrollment_id, weeks, weekly_count, duration_min, start_date, base_end_date, lessons_purchased, status, policy_basis)
    values (e_b2, s_b, 2, e_b, 4, 2, 50, '2031-04-03', date '2031-04-03' + 27, 8, 'confirmed', 'policy_v1');
  insert into enrollment_periods (id, enrollment_id, idx, start_date, end_date, credits_granted) values
    (p_a, e_a, 1, '2031-03-04', '2031-03-31', 1), (p_b, e_b, 1, '2031-03-04', '2031-03-31', 2);
  insert into regular_schedules (student_id, tutor_id, weekday, start_time_kst, duration_min, effective_from) values
    (s_a, t_x, 2, '20:00', 50, '2031-03-04'), (s_b, t_y, 2, '21:00', 50, '2031-03-04'), (s_b, t_y, 4, '21:00', 50, '2031-03-04');
  insert into lessons (id, enrollment_id, student_id, tutor_id, kind, seq, starts_at, ends_at, state, class_status, canceled_at) values
    (l_a1, e_a, s_a, t_x, 'regular', 1, '2031-03-04 11:00+00', '2031-03-04 11:50+00', 'done', 'Normal', null),
    (l_a2, e_a, s_a, t_x, 'regular', 2, '2031-03-11 11:00+00', '2031-03-11 11:50+00', 'canceled', 'Tutor canceled late', now()),
    (l_b1, e_b, s_b, t_y, 'regular', 1, '2031-03-04 12:00+00', '2031-03-04 12:50+00', 'done', 'Normal', null),
    (l_b2, e_b, s_b, t_y, 'regular', 2, '2031-03-06 12:00+00', '2031-03-06 12:50+00', 'canceled', 'Student canceled in advance', now());
  insert into class_records (lesson_id, covered_topics) values (l_a1, 'A 수업 기록'), (l_b1, 'B 수업 기록');
  insert into change_requests (lesson_id, student_id, tutor_id, type, status, via) values (l_b2, s_b, t_y, 'student_cancel', 'applied', 'student_app');
  insert into credit_ledger (period_id, lesson_id, reason, delta) values (p_b, l_b2, 'student_change', -1);
  insert into payments (enrollment_id, method, payer_name, amount_received, received_on, paid_at, confirmed_by) values
    (e_a, 'bank_transfer', '점검가상학생A', 1000000, '2031-03-01', '2031-03-01 01:00+00', u_admin),
    (e_b, 'card_link', '점검가상학생B', 200000, '2031-03-01', '2031-03-01 01:00+00', u_admin),
    (e_b2, 'card_link', '점검가상학생B', 200000, '2031-03-31', '2031-03-31 01:00+00', u_admin);   -- 기한 안 재등록 → 강사 Y 통보 업무
  insert into refunds (enrollment_id, amount, reason) values (e_b, 10000, '점검용 가상 환불');
  insert into reward_ledger (student_id, kind, amount, lesson_id) values (s_a, 'grant_tutor_late_cancel', 5000, l_a2);
  insert into reward_ledger (student_id, kind, amount, note) values (s_b, 'grant_admin', 3000, '점검용 가상 적립');
  insert into long_leave_requests (enrollment_id, leave_start, days, reason_kind) values (e_a, '2031-04-01', 7, 'health');
  insert into makeup_requests (source_lesson_id, student_id, tutor_id) values (l_b2, s_b, t_y);
  insert into tutor_time_off (tutor_id, starts_at, ends_at, kind) values (t_x, '2031-05-01 00:00+00', '2031-05-02 00:00+00', 'leave');
  insert into tutor_availability (tutor_id, weekday, start_local, end_local, timezone) values (t_y, 1, '09:00', '12:00', 'America/Toronto');
  insert into tutor_contracts (tutor_id, terms_version, signed_on, base_rate_usd, max_rate_usd) values
    (t_x, 'TC3', '2031-01-01', 11, 14), (t_y, 'TC3', '2031-01-01', 12, 15);
  insert into payroll_runs (tutor_id, month, status, final_amount_usd, approved_by) values
    (t_x, '2031-03-01', 'approved', 100, u_admin), (t_y, '2031-03-01', 'approved', 200, u_admin);
  insert into terms_deliveries (terms_code, student_id, enrollment_id, timing, channel) values
    ('G20260709', s_a, e_a, 'after_payment', 'online_page'), ('G20260709', s_b, e_b, 'after_payment', 'online_page');
  insert into terms_deliveries (terms_code, tutor_id, timing, channel) values ('TC3', t_x, 'at_signing', 'esign'), ('TC3', t_y, 'at_signing', 'esign');
  insert into terms_versions (code, kind, audience, title, source_ref) values ('PROBECT1', 'class_terms', 'student', '점검용 가상 수업 안내', 'PROBE');
  insert into terms_documents (id, terms_code, format, body_md, required_items, status, published_at)
    values (doc, 'PROBECT1', 'text', '점검용 가상 문구', '[{"key":"ok","text":"확인"}]', 'published', now());
  insert into consent_requests (student_id, enrollment_id, document_id, reason) values (s_a, e_a, doc, 'new');
  insert into consent_requests (id, student_id, enrollment_id, document_id, reason) values (cr_b, s_b, e_b, doc, 'new');
  insert into notifications (recipient_kind, recipient_id, email, locale, template, dedupe_key) values
    ('student', s_b, 'probe-b@example.com', 'ko', 'probe', 'probe-b-1');

  -- -------------------------------------------------------------------
  -- 1. 권한 표 (catalog)
  -- -------------------------------------------------------------------
  select array_agg(c.relname order by c.relname) into rels
  from pg_class c join pg_namespace s on s.oid = c.relnamespace
  where s.nspname = 'public' and c.relkind in ('r', 'v', 'm', 'p', 'f');

  foreach r in array rels loop
    foreach v in array array['INSERT', 'UPDATE', 'DELETE', 'TRUNCATE', 'REFERENCES', 'TRIGGER'] loop
      if has_table_privilege('authenticated', format('public.%I', r), v) or has_table_privilege('anon', format('public.%I', r), v)
         or (v in ('INSERT', 'UPDATE', 'REFERENCES') and (has_any_column_privilege('authenticated', format('public.%I', r), v)
                                                          or has_any_column_privilege('anon', format('public.%I', r), v))) then
        fails := fails || format('[권한] %s: 앱 사용자에게 %s 권한이 열려 있음', r, v);
      end if;
    end loop;
  end loop;
  select count(*) into bad from pg_class c join pg_namespace s on s.oid = c.relnamespace
   where s.nspname = 'public' and c.relkind in ('r', 'p') and not c.relrowsecurity;
  if bad > 0 then fails := fails || format('[권한] RLS가 꺼진 표 %s개: %s', bad,
    (select string_agg(c.relname, ', ') from pg_class c join pg_namespace s on s.oid = c.relnamespace
      where s.nspname = 'public' and c.relkind in ('r', 'p') and not c.relrowsecurity)); end if;
  select string_agg(c.relname, ', ') into v from pg_class c join pg_namespace s on s.oid = c.relnamespace
   where s.nspname = 'public' and c.relkind = 'v'
     and not coalesce('security_invoker=true' = any(c.reloptions) or 'security_invoker=on' = any(c.reloptions), false)
     and has_table_privilege('authenticated', c.oid, 'SELECT');
  if v is not null then fails := fails || format('[권한] RLS를 건너뛰는 보기(view): %s', v); end if;
  select string_agg(c.relname, ', ') into v from pg_class c join pg_namespace s on s.oid = c.relnamespace
   where s.nspname = 'public' and c.relkind = 'S'
     and (has_sequence_privilege('authenticated', c.oid, 'USAGE') or has_sequence_privilege('authenticated', c.oid, 'UPDATE')
          or has_sequence_privilege('anon', c.oid, 'USAGE') or has_sequence_privilege('anon', c.oid, 'UPDATE'));
  if v is not null then fails := fails || format('[권한] 앱 사용자가 쓸 수 있는 번호 시퀀스: %s', v); end if;
  -- 함수 판정 (2026-10-17 실물 Supabase 결과 반영)
  --  - 검토된 확장(btree_gist)의 내부 함수: 실물 Supabase는 확장을 플랫폼 관리자(supabase_admin) 소유로 만들고
  --    anon 실행 권한을 기본으로 준다. 우리 SQL(postgres 권한)로는 그 권한을 회수할 수 없고(로컬은 슈퍼유저라 회수됨),
  --    함수가 숫자 거리 계산·인덱스 내부용(internal 인자)이라 데이터를 읽지 않으며 REST API로도 부를 수 없다
  --    (인자가 이름 없는 2개 이상) → 실패가 아니라 '참고'로 표시. 다른 확장의 함수는 여전히 실패로 잡는다.
  --  - 트리거·이벤트 트리거 함수(예: Supabase 자동 RLS 켜기 rls_auto_enable): 직접 호출할 수 없고
  --    DB 이벤트가 있을 때만 실행됨 → SECURITY DEFINER 여도 '참고'로 표시.
  select string_agg(p.proname, ', ') into v from pg_proc p join pg_namespace s on s.oid = p.pronamespace
   where s.nspname = 'public' and has_function_privilege('anon', p.oid, 'EXECUTE')
     and coalesce((select e.extname from pg_depend d join pg_extension e on e.oid = d.refobjid where d.classid = 'pg_proc'::regclass and d.objid = p.oid and d.deptype = 'e' limit 1), '') <> all (reviewed_ext);
  if v is not null then fails := fails || format('[권한] 로그인 안 한 사용자가 실행할 수 있는 함수: %s', v); end if;
  select string_agg(distinct (select e.extname from pg_depend d join pg_extension e on e.oid = d.refobjid where d.classid = 'pg_proc'::regclass and d.objid = p.oid and d.deptype = 'e' limit 1) || ' (' || pg_get_userbyid(p.proowner) || ' 소유)', ', '), count(*) into v, n
    from pg_proc p join pg_namespace s on s.oid = p.pronamespace
   where s.nspname = 'public' and has_function_privilege('anon', p.oid, 'EXECUTE') and (select e.extname from pg_depend d join pg_extension e on e.oid = d.refobjid where d.classid = 'pg_proc'::regclass and d.objid = p.oid and d.deptype = 'e' limit 1) = any (reviewed_ext);
  if n > 0 then infos := infos || format('확장 내부 함수 %s개에 비로그인 실행 권한이 남아 있음: %s — 데이터 접근 없음·API로 호출 불가, 운영 프로젝트는 확장을 extensions 스키마에 설치 권장', n, v); end if;
  select string_agg(p.proname, ', ') into v from pg_proc p join pg_namespace s on s.oid = p.pronamespace
   where s.nspname = 'public' and p.prosecdef and has_function_privilege('authenticated', p.oid, 'EXECUTE')
     and p.proname <> all (definer_ok)
     and p.prorettype not in ('trigger'::regtype, 'event_trigger'::regtype);
  if v is not null then fails := fails || format('[권한] 검토 안 된 SECURITY DEFINER 함수: %s', v); end if;
  select string_agg(p.proname || ' (' || pg_get_userbyid(p.proowner) || ' 소유)', ', ') into v
    from pg_proc p join pg_namespace s on s.oid = p.pronamespace
   where s.nspname = 'public' and p.prosecdef and p.prorettype in ('trigger'::regtype, 'event_trigger'::regtype);
  if v is not null then infos := infos || format('SECURITY DEFINER 트리거·이벤트 트리거 함수(직접 호출 불가): %s', v); end if;
  select string_agg(p.proname, ', ' order by p.proname) into v from pg_proc p join pg_namespace s on s.oid = p.pronamespace
   where s.nspname = 'public' and not p.prosecdef and p.prorettype not in ('trigger'::regtype, 'event_trigger'::regtype)
     and has_function_privilege('authenticated', p.oid, 'EXECUTE')
     and (select e.extname from pg_depend d join pg_extension e on e.oid = d.refobjid where d.classid = 'pg_proc'::regclass and d.objid = p.oid and d.deptype = 'e' limit 1) is null;   -- 확장 내부 함수 제외
  infos := infos || format('로그인 사용자가 실행할 수 있는 일반 함수(RLS 그대로 적용): %s', coalesce(v, '없음'));
  if cardinality(fails) = 0 then passes := passes + 1; end if;

  -- -------------------------------------------------------------------
  -- 2. 소유 범위 계산 (점검자 권한으로): 사람마다 '본인 것' ID 집합
  --    시작 = 학생/강사 번호 + 로그인 ID, 그 ID를 담은 행의 id(UUID만) 를 계속 더해 감
  --    (이력 표의 1·2·3 같은 숫자 번호는 다른 칸의 숫자와 우연히 겹치므로 넣지 않음)
  -- -------------------------------------------------------------------
  create temp table _own (who text, val text, primary key (who, val)) on commit drop;
  insert into _own values ('A', s_a::text), ('A', u_a::text), ('B', s_b::text), ('B', u_b::text),
                          ('X', t_x::text), ('X', u_x::text), ('Y', t_y::text), ('Y', u_y::text);
  grant select on _own to authenticated;
  create temp table _seen (who text, rel text, n bigint) on commit drop;   -- 아래에서 '로그인 사용자'로 읽을 때 비교용 (끝나면 표째 사라짐)
  loop
    n := 0;
    foreach r in array rels loop
      if exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = r and column_name = 'id')
         and (select relkind from pg_class where oid = format('public.%I', r)::regclass) in ('r', 'p') then
        execute format($q$
          insert into _own (who, val)
          select distinct o.who, (to_jsonb(t) ->> 'id') from public.%I t, lateral jsonb_each_text(to_jsonb(t)) kv
          join _own o on o.val = kv.value
          where (to_jsonb(t) ->> 'id') ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
          on conflict do nothing$q$, r);
        get diagnostics total = row_count;
        n := n + total;
      end if;
    end loop;
    exit when n = 0;
  end loop;

  -- -------------------------------------------------------------------
  -- 3. 사람마다 모든 표·보기를 직접 읽어 봄
  -- -------------------------------------------------------------------
  for i in 1 .. cardinality(personas) loop
    perform set_config('request.jwt.claim.sub', persona_uid[i]::text, true);
    perform set_config('request.jwt.claims', json_build_object('sub', persona_uid[i], 'role', 'authenticated', 'aal', persona_aal[i])::text, true);
    perform set_config('request.jwt.claim.role', 'authenticated', true);
    ok := true;
    foreach r in array rels loop
      execute 'set local role authenticated';
      begin
        execute format('select count(*) from public.%I', r) into n;
      exception when insufficient_privilege then n := 0;
      end;
      if n > 0 and persona_owner[i] is not null and r <> all (reference_rels) then
        -- 본인 범위(_own)에 닿지 않는 행 수 / 다른 학생·강사 범위에만 닿는 행 수
        execute format($q$
          select count(*) filter (where not exists (select 1 from jsonb_each_text(to_jsonb(t)) kv join _own o on o.val = kv.value and o.who = %L))
          from public.%I t$q$, persona_owner[i], r) into bad;
      else
        bad := 0;
      end if;
      execute 'reset role';
      execute format('select count(*) from public.%I', r) into total;
      insert into _seen values (personas[i], r, n);

      if personas[i] in ('운영자', '운영직원') then
        if n <> total then infos := infos || format('%s에게 %s 표가 %s/%s행만 보임', personas[i], r, n, total); end if;
      elsif personas[i] in ('미등록', '운영자(TOTP 전)') then
        if n > 0 and r <> all (reference_rels) then
          ok := false; fails := fails || format('[읽기] %s 계정이 %s 표에서 %s행을 봄', personas[i], r, n);
        end if;
      elsif persona_owner[i] in ('A', 'B') then
        if n > 0 and r <> all (reference_rels || student_rels) then
          ok := false; fails := fails || format('[읽기] %s이 학생에게 닫혀 있어야 할 %s 표에서 %s행을 봄', personas[i], r, n);
        elsif bad > 0 then
          ok := false; fails := fails || format('[읽기] %s이 %s 표에서 본인 것이 아닌 행 %s개를 봄', personas[i], r, bad);
        end if;
      else
        if n > 0 and r <> all (reference_rels || tutor_rels) then
          ok := false; fails := fails || format('[읽기] %s가 강사에게 닫혀 있어야 할 %s 표에서 %s행을 봄', personas[i], r, n);
        elsif bad > 0 then
          ok := false; fails := fails || format('[읽기] %s가 %s 표에서 본인 담당이 아닌 행 %s개를 봄', personas[i], r, bad);
        end if;
      end if;
    end loop;
    if ok then passes := passes + 1; end if;

    -- 4. 쓰기 시도 (모두 권한 없음 42501 로 거절돼야 함)
    writes := array[
      format($w$insert into app_users (auth_user_id, role) values (%L, 'admin')$w$, persona_uid[i]),
      format($w$update app_users set role = 'admin' where auth_user_id = %L$w$, persona_uid[i]),
      format($w$insert into students (code, name_ko, name_en) values ('STU-9899', '가상', 'x')$w$),
      format($w$update students set admin_memo = '변조', email = 'x@example.com' where id in (%L, %L)$w$, s_a, s_b),
      format($w$delete from students where id = %L$w$, s_b),
      format($w$insert into payments (enrollment_id, method, amount_received, received_on, paid_at, confirmed_by) values (%L, 'bank_transfer', 1, current_date, now(), %L)$w$, e_b, persona_uid[i]),
      format($w$update payments set amount_received = 1 where enrollment_id = %L$w$, e_b),
      format($w$insert into reward_ledger (student_id, kind, amount, note) values (%L, 'grant_admin', 999999, 'x')$w$, s_a),
      format($w$insert into credit_ledger (period_id, reason, delta) values (%L, 'admin_adjust', 1)$w$, p_b),
      format($w$update lessons set state = 'canceled', canceled_at = now(), class_status = 'Tutor canceled late' where id = %L$w$, l_b1),
      format($w$update enrollments set base_end_date = base_end_date + 28 where id = %L$w$, e_a),
      format($w$update feature_flags set enabled = true$w$),
      format($w$insert into consent_events (request_id, action, document_sha256, actor_auth_id, actor_role) values (%L, 'accepted', 'x', %L, 'student')$w$, cr_b, persona_uid[i]),
      format($w$update class_records set covered_topics = '변조' where lesson_id = %L$w$, l_b1),
      format($w$insert into admin_tasks (kind, enrollment_id) values ('new_student_matching', %L)$w$, e_b2),
      format($w$select nextval('student_code_seq')$w$),
      format($w$select lms_protect('public.students'::regclass)$w$)
    ];
    ok := true;
    foreach stmt in array writes loop
      begin
        execute 'set local role authenticated';
        execute stmt;
        execute 'reset role';
        ok := false; fails := fails || format('[쓰기] %s: 거절되지 않음 → %s', personas[i], left(stmt, 90));
      exception when others then
        execute 'reset role';
        if sqlstate <> '42501' then
          ok := false; fails := fails || format('[쓰기] %s: 권한이 아닌 다른 이유로 막힘 [%s] %s → %s', personas[i], sqlstate, left(sqlerrm, 60), left(stmt, 60));
        end if;
      end;
    end loop;
    if ok then passes := passes + 1; end if;

    -- 5. 함수 (본인 확인을 DB가 직접 하는지)
    select email into email_a from students where id = s_a;
    execute 'set local role authenticated';
    begin
      if personas[i] not in ('운영자', '운영직원') and is_admin() then fails := fails || format('[함수] %s: is_admin() 이 참', personas[i]); end if;
      if personas[i] in ('운영자', '운영직원') and not is_admin() then fails := fails || format('[함수] %s: is_admin() 이 거짓', personas[i]); end if;
      if my_role() is distinct from (case when personas[i] = '미등록' then null when personas[i] like '학생%' then 'student'
                                          when personas[i] like '강사%' then 'tutor' else 'admin' end) then
        fails := fails || format('[함수] %s: my_role() = %s', personas[i], my_role()); end if;
      if (personas[i] = '운영자') <> is_owner() then fails := fails || format('[함수] %s: is_owner() = %s', personas[i], is_owner()); end if;
      if personas[i] in ('미등록', '강사X', '강사Y', '운영자', '운영자(TOTP 전)', '운영직원') and my_student_id() is not null then fails := fails || format('[함수] %s: 학생 번호가 잡힘', personas[i]); end if;
      if personas[i] in ('미등록', '학생A', '학생B', '운영자', '운영자(TOTP 전)', '운영직원') and my_tutor_id() is not null then fails := fails || format('[함수] %s: 강사 번호가 잡힘', personas[i]); end if;
      select count(*) into n from student_my_tutors();
      if (personas[i] in ('학생A', '학생B') and n <> 1) or (personas[i] not in ('학생A', '학생B') and n <> 0) then
        fails := fails || format('[함수] %s: student_my_tutors() %s명', personas[i], n); end if;
      select count(*) into n from tutor_my_students();
      select count(*) into bad from tutor_my_students() t
        where t.student_id <> case personas[i] when '강사X' then s_a when '강사Y' then s_b end;
      if (personas[i] in ('강사X', '강사Y') and (n <> 1 or bad <> 0)) or (personas[i] not in ('강사X', '강사Y') and n <> 0) then
        fails := fails || format('[함수] %s: tutor_my_students() %s명 (담당 아닌 학생 %s명)', personas[i], n, bad); end if;
      if personas[i] not in ('학생B', '운영자', '운영직원') then
        if coalesce(reward_balance(s_b), 0) <> 0 then fails := fails || format('[함수] %s: 학생 B 적립금 잔액이 보임', personas[i]); end if;
        if coalesce(credit_balance(p_b), 0) <> 0 then fails := fails || format('[함수] %s: 학생 B 변경권 잔액이 보임', personas[i]); end if;
      end if;
      -- 신규 학생 등록 함수 (migration 900): 운영자(aal2)만. 다른 사람은 권한 오류
      begin
        perform admin_register_student(gen_random_uuid(), '{}'::jsonb);
        fails := fails || format('[함수] %s: 빈 등록 요청이 통과함', personas[i]);
      exception when others then
        if personas[i] not in ('운영자', '운영직원') and sqlstate <> '42501' then
          fails := fails || format('[함수] %s: 학생 등록이 권한 오류가 아닌 이유로 막힘 [%s] %s', personas[i], sqlstate, sqlerrm); end if;
        if personas[i] in ('운영자', '운영직원') and sqlstate = '42501' then
          fails := fails || format('[함수] %s: 운영자인데 학생 등록 권한 없음', personas[i]); end if;
      end;
      -- 기존 학생 간단 입력 (migration 1300): 운영자(aal2)만
      begin
        perform admin_import_existing_student(gen_random_uuid(), '{}'::jsonb);
        fails := fails || format('[함수] %s: 빈 기존 학생 입력이 통과함', personas[i]);
      exception when others then
        if personas[i] not in ('운영자', '운영직원') and sqlstate <> '42501' then
          fails := fails || format('[함수] %s: 기존 학생 입력이 권한 오류가 아닌 이유로 막힘 [%s] %s', personas[i], sqlstate, sqlerrm); end if;
        if personas[i] in ('운영자', '운영직원') and sqlstate = '42501' then
          fails := fails || format('[함수] %s: 운영자인데 기존 학생 입력 권한 없음', personas[i]); end if;
      end;
      select count(*) into n from admin_students_with_email(email_a);
      if (personas[i] in ('운영자', '운영직원') and email_a is not null and n = 0) or (personas[i] not in ('운영자', '운영직원') and n <> 0) then
        fails := fails || format('[함수] %s: 같은 이메일 확인 결과 %s건', personas[i], n); end if;
      begin
        perform consent_record(cr_b, 'accepted', array['ok']);
        if personas[i] <> '학생B' then fails := fails || format('[함수] %s: 학생 B 대신 동의가 됨', personas[i]); end if;
      exception when others then
        if personas[i] = '학생B' then fails := fails || format('[함수] 학생B 본인 동의 실패: %s', sqlerrm); end if;
      end;
      execute 'reset role';
    exception when others then
      execute 'reset role';
      fails := fails || format('[함수] %s: 점검 중 오류 %s', personas[i], sqlerrm);
    end;
  end loop;

  -- 점검이 헛돌지 않는지: 본인 것은 실제로 보여야 함 (안 보이면 로그인 흉내가 안 된 것)
  select string_agg(format('%s:%s=%s', e.who, e.rel, coalesce(x.n, 0)), ', ') into v
  from (values ('학생A', 'students', 1), ('학생A', 'enrollments', 1), ('학생A', 'lessons', 2), ('학생A', 'reward_ledger', 1),
               ('학생A', 'long_leave_requests', 1), ('학생A', 'consent_requests', 1),
               ('학생B', 'students', 1), ('학생B', 'enrollments', 2), ('학생B', 'lessons', 2), ('학생B', 'credit_ledger', 1),
               ('학생B', 'reward_ledger', 1), ('학생B', 'makeup_requests', 1),
               ('강사X', 'tutors', 1), ('강사X', 'lessons', 2), ('강사X', 'class_records', 1), ('강사X', 'payroll_runs', 1),
               ('강사Y', 'tutors', 1), ('강사Y', 'lessons', 2), ('강사Y', 'admin_tasks', 1), ('강사Y', 'makeup_requests', 1)) e(who, rel, want)
  left join _seen x on x.who = e.who and x.rel = e.rel
  where coalesce(x.n, 0) <> e.want;
  if v is not null then fails := fails || format('[점검 자체] 본인 것이 예상대로 보이지 않음: %s', v); else passes := passes + 1; end if;

  -- 운영자는 읽기 전용 (쓰기는 서버 전용 키로만) — 위 4번에서 운영자도 모두 거절돼야 통과
  -- 기능 확인: 학생 B는 본인 결제·환불을 앱에서 직접 보지 못함 (RLS 정책 없음, 화면은 서버가 필요한 칸만 보여 줄 예정)
  infos := infos || '학생은 본인 결제·환불 표도 직접 못 봄 (정책 없음) — 화면 설계 때 필요하면 결제 요약만 여는 정책 추가'::text;

  raise exception using message = format(E'AUTHZ-PROBE 결과: %s\n(이 오류는 가상 데이터를 되돌리기 위한 정상 동작입니다)\n%s%s',
    case when cardinality(fails) = 0 then format('모두 통과 (점검 묶음 %s개)', passes) else format('실패 %s건', cardinality(fails)) end,
    case when cardinality(fails) = 0 then '' else E'\n실패:\n- ' || array_to_string(fails, E'\n- ') || E'\n' end,
    E'\n참고:\n- ' || array_to_string(infos, E'\n- '));
end
$probe$;
