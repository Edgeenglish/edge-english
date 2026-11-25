-- 학생은 어느 회차든 '대체강사와 수업' 가능 (H26(218) 보충5, 대표 11/25: 강사가 연 시간 중 학생이 갈 수 있는 시간이 없을 때도)
--  20261126100000 의 '같은 주 후보 0개만' 검사를 뺌. 학생만(강사 신청은 그대로 막음) · 배정·확정 절차는 그대로
do $$
declare d text; n text;
begin
  d := pg_get_functiondef('lms_ttl_submit(uuid, uuid, jsonb, text)'::regprocedure);
  if position('같은 주에 고를 수 있는 시간이 생겼어요' in d) > 0 then
    n := replace(d, $x$      if not exists (select 1 from jsonb_array_elements(v_opt -> 'rows') o
                     where o ->> 'key' = r.key and jsonb_array_length(coalesce(o -> 'cands', '[]'::jsonb)) = 0) then
        raise exception '같은 주에 고를 수 있는 시간이 생겼어요. 창을 닫고 다시 열어 주세요.' using hint = 'ttl';
      end if;
$x$, '');
    n := replace(n, $x$    v_opt := lms_ttl_options(p_tutor, p_student);
$x$, '');
    if position('같은 주에 고를 수 있는 시간이 생겼어요' in n) > 0 or position('v_opt := ' in n) > 0 then raise exception 'lms_ttl_submit: 뺄 곳을 못 찾음'; end if;
    execute n;
  end if;
end $$;
