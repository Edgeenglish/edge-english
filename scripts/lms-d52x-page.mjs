// 기존 학생 입력 확대판 적용 안내 페이지 (migration 1500). 시험용 먼저 → 화면 시험 → 대표 승인 후 운영
// 사용: node scripts/lms-d52x-page.mjs → docs/lms/previews/d52x-apply.html (SQL을 고치면 다시 만들고 다시 발행)
import { readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { COPY_SCRIPT, PAGE_STYLE, stepMaker } from './lms-prod-page.mjs';

export function buildD52xPage(root) {
  const sql = (p) => readFileSync(join(root, p), 'utf8').trimEnd();
  const apply = ['begin;', sql('supabase/migrations/20261024001500_lms_import_expanded.sql'), 'commit;'].join('\n\n');
  const projectCheck = (name) => `-- 이 DB가 ${name} 인지 확인 (읽기만)\nselect name as 프로젝트_이름 from lms_backup.project;`;
  const testStep = stepMaker('t');
  const prodStep = stepMaker('p');
  const preview = 'Vercel → Deployments → 브랜치 <code>claude/funny-feynman-6n5cup</code> 의 최신 Preview 주소';
  const imp = '<code>/lms/admin/students/import</code>';

  const tests = [
    ['M. 원래 수업 날짜 · 같음', `${imp} · 이름 <b>가상확대일</b>/<code>Virtual Ex One</code> · 강사 <b>가상강사 Alex</b> · 50분 · <b>화 오후 07:00</b> · 종료일 4주 뒤 · 3번 <b>[+ 미예약 보강]</b> → 원래 수업 날짜 = <b>다음 주 화요일</b> · 4번 3개월(12주) · 1기간 · 기간 시작일 = 오늘 · 변경권 아무거나 · 5번 시트 총 수업 수 = <b>계산식 맨 끝 숫자</b>, 진행·차감 0 → [저장] → <b>[시트와 같음 · 대조 완료]</b>`, "보강 칸 아래 '○/○ 정규 수업은 만들지 않아요', 5번 목록에서 그 화요일 줄에 줄 그어짐 · 초록 '✓ 시트 남은 …회 = 만들 수업 …회' · 저장 뒤 '✓ 대조 완료로 기록했어요'"],
    ['N. 숫자 다름', `새로 <b>가상확대이</b> · Alex · 50분 · <b>목 오후 07:00</b> · 같은 종료일 · 보강 없음 · 4번 M과 같게 · 5번 시트 총 수업 수 = <b>계산식 숫자 + 1</b>, 진행·차감 0`, "노란 '…1회 적어요' + 저장 버튼이 갈색 <b>'차이 1회 그대로 저장'</b> → 저장됨. 대조 완료는 누르지 말고 <code>/lms/admin</code> → 처리할 일에 <b>'시트 대조 · 1회 차이 · 가상확대이'</b> → [시트와 같음 · 대조 완료] → 카드 사라짐"],
    ['O. 날짜 확인 필요', `새로 <b>가상확대삼</b> · Alex · 50분 · <b>금 오후 07:00</b> · 3번 [+ 미예약 보강] → <b>[날짜 확인 필요]</b> · 나머지 N과 같게, 시트 숫자는 계산식과 같게 → 저장 → 대조 완료 누름 → <code>/lms/admin</code>`, "처리할 일에 '보강 날짜 확인 · 가상확대삼' 카드 (대조 버튼 없음). 날짜 칸에 <b>내일</b> → [날짜 저장] → 빨간 '입력 시작일 … 전이어야' 거절. <b>지난주 금요일</b> → [날짜 저장] → 카드 사라짐"],
    ['P. 근거 없이는 막힘', `새로 <b>가상확대사</b> · [+ 미예약 보강]을 누르고 원래 날짜·날짜 확인 필요 둘 다 안 고름 · 5번 [+ 수업 날짜 추가]에 날짜·시각만 넣고 근거 비움 → [저장]`, "저장 안 됨 · '원래 수업 날짜를 넣거나 날짜 확인 필요를 골라 주세요' · 근거 칸 아래 '필요해요'. 확인 뒤 [다음 학생 입력] 없이 화면 닫기"],
    ['K. 휴대폰', 'M~P 중 하나를 휴대폰으로', '글자가 잘리거나 옆으로 밀리지 않고, 경고가 그 칸 바로 아래 보임'],
  ];

  return `<title>기존 학생 입력 확대 적용</title>
<meta name="claude:viewport-fit-sides" content="cover">
${PAGE_STYLE}
<style>
.tests { width:100%; border-collapse:collapse; font-size:13.5px; }
.tests th, .tests td { border-top:1px solid var(--line); padding:8px 6px; text-align:left; vertical-align:top; }
.tests th { color:var(--sub); font-weight:600; }
.scroll { overflow-x:auto; }
</style>
<div class="wrap">
  <h1>기존 학생 입력 확대 (migration 1500)</h1>
  <p class="lead">A. 시험용 DB에 먼저 → B. 화면 시험 → 모두 통과하고 대표 승인 뒤 C. 운영 DB. 약 10분 + 화면 시험.</p>

  <h3>A. 시험용 DB (edgeenglish-lms-test)</h3>
  <div class="where">붙여 넣는 곳: Supabase → <b>edgeenglish-lms-test</b> → SQL Editor → 탭 줄 오른쪽 <b>+</b> → 붙여 넣기(Ctrl+V) → 초록 <b>Run</b>. 단계마다 새 탭 하나씩.</div>
  ${testStep('시험용인지 확인', '<p class="expect">정상: <b>edgeenglish-lms-test</b> 한 줄. 다르면 멈추고 Claude에게</p>', projectCheck('edgeenglish-lms-test'))}
  ${testStep('변경 전 백업', '<p class="expect">결과 표 오른쪽 위 <b>Export → Download CSV</b> → 파일 이름 앞에 날짜 (예: <code>2026-10-24_1500적용전_test-backup.csv</code>) → 구글 드라이브 <b>LMS 백업</b> 폴더. 문제 없으면 바로 다음으로</p>', sql('supabase/backup/backup.sql'))}
  ${testStep('변경 적용 (1500)', "<p class=\"expect\">정상: 빨간 글씨 없이 끝남 (Success 또는 빈 결과). 'Potential issue detected' 창이 뜨면 초록 <b>Run and enable RLS</b>. 문제 없으면 바로 다음으로</p>", apply)}
  ${testStep('확인 (읽기만)', '<p class="expect">정상: 6줄 모두 <b>통과</b></p>', sql('supabase/test-setup/d52x-check.sql'))}

  <h3>B. 화면 시험 (시험용 데이터, 휴대폰도 가능)</h3>
  <p class="lead">${preview} → <code>/lms/login</code> 로그인 → 주소 끝을 바꿔 가며. 이름은 <b>'가상'으로 시작</b>.</p>
  <div class="scroll"><table class="tests">
    <tr><th>시험</th><th>하는 것</th><th>통과 기준</th></tr>
    ${tests.map(([a, b, c]) => `<tr><td><b>${a}</b></td><td>${b}</td><td>${c}</td></tr>`).join('\n    ')}
  </table></div>
  <p class="note">통과 못 한 줄이 있으면 그 시험 이름(예: N)과 화면 캡처만 보내 주세요. 모두 통과면 "B 통과"라고 알려 주세요. C는 Claude가 운영 반영 준비를 마치고 승인을 받은 뒤에 해요.</p>

  <h3>C. 운영 DB (edgeenglish-lms) — B 통과 + 대표 승인 뒤에만</h3>
  <div class="where">붙여 넣는 곳: 조직 <b>EdgeEnglish LMS</b> → <b>edgeenglish-lms</b> → SQL Editor. 화면 맨 위 이름을 꼭 확인</div>
  ${prodStep('운영인지 확인', '<p class="expect">정상: <b>edgeenglish-lms</b> 한 줄</p>', projectCheck('edgeenglish-lms'))}
  ${prodStep('적용 직전 백업', '<p class="expect">결과 표 오른쪽 위 <b>Export → Download CSV</b> → 파일 이름 앞에 날짜 (예: <code>2026-10-24_1500적용전_lms-backup.csv</code>) → 구글 드라이브 <b>LMS 백업</b> 폴더</p>', sql('supabase/backup/backup.sql'))}
  ${prodStep('변경 적용 (1500)', '<p class="expect">정상: 빨간 글씨 없이 끝남. 창이 뜨면 초록 <b>Run and enable RLS</b></p>', apply)}
  ${prodStep('확인 (읽기만)', '<p class="expect">정상: 6줄 모두 <b>통과</b></p>', sql('supabase/test-setup/d52x-check.sql'))}
  <p class="note">오류가 나면 오류 첫 줄만 Claude에게. 변경 적용은 한 묶음이라 오류가 나면 아무것도 바뀌지 않아요.</p>
</div>
${COPY_SCRIPT}
`;
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const root = join(import.meta.dirname, '..');
  writeFileSync(join(root, 'docs/lms/previews/d52x-apply.html'), buildD52xPage(root));
  console.log('docs/lms/previews/d52x-apply.html 생성');
}
