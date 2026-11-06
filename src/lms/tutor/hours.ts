// 강사 가능 시간 고치기 [My hours] (migration 3100) — 판정은 DB 함수 tutor_hours·tutor_hours_save, 여기는 칸 모양·바뀐 내용 글만
//  - Every week 칸 키 '요일:HH:MM' (요일 0=일 … 6=토, 강사 현지) · One week only 칸 키 'YYYY-MM-DDTHH:MM' (강사 현지)

import { addDays, formatInZone } from '../rules/dates';
import { cityTime, localToInstant } from './hours-view';

/** 그 주만 칸: c 수업·보강 · r 보강 신청/대체 요청 답 대기 · l 휴무 · p 6시간 안·지난 시간 · s 매주 닫힘 · b 그 주만 닫음 · o 열림 */
export type CellCode = 'c' | 'r' | 'l' | 'p' | 's' | 'b' | 'o';
export type WeeklyClass = { d: number; time: string; min: number; student: string };
export type HoursLesson = { start: string; min: number; student: string; makeup: boolean };
/** onceClose·onceOpen = 그날만 막기·풀기, dayOpen = 그날만 열기, note = 막을 때·고친 메모 (Schedule, 4403) */
export type HoursChanges = { from: string; weeklyOpen: string[]; weeklyClose: string[]; onceClose: string[]; onceOpen: string[]; dayOpen?: string[]; note?: string | null; noteOf?: string | null };
export type HoursHistory = { at: Date; byAdmin: boolean; changes: HoursChanges };

export type HoursData = {
  tutor: { id: string; name: string; timezone: string };
  /** 매주 변경이 시작되는 날 (다음 주 월요일) */
  from: string;
  /** 그 주만 탭 첫 주 월요일 (강사 현지) */
  monday: string;
  times: string[];
  weeklyOpen: string[];
  weeklyClasses: WeeklyClass[];
  cells: Record<string, CellCode>;
  lessons: HoursLesson[];
  /** 운영자 보기에서만 (강사 본인은 null) */
  history: HoursHistory[] | null;
};

/* eslint-disable @typescript-eslint/no-explicit-any -- DB 함수가 돌려주는 JSON 을 화면 모양으로 바꾸는 곳 */
const changesOf = (c: any): HoursChanges => ({
  from: c.from, weeklyOpen: c.weekly_open ?? [], weeklyClose: c.weekly_close ?? [], onceClose: c.once_close ?? [], onceOpen: c.once_open ?? [],
  dayOpen: c.day_open ?? [], note: c.note ?? null, noteOf: c.note_of ?? null,
});
export function parseHours(j: any): HoursData {
  return {
    tutor: { id: j.tutor.id, name: j.tutor.name, timezone: j.tutor.timezone },
    from: j.from,
    monday: j.monday,
    times: j.times ?? [],
    weeklyOpen: j.weekly_open ?? [],
    weeklyClasses: j.weekly_classes ?? [],
    cells: j.cells ?? {},
    lessons: j.lessons ?? [],
    history: j.history == null ? null : j.history.map((h: any) => ({ at: new Date(h.at), byAdmin: !!h.by_admin, changes: changesOf(h.changes) })),
  };
}
/* eslint-enable @typescript-eslint/no-explicit-any */

/** 화면 요일 순서 월~일 (값 = 요일 번호 0=일) */
export const WEEK_DAYS = [1, 2, 3, 4, 5, 6, 0];
const SHORT = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];
const FULL = ['Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday'];
const KO = ['일', '월', '화', '수', '목', '금', '토'];
const MONTHS = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

export const toMin = (t: string): number => Number(t.slice(0, 2)) * 60 + Number(t.slice(3, 5));
/** 9:00 · 21:30 (시안처럼 앞 0 없음) */
export const timeText = (m: number): string => `${Math.floor(m / 60)}:${String(m % 60).padStart(2, '0')}`;
export const hhmm = (m: number): string => `${String(Math.floor(m / 60)).padStart(2, '0')}:${String(m % 60).padStart(2, '0')}`;

