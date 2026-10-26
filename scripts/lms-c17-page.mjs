// 수업 변경·보강 적용 안내 페이지 (migration 1700). 시험용 먼저 → 화면 시험(날짜는 Claude가 그날 계산해 대화창으로) → 대표 승인 후 운영
// 사용: node scripts/lms-c17-page.mjs → docs/lms/previews/c17-apply.html (SQL을 고치면 다시 만들고 다시 발행)
import { readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { COPY_SCRIPT, PAGE_STYLE, stepMaker } from './lms-prod-page.mjs';

export function buildC17Page(root) {
  const sql = (p) => readFileSync(join(root, p), 'utf8').trimEnd();
  const apply = ['begin;', sql('supabase/migrations/20261026001700_lms_lesson_change.sql'), 'commit;'].join('\n\n');
  const projectCheck = (name) => `-- 이 DB가 ${name} 인지 확인 (읽기만)\nselect name as 프로젝트_이름 from lms_backup.project;`;
  const testStep = stepMaker('t');
  const prodStep = stepMaker('p');

  return `<title>수업 변경 적용</title>
<meta name="claude:viewport-fit-sides" content="cover">
${PAGE_STYLE}
<div class="wrap">
  <h1>수업 변경·보강 (migration 1700)</h1>

  <h3>A. 시험용 DB (edgeenglish-lms-test)</h3>
  <div class="where">Supabase → 조직 EdgeEnglish → <b>edgeenglish-lms-test</b> → 왼쪽 SQL Editor → 탭 줄 오른쪽 <b>+</b> → 붙여 넣기(Ctrl+V) → 초록 <b>Run</b>. 단계마다 새 탭 하나씩.</div>
  ${testStep('시험용인지 확인', '<p class="expect">확인: <b>edgeenglish-lms-test</b> 한 줄. 다르면 멈추고 Claude에게</p>', projectCheck('edgeenglish-lms-test'))}
  ${testStep('변경 전 백업', '<p class="expect">결과 표 오른쪽 위 <b>Export → Download CSV</b> → 파일 이름 앞에 <code>날짜_시험용_1700적용전_</code> → 구글 드라이브 <b>LMS 백업</b> 폴더 → 바로 다음 단계</p>', sql('supabase/backup/backup.sql'))}
  ${testStep('변경 적용 (1700)', "<p class=\"expect\">확인: 빨간 글씨 없이 끝남. 'Potential issue detected' 창이 뜨면 초록 <b>Run and enable RLS</b> → 바로 다음 단계</p>", apply)}
  ${testStep('확인 (읽기만)', '<p class="expect">확인: 5줄 모두 <b>통과</b></p>', sql('supabase/test-setup/c17-check.sql'))}
  <p class="note">A가 끝나면 Claude에게 "A 했어". 화면 시험(B)은 그날 날짜를 넣어 대화창으로 드려요.</p>

  <h3>C. 운영 DB (edgeenglish-lms) — B 통과 + 대표 승인 뒤에만</h3>
  <div class="where">Supabase → 조직 <b>EdgeEnglish LMS</b> → <b>edgeenglish-lms</b> → 왼쪽 SQL Editor. 화면 맨 위 이름 확인</div>
  ${prodStep('운영인지 확인', '<p class="expect">확인: <b>edgeenglish-lms</b> 한 줄</p>', projectCheck('edgeenglish-lms'))}
  ${prodStep('적용 직전 백업', '<p class="expect">결과 표 오른쪽 위 <b>Export → Download CSV</b> → 파일 이름 앞에 <code>날짜_운영_1700적용전_</code> → 구글 드라이브 <b>LMS 백업</b> 폴더</p>', sql('supabase/backup/backup.sql'))}
  ${prodStep('변경 적용 (1700)', '<p class="expect">확인: 빨간 글씨 없이 끝남. \'Potential issue detected\' 창이 뜨면 주황 <b>Run query</b> (규칙을 새 규칙으로 바꾸는 줄 때문, 데이터 지우지 않음). \'Run and enable RLS\' 창이면 초록 버튼</p>', apply)}
  ${prodStep('확인 (읽기만)', '<p class="expect">확인: 5줄 모두 <b>통과</b></p>', sql('supabase/test-setup/c17-check.sql'))}
  <p class="note">오류가 나면 오류 첫 줄만 Claude에게. 변경 적용은 한 묶음이라 오류가 나면 아무것도 바뀌지 않아요.</p>
</div>
${COPY_SCRIPT}
`;
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const root = join(import.meta.dirname, '..');
  writeFileSync(join(root, 'docs/lms/previews/c17-apply.html'), buildC17Page(root));
  console.log('docs/lms/previews/c17-apply.html 생성');
}
