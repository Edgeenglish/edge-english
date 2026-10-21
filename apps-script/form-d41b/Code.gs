/**
 * D-41 2차: 신청서(구글폼) 수업 시작 희망일·사는 도시 안내 바꾸기 — 한 번만 실행하는 스크립트 (2026-10-21)
 *
 * 대상: '미국·캐나다 원어민 1:1 화상수업 신청서' (support@edgeenglish.kr)
 * 바꾸는 것:
 *   '수업 시작 희망일을 알려주세요.' (글로 쓰기) → '첫 수업 희망 날짜' (날짜 고르기). 옛 질문은 1차 때 만든 '보관' 섹션으로 숨겨서 보관
 *   '사는 도시' 안내 문구 → 해외 거주자는 꼭 적도록
 * - 필수 여부는 옛 질문과 같게. 예전 응답·다른 질문·시트 연결은 건드리지 않음
 * - 수업 길이·횟수, 학습 목적(글 칸)은 그대로 (2026-10-21 대표)
 *
 * 쓰는 법: 1) 미리보기 실행 → 실행 로그 확인  2) 적용 실행  (두 번 실행해도 두 번 바뀌지 않음)
 */

const FORM_ID = '163rAf9Jn-bCxNN8Px38G2BgUTfK-AeixxIlTLedjXNs';

const OLD_START = '수업 시작 희망일';
const NEW_START = '첫 수업 희망 날짜';
const CITY = '사는 도시';
const ARCHIVE = '보관: 예전 질문 (학생에게 안 보임)';

const START_HELP = '수업을 시작할 수 있는 가장 빠른 날짜를 골라 주세요.\n※ 강사 매칭 및 등록 일정에 따라 실제 시작일이 달라질 수 있습니다';
const CITY_HELP = '해외에 사시면 꼭 적어 주세요. 같은 나라 안에서도 도시마다 시간이 달라요.\n예) 시드니, 멜버른, 토론토, 밴쿠버. 한국에 사시면 비워 두셔도 돼요.';

function 미리보기() {
  const plan = check_();
  Logger.log('폼: ' + plan.form.getTitle());
  Logger.log('바꿀 질문 (' + (plan.start.getIndex() + 1) + '번째): ' + firstLine_(plan.start.getTitle()) + ' / 필수: ' + (isRequired_(plan.start) ? '예' : '아니오'));
  Logger.log('안내 바꿀 질문 (' + (plan.city.getIndex() + 1) + '번째): ' + plan.city.getTitle());
  Logger.log('보관 섹션 (' + (plan.archive.getIndex() + 1) + '번째) 안으로 옛 질문을 옮깁니다.');
  Logger.log('문제 없음 → 이제 \'적용\' 을 실행하세요.');
}

function 적용() {
  const plan = check_();
  const form = plan.form;

  const at = plan.start.getIndex();
  const required = isRequired_(plan.start);
  const date = form.addDateItem().setTitle(NEW_START).setHelpText(START_HELP).setIncludesYear(true).setRequired(required);
  form.moveItem(date.getIndex(), at); // 옛 질문 자리
  unrequire_(plan.start);
  form.moveItem(plan.start.getIndex(), form.getItems().length - 1); // 맨 끝 = 보관 섹션 안

  plan.city.asTextItem().setHelpText(CITY_HELP);

  Logger.log('완료. 폼 미리보기(눈 모양)로 확인한 뒤 시험 응답 1건을 제출해 주세요.');
}

/** 바꿀 질문이 정확히 하나씩 있고, 보관 섹션이 맨 끝에 있고, 이미 바뀐 상태가 아닌지 확인. 아니면 아무것도 안 하고 멈춤 */
function check_() {
  const form = FormApp.openById(FORM_ID);
  const items = form.getItems();
  const find = (prefix) => items.filter((it) => it.getTitle().trim().indexOf(prefix) === 0);
  if (find(NEW_START).length) throw new Error('이미 바뀐 폼입니다 (첫 수업 희망 날짜 질문이 있음). 아무것도 하지 않았습니다.');
  const start = find(OLD_START);
  const city = items.filter((it) => it.getTitle().trim() === CITY && it.getType() === FormApp.ItemType.TEXT);
  const archive = find(ARCHIVE).filter((it) => it.getType() === FormApp.ItemType.PAGE_BREAK);
  if (start.length !== 1 || city.length !== 1 || archive.length !== 1) {
    throw new Error('바꿀 질문을 정확히 찾지 못했습니다 (시작 희망일 ' + start.length + '개, 사는 도시 ' + city.length + '개, 보관 섹션 ' + archive.length + '개). 아무것도 하지 않았습니다.');
  }
  if (start[0].getIndex() > archive[0].getIndex()) throw new Error('시작 희망일 질문이 이미 보관 섹션 안에 있습니다. 아무것도 하지 않았습니다.');
  return { form, start: start[0], city: city[0], archive: archive[0] };
}

function isRequired_(item) {
  const t = item.getType();
  if (t === FormApp.ItemType.TEXT) return item.asTextItem().isRequired();
  if (t === FormApp.ItemType.PARAGRAPH_TEXT) return item.asParagraphTextItem().isRequired();
  if (t === FormApp.ItemType.DATE) return item.asDateItem().isRequired();
  return true;
}

/** 옛 질문은 지우지 않고 '필수'만 풀기 (보관 섹션에 있어도 혹시 보이게 되돌렸을 때 막히지 않게) */
function unrequire_(item) {
  const t = item.getType();
  if (t === FormApp.ItemType.TEXT) item.asTextItem().setRequired(false);
  else if (t === FormApp.ItemType.PARAGRAPH_TEXT) item.asParagraphTextItem().setRequired(false);
  else if (t === FormApp.ItemType.DATE) item.asDateItem().setRequired(false);
  else Logger.log('옛 질문 형식이 예상과 달라 필수 여부를 그대로 둠: ' + t);
}

function firstLine_(s) {
  return String(s).split('\n')[0];
}
