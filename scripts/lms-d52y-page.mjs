// 기존 학생 입력 시안 2 적용 안내 페이지 (migration 1600). 시험용 먼저(1500은 2026-10-24 적용됨) → 화면 시험 → 대표 승인 후 운영(1500+1600)
// 사용: node scripts/lms-d52y-page.mjs → docs/lms/previews/d52y-apply.html (SQL을 고치면 다시 만들고 다시 발행)
import { readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { COPY_SCRIPT, PAGE_STYLE, stepMaker } from './lms-prod-page.mjs';

export function buildD52yPage(root) {
  const sql = (p) => readFileSync(join(root, p), 'utf8').trimEnd();
  const m1500 = sql('supabase/migrations/20261024001500_lms_import_expanded.sql');
  const m1600 = sql('supabase/migrations/20261026001600_lms_import_course_dates.sql');
  const applyTest = ['begin;', m1600, 'commit;'].join('\n\n');
  const applyProd = ['begin;', m1500, m1600, 'commit;'].join('\n\n');
  const projectCheck = (name) => `-- 이 DB가 ${name} 인지 확인 (읽기만)\nselect name as 프로젝트_이름 from lms_backup.project;`;
  const testStep = stepMaker('t');
  const prodStep = stepMaker('p');
  const url = '<code>https://edge-english-git-lms-test-support-2126.vercel.app/lms/admin/students/import</code>';
  const common = '강사 <b>가상강사 Blair</b> · 40분 · 요일 <b>월·수</b> · 상품 <b>3개월(12주)</b> · 수강 시작일 <b>2026-10-14</b> · 남은 변경권 <b>1개</b>';

  const tests = [
    ['R1. 보강 없는 학생', `${url} · 이름 <b>가상시안일</b>/<code>Virtual Two A</code> · ${common} · 시각 <b>오전 11:00</b> · 4번 '없음' 그대로 · 5번 시트 총 수업 수 = <b>계산식 맨 끝 숫자</b>, 진행·차감 0 → [저장] → [시트와 같음 · 대조 완료]`, "2번에 1~3기간 날짜(10/14·11/11·12/9 시작)와 '지금 · 변경권 1/2', 종료일 <b>2027-01-05 자동</b> · 3번 첫 정규 수업일이 오늘 이후 첫 월·수로 자동 · 초록 '✓ 시트 남은 …회 = 만들 수업 …회' · 저장·대조 완료"],
    ['R2. 강사 휴무 연장', `새로 <b>가상시안이</b> · ${common} · 시각 <b>오후 01:00</b> · 2번 종료일을 <b>2027-01-11</b>로 고침 → 이유 <b>[강사 장기 휴무 연장]</b> · 5번 시트 숫자는 계산식과 같게 → [저장]`, "노란 상자 '…<b>6일 늦어요</b>' + '늘어난 1/6(수) ~ 1/11(월)에는 정규 수업을 만들지 않아요'. 종료일을 고치기 전과 후 <b>5번 계산식 숫자가 같음</b>(정규가 늘지 않음) · 6번 종료일 '(계산보다 +6일 · 강사 장기 휴무 연장)'"],
    ['R3. 보강이 종료일 뒤', `새로 <b>가상시안삼</b> · ${common} · 시각 <b>오후 03:00</b> · 4번 <b>[있음]</b> → [+ 예약된 보강] → 원래 수업 날짜 = 첫 정규 수업일, 보강 날짜 <b>2027-01-08</b> 오후 03:00 Blair → [저장]`, "저장 안 됨 '보강 1: 수강 종료일 뒤예요. 종료일(연장)을 먼저 맞춰 주세요.' → 2번 종료일 <b>2027-01-11</b> + [강사 장기 휴무 연장] → 저장됨. 5번 목록에서 원래 수업 날 줄은 '취소됨 · 보강 잡힘'"],
    ['R4. 지금 기간 고치기', `R1 같은 화면을 새로 열어(저장 안 함) 2번 <b>[시트의 지금 기간이 다르면 고르기]</b> → <b>2기간</b>`, "기간 목록에서 2기간이 보라색 '지금', 1기간은 '지난 기간', 아래 글씨 '지금 기간을 2기간으로 고쳤어요'. 다시 1기간을 누르면 자동으로 돌아옴. 확인 후 화면 닫기(저장 안 함)"],
    ['R5. 고정 요일 바꾼 학생', `새로 <b>가상시안사</b> · ${common.replace('2026-10-14', '2026-10-13')} · 시각 <b>오후 05:00</b> · 시트 숫자 계산식과 같게 → [저장]`, "수강 시작일 아래 파란 안내 '10/13(화)이 지금 수업 요일(월·수)과 달라요. 수강 중 고정 요일을 바꾼 학생이면 정상이에요' — 빨간 경고 아님, 저장됨"],
    ['R6. 종료일 이유 안 고름', `새로 <b>가상시안육</b> · ${common} · 시각 <b>오후 08:00</b> · 2번 종료일을 <b>2027-01-11</b>로 고치고 <b>이유는 고르지 않음</b> · 시트 숫자 계산식과 같게 → [저장] → [시트와 같음 · 대조 완료] → <code>/lms/admin</code>`, "저장됨 + 노란 글씨 '종료일 이유 확인으로 남았어요'. 대조 완료를 눌러도 처리할 일에 <b>'종료일 이유 확인 · 가상시안육'</b>이 남음 → [강사 장기 휴무 연장] → [이유 저장] → 카드 사라짐"],
    ['R7. 강사 휴가 보강', `새로 <b>가상시안칠</b> · ${common} · 시각 <b>오후 09:00</b> · 4번 [있음] → [+ 예약된 보강] → <b>[강사 휴가로 생긴 보강]</b> 체크 → 원래 수업 날짜 = 첫 정규 수업일, 보강 날짜 <b>2027-01-08</b> 오후 09:00 Blair`, "보강 칸 아래 빨간 상자에 <b>[종료일을 1/8(금)로 늘리기 (강사 장기 휴무 연장)]</b> 버튼 → 누르면 종료일 2027-01-08 + 이유 자동, 빨간 상자 사라짐 → 시트 숫자 맞추고 [저장] 됨"],
    ['N. 숫자 다름 → 처리할 일', `새로 <b>가상시안오</b> · ${common} · 시각 <b>오후 07:00</b> · 5번 시트 총 수업 수 = <b>계산식 숫자 + 1</b> → 갈색 [차이 1회 그대로 저장] → 대조 완료는 누르지 않음 → <code>/lms/admin</code>`, "처리할 일에 '시트 대조 · 1회 차이 · 가상시안오' → [시트와 같음 · 대조 완료] → 카드 사라짐"],
    ['K. 휴대폰', 'R1~R5 중 하나를 휴대폰으로', '글자가 잘리거나 옆으로 밀리지 않고, 날짜 칸을 누르면 달력이 열리고, 경고가 그 칸 바로 아래 보임'],
  ];

  return `<title>기존 학생 입력 시안 2 적용</title>
<meta name="claude:viewport-fit-sides" content="cover">
${PAGE_STYLE}
<style>
.tests { width:100%; border-collapse:collapse; font-size:13.5px; }
.tests th, .tests td { border-top:1px solid var(--line); padding:8px 6px; text-align:left; vertical-align:top; }
.tests th { color:var(--sub); font-weight:600; }
.scroll { overflow-x:auto; }
</style>
<div class="wrap">
  <h1>기존 학생 입력 시안 2 (migration 1600)</h1>
  <p class="lead">A. 시험용 DB에 1600 → B. 화면 시험 → 모두 통과하고 대표 승인 뒤 C. 운영 DB에 1500+1600. 약 10분 + 화면 시험.</p>

  <h3>A. 시험용 DB (edgeenglish-lms-test)</h3>
  <div class="where">붙여 넣는 곳: Supabase → 조직 EdgeEnglish → <b>edgeenglish-lms-test</b> → 왼쪽 SQL Editor → 탭 줄 오른쪽 <b>+</b> → 붙여 넣기(Ctrl+V) → 초록 <b>Run</b>. 단계마다 새 탭 하나씩.</div>
  ${testStep('시험용인지 확인', '<p class="expect">정상: <b>edgeenglish-lms-test</b> 한 줄. 다르면 멈추고 Claude에게</p>', projectCheck('edgeenglish-lms-test'))}
  ${testStep('변경 전 백업', '<p class="expect">결과 표 오른쪽 위 <b>Export → Download CSV</b> → 파일 이름 앞에 <code>2026-10-26_시험용_1600적용전_</code> → 구글 드라이브 <b>LMS 백업</b> 폴더. 문제 없으면 바로 다음으로</p>', sql('supabase/backup/backup.sql'))}
  ${testStep('변경 적용 (1600)', "<p class=\"expect\">정상: 빨간 글씨 없이 끝남 (Success 또는 빈 결과). 'Potential issue detected' 창이 뜨면 초록 <b>Run and enable RLS</b>. 문제 없으면 바로 다음으로</p>", applyTest)}
  ${testStep('확인 (읽기만)', '<p class="expect">정상: 4줄 모두 <b>통과</b></p>', sql('supabase/test-setup/d52y-check.sql'))}

  <h3>B. 화면 시험 (시험용 데이터, 휴대폰도 가능)</h3>
  <p class="lead">A가 끝나고 2~3분 뒤 시험 주소 <code>https://edge-english-git-lms-test-support-2126.vercel.app/lms/admin</code> (즐겨찾기) → 맨 위 회색 띠 '시험용 DB' 확인 → 아래 표 순서대로. 이름은 <b>'가상'으로 시작</b>.</p>
  <div class="scroll"><table class="tests">
    <tr><th>시험</th><th>하는 것</th><th>통과 기준</th></tr>
    ${tests.map(([a, b, c]) => `<tr><td><b>${a}</b></td><td>${b}</td><td>${c}</td></tr>`).join('\n    ')}
  </table></div>
  <p class="note">예전 시험 학생과 시간이 겹쳐 '일정 충돌'이 뜨면 충돌 검사가 정상 동작한 거예요. 그 시험만 시각을 1시간 미뤄서 다시 하세요.</p>
  <p class="note">통과 못 한 줄이 있으면 그 시험 이름(예: R2)과 화면 캡처만 보내 주세요. 모두 통과면 "B 통과"라고 알려 주세요. C는 대표 승인 뒤에 해요.</p>

  <h3>C. 운영 DB (edgeenglish-lms) — B 통과 + 대표 승인 뒤에만</h3>
  <div class="where">붙여 넣는 곳: Supabase → 조직 <b>EdgeEnglish LMS</b> → <b>edgeenglish-lms</b> → 왼쪽 SQL Editor. 화면 맨 위 이름을 꼭 확인</div>
  ${prodStep('운영인지 확인', '<p class="expect">정상: <b>edgeenglish-lms</b> 한 줄</p>', projectCheck('edgeenglish-lms'))}
  ${prodStep('적용 직전 백업', '<p class="expect">결과 표 오른쪽 위 <b>Export → Download CSV</b> → 파일 이름 앞에 <code>날짜_운영_1500-1600적용전_</code> → 구글 드라이브 <b>LMS 백업</b> 폴더</p>', sql('supabase/backup/backup.sql'))}
  ${prodStep('변경 적용 (1500 + 1600 한 번에)', '<p class="expect">정상: 빨간 글씨 없이 끝남. 창이 뜨면 초록 <b>Run and enable RLS</b></p>', applyProd)}
  ${prodStep('확인 1 (읽기만)', '<p class="expect">정상: 6줄 모두 <b>통과</b></p>', sql('supabase/test-setup/d52x-check.sql'))}
  ${prodStep('확인 2 (읽기만)', '<p class="expect">정상: 4줄 모두 <b>통과</b></p>', sql('supabase/test-setup/d52y-check.sql'))}
  <p class="note">오류가 나면 오류 첫 줄만 Claude에게. 변경 적용은 한 묶음이라 오류가 나면 아무것도 바뀌지 않아요.</p>
</div>
${COPY_SCRIPT}
`;
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const root = join(import.meta.dirname, '..');
  writeFileSync(join(root, 'docs/lms/previews/d52y-apply.html'), buildD52yPage(root));
  console.log('docs/lms/previews/d52y-apply.html 생성');
}
