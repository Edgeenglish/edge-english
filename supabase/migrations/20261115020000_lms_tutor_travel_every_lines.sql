-- 강사 해외 이동 기간 4차 QA ① (정책 원본 H26(182)): 강사 메일의 매주 시간 줄도 지역이 바뀌면 지역마다 나눔
--  'Every Mon 9:00 PM *Sydney Time* / 7:00 PM *KST*' + 줄바꿈 + 'From Thu, 24 Dec: Every Mon, Thu 7:00 AM *Buenos Aires Time* / 7:00 PM *KST*'
--  화면 src/lms/admin/time-text.ts enEveryLines 와 같은 규칙. 이동 기간이 없으면 lms_mail_en_every 한 줄 그대로 (전과 같음)
--  끝: p_last(마지막 수업) 또는 p_count(횟수). 둘 다 없으면 이 강사의 실제 수업이 있는 회차만 (없으면 26주)
create or replace function public.lms_tutor_every(p_tutor uuid, p_every timestamptz[], p_last timestamptz, p_count int)
 returns text language plpgsql stable security definer set search_path to 'public' as $function$
declare
  v_first timestamptz;
  v_cap timestamptz;
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
  if not exists (select 1 from tutor_locations where tutor_id = p_tutor) then
    return lms_mail_en_every(p_every, lms_tutor_tz_at(p_tutor, (p_every)[1]));
  end if;
  select min(x) into v_first from unnest(p_every) x;
  v_cap := coalesce(p_last, case when p_count is null then v_first + interval '26 weeks' end);
  for k in 0..119 loop
    exit when v_cap is not null and v_first + make_interval(days => 7 * k) > v_cap;
    foreach e in array p_every loop
      t := e + make_interval(days => 7 * k);
      if v_cap is null or t <= v_cap then occ := occ || t; end if;
    end loop;
    exit when p_count is not null and coalesce(array_length(occ, 1), 0) >= p_count;
  end loop;
  select array_agg(x order by x) into occ from unnest(occ) x;
  if p_count is not null then occ := occ[1:p_count]; end if;
  if p_last is null and p_count is null then
    -- 끝을 모르면 실제 수업이 있는 회차만 (정규 시간 변경·첫 수업 안내)
    if exists (select 1 from lessons l where l.tutor_id = p_tutor and l.state <> 'canceled' and l.starts_at = any(occ)) then
      select array_agg(x order by x) into occ from unnest(occ) x
      where exists (select 1 from lessons l where l.tutor_id = p_tutor and l.state <> 'canceled' and l.starts_at = x);
    end if;
  end if;
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

-- 강사 메일 함수 5개: lms_mail_en_every(X, lms_tutor_tz_at(tu.id, (X)[1])) → lms_tutor_every(tu.id, X, 끝, 횟수)
do $mig$
declare
  f record;
  def text;
  n int := 0;
begin
  for f in select p.oid, p.proname from pg_proc p join pg_namespace s on s.oid = p.pronamespace
           where s.nspname = 'public' and p.proname in ('lms_plan_confirmed_notice', 'lms_plan_request_notice', 'lms_plan_nudge_run',
             'lms_regular_change_notice', 'lms_tutor_first_class_mail') loop
    def := pg_get_functiondef(f.oid);
    def := regexp_replace(def, 'lms_mail_en_every\(([a-z_.]+), lms_tutor_tz_at\(tu\.id, \(\1\)\[1\]\)\)',
      case f.proname when 'lms_plan_confirmed_notice' then 'lms_tutor_every(tu.id, \1, x.last_at, null)'
                     when 'lms_plan_request_notice' then 'lms_tutor_every(tu.id, \1, null, e.lessons_purchased::int)'
                     when 'lms_plan_nudge_run' then 'lms_tutor_every(tu.id, \1, null, e.lessons_purchased::int)'
                     else 'lms_tutor_every(tu.id, \1, null, null)' end, 'g');
    if def ~ 'lms_mail_en_every\(' then raise exception '% 에 바꾸지 못한 매주 시간 줄이 남음', f.proname; end if;
    execute def;
    n := n + 1;
  end loop;
  if n <> 5 then raise exception '강사 메일 함수 5개를 찾지 못함 (%)', n; end if;
end $mig$;
