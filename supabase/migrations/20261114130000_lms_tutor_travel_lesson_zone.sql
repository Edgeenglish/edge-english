-- 강사 해외 이동 기간 후속 (정책 원본 H26(175), 대표 11/14): 강사 Home·강사에게 가는 메일의 수업 시각을
-- '지금 있는 곳'이 아니라 '그 수업 날짜에 설정된 지역' 시간대로 표시. 실제 수업 시각·학생 화면·학생 메일은 그대로
--  · 강사 Home: tutor_travel_periods 로 이동 기간을 읽어 화면에서 수업마다 지역을 정함 (lms_tutor_tz_at 과 같은 규칙)
--  · 강사 메일: 영어 메일 시각 함수(lms_mail_en_*)는 모두 강사 메일에서만 쓰이고, 강사 시간대를 tu.timezone 으로 받음.
--    아래 함수 9개 본문에서 그 자리를 lms_tutor_tz_at(tu.id, 그 시각)으로 바꿈 (매주 반복 'Every …' 는 첫 수업 시각 기준).
--    이동 기간이 없는 강사는 lms_tutor_tz_at = tutors.timezone 이라 결과가 전과 같음

create or replace function tutor_travel_periods(p_tutor uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', l.id, 'city', l.city, 'country', l.country, 'timezone', l.timezone, 'from', l.starts_on, 'to', l.ends_on) order by l.starts_on), '[]'::jsonb)
  from tutor_locations l where l.tutor_id = lms_screen_tutor(p_tutor)
$$;
revoke all on function tutor_travel_periods(uuid) from public, anon;
grant execute on function tutor_travel_periods(uuid) to authenticated;

do $mig$
declare
  f record;
  def text;
  n int := 0;
begin
  for f in select p.oid, p.proname from pg_proc p join pg_namespace s on s.oid = p.pronamespace
           where s.nspname = 'public' and p.proname in ('lms_cover_mail_run', 'lms_makeup_nudge_run', 'lms_notice_mail', 'lms_plan_confirmed_notice',
             'lms_plan_nudge_run', 'lms_plan_request_notice', 'lms_regular_change_notice', 'lms_sub_confirmed_mail', 'lms_tutor_first_class_mail') loop
    def := pg_get_functiondef(f.oid);
    -- ① '… when(시각, tu.timezone) || ' ' || zone(tu.timezone)' → 시간대 이름도 그 시각 기준
    def := regexp_replace(def, 'lms_mail_en_when\(([^;|]*?), tu\.timezone\) \|\| '' '' \|\| lms_mail_en_zone\(tu\.timezone\)',
                          'lms_mail_en_when(\1, lms_tutor_tz_at(tu.id, \1)) || '' '' || lms_mail_en_zone(lms_tutor_tz_at(tu.id, \1))', 'g');
    -- ② at·when·date(시각, tu.timezone)
    def := regexp_replace(def, 'lms_mail_en_(at|when|date)\(([^;|]*?), tu\.timezone\)', 'lms_mail_en_\1(\2, lms_tutor_tz_at(tu.id, \2))', 'g');
    -- ③ every(시각 목록, tu.timezone) → 첫 시각 기준
    def := regexp_replace(def, 'lms_mail_en_every\(([a-z_.]+), tu\.timezone\)', 'lms_mail_en_every(\1, lms_tutor_tz_at(tu.id, (\1)[1]))', 'g');
    if def ~ 'tu\.timezone' then raise exception '강사 메일 시각 바꾸기 실패: % 에 tu.timezone 이 남음', f.proname; end if;
    execute def;
    n := n + 1;
  end loop;
  if n <> 9 then raise exception '강사 메일 함수 9개가 아님: %', n; end if;
end $mig$;
