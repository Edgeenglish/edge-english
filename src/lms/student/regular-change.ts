/*
 * 학생 [정규 시간 변경] 신청 계산 (정책 원본 H26(208)·보충·보충 2, 대표 11/17)
 * DB lms_rc_week·lms_rc_first 와 같은 규칙 — 화면에 '○○(월) 주부터'를 미리 보여 주는 데만 씀 (신청·확정 판정은 DB)
 *  · 한 주 = 월~일, 한국 날짜 · 신청한 주가 아닌 다음 주부터
 *  · 그 주에 바뀌는 첫 수업(옮겨지는 기존 수업·새 수업 중 빠른 날) 4일 전 날까지 (한국 날짜)
 *  · 그 수업이 든 수강기간(28일)에 확정된 변경이 없어야 함 · 수강 종료일 안
 */
import type { KstDate } from '@/lms/rules/dates';

/** 한국 시간 기준 정규 시각 (weekday 0 = 일요일, time 'HH:MM') */
export type KstSlot = { weekday: number; time: string };
export type RcPeriod = { start: KstDate; end: KstDate; used: boolean };
export type RcContext = { today: KstDate; finalEnd: KstDate; periods: RcPeriod[] };
export type RcPair = { old: KstSlot; new: KstSlot };

export function addDays(d: string, n: number): KstDate {
  const t = new Date(`${d.slice(0, 10)}T00:00:00Z`);
  t.setUTCDate(t.getUTCDate() + n);
  return t.toISOString().slice(0, 10) as KstDate;
}
const dowOf = (d: string) => new Date(`${d.slice(0, 10)}T00:00:00Z`).getUTCDay();
/** 그 날이 든 주의 월요일 */
export const mondayOf = (d: string): KstDate => addDays(d, -((dowOf(d) + 6) % 7));
/** 월요일 week 의 그 요일 날짜 */
export const dayOf = (week: string, weekday: number): KstDate => addDays(week, (weekday + 6) % 7);

/** 그 주에 바뀌는 첫 수업 날짜 */
export function firstDate(week: string, pairs: RcPair[]): KstDate {
  return pairs.flatMap((p) => [dayOf(week, p.old.weekday), dayOf(week, p.new.weekday)]).sort()[0];
}

/** DB lms_lesson_period 와 같음: 그 날이 든 기간, 없으면 그 전에 시작한 마지막 기간 */
export function periodOf(periods: RcPeriod[], day: string): RcPeriod | null {
  return periods.find((p) => p.start <= day && day <= p.end) ?? [...periods].filter((p) => p.start <= day).at(-1) ?? null;
}

/** 가장 빠른 적용 주(월요일). 없으면 null */
export function weekFor(c: RcContext, pairs: RcPair[]): KstDate | null {
  for (let w = addDays(mondayOf(c.today), 7); w <= c.finalEnd; w = addDays(w, 7)) {
    const f = firstDate(w, pairs);
    if (f <= c.finalEnd && c.today <= addDays(f, -4) && !periodOf(c.periods, f)?.used) return w;
  }
  return null;
}

/** 그 주의 그 정규 시각 (실제 순간 — 학생 시간대로 바꿔 보여 줄 때) */
export const slotAt = (week: string, s: KstSlot): Date => new Date(`${dayOf(week, s.weekday)}T${s.time}:00+09:00`);

export const sameSlot = (a: KstSlot, b: KstSlot) => a.weekday === b.weekday && a.time === b.time;

/** 강사 변경 상담 내용 (DB 코드 → 화면 글, 대표 11/17 확정 순서) */
export const TUTOR_CHANGE_REASONS: { code: 'style' | 'time' | 'other_tutor' | 'consult'; label: string }[] = [
  { code: 'style', label: '다른 수업 스타일을 경험해 보고 싶어요' },
  { code: 'time', label: '수업 시간이 잘 맞지 않아요' },
  { code: 'other_tutor', label: '다른 강사님과 수업하고 싶어요' },
  { code: 'consult', label: '먼저 상담받고 싶어요' },
];