const parts = (date: string) => { const d = new Date(`${date}T00:00:00Z`); return { dow: d.getUTCDay(), day: d.getUTCDate(), month: d.getUTCMonth() }; };
export function plusDays(date: string, n: number): string {
  const d = new Date(`${date}T00:00:00Z`);
  d.setUTCDate(d.getUTCDate() + n);
  return d.toISOString().slice(0, 10);
}
/** 'Mon 2 Nov' */
export const dateText = (date: string): string => { const p = parts(date); return `${SHORT[p.dow]} ${p.day} ${MONTHS[p.month]}`; };
/** '2 – 8 Nov' · '30 Nov – 6 Dec' */
export function weekText(monday: string): string {
  const a = parts(monday);
  const b = parts(plusDays(monday, 6));
  return a.month === b.month ? `${a.day} – ${b.day} ${MONTHS[b.month]}` : `${a.day} ${MONTHS[a.month]} – ${b.day} ${MONTHS[b.month]}`;
}
const koDate = (date: string): string => { const p = parts(date); return `${p.month + 1}/${p.day}(${KO[p.dow]})`; };

/** 고정 수업이 걸친 매주 칸 (30분 칸이 수업 시간과 겹치면) */
export function weeklyClassAt(classes: WeeklyClass[], d: number, time: string): { c: WeeklyClass; first: boolean } | null {
  const m = toMin(time);
  for (const c of classes) {
    const s = toMin(c.time);
    if (c.d === d && m < s + c.min && s < m + 30) return { c, first: m <= s };
  }
  return null;
}
/**
 * 30분 칸 안에서 수업이 실제로 차지하는 부분 (0~1). 40분 수업이면 두 번째 칸은 위 1/3만 수업
 * (2026-11-04 대표: 칸을 꽉 칠하면 1시간 수업처럼 보임). 나머지는 수업 직후라 예약 불가 → 연하게
 */
export function classFill(start: number, min: number, cell: number): { from: number; to: number } {
  return { from: Math.max(0, start - cell) / 30, to: Math.min(30, start + min - cell) / 30 };
}
/** 그 칸에 걸친 수업·보강 (그 주만 탭) */
export function lessonAt(lessons: HoursLesson[], date: string, time: string): { l: HoursLesson; first: boolean } | null {
  const m = toMin(time);
  for (const l of lessons) {
    if (l.start.slice(0, 10) !== date) continue;
    const s = toMin(l.start.slice(11, 16));
    if (m < s + l.min && s < m + 30) return { l, first: m <= s };
  }
  return null;
}

/** 붙은 30분 칸을 [처음, 마지막] 묶음으로 */
export function runs(mins: number[]): [number, number][] {
  const out: [number, number][] = [];
  for (const m of [...mins].sort((a, b) => a - b)) {
    const last = out[out.length - 1];
    if (last && last[1] + 30 === m) last[1] = m;
    else out.push([m, m]);
  }
  return out;
}

export const diff = (base: Iterable<string>, cur: Iterable<string>) => {
  const b = new Set(base);
  const c = new Set(cur);
  return { added: [...c].filter((x) => !b.has(x)).sort(), removed: [...b].filter((x) => !c.has(x)).sort() };
};

/** 바뀐 내용을 사람 말로: 강사 확인 창(en) · 운영자 바뀐 기록(ko) */
export function describeChanges(ch: Omit<HoursChanges, 'from'> & { from?: string }, lang: 'en' | 'ko'): string[] {
  const out: string[] = [];
  const weekly = (keys: string[], open: boolean) => {
    for (const d of WEEK_DAYS) {
      const mins = keys.filter((k) => Number(k.split(':')[0]) === d).map((k) => toMin(k.slice(2)));
      for (const [a, b] of runs(mins)) {
        const span = `${timeText(a)}–${timeText(b + 30)}`;
        out.push(lang === 'en' ? `Every ${FULL[d]} ${span} → ${open ? 'open' : 'closed'}` : `매주 ${KO[d]} ${span} → ${open ? '열림' : '닫음'}`);
      }
    }
  };
  const once = (keys: string[], what: 'close' | 'reopen' | 'dayOpen') => {
    for (const date of [...new Set(keys.map((k) => k.slice(0, 10)))].sort()) {
      for (const [a, b] of runs(keys.filter((k) => k.startsWith(date)).map((k) => toMin(k.slice(11))))) {
        const span = `${timeText(a)}–${timeText(b + 30)}`;
        const en = { close: 'blocked', reopen: 'block removed', dayOpen: 'available (this day only)' }[what];
        const ko = { close: '그날만 막음', reopen: '막기 풂', dayOpen: '그날만 엶' }[what];
        out.push(lang === 'en' ? `${dateText(date)} ${span} → ${en}` : `${koDate(date)} ${span} → ${ko}`);
      }
    }
  };
  weekly(ch.weeklyOpen, true);
  weekly(ch.weeklyClose, false);
  once(ch.onceClose, 'close');
  once(ch.onceOpen, 'reopen');
  once(ch.dayOpen ?? [], 'dayOpen');
  if (ch.note && ch.onceClose.length > 0) out.push(lang === 'en' ? `Note: ${ch.note}` : `메모: ${ch.note}`);
  if (ch.noteOf) {
    const [a] = ch.noteOf.split('/');
    out.push(lang === 'en' ? `${dateText(a.slice(0, 10))} ${timeText(toMin(a.slice(11)))} block note → ${ch.note ?? '(none)'}` : `${koDate(a.slice(0, 10))} ${timeText(toMin(a.slice(11)))} 막은 시간 메모 → ${ch.note ?? '(없음)'}`);
  }
  return out;
}
/**
 * 바뀐 내용 (표시 시간대 기준 + 다른 시간대 보조). 저장 키는 강사 현지 그대로이고 보여 주는 글만 바꿈 (2026-11-04 대표 8번).
 * main = 고른 시간대 'Every Mon 17:30–18:00 KST → open', sub = 다른 시간대 'Every Mon 15:30–16:00 Ho Chi Minh Time' (강사가 한국이면 없음)
 * 날짜·요일이 시간대 때문에 달라져도 각각 정확히: 걸치면 'Mon 23:30 – Tue 0:30'. 매주 변경은 적용일 주(from) 기준
 */
