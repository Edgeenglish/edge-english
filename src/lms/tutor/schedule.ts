// 강사 Schedule (2026-11-04 대표 결정 H26(49)+(50), 시안 docs/lms/previews/tutor-schedule-drafts.html 시안 2)
//  Month = 한 달 수업 + 평소와 다른 날 짧은 글자 / Week = 30분 칸 격자 + 날짜별 막기(Block time)·열기(Make available)
//  판정은 DB 함수 tutor_schedule·tutor_schedule_save (migration 4403). 여기는 칸 모양·날짜 계산만

import { formatInZone } from '../rules/dates';
import { cityTime, localToInstant } from './hours-view';
import { plusDays, toMin, type CellCode } from './hours';
import { kindTag, type TutorLesson } from './screen';

/** 칸 판정 (4403): My hours 와 같고 x = 매주 닫혔지만 그날만 연 칸 */
export type ScheduleCode = CellCode | 'x';
export type ScheduleBlock = { id: string; kind: 'block' | 'leave'; start: string; end: string; note: string | null };
export type ScheduleOpen = { start: string; end: string };
export type ScheduleData = {
  tutor: { id: string; name: string; timezone: string };
  /** 강사 현지 오늘 · 막기·열기 마지막 날 (오늘 + 12주) */
  today: string;
  last: string;
  /** 수업 시작 가능 시각 (강사 현지 06:00~22:30) */
  times: string[];
  /** 'YYYY-MM-DDTHH:MM'(강사 현지) → 열림(o)이 아닌 칸만. Week 보기에서만, 오늘~12주 안 날짜만 */
  cells: Record<string, ScheduleCode> | null;
  blocks: ScheduleBlock[];
  opens: ScheduleOpen[];
};
export type ScheduleAction = 'block' | 'open' | 'note' | 'unblock';

/* eslint-disable @typescript-eslint/no-explicit-any -- DB 함수가 돌려주는 JSON 을 화면 모양으로 바꾸는 곳 */
export function parseSchedule(j: any): ScheduleData {
  return {
    tutor: { id: j.tutor.id, name: j.tutor.name, timezone: j.tutor.timezone },
    today: j.today,
    last: j.last,
    times: j.times ?? [],
    cells: j.cells ?? null,
    blocks: (j.blocks ?? []).map((b: any) => ({ id: b.id, kind: b.kind, start: b.start, end: b.end, note: b.note ?? null })),
    opens: j.opens ?? [],
  };
}
/* eslint-enable @typescript-eslint/no-explicit-any */

/** 메모 최대 글자 수 — 대표 결정 H26(50) ③ (DB 도 같은 수로 다시 검사) */
export const NOTE_MAX = 100;
export const NOTE_HELP = 'Only you and Edge English see this note. Students just see this time as unavailable.';

const SHORT = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];
const MONTHS = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
const LONG_MONTHS = ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December'];
const dow = (date: string) => new Date(`${date}T00:00:00Z`).getUTCDay();

/** 'Fri, Nov 20' */
export const dayText = (date: string) => `${SHORT[dow(date)]}, ${MONTHS[Number(date.slice(5, 7)) - 1]} ${Number(date.slice(8))}`;
/** 'November 2026' */
export const monthTitle = (month: string) => `${LONG_MONTHS[Number(month.slice(5, 7)) - 1]} ${month.slice(0, 4)}`;
/** 'Nov 16 – 22' · 'Nov 30 – Dec 6' */
export function weekTitle(monday: string): string {
  const end = plusDays(monday, 6);
  const m = (d: string) => MONTHS[Number(d.slice(5, 7)) - 1];
  return m(monday) === m(end) ? `${m(monday)} ${Number(monday.slice(8))} – ${Number(end.slice(8))}` : `${m(monday)} ${Number(monday.slice(8))} – ${m(end)} ${Number(end.slice(8))}`;
}
export const mondayOf = (date: string) => plusDays(date, -((dow(date) + 6) % 7));
/** 'YYYY-MM' 의 달력 칸 (일요일 시작, 시안): 앞뒤 달 날짜 포함, 4~6주 */
export function monthGrid(month: string): string[] {
  const first = `${month}-01`;
  const start = plusDays(first, -dow(first));
  const next = addMonth(month, 1);
  const out: string[] = [];
  for (let d = start; out.length < 42; d = plusDays(d, 1)) {
    if (d >= `${next}-01` && out.length % 7 === 0) break;
    out.push(d);
  }
  return out;
}
export function addMonth(month: string, n: number): string {
  const y = Number(month.slice(0, 4));
  const m = Number(month.slice(5, 7)) - 1 + n;
  const yy = y + Math.floor(m / 12);
  return `${yy}-${String(((m % 12) + 12) % 12 + 1).padStart(2, '0')}`;
}

