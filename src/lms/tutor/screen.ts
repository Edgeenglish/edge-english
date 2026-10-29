// 강사 화면(영어) 판정·표시 — 데이터는 DB 함수 tutor_screen 하나 (migration 2000)
// 수업 결과는 lessons.class_status 하나 (POL-ST-02). 강사는 '진행 / 강사 지각 / 학생 노쇼'만 고르고 정확한 상태 이름은 DB가 정함

import { addDays, formatInZone } from '../rules/dates';
import type { ClassStatus } from '../rules/status';

export type TutorResult = 'held' | 'late' | 'student_no_show';
export type LessonKind = 'regular' | 'makeup' | 'compensation' | 'carryover' | 'migrated_makeup' | 'migrated_extra';

export type TutorLesson = {
  id: string;
  startsAt: Date;
  endsAt: Date;
  kind: LessonKind;
  state: 'scheduled' | 'canceled' | 'done';
  classStatus: ClassStatus | null;
  student: string;
  level: string | null;
  noteUrl: string | null;
  covering: boolean;
  makeupOf: Date | null;
  count: { n: number; total: number } | null;
  topics: string | null;
  remarks: string | null;
  recordedAt: Date | null;
  locked: boolean;
};

export type MakeupSlot = { id: string; startsAt: Date; endsAt: Date; answer: 'yes' | 'no' | null; busy: boolean; past: boolean };
export type TutorMakeup = {
  id: string;
  student: string;
  originalAt: Date | null;
  originalDate: string | null;
  note: string | null;
  answeredAt: Date | null;
  slots: MakeupSlot[];
};

/** 대체 수업 요청 (2600): 운영진이 이 강사를 대체강사로 골라 답을 기다리는 수업 */
export type TutorCover = { id: string; student: string; startsAt: Date; endsAt: Date; busy: boolean };

export type TutorScreen = {
  tutor: { id: string; name: string; timezone: string; meetUrl: string | null };
  lessons: TutorLesson[];
  toRecord: string[];
  makeups: TutorMakeup[];
  covers: TutorCover[];
};

/* eslint-disable @typescript-eslint/no-explicit-any -- DB 함수가 돌려주는 JSON 을 화면 모양으로 바꾸는 곳 */
const at = (v: any): Date | null => (v ? new Date(v) : null);
export function parseScreen(j: any): TutorScreen {
  return {
    tutor: { id: j.tutor.id, name: j.tutor.name, timezone: j.tutor.timezone, meetUrl: j.tutor.meet_url ?? null },
    lessons: (j.lessons ?? []).map((l: any) => ({
      id: l.id, startsAt: new Date(l.starts_at), endsAt: new Date(l.ends_at), kind: l.kind, state: l.state, classStatus: l.class_status ?? null,
      student: l.student, level: l.level ?? null, noteUrl: l.note_url ?? null, covering: !!l.covering, makeupOf: at(l.makeup_of),
      count: l.count ? { n: Number(l.count.n), total: Number(l.count.total) } : null,
      topics: l.topics ?? null, remarks: l.remarks ?? null, recordedAt: at(l.recorded_at), locked: !!l.locked,
    })),
    toRecord: j.to_record ?? [],
    makeups: (j.makeups ?? []).map((m: any) => ({
      id: m.id, student: m.student, originalAt: at(m.original_at), originalDate: m.original_date ?? null, note: m.note ?? null, answeredAt: at(m.answered_at),
      slots: (m.slots ?? []).map((s: any) => ({ id: s.id, startsAt: new Date(s.starts_at), endsAt: new Date(s.ends_at), answer: s.answer ?? null, busy: !!s.busy, past: !!s.past })),
    })),
    covers: (j.covers ?? []).map((c: any) => ({ id: c.id, student: c.student, startsAt: new Date(c.starts_at), endsAt: new Date(c.ends_at), busy: !!c.busy })),
  };
}
/* eslint-enable @typescript-eslint/no-explicit-any */

const MON = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
const WD = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];

/** 'Mon 3 Nov' (그 날짜 문자열 그대로) */
export function dayLabel(date: string): string {
  return `${WD[new Date(`${date}T00:00:00Z`).getUTCDay()]}, ${Number(date.slice(8))} ${MON[Number(date.slice(5, 7)) - 1]}`;
}
export function localDate(t: Date, tz: string): string {
  return formatInZone(t, tz).date;
}
/** '09:00–09:40' 강사 현지 */
export function timeRange(l: { startsAt: Date; endsAt: Date }, tz: string): string {
  return `${formatInZone(l.startsAt, tz).time}–${formatInZone(l.endsAt, tz).time}`;
}
/** 'Mon 3 Nov 09:00' 강사 현지 */
export function whenText(t: Date, tz: string): string {
  return `${dayLabel(localDate(t, tz))} ${formatInZone(t, tz).time}`;
}
/** 한국 시각 'KST 08:00' (날짜가 다르면 'KST Tue 08:00'). 강사가 한국 시간대면 null */
export function kstText(t: Date, tz: string): string | null {
  if (tz === 'Asia/Seoul') return null;
  const k = formatInZone(t, 'Asia/Seoul');
  return localDate(t, tz) === k.date ? `KST ${k.time}` : `KST ${WD[new Date(`${k.date}T00:00:00Z`).getUTCDay()]} ${k.time}`;
}
export const minutesOf = (l: { startsAt: Date; endsAt: Date }) => Math.round((+l.endsAt - +l.startsAt) / 60000);

