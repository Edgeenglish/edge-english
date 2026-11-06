// 강사 휴무·대체강사 적용 안내 페이지 (migration 1800). 시험용 먼저(대표) → 화면 시험 → 대표 승인 후 운영(Claude가 커넥터로, 직전 백업)
// 사용: node scripts/lms-l18-page.mjs → docs/lms/previews/l18-apply.html (SQL을 고치면 다시 만들고 다시 발행)
import { readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { COPY_SCRIPT, PAGE_STYLE, stepMaker } from './lms-prod-page.mjs';

export function buildL18Page(root) {
  const sql = (p) => readFileSync(join(root, p), 'utf8').trimEnd();
  const apply = ['begin;', sql('supabase/migrations/20261027001800_lms_tutor_leave.sql'), 'commit;'].join('\n\n');
  const projectCheck = (name) => `-- 이 DB가 ${name} 인지 확인 (읽기만)\nselect name as 프로젝트_이름 from lms_backup.project;`;
  const testStep = stepMaker('t');

  return `<title>강사 휴무 적용</title>
<meta name="claude:viewport-fit-sides" content="cover">
${PAGE_STYLE}
<div class="wrap">
  <h1>강사 휴무·대체강사 (migration 1800) · 2026-10-27 수정판</h1>

  <h3>A. 시험용 DB (edgeenglish-lms-test)</h3>
  <div class="where">Supabase → 조직 EdgeEnglish → <b>edgeenglish-lms-test</b> → 왼쪽 SQL Editor → 탭 줄 오른쪽 <b>+</b> → 붙여 넣기(Ctrl+V) → 초록 <b>Run</b>. 단계마다 새 탭 하나씩.</div>
  ${testStep('시험용인지 확인', '<p class="expect">확인: <b>edgeenglish-lms-test</b> 한 줄. 다르면 멈추고 Claude에게</p>', projectCheck('edgeenglish-lms-test'))}
  ${testStep('변경 전 백업', '<p class="expect">결과 표 오른쪽 위 <b>Export → Download CSV</b> → 파일 이름 앞에 <code>날짜_시험용_1800적용전_</code> → 구글 드라이브 <b>LMS 백업</b> 폴더 → 바로 다음 단계</p>', sql('supabase/backup/backup.sql'))}
  ${testStep('변경 적용 (1800)', "<p class=\"expect\">확인: 빨간 글씨 없이 끝남. 'Potential issue detected' 창이 뜨면 초록 <b>Run and enable RLS</b> → 바로 다음 단계</p>", apply)}
  ${testStep('확인 (읽기만)', '<p class="expect">확인: 5줄 모두 <b>통과</b></p>', sql('supabase/test-setup/l18-check.sql'))}
  ${testStep('화면 시험용 가상 강사·학생', '<p class="expect">확인: 김하준 5줄 · 박서연 3줄</p>', sql('supabase/test-setup/l18-seed.sql'))}
  <p class="note">A가 끝나면 Claude에게 "A 했어". 화면 시험 순서는 대화창으로 드려요.</p>

  <h3>C. 운영 DB (edgeenglish-lms)</h3>
  <p class="note">화면 시험 통과 + 대표 '응' 뒤에 Claude가 직접 적용해요 (적용 직전 백업을 Claude가 만들어 구글 드라이브 LMS 백업 폴더에 보관).</p>
</div>
${COPY_SCRIPT}
`;
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const root = join(import.meta.dirname, '..');
  writeFileSync(join(root, 'docs/lms/previews/l18-apply.html'), buildL18Page(root));
  console.log('docs/lms/previews/l18-apply.html 생성');
}
