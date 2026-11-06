/**
 * D-41 4차: 카드결제 링크를 신청서 중간에서 빼고 '제출 후 화면'으로 옮기기 — 한 번만 실행하는 스크립트 (2026-10-21)
 *
 * 왜: 대표가 휴대폰으로 시험 응답 중 '결제 방법' 안내의 아임웹 링크를 누르고 돌아오니 적던 내용이 사라짐.
 *     신청서를 쓰는 도중에는 다른 화면으로 나가지 않게 한다 (기존 원칙).
 * 바꾸는 것:
 *   '결제 방법' 안내 문구 → 링크 없이 "제출하면 다음 화면에 결제 링크가 나와요"
 *   제출 후 화면(응답 확인 메시지) 끝에 카드결제 링크 추가 (기존 문구는 그대로 두고 뒤에 붙임)
 * - 질문 순서·다른 질문·응답·시트 연결은 건드리지 않음 (대표가 순서를 바꿔 둠)
 *
 * 쓰는 법: 1) 미리보기 실행 → 실행 로그 확인  2) 적용 실행  (두 번 실행해도 두 번 바뀌지 않음)
 */

const FORM_ID = '163rAf9Jn-bCxNN8Px38G2BgUTfK-AeixxIlTLedjXNs';

const PAY = '결제 방법';
const CARD_URL = 'https://tangerineenglish.imweb.me/?idx=11';
const PAY_HELP = '계좌이체: 안내된 계좌로 입금해 주세요. 입금자명이 학생 이름과 다르면 \'입금자명\'에 꼭 적어 주세요.\n' +
  '카드결제: 신청서를 제출하면 다음 화면에 결제 링크가 나와요. 지금은 이 화면을 벗어나지 말고 끝까지 작성해 주세요.';
const CONFIRM_ADD = '💳 카드결제를 고르셨다면 아래 링크에서 결제해 주세요.\n(수업 길이·횟수·수강 기간을 신청서와 똑같이 골라 주세요)\n' + CARD_URL + '\n결제가 어려우시면 카카오톡 채널로 말씀해 주세요.';

function 미리보기() {
  const plan = check_();
  Logger.log('폼: ' + plan.form.getTitle());
  Logger.log('안내 바꿀 질문 (' + (plan.pay.getIndex() + 1) + '번째): ' + PAY);
  Logger.log('지금 제출 후 화면 문구: ' + (plan.form.getConfirmationMessage() || '(비어 있음 — 구글 기본 문구가 나오는 중)'));
  Logger.log('→ 이 문구 끝에 카드결제 링크를 붙입니다.');
  Logger.log('문제 없음 → 이제 \'적용\' 을 실행하세요.');
}

function 적용() {
  const plan = check_();
  const form = plan.form;
  // '결제 방법' 안내는 2026-10-21 대표가 폼에서 직접 고침 (계좌번호 포함) → 스크립트는 건드리지 않음
  const now = form.getConfirmationMessage() || '';
  form.setConfirmationMessage(now ? now + '\n\n' + CONFIRM_ADD : CONFIRM_ADD);
  Logger.log('완료. 휴대폰으로 시험 응답 1건을 제출해서 제출 후 화면에 링크가 나오는지 확인해 주세요.');
}

/** 결제 방법 질문이 정확히 하나 있고, 아직 바뀌지 않았는지 확인. 아니면 아무것도 안 하고 멈춤 */
function check_() {
  const form = FormApp.openById(FORM_ID);
  if ((form.getConfirmationMessage() || '').indexOf(CARD_URL) !== -1) {
    throw new Error('이미 바뀐 폼입니다 (제출 후 화면에 카드결제 링크가 있음). 아무것도 하지 않았습니다.');
  }
  const pay = form.getItems().filter((it) => it.getTitle().trim() === PAY && it.getType() === FormApp.ItemType.MULTIPLE_CHOICE);
  if (pay.length !== 1) throw new Error('\'결제 방법\' 질문을 정확히 찾지 못했습니다 (' + pay.length + '개). 아무것도 하지 않았습니다.');
  return { form, pay: pay[0] };
}
