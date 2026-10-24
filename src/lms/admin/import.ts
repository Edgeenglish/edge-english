// 기존 학생 입력 (D-52, 정책 원본 H23(3) → 확대판 H26, 2026-10-24 대표 결정 6가지)
// - 지금 수업 중인 학생의 고정 시간표 → 시작일(기본 오늘)~지금 수강 종료일 정규 수업
// - 미완료 보강: 예약됨(날짜·시각·길이·강사 → 그날 하나만) / 미예약(날짜 없음). 둘 다 원래 수업 날짜 또는 '날짜 확인 필요'
//   원래 수업 날짜가 시작일 이후면 그날 정규 수업은 만들지 않음 (한 수업을 정규·보강으로 두 번 세지 않음)
// - 수업 날짜 추가: 실제로 받아야 하는 수업 (근거 필수, 그날 하나만). 근거 없이 수업 권리를 만들지 않음
// - 남은 수업 = 정규 + 예약 보강 + 미예약 보강 + 추가. 시트(총 수업 수 − 이미 진행·차감된 수)와 달라도 저장, 차이는 처리할 일로
// - 지금 28일 기간·그 기간 남은 변경권 → 다음 기간부터 기존 규칙대로 새로 지급
// - 화면 검사는 편의. 저장 때 DB(admin_import_existing_student)가 같은 규칙으로 다시 검사하고, 충돌이면 아무것도 저장 안 함

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

export type ImportDraft = {
  nameKo: string;
  nameEn: string;
  email: string;
  phone: string;
  timezone: string;
  memo: string;
  tutorId: string;
  durationMin: number | null;
  slots: ImportSlot[];
  fromDate: KstDate;
  endDate: KstDate | '';
  makeups: ImportMakeup[];
  extras: ImportExtra[];
  /** 시트보다 많을 때 운영진이 뺀 정규 수업 날짜 */
  skipDates: KstDate[];
  weeks: ImportWeeks | null;
  periodIdx: number | null;
  periodStart: KstDate | '';
  creditsLeft: number | null;
  /** 시트의 등록 총 수업 수 · 이미 진행·차감된 수 (Class Status 기준, 회차 번호 아님) */
  sheetTotal: number | null;
  sheetUsed: number | null;
};

export const emptyImport = (today: KstDate): ImportDraft => ({
  nameKo: '', nameEn: '', email: '', phone: '', timezone: 'Asia/Seoul', memo: '',
  tutorId: '', durationMin: 50, slots: [{ weekday: 1, time: '' }], fromDate: today, endDate: '', makeups: [],
  extras: [], skipDates: [], weeks: null, periodIdx: null, periodStart: '', creditsLeft: null, sheetTotal: null, sheetUsed: null,
});

export const newMakeup = (d: ImportDraft, status: ImportMakeup['status']): ImportMakeup => ({
  status, originalDate: '', originUnknown: false, date: '', time: '', durationMin: d.durationMin ?? 50, tutorId: d.tutorId,
});

export const WEEKLY_ALLOWED = [1, 2, 3, 5] as const;
export const DURATIONS = [20, 40, 50] as const;
const isTime = (t: string) => /^([01]\d|2[0-3]):[0-5]\d$/.test(t);

