-- =====================================================================
-- 새 수업 시간 고르기 보충 (정책 원본 H26(218) 보충2, 대표 11/25 '넣어')
--  ① 새 시간으로 확정된 뒤 강사가 그 시간을 근무 가능 시간에서 빼면, 그 수업은 다시 학생 고르기 대상
--  ② 메일 (문구 대표 11/25 확정)
--     학생 '수업 시간을 새로 골라 주세요' = 대상 생기면 1통 (15분마다 확인) + 안 고르면 첫 대상 수업 7일 전 1통
--       (첫 메일이 이미 7일 안쪽이면 첫 메일 24시간 뒤) · 다시 1통은 제목 '(다시 알려드려요)', 아직 안 고른 수업만
--     학생 '선생님이 신청한 수업 시간을 확인해 주세요' = 강사 신청 바로 1통
--     확정 = 한 번 처리한 결과 1통씩 (학생 한국어·강사 영어). 운영진 확인 회차는 그 줄만 덧붙임. 확정 0회면 안 보냄
--     강사 'New class times needed' 메일 없음 (To do 만)
-- =====================================================================

-- 기존 정규 수업이 지금 옮겨야 하는 상태인지 (lms_ttl_rows 대상 조건과 같음)
create or replace function lms_ttl_needs_move(p_lesson uuid)
returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from lessons l
    where l.id = p_lesson and l.kind = 'regular' and l.state = 'scheduled' and l.voided_at is null and l.original_tutor_id is null
      and l.enrollment_id is not null and l.starts_at > now()
      and lms_tutor_location_at(l.tutor_id, l.starts_at) is not null
      and not lms_tutor_available(l.tutor_id, l.starts_at)
      and not exists (select 1 from tutor_time_off o where o.tutor_id = l.tutor_id and o.starts_at < l.ends_at and l.starts_at < o.ends_at)
      and not exists (select 1 from leave_items li where li.lesson_id = l.id and li.withdrawn_at is null))
$$;

create or replace function lms_ttl_rows(p_tutor uuid, p_student uuid)
returns table (key text, lesson_id uuid, pending_id uuid, tutor_id uuid, student_id uuid, enrollment_id uuid, location_id uuid,
               orig_starts_at timestamptz, minutes integer, state text, new_starts_at timestamptz, conflict text, batch_id uuid, move_id uuid)
