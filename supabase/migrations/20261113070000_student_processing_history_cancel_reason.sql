-- 학생 처리 내역: 취소 사유(cancel_reason) 한 칸 추가 — 수강생 취소 / 강사가 취소 / 강사 휴무로 취소 / 강사 사정으로 취소 (대표 11/13).
-- 읽기 전용 함수 교체만. 표·데이터·트리거 변경 없음. 다시 실행해도 같은 결과. 화면은 이 칸이 없는 옛 응답에서도 그대로 동작.
-- Read-only student processing history. No backfill, data writes, new triggers or mail.
-- audit_log remains admin-only; return an allowlisted projection after the existing
-- student / AAL2 admin ownership guard. audit.at is processing time, not lesson time.
create or replace function public.student_processing_history(p_student uuid default null)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_student uuid;
begin
  if auth.uid() is null then
    raise exception '학생 계정으로 로그인해 주세요.' using errcode = '42501';
  end if;
  v_student := public.lms_screen_student(p_student);
  return (
    with owned as (
      select a.* from public.lessons l
      join public.audit_log a on a.table_name = 'lessons' and a.row_id = l.id::text
      where l.student_id = v_student and a.new_row->>'student_id' = v_student::text
      union all
      select a.* from public.makeup_requests r
      join public.audit_log a on a.table_name = 'makeup_requests' and a.row_id = r.id::text
      where r.student_id = v_student and a.new_row->>'student_id' = v_student::text
    ), events as (
      select a.*, e.kind, e.step from owned a
      cross join lateral (values
        ('lesson_canceled', 1, a.table_name = 'lessons'
          and (a.new_row->>'state' = 'canceled' or a.new_row->>'class_status' = 'Tutor no-show')
          and not (coalesce(a.old_row->>'state' = 'canceled', false) or coalesce(a.old_row->>'class_status' = 'Tutor no-show', false))),
        ('lesson_restored', 1, a.table_name = 'lessons' and a.new_row->>'state' = 'scheduled'
          and (a.old_row->>'state' = 'canceled' or a.old_row->>'class_status' = 'Tutor no-show')),
        ('makeup_requested', 1, a.table_name = 'makeup_requests' and a.action = 'INSERT'),
        ('tutor_waiting', 2, a.table_name = 'makeup_requests' and a.new_row->>'status' = 'requested'
          and a.new_row->>'status' is distinct from a.old_row->>'status'),
        ('tutor_answered', 3, a.table_name = 'makeup_requests' and a.new_row->>'tutor_answered_at' is not null
          and a.new_row->>'tutor_answered_at' is distinct from a.old_row->>'tutor_answered_at'
          and a.new_row->>'status' <> 'countered'),
        ('tutor_suggested', 3, a.table_name = 'makeup_requests' and a.new_row->>'suggested_at' is not null
          and a.new_row->>'suggested_at' is distinct from a.old_row->>'suggested_at'),
        ('suggestion_declined', 4, a.table_name = 'makeup_requests' and a.new_row->>'student_declined_at' is not null
          and a.new_row->>'student_declined_at' is distinct from a.old_row->>'student_declined_at'),
        ('makeup_confirmed', 5, a.table_name = 'makeup_requests' and a.new_row->>'status' = 'confirmed'
          and a.new_row->>'status' is distinct from a.old_row->>'status'),
        ('makeup_withdrawn', 5, a.table_name = 'makeup_requests' and a.new_row->>'status' = 'withdrawn'
          and a.new_row->>'status' is distinct from a.old_row->>'status'),
        ('makeup_expired', 5, a.table_name = 'makeup_requests' and a.new_row->>'status' = 'expired'
          and a.new_row->>'status' is distinct from a.old_row->>'status'),
        ('makeup_voided', 5, a.table_name = 'makeup_requests' and a.new_row->>'status' = 'voided'
          and a.new_row->>'status' is distinct from a.old_row->>'status')
      ) e(kind, step, include) where e.include
    )
    select coalesce(jsonb_agg(jsonb_build_object(
      'id', e.id::text || ':' || e.kind, 'at', e.at, 'kind', e.kind,
      'request_id', case when e.table_name = 'makeup_requests' then e.row_id end,
      'lesson_at', case when e.table_name = 'lessons' then e.new_row->>'starts_at' else src.starts_at::text end,
      'original_date', mi.original_date,
      'tutor', t.name,
      'compensation', e.new_row->>'compensation_id' is not null,
      'tutor_fault', e.new_row->>'class_status' in ('Tutor no-show', 'Tutor canceled in advance', 'Tutor canceled late', 'Tutor on leave'),
      'cancel_reason', case when e.kind = 'lesson_canceled' then
        case when e.new_row->>'class_status' in ('Tutor long-term leave', 'Tutor on leave') then 'tutor_leave'
             when e.new_row->>'class_status' in ('Tutor canceled in advance', 'Tutor canceled late') then 'tutor_canceled'
             when e.new_row->>'class_status' = 'Tutor no-show' then 'tutor_fault'
             else 'student' end end,
      'booked_at', case when e.kind = 'makeup_confirmed' then booked.new_row->>'starts_at' end,
      'slots', coalesce(slots.items, '[]'::jsonb)
    ) order by e.at desc, e.id desc, e.step desc), '[]'::jsonb)
    from events e
    left join public.lessons src on src.id::text = e.new_row->>'source_lesson_id' and src.student_id = v_student
    left join public.migrated_items mi on mi.id::text = e.new_row->>'migrated_item_id'
      and exists (select 1 from public.enrollments en where en.id = mi.enrollment_id and en.student_id = v_student)
    left join public.tutors t on t.id::text = e.new_row->>'tutor_id'
    left join lateral (
      select a.new_row from public.audit_log a
      where a.table_name = 'lessons' and a.row_id = e.new_row->>'confirmed_lesson_id'
        and a.new_row->>'student_id' = v_student::text and a.at <= e.at
      order by a.at desc, a.id desc limit 1
    ) booked on true
    left join lateral (
      select jsonb_agg(jsonb_build_object('at', x.new_row->>'starts_at', 'answer', x.new_row->>'tutor_answer')
        order by x.new_row->>'starts_at') items
      from (
        select distinct on (a.row_id) a.new_row, a.action
        from public.audit_log a
        where a.table_name = 'makeup_candidates' and coalesce(a.new_row, a.old_row)->>'request_id' = e.row_id and a.at <= e.at
        order by a.row_id, a.at desc, a.id desc
      ) x
      where x.action <> 'DELETE'
        and (case when e.kind = 'tutor_suggested' then x.new_row->>'proposed_by' = 'tutor'
          else x.new_row->>'proposed_by' <> 'tutor' end)
        and e.kind in ('makeup_requested', 'tutor_answered', 'tutor_suggested')
    ) slots on e.table_name = 'makeup_requests'
  );
end $$;
revoke all on function public.student_processing_history(uuid) from public, anon, authenticated;
grant execute on function public.student_processing_history(uuid) to authenticated;
