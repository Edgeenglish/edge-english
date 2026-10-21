/**
 * D-41 신청서(구글폼) 희망 시간·거주지 질문 바꾸기 — 한 번만 실행하는 스크립트 (2026-10-18)
 *
 * 대상: '미국·캐나다 원어민 1:1 화상수업 신청서' (support@edgeenglish.kr)
 * 바꾸는 것:
 *   '희망 수업시간' (자유 서술)          → 희망 수업 시작 시각 (요일 × 30분 단위 시작 시각 체크, 지금 사는 곳 시각)
 *   '현재 거주 중인 국가와 도시' (자유 서술) → 사는 나라 (객관식 + 기타) + 사는 도시
 * - 2026-10-18 대표: 옛 질문은 삭제하지 않음 → 새 질문을 옛 질문 바로 앞에 넣고, 옛 질문은 '필수'만 풀어 둠 (건너뛸 수 있게)
 *   나중에 옛 질문을 지울지는 대표가 결정. 예전 응답은 응답 시트에 그대로
 * - 다른 질문·응답·시트 연결은 건드리지 않음
 * - 백업: 같은 드라이브에 '[백업 2026-10-18, 수정 전] …' 사본 (Claude가 미리 만들어 둠)
 *
 * 쓰는 법: 1) 미리보기 실행 → 실행 로그 확인  2) 적용 실행  (두 번 실행해도 두 번 바뀌지 않음)
 */

const FORM_ID = '163rAf9Jn-bCxNN8Px38G2BgUTfK-AeixxIlTLedjXNs';

const OLD_TIME = '희망 수업시간';
const OLD_PLACE = '현재 거주 중인 국가와 도시';

const NEW_GRID = '희망 수업 시작 시각 (지금 사는 곳의 시각 기준)';
const NEW_COUNTRY = '지금 사는 나라';
const NEW_CITY = '사는 도시';

const DAYS = ['월', '화', '수', '목', '금', '토', '일'];
// 06:00 ~ 23:30, 30분 단위 시작 시각 (줄). 칸은 요일 7개 — 휴대폰에서 칸이 7개여야 한 화면에 들어감
const STARTS = (() => {
  const out = [];
  for (let m = 6 * 60; m < 24 * 60; m += 30) {
    const h = Math.floor(m / 60);
    const ampm = h < 12 ? '오전' : '오후';
    const h12 = h % 12 === 0 ? 12 : h % 12;
    out.push(ampm + ' ' + h12 + ':' + (m % 60 === 0 ? '00' : '30'));
  }
  return out;
})();
const COUNTRIES = ['한국', '호주', '미국', '캐나다', '뉴질랜드', '싱가포르'];

function 미리보기() {
  const plan = check_();
  Logger.log('폼: ' + plan.form.getTitle());
  Logger.log('바꿀 질문 1 (' + (plan.time.getIndex() + 1) + '번째): ' + firstLine_(plan.time.getTitle()));
  Logger.log('바꿀 질문 2 (' + (plan.place.getIndex() + 1) + '번째): ' + firstLine_(plan.place.getTitle()));
  Logger.log('문제 없음 → 이제 \'적용\' 을 실행하세요.');
}

function 적용() {
  const plan = check_();
  const form = plan.form;

  // 뒤쪽 질문부터 넣어야 앞쪽 질문 위치가 안 밀림
  const [first, second] = plan.time.getIndex() > plan.place.getIndex() ? ['time', 'place'] : ['place', 'time'];
  [first, second].forEach((k) => (k === 'time' ? replaceTime_(form, plan.time) : replacePlace_(form, plan.place)));

  Logger.log('완료. 폼 미리보기(눈 모양)로 확인한 뒤 시험 응답 1건을 제출해 주세요.');
}

function replaceTime_(form, old) {
  const at = old.getIndex();
  const grid = form.addCheckboxGridItem()
    .setTitle(NEW_GRID)
    .setHelpText('수업을 시작할 수 있는 시각을 요일마다 모두 골라 주세요. 많이 고를수록 강사 매칭이 빨라요.\n예) 화·목 저녁 7시 30분 시작 → \'오후 7:30\' 줄의 화·목 칸\n해외에 계시면 한국 시각이 아니라 지금 계신 곳의 시각으로 골라 주세요.')
    .setRows(STARTS)
    .setColumns(DAYS);
  form.moveItem(grid, at); // 옛 질문 바로 앞
  unrequire_(old);
}

function replacePlace_(form, old) {
  const at = old.getIndex();
  const country = form.addMultipleChoiceItem()
    .setTitle(NEW_COUNTRY)
    .setHelpText('수업 시간을 정확히 맞추려고 여쭤봐요. 목록에 없으면 \'기타\'에 적어 주세요.');
  country.setChoiceValues(COUNTRIES).showOtherOption(true).setRequired(true);
  const city = form.addTextItem()
    .setTitle(NEW_CITY)
    .setHelpText('예) 시드니, 멜버른, 토론토, 밴쿠버. 한국에 사시면 비워 두셔도 돼요.');
  form.moveItem(country, at); // 옛 질문 바로 앞
  form.moveItem(city, at + 1);
  unrequire_(old);
}

/** 바꿀 질문이 정확히 하나씩 있고, 이미 바뀐 상태가 아닌지 확인. 아니면 아무것도 안 하고 멈춤 */
function check_() {
  const form = FormApp.openById(FORM_ID);
  const items = form.getItems();
  const find = (prefix) => items.filter((it) => it.getTitle().trim().indexOf(prefix) === 0);
  if (find(NEW_GRID).length || find(NEW_COUNTRY).length) {
    throw new Error('이미 바뀐 폼입니다 (새 질문이 있음). 아무것도 하지 않았습니다.');
  }
  const time = find(OLD_TIME);
  const place = find(OLD_PLACE);
  if (time.length !== 1 || place.length !== 1) {
    throw new Error('바꿀 질문을 정확히 찾지 못했습니다 (희망 수업시간 ' + time.length + '개, 국가와 도시 ' + place.length + '개). 아무것도 하지 않았습니다.');
  }
  return { form, time: time[0], place: place[0] };
}

/** 옛 질문은 지우지 않고 '필수'만 풀기 (새 질문과 둘 다 답해야 하는 일이 없게) */
function unrequire_(item) {
  const t = item.getType();
  if (t === FormApp.ItemType.TEXT) item.asTextItem().setRequired(false);
  else if (t === FormApp.ItemType.PARAGRAPH_TEXT) item.asParagraphTextItem().setRequired(false);
  else Logger.log('옛 질문 형식이 서술형이 아니라 필수 여부를 그대로 둠: ' + t);
}

function firstLine_(s) {
  return String(s).split('\n')[0];
}
