import type { FormResponse, WishWindow } from './registration';
import { instantToKstDate } from '../rules/dates';

export type FormItem = { id: string; title: string; type: string; value: unknown; rows?: string[] };
export type GoogleApplication = { id: string; submittedAt: string; email: string; items: FormItem[] };
const text = (value: unknown): string => Array.isArray(value) ? value.map(text).join(', ') : typeof value === 'string' ? value.trim() : '';
const title = (s: string) => s.replace(/\s+/g, ' ').trim();

/** Read actual question responses, never duplicate/archived spreadsheet column positions. */
export function applicationFromGoogle(response: GoogleApplication): FormResponse {
  const get = (match: RegExp) => text(response.items.find(i => match.test(title(i.title)))?.value);
  const grid = response.items.find(i => i.type === 'CHECKBOX_GRID' && title(i.title) === '희망 수업 시작 시각 (지금 사는 곳의 시각 기준)');
  const wishes: WishWindow[] = [];
  if (grid && Array.isArray(grid.value)) grid.value.forEach((answer, index) => {
    const row = grid.rows?.[index] ?? '';
    const m = /^(오전|오후)\s*(\d{1,2}):(\d{2})$/.exec(row);
    if (!m) return;
    const hour = Number(m[2]) % 12 + (m[1] === '오후' ? 12 : 0);
    const from = `${String(hour).padStart(2, '0')}:${m[3]}`;
    // A checked row is a possible START, not a half-hour interval of possible starts.
    for (const day of (Array.isArray(answer) ? answer : [])) {
      const weekday = ['일', '월', '화', '수', '목', '금', '토'].indexOf(String(day));
      if (weekday >= 0) wishes.push({ weekday, from, to: from, startOnly: true });
    }
  });
  const country = get(/^지금 사는 나라$/);
  const city = get(/^사는 도시$/);
  return {
    ref: response.id, submittedAt: response.submittedAt,
    nameKo: get(/^성함을 적어주세요/), nameEn: get(/^성함을 영어 철자로/),
    email: get(/^이메일 주소$/) || response.email, phone: get(/^휴대폰 번호/),
    countryCity: country ? [country, city].filter(Boolean).join(' / ') : get(/^현재 거주 중인 국가와 도시/),
    ageGroup: get(/^연령대/), gender: get(/^성별/), concern: get(/^현재 영어 고민/),
    duration: get(/^수업 길이를/), weekly: get(/^수업 횟수를/), term: get(/^수강 기간/),
    desiredTime: get(/^희망 수업시간/), wishGrid: grid ? wishes : null,
    startWish: get(/^수업 시작 희망일/), payerName: get(/^입금자명/),
    paymentMethod: get(/^결제 방법$/) === '계좌이체' ? 'bank_transfer' : get(/^결제 방법$/) === '카드결제' ? 'card_link' : null,
    raw: response.items.map(i => [i.title, i === grid ? wishes.map(w => `${['일', '월', '화', '수', '목', '금', '토'][w.weekday]} ${w.from}`).join(', ') : text(i.value)]),
  };
}

/** All date filters use Korean submission dates, including UTC month/year boundaries. */
export function applicationDate(application: Pick<FormResponse, 'submittedAt'>): string {
  const value = application.submittedAt;
  if (/^\d{4}-\d{2}-\d{2}T.*(?:Z|[+-]\d{2}:?\d{2})$/.test(value)) return instantToKstDate(new Date(value));
  const match = /^(\d{4})[-./]\s*(\d{1,2})[-./]\s*(\d{1,2})/.exec(value);
  return match ? `${match[1]}-${match[2].padStart(2, '0')}-${match[3].padStart(2, '0')}` : '';
}
