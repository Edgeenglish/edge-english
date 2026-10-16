/**
 * 엣지영어 수강후기 공개 피드 (홈페이지가 5분마다 읽어 감)
 *
 * - 배포: 웹 앱, 실행 사용자 = 나, 액세스 권한 = 모든 사용자
 * - '공개'로 표시된 후기만, 홈페이지에 필요한 칸만 내보냄
 *   (비공개 후기·등록 일시 등은 Google 밖으로 나가지 않음)
 * - 배포 주소는 Vercel 환경변수 REVIEWS_FEED_URL 에만 저장
 * 설정 방법: docs/reviews-setup.md
 */

// 후기 시트 주소의 /d/ 와 /edit 사이 글자를 붙여넣기
const SPREADSHEET_ID = '여기에_후기_시트_ID_붙여넣기';
const SHEET_NAME = '후기';
const COL = { id: 0, brand: 1, date: 2, name: 3, job: 4, text: 5, highlight: 6, isPublic: 7, createdAt: 8 };

function doGet(e) {
  const brand = (e && e.parameter && e.parameter.brand) || '엣지영어';
  try {
    return json_({ reviews: getPublicReviews(brand) });
  } catch (error) {
    return json_({ error: String(error && error.message ? error.message : error) });
  }
}

function getPublicReviews(brand) {
  const sheet = SpreadsheetApp.openById(SPREADSHEET_ID).getSheetByName(SHEET_NAME);
  if (!sheet) throw new Error('후기 탭을 찾을 수 없습니다.');

  return sheet
    .getDataRange()
    .getValues()
    .slice(1)
    .filter((row) => isTrue_(row[COL.isPublic]) && String(row[COL.brand]) === brand && String(row[COL.text]).trim())
    .map((row, i) => ({
      id: String(row[COL.id] || 'row-' + i),
      date: toDateText_(row[COL.date]),
      name: maskName(row[COL.name]),
      job: String(row[COL.job] || '').trim(),
      text: String(row[COL.text]).trim(),
      highlight: String(row[COL.highlight] || '').trim(),
      createdAt: toStampText_(row[COL.createdAt]),
    }))
    .sort((a, b) => b.date.localeCompare(a.date) || b.createdAt.localeCompare(a.createdAt))
    .map(({ createdAt: _createdAt, ...review }) => review);
}

// 이름 중간 글자 가리기 (시트에 직접 입력한 경우 대비)
function maskName(raw) {
  const chars = Array.from(String(raw || '').replace(/\s+/g, ''));
  if (chars.length <= 1) return chars.join('');
  if (chars.length === 2) return chars[0] + 'O';
  return chars[0] + 'O'.repeat(chars.length - 2) + chars[chars.length - 1];
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

function json_(data) {
  return ContentService.createTextOutput(JSON.stringify(data)).setMimeType(ContentService.MimeType.JSON);
}
