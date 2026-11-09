-- =====================================================================
-- 강사 Home To-do '취소된 수업' (대표 11/8): 학생이 취소한 앞으로의 수업을 강사가 들어오자마자 봄
--  - 읽기 함수 하나. 표·데이터는 바꾸지 않음. 다시 실행해도 같은 결과
--  - 대상: 이 강사의 아직 안 지난 수업 중 학생이 취소한 것 (일찍 취소·공휴일 취소·늦은 취소). 강사가 직접 취소한 수업은 제외
--  - 그 수업 시간이 지나면 저절로 빠짐 (확인 버튼 없음)
--  - tutorId: 운영자가 고른 강사 (강사 본인은 비움 — lms_screen_tutor 가 가름)
-- =====================================================================
create or replace function tutor_canceled_classes(p_tutor uuid default null)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  me uuid := lms_screen_tutor(p_tutor);
begin
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'id', l.id, 'starts_at', l.starts_at, 'ends_at', l.ends_at, 'kind', l.kind, 'class_status', l.class_status,
             'student', coalesce(s.display_name, s.name_en), 'student_id', s.id) order by l.starts_at)
    from lessons l
    join students s on s.id = l.student_id
    where l.tutor_id = me and l.voided_at is null and l.state = 'canceled' and l.starts_at > now()
      and l.class_status in ('Student canceled in advance', 'Student canceled in advance (public holiday)', 'Student canceled late')), '[]'::jsonb);
end $$;
revoke all on function tutor_canceled_classes(uuid) from public, anon;
grant execute on function tutor_canceled_classes(uuid) to authenticated;
