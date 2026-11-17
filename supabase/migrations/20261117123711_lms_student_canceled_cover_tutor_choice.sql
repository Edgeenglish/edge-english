-- 2026-11-17 대표 승인: 학생이 정상 취소한 대체수업도 원래/대체강사 선택.
-- 학생 직전 취소·결석의 보강 불가, 추가 무료 보상수업 강사 고정은 유지.
create or replace function lms_makeup_tutors(p_lesson uuid, p_item uuid, p_comp uuid)
returns jsonb language sql stable security definer set search_path = public as $$
  with source as (
    select l.tutor_id, case when l.class_status in ('Student canceled in advance', 'Student canceled in advance (public holiday)',
      'Tutor canceled in advance', 'Tutor canceled late', 'Tutor no-show')
      then l.original_tutor_id end as original_id
    from lessons l where p_comp is null and p_item is null and l.id = p_lesson
    union all
    select coalesce(l.original_tutor_id, l.tutor_id), null::uuid
    from migrated_items m cross join lateral (
      select x.tutor_id, x.original_tutor_id from lessons x
      where x.enrollment_id=m.enrollment_id and x.voided_at is null order by x.starts_at desc limit 1
    ) l where p_comp is null and p_lesson is null and m.id=p_item
    union all
    select l.tutor_id, null::uuid from compensations c join lessons l on l.id=c.source_lesson_id where c.id=p_comp
  ), choices as (
    select tutor_id as id, case when original_id is not null and original_id<>tutor_id then 'substitute' else 'assigned' end as role, 1 as ord from source
    union all
    select original_id, 'original', 0 from source where original_id is not null and original_id<>tutor_id
  )
  select coalesce(jsonb_agg(jsonb_build_object('id', t.id, 'name', t.name, 'role', c.role) order by c.ord), '[]'::jsonb)
  from choices c join tutors t on t.id=c.id;
$$;
revoke all on function lms_makeup_tutors(uuid,uuid,uuid) from public,anon,authenticated;

notify pgrst, 'reload schema';
