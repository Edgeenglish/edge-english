-- =====================================================================
-- 첫 수업 Follow-up 완료 → 수강생에게 안내 메일 1번 (대표 2026-11-10, 문구 대표 확정)
--  강사가 Level · Wants to Improve · Class Style · Class Notes 4칸을 모두 저장한 순간 수강생(한국어)에게 1번
--  (같은 수강생에게 다시 보내지 않음: dedupe_key followup_done:수강생)
--  발송은 기존 자동 메일과 같음: send_emails 가 꺼져 있으면 운영진 메일로만 ('[시험 · 수강생 번호]' 표시)
-- 표·기존 데이터는 바꾸지 않음. 다시 실행해도 같은 결과
-- =====================================================================
create or replace function lms_followup_done_mail(p_student uuid, p_tutor uuid) returns void
language plpgsql security definer set search_path = public as $$
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
begin
  j := lms_first_lesson_todo(p_tutor, p_student);
  if j is null or coalesce((j ->> 'pending')::int, 1) > 0 then return; end if;
  if exists (select 1 from notifications n where n.dedupe_key = 'followup_done:' || p_student) then return; end if;
  select * into st from students where id = p_student;
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
  v_subject := case when v_live then '' else '[시험 · ' || st.code || '] ' end || '[엣지영어] 강사님이 첫 수업 학습 정보를 등록했어요';
  v_lines := array[
    '[엣지영어] 강사님이 첫 수업 학습 정보를 등록했어요',
    '안녕하세요, ' || v_name || '님,',
    '담당 강사님이 첫 수업을 바탕으로 ' || v_name || '님 학습 정보를 적어주셨어요.',
    '영어 레벨: ' || coalesce(st.level, '-'),
    '학습 목표: ' || coalesce(st.improve, '-'),
    '수업 방식: ' || v_style,
    '수업 노트: 노트 열기',
    '(매 수업 내용이 이 노트에 계속 쌓여요.)'];
  v_body := v_lines[1] || E'\n\n' || v_lines[2] || E'\n\n' || v_lines[3] || E'\n\n' || v_lines[4] || E'\n' || v_lines[5] || E'\n' || v_lines[6]
            || E'\n수업 노트: ' || st.class_note_url || E'\n' || v_lines[8]
            || E'\n\n' || v_btn || ': ' || v_url || '/student' || E'\n\n' || v_foot1 || E'\n' || v_foot2
            || case when v_live then '' else E'\n\n(시험 발송 · 원래 받는 사람: ' || v_intended || ')' end;
  v_html := '<div style="font-family:sans-serif;font-size:15px;line-height:1.6;color:#1d1b2a;max-width:480px">'
            || case when v_live then '' else '<p style="background:#fff4d6;color:#5c3b00;border-radius:8px;padding:8px 10px;font-size:13px;font-weight:600">시험 발송 · 원래 받는 사람: ' || lms_html(v_intended) || '</p>' end
            || '<p style="font-weight:700">' || lms_html(v_lines[1]) || '</p>'
            || '<p>' || lms_html(v_lines[2]) || '</p><p>' || lms_html(v_lines[3]) || '</p>'
            || '<p><b>영어 레벨</b> ' || lms_html(coalesce(st.level, '-')) || '<br><b>학습 목표</b> ' || lms_html(coalesce(st.improve, '-'))
            || '<br><b>수업 방식</b> ' || lms_html(v_style)
            || '<br><b>수업 노트</b> <a href="' || lms_html(st.class_note_url) || '" style="color:#5b3df0;font-weight:700">노트 열기</a>'
            || '<br><span style="color:#55526a">' || lms_html(v_lines[8]) || '</span></p>'
            || '<p><a href="' || lms_html(v_url || '/student') || '" style="display:inline-block;background:#5b3df0;color:#fff;border-radius:10px;padding:11px 18px;font-weight:700;text-decoration:none">' || lms_html(v_btn) || '</a></p>'
            || '<p style="font-size:12.5px;color:#55526a;border-top:1px solid #e6e3ef;padding-top:10px">' || lms_html(v_foot1) || '<br>' || lms_html(v_foot2) || '</p></div>';
  insert into notifications (recipient_kind, recipient_id, email, locale, template, payload, dedupe_key)
  values ('student', p_student, v_to, 'ko', 'first_lesson_followup_done',
          jsonb_build_object('intended_email', v_intended, 'subject', v_subject, 'html', v_html, 'text', v_body),
          'followup_done:' || p_student)
  on conflict (dedupe_key) do nothing
  returning id into v_id;
  if v_id is not null then perform lms_mail_dispatch(v_id); end if;
end $$;
revoke all on function lms_followup_done_mail(uuid, uuid) from public, anon, authenticated;

-- 강사 입력 저장: 20261108170000 판 그대로 + 마지막에 위 메일 호출 한 줄
create or replace function tutor_first_lesson_save(p_student uuid, p jsonb, p_tutor uuid default null)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  me uuid := case when is_admin() and p_tutor is not null then lms_screen_tutor(p_tutor) else my_tutor_id() end;
  s students;
  k text;
  v text;
  v_style text;
  v_mix text[];
  v_role text := case when is_admin() and my_tutor_id() is null then 'admin' else 'tutor' end;
