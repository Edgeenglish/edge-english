/**
 * 엣지영어 수강후기 관리 화면 (Google 시트에 연결된 Apps Script)
 *
 * - 배포: 웹 앱, 실행 사용자 = 나, 액세스 권한 = 나만
 *   → 관리자 구글 계정(support@edgeenglish.kr)으로 로그인했을 때만 열림
 * - 후기는 이 시트의 '후기' 탭에 저장됨
 * - 홈페이지에는 별도의 '공개 피드'(apps-script/feed) 가 공개 후기만 전달함
 * 설정 방법: docs/reviews-setup.md
 */

// 홈페이지 주소 (등록 즉시 반영·반영 상태 확인용). 앞에 있는 주소부터 확인
const SITE_URLS = ['https://edgeenglish.kr'];
// Vercel 환경변수 REVIEWS_REFRESH_SECRET 과 같은 값
const REFRESH_SECRET = '여기에_반영_비밀값_붙여넣기';

const SHEET_NAME = '후기';
const HEADERS = ['id', '브랜드', '날짜', '이름', '직업', '후기', '대표 문장', '공개', '등록 일시', '수정 일시', '강사'];
const COL = { id: 0, brand: 1, date: 2, name: 3, job: 4, text: 5, highlight: 6, isPublic: 7, createdAt: 8, updatedAt: 9, tutor: 10 };
// 관리용 강사 목록 (홈페이지에는 표시 안 함). 시트의 '강사' 탭 A열을 고치면 관리 화면 버튼이 바뀜
const TUTOR_SHEET_NAME = '강사';
const DEFAULT_TUTORS = ['Grace', 'Kai', 'Maria', 'Benny', 'Leslie', 'Olivia'];
const BRANDS = ['엣지영어', '영붙캠'];

function doGet() {
  return HtmlService.createHtmlOutputFromFile('Admin')
    .setTitle('엣지영어 후기 관리')
    .addMetaTag('viewport', 'width=device-width, initial-scale=1');
}

/* ---------- 화면에서 부르는 기능 ---------- */

function listReviews(brand) {
  return readAll_()
    .filter((r) => r.brand === brand)
    .sort((a, b) => b.date.localeCompare(a.date) || b.createdAt.localeCompare(a.createdAt))
    .map(toClient_);
}

function saveReview(input) {
  const review = validate_(input);
  return afterWrite_(() => withLock_(() => {
    const sheet = getSheet_();
    const now = timestamp_();

    if (review.id) {
      const found = findRow_(review.id);
      if (!found) throw new Error('수정할 후기를 찾지 못했어요. 목록을 새로고침해 주세요.');
      const row = rowValues_({ ...found, ...review, createdAt: found.createdAt, updatedAt: now });
      sheet.getRange(found.rowNumber, 1, 1, HEADERS.length).setValues([row]);
      return toClient_(fromRow_(row));
    }

    const created = { ...review, id: Utilities.getUuid(), createdAt: now, updatedAt: now };
    writeNewRow_(sheet, rowValues_(created));
    return toClient_(created);
  }));
}

function setPublic(id, isPublic) {
  return afterWrite_(() => withLock_(() => {
    const found = findRow_(id);
    if (!found) throw new Error('후기를 찾지 못했어요. 목록을 새로고침해 주세요.');
    const sheet = getSheet_();
    sheet.getRange(found.rowNumber, COL.isPublic + 1).setValue(Boolean(isPublic));
    sheet.getRange(found.rowNumber, COL.updatedAt + 1).setValue(timestamp_());
    return true;
  }));
}

function deleteReview(id) {
  return afterWrite_(() => withLock_(() => {
    const found = findRow_(id);
    if (!found) throw new Error('이미 삭제된 후기예요.');
    getSheet_().deleteRow(found.rowNumber);
    return true;
  }));
}

// 홈페이지에 지금 떠 있는 공개 후기 id (관리 화면의 '반영 완료/반영 중' 표시용)
function getSiteStatus() {
  for (const base of SITE_URLS) {
    try {
      const res = UrlFetchApp.fetch(base + '/api/reviews/status', { muteHttpExceptions: true, followRedirects: true });
      if (res.getResponseCode() !== 200) continue;
      const data = JSON.parse(res.getContentText());
      if (Array.isArray(data.ids)) return { ok: true, source: data.source, ids: data.ids };
    } catch (e) {
      // 다음 주소 확인
    }
  }
  return { ok: false };
}

