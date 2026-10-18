// 신규 학생 등록 (2026-10-18 대표 최종 시안: C안 신청서 불러오기 + A안 직접 입력·스케줄)
// - 신청서(구글폼 응답) → 등록 초안 자동 채움. 운영자가 고칠 수 있고, 신청서가 없으면 직접 입력
// - 신청서 희망 시간은 자유 서술이라 그대로 보여 주고, 요일·시각은 운영자가 캘린더에서 고른다
// - 시간대는 신청서에 칸이 없어 거주 국가로 '추천'만 하고 운영자가 확인 (모르면 비워 둠)
// - 이메일이 같아도 기존 학생·계정에 자동 연결하지 않는다 (POL-AC-04). 같은 이메일이 있으면 알려 주기만

import type { AvailabilityWindow, Busy } from '../rules/booking';
import { diffDays, type KstDate } from '../rules/dates';
import { computePeriods } from '../rules/period';
import { CONFIRMED, type CourseWeeks } from '../rules/policy';
import type { RegularSlot } from '../rules/schedule';

/** 신청서 응답 1건 (응답 시트 한 줄). raw = 원본 칸 그대로 (원본 보기용) */
export type FormResponse = {
  ref: string; // 응답 시트 위치 (예: '응답 2026-10-15 14:22')
  submittedAt: string;
  nameKo: string;
  nameEn: string;
  email: string;
  phone: string;
  countryCity: string;
  ageGroup: string;
  gender: string;
  concern: string; // 영어 고민 / 학습 목표
  duration: string; // '50분'
  weekly: string; // '주 2회'
  term: string; // '12주'
  desiredTime: string; // 예전 신청서: 자유 서술 (그대로 보여 주기만)
  /** 새 신청서(제안): 요일 × 시간대 체크 → 학생 현지 시각 기준 칸. 예전 응답이면 null */
  wishGrid: WishWindow[] | null;
  startWish: string; // '2026-11-03' 또는 자유 서술
  payerName: string;
  raw: [string, string][];
};

/** 학생 희망 시간 한 칸 (학생 현지 요일·시각). 캘린더에서 날짜마다 한국 시각으로 바꿔 표시 → 서머타임 자동 */
export type WishWindow = { weekday: number; from: string; to: string };

export type Draft = {
  source: 'form' | 'manual';
  formRef: string | null;
  nameKo: string;
  nameEn: string;
  email: string;
  phone: string;
  country: string;
  city: string;
  timezone: string; // IANA. 비어 있으면 운영자가 골라야 함
  goal: string;
  desiredTime: string;
  wishes: WishWindow[];
  startWish: KstDate | '';
  durationMin: number | null;
  weeklyCount: number | null;
  weeks: CourseWeeks | null;
  memo: string;
};

export const EMPTY_DRAFT: Draft = {
  source: 'manual', formRef: null, nameKo: '', nameEn: '', email: '', phone: '', country: '', city: '', timezone: '',
  goal: '', desiredTime: '', wishes: [], startWish: '', durationMin: null, weeklyCount: null, weeks: null, memo: '',
};

const num = (s: string) => {
  const m = /(\d+)/.exec(s);
  return m ? Number(m[1]) : null;
};
const oneOf = <T extends number>(n: number | null, allowed: readonly T[]): T | null => (n !== null && (allowed as readonly number[]).includes(n) ? (n as T) : null);

/** 수강 기간: '4주'·'12주'·'24주' 또는 '1개월'·'3개월'·'6개월' (28일 단위 상품) */
function parseWeeks(s: string): CourseWeeks | null {
  const n = num(s);
  if (n === null) return null;
  if (/개월|달/.test(s)) return oneOf(n * 4, CONFIRMED.courseWeeks);
  return oneOf(n, CONFIRMED.courseWeeks);
}

function parseDate(s: string): KstDate | '' {
  const m = /(\d{4})[-./]\s*(\d{1,2})[-./]\s*(\d{1,2})/.exec(s);
  return m ? `${m[1]}-${m[2].padStart(2, '0')}-${m[3].padStart(2, '0')}` : '';
}

