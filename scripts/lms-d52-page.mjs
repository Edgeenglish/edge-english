// [보냈어요]·기존 학생 간단 입력 적용 안내 페이지 (migration 1200·1300). 시험용 먼저 → 화면 시험 → 통과 후 운영
// 사용: node scripts/lms-d52-page.mjs → docs/lms/previews/d52-apply.html (SQL을 고치면 다시 만들고 다시 발행)
import { readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { COPY_SCRIPT, PAGE_STYLE, esc, stepMaker } from './lms-prod-page.mjs';

export function buildD52Page(root) {
  const sql = (p) => readFileSync(join(root, p), 'utf8').trimEnd();
  const migrations = ['supabase/migrations/20261022001200_lms_notice_sent_button.sql', 'supabase/migrations/20261022001300_lms_import_existing_student.sql', 'supabase/migrations/20261022001400_lms_fixed_slot_hold.sql'];
  const apply = ['begin;', ...migrations.map(sql), 'commit;'].join('\n\n');
  const projectCheck = (name) => `-- 이 DB가 ${name} 인지 확인 (읽기만)\nselect name as 프로젝트_이름 from lms_backup.project;`;
  const testStep = stepMaker('t');
  const prodStep = stepMaker('p');
  const preview = 'Vercel → Deployments → 브랜치 <code>claude/admiring-gauss-c8crhe</code> 의 최신 Preview 주소';

  const tests = [
    ['C. 한쪽만', '가상확정일처럼 확정된 카드에서 <b>학생 줄 [복사]</b>만 누름', "학생 줄이 '복사함 · 보낸 뒤 [보냈어요]'로만 바뀌고 <b>보냄이 아님</b>. 이어서 학생 [보냈어요] → 학생 '보냄', 카드는 '강사 안내 안 함'으로 남음"],
    ['D. 양쪽', '강사 줄 [복사] → [보냈어요]', '카드가 처리할 일에서 사라짐'],
    ['G. 기존 학생 입력', '<code>/lms/admin/students/import</code> · 이름 <b>가상이관일</b>/<code>Virtual One</code> · 강사 <b>가상강사 Alex</b> · 50분 · <b>월 06:30</b> · 종료일 4주 뒤 · 보강 추가: 다음 주 <b>목요일 06:30</b> 50분 Alex → [저장]', "'입력 완료 · STU-…' · 정규 4회 안팎 + 보강 1회"],
    ['H. 기존 학생 시간표와 충돌', '새로 <b>가상이관이</b> · Alex · <b>월 06:30</b> · 같은 종료일', "저장 전에 '일정 충돌' 목록: 월요일마다 '강사의 다른 학생 정규 수업과 겹침 (가상이관일)'. 저장 버튼이 막힘"],
    ['I. 보강은 그날만', '같은 화면에서 요일만 <b>목 06:30</b> 으로 바꿈', 'G의 보강 날짜 <b>하루만</b> 충돌 (다른 목요일은 괜찮음)'],
    ['J. 강사 휴무와 충돌', '아래 ③ SQL로 가상 휴무를 넣은 뒤, 요일을 <b>수 06:30</b> 으로 바꿈', "③ 결과의 수요일 <b>하루만</b> '강사 휴무'로 충돌"],
    ['L. 재등록 대기 자리', '새로 <b>가상이관삼</b> · Alex · 50분 · <b>월 오후 06:30</b> · 시작일 <b>2026-11-20</b> · 종료일 <b>2026-12-17</b>', "저장 전에 11/23·11/30·12/7·12/14 모두 '재등록 대기 중인 학생의 고정 시간 (가상이관일 · 11/19 23:59까지)'. 오후 07:30 으로 바꾸면 충돌 없음"],
    ['K. 휴대폰', 'G~J 중 하나를 휴대폰으로', '글자가 잘리거나 옆으로 밀리지 않고 저장·충돌 목록이 보임'],
  ];

  return `<title>보냈어요·기존 학생 입력 적용</title>
<meta name="claude:viewport-fit-sides" content="cover">
${PAGE_STYLE}
<style>
.tests { width:100%; border-collapse:collapse; font-size:13.5px; }
.tests th, .tests td { border-top:1px solid var(--line); padding:8px 6px; text-align:left; vertical-align:top; }
.tests th { color:var(--sub); font-weight:600; }
.scroll { overflow-x:auto; }
</style>
<div class="wrap">
  <h1>[보냈어요] · 기존 학생 간단 입력</h1>
  <p class="lead">A. 시험용 DB에 먼저 → B. 화면 시험 → 모두 통과하면 C. 운영 DB. 약 15분 + 화면 시험.</p>

  <h3>A. 시험용 DB (edgeenglish-lms-test)</h3>
  <div class="where">붙여 넣는 곳: Supabase → <b>edgeenglish-lms-test</b> → SQL Editor → 탭 줄 오른쪽 <b>+</b> → 붙여 넣기(Ctrl+V) → 초록 <b>Run</b>. 단계마다 새 탭 하나씩.</div>
  ${testStep('시험용인지 확인', '<p class="expect">정상: <b>edgeenglish-lms-test</b> 한 줄. 다르면 멈추고 Claude에게</p>', projectCheck('edgeenglish-lms-test'))}
  ${testStep('변경 적용 (1200·1300·1400)', "<p class=\"expect\">정상: 빨간 글씨 없이 끝남 (Success 또는 빈 결과). 'Potential issue detected' 창이 뜨면 초록 <b>Run and enable RLS</b>. 문제 없으면 바로 다음으로</p>", apply)}
  ${testStep('확인 (읽기만)', '<p class="expect">정상: 7줄 모두 <b>통과</b></p>', sql('supabase/test-setup/d52-check.sql'))}
  ${testStep('화면 시험 J용 가상 휴무 넣기', '<p class="expect">정상: 약 2주 뒤 수요일 날짜가 한 줄 나옴 — 그 날짜를 기억해 두세요 (시험용에서만 들어가요)</p>', sql('supabase/test-setup/d52-time-off.sql'))}

  <h3>B. 화면 시험 (시험용 데이터, 휴대폰도 가능)</h3>
  <p class="lead">${preview} → <code>/lms/login</code> 로그인 → 주소 끝을 바꿔 가며. 이름은 <b>'가상'으로 시작</b>. 기존 A·B·E·F 시험은 그대로예요.</p>
  <div class="scroll"><table class="tests">
    <tr><th>시험</th><th>하는 것</th><th>통과 기준</th></tr>
    ${tests.map(([a, b, c]) => `<tr><td><b>${a}</b></td><td>${b}</td><td>${c}</td></tr>`).join('\n    ')}
  </table></div>
  <p class="note">통과 못 한 줄이 있으면 그 시험 이름(예: H)과 화면 캡처만 보내 주세요. 모두 통과면 "B 통과"라고만 알려 주시고 바로 C로 가셔도 돼요.</p>

  <h3>C. 운영 DB (edgeenglish-lms) — B를 모두 통과한 뒤에만</h3>
  <div class="where">붙여 넣는 곳: 조직 <b>EdgeEnglish LMS</b> → <b>edgeenglish-lms</b> → SQL Editor. 화면 맨 위 이름을 꼭 확인</div>
  ${prodStep('운영인지 확인', '<p class="expect">정상: <b>edgeenglish-lms</b> 한 줄</p>', projectCheck('edgeenglish-lms'))}
  ${prodStep('적용 직전 백업', '<p class="expect">결과 표 오른쪽 위 <b>Export → Download CSV</b> → 파일 이름 앞에 날짜 (예: <code>2026-10-23_1200-1300적용전_lms-backup.csv</code>) → 구글 드라이브 <b>LMS 백업</b> 폴더</p>', sql('supabase/backup/backup.sql'))}
  ${prodStep('변경 적용 (1200·1300·1400)', '<p class="expect">정상: 빨간 글씨 없이 끝남. 창이 뜨면 초록 <b>Run and enable RLS</b></p>', apply)}
  ${prodStep('확인 (읽기만)', '<p class="expect">정상: 7줄 모두 <b>통과</b>. 운영 DB에는 가상 휴무를 넣지 않아요</p>', sql('supabase/test-setup/d52-check.sql'))}
  <p class="note">오류가 나면 오류 첫 줄만 Claude에게. 변경 적용은 한 묶음이라 오류가 나면 아무것도 바뀌지 않아요.</p>
</div>
${COPY_SCRIPT}
`;
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const root = join(import.meta.dirname, '..');
  writeFileSync(join(root, 'docs/lms/previews/d52-apply.html'), buildD52Page(root));
  console.log('docs/lms/previews/d52-apply.html 생성');
}
