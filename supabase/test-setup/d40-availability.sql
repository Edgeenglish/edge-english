-- =====================================================================
-- D-40 화면 시험용: 가상 강사 2명의 '수업 가능 시간' (시험용 Supabase 전용, 실제 강사 정보 아님)
-- seed_fake 에는 가능 시간이 없어 등록 화면에서 정규 시간을 고를 칸이 하나도 안 열린다 → 이 파일로 채운다
-- - 가상강사 Alex (시드니): 월~금 18:00~23:00 시드니 시각 (한국 16:00~21:00, 시드니 서머타임 기준)
-- - 가상강사 Blair (토론토): 월~토 06:00~11:00 토론토 시각 (한국 19:00~24:00, 토론토 서머타임 기준 / 11월 2일부터 한 시간 늦어짐)
-- 여러 번 실행해도 같은 행이 두 번 들어가지 않음 (고정 ID + on conflict do nothing). 지우는 명령 없음
-- =====================================================================
begin;
set local app.actor_via = 'seed_fake';

insert into tutor_availability (id, tutor_id, weekday, start_local, end_local, timezone, effective_from)
select ('00000000-7e57-0000-0000-0000000d4' || lpad((t.n * 10 + w)::text, 3, '0'))::uuid,
       t.id, w, t.s, t.e, t.tz, date '2026-10-01'
from (values (1, '00000000-7e57-0000-0000-00000000a001'::uuid, time '18:00', time '23:00', 'Australia/Sydney', 5),
             (2, '00000000-7e57-0000-0000-00000000a002'::uuid, time '06:00', time '11:00', 'America/Toronto', 6)) t(n, id, s, e, tz, last_day)
cross join generate_series(1, 6) w
where w <= t.last_day
  and exists (select 1 from tutors where tutors.id = t.id)   -- 가상 강사가 없는 프로젝트(=시험용이 아님)면 아무것도 넣지 않음
on conflict do nothing;

commit;

select tu.name as 강사, count(*) as 가능요일수, min(a.start_local) as 시작, max(a.end_local) as 끝, a.timezone as 시간대
from tutor_availability a join tutors tu on tu.id = a.tutor_id
where tu.name like '가상강사%'
group by tu.name, a.timezone order by tu.name;
