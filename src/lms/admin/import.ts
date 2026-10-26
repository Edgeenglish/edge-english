// 기존 학생 입력 (D-52, 정책 원본 H23(3) → 확대판 H26(9) → 시안 2, 2026-10-26 대표 승인)
// 카드 순서: 학생 → 현재 수강권 → 강사·정규 수업 → 미완료 보강 → 남은 수업 대조 → 확인·저장
// - 수강권: 상품 + 수강 시작일(시트 '첫번째 수강 기간' 시작일) → 28일 기간 자동, 지금 기간은 오늘 날짜로 자동(다르면 고침)
//   종료일은 마지막 기간 끝으로 자동. 시트 종료일과 다르면 차이·이유(강사 장기 휴무 연장 / 학생 장기 연기(24주) / 기타) — 저장은 막지 않음
// - 정규 수업은 첫 정규 수업일 ~ 28일 기간 계산 끝까지만. 연장으로 늘어난 날에는 정규를 만들지 않음 (A41 ④: 연장 = 기간 확대, 새 수업 아님)
// - 미완료 보강: 없으면 건너뜀. 예약됨/미예약 + 원래 수업 날짜(모르면 '날짜 확인 필요'). 원래 날짜가 첫 정규 수업일 이후면 그날 정규는 안 만듦
// - 수업 날짜 추가: 실제로 받아야 하는 수업 (근거 필수, 그날 하나만)
// - 남은 수업 = 정규 + 예약 보강 + 미예약 보강 + 추가. 시트(총 수업 수 − 이미 진행·차감된 수)와 달라도 저장, 차이는 처리할 일로
// - 화면 검사는 편의. 저장 때 DB(admin_import_existing_student, migration 1600)가 같은 규칙으로 다시 검사

import { clashes, type Busy } from '../rules/booking';
import { addDays, diffDays, kstToInstant, weekdayOf, type KstDate, type KstTime } from '../rules/dates';
import { creditsPerPeriod } from '../rules/policy';
import type { RegTutor } from './registration';
import { dayLabel, WEEKDAY_KO } from './schedule';

export type ImportSlot = { weekday: number; time: KstTime };
export type ImportMakeup = {
  status: 'booked' | 'open';
  /** 원래 수업 날짜. 시트에서 알 수 없으면 비우고 originUnknown (가짜 날짜 금지) */
  originalDate: KstDate | '';
  originUnknown: boolean;
  /** 예약됨일 때만 */
  date: KstDate | '';
  time: KstTime | '';
  durationMin: number;
  tutorId: string;
};
export type ImportExtra = { date: KstDate | ''; time: KstTime | ''; reason: string };
export type ImportWeeks = 4 | 12 | 24;
/** 종료일이 기간 계산과 다를 때 이유 (enrollment_extensions.reason 과 같은 값, 2026-10-26 대표: 3가지만) */
export type EndReason = 'tutor_long_term_leave' | 'student_long_term_leave' | 'admin_exception';
export const END_REASON_TEXT: Record<EndReason, string> = {
  tutor_long_term_leave: '강사 장기 휴무 연장',
  student_long_term_leave: '학생 장기 연기(24주)',
  admin_exception: '기타(메모)',
};

export type ImportDraft = {
  /** 화면을 연 날 (KST). 지금 기간·첫 정규 수업일 자동 계산 기준 */
  today: KstDate;
  nameKo: string;
  nameEn: string;
  email: string;
  phone: string;
  timezone: string;
  memo: string;
  tutorId: string;
  durationMin: number | null;
  slots: ImportSlot[];
  /** 앞으로 남은 첫 정규 수업일 (자동: 오늘 이후 첫 수업 요일, 고칠 수 있음) */
  fromDate: KstDate;
  endDate: KstDate | '';
  endReason: EndReason | '';
  endNote: string;
  hasMakeups: boolean;
  makeups: ImportMakeup[];
  extras: ImportExtra[];
  /** 시트보다 많을 때 운영진이 뺀 정규 수업 날짜 */
  skipDates: KstDate[];
  weeks: ImportWeeks | null;
  /** 수강 시작일 = 1기간 시작 (시트 '첫번째 수강 기간') */
  courseStart: KstDate | '';
  /** 지금 기간을 오늘 날짜 계산과 다르게 고친 경우만 */
  periodOverride: number | null;
  creditsLeft: number | null;
  /** 시트의 등록 총 수업 수 · 이미 진행·차감된 수 (Class Status 기준, 회차 번호 아님) */
  sheetTotal: number | null;
  sheetUsed: number | null;
};