/** 강사 현지 'YYYY-MM-DDTHH:MM' → 시각 */
export const localInstant = (key: string, tz: string) => localToInstant(key.slice(0, 10), key.slice(11, 16), tz);
/** 시각 → 보는 시간대의 날짜·시각 */
export const inZone = (t: Date, zone: string) => { const f = formatInZone(t, zone); return { date: f.date, time: f.time }; };
/** 보는 시간대 칸(날짜·시각) → 강사 현지 칸 키 */
export function sourceKey(date: string, time: string, viewZone: string, tutorZone: string): string {
  if (viewZone === tutorZone) return `${date}T${time}`;
  const f = formatInZone(localToInstant(date, time, viewZone), tutorZone);
  return `${f.date}T${f.time}`;
}

/** '13:00–15:00 Toronto Time' (같은 날이 아니면 끝 날짜도) */
export function spanText(a: Date, b: Date, zone: string): string {
  const s = inZone(a, zone);
  const e = inZone(b, zone);
  const end = e.time === '00:00' && plusDays(s.date, 1) === e.date ? '24:00' : e.date === s.date ? e.time : `${dayText(e.date)} ${e.time}`;
  return `${s.time}–${end} ${cityTime(zone)}`;
}
/** 'Fri, Nov 20 13:00–15:00 Toronto Time' */
export const whenSpan = (a: Date, b: Date, zone: string) => `${dayText(inZone(a, zone).date)} ${spanText(a, b, zone)}`;
/** 보조로 보여 줄 다른 시간대 (강사가 한국이면 없음) */
export const otherZone = (viewZone: string, tutorZone: string): string | null =>
  tutorZone === 'Asia/Seoul' ? null : viewZone === tutorZone ? 'Asia/Seoul' : tutorZone;

/** Week 칸 모양 (화면 판정은 편의, 저장 때 DB 가 다시 검사) */
export type CellKind = 'free' | 'closed' | 'blocked' | 'class' | 'request' | 'leave' | 'locked' | 'outside' | 'past' | 'far';
export function cellKind(key: string, d: ScheduleData, hasLesson: boolean): CellKind {
  if (hasLesson) return 'class';
  const date = key.slice(0, 10);
  if (date < d.today) return 'past';
  if (!d.times.includes(key.slice(11, 16))) return 'outside';
  if (date > d.last) return 'far';
  const c = d.cells?.[key] ?? 'o';
  if (c === 'c') return 'class';
  if (c === 'r') return 'request';
  if (c === 'l') return 'leave';
  if (c === 'p') return 'locked';
  if (c === 's') return 'closed';
  if (c === 'b') return 'blocked';
  return 'free';
}

/** 그 칸(시작 시각, 30분)에 걸친 막은 시간 */
export function blockAt(blocks: ScheduleBlock[], at: Date, tz: string): ScheduleBlock | null {
  const end = +at + 30 * 60000;
  return blocks.find((b) => +localInstant(b.start, tz) < end && +at < +localInstant(b.end, tz)) ?? null;
}