language sql stable security definer set search_path = public as $$
  with det as (
    select 'l:' || l.id as key, l.id as lesson_id, null::uuid as pending_id, l.tutor_id, l.student_id, l.enrollment_id,
           lms_tutor_location_at(l.tutor_id, l.starts_at) as location_id, l.starts_at as orig,
           (extract(epoch from l.ends_at - l.starts_at) / 60)::int as minutes
    from lessons l
    where (p_tutor is null or l.tutor_id = p_tutor) and (p_student is null or l.student_id = p_student)
      and l.kind = 'regular' and l.state = 'scheduled' and l.voided_at is null and l.original_tutor_id is null
      and l.enrollment_id is not null and l.starts_at > now()
      and lms_tutor_location_at(l.tutor_id, l.starts_at) is not null
      and not lms_tutor_available(l.tutor_id, l.starts_at)
      and not exists (select 1 from tutor_time_off o where o.tutor_id = l.tutor_id and o.starts_at < l.ends_at and l.starts_at < o.ends_at)
      and not exists (select 1 from leave_items li where li.lesson_id = l.id and li.withdrawn_at is null)
      and not exists (select 1 from temp_location_moves m where m.lesson_id = l.id)
    union all
    select 'p:' || p.id, null::uuid, p.id, p.tutor_id, p.student_id, p.enrollment_id,
           lms_tutor_location_at(p.tutor_id, (p.original_date + p.time_kst) at time zone 'Asia/Seoul'),
           (p.original_date + p.time_kst) at time zone 'Asia/Seoul', e.duration_min::int
    from plan_pending_lessons p join enrollments e on e.id = p.enrollment_id
    where (p_tutor is null or p.tutor_id = p_tutor) and (p_student is null or p.student_id = p_student)
      and p.resolved_at is null
      and not exists (select 1 from temp_location_moves m where m.pending_id = p.id)
  )
  select d.key, d.lesson_id, d.pending_id, d.tutor_id, d.student_id, d.enrollment_id, d.location_id, d.orig, d.minutes,
         null::text, null::timestamptz, null::text, null::uuid, null::uuid
  from det d where d.location_id is not null
  union all
  -- ① 확정됐던 기존 수업이 다시 근무 시간 밖이 됨 → 지금 시각 기준으로 다시 고르기 대상
  select 'l:' || m.lesson_id, m.lesson_id, null::uuid, m.tutor_id, m.student_id, m.enrollment_id,
         lms_tutor_location_at(l.tutor_id, l.starts_at), l.starts_at, m.minutes,
         null::text, null::timestamptz, null::text, null::uuid, m.id
  from temp_location_moves m join lessons l on l.id = m.lesson_id
  where (p_tutor is null or m.tutor_id = p_tutor) and (p_student is null or m.student_id = p_student)
    and m.state = 'confirmed' and lms_ttl_needs_move(m.lesson_id)
  union all
  select case when m.lesson_id is not null then 'l:' || m.lesson_id else 'p:' || m.pending_id end,
         m.lesson_id, m.pending_id, m.tutor_id, m.student_id, m.enrollment_id, m.location_id, m.orig_starts_at, m.minutes,
         m.state, m.new_starts_at, m.conflict, m.batch_id, m.id
  from temp_location_moves m
  where (p_tutor is null or m.tutor_id = p_tutor) and (p_student is null or m.student_id = p_student)
    and ((m.state = 'confirmed' and m.lesson_id is not null and not lms_ttl_needs_move(m.lesson_id))
         -- 협의 필요 회차에서 만든 수업: 그 수업이 다시 대상이 되면(위 det 'l:' 줄) 또는 그 수업으로 다시 옮긴 줄이 있으면 이 줄은 숨김
         or (m.state = 'confirmed' and m.pending_id is not null
             and not (m.result_lesson_id is not null and (lms_ttl_needs_move(m.result_lesson_id)
                      or exists (select 1 from temp_location_moves m2 where m2.lesson_id = m.result_lesson_id))))
         or m.state in ('admin', 'admin_done')
         -- 아직 처리 안 끝난 회차는 지금도 옮길 필요가 있을 때만 (강사가 그 시간을 열었거나 수업이 취소됐으면 빠짐)
         or (m.state not in ('confirmed', 'admin', 'admin_done') and m.lesson_id is not null
             and exists (select 1 from lessons l where l.id = m.lesson_id and l.state = 'scheduled' and l.voided_at is null
                         and l.starts_at > now() and not lms_tutor_available(l.tutor_id, l.starts_at)))
         or (m.state not in ('confirmed', 'admin', 'admin_done') and m.pending_id is not null
             and exists (select 1 from plan_pending_lessons p where p.id = m.pending_id and p.resolved_at is null)))
$$;

-- 처리 줄 저장: 다시 대상이 된 줄은 지금 시각을 원래 시각으로 (메일·화면의 '기존 수업')
create or replace function lms_ttl_save(p_row jsonb, p_state text, p_at timestamptz, p_conflict text,
                                        p_batch uuid, p_by text, p_result uuid)
returns void
language plpgsql security definer set search_path = public as $$
declare
  v_id uuid;
begin
  select x.id into v_id from temp_location_moves x
  where x.lesson_id = (p_row ->> 'lesson_id')::uuid or x.pending_id = (p_row ->> 'pending_id')::uuid;
  if v_id is not null then
    update temp_location_moves set state = p_state, new_starts_at = p_at, conflict = p_conflict, batch_id = p_batch, by_kind = p_by,
           orig_starts_at = coalesce((p_row ->> 'orig_starts_at')::timestamptz, orig_starts_at),
           location_id = coalesce((p_row ->> 'location_id')::uuid, location_id),
           by_admin = is_admin() and p_by <> 'admin', result_lesson_id = coalesce(p_result, result_lesson_id),
           decided_at = case when p_state in ('confirmed', 'admin', 'admin_done') then now() end
    where id = v_id;
  else
    insert into temp_location_moves (tutor_id, student_id, enrollment_id, location_id, lesson_id, pending_id, orig_starts_at, minutes,
                                     state, new_starts_at, conflict, batch_id, by_kind, by_admin, result_lesson_id, created_by, decided_at)
    values ((p_row ->> 'tutor_id')::uuid, (p_row ->> 'student_id')::uuid, (p_row ->> 'enrollment_id')::uuid, (p_row ->> 'location_id')::uuid,
            (p_row ->> 'lesson_id')::uuid, (p_row ->> 'pending_id')::uuid, (p_row ->> 'orig_starts_at')::timestamptz, (p_row ->> 'minutes')::int,
            p_state, p_at, p_conflict, p_batch, p_by, is_admin() and p_by <> 'admin', p_result, auth.uid(),
            case when p_state in ('confirmed', 'admin', 'admin_done') then now() end);
  end if;
