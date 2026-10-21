// 강사 일정 충돌 판정 (신규 등록·고정 일정 선택)
// - 화면은 30분 칸이지만 판정은 실제 시각으로: 수업 길이(20·40·50분) + 수업 사이 최소 휴식 10분 (POL-OP-21)
// - 보강·보상 등 일회성 수업은 그 날짜만 막는다. 같은 요일·시각의 정규 가능 여부를 영구히 막지 않음
// - 새 정규 수업은 첫 수업일부터 등록기간 전체 날짜를 하나씩 검사해, 충돌 날짜와 이유를 돌려준다
// - 강사 가능 시간은 강사 현지 시각 + IANA 시간대로 저장 → 날짜마다 변환하므로 서머타임이 자동 반영된다

import { addDays, formatInZone, instantToKstDate, kstToInstant, weekdayOf, type KstDate, type KstTime } from './dates';
import { generateRegularLessons, type PlannedLesson, type RegularSlot } from './schedule';
import { CONFIRMED, type CourseWeeks } from './policy';

export const MIN_BREAK_MIN: number = CONFIRMED.minBreakMin;

const MIN = 60 * 1000;

/** 강사(또는 학생)의 이미 잡힌 시간 */
export type Busy = {
  id: string;
  startsAt: Date;
  endsAt: Date;
  /** regular = 매주 고정 수업의 회차, makeup = 보강·보상·이월 등 그날만 있는 수업, time_off = 강사 휴무·막은 시간 */
  kind: 'regular' | 'makeup' | 'time_off';
  label?: string;
};

/** 강사 주간 수업 가능 시간 (tutor_availability 한 행) */
export type AvailabilityWindow = {
  weekday: number; // 강사 현지 요일 0=일
  startLocal: string; // 'HH:MM' 강사 현지
  endLocal: string;
  timezone: string;
  effectiveFrom: KstDate;
  effectiveTo: KstDate | null;
};

const toMin = (hhmm: string) => Number(hhmm.slice(0, 2)) * 60 + Number(hhmm.slice(3, 5));

/** [start, end) 가 강사 가능 시간 한 칸 안에 완전히 들어가는지 (현지 날짜가 바뀌는 경계는 넘지 않는 것으로 봄) */
export function withinAvailability(start: Date, end: Date, windows: readonly AvailabilityWindow[]): boolean {
  const kstDay = instantToKstDate(start);
  return windows.some((w) => {
    if (kstDay < w.effectiveFrom || (w.effectiveTo !== null && kstDay > w.effectiveTo)) return false;
    const s = formatInZone(start, w.timezone);
    const e = formatInZone(new Date(end.getTime() - 1), w.timezone); // 끝 시각 직전이 같은 현지 날짜인지
    if (s.date !== e.date || weekdayOf(s.date) !== w.weekday) return false;
    const sm = toMin(s.time);
    const em = sm + Math.round((end.getTime() - start.getTime()) / MIN);
    return sm >= toMin(w.startLocal) && em <= toMin(w.endLocal);
  });
}

export type Clash = { busy: Busy; reason: 'overlap' | 'break' };

/** 새 수업 [start, end) 와 부딪히는 일정. 수업끼리는 앞뒤 휴식 10분까지, 휴무는 겹칠 때만 */
export function clashes(start: Date, end: Date, busy: readonly Busy[], breakMin = MIN_BREAK_MIN): Clash[] {
  const out: Clash[] = [];
  for (const b of busy) {
    if (b.startsAt < end && start < b.endsAt) {
      out.push({ busy: b, reason: 'overlap' });
      continue;
    }
    if (b.kind === 'time_off') continue;
    const gap = b.endsAt <= start ? start.getTime() - b.endsAt.getTime() : b.startsAt.getTime() - end.getTime();
    if (gap < breakMin * MIN) out.push({ busy: b, reason: 'break' });
  }
  return out;
}

export type PlanIssue = {
  seq: number;
  kstDate: KstDate;
  kstTime: KstTime;
  /** tutor_regular·tutor_makeup·tutor_time_off·break = 강사 쪽, student = 학생 본인 다른 수업, outside_availability = 강사 가능 시간 밖 */
  reason: 'tutor_regular' | 'tutor_makeup' | 'tutor_time_off' | 'break' | 'student' | 'outside_availability';
  detail: string;
};