// Apps Script 편집기에서 한 번 실행: 외부 연결 권한 허용 + 홈페이지 연결 확인
function checkSite() {
  const refreshed = notifySite_();
  const status = getSiteStatus();
  const msg = '즉시 반영 알림: ' + (refreshed ? '성공' : '실패(비밀값·주소 확인)') + ' / 반영 상태 확인: ' + (status.ok ? '성공 (' + status.source + ', 공개 ' + status.ids.length + '개)' : '실패');
  Logger.log(msg);
  return msg;
}

// 관리 화면 강사 버튼 목록 ('강사' 탭이 없으면 기본 목록으로 만듦)
function getTutors() {
  const ss = SpreadsheetApp.getActive();
  let sheet = ss.getSheetByName(TUTOR_SHEET_NAME);
  if (!sheet) {
    sheet = ss.insertSheet(TUTOR_SHEET_NAME);
    sheet.getRange(1, 1, DEFAULT_TUTORS.length + 1, 1).setValues([['강사 이름']].concat(DEFAULT_TUTORS.map((t) => [t])));
    sheet.getRange(1, 1).setFontWeight('bold');
  }
  return sheet.getDataRange().getValues().slice(1).map((row) => String(row[0]).trim()).filter(Boolean);
}

/* ---------- 처음 한 번 실행: 시트 준비 + 기존 홈페이지 후기 6개 옮기기 ---------- */

function setup() {
  const ss = SpreadsheetApp.getActive();
  let sheet = ss.getSheetByName(SHEET_NAME);
  if (!sheet) sheet = ss.insertSheet(SHEET_NAME);

  sheet.getRange(1, 1, 1, HEADERS.length).setValues([HEADERS]).setFontWeight('bold');
  sheet.setFrozenRows(1);
  sheet.getRange('C:C').setNumberFormat('@'); // 날짜를 글자(YYYY-MM-DD) 그대로 저장
  sheet.setColumnWidth(COL.text + 1, 420);
  sheet.hideColumns(COL.id + 1);
  clearEmptyRows_(sheet);

  if (lastReviewRow_(sheet) <= 1) {
    const now = timestamp_();
    LEGACY_REVIEWS.forEach((r, i) => {
      writeNewRow_(sheet, rowValues_({ ...r, id: Utilities.getUuid(), brand: '엣지영어', date: '', isPublic: true, createdAt: now + '-' + i, updatedAt: now }));
    });
  }
  return '준비 완료';
}

// 기존 홈페이지 후기 (받은 날짜를 몰라 비워 둠 → 관리 화면에서 날짜 입력)
const LEGACY_REVIEWS = [
  { name: '유OO', job: '직장인', highlight: '미국, 캐나다 영어 선생님들에게서 본토 발음을 배울 수 있어서 너무 좋아요.', text: '엣지영어 최고! 다른 플랫폼은 필리핀 선생님들이 많아서 발음이 조금 아쉬웠는데, 여기서는 미국, 캐나다 영어 선생님들에게서 본토 발음을 배울 수 있어서 너무 좋아요. 수업 들을 때마다 영어에 더 자신감이 생기는 느낌이에요!' },
  { name: '김OO', job: '', highlight: '처음이라 엄청 긴장했는데, 막상 수업 들어보니까 생각보다 훨씬 편하고 재밌었어요.', text: '화상영어는 처음이라 엄청 긴장했는데, 막상 수업 들어보니까 생각보다 훨씬 편하고 재밌었어요. 화면 너머 강사님이 밝게 인사해 주시고, 천천히 말해주시니까 금방 적응됐어요. 영어와 외국인 울렁증이 심했던 저한텐 큰 도전이었는데, 지금은 수업 기다려지는 저 자신이 신기해요.' },
  { name: '정OO', job: '대학생', highlight: '매주 같은 요일, 같은 시간에 수업이 있어서 영어 공부 루틴이 자연스럽게 생겼어요.', text: '매주 같은 요일, 같은 시간에 수업이 있어서 영어 공부 루틴이 자연스럽게 생겼어요. 예전엔 영어가 늘 뒷전이었는데, 지금은 정해진 시간에 딱 집중할 수 있어서 빠지지 않고 계속하게 되네요. 강사님이 지난 수업에서 다뤘던 표현도 먼저 다시 짚어주시니까, 그때 배운 게 머릿속에 계속 남아요. 영어가 점점 몸에 익어가는 기분입니다!!' },
  { name: '김OO', job: '직장인', highlight: '첫 수업이었는데 생각했던 것보다 더 좋았어요.', text: '오늘 강사님과 첫 수업이었는데 생각했던 것보다 더 좋았어요. 자연스럽게 대화를 이어갈 수 있게 이끌어주셔서 40분이 금방 지나갔어요:)' },
  { name: '최OO', job: '전업주부', highlight: '서투르게 말한 문장을 하나하나 워드에 적어 주시고, 같이 보면서 바로 고쳐 주셨어요.', text: '강사님께서 제가 서투르게 말한 문장을 하나하나 워드에 적어 주시고, 같이 보면서 바로 고쳐 주셨어요. 매 수업마다 제 문장을 함께 수정하고 따라 읽는 과정을 반복하다 보니, 어느새 자연스럽게 영어 문장을 말하고 있는 제 모습을 발견했답니다. 평생 콤플렉스였던 영어를 이렇게 재미있게 배울 수 있었다니, 정말 신기하고 감사할 따름입니다!' },
  { name: '이OO', job: '직장인', highlight: '수업 후 유용한 표현들을 정리해서 피드백으로 보내주세요.', text: '수업을 그냥 듣고 끝나는 게 아니라, 강사님이 수업 후 유용한 표현들을 정리해서 피드백으로 보내주세요. 그날 배운 내용을 다시 복습해 주면 머릿속에 확실히 남아요. 덕분에 영어 실력이 더 빨리 느는 것 같아요~!' },
];