export const emptyImport = (today: KstDate): ImportDraft => ({
  today, nameKo: '', nameEn: '', email: '', phone: '', timezone: 'Asia/Seoul', memo: '',
  tutorId: '', durationMin: 50, slots: [{ weekday: 1, time: '' }], fromDate: today, endDate: '', endReason: '', endNote: '',
  hasMakeups: false, makeups: [], extras: [], skipDates: [], weeks: null, courseStart: '', periodOverride: null, creditsLeft: null,
  sheetTotal: null, sheetUsed: null,
});

export const newMakeup = (d: ImportDraft, status: ImportMakeup['status']): ImportMakeup => ({
  status, originalDate: '', originUnknown: false, date: '', time: '', durationMin: d.durationMin ?? 50, tutorId: d.tutorId,
});

export const WEEKLY_ALLOWED = [1, 2, 3, 5] as const;
export const DURATIONS = [20, 40, 50] as const;
const isTime = (t: string) => /^([01]\d|2[0-3]):[0-5]\d$/.test(t);

/** '없음'을 고르면 적어 둔 보강은 저장·계산에서 빠짐 */
export const activeMakeups = (d: ImportDraft): ImportMakeup[] => (d.hasMakeups ? d.makeups : []);

export type ImportPeriod = { index: number; start: KstDate; end: KstDate; state: 'past' | 'now' | 'next'; credits: number };

/** 오늘 날짜가 든 기간 (없으면 null) */
export function todayPeriod(d: ImportDraft): number | null {
  if (!d.weeks || !d.courseStart) return null;
  const k = Math.floor(diffDays(d.courseStart, d.today) / 28) + 1;
  return k >= 1 && k <= d.weeks / 4 ? k : null;
}
export const currentPeriod = (d: ImportDraft): number | null => d.periodOverride ?? todayPeriod(d);

/** 상품의 28일 기간 전체 (수강 시작일부터). 지금 기간은 남은 변경권, 다음 기간부터 새로 지급 */
export function importPeriods(d: ImportDraft): ImportPeriod[] {
  if (!d.weeks || !d.courseStart || d.slots.length === 0) return [];
  const granted = creditsPerPeriod(d.slots.length);
  const now = currentPeriod(d);
  return Array.from({ length: d.weeks / 4 }, (_, i) => {
    const index = i + 1;
    const start = addDays(d.courseStart as KstDate, i * 28);
    const state = now !== null && index < now ? 'past' : index === now ? 'now' : now === null && start <= d.today ? 'past' : 'next';
    return { index, start, end: addDays(start, 27), state, credits: state === 'now' ? (d.creditsLeft ?? granted) : granted };
  });
}

/** 28일 기간 계산 끝 (마지막 기간의 끝). 정규 수업은 여기까지만 */
export function autoEndDate(d: ImportDraft): KstDate | '' {
  const ps = importPeriods(d);
  return ps.length > 0 ? ps[ps.length - 1].end : '';
}

/** 정규 수업 마지막 날 = 종료일과 기간 계산 끝 중 빠른 날 (DB lms_import_regular_end 와 같음) */
export function regularEnd(d: ImportDraft): KstDate | '' {
  const calc = autoEndDate(d);
  if (!d.endDate) return '';
  return calc && calc < d.endDate ? calc : d.endDate;
}

/** 오늘 이후(오늘 포함) 첫 수업 요일 */
export function autoFromDate(d: ImportDraft): KstDate {
  const days = d.slots.map((s) => s.weekday);
  for (let i = 0; i < 7; i++) if (days.includes(weekdayOf(addDays(d.today, i)))) return addDays(d.today, i);
  return d.today;
}