end $$;

-- ---------------------------------------------------------------------
-- 메일
-- ---------------------------------------------------------------------
create table if not exists temp_location_mails (
  id uuid primary key default gen_random_uuid(),
  kind text not null check (kind in ('pick', 'pick_again', 'proposed', 'confirmed_student', 'confirmed_tutor')),
  tutor_id uuid not null references tutors(id),
  student_id uuid not null references students(id),
  location_id uuid references tutor_locations(id),
  batch_id uuid,
  pick_id uuid references temp_location_mails(id),           -- pick_again 이 어느 pick 의 다시 알림인지
  keys text[] not null default '{}',                         -- 메일에 넣은 회차
  notification_id uuid references notifications(id),
  created_at timestamptz not null default now()
);
create unique index if not exists temp_location_mails_again on temp_location_mails (pick_id) where kind = 'pick_again';
create unique index if not exists temp_location_mails_batch on temp_location_mails (batch_id, kind) where batch_id is not null;
create index if not exists temp_location_mails_group on temp_location_mails (student_id, tutor_id, kind);
alter table temp_location_mails enable row level security;
drop policy if exists temp_location_mails_admin_read on temp_location_mails;
create policy temp_location_mails_admin_read on temp_location_mails for select using (is_admin());
revoke insert, update, delete on temp_location_mails from anon, authenticated;
drop trigger if exists temp_location_mails_no_delete on temp_location_mails;
create trigger temp_location_mails_no_delete before delete on temp_location_mails for each row execute function forbid_delete();

-- 학생 메일 한 줄: 시각 (거주지 시간 · 한국이 아니면 한국 시간 함께)
create or replace function lms_ttl_ko_at(p_at timestamptz, p_tz text) returns text
language sql stable as $$ select lms_mail_ko_at(p_at, p_tz) $$;

-- 학생 메일 한 줄: 기존 → 새 시각 (한국 거주 + 같은 날이면 '12월 1일(화) 오후 7시 → 오후 8시 [한국 시간]')
create or replace function lms_ttl_ko_move(p_old timestamptz, p_new timestamptz, p_tz text) returns text
language sql stable as $$
  select case
    when coalesce(nullif(p_tz, ''), 'Asia/Seoul') = 'Asia/Seoul' then
      lms_mail_ko_when(p_old, 'Asia/Seoul') || ' → '
      || case when (p_old at time zone 'Asia/Seoul')::date = (p_new at time zone 'Asia/Seoul')::date then lms_mail_ko_hour(p_new, 'Asia/Seoul')
              else lms_mail_ko_when(p_new, 'Asia/Seoul') end || ' [한국 시간]'
    else lms_mail_ko_at(p_old, p_tz) || ' → ' || lms_mail_ko_at(p_new, p_tz) end
$$;

-- 학생 메일 보내기 (다른 학생 메일과 같은 틀: 시험 DB 는 support@ 로, 제목 앞 [시험 · 학생번호])
create or replace function lms_ttl_student_mail(p_student uuid, p_template text, p_key text, p_subject text, p_lines text[], p_btn text)
returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_live boolean := coalesce((select f.enabled from feature_flags f where f.key = 'send_emails'), false);
  st students;
  v_intended text;
  v_subject text;
  v_url text := lms_url() || '/student';
  v_foot text := '문의: 카카오톡 채널 엣지영어';
  v_body text;
  v_html text;
  v_id uuid;