// 거주 국가 → 시간대 추천. 한 나라에 시간대가 여럿이면(미국·캐나다·호주 등) 도시로만 추천하고, 모르면 비워 둠
const COUNTRY_TZ: [RegExp, string][] = [
  [/한국|대한민국|korea|서울|seoul/i, 'Asia/Seoul'],
  [/일본|japan|도쿄|tokyo/i, 'Asia/Tokyo'],
  [/영국|uk|united kingdom|런던|london/i, 'Europe/London'],
  [/싱가포르|singapore/i, 'Asia/Singapore'],
  [/베트남|vietnam|호치민|하노이/i, 'Asia/Ho_Chi_Minh'],
  [/시드니|sydney|멜버른|melbourne/i, 'Australia/Sydney'],
  [/브리즈번|brisbane/i, 'Australia/Brisbane'],
  [/토론토|toronto|뉴욕|new york/i, 'America/Toronto'],
  [/밴쿠버|vancouver|la|로스앤젤레스|los angeles|샌프란시스코|시애틀/i, 'America/Los_Angeles'],
];

export function suggestTimezone(countryCity: string): string {
  return COUNTRY_TZ.find(([re]) => re.test(countryCity))?.[1] ?? '';
}

/** 신청서 → 등록 초안. 읽지 못한 칸은 비워 두고 checkDraft 가 '확인 필요'로 알려 줌 */
export function draftFromForm(f: FormResponse): Draft {
  const [country, ...cityParts] = f.countryCity.split(/[\/,·]/).map((x) => x.trim());
  return {
    source: 'form',
    formRef: f.ref,
    nameKo: f.nameKo.trim(),
    nameEn: f.nameEn.trim(),
    email: f.email.trim().toLowerCase(),
    phone: f.phone.trim(),
    country: country ?? '',
    city: cityParts.join(' '),
    timezone: suggestTimezone(f.countryCity),
    goal: f.concern.trim(),
    desiredTime: f.desiredTime.trim(),
    wishes: f.wishGrid ?? [],
    startWish: parseDate(f.startWish),
    durationMin: oneOf(num(f.duration), CONFIRMED.durations),
    weeklyCount: oneOf(num(f.weekly), CONFIRMED.weeklyCounts),
    weeks: parseWeeks(f.term),
    memo: '',
  };
}

export type DraftProblem = { field: keyof Draft; text: string };

const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

/** 학생 정보 단계에서 저장 전 확인할 것 */
export function checkDraft(d: Draft): DraftProblem[] {
  const p: DraftProblem[] = [];
  if (!d.nameKo.trim()) p.push({ field: 'nameKo', text: '한글 이름을 넣어 주세요' });
  if (!d.nameEn.trim()) p.push({ field: 'nameEn', text: '영문 이름을 넣어 주세요' });
  if (!EMAIL_RE.test(d.email.trim())) p.push({ field: 'email', text: '이메일 형식을 확인해 주세요' });
  if (!d.timezone) p.push({ field: 'timezone', text: '사는 곳 시간대를 골라 주세요' });
  if (d.durationMin === null) p.push({ field: 'durationMin', text: '수업 길이(20·40·50분)를 골라 주세요' });
  if (d.weeklyCount === null) p.push({ field: 'weeklyCount', text: '주 횟수를 골라 주세요' });
  if (d.weeks === null) p.push({ field: 'weeks', text: '수강 기간(4·12·24주)을 골라 주세요' });
  return p;
}

export type Payment = {
  status: 'unconfirmed' | 'confirmed';
  method: 'bank_transfer' | 'card_link' | null;
  amount: number | null;
  /** 실제 입금·결제 완료 시각 (ISO, 은행 거래내역·아임웹 주문 시각) */
  paidAt: string;
  /** 아임웹 주문번호·은행 거래 식별값 (같은 결제 두 번 기록 방지, 없으면 빈칸) */
  externalRef: string;
  payerName: string;
};

export const EMPTY_PAYMENT: Payment = { status: 'unconfirmed', method: null, amount: null, paidAt: '', externalRef: '', payerName: '' };

export function checkPayment(p: Payment): string[] {
  if (p.status !== 'confirmed') return [];
  const out: string[] = [];
  if (!p.method) out.push('결제 방법(계좌이체·아임웹 카드)을 골라 주세요');
  if (!p.amount || p.amount <= 0) out.push('받은 금액을 넣어 주세요');
  if (!p.paidAt) out.push('입금·결제 시각을 넣어 주세요');
  return out;
}

