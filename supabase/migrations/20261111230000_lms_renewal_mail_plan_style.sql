-- 재등록 안내 메일 모양 통일 (대표 11/11): 1개월도 3·6개월처럼 굵은 제목 + 아래 줄 가격, 세 코스 모두 💜 (📍·🔥 없앰). 그 밖의 문구·규칙은 그대로
create or replace function lms_renewal_mail(p_enrollment uuid, p_stage text, p_left int) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_live boolean := coalesce((select x.enabled from feature_flags x where x.key = 'send_emails'), false);
  e enrollments;
  st students;
  v_tz text;
  v_intended text;
  v_to text;
  v_end timestamptz;
  v_end_text text;
  v_plans jsonb;
  v_first text;
  v_second text;
  v_subject text;
  v_zone_line text := '';
  v_foot text := '문의: 카카오톡 채널 엣지영어';
  v_card text := 'https://tangerineenglish.imweb.me/?idx=11';
  v_paras text[];
  p text;
  v_text text;
  v_html text := '';
  v_id uuid;
begin
  select * into e from enrollments where id = p_enrollment;
  select * into st from students where id = e.student_id;
  v_intended := lms_notice_recipient_email('student', st.id);
  if v_intended is null then return null; end if;
  v_to := case when v_live then v_intended else 'support@edgeenglish.kr' end;
  v_tz := coalesce(nullif(st.timezone, ''), 'Asia/Seoul');
  -- 종료일 23:59 KST 를 학생 거주지 시간으로 (한국이면 날짜만)
  v_end := ((e.final_end_date + 1)::timestamp at time zone 'Asia/Seoul') - interval '1 minute';
  v_end_text := lms_mail_ko_date(v_end, v_tz) || case when v_tz = 'Asia/Seoul' then '' else ' ' || lms_mail_ko_clock(v_end, v_tz) || '까지' end;
  if v_tz <> 'Asia/Seoul' then
    v_zone_line := '모든 시간은 ' || regexp_replace(lms_mail_ko_zone(v_tz), ' 시간$', '') || ' 시간대 기준이에요.';
  end if;
  v_plans := lms_renewal_plans(e.duration_min, e.weekly_count);
  v_first := '안녕하세요 ' || st.name_ko || '님☺️' || E'\n'
    || case p_stage
         when 'ended' then '엣지영어 수강기간 수업이 모두 끝났어요!'
         else '엣지영어 수업이 ' || (case p_stage when 'one' then 1 else 2 end) || '회 남았어요!' end
    || ' (종료일: ' || v_end_text || ')';
  v_second := case p_stage
    when 'ended' then '종료일까지 재등록 결제를 마치시면' || E'\n' || '지금 수업 요일·시간이 그대로 유지돼요.'
    else '지금 재등록하시면' || E'\n' || '잔여 수업이 있다면 다음 수강 기간으로 이월되고, 기존 수업 요일·시간도 그대로 유지돼요.' end;
  v_subject := case when v_live then '' else '[시험 · ' || st.code || '] ' end
    || '[엣지영어] ' || case p_stage when 'ended' then '수강기간 수업이 모두 끝났어요' when 'one' then '수업이 1회 남았어요' else '수업이 2회 남았어요' end;
  v_paras := array[v_first, v_second];
  -- 가격표에 없는 코스는 코스·가격 부분을 뺌 (가격을 짐작하지 않음)
  if v_plans is not null then
    v_paras := v_paras || array[
      '**현재 수강 코스: ' || e.duration_min || '분 주 ' || e.weekly_count || '회 (월 ' || (e.weekly_count * 4) || '회)**',
      '💜 **1개월 (4주)**' || E'\n' || to_char((v_plans ->> 'monthly')::int, 'FM999,999,999') || '원',
      '💜 **3개월 (12주) | 5% 할인**' || E'\n' || to_char((v_plans #>> '{three,total}')::int, 'FM999,999,999') || '원 (월 '
        || to_char((v_plans #>> '{three,per_month}')::int, 'FM999,999,999') || '원)' || E'\n→ '
        || to_char((v_plans #>> '{three,save}')::int, 'FM999,999,999') || '원 절약!',
      '💜 **6개월 (24주) | 최대 혜택**' || E'\n' || to_char((v_plans #>> '{six,total}')::int, 'FM999,999,999') || '원 (월 약 '
        || to_char((v_plans #>> '{six,per_month}')::int, 'FM999,999,999') || '원)' || E'\n→ '
        || to_char((v_plans #>> '{six,save}')::int, 'FM999,999,999') || '원 절약 + Ebook 패키지 무료!'];
  end if;
  v_paras := v_paras || array[
    '💳 결제 안내' || E'\n' || '계좌이체' || E'\n' || '카카오뱅크 3333-27-7626253' || E'\n' || '이진솔(탠저린 영어)' || E'\n\n' || '카드결제' || E'\n' || v_card,
    '문의사항 있으시면 편하게 답장 주세요! ☺️'];
  v_text := '';
  foreach p in array v_paras loop
    v_text := v_text || replace(p, '**', '') || E'\n\n';
    v_html := v_html || '<p>'
      || regexp_replace(regexp_replace(replace(lms_html(p), E'\n', '<br>'), '\*\*(.+?)\*\*', '<b>\1</b>', 'g'),
                        '(https://[^\s<]+)', '<a href="\1">\1</a>', 'g')
      || '</p>';
  end loop;
  v_text := v_text || case when v_zone_line <> '' then v_zone_line || E'\n' else '' end || v_foot
    || case when v_live then '' else E'\n\n(시험 발송 · 원래 받는 사람: ' || v_intended || ')' end;
  v_html := '<div style="font-family:sans-serif;font-size:15px;line-height:1.6;color:#1d1b2a;max-width:480px">'
    || case when v_live then '' else '<p style="background:#fff4d6;color:#5c3b00;border-radius:8px;padding:8px 10px;font-size:13px;font-weight:600">시험 발송 · 원래 받는 사람: ' || lms_html(v_intended) || '</p>' end
    || v_html
    || '<p style="font-size:12.5px;color:#55526a;border-top:1px solid #e6e3ef;padding-top:10px">'
    || case when v_zone_line <> '' then lms_html(v_zone_line) || '<br>' else '' end || lms_html(v_foot) || '</p></div>';
  insert into notifications (recipient_kind, recipient_id, email, locale, template, payload, dedupe_key)
  values ('student', st.id, v_to, 'ko', 'renewal_' || p_stage,
          jsonb_build_object('intended_email', v_intended, 'subject', v_subject, 'html', v_html, 'text', v_text,
                             'enrollment_id', e.id, 'stage', p_stage, 'lessons_left', p_left),
          'renewal_mail:' || e.id || ':' || p_stage)
  on conflict (dedupe_key) do nothing
  returning id into v_id;
  if v_id is not null then perform lms_mail_dispatch(v_id); end if;
  return v_id;
end $$;
revoke all on function lms_renewal_mail(uuid, text, int) from public, anon, authenticated;