begin
  select * into st from students where id = p_student;
  v_intended := lms_notice_recipient_email('student', st.id);
  if v_intended is null then return null; end if;
  select id into v_id from notifications where dedupe_key = p_key;
  if v_id is not null then return v_id; end if;
  v_subject := case when v_live then '' else '[시험 · ' || st.code || '] ' end || p_subject;
  v_body := lms_strip_bold(array_to_string(p_lines, E'\n\n')) || E'\n\n' || coalesce(p_btn || ': ' || v_url || E'\n', '') || v_foot
            || case when v_live then '' else E'\n\n(시험 발송 · 원래 받는 사람: ' || v_intended || ')' end;
  select '<div style="font-family:sans-serif;font-size:15px;line-height:1.6;color:#1d1b2a;max-width:480px">'
         || case when v_live then '' else '<p style="background:#fff4d6;color:#5c3b00;border-radius:8px;padding:8px 10px;font-size:13px;font-weight:600">시험 발송 · 원래 받는 사람: ' || lms_html(v_intended) || '</p>' end
         || string_agg('<p>' || replace(lms_bold_html(line), E'\n', '<br>') || '</p>', '' order by ord)
         || coalesce('<p><a href="' || lms_html(v_url) || '" style="display:inline-block;background:#5b3df0;color:#fff;border-radius:10px;padding:11px 18px;font-weight:700;text-decoration:none">' || lms_html(p_btn) || '</a></p>', '')
         || '<p>' || lms_html(v_foot) || '</p></div>'
    into v_html from unnest(p_lines) with ordinality as lines(line, ord);
  insert into notifications (recipient_kind, recipient_id, email, locale, template, payload, dedupe_key)
  values ('student', st.id, case when v_live then v_intended else 'support@edgeenglish.kr' end, 'ko', p_template,
          jsonb_build_object('intended_email', v_intended, 'subject', v_subject, 'html', v_html, 'text', v_body),
          p_key)
  on conflict (dedupe_key) do nothing
  returning id into v_id;
  if v_id is null then select id into v_id from notifications where dedupe_key = p_key; return v_id; end if;
  perform lms_mail_dispatch(v_id);
  return v_id;
end $$;

-- 학생 '수업 시간을 새로 골라 주세요' (처음 · 다시). 아직 안 고른 회차(state null·later·returned)만
create or replace function lms_ttl_pick_mail(p_tutor uuid, p_student uuid, p_location uuid, p_again uuid)
returns uuid
language plpgsql security definer set search_path = public as $$
declare
  st students;
  tu tutors;
  loc tutor_locations;
  v_keys text[];
  v_list text;
  n integer;
  v_mail uuid;
  v_row uuid;
begin
  select * into st from students where id = p_student;
  select * into tu from tutors where id = p_tutor;
  select * into loc from tutor_locations where id = p_location;
  select array_agg(r.key order by r.orig_starts_at), count(*),
         string_agg(lms_ttl_ko_at(r.orig_starts_at, st.timezone), E'\n' order by r.orig_starts_at)
    into v_keys, n, v_list
  from lms_ttl_rows(p_tutor, p_student) r
  where r.location_id = p_location and (r.state is null or r.state in ('later', 'returned'));
  if coalesce(n, 0) = 0 then return null; end if;
  insert into temp_location_mails (kind, tutor_id, student_id, location_id, pick_id, keys)
  values (case when p_again is null then 'pick' else 'pick_again' end, p_tutor, p_student, p_location, p_again, v_keys)
  on conflict do nothing
  returning id into v_row;
  if v_row is null then return null; end if;
  v_mail := lms_ttl_student_mail(st.id, 'ttl_pick', 'ttl_pick:' || v_row,
    '[엣지영어] ' || case when p_again is null then '' else '(다시 알려드려요) ' end || '수업 시간을 새로 골라 주세요',
    array[tu.name || ' 선생님의 근무 지역이 ' || extract(month from loc.starts_on)::int || '월 ' || extract(day from loc.starts_on)::int || '일~'
            || coalesce(extract(month from loc.ends_on)::int || '월 ' || extract(day from loc.ends_on)::int || '일', '') || ' 동안 잠시 바뀌어,' || E'\n'
            || '아래 수업 ' || n || '회의 시간을 바꿔야 해요.',
          v_list],
    '새 수업 시간 고르기');
  update temp_location_mails set notification_id = v_mail where id = v_row;
  return v_mail;
