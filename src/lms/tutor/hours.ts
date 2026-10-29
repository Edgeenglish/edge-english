// 강사 가능 시간 고치기 [My hours] (migration 3100) — 판정은 DB 함수 tutor_hours·tutor_hours_save, 여기는 칸 모양·바뀐 내용 글만
//  - Every week 칸 키 '요일:HH:MM' (요일 0=일 … 6=토, 강사 현지) · One week only 칸 키 'YYYY-MM-DDTHH:MM' (강사 현지)

/** 그 주만 칸: c 수업·보강 · r 보강 신청/대체 요청 답 대기 · l 휴무 · p 6시간 안·지난 시간 · s 매주 닫힘 · b 그 주만 닫음 · o 열림 */
export type CellCode = 'c' | 'r' | 'l' | 'p' | 's' | 'b' | 'o';
export type WeeklyClass = { d: number; time: string; min: number; student: string };
export type HoursLesson = { start: string; min: number; student: string; makeup: boolean };
export type HoursChanges = { from: string; weeklyOpen: string[]; weeklyClose: string[]; onceClose: string[]; onceOpen: string[] };
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
  const once = (keys: string[], close: boolean) => {
    for (const date of [...new Set(keys.map((k) => k.slice(0, 10)))].sort()) {
      for (const [a, b] of runs(keys.filter((k) => k.startsWith(date)).map((k) => toMin(k.slice(11))))) {
        const span = `${timeText(a)}–${timeText(b + 30)}`;
        out.push(lang === 'en'
          ? `${dateText(date)} ${span} → ${close ? 'unavailable this week' : 'open again'}`
          : `${koDate(date)} ${span} → ${close ? '그 주만 닫음' : '다시 엶'}`);
      }
    }
  };
  weekly(ch.weeklyOpen, true);
  weekly(ch.weeklyClose, false);
  once(ch.onceClose, true);
  once(ch.onceOpen, false);
  return out;
}
/** 매주 변경 시작일 문구 */
export const fromText = (from: string, lang: 'en' | 'ko'): string => (lang === 'en' ? `Every week changes start ${dateText(from)}.` : `${koDate(from)}부터`);