/** 자동 채우기: 종료일·첫 정규 수업일은 비어 있거나 직전 자동값 그대로일 때만 새 자동값으로 (직접 고친 날짜는 그대로) */
export function withAutoEnd(prev: ImportDraft, next: ImportDraft): ImportDraft {
  let out = next;
  const auto = autoEndDate(next);
  if (auto && next.endDate === prev.endDate && (prev.endDate === '' || prev.endDate === autoEndDate(prev))) out = { ...out, endDate: auto };
  if (next.fromDate === prev.fromDate && prev.fromDate === autoFromDate(prev)) out = { ...out, fromDate: autoFromDate(next) };
  if (out.endDate && out.endDate === autoEndDate(out)) out = { ...out, endReason: '', endNote: '' };
  return out;
}

/** 저장 전 막을 것 (사람이 고칠 수 있는 말로) */
export function importProblems(d: ImportDraft): string[] {
  const out: string[] = [];
  const mks = activeMakeups(d);
  if (!d.nameKo.trim()) out.push('한글 이름을 넣어 주세요.');
  if (!d.nameEn.trim()) out.push('영문 이름을 넣어 주세요.');
  if (!d.timezone) out.push('학생 시간대를 골라 주세요.');
  if (!d.weeks) out.push('상품(1·3·6개월)을 골라 주세요.');
  if (!d.courseStart) out.push('수강 시작일을 넣어 주세요.');
  else if (d.weeks && currentPeriod(d) === null) out.push('오늘이 수강기간 밖이에요. 수강 시작일·상품을 확인하거나 지금 기간을 골라 주세요.');
  if (d.creditsLeft === null) out.push('지금 기간에 남은 변경권을 골라 주세요.');
  if (!d.endDate) out.push('현재 수강 종료일을 넣어 주세요.');
  else if (d.endDate < d.fromDate) out.push('수강 종료일이 첫 정규 수업일보다 빨라요.');
  if (d.endReason === 'student_long_term_leave' && d.weeks !== 24) out.push('학생 장기 연기는 6개월(24주) 상품만 가능해요.');
  if (!d.tutorId) out.push('담당 강사를 골라 주세요.');
  if (!d.durationMin) out.push('수업 길이를 골라 주세요.');
  if (!(WEEKLY_ALLOWED as readonly number[]).includes(d.slots.length)) out.push(`주 수업 횟수는 1·2·3·5회만 가능해요 (지금 ${d.slots.length}회).`);
  if (d.slots.some((s) => !isTime(s.time))) out.push('정규 수업 시각을 모두 넣어 주세요.');
  if (new Set(d.slots.map((s) => s.weekday)).size !== d.slots.length) out.push('같은 요일이 두 번 있어요.');
  mks.forEach((m, i) => {
    const n = `보강 ${i + 1}`;
    if (!m.originalDate && !m.originUnknown) out.push(`${n}: 원래 수업 날짜를 넣거나 '날짜 확인 필요'를 골라 주세요.`);
    if (m.status === 'open') return;
    if (!m.date || !isTime(m.time)) out.push(`${n}: 날짜·시각을 넣어 주세요.`);
    else if (m.date < d.fromDate) out.push(`${n}: 첫 정규 수업일 전 보강은 넣지 않아요 (지난 보강은 시트에).`);
    else if (d.endDate && m.date > d.endDate) out.push(`${n}: 수강 종료일 뒤예요. 종료일(연장)을 먼저 맞춰 주세요.`);
    if (!m.tutorId) out.push(`${n}: 강사를 골라 주세요.`);
  });
  const origins = mks.map((m) => m.originalDate).filter(Boolean);
  if (new Set(origins).size !== origins.length) out.push('같은 원래 수업 날짜의 보강이 두 개 있어요. 한 수업에는 보강 하나예요.');
  d.extras.forEach((x, i) => {
    const n = `추가 수업 ${i + 1}`;
    if (!x.date || !isTime(x.time)) out.push(`${n}: 날짜·시각을 넣어 주세요.`);
    else if (x.date < d.fromDate) out.push(`${n}: 첫 정규 수업일 전 날짜는 넣지 않아요.`);
    else if (d.endDate && x.date > d.endDate) out.push(`${n}: 수강 종료일 뒤예요.`);
    if (!x.reason.trim()) out.push(`${n}: 근거를 적어 주세요 (예: 시트 몇 회차).`);
  });
  if (d.sheetTotal === null || d.sheetUsed === null) out.push('시트의 총 수업 수와 진행·차감된 수를 넣어 주세요.');
  else if (d.sheetUsed > d.sheetTotal) out.push('진행·차감된 수가 총 수업 수보다 많아요.');
  return out;
}