end $$;

-- 15분마다: 새 대상이 생긴 묶음에 1통 · 안 고른 묶음에 다시 1통
create or replace function lms_ttl_mail_run()
returns integer
language plpgsql security definer set search_path = public as $$
declare
  g record;
  p temp_location_mails;
  v_due timestamptz;
  n integer := 0;
begin
  for g in
    select r.tutor_id, r.student_id, r.location_id, array_agg(r.key) keys, min(r.orig_starts_at) first_at
    from lms_ttl_rows(null, null) r
    where r.state is null or r.state in ('later', 'returned')
    group by r.tutor_id, r.student_id, r.location_id
  loop
    -- 강사가 보낸 시간이 학생 확인을 기다리는 중이면 보내지 않음
    continue when exists (select 1 from temp_location_moves m where m.tutor_id = g.tutor_id and m.student_id = g.student_id and m.state = 'proposed');
    -- 아직 어떤 '골라 주세요' 메일에도 넣지 않은 회차가 있으면 처음 1통
    if exists (select 1 from unnest(g.keys) k
               where not exists (select 1 from temp_location_mails x where x.student_id = g.student_id and x.tutor_id = g.tutor_id
                                 and x.kind in ('pick', 'pick_again') and k = any (x.keys))) then
      if lms_ttl_pick_mail(g.tutor_id, g.student_id, g.location_id, null) is not null then n := n + 1; end if;
      continue;
    end if;
    -- 다시 1통: 마지막 '골라 주세요' 기준, 첫 대상 수업 7일 전 (첫 메일이 이미 그 뒤면 첫 메일 24시간 뒤)
    select * into p from temp_location_mails x
    where x.student_id = g.student_id and x.tutor_id = g.tutor_id and x.location_id = g.location_id and x.kind = 'pick'
    order by x.created_at desc limit 1;
    continue when p.id is null or exists (select 1 from temp_location_mails x where x.pick_id = p.id);
    v_due := g.first_at - interval '7 days';
    if p.created_at > v_due then v_due := p.created_at + interval '24 hours'; end if;
    if now() >= v_due and lms_ttl_pick_mail(g.tutor_id, g.student_id, g.location_id, p.id) is not null then n := n + 1; end if;
  end loop;
  return n;
end $$;

-- 학생 '선생님이 신청한 수업 시간을 확인해 주세요' (강사 신청 바로 1통)
create or replace function lms_ttl_proposed_mail(p_tutor uuid, p_student uuid, p_batch uuid)
returns uuid
language plpgsql security definer set search_path = public as $$
declare
  st students;
  tu tutors;
  v_list text;
  n integer;
  v_row uuid;
  v_mail uuid;
begin
  select * into st from students where id = p_student;
  select * into tu from tutors where id = p_tutor;
  select count(*), string_agg(lms_ttl_ko_move(m.orig_starts_at, m.new_starts_at, st.timezone), E'\n' order by m.orig_starts_at)
    into n, v_list
  from temp_location_moves m where m.batch_id = p_batch and m.state = 'proposed' and m.new_starts_at is not null;
  if coalesce(n, 0) = 0 then return null; end if;
  insert into temp_location_mails (kind, tutor_id, student_id, batch_id) values ('proposed', p_tutor, p_student, p_batch)
  on conflict do nothing returning id into v_row;
  if v_row is null then return null; end if;
  v_mail := lms_ttl_student_mail(st.id, 'ttl_proposed', 'ttl_proposed:' || p_batch,
    '[엣지영어] 선생님이 신청한 수업 시간을 확인해 주세요',
    array[tu.name || ' 선생님이 아래 수업 ' || n || '회의 새 시간을 신청했어요.', v_list],
    '확인하기');
  update temp_location_mails set notification_id = v_mail where id = v_row;
  return v_mail;
end $$;

-- 확정 메일 (학생 한국어 · 강사 영어), 한 번 처리한 결과 1통씩. 확정 0회면 안 보냄
create or replace function lms_ttl_confirmed_mail(p_batch uuid)
returns void
language plpgsql security definer set search_path = public as $$
declare
  m0 temp_location_moves;
  st students;
  tu tutors;
  v_name text;
  n integer;
  v_ko text;
  v_en text;
  na integer;
  v_ko_admin text;
  v_en_admin text;
  v_lines text[];
  v_paras text[];
  v_row uuid;
  v_mail uuid;