begin
  if not is_admin() then
    if me is null or lms_tutor_student_access(me, p_student) is distinct from 'regular' then
      raise exception 'Only the student''s regular tutor can edit this.' using errcode = '42501';
    end if;
  end if;
  select * into s from students where id = p_student for update;
  if not found then raise exception 'Student not found.' using errcode = 'P0002'; end if;
  for k in select jsonb_object_keys(coalesce(p, '{}'::jsonb)) loop
    if k not in ('level', 'improve', 'class_style', 'class_style_mix', 'textbook', 'materials_note', 'class_note_url') then
      raise exception 'Field % cannot be changed here.', k using errcode = '42501';
    end if;
  end loop;
  perform set_config('app.actor_id', auth.uid()::text, true);
  perform set_config('app.actor_via', 'tutor_first_lesson_save', true);

  -- 저장 전에 모든 값을 먼저 검사 (한 칸이 틀리면 아무것도 저장 안 함)
  if p ? 'class_note_url' and not lms_is_google_doc_url(p ->> 'class_note_url') then
    raise exception 'Paste a Google Docs link.' using errcode = '22023';
  end if;

  if p ? 'level' then
    v := nullif(trim(coalesce(p ->> 'level', '')), '');
    if v is null then raise exception 'Please choose a level.' using errcode = '22023'; end if;
    if v not in ('Beginner', 'Pre-Intermediate', 'Intermediate', 'Advanced') then raise exception 'Level must be one of the rubric levels.' using errcode = '22023'; end if;
    perform lms_profile_edit(p_student, 'level', s.level, v, v_role, 'tutor_first_lesson_save');
    update students set level = v, level_by = auth.uid(), level_at = now() where id = p_student;
  end if;

  if p ? 'improve' then
    v := nullif(trim(coalesce(p ->> 'improve', '')), '');
    if v is null then raise exception 'Please write what the student wants to improve.' using errcode = '22023'; end if;
    perform lms_profile_edit(p_student, 'improve', s.improve, v, v_role, 'tutor_first_lesson_save');
    update students set improve = v, improve_tutor_at = now(), improve_tutor_by = auth.uid() where id = p_student;
  end if;

  if p ? 'class_style' then
    v_style := nullif(trim(coalesce(p ->> 'class_style', '')), '');
    if v_style is null or v_style not in ('conversation', 'textbook', 'student_materials', 'mixed') then
      raise exception 'Please choose a class style.' using errcode = '22023';
    end if;
    v_mix := null;
    if v_style = 'mixed' then
      select array_agg(distinct x order by x) into v_mix from jsonb_array_elements_text(coalesce(p -> 'class_style_mix', '[]'::jsonb)) x;
      if coalesce(array_length(v_mix, 1), 0) = 0 then raise exception 'Choose what the mixed class includes.' using errcode = '22023'; end if;
      if exists (select 1 from unnest(v_mix) x where x not in ('conversation', 'textbook', 'student_materials', 'other')) then
        raise exception 'Unknown mix option.' using errcode = '22023';
      end if;
    end if;
    if v_style = 'textbook' or (v_style = 'mixed' and 'textbook' = any(v_mix)) then
      v := case when p ? 'textbook' then nullif(trim(coalesce(p ->> 'textbook', '')), '') else nullif(trim(coalesce(s.textbook, '')), '') end;
      if v is null then raise exception 'Please choose the textbook.' using errcode = '22023'; end if;
      perform lms_profile_edit(p_student, 'textbook', s.textbook, v, v_role, 'tutor_first_lesson_save');
      update students set textbook = v where id = p_student;
    end if;
    if v_style = 'student_materials' or (v_style = 'mixed' and 'student_materials' = any(v_mix)) then
      if p ? 'materials_note' then
        v := nullif(trim(coalesce(p ->> 'materials_note', '')), '');
        perform lms_profile_edit(p_student, 'tutor_materials_note', s.tutor_materials_note, v, v_role, 'tutor_first_lesson_save');
        update students set tutor_materials_note = v where id = p_student;
      end if;
    end if;
    perform lms_profile_edit(p_student, 'tutor_class_style', s.tutor_class_style, v_style, v_role, 'tutor_first_lesson_save');
    perform lms_profile_edit(p_student, 'tutor_class_style_mix', array_to_string(s.tutor_class_style_mix, ','), array_to_string(v_mix, ','), v_role, 'tutor_first_lesson_save');
    update students set tutor_class_style = v_style, tutor_class_style_mix = v_mix, tutor_class_style_at = now(), tutor_class_style_by = auth.uid()
    where id = p_student;
  end if;

  -- 4 Class Notes (Google Docs) — 운영자 화면 'Google Docs' 와 같은 칸
  if p ? 'class_note_url' then
    v := trim(p ->> 'class_note_url');
    perform lms_profile_edit(p_student, 'class_note_url', s.class_note_url, v, v_role, 'tutor_first_lesson_save');
    update students set class_note_url = v where id = p_student;
  end if;
  -- 4칸이 모두 저장됐으면 수강생에게 안내 메일 1번 (실패해도 저장은 그대로)
  begin
    perform lms_followup_done_mail(p_student, me);
  exception when others then
    raise warning 'first lesson done mail: %', sqlerrm;
  end;
  return coalesce(lms_first_lesson_todo(me, p_student), jsonb_build_object('first_lesson', null, 'done', null, 'pending', null));
end $$;
revoke all on function tutor_first_lesson_save(uuid, jsonb, uuid) from public, anon;
grant execute on function tutor_first_lesson_save(uuid, jsonb, uuid) to authenticated;