/** 정규 수업 후보 하나하나: 만듦 / 보강의 원래 수업이라 안 만듦 / 운영진이 뺌 */
export type RegularRow = { date: KstDate; time: KstTime; state: 'keep' | 'origin' | 'skip' };

export function regularRows(d: ImportDraft): RegularRow[] {
  const last = regularEnd(d);
  if (!last || last < d.fromDate) return [];
  const origins = new Set(activeMakeups(d).map((m) => m.originalDate).filter(Boolean));
  const out: RegularRow[] = [];
  const days = diffDays(d.fromDate, last);
  for (let i = 0; i <= days; i++) {
    const date = addDays(d.fromDate, i);
    for (const s of d.slots) {
      if (s.weekday !== weekdayOf(date) || !isTime(s.time)) continue;
      out.push({ date, time: s.time, state: origins.has(date) ? 'origin' : d.skipDates.includes(date) ? 'skip' : 'keep' });
    }
  }
  return out;
}

/** 남은 수업 대조. sheetLeft·diff 는 시트 숫자를 넣었을 때만 */
export function importCount(d: ImportDraft) {
  const rows = regularRows(d);
  const mks = activeMakeups(d);
  const regular = rows.filter((r) => r.state === 'keep').length;
  const booked = mks.filter((m) => m.status === 'booked').length;
  const open = mks.filter((m) => m.status === 'open').length;
  const extra = d.extras.length;
  const lmsLeft = regular + booked + open + extra;
  const sheetLeft = d.sheetTotal !== null && d.sheetUsed !== null ? d.sheetTotal - d.sheetUsed : null;
  return {
    candidates: rows.length,
    origin: rows.filter((r) => r.state === 'origin').length,
    skipped: rows.filter((r) => r.state === 'skip').length,
    regular, booked, open, extra, lmsLeft, sheetLeft,
    diff: sheetLeft === null ? null : lmsLeft - sheetLeft,
  };
}

/** 저장은 막지 않는 확인 사항 (입력칸 바로 아래에 보여 줌) */
export function importWarnings(d: ImportDraft): { courseDay?: string; end?: { days: number; calc: KstDate }; origins: Record<number, string> } {
  const keep = new Set(regularRows(d).map((r) => r.date));
  const origins: Record<number, string> = {};
  activeMakeups(d).forEach((m, i) => {
    if (m.originalDate && m.originalDate >= d.fromDate && !keep.has(m.originalDate)) origins[i] = '이날은 만들 정규 수업 날이 아니에요. 날짜를 확인해 주세요.';
  });
  const days = d.slots.filter((x) => isTime(x.time)).map((x) => x.weekday);
  const calc = autoEndDate(d);
  return {
    courseDay:
      d.courseStart && days.length > 0 && !days.includes(weekdayOf(d.courseStart))
        ? `${dayLabel(d.courseStart)}이 지금 수업 요일(${days.map((w) => WEEKDAY_KO[w]).join('·')})과 달라요. 수강 중 고정 요일을 바꾼 학생이면 정상이에요. 시트 날짜 그대로 두세요.`
        : undefined,
    end: calc && d.endDate && d.endDate !== calc ? { days: diffDays(calc, d.endDate), calc } : undefined,
    origins,
  };
}

export type ImportLesson = { n: number; kind: 'regular' | 'makeup' | 'extra'; tutorId: string; date: KstDate; time: KstTime; startsAt: Date; endsAt: Date };

