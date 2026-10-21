// 날짜·시간 계산 도우미
// - 운영 규칙(수강기간, 6시간 기준, 공휴일)은 모두 한국 시간(KST) 기준
// - 한국은 서머타임이 없으므로 KST = UTC+9 고정
// - 저장은 UTC(timestamptz), 학생·강사 화면은 각자의 IANA 시간대(예: Australia/Sydney)로 변환

export type KstDate = string; // 'YYYY-MM-DD' (한국 날짜)
export type KstTime = string; // 'HH:MM' (한국 시각, 24시간)

const KST_OFFSET_MS = 9 * 60 * 60 * 1000;
const DAY_MS = 24 * 60 * 60 * 1000;

const DATE_RE = /^(\d{4})-(\d{2})-(\d{2})$/;
const TIME_RE = /^([01]\d|2[0-3]):([0-5]\d)$/;

function parseDate(date: KstDate): [number, number, number] {
  const m = DATE_RE.exec(date);
  if (!m) throw new Error(`날짜 형식이 올바르지 않습니다: ${date}`);
  const [y, mo, d] = [Number(m[1]), Number(m[2]), Number(m[3])];
  const check = new Date(Date.UTC(y, mo - 1, d));
  if (check.getUTCFullYear() !== y || check.getUTCMonth() !== mo - 1 || check.getUTCDate() !== d) {
    throw new Error(`존재하지 않는 날짜입니다: ${date}`);
  }
  return [y, mo, d];
}

function parseTime(time: KstTime): [number, number] {
  const m = TIME_RE.exec(time);
  if (!m) throw new Error(`시각 형식이 올바르지 않습니다: ${time}`);
  return [Number(m[1]), Number(m[2])];
}

const pad = (n: number) => String(n).padStart(2, '0');

/** 한국 날짜에 일수를 더함 (시작일 포함 28일 = addDays(시작일, 27)) */
export function addDays(date: KstDate, days: number): KstDate {
  const [y, m, d] = parseDate(date);
  const t = new Date(Date.UTC(y, m - 1, d) + days * DAY_MS);
  return `${t.getUTCFullYear()}-${pad(t.getUTCMonth() + 1)}-${pad(t.getUTCDate())}`;
}

/** b - a (일) */
export function diffDays(a: KstDate, b: KstDate): number {
  const [y1, m1, d1] = parseDate(a);
  const [y2, m2, d2] = parseDate(b);
  return Math.round((Date.UTC(y2, m2 - 1, d2) - Date.UTC(y1, m1 - 1, d1)) / DAY_MS);
}

/** 요일: 0=일, 1=월 … 6=토 (한국 날짜 기준) */
export function weekdayOf(date: KstDate): number {
  const [y, m, d] = parseDate(date);
  return new Date(Date.UTC(y, m - 1, d)).getUTCDay();
}

export const WEEKDAY_KO = ['일', '월', '화', '수', '목', '금', '토'] as const;

/** 한국 날짜·시각 → 실제 시점(UTC) */
export function kstToInstant(date: KstDate, time: KstTime): Date {
  const [y, m, d] = parseDate(date);
  const [hh, mm] = parseTime(time);
  return new Date(Date.UTC(y, m - 1, d, hh, mm) - KST_OFFSET_MS);
}

/** 실제 시점 → 한국 날짜 */
export function instantToKstDate(instant: Date): KstDate {
  const t = new Date(instant.getTime() + KST_OFFSET_MS);
  return `${t.getUTCFullYear()}-${pad(t.getUTCMonth() + 1)}-${pad(t.getUTCDate())}`;
}

/** 한국 날짜의 23:59:59.999 (보강 기한 등 '그날 끝까지' 판단용) */
export function endOfKstDay(date: KstDate): Date {
  return new Date(kstToInstant(date, '00:00').getTime() + DAY_MS - 1);
}

/** 실제 시점을 특정 시간대의 현지 날짜·시각으로 (서머타임 자동 반영) */
export function formatInZone(instant: Date, timeZone: string): { date: string; time: string; weekday: string } {
  const parts = new Intl.DateTimeFormat('en-CA', {
    timeZone,
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
    hour: '2-digit',
    minute: '2-digit',
    weekday: 'short',
    hourCycle: 'h23',
  }).formatToParts(instant);
  const get = (type: string) => parts.find((p) => p.type === type)?.value ?? '';
  return {
    date: `${get('year')}-${get('month')}-${get('day')}`,
    time: `${get('hour')}:${get('minute')}`,
    weekday: get('weekday'),
  };
}

/** 두 시점 사이의 시간(시간 단위, 소수 포함) */
export function hoursBetween(from: Date, to: Date): number {
  return (to.getTime() - from.getTime()) / (60 * 60 * 1000);
}

/** 영업일(토·일·공휴일 제외)을 더함 — 시작 날짜 다음 날부터 셈. 공휴일 목록은 운영자가 등록한 holidays (POL-CHG-07) */
export function addBusinessDays(date: KstDate, n: number, holidays: ReadonlySet<KstDate>): KstDate {
  if (!Number.isInteger(n) || n < 1) throw new Error(`영업일 수가 올바르지 않습니다: ${n}`);
  let d = date;
  let left = n;
  while (left > 0) {
    d = addDays(d, 1);
    const w = weekdayOf(d);
    if (w !== 0 && w !== 6 && !holidays.has(d)) left--;
  }
  return d;
}
