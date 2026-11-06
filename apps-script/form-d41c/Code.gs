/**
 * D-41 3차: 신청서(구글폼)에 '결제 방법' 질문 넣기 — 한 번만 실행하는 스크립트 (2026-10-21)
 *
 * 대상: '미국·캐나다 원어민 1:1 화상수업 신청서' (support@edgeenglish.kr)
 * - '수강신청 방법' 안내(계좌 정보가 있는 곳) 바로 아래에 '결제 방법' (계좌이체 / 카드결제, 필수) 질문을 넣음
 * - 2026-10-21 대표 A안: 질문 하나 + 안내 문구. 답에 따라 페이지를 나누지 않음 (보관 섹션 숨김 설정이 꼬이지 않게)
 * - 다른 질문·응답·시트 연결은 건드리지 않음
 *
 * 쓰는 법: 1) 미리보기 실행 → 실행 로그 확인  2) 적용 실행  (두 번 실행해도 두 번 바뀌지 않음)
 */

const FORM_ID = '163rAf9Jn-bCxNN8Px38G2BgUTfK-AeixxIlTLedjXNs';

const GUIDE = '수강신청 방법';
const PAY = '결제 방법';
const PAY_CHOICES = ['계좌이체', '카드결제'];
const PAY_HELP = '계좌이체: 위 계좌로 입금해 주세요. 입금자명이 학생 이름과 다르면 아래 \'입금자명\'에 꼭 적어 주세요.\n' +
  '카드결제: 신청서 제출 후 아래 링크에서 결제해 주세요. (수업 길이·횟수·수강 기간을 신청서와 똑같이 골라 주세요)\n' +
  'https://tangerineenglish.imweb.me/?idx=11';

function 미리보기() {
  const plan = check_();
  Logger.log('폼: ' + plan.form.getTitle());
  Logger.log('\'' + firstLine_(plan.guide.getTitle()) + '\' (' + (plan.guide.getIndex() + 1) + '번째) 바로 아래에 \'결제 방법\' 질문을 넣습니다.');
  Logger.log('문제 없음 → 이제 \'적용\' 을 실행하세요.');
}

function 적용() {
  const plan = check_();
  const form = plan.form;
  const pay = form.addMultipleChoiceItem().setTitle(PAY).setHelpText(PAY_HELP);
  pay.setChoiceValues(PAY_CHOICES).setRequired(true);
  form.moveItem(pay.getIndex(), plan.guide.getIndex() + 1);
  Logger.log('완료. 폼 미리보기(눈 모양)로 확인한 뒤 시험 응답 1건을 제출해 주세요.');
}

/** '수강신청 방법' 안내가 정확히 하나 있고, 결제 방법 질문이 아직 없는지 확인. 아니면 아무것도 안 하고 멈춤 */
function check_() {
  const form = FormApp.openById(FORM_ID);
  const items = form.getItems();
  if (items.some((it) => it.getTitle().trim() === PAY)) throw new Error('이미 바뀐 폼입니다 (결제 방법 질문이 있음). 아무것도 하지 않았습니다.');
  const guide = items.filter((it) => it.getTitle().trim().indexOf(GUIDE) === 0);
  if (guide.length !== 1) throw new Error('\'수강신청 방법\' 안내를 정확히 찾지 못했습니다 (' + guide.length + '개). 아무것도 하지 않았습니다.');
  return { form, guide: guide[0] };
}

function firstLine_(s) {
  return String(s).split('\n')[0];
}