begin
  select * into m0 from temp_location_moves where batch_id = p_batch limit 1;
  if not found then return; end if;
  select * into st from students where id = m0.student_id;
  select * into tu from tutors where id = m0.tutor_id;
  v_name := lms_student_en(st);
  select count(*),
         string_agg(lms_ttl_ko_move(m.orig_starts_at, m.new_starts_at, st.timezone), E'\n' order by m.orig_starts_at),
         string_agg(lms_mail_en_at(m.orig_starts_at, lms_tutor_tz_at(m.tutor_id, m.orig_starts_at)) || E'\n→ '
                    || lms_mail_en_at(m.new_starts_at, lms_tutor_tz_at(m.tutor_id, m.new_starts_at)), E'\n' order by m.orig_starts_at)
    into n, v_ko, v_en
  from temp_location_moves m where m.batch_id = p_batch and m.state = 'confirmed';
  if coalesce(n, 0) = 0 then return; end if;
  select count(*),
         string_agg(lms_ttl_ko_at(m.orig_starts_at, st.timezone), E'\n' order by m.orig_starts_at),
         string_agg(lms_mail_en_at(m.orig_starts_at, lms_tutor_tz_at(m.tutor_id, m.orig_starts_at)), E'\n' order by m.orig_starts_at)
    into na, v_ko_admin, v_en_admin
  from temp_location_moves m where m.batch_id = p_batch and m.state = 'admin';

  v_lines := array[tu.name || ' 선생님 수업 ' || n || '회의 시간이 바뀌었어요.', v_ko];
  if na > 0 then
    v_lines := v_lines || ('아래 ' || na || '회는 다른 수업과 시간이 겹쳐서 운영진이 확인하고 있어요.' || E'\n' || v_ko_admin);
  end if;
  insert into temp_location_mails (kind, tutor_id, student_id, batch_id) values ('confirmed_student', m0.tutor_id, m0.student_id, p_batch)
  on conflict do nothing returning id into v_row;
  if v_row is not null then
    v_mail := lms_ttl_student_mail(st.id, 'ttl_confirmed', 'ttl_confirmed_student:' || p_batch,
      '[엣지영어] 수업 시간이 바뀌었어요', v_lines, null);
    update temp_location_mails set notification_id = v_mail where id = v_row;
  end if;

  v_paras := array['The new class times for ' || v_name || ' are confirmed (' || n || ' classes).', v_en];
  if na > 0 then
    v_paras := v_paras || (na || case when na = 1 then ' class' else ' classes' end || ' could not be confirmed because the time was already booked.' || E'\n'
                           || 'Edge English will set a new time.' || E'\n' || v_en_admin);
  end if;
  v_row := null;
  insert into temp_location_mails (kind, tutor_id, student_id, batch_id) values ('confirmed_tutor', m0.tutor_id, m0.student_id, p_batch)
  on conflict do nothing returning id into v_row;
  if v_row is not null then
    v_mail := lms_tutor_mail(m0.tutor_id, st.id, 'ttl_confirmed', 'ttl_confirmed_tutor:' || p_batch,
      '[Edge English] New class times confirmed – ' || v_name, v_paras, false);
    update temp_location_mails set notification_id = v_mail where id = v_row;
  end if;
end $$;

-- 메일을 부르는 곳 (나머지는 20261123140000 그대로): 강사 신청 → 확인 메일 · 학생 신청/동의 · 운영진 시간 넣기 → 확정 메일
create or replace function lms_ttl_submit(p_tutor uuid, p_student uuid, p_items jsonb, p_by text)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  it jsonb;
  r record;
  v_batch uuid := gen_random_uuid();
  v_at timestamptz;
  c text;
  st text;
  n_ok integer := 0;
  n_admin integer := 0;
  n_sent integer := 0;
  v_weeks jsonb := '[]'::jsonb;
  w record;