/** 저장 전 막을 것 (사람이 고칠 수 있는 말로) */
export function importProblems(d: ImportDraft): string[] {
  const out: string[] = [];
  if (!d.nameKo.trim()) out.push('한글 이름을 넣어 주세요.');
  if (!d.nameEn.trim()) out.push('영문 이름을 넣어 주세요.');
  if (!d.timezone) out.push('학생 시간대를 골라 주세요.');
  if (!d.tutorId) out.push('담당 강사를 골라 주세요.');
  if (!d.durationMin) out.push('수업 길이를 골라 주세요.');
  if (!(WEEKLY_ALLOWED as readonly number[]).includes(d.slots.length)) out.push(`주 수업 횟수는 1·2·3·5회만 가능해요 (지금 ${d.slots.length}회).`);
  if (d.slots.some((s) => !isTime(s.time))) out.push('정규 수업 시각을 모두 넣어 주세요.');
  if (new Set(d.slots.map((s) => s.weekday)).size !== d.slots.length) out.push('같은 요일이 두 번 있어요.');
  if (!d.endDate) out.push('지금 수강 종료일을 넣어 주세요.');
  else if (d.endDate < d.fromDate) out.push('수강 종료일이 시작일보다 빨라요.');
  d.makeups.forEach((m, i) => {
    const n = `보강 ${i + 1}`;
    if (!m.originalDate && !m.originUnknown) out.push(`${n}: 원래 수업 날짜를 넣거나 '날짜 확인 필요'를 골라 주세요.`);
    if (m.status === 'open') return;
    if (!m.date || !isTime(m.time)) out.push(`${n}: 날짜·시각을 넣어 주세요.`);
    else if (m.date < d.fromDate) out.push(`${n}: 시작일 전 보강은 넣지 않아요 (지난 보강은 시트에).`);
    if (!m.tutorId) out.push(`${n}: 강사를 골라 주세요.`);
  });
  const origins = d.makeups.map((m) => m.originalDate).filter(Boolean);
  if (new Set(origins).size !== origins.length) out.push('같은 원래 수업 날짜의 보강이 두 개 있어요. 한 수업에는 보강 하나예요.');
  d.extras.forEach((x, i) => {
    const n = `추가 수업 ${i + 1}`;
    if (!x.date || !isTime(x.time)) out.push(`${n}: 날짜·시각을 넣어 주세요.`);
    else if (x.date < d.fromDate) out.push(`${n}: 시작일 전 날짜는 넣지 않아요.`);
    if (!x.reason.trim()) out.push(`${n}: 근거를 적어 주세요 (예: 시트 몇 회차).`);
  });
  if (!d.weeks) out.push('상품(1·3·6개월)을 골라 주세요.');
  else if (!d.periodIdx || d.periodIdx > d.weeks / 4) out.push('지금 몇 번째 기간인지 골라 주세요.');
  if (!d.periodStart) out.push('지금 기간의 시작일을 넣어 주세요.');
  if (d.creditsLeft === null) out.push('이 기간 남은 변경권을 골라 주세요.');
  if (d.sheetTotal === null || d.sheetUsed === null) out.push('시트의 총 수업 수와 진행·차감된 수를 넣어 주세요.');
  else if (d.sheetUsed > d.sheetTotal) out.push('진행·차감된 수가 총 수업 수보다 많아요.');
  return out;
}

/** 정규 수업 후보 하나하나: 만듦 / 보강의 원래 수업이라 안 만듦 / 운영진이 뺌 */
export type RegularRow = { date: KstDate; time: KstTime; state: 'keep' | 'origin' | 'skip' };

