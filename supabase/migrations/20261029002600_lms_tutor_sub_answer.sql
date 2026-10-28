-- =====================================================================
-- 강사 화면에서 대체 수업 요청에 가능/불가 답하기 (2026-10-28 대표: 대표와 강사 사이 WhatsApp 대화 줄이기)
--  - 정책 원본 H26(27): 대체강사는 운영진이 골라 학생에게 제안 (학생이 강사를 고르지 않음). 강사는 운영진이 고른 수업에 답만
--  - 가능 → 휴무 화면 1단계의 '가능한 수업 저장'(admin_leave_sub_ok)과 같은 결과 (학생에게 제안할 수 있게 됨)
--  - 불가 → 그 수업은 다시 '대체 강사 고르기 필요'로, 그 강사는 이 수업의 대체 강사 목록에서 '불가'로 보임 (leave_items.sub_declined)
--  - 운영자(TOTP)도 강사 화면에서 같은 함수로 대신 답할 수 있음. 강사 화면에는 휴무 강사 이름을 보이지 않음
-- 기존 표·데이터를 지우지 않음. 다시 실행해도 같은 결과
-- =====================================================================

alter table leave_items add column if not exists sub_declined uuid[] not null default '{}';

create or replace function tutor_sub_answer(p_items uuid[], p_yes uuid[])
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  it leave_items;
  v_yes uuid[] := coalesce(p_yes, '{}');
  v_changed integer := 0;
begin
  if exists (select 1 from unnest(v_yes) y where y <> all(coalesce(p_items, '{}'))) then
    raise exception 'Unknown class in your answer. Please reload the page.';
  end if;
  perform set_config('app.actor_id', me::text, true);
  perform set_config('app.actor_via', case when is_admin() then 'admin_sub_answer' else 'tutor_sub_answer' end, true);
  for it in select * from leave_items where id = any(p_items) order by starts_at for update loop
    if not (is_admin() or (my_tutor_id() is not null and it.sub_tutor_id = my_tutor_id())) then
      raise exception 'This is not your cover request.' using errcode = '42501';
    end if;
    if it.choice <> 'substitute' or it.sub_stage <> 'asked' then
      raise exception 'This cover request is already closed. Please reload the page.' using hint = 'closed';
    end if;
    -- 강사가 화면에서 답했으면 WhatsApp으로 물어볼 글은 보낼 필요 없음 (이미 보냈으면 그대로)
    update lesson_notices set status = 'not_needed' where leave_item_id = it.id and event = 'sub_ask' and status = 'pending';
    if it.id = any(v_yes) then
      if it.starts_at <= now() then raise exception 'This class has already started.'; end if;
      update leave_items set sub_stage = 'tutor_ok' where id = it.id;
      update lesson_notices set status = 'not_needed', sent_at = null, sent_by = null
      where leave_item_id = it.id and event = 'sub_student' and status = 'sent';
      insert into lesson_notices (leave_item_id, event, recipient_kind, recipient_id) values (it.id, 'sub_student', 'student', it.student_id);
    else
      update leave_items set choice = 'undecided', sub_tutor_id = null, sub_stage = null, sub_lesson_id = null, decided_at = null, decided_by = null,
                             sub_declined = case when it.sub_tutor_id = any(sub_declined) then sub_declined else sub_declined || it.sub_tutor_id end
      where id = it.id;
    end if;
    v_changed := v_changed + 1;
  end loop;
  return jsonb_build_object('changed', v_changed, 'yes', cardinality(v_yes));
end $$;
revoke all on function tutor_sub_answer(uuid[], uuid[]) from public, anon;
grant execute on function tutor_sub_answer(uuid[], uuid[]) to authenticated;

create or replace function admin_leave_sub_options(p_items uuid[])
returns table (tutor_id uuid, name text, timezone text, free integer, busy_dates text[])
language plpgsql stable security definer set search_path = public as $$
begin
  if not is_admin() then raise exception '운영자(추가 인증 완료)만 볼 수 있습니다.' using errcode = '42501'; end if;
  return query
  select t.id, t.name, t.timezone,
         count(*) filter (where lms_sub_conflict(t.id, i.starts_at, i.ends_at, i.lesson_id) is null and not t.id = any(i.sub_declined))::int,
         coalesce(array_agg(to_char(i.starts_at at time zone 'Asia/Seoul', 'FMMM/FMDD') order by i.starts_at)
                  filter (where lms_sub_conflict(t.id, i.starts_at, i.ends_at, i.lesson_id) is not null or t.id = any(i.sub_declined)), '{}')
  from tutors t cross join leave_items i
  where i.id = any(p_items) and t.id <> i.tutor_id and t.active
  group by t.id, t.name, t.timezone
  order by 4 desc, t.name;
