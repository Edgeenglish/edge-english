-- 이미 수강 중이던 학생에게는 학습 정보 등록 메일 제목에서 '첫 수업'을 뺌 (대표 11/14). 나머지(새 학생)는 그대로
-- 강사가 학습 정보를 다 채웠을 때 학생에게 가는 메일 문구 (대표 11/14)
--  - 본문 '첫 수업을 바탕으로' → '진행했던 수업을 바탕으로' (기존 수강 중인 학생에게도 맞게)
--  - [LMS 열기] 가 '내 정보' 화면을 바로 엶 (/student?tab=me)
--  - 막아 둔(canceled) 옛 기록은 '보냄'으로 치지 않고, 새 기록 키 followup_done_v2 로 한 번만 보냄
create or replace function public.lms_followup_done_mail(p_student uuid, p_tutor uuid)
 returns void
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare
  j jsonb;
  st students;
  v_live boolean := coalesce((select f.enabled from feature_flags f where f.key = 'send_emails'), false);
  v_intended text;
  v_to text;
  v_name text;
  v_style text;
  v_parts text[];
  v_m text;
  v_book text;
  v_mat text;
  v_url text := lms_url();
  v_btn text := 'LMS 열기';
  v_foot1 text := '내용이 다르거나 궁금한 점이 있으시면 편하게 연락 주세요.';
  v_foot2 text := '문의: 카카오톡 채널 엣지영어';
  v_lines text[];
  v_subject text;
  v_body text;
  v_html text;
  v_id uuid;
  v_old boolean := false;
  v_title text;
begin
  j := lms_first_lesson_todo(p_tutor, p_student);
  if j is null or coalesce((j ->> 'pending')::int, 1) > 0 then return; end if;
  if exists (select 1 from notifications n where n.dedupe_key = 'followup_done_v2:' || p_student)
     or exists (select 1 from notifications n where n.dedupe_key = 'followup_done:' || p_student and n.status <> 'canceled') then return; end if;
  select * into st from students where id = p_student;
  -- 이미 수강 중이던 학생(대표 11/14 학습 정보 채우기 목록)은 '첫 수업' 말을 빼고 보냄
  v_old := exists (select 1 from first_lesson_followup_exceptions x where x.student_id = p_student and x.note like '%기존 학생 학습 정보%');
  v_title := case when v_old then '[엣지영어] 강사님이 학습 정보를 등록했어요' else '[엣지영어] 강사님이 첫 수업 학습 정보를 등록했어요' end;
  v_intended := lms_notice_recipient_email('student', p_student);
  if v_intended is null then return; end if;
  v_to := case when v_live then v_intended else 'support@edgeenglish.kr' end;
  v_name := coalesce(nullif(st.name_ko, ''), st.name_en);
  v_book := case when nullif(trim(coalesce(st.textbook, '')), '') is not null then ' (' || st.textbook || ')' else '' end;
  v_mat := case when nullif(trim(coalesce(st.tutor_materials_note, '')), '') is not null then ' (' || st.tutor_materials_note || ')' else '' end;
  v_style := case st.tutor_class_style
    when 'conversation' then '회화'
    when 'textbook' then '교재 중심' || v_book
    when 'student_materials' then '수강생 제공 자료' || v_mat
    else '혼합' end;
  if st.tutor_class_style = 'mixed' then
    v_parts := array[]::text[];
    foreach v_m in array coalesce(st.tutor_class_style_mix, array[]::text[]) loop
      v_parts := v_parts || (case v_m when 'conversation' then '회화' when 'textbook' then '교재' || v_book
                                       when 'student_materials' then '수강생 자료' || v_mat else '기타' end);
    end loop;
    v_style := '혼합: ' || array_to_string(v_parts, ' + ');
  end if;
  v_subject := case when v_live then '' else '[시험 · ' || st.code || '] ' end || v_title;
  v_lines := array[
    v_title,
    '안녕하세요, ' || v_name || '님,',
    '담당 강사님이 진행했던 수업을 바탕으로 ' || v_name || '님 학습 정보를 적어주셨어요.',
    '영어 레벨: ' || coalesce(st.level, '-'),
    '학습 목표: ' || coalesce(st.improve, '-'),
    '수업 방식: ' || v_style,
    '수업 노트: 노트 열기',
    '(매 수업 내용이 이 노트에 계속 쌓여요.)'];
  v_body := v_lines[1] || E'\n\n' || v_lines[2] || E'\n\n' || v_lines[3] || E'\n\n' || v_lines[4] || E'\n' || v_lines[5] || E'\n' || v_lines[6]
            || E'\n수업 노트: ' || st.class_note_url || E'\n' || v_lines[8]
            || E'\n\n' || v_btn || ': ' || v_url || '/student?tab=me' || E'\n\n' || v_foot1 || E'\n' || v_foot2
            || case when v_live then '' else E'\n\n(시험 발송 · 원래 받는 사람: ' || v_intended || ')' end;
  v_html := '<div style="font-family:sans-serif;font-size:15px;line-height:1.6;color:#1d1b2a;max-width:480px">'
            || case when v_live then '' else '<p style="background:#fff4d6;color:#5c3b00;border-radius:8px;padding:8px 10px;font-size:13px;font-weight:600">시험 발송 · 원래 받는 사람: ' || lms_html(v_intended) || '</p>' end
            || '<p style="font-weight:700">' || lms_html(v_lines[1]) || '</p>'
            || '<p>' || lms_html(v_lines[2]) || '</p><p>' || lms_html(v_lines[3]) || '</p>'
            || '<p><b>영어 레벨</b> ' || lms_html(coalesce(st.level, '-')) || '<br><b>학습 목표</b> ' || lms_html(coalesce(st.improve, '-'))
            || '<br><b>수업 방식</b> ' || lms_html(v_style)
            || '<br><b>수업 노트</b> <a href="' || lms_html(st.class_note_url) || '" style="color:#5b3df0;font-weight:700">노트 열기</a>'
            || '<br><span style="color:#55526a">' || lms_html(v_lines[8]) || '</span></p>'
            || '<p><a href="' || lms_html(v_url || '/student?tab=me') || '" style="display:inline-block;background:#5b3df0;color:#fff;border-radius:10px;padding:11px 18px;font-weight:700;text-decoration:none">' || lms_html(v_btn) || '</a></p>'
            || '<p style="font-size:12.5px;color:#55526a;border-top:1px solid #e6e3ef;padding-top:10px">' || lms_html(v_foot1) || '<br>' || lms_html(v_foot2) || '</p></div>';
  insert into notifications (recipient_kind, recipient_id, email, locale, template, payload, dedupe_key)
  values ('student', p_student, v_to, 'ko', 'first_lesson_followup_done',
          jsonb_build_object('intended_email', v_intended, 'subject', v_subject, 'html', v_html, 'text', v_body),
          'followup_done_v2:' || p_student)
  on conflict (dedupe_key) do nothing
  returning id into v_id;
  if v_id is not null then perform lms_mail_dispatch(v_id); end if;
end $function$;