/* ---------- 내부 도구 ---------- */

// 이름 중간 글자 가리기: 김민 → 김O, 김민수 → 김O수, 남궁민수 → 남OO수 (이미 가린 이름은 그대로)
function maskName(raw) {
  const chars = Array.from(String(raw || '').replace(/\s+/g, ''));
  if (chars.length <= 1) return chars.join('');
  if (chars.length === 2) return chars[0] + 'O';
  return chars[0] + 'O'.repeat(chars.length - 2) + chars[chars.length - 1];
}

function validate_(input) {
  const r = {
    id: String(input.id || ''),
    brand: String(input.brand || ''),
    date: String(input.date || ''),
    name: maskName(input.name),
    job: String(input.job || '').trim(),
    text: String(input.text || '').trim(),
    highlight: String(input.highlight || '').trim(),
    isPublic: input.isPublic !== false,
    tutor: String(input.tutor || '').trim(),
  };
  if (BRANDS.indexOf(r.brand) < 0) throw new Error('브랜드를 선택해 주세요.');
  if (!r.text) throw new Error('후기 내용을 붙여넣어 주세요.');
  if (!r.name) throw new Error('수강생 이름을 입력해 주세요.');
  if (!/^\d{4}-\d{2}-\d{2}$/.test(r.date)) throw new Error('날짜를 선택해 주세요.');
  return r;
}

function getSheet_() {
  const sheet = SpreadsheetApp.getActive().getSheetByName(SHEET_NAME);
  if (sheet) {
    // 예전 버전으로 만든 시트에 '강사' 칸 제목 추가
    const header = sheet.getRange(1, COL.tutor + 1);
    if (!String(header.getValue()).trim()) header.setValue(HEADERS[COL.tutor]).setFontWeight('bold');
    return sheet;
  }
  setup();
  return SpreadsheetApp.getActive().getSheetByName(SHEET_NAME);
}

function readAll_() {
  const sheet = getSheet_();
  const values = sheet.getDataRange().getValues();
  const list = [];
  for (let i = 1; i < values.length; i++) {
    const r = fromRow_(values[i]);
    if (!r.text && !r.name) continue; // 빈 줄
    if (!r.id) {
      // 시트에 직접 입력한 줄에는 id 를 채워 줌
      r.id = Utilities.getUuid();
      sheet.getRange(i + 1, COL.id + 1).setValue(r.id);
    }
    r.rowNumber = i + 1;
    list.push(r);
  }
  return list;
}

// 후기(내용 또는 이름)가 있는 마지막 줄 번호. 빈 체크박스 줄은 세지 않음
function lastReviewRow_(sheet) {
  const values = sheet.getDataRange().getValues();
  for (let i = values.length - 1; i >= 1; i--) {
    if (String(values[i][COL.text]).trim() || String(values[i][COL.name]).trim()) return i + 1;
  }
  return 1;
}