/** 최종 확인 요약: 기간·회차 (현행 상품만 — 28일 × 기간 수, 회차 = 주 횟수 × 주 수) */
export function planSummary(d: Pick<Draft, 'weeks' | 'weeklyCount'>, firstDate: KstDate | null) {
  if (!d.weeks || !d.weeklyCount || !firstDate) return null;
  const periods = computePeriods(firstDate, d.weeks);
  return { startDate: firstDate, endDate: periods[periods.length - 1].end, periods: periods.length, lessons: d.weeklyCount * d.weeks };
}

/** 고른 정규 시간과 주 횟수가 맞는지 (같은 요일 2번 불가는 generateRegularLessons 가 막음) */
export function slotProblem(slots: readonly RegularSlot[], weeklyCount: number | null): string | null {
  if (weeklyCount === null) return '주 횟수를 먼저 정해 주세요';
  if (slots.length < weeklyCount) return `정규 시간을 ${weeklyCount - slots.length}개 더 골라 주세요 (주 ${weeklyCount}회)`;
  if (slots.length > weeklyCount) return `주 ${weeklyCount}회라 ${slots.length - weeklyCount}개를 빼 주세요`;
  if (new Set(slots.map((s) => s.weekday)).size !== slots.length) return '같은 요일에 정규 수업을 2개 넣을 수 없어요';
  return null;
}

/** 첫 수업일이 희망 시작일보다 이르거나 오늘보다 앞이면 경고 (희망일은 참고라 막지는 않음) */
export function firstDateWarnings(first: KstDate, today: KstDate, wish: KstDate | ''): string[] {
  const w: string[] = [];
  if (diffDays(today, first) < 0) w.push('첫 수업일이 오늘보다 앞이에요');
  if (wish && diffDays(wish, first) < 0) w.push('학생 희망 시작일보다 빨라요');
  if (wish && diffDays(wish, first) > 14) w.push(`희망 시작일보다 ${diffDays(wish, first)}일 늦어요 — 학생 안내 필요`);
  return w;
}

/** 저장 요청 1건의 고유 번호. 같은 화면에서 저장을 여러 번 눌러도 이 번호가 같아 DB가 한 번만 만든다 */
export function newRequestId(): string {
  return crypto.randomUUID();
}

const WD = ['일', '월', '화', '수', '목', '금', '토'];

/** 희망 시간 요약: '화·목 19:00–22:00' (같은 시간대끼리 요일을 묶음) */
export function wishText(w: readonly WishWindow[]): string {
  const groups = new Map<string, number[]>();
  for (const x of w) groups.set(`${x.from}–${x.to}`, [...(groups.get(`${x.from}–${x.to}`) ?? []), x.weekday]);
  return [...groups].map(([range, days]) => `${days.sort((a, b) => ((a + 6) % 7) - ((b + 6) % 7)).map((d) => WD[d]).join('·')} ${range}`).join(', ');
}

/** 등록 화면에 필요한 강사 정보: 가능 시간(현지 시각) + 이미 잡힌 수업·휴무 */
export type RegTutor = {
  id: string;
  name: string;
  country: string;
  timezone: string;
  availability: AvailabilityWindow[];
  busy: Busy[];
};

/** 저장 요청 (DB 함수 admin_register_student 의 p 와 같은 모양) */
export function savePayload(d: Draft, slots: readonly RegularSlot[], tutorId: string | null, firstDate: KstDate, pay: Payment) {
  const paid = pay.status === 'confirmed';
  const memo = [d.goal && `학습 목표: ${d.goal}`, d.formRef && `신청서: ${d.formRef}`, d.memo].filter(Boolean).join('\n');
  return {
    student: { name_ko: d.nameKo.trim(), name_en: d.nameEn.trim(), email: d.email.trim().toLowerCase(), phone: d.phone.trim(), country: d.country.trim(), city: d.city.trim(), timezone: d.timezone, admin_memo: memo },
    course: { weeks: d.weeks, weekly_count: d.weeklyCount, duration_min: d.durationMin, start_date: firstDate, amount_due: pay.amount },
    // 결제 확인 전에는 강사·정규 일정을 보내지 않음 (DB도 거절 — POL-OP-13)
    tutor_id: paid ? tutorId : null,
    slots: paid && tutorId ? slots.map((s) => ({ weekday: s.weekday, time: s.time })) : [],
    payment: paid ? { method: pay.method, amount: pay.amount, paid_at: pay.paidAt, external_ref: pay.externalRef, payer_name: pay.payerName } : null,
  };
}
