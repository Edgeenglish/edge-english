-- 학생 홈·내 정보 (11/11 대표 지시: 최신 통합 시안)
--  ① 공지 확인 여부: 학생이 공지를 열면 '확인함' (공지별 저장). 운영자 보기로 열어도 학생 확인으로 남기지 않음
--  ② 내 수강권 '현재·지난 수강권 / 결제 내역': 실제 등록·결제 기록만 (금액·카드 정보는 안 보냄, POL-PAY-11)
create table if not exists announcement_reads (
  announcement_id uuid not null references announcements(id),
  student_id uuid not null references students(id),
  read_at timestamptz not null default now(),
  primary key (announcement_id, student_id)
);
alter table announcement_reads enable row level security;

create or replace function student_notices(p_student uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_student uuid := lms_screen_student(p_student);
  v_today date := (now() at time zone 'Asia/Seoul')::date;
begin
  return coalesce((
    select jsonb_agg(jsonb_build_object('id', a.id, 'title', a.title, 'body', a.body, 'starts_on', a.starts_on,
             'read', exists (select 1 from announcement_reads r where r.announcement_id = a.id and r.student_id = v_student))
           order by a.starts_on desc, a.created_at desc)
    from announcements a
    where a.ended_at is null and a.starts_on <= v_today and a.ends_on >= v_today and a.audience in ('student', 'both')), '[]'::jsonb);
end $$;

create or replace function student_notice_read(p_student uuid, p_announcement uuid) returns void
language plpgsql security definer set search_path = public as $$
declare v_student uuid := lms_screen_student(p_student);
begin
  if is_admin() then return; end if;  -- 운영자 보기로 연 것은 학생 확인이 아님
  if not exists (select 1 from announcements a where a.id = p_announcement and a.audience in ('student', 'both')) then
    raise exception '공지를 찾을 수 없어요.' using errcode = '22023';
  end if;
  insert into announcement_reads(announcement_id, student_id) values (p_announcement, v_student)
  on conflict do nothing;
end $$;

create or replace function student_enrollment_history(p_student uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_student uuid := lms_screen_student(p_student);
  v_current uuid := lms_student_enrollment(v_student);
begin
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'id', e.id, 'current', e.id = v_current, 'status', e.status,
             'duration_min', e.duration_min, 'weekly_count', e.weekly_count, 'weeks', e.weeks, 'legacy_label', e.legacy_label,
             'start_date', e.start_date, 'final_end_date', e.final_end_date,
             'method', (select p.method from payments p where p.enrollment_id = e.id order by p.confirmed_at desc limit 1),
             'confirmed_on', (select min((p.confirmed_at at time zone 'Asia/Seoul')::date) from payments p where p.enrollment_id = e.id))
           order by e.seq desc)
    from enrollments e where e.student_id = v_student and e.status <> 'canceled'), '[]'::jsonb);
end $$;

revoke all on function student_notices(uuid) from public, anon;
revoke all on function student_notice_read(uuid, uuid) from public, anon;
revoke all on function student_enrollment_history(uuid) from public, anon;
grant execute on function student_notices(uuid) to authenticated;
grant execute on function student_notice_read(uuid, uuid) to authenticated;
grant execute on function student_enrollment_history(uuid) to authenticated;