// 마지막 후기 바로 다음 줄에 쓰고, 그 줄의 '공개' 칸만 체크박스로
function writeNewRow_(sheet, row) {
  const rowNumber = lastReviewRow_(sheet) + 1;
  sheet.getRange(rowNumber, 1, 1, HEADERS.length).setValues([row]);
  sheet.getRange(rowNumber, COL.isPublic + 1).setDataValidation(SpreadsheetApp.newDataValidation().requireCheckbox().build());
}

// 후기가 없는 줄에 남은 체크박스·값 지우기 (이전 버전이 열 전체에 깔아 둔 체크박스 정리)
function clearEmptyRows_(sheet) {
  const from = lastReviewRow_(sheet) + 1;
  const to = sheet.getMaxRows();
  if (to >= from) sheet.getRange(from, 1, to - from + 1, HEADERS.length).clearDataValidations().clearContent();
}

function findRow_(id) {
  return readAll_().find((r) => r.id === id) || null;
}

function fromRow_(row) {
  return {
    id: String(row[COL.id] || ''),
    brand: String(row[COL.brand] || ''),
    date: toDateText_(row[COL.date]),
    name: String(row[COL.name] || ''),
    job: String(row[COL.job] || ''),
    text: String(row[COL.text] || ''),
    highlight: String(row[COL.highlight] || ''),
    isPublic: isTrue_(row[COL.isPublic]),
    createdAt: toStampText_(row[COL.createdAt]),
    updatedAt: toStampText_(row[COL.updatedAt]),
    tutor: String(row[COL.tutor] || '').trim(),
  };
}

function rowValues_(r) {
  const row = [];
  row[COL.id] = r.id;
  row[COL.brand] = r.brand;
  row[COL.date] = r.date;
  row[COL.name] = r.name;
  row[COL.job] = r.job;
  row[COL.text] = r.text;
  row[COL.highlight] = r.highlight;
  row[COL.isPublic] = Boolean(r.isPublic);
  row[COL.createdAt] = r.createdAt;
  row[COL.updatedAt] = r.updatedAt;
  row[COL.tutor] = r.tutor || '';
  return row;
}

function toClient_(r) {
  return { id: r.id, brand: r.brand, date: r.date, name: r.name, job: r.job, text: r.text, highlight: r.highlight, isPublic: r.isPublic, createdAt: r.createdAt.slice(0, 16), tutor: r.tutor };
}

// 시트를 바꾼 뒤 홈페이지에 바로 알림 (실패해도 홈페이지는 5분 안에 스스로 갱신)
function afterWrite_(fn) {
  const result = fn();
  notifySite_();
  return result;
}

function notifySite_() {
  let ok = false;
  SITE_URLS.forEach((base) => {
    try {
      const res = UrlFetchApp.fetch(base + '/api/reviews/refresh', {
        method: 'post',
        contentType: 'application/json',
        payload: JSON.stringify({ secret: REFRESH_SECRET }),
        muteHttpExceptions: true,
      });
      if (res.getResponseCode() === 200) ok = true;
    } catch (e) {
      // 무시: 5분 자동 갱신으로 반영됨
    }
  });
  return ok;
}

function toDateText_(v) {
  if (v instanceof Date) return Utilities.formatDate(v, Session.getScriptTimeZone(), 'yyyy-MM-dd');
  return String(v || '').trim().replace(/\./g, '-');
}

// 시트가 '2026-10-16 14:50:00' 같은 글자를 날짜로 바꿔 저장해도 다시 같은 글자로 읽기
function toStampText_(v) {
  if (v instanceof Date) return Utilities.formatDate(v, 'Asia/Seoul', 'yyyy-MM-dd HH:mm:ss');
  return String(v || '');
}

function isTrue_(v) {
  return v === true || /^(true|공개|y|yes|o)$/i.test(String(v).trim());
}

function timestamp_() {
  return Utilities.formatDate(new Date(), 'Asia/Seoul', 'yyyy-MM-dd HH:mm:ss');
}

function withLock_(fn) {
  const lock = LockService.getScriptLock();
  lock.waitLock(10000);
  try {
    return fn();
  } finally {
    lock.releaseLock();
  }
}
