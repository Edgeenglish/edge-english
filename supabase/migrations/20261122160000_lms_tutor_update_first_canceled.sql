-- =====================================================================
-- 강사 Home 'New student' 줄: 첫 수업을 학생이 취소했으면 실제 첫 수업을 보여 줌 (2026-11-22 대표 '어')
--   First class: Wed, 25 Nov · 20 min · 8 classes
--   Mon, 23 Nov class canceled by student
--  tutor_updates_feed 의 신규 배정 줄에 first_actual·first_canceled 를 더하고, 실제 첫 수업이 끝날 때까지 보이게 함
--  등록 회차·수강 시작일은 바꾸지 않음. 메일 없음
-- =====================================================================
do $$
declare
  d text := pg_get_functiondef('tutor_updates_feed(uuid)'::regprocedure);
  a text := E'''at'', coalesce(u.info ->> ''first'', u.info ->> ''from'', u.info ->> ''to''), ''info'', u.info) as r\n    from tutor_updates u join students s on s.id = u.student_id\n    where u.tutor_id = me and u.visible_until > now()';
  b text := E'''at'', coalesce(u.info ->> ''first'', u.info ->> ''from'', u.info ->> ''to''), ''info'', u.info || coalesce(fx.extra, ''{}''::jsonb)) as r\n'
    || E'    from tutor_updates u join students s on s.id = u.student_id\n'
    || E'    left join lateral (\n'
    || E'      select case when f0.state = ''canceled'' and f1.starts_at is not null then jsonb_build_object(''first_actual'', f1.starts_at, ''first_canceled'', f0.starts_at) end as extra, f1.ends_at as actual_end\n'
    || E'      from (select 1) z\n'
    || E'      left join lateral (select l.state, l.starts_at from lessons l where u.kind = ''new_student'' and l.student_id = u.student_id and l.tutor_id = me and l.kind = ''regular''\n'
    || E'                         and l.voided_at is null and l.starts_at = (u.info ->> ''first'')::timestamptz limit 1) f0 on true\n'
    || E'      left join lateral (select l.starts_at, l.ends_at from lessons l where u.kind = ''new_student'' and l.student_id = u.student_id and l.tutor_id = me and l.kind = ''regular''\n'
    || E'                         and l.voided_at is null and l.state = ''scheduled'' and l.starts_at > (u.info ->> ''first'')::timestamptz order by l.starts_at limit 1) f1 on true\n'
    || E'    ) fx on true\n'
    || E'    where u.tutor_id = me and (u.visible_until > now() or (fx.extra is not null and fx.actual_end > now()))';
begin
  if (length(d) - length(replace(d, a, ''))) / length(a) <> 1 then raise exception '자리 못 찾음'; end if;
  execute replace(d, a, b);
end $$;
