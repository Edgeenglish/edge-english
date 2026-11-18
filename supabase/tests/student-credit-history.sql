-- 시험 DB 읽기 전용 점검 (student_credit_history, 20261118100000). 기존 데이터만 씀, BEGIN/ROLLBACK 안에서 실행.
-- ① 학생 본인 = 운영자 보기 ② 다른 학생·강사·인증 앱 안 한 운영자·비로그인 거절 ③ 모든 학생: 기간 left = credit_balance,
--    줄은 처리 시각 최신순, 운영 메모(note) 칸 없음, 변경권 줄(사용·반환·조정) 수 = credit_ledger 수
do $$
declare
  admin_uid uuid; student_uid uuid; sid uuid; other_sid uuid; tutor_uid uuid;
  row record; h jsonb; mine jsonb; denied boolean; checked int := 0;
begin
  select auth_user_id into admin_uid from app_users where role = 'admin' limit 1;
  select auth_user_id, student_id into student_uid, sid from app_users where role = 'student' limit 1;
  select id into other_sid from students where id <> sid limit 1;
  select auth_user_id into tutor_uid from app_users where role = 'tutor' limit 1;
  perform set_config('request.jwt.claims', jsonb_build_object('sub', admin_uid, 'aal', 'aal2')::text, true);
  for row in select id from students loop
    h := student_credit_history(row.id);
    if exists (select 1 from jsonb_array_elements(h) p join enrollment_periods ep on ep.start_date = (p->>'start')::date
               join enrollments en on en.id = ep.enrollment_id and en.student_id = row.id
               where (p->>'left')::int <> credit_balance(ep.id)) then
      raise exception 'left 가 credit_balance 와 다름';
    end if;
    if exists (select 1 from jsonb_array_elements(h) p, lateral (select (i->>'at')::timestamptz at,
                 lag((i->>'at')::timestamptz) over (order by ord) prev from jsonb_array_elements(p->'items') with ordinality x(i, ord)) x
               where x.at > x.prev) then
      raise exception '최신순 아님';
    end if;
    if exists (select 1 from jsonb_array_elements(h) p, jsonb_array_elements(p->'items') i, jsonb_object_keys(i) k
               where k not in ('id','at','kind','delta','lesson_at','cancel_at','timing','holiday','reverted','after')) then
      raise exception '검토 안 한 칸';
    end if;
    if (select count(*) from jsonb_array_elements(h) p, jsonb_array_elements(p->'items') i where (i->>'delta')::int <> 0)
       <> (select count(*) from credit_ledger g join enrollment_periods ep on ep.id = g.period_id
           join enrollments en on en.id = ep.enrollment_id and en.student_id = row.id) then
      raise exception '변경권 기록 수가 다름';
    end if;
    checked := checked + 1;
  end loop;
  mine := student_credit_history(sid);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', student_uid, 'aal', 'aal1')::text, true);
  set local role authenticated;
  if student_credit_history(null) <> mine then raise exception '학생 본인 ≠ 운영자 보기'; end if;
  denied := false; begin perform student_credit_history(other_sid); exception when insufficient_privilege then denied := true; end;
  if not denied then raise exception '다른 학생 열림'; end if;
  perform set_config('request.jwt.claims', jsonb_build_object('sub', tutor_uid, 'aal', 'aal2')::text, true);
  denied := false; begin perform student_credit_history(sid); exception when insufficient_privilege then denied := true; end;
  if not denied then raise exception '강사가 열림'; end if;
  perform set_config('request.jwt.claims', jsonb_build_object('sub', admin_uid, 'aal', 'aal1')::text, true);
  denied := false; begin perform student_credit_history(sid); exception when insufficient_privilege then denied := true; end;
  if not denied then raise exception '인증 앱 안 한 운영자가 열림'; end if;
  perform set_config('request.jwt.claims', '{}', true);
  denied := false; begin perform student_credit_history(sid); exception when others then denied := true; end;
  if not denied then raise exception '비로그인 열림'; end if;
  reset role;
  raise notice 'credit history QA 통과: 학생 %명', checked;
end $$;