export function describeChangesIn(
  ch: Omit<HoursChanges, 'from'>, from: string, tutorZone: string, viewZone: string,
): { main: string; sub: string | null }[] {
  const names = (z: string) => cityTime(z);
  const at = (date: string, a: number, b: number, zone: string, weekly: boolean): string => {
    const start = localToInstant(date, hhmm(a), tutorZone);
    const end = new Date(+start + (b + 30 - a) * 60000);
    const s = formatInZone(start, zone);
    const e = formatInZone(end, zone);
    const day = (d: string) => (weekly ? FULL[parts(d).dow] : dateText(d));
    const head = weekly ? `Every ${day(s.date)}` : day(s.date);
    const span = s.date === e.date || e.time === '00:00' && addDays(s.date, 1) === e.date
      ? `${timeText(toMin(s.time))}–${e.time === '00:00' ? '24:00' : timeText(toMin(e.time))}`
      : `${timeText(toMin(s.time))} – ${day(e.date)} ${timeText(toMin(e.time))}`;
    return `${head} ${span} ${names(zone)}`;
  };
  const other = tutorZone === 'Asia/Seoul' && viewZone === 'Asia/Seoul' ? null : viewZone === tutorZone ? 'Asia/Seoul' : tutorZone;
  const out: { main: string; sub: string | null }[] = [];
  const add = (date: string, a: number, b: number, weekly: boolean, tail: string) => {
    out.push({ main: `${at(date, a, b, viewZone, weekly)} → ${tail}`, sub: other ? at(date, a, b, other, weekly) : null });
  };
  const weekly = (keys: string[], open: boolean) => {
    for (const d of WEEK_DAYS) {
      const mins = keys.filter((k) => Number(k.split(':')[0]) === d).map((k) => toMin(k.slice(2)));
      for (const [a, b] of runs(mins)) add(plusDays(from, (d + 6) % 7), a, b, true, open ? 'open' : 'closed');
    }
  };
  const once = (keys: string[], close: boolean) => {
    for (const date of [...new Set(keys.map((k) => k.slice(0, 10)))].sort()) {
      for (const [a, b] of runs(keys.filter((k) => k.startsWith(date)).map((k) => toMin(k.slice(11))))) add(date, a, b, false, close ? 'blocked' : 'block removed');
    }
  };
  weekly(ch.weeklyOpen, true);
  weekly(ch.weeklyClose, false);
  once(ch.onceClose, true);
  once(ch.onceOpen, false);
  return out;
}
/** 매주 변경 적용일 안내 (2026-11-04 대표: 저장하면 바로 바뀌는 줄 오해, 문구는 시안 2 표 2번) — 'Changes apply from Mon, Nov 23.' 강사 현지 날짜 */
export const applyFromText = (from: string): string => { const p = parts(from); return `Changes apply from ${SHORT[p.dow]}, ${MONTHS[p.month]} ${p.day}.`; };
/** 매주 변경 시작일 문구 */
export const fromText = (from: string, lang: 'en' | 'ko'): string => (lang === 'en' ? `Every week changes start ${dateText(from)}.` : `${koDate(from)}부터`);