begin
  perform pg_advisory_xact_lock(hashtextextended('ttl:' || p_tutor, 0));
  if exists (select 1 from regular_change_requests q where q.student_id = p_student and q.status = 'pending') then
    raise exception '%', case when p_by = 'tutor' then 'The student has a pending regular schedule change. Please try again after it is processed.'
                              else '정규 시간 변경 신청이 처리된 뒤에 고를 수 있어요.' end using hint = 'ttl';
  end if;
  if exists (select 1 from temp_location_moves m where m.tutor_id = p_tutor and m.student_id = p_student and m.state = 'proposed') then
    raise exception '%', case when p_by = 'tutor' then 'Waiting for the student to confirm your last request.'
                              else '선생님이 신청한 수업 시간을 먼저 확인해 주세요.' end using hint = 'ttl';
  end if;
  if jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then
    raise exception '%', case when p_by = 'tutor' then 'Choose at least one class.' else '고른 수업이 없어요.' end using hint = 'ttl';
  end if;
  for it in select * from jsonb_array_elements(p_items) loop
    select * into r from lms_ttl_rows(p_tutor, p_student) x where x.key = it ->> 'key';
    if not found or not (r.state is null or r.state in ('later', 'returned')) then
      raise exception '%', case when p_by = 'tutor' then 'This class was already handled. Please reopen the list.'
                                else '이미 처리된 수업이 있어요. 창을 닫고 다시 열어 주세요.' end using hint = 'ttl';
    end if;
    if (it ->> 'later')::boolean is true then
      perform lms_ttl_save(to_jsonb(r), 'later', null, null, v_batch, p_by, null);
      continue;
    end if;
    v_at := case when (it ->> 'admin')::boolean is true then null else (it ->> 'at')::timestamptz end;
    if v_at is null and (it ->> 'admin')::boolean is not true then
      raise exception '%', case when p_by = 'tutor' then 'Choose a time for every class.' else '시간을 고르지 않은 수업이 있어요.' end using hint = 'ttl';
    end if;
    if p_by = 'tutor' then
      if v_at is not null then
        c := lms_ttl_conflict(r.tutor_id, r.student_id, r.enrollment_id, r.location_id, r.lesson_id, r.orig_starts_at, r.minutes, v_at);
        if c is not null or not lms_tutor_available(r.tutor_id, v_at) then
          raise exception 'One of the times is no longer available (%). Please reopen the list.', coalesce(c, 'hours') using hint = 'ttl';
        end if;
      end if;
      perform lms_ttl_save(to_jsonb(r), 'proposed', v_at, null, v_batch, p_by, null);
      n_sent := n_sent + 1;
    else
      st := lms_ttl_confirm_one(p_tutor, p_student, r.key, v_at, v_batch, p_by);
      if st = 'confirmed' then n_ok := n_ok + 1; else n_admin := n_admin + 1; end if;
      v_weeks := v_weeks || jsonb_build_object('e', r.enrollment_id, 'w', lms_rc_monday((r.orig_starts_at at time zone 'Asia/Seoul')::date));
    end if;
  end loop;
  for w in select distinct (x ->> 'e')::uuid e, (x ->> 'w')::date wk from jsonb_array_elements(v_weeks) x loop
    perform lms_ttl_reseq(w.e, w.wk);
  end loop;
  if p_by = 'tutor' then perform lms_ttl_proposed_mail(p_tutor, p_student, v_batch);
  else perform lms_ttl_confirmed_mail(v_batch); end if;
  return jsonb_build_object('ok', n_ok, 'admin', n_admin, 'sent', n_sent, 'batch', v_batch,
    'left', (select count(*) from lms_ttl_rows(p_tutor, p_student) x where x.state is null or x.state in ('later', 'returned')));
end $$;

create or replace function student_ttl_answer(p_student uuid, p_tutor uuid, p_agree boolean)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_student uuid := lms_screen_student(p_student);
  r record;
  v_batch uuid := gen_random_uuid();
  st text;
  n_ok integer := 0;
  n_admin integer := 0;
  w record;