export function regularRows(d: ImportDraft): RegularRow[] {
  if (!d.endDate || d.endDate < d.fromDate) return [];
  const origins = new Set(d.makeups.map((m) => m.originalDate).filter(Boolean));
  const out: RegularRow[] = [];
  const days = diffDays(d.fromDate, d.endDate);
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
  const regular = rows.filter((r) => r.state === 'keep').length;
  const booked = d.makeups.filter((m) => m.status === 'booked').length;
  const open = d.makeups.filter((m) => m.status === 'open').length;
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

export type ImportPeriod = { index: number; start: KstDate; end: KstDate; state: 'past' | 'now' | 'next'; credits: number };

/** 상품의 28일 기간들. 지금 기간은 남은 변경권, 다음 기간부터 새로 지급 (지난 기간은 시트) */
export function importPeriods(d: ImportDraft): ImportPeriod[] {
  if (!d.weeks || !d.periodIdx || !d.periodStart || d.slots.length === 0) return [];
  const granted = creditsPerPeriod(d.slots.length);
  return Array.from({ length: d.weeks / 4 }, (_, i) => {
    const index = i + 1;
    const start = addDays(d.periodStart as KstDate, (index - d.periodIdx!) * 28);
    const state = index < d.periodIdx! ? 'past' : index === d.periodIdx ? 'now' : 'next';
    return { index, start, end: addDays(start, 27), state, credits: state === 'now' ? (d.creditsLeft ?? granted) : granted };
  });
}

/** 4번(상품·지금 기간·기간 시작일)으로 계산한 수강 종료일 = 마지막 28일 기간의 끝. 다 안 넣었으면 '' */
export function autoEndDate(d: ImportDraft): KstDate | '' {
  const ps = importPeriods(d);
  return ps.length > 0 ? ps[ps.length - 1].end : '';
}

/** 종료일 자동 채우기: 비어 있거나 직전 자동값 그대로일 때만 새 자동값으로 (직접 고친 날짜는 건드리지 않음 — 연장·옛 상품) */
export function withAutoEnd(prev: ImportDraft, next: ImportDraft): ImportDraft {
  const auto = autoEndDate(next);
  if (!auto || next.endDate !== prev.endDate) return next;
  return prev.endDate === '' || prev.endDate === autoEndDate(prev) ? { ...next, endDate: auto } : next;
}

/** 저장은 막지 않는 확인 사항 (입력칸 바로 아래에 보여 줌) */
export function importWarnings(d: ImportDraft): { period?: string; periodDay?: string; endDate?: string; origins: Record<number, string> } {
  const ps = importPeriods(d);
  const now = ps.find((p) => p.state === 'now');
  const last = ps[ps.length - 1];
  const keep = new Set(regularRows(d).map((r) => r.date));
  const origins: Record<number, string> = {};
  d.makeups.forEach((m, i) => {
    if (m.originalDate && m.originalDate >= d.fromDate && !keep.has(m.originalDate)) origins[i] = '이날은 정규 수업 날이 아니에요. 날짜를 확인해 주세요.';
  });
  const days = d.slots.filter((x) => isTime(x.time)).map((x) => x.weekday);
  const periodDay =
    d.periodStart && days.length > 0 && !days.includes(weekdayOf(d.periodStart))
      ? `${dayLabel(d.periodStart)}은 수업 요일(${days.map((w) => WEEKDAY_KO[w]).join('·')})이 아니에요. 기간 시작일은 첫 수업일부터 28일씩이라 항상 수업 요일이에요.`
      : undefined;
  return {
    periodDay,
    period: now && (d.fromDate < now.start || d.fromDate > now.end) ? `시작일(${d.fromDate})이 지금 기간(${now.start}~${now.end}) 밖이에요. 기간 시작일을 확인해 주세요.` : undefined,
    endDate: last && d.endDate && d.endDate !== last.end ? `종료일이 28일 규칙의 끝(${last.end})과 ${Math.abs(diffDays(last.end, d.endDate))}일 달라요. 연장·옛 상품이면 그대로 저장돼요.` : undefined,
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
  for (const m of d.makeups) if (m.status === 'booked' && m.date && isTime(m.time)) at('makeup', m.tutorId, m.date, m.time, m.durationMin);
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
  return {
    student: { name_ko: d.nameKo.trim(), name_en: d.nameEn.trim(), email: d.email.trim(), phone: d.phone.trim(), timezone: d.timezone, admin_memo: d.memo.trim() },
    tutor_id: d.tutorId,
    slots: d.slots.map((s) => ({ weekday: s.weekday, time: s.time })),
    duration_min: d.durationMin,
    from_date: d.fromDate,
    end_date: d.endDate,
    makeups: d.makeups.map((m) => ({
      status: m.status,
      ...(m.originalDate ? { original_date: m.originalDate } : { origin_unknown: true }),
      ...(m.status === 'booked' ? { date: m.date, time: m.time, duration_min: m.durationMin, tutor_id: m.tutorId } : {}),
    })),
    extras: d.extras.map((x) => ({ date: x.date, time: x.time, reason: x.reason.trim() })),
    skip_dates: d.skipDates.filter((s) => regularRows(d).some((r) => r.date === s && r.state === 'skip')),
    course: { weeks: d.weeks, period_idx: d.periodIdx, period_start: d.periodStart, credits_left: d.creditsLeft },
    sheet: { total: d.sheetTotal, used: d.sheetUsed },
  };
}
