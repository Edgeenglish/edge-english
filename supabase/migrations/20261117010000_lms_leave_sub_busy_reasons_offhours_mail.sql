-- 강사 휴무 화면 수정 (대표 11/17, 시안 승인):
--  ① 대체 강사 고르기 목록의 '불가' 날짜마다 사유(휴무·다른 수업·현지 06:00~22:30 밖·Schedule에서 막은 시간·불가 답함)
--  ② 대체 수업 요청 메일: 강사 정규 근무시간 밖 수업 줄 끝에 '(outside your regular working hours)' + 그런 수업이 있을 때만 한 문장
-- 함수 1개 추가 + 메일 함수 1개 본문 일부 교체. 표·기존 데이터는 안 바뀜. 다시 실행해도 같은 결과 (이미 바뀌었으면 건너뜀)

create or replace function admin_leave_sub_busy_reasons(p_items uuid[])
returns table (tutor_id uuid, md text, reason text)
language plpgsql stable security definer set search_path = public as $$
begin
  if not is_admin() then raise exception '운영자(추가 인증 완료)만 볼 수 있습니다.' using errcode = '42501'; end if;
  return query
  select t.id, to_char(i.starts_at at time zone 'Asia/Seoul', 'FMMM/FMDD'),
         case
           when c.msg is null then '불가 답함'
           when c.msg = '강사 휴무' then '휴무'
           when c.msg like '강사 다른 수업%' then '다른 수업'
           when c.msg like '강사 현지%' then '현지 06:00~22:30 밖'
           when c.msg like '강사가 열어 둔 시간이 아님%' then 'Schedule에서 막은 시간'
           else '불가'
         end
  from tutors t cross join leave_items i
  cross join lateral (select lms_sub_conflict(t.id, i.starts_at, i.ends_at, i.lesson_id) as msg) c
  where i.id = any(p_items) and t.id <> i.tutor_id and t.active
    and (c.msg is not null or t.id = any(i.sub_declined))
  order by i.starts_at, t.name;
end $$;
revoke all on function admin_leave_sub_busy_reasons(uuid[]) from public, anon;
grant execute on function admin_leave_sub_busy_reasons(uuid[]) to authenticated;

-- 대체 수업 요청 첫 메일: 정규 근무시간 밖 수업 표시 (재촉 메일은 그대로)
do $mig$
declare
  def text := pg_get_functiondef('lms_cover_mail_run(timestamptz,timestamptz,boolean)'::regprocedure);
  a text := $a$q.rn || ') ' || lms_mail_en_at(q.starts_at, lms_tutor_tz_at(tu.id, q.starts_at)) || ' · ' || q.name || ' · ' || q.dur || ' min'$a$;
  b text := $b$'Please open To do on your LMS Home and tick only the classes you can teach. Leave the others unchecked.'];$b$;
  pa int := position(a in def);
  pb int := position(b in def);
begin
  if position('(outside your regular working hours)' in def) > 0 then return; end if;
  if pa = 0 or pb = 0 then raise exception '대체 수업 요청 메일 함수 모양이 달라 바꾸지 못했어요'; end if;
  -- 뒤쪽(문단)부터 바꿔야 앞쪽 위치가 안 밀림
  def := substr(def, 1, pb - 1) || b || E'\n' ||
    $c$    if position('(outside your regular working hours)' in v_list) > 0 then
      v_paras := v_paras[1:2] || array['We know the marked classes are outside your regular working hours, but would you be available to cover any of them? No worries if not!'] || v_paras[3:3];
    end if;$c$ || substr(def, pb + length(b));
  def := substr(def, 1, pa - 1) || a || $d$ || case when lms_tutor_available(tu.id, q.starts_at) then '' else ' (outside your regular working hours)' end$d$ || substr(def, pa + length(a));
  execute def;
end $mig$;