end $$;
revoke all on function admin_leave_sub_options(uuid[]) from public, anon;
grant execute on function admin_leave_sub_options(uuid[]) to authenticated;

create or replace function tutor_screen(p_tutor uuid, p_from date, p_to date)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_tutor uuid := lms_screen_tutor(p_tutor);
  t tutors;
begin
  if p_from is null or p_to is null or p_to < p_from then raise exception 'Invalid date range.'; end if;
  select * into t from tutors where id = v_tutor;
  return jsonb_build_object(
    'tutor', jsonb_build_object('id', t.id, 'name', t.name, 'timezone', t.timezone, 'meet_url', t.meet_url),
    'lessons', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', l.id, 'starts_at', l.starts_at, 'ends_at', l.ends_at, 'kind', l.kind, 'state', l.state, 'class_status', l.class_status,
        'student', coalesce(s.display_name, s.name_en), 'level', s.level, 'note_url', s.class_note_url,
        'covering', l.original_tutor_id is not null and l.original_tutor_id <> l.tutor_id,
        'makeup_of', o.starts_at,
        'count', lms_lesson_count(l.id),
        'topics', cr.covered_topics, 'remarks', cr.remarks, 'recorded_at', cr.first_submitted_at,
        'locked', exists (select 1 from payroll_items p where p.lesson_id = l.id))
        order by l.starts_at)
      from lessons l
      join students s on s.id = l.student_id
      left join lessons o on o.id = l.makeup_of
      left join class_records cr on cr.lesson_id = l.id
      where l.tutor_id = v_tutor and l.voided_at is null
        and (l.kst_date between p_from and p_to
             or (l.state = 'scheduled' and l.starts_at <= now()
                 and l.starts_at >= (select min(u.created_at) from app_users u where u.tutor_id = v_tutor)))), '[]'::jsonb),
    -- 기록할 수업: 시작했는데 결과가 없는 수업 (강사 LMS 계정이 생긴 뒤 시작한 수업만 — 그 전 수업은 시트에 기록됨)
    'to_record', coalesce((
      select jsonb_agg(l.id order by l.starts_at)
      from lessons l
      where l.tutor_id = v_tutor and l.state = 'scheduled' and l.voided_at is null and l.starts_at <= now()
        and l.starts_at >= (select min(u.created_at) from app_users u where u.tutor_id = v_tutor)), '[]'::jsonb),
    'makeups', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', r.id, 'student', coalesce(s.display_name, s.name_en),
        'original_at', src.starts_at, 'original_date', mi.original_date,
        'note', r.tutor_note, 'answered_at', r.tutor_answered_at,
        'slots', (select jsonb_agg(jsonb_build_object(
                    'id', c.id, 'starts_at', c.starts_at, 'ends_at', c.ends_at, 'answer', c.tutor_answer,
                    'busy', lms_makeup_conflict(r.tutor_id, r.student_id, c.starts_at, c.ends_at, true) is not null, 'past', c.starts_at <= now())
                    order by c.starts_at)
                  from makeup_candidates c where c.request_id = r.id and c.proposed_by = 'student'))
        order by r.created_at)
      from makeup_requests r
      join students s on s.id = r.student_id
      left join lessons src on src.id = r.source_lesson_id
      left join migrated_items mi on mi.id = r.migrated_item_id
      where r.tutor_id = v_tutor and r.status in ('requested', 'countered')), '[]'::jsonb),
    -- 대체 수업 요청: 운영진이 이 강사를 대체강사로 골라 답을 기다리는 수업 (2600). 휴무 강사 이름은 안 보임
    'covers', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', i.id, 'student', coalesce(s.display_name, s.name_en), 'starts_at', i.starts_at, 'ends_at', i.ends_at,
        'busy', lms_sub_conflict(v_tutor, i.starts_at, i.ends_at, i.lesson_id) is not null)
        order by i.starts_at)
      from leave_items i join students s on s.id = i.student_id
      where i.sub_tutor_id = v_tutor and i.choice = 'substitute' and i.sub_stage = 'asked' and i.starts_at > now()), '[]'::jsonb));
end $$;
revoke all on function tutor_screen(uuid, date, date) from public, anon;
grant execute on function tutor_screen(uuid, date, date) to authenticated;
