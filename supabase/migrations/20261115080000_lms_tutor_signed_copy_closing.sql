-- 강사 서명본 메일 맺음말 'Edge English' → 'Edge English Team' (대표 11/15: 메일 3개 맺음말 통일, H26(191))
-- tutor_sign 본문에서 해당 두 곳만 바꿈. 본문이 예상과 다르면 멈춤. 다시 실행해도 같은 결과
do $mig$
declare d text; n text;
begin
  d := pg_get_functiondef('public.tutor_sign(uuid, text, text, text)'::regprocedure);
  if position($x$<p>Edge English Team</p></div>$x$ in d) > 0 then return; end if;
  n := replace(d, $x$lms_strip_bold(v_when) || E'\n\n' || 'Edge English'$x$, $x$lms_strip_bold(v_when) || E'\n\n' || 'Edge English Team'$x$);
  n := replace(n, $x$<p>Edge English</p></div>$x$, $x$<p>Edge English Team</p></div>$x$);
  if n = d or position($x$<p>Edge English Team</p></div>$x$ in n) = 0 or position($x$|| 'Edge English Team'$x$ in n) = 0 then
    raise exception 'tutor_sign: 예상한 맺음말 줄이 없음 — 멈춤';
  end if;
  execute n;
end
$mig$;