const REASON_TEXT: Record<PlanIssue['reason'], string> = {
  tutor_regular: '강사의 다른 정규 수업과 겹침',
  tutor_makeup: '그날만 있는 보강과 겹침',
  tutor_time_off: '강사 휴무',
  break: '앞뒤 수업과 휴식 10분이 안 됨',
  student: '학생의 다른 수업과 겹침',
  outside_availability: '강사 수업 가능 시간 밖',
};

export const issueText = (r: PlanIssue['reason']) => REASON_TEXT[r];

const hhmm = (d: Date) => formatInZone(d, 'Asia/Seoul').time;

/**
 * 새 정규 일정 전체 검사: 등록기간의 모든 회차를 만들고 날짜마다 충돌을 찾는다.
 * 문제가 없으면 issues 가 빈 배열. 저장 전에 DB 함수가 같은 검사를 한 번 더 한다.
 */
export function checkRegularPlan(input: {
  startDate: KstDate;
  weeks: CourseWeeks;
  slots: RegularSlot[];
  durationMin: number;
  tutorBusy: readonly Busy[];
  studentBusy?: readonly Busy[];
  availability: readonly AvailabilityWindow[];
  breakMin?: number;
}): { lessons: PlannedLesson[]; issues: PlanIssue[] } {
  const lessons = generateRegularLessons(input);
  const issues: PlanIssue[] = [];
  for (const l of lessons) {
    const base = { seq: l.seq, kstDate: l.kstDate, kstTime: l.kstTime };
    if (!withinAvailability(l.startsAt, l.endsAt, input.availability)) {
      issues.push({ ...base, reason: 'outside_availability', detail: REASON_TEXT.outside_availability });
    }
    for (const c of clashes(l.startsAt, l.endsAt, input.tutorBusy, input.breakMin)) {
      const reason: PlanIssue['reason'] =
        c.reason === 'break' ? 'break' : c.busy.kind === 'time_off' ? 'tutor_time_off' : c.busy.kind === 'makeup' ? 'tutor_makeup' : 'tutor_regular';
      issues.push({ ...base, reason, detail: `${REASON_TEXT[reason]} · ${hhmm(c.busy.startsAt)}–${hhmm(c.busy.endsAt)}${c.busy.label ? ` ${c.busy.label}` : ''}` });
    }
    for (const c of clashes(l.startsAt, l.endsAt, input.studentBusy ?? [], input.breakMin)) {
      issues.push({ ...base, reason: 'student', detail: `${REASON_TEXT.student} · ${hhmm(c.busy.startsAt)}–${hhmm(c.busy.endsAt)}` });
    }
  }
  return { lessons, issues };
}

export type CellState = 'available' | 'regular' | 'makeup' | 'off' | 'unavailable';

/**
 * 주간 캘린더의 30분 칸 상태 (화면 표시용 — 예약 판정은 checkRegularPlan/clashes 가 따로 함)
 * 칸 [t, t+30) 에 수업이 조금이라도 걸치면 그 수업 종류, 휴무가 걸치면 off,
 * 칸 전체가 가능 시간 안이면 available, 아니면 unavailable
 */
export function cellState(date: KstDate, time: KstTime, stepMin: number, busy: readonly Busy[], availability: readonly AvailabilityWindow[]): { state: CellState; busy?: Busy } {
  const s = kstToInstant(date, time);
  const e = new Date(s.getTime() + stepMin * MIN);
  const hit = (k: Busy['kind']) => busy.find((b) => b.kind === k && b.startsAt < e && s < b.endsAt);
  const reg = hit('regular');
  if (reg) return { state: 'regular', busy: reg };
  const mk = hit('makeup');
  if (mk) return { state: 'makeup', busy: mk };
  const off = hit('time_off');
  if (off) return { state: 'off', busy: off };
  return { state: withinAvailability(s, e, availability) ? 'available' : 'unavailable' };
}

/** 고른 요일들 중 from 이후(포함) 가장 이른 날 = 첫 정규 수업일 후보 */
export function firstLessonDateOnOrAfter(from: KstDate, weekdays: readonly number[]): KstDate | null {
  if (weekdays.length === 0) return null;
  for (let i = 0; i < 7; i++) {
    const d = addDays(from, i);
    if (weekdays.includes(weekdayOf(d))) return d;
  }
  return null;
}
