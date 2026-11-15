-- 강사 해외 이동 기간 재QA (정책 원본 H26(184) 뒤): 매주 시간 줄의 지역 나눔을 '그 학생 수강권의 실제 수업 범위'로만
--  · lms_tutor_every: 끝(p_last)·횟수(p_count)를 모르면 나누지 않고 한 줄 (다른 학생 수업·26주 추정을 쓰지 않음)
--  · 첫 수업 안내 메일: 끝 = 그 수강권 마지막 정규 수업
--  · 정규 시간 변경 메일·Updates: 끝 = 그 수강권 마지막 정규 수업 (Updates info 에 'last' 추가)
create or replace function public.lms_tutor_every(p_tutor uuid, p_every timestamptz[], p_last timestamptz, p_count int)
 returns text language plpgsql stable security definer set search_path to 'public' as $function$
declare
  v_first timestamptz;
  occ timestamptz[] := '{}';
  k int;
  e timestamptz;
  t timestamptz;
  z text;
  cur text;
  seg timestamptz[];
  out text;
begin
  if p_every is null or coalesce(array_length(p_every, 1), 0) = 0 then return null; end if;
  select min(x) into v_first from unnest(p_every) x;
  if (p_last is null and p_count is null) or not exists (select 1 from tutor_locations where tutor_id = p_tutor) then
    return lms_mail_en_every(p_every, lms_tutor_tz_at(p_tutor, v_first));
  end if;
  for k in 0..119 loop
    exit when p_last is not null and v_first + make_interval(days => 7 * k) > p_last;
    foreach e in array p_every loop
      t := e + make_interval(days => 7 * k);
      if p_last is null or t <= p_last then occ := occ || t; end if;
    end loop;
    exit when p_count is not null and coalesce(array_length(occ, 1), 0) >= p_count;
  end loop;
  select array_agg(x order by x) into occ from unnest(occ) x;
  if p_count is not null then occ := occ[1:p_count]; end if;
  foreach t in array occ loop
    z := lms_tutor_tz_at(p_tutor, t);
    if cur is null then cur := z; seg := array[t];
    elsif z = cur then seg := seg || t;
    else
      out := coalesce(out || E'\n' || 'From ' || lms_mail_en_date(seg[1], cur) || ': ', '') || lms_mail_en_every(seg, cur);
      cur := z; seg := array[t];
    end if;
  end loop;
  return coalesce(out || E'\n' || 'From ' || lms_mail_en_date(seg[1], cur) || ': ', '') || lms_mail_en_every(seg, cur);
end $function$;
revoke all on function public.lms_tutor_every(uuid, timestamptz[], timestamptz, int) from public, anon, authenticated;

create or replace function public.lms_course_last_regular(p_enrollment uuid) returns timestamptz
 language sql stable security definer set search_path to 'public' as $function$
  select max(l.starts_at) from lessons l
  where l.enrollment_id = p_enrollment and l.kind = 'regular' and l.voided_at is null and l.state <> 'canceled'
$function$;
revoke all on function public.lms_course_last_regular(uuid) from public, anon, authenticated;

do $mig$
declare
  def text;
begin
  def := pg_get_functiondef('public.lms_regular_change_notice'::regproc);
  if def !~ 'lms_tutor_every\(tu\.id, v_every, null, null\)' or def !~ '''changed'', coalesce\(v_n, 0\)\)' then
    raise exception 'lms_regular_change_notice 모양이 예상과 다름';
  end if;
  def := replace(def, 'lms_tutor_every(tu.id, v_every, null, null)', 'lms_tutor_every(tu.id, v_every, lms_course_last_regular(new.enrollment_id), null)');
  def := replace(def, '''changed'', coalesce(v_n, 0))', '''changed'', coalesce(v_n, 0), ''last'', lms_course_last_regular(new.enrollment_id))');
  execute def;
  def := pg_get_functiondef('public.lms_tutor_first_class_mail(enrollments, lessons, timestamptz[], boolean, text, text, jsonb, text)'::regprocedure);
  if def !~ 'lms_tutor_every\(tu\.id, p_every, null, null\)' then raise exception 'lms_tutor_first_class_mail 모양이 예상과 다름'; end if;
  def := replace(def, 'lms_tutor_every(tu.id, p_every, null, null)', 'lms_tutor_every(tu.id, p_every, lms_course_last_regular(e.id), null)');
  execute def;
end $mig$;