/** 만들어질 수업 (정규 + 예약된 보강 + 추가 수업), 시간순. DB lms_import_candidates 와 같은 규칙 */
export function importLessons(d: ImportDraft): ImportLesson[] {
  if (!d.endDate || !d.durationMin || d.endDate < d.fromDate) return [];
  const dur = d.durationMin;
  const out: Omit<ImportLesson, 'n'>[] = [];
  const at = (kind: ImportLesson['kind'], tutorId: string, date: KstDate, time: KstTime, min: number) => {
    const startsAt = kstToInstant(date, time);
    out.push({ kind, tutorId, date, time, startsAt, endsAt: new Date(startsAt.getTime() + min * 60_000) });
  };
  for (const r of regularRows(d)) if (r.state === 'keep') at('regular', d.tutorId, r.date, r.time, dur);
  for (const m of activeMakeups(d)) if (m.status === 'booked' && m.date && isTime(m.time)) at('makeup', m.tutorId, m.date, m.time, m.durationMin);
  for (const x of d.extras) if (x.date && isTime(x.time)) at('extra', d.tutorId, x.date, x.time, dur);
  return out
    .sort((a, b) => a.startsAt.getTime() - b.startsAt.getTime() || (a.kind === 'regular' ? -1 : 1))
    .map((l, i) => ({ ...l, n: i + 1 }));
}

export type ImportIssue = {
  lesson: ImportLesson;
  reason: 'tutor_regular' | 'tutor_makeup' | 'tutor_time_off' | 'tutor_hold' | 'break' | 'self';
  other?: string; // 상대 학생 이름·휴무 사유
};

export const IMPORT_REASON_TEXT: Record<ImportIssue['reason'], string> = {
  tutor_regular: '강사의 다른 학생 정규 수업과 겹침',
  tutor_makeup: '강사의 그날 보강과 겹침',
  tutor_time_off: '강사 휴무',
  tutor_hold: '재등록 대기 중인 학생의 고정 시간',
  break: '앞뒤 수업과 휴식 10분이 안 됨',
  self: '이 학생의 다른 수업과 겹침',
};

/** 화면 미리 검사: 강사 기존 일정(수업·휴무, 휴식 10분 포함) + 이번 입력끼리 */
export function importIssues(lessons: readonly ImportLesson[], tutors: readonly RegTutor[]): ImportIssue[] {
  const out: ImportIssue[] = [];
  for (const l of lessons) {
    const busy = tutors.find((t) => t.id === l.tutorId)?.busy ?? [];
    for (const c of clashes(l.startsAt, l.endsAt, busy)) {
      const b: Busy = c.busy;
      out.push({
        lesson: l,
        reason: b.kind === 'hold' ? 'tutor_hold' : b.kind === 'time_off' ? 'tutor_time_off' : c.reason === 'break' ? 'break' : b.kind === 'regular' ? 'tutor_regular' : 'tutor_makeup',
        other: b.label,
      });
    }
    for (const o of lessons) {
      if (o.n === l.n) continue;
      const overlap = o.startsAt < l.endsAt && l.startsAt < o.endsAt;
      const near = o.tutorId === l.tutorId && clashes(l.startsAt, l.endsAt, [{ id: String(o.n), startsAt: o.startsAt, endsAt: o.endsAt, kind: 'makeup' }]).length > 0;
      if (overlap || near) out.push({ lesson: l, reason: overlap ? 'self' : 'break', other: '이번 입력' });
    }
  }
  return out;
}

export function importPayload(d: ImportDraft) {
  const idx = currentPeriod(d);
  const now = importPeriods(d).find((p) => p.index === idx);
  return {
    student: { name_ko: d.nameKo.trim(), name_en: d.nameEn.trim(), email: d.email.trim(), phone: d.phone.trim(), timezone: d.timezone, admin_memo: d.memo.trim() },
    tutor_id: d.tutorId,
    slots: d.slots.map((s) => ({ weekday: s.weekday, time: s.time })),
    duration_min: d.durationMin,
    from_date: d.fromDate,
    end_date: d.endDate,
    makeups: activeMakeups(d).map((m) => ({
      status: m.status,
      ...(m.originalDate ? { original_date: m.originalDate } : { origin_unknown: true }),
      ...(m.status === 'booked' ? { date: m.date, time: m.time, duration_min: m.durationMin, tutor_id: m.tutorId } : {}),
    })),
    extras: d.extras.map((x) => ({ date: x.date, time: x.time, reason: x.reason.trim() })),
    skip_dates: d.skipDates.filter((s) => regularRows(d).some((r) => r.date === s && r.state === 'skip')),
    course: { weeks: d.weeks, period_idx: idx, period_start: now?.start ?? null, credits_left: d.creditsLeft },
    extension: { reason: d.endReason, note: d.endNote.trim() },
    sheet: { total: d.sheetTotal, used: d.sheetUsed },
  };
}