/** 그 날(보는 시간대)의 일정: 수업 + 막은 시간 + 그날만 연 시간 */
export type DayItem =
  | { kind: 'lesson'; at: Date; lesson: TutorLesson }
  | { kind: 'block'; at: Date; end: Date; block: ScheduleBlock }
  | { kind: 'open'; at: Date; end: Date };
export function dayItems(date: string, zone: string, lessons: TutorLesson[], d: ScheduleData | null): DayItem[] {
  const tz = d?.tutor.timezone ?? zone;
  const dayStart = +localToInstant(date, '00:00', zone);
  const dayEnd = +localToInstant(plusDays(date, 1), '00:00', zone);
  const items: DayItem[] = lessons.filter((l) => inZone(l.startsAt, zone).date === date).map((l) => ({ kind: 'lesson', at: l.startsAt, lesson: l }));
  for (const b of d?.blocks ?? []) {
    const a = localInstant(b.start, tz);
    const e = localInstant(b.end, tz);
    if (+a < dayEnd && dayStart < +e) items.push({ kind: 'block', at: a, end: e, block: b });
  }
  for (const o of d?.opens ?? []) {
    const a = localInstant(o.start, tz);
    const e = localInstant(o.end, tz);
    if (+a < dayEnd && dayStart < +e) items.push({ kind: 'open', at: a, end: e });
  }
  return items.sort((x, y) => +x.at - +y.at);
}

/** Month 칸 짧은 글자 (색으로만 구분하지 않게, H26(49) ①). 평소와 다른 것 하나 — 앞이 먼저 */
export function dayTag(items: DayItem[]): string | null {
  const ls = items.flatMap((i) => (i.kind === 'lesson' ? [i.lesson] : []));
  if (ls.some((l) => l.state === 'canceled')) return 'Cancel';
  if (items.some((i) => i.kind === 'block' && i.block.kind === 'leave') || ls.some((l) => l.leaveOpen)) return 'Leave';
  if (ls.some((l) => l.covering)) return 'Cover';
  if (ls.some((l) => l.kind === 'makeup' || l.kind === 'migrated_makeup')) return 'Make-up';
  if (ls.some((l) => l.kind === 'compensation')) return 'Comp';
  if (items.some((i) => i.kind === 'block')) return 'Block';
  if (items.some((i) => i.kind === 'open')) return 'Open';
  if (ls.some((l) => l.state !== 'canceled' && l.count && l.count.n === l.count.total)) return 'Last';
  return null;
}
/** 수업 한 줄 꼬리 글자 (Month PC·그날 목록) */
export function lessonTag(l: TutorLesson): string | null {
  if (l.state === 'canceled') return 'Canceled';
  if (l.leaveOpen) return 'Leave';
  const k = kindTag(l);
  if (k) return k;
  return l.count && l.count.n === l.count.total ? 'Last class' : null;
}

/**
 * 고를 수 있는 끝 시각: 시작 칸부터 같은 종류(막기 = 빈 칸, 열기 = 회색 칸)가 이어지는 동안.
 * cells = 그날(보는 시간대) 칸 종류 ALL_HOURS 순서. 이어짐이 수업에서 끊기면 cutBy = 그 칸 번호
 */
export function runFrom(kinds: CellKind[], start: number, want: CellKind): { ends: number[]; cutBy: number | null } {
  const ends: number[] = [];
  let i = start;
  while (i < kinds.length && kinds[i] === want) { i++; ends.push(i); }
  return { ends, cutBy: i < kinds.length && kinds[i] === 'class' ? i : null };
}
/** 칸 번호(30분) → 'HH:MM' (48 = 24:00) */
export const slotTime = (i: number) => `${String(Math.floor(i / 2)).padStart(2, '0')}:${i % 2 ? '30' : '00'}`;
export const slotText = (i: number) => (i === 48 ? '24:00' : slotTime(i));
export const slotOf = (time: string) => toMin(time) / 30;