begin
  perform pg_advisory_xact_lock(hashtextextended('ttl:' || p_tutor, 0));
  if not exists (select 1 from temp_location_moves m where m.tutor_id = p_tutor and m.student_id = v_student and m.state = 'proposed') then
    raise exception '이미 답한 신청이에요. 창을 닫고 다시 열어 주세요.' using hint = 'ttl';
  end if;
  if p_agree and exists (select 1 from regular_change_requests q where q.student_id = v_student and q.status = 'pending') then
    raise exception '정규 시간 변경 신청이 처리된 뒤에 동의할 수 있어요.' using hint = 'ttl';
  end if;
  for r in select * from lms_ttl_rows(p_tutor, v_student) x where x.state = 'proposed' order by x.orig_starts_at loop
    if p_agree then
      st := lms_ttl_confirm_one(p_tutor, v_student, r.key, r.new_starts_at, v_batch, 'student');
      if st = 'confirmed' then n_ok := n_ok + 1; else n_admin := n_admin + 1; end if;
    else
      perform lms_ttl_save(to_jsonb(r), 'returned', null, null, v_batch, 'student', null);
    end if;
  end loop;
  -- 수업이 취소돼 대상에서 빠진 신청 줄은 그대로 두면 다시 막으므로 '나중에'로 돌림
  update temp_location_moves set state = 'later', new_starts_at = null where tutor_id = p_tutor and student_id = v_student and state = 'proposed';
  if p_agree then
    for w in select distinct m.enrollment_id e, lms_rc_monday((m.orig_starts_at at time zone 'Asia/Seoul')::date) wk
             from temp_location_moves m where m.batch_id = v_batch loop
      perform lms_ttl_reseq(w.e, w.wk);
    end loop;
  end if;
  if p_agree then perform lms_ttl_confirmed_mail(v_batch); end if;
  return jsonb_build_object('ok', n_ok, 'admin', n_admin, 'agree', p_agree,
    'left', (select count(*) from lms_ttl_rows(p_tutor, v_student) x where x.state is null or x.state in ('later', 'returned')));
end $$;

create or replace function admin_ttl_resolve(p_move uuid, p_starts_at timestamptz)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  m temp_location_moves;
  r record;
  st text;
  v_batch uuid := gen_random_uuid();
begin
  if not is_admin() then raise exception '운영자(추가 인증 완료)만 처리할 수 있습니다.' using errcode = '42501'; end if;
  select * into m from temp_location_moves where id = p_move;
  if not found or m.state <> 'admin' then raise exception '이미 처리된 회차입니다.'; end if;
  perform pg_advisory_xact_lock(hashtextextended('ttl:' || m.tutor_id, 0));
  if p_starts_at is null then
    update temp_location_moves set state = 'admin_done', by_kind = 'admin', decided_at = now() where id = m.id;
    return jsonb_build_object('state', 'admin_done');
  end if;
  select * into r from lms_ttl_rows(m.tutor_id, m.student_id) x where x.move_id = m.id;
  st := lms_ttl_confirm_one(m.tutor_id, m.student_id, r.key, p_starts_at, v_batch, 'admin');
  if st <> 'confirmed' then
    raise exception '그 시간에는 넣을 수 없습니다 (%).', (select conflict from temp_location_moves where id = m.id);
  end if;
  perform lms_ttl_reseq(m.enrollment_id, lms_rc_monday((m.orig_starts_at at time zone 'Asia/Seoul')::date));
  perform lms_ttl_confirmed_mail(v_batch);
  return jsonb_build_object('state', st);
end $$;

revoke all on function lms_ttl_needs_move(uuid), lms_ttl_rows(uuid, uuid), lms_ttl_save(jsonb, text, timestamptz, text, uuid, text, uuid),
  lms_ttl_ko_at(timestamptz, text), lms_ttl_ko_move(timestamptz, timestamptz, text),
  lms_ttl_student_mail(uuid, text, text, text, text[], text), lms_ttl_pick_mail(uuid, uuid, uuid, uuid), lms_ttl_mail_run(),
  lms_ttl_proposed_mail(uuid, uuid, uuid), lms_ttl_confirmed_mail(uuid), lms_ttl_submit(uuid, uuid, jsonb, text) from public, anon, authenticated;
grant execute on function student_ttl_answer(uuid, uuid, boolean), admin_ttl_resolve(uuid, timestamptz) to authenticated;

-- 15분마다 확인 (pg_cron 이 있는 Supabase 에서만)
do $$
begin
  if to_regnamespace('cron') is not null then
    perform cron.schedule('lms-ttl-mail', '*/15 * * * *', 'select lms_ttl_mail_run(); select lms_mail_run();');
  end if;
end $$;