/** 강사 현지 기준 월~일 한 주. offset: 0 이번 주, -1 지난주, 1 다음 주 */
export function weekOf(now: Date, tz: string, offset: number): { from: string; to: string; kstFrom: string; kstTo: string } {
  const today = localDate(now, tz);
  const wd = new Date(`${today}T00:00:00Z`).getUTCDay();
  const from = addDays(today, -((wd + 6) % 7) + offset * 7);
  const to = addDays(from, 6);
  // DB는 한국 날짜로 거름 → 시차로 날짜가 넘어가는 수업까지 하루씩 넓혀 읽고 화면에서 현지 날짜로 다시 거름
  return { from, to, kstFrom: addDays(from, -1), kstTo: addDays(to, 1) };
}

export type Day = { date: string; lessons: TutorLesson[] };
/** 그 주의 날짜별 수업 (수업 없는 날은 빼고) */
export function daysOf(lessons: TutorLesson[], tz: string, week: { from: string; to: string }): Day[] {
  const days = new Map<string, TutorLesson[]>();
  for (const l of [...lessons].sort((a, b) => +a.startsAt - +b.startsAt)) {
    const d = localDate(l.startsAt, tz);
    if (d < week.from || d > week.to) continue;
    days.set(d, [...(days.get(d) ?? []), l]);
  }
  return [...days.entries()].map(([date, ls]) => ({ date, lessons: ls }));
}

/** 강사가 보는 결과 문구 (14개 상태 전부) */
export const TUTOR_STATUS_TEXT: Record<ClassStatus, string> = {
  Normal: 'Held',
  'Make-up completed': 'Held · make-up',
  'Covered by another tutor': 'Held · substitute',
  'Tutor Late - Student Present': 'Held · tutor late',
  'Student no-show': 'Student no-show',
  'Student canceled in advance': 'Canceled by student',
  'Student canceled in advance (public holiday)': 'Canceled · public holiday',
  'Student canceled late': 'Student canceled late',
  'No change credits left': 'Canceled by student',
  'Tutor canceled in advance': 'Canceled by tutor',
  'Tutor canceled late': 'Canceled by tutor (late)',
  'Tutor no-show': 'Tutor no-show',
  'Tutor long-term leave': 'Tutor on leave',
  'Student long-term leave': 'Student on leave',
};

export type LessonPhase = 'upcoming' | 'to_record' | 'recorded' | 'canceled';
export function phaseOf(l: TutorLesson, now: Date): LessonPhase {
  if (l.state === 'canceled') return 'canceled';
  if (l.state === 'done') return 'recorded';
  return l.startsAt <= now ? 'to_record' : 'upcoming';
}
export function statusText(l: TutorLesson, now: Date): string {
  const p = phaseOf(l, now);
  if (p === 'upcoming') return 'Upcoming';
  if (p === 'to_record') return 'Not recorded';
  return l.classStatus ? TUTOR_STATUS_TEXT[l.classStatus] : '';
}

/** 저장된 결과 → 강사가 고른 버튼 (고칠 때 처음 선택) */
export function resultOf(s: ClassStatus | null): TutorResult | null {
  if (s === 'Tutor Late - Student Present') return 'late';
  if (s === 'Student no-show') return 'student_no_show';
  if (s === 'Normal' || s === 'Make-up completed' || s === 'Covered by another tutor') return 'held';
  return null;
}
/** 저장 뒤 결과 이름 — DB tutor_record_class 와 같은 규칙 (수업 종류·대체 진행으로 정함) */
export function savedStatus(l: Pick<TutorLesson, 'kind' | 'covering'>, r: TutorResult): ClassStatus {
  if (r === 'late') return 'Tutor Late - Student Present';
  if (r === 'student_no_show') return 'Student no-show';
  if (l.kind === 'makeup' || l.kind === 'migrated_makeup' || l.kind === 'compensation') return 'Make-up completed';
  return l.covering ? 'Covered by another tutor' : 'Normal';
}
export const RESULT_TEXT: Record<TutorResult, string> = { held: 'Held', late: 'I was late', student_no_show: 'Student no-show' };

/** 화면에서 저장 버튼을 누를 수 있는지 (DB가 다시 확인) — 다룬 내용 필수, 지각은 사유(Remarks) 필수 (POL-TU-01) */
export function recordReady(r: TutorResult | null, topics: string, remarks: string): boolean {
  if (!r) return false;
  if (r === 'student_no_show') return true;
  if (!topics.trim()) return false;
  return r !== 'late' || !!remarks.trim();
}
export function canRecord(l: TutorLesson, now: Date): boolean {
  return l.state !== 'canceled' && l.startsAt <= now && !l.locked;
}

export function kindTag(l: TutorLesson): string | null {
  if (l.kind === 'makeup' || l.kind === 'migrated_makeup') return 'Make-up';
  if (l.kind === 'compensation') return 'Compensation';
  if (l.covering) return 'Substitute';
  return null;
}

/** 보강 신청의 원래 수업 ('Mon 3 Nov 09:00', 시트에서 옮겨 온 보강은 날짜만) */
export function makeupOrigin(m: TutorMakeup, tz: string): string {
  if (m.originalAt) return whenText(m.originalAt, tz);
  return m.originalDate ? dayLabel(m.originalDate) : '';
}
/** 보강 답을 보낼 수 있는지: 가능한 시간이 하나 이상이거나, 모두 안 되면 다른 가능 시간 메모 */
export function answerReady(yes: ReadonlySet<string>, note: string): boolean {
  return yes.size > 0 || !!note.trim();
}
