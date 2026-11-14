// 강사 화면(영어) 판정·표시 — 데이터는 DB 함수 tutor_screen 하나 (migration 2000)
// 수업 결과는 lessons.class_status 하나 (POL-ST-02). 강사는 결과(Held / Student no-show)와 지각(수강생·강사, 분)을 따로 고르고 정확한 상태 이름은 DB가 정함 (4400)

import { addDays, ampmEn, formatInZone } from '../rules/dates';
import { cityTime } from './hours-view';
import { rangeText } from './hours';
import { bold } from '../admin/time-text';
import { parsePeriod, type TravelPeriod } from './travel';
import type { ClassStatus } from '../rules/status';
import { asClassType, CLASS_TYPE_EN, typeFromKind, type ClassType } from '../class-type';

/** 수업 결과 하나. tutor_no_show = 운영자만 (4000). 지각은 결과와 따로 (4400) */
export type TutorResult = 'held' | 'student_no_show' | 'tutor_no_show';
/** 지각 (4400): 수강생·강사 각각, 분은 모를 수 있음(예전 'I was late' 기록) */
export type Late = { student: boolean; studentMin: number | null; tutor: boolean; tutorMin: number | null };
export const NO_LATE: Late = { student: false, studentMin: null, tutor: false, tutorMin: null };
/** 지각 시간 고르기 칸 — 대표가 정한 값 (2026-11-04). Custom 은 분 직접 입력 */
export const LATE_PRESETS = [5, 10, 15] as const;
export type LessonKind = 'regular' | 'makeup' | 'compensation' | 'carryover' | 'migrated_makeup' | 'migrated_extra';

export type TutorLesson = {
  id: string;
  startsAt: Date;
  endsAt: Date;
  kind: LessonKind;
  state: 'scheduled' | 'canceled' | 'done';
  classStatus: ClassStatus | null;
  student: string;
  /** 수강생 프로필 창 열기용 (4300) */
  studentId?: string;
  level: string | null;
  noteUrl: string | null;
  covering: boolean;
  /** 수업 종류 (H26(138), DB class_type). 없으면 kind·covering 으로 */
  type?: ClassType;
  /** 원래 이 강사 수업인데 다른 강사가 대체 (H26(138)): 회색 줄, 기록·급여 대상 아님 */
  coveredByOther?: boolean;
  makeupOf: Date | null;
  count: { n: number; total: number } | null;
  topics: string | null;
  remarks: string | null;
  /** 수강생 지각 표시 (정상 수업, migration 3000) — late.student 와 같음 */
  studentLate: boolean;
  /** 출결·지각 (4400) */
  late: Late;
  recordedAt: Date | null;
  locked: boolean;
  /** 강사 LMS 계정을 만들기 전 수업: LMS 기록 대상이 아님 (DB to_record 와 같은 기준, R7) */
  beforeLms?: boolean;
  /** 이 강사 휴무로 처리 중인 수업 (미정 · 대체강사 확정 전, 수강생 화면 '일정 조율 중'과 같은 판정, migration 3500) */
  leaveOpen?: boolean;
  /** 강사 노쇼 보상 수업 상태 (4000): available·used·expired·voided */
  compensation?: string | null;
  /** 보상 수업이면 강사 노쇼였던 원래 수업 시각 (4100) */
  compensationOf?: Date | null;
};

/** why: 왜 못 고르는지 (4530) — closed 강사가 열지 않은 시간 · busy 다른 수업 · leave 휴무 · hours 06:00~22:30 밖 · b2b 연속 수업 규칙 */
export type ConflictWhy = 'closed' | 'busy' | 'leave' | 'hours' | 'b2b' | 'other';
export type MakeupSlot = { id: string; startsAt: Date; endsAt: Date; answer: 'yes' | 'no' | null; busy: boolean; why?: ConflictWhy | null; past: boolean };
export type TutorMakeup = {
  id: string;
  student: string;
  studentId?: string;
  originalAt: Date | null;
  originalDate: string | null;
  note: string | null;
  answeredAt: Date | null;
  slots: MakeupSlot[];
  /** 강사 노쇼 무료 보상수업 신청 (4100) */
  compensation?: boolean;
  /** H26(134) DB makeup_stage: 'tutor' 강사 답 필요 · 'student' 학생 선택 대기 · 'admin' 운영진 조율. 강사가 시간을 제안한 신청에만 있음 */
  stage?: string;
  /** 강사가 학생에게 제안한 시간 (ok = 지금도 그 시간이 열려 있음) */
  suggested?: { startsAt: Date; endsAt: Date; ok: boolean }[];
};

/** 대체 수업 요청 (2600): 운영진이 이 강사를 대체강사로 골라 답을 기다리는 수업 */
export type TutorCover = { id: string; student: string; studentId?: string; startsAt: Date; endsAt: Date; busy: boolean; why?: ConflictWhy | null };

export type TutorScreen = {
  tutor: { id: string; name: string; timezone: string; meetUrl: string | null };
  /** 이동 기간 (H26(173)(175)) — 수업 시각은 그 수업 날짜에 있는 지역 시간으로 */
  locations: TravelPeriod[];
  lessons: TutorLesson[];
  toRecord: string[];
  makeups: TutorMakeup[];
  covers: TutorCover[];
};

/* eslint-disable @typescript-eslint/no-explicit-any -- DB 함수가 돌려주는 JSON 을 화면 모양으로 바꾸는 곳 */
const at = (v: any): Date | null => (v ? new Date(v) : null);
export function parseScreen(j: any, loadedAt: Date = new Date()): TutorScreen {
  const toRecord = new Set<string>(j.to_record ?? []);
  return {
    tutor: { id: j.tutor.id, name: j.tutor.name, timezone: j.tutor.timezone, meetUrl: j.tutor.meet_url ?? null },
    locations: (j.locations ?? []).map(parsePeriod),
    lessons: (j.lessons ?? []).map((l: any) => ({
      id: l.id, startsAt: new Date(l.starts_at), endsAt: new Date(l.ends_at), kind: l.kind, state: l.state, classStatus: l.class_status ?? null,
      student: l.student, studentId: l.student_id ?? undefined, level: l.level ?? null, noteUrl: l.note_url ?? null, covering: !!l.covering, makeupOf: at(l.makeup_of),
      type: asClassType(l.type, l.kind, !!l.covering), coveredByOther: !!l.covered_by_other,
      count: l.count ? { n: Number(l.count.n), total: Number(l.count.total) } : null,
      topics: l.topics ?? null, remarks: l.remarks ?? null, studentLate: !!l.student_late,
      late: { student: !!l.student_late, studentMin: l.student_late_min ?? null, tutor: !!l.tutor_late, tutorMin: l.tutor_late_min ?? null }, recordedAt: at(l.recorded_at), locked: !!l.locked,
      beforeLms: l.state === 'scheduled' && new Date(l.starts_at) <= loadedAt && !toRecord.has(l.id),
      leaveOpen: !!l.leave_open,
      compensation: l.compensation ?? null,
      compensationOf: at(l.compensation_of),
    })),
    toRecord: j.to_record ?? [],
    makeups: (j.makeups ?? []).map((m: any) => ({
      id: m.id, student: m.student, studentId: m.student_id ?? undefined, originalAt: at(m.original_at), originalDate: m.original_date ?? null, note: m.note ?? null, answeredAt: at(m.answered_at), compensation: !!m.compensation,
      slots: (m.slots ?? []).map((s: any) => ({ id: s.id, startsAt: new Date(s.starts_at), endsAt: new Date(s.ends_at), answer: s.answer ?? null, busy: !!s.busy, why: s.why ?? null, past: !!s.past })),
    })),
    covers: (j.covers ?? []).map((c: any) => ({ id: c.id, student: c.student, studentId: c.student_id ?? undefined, startsAt: new Date(c.starts_at), endsAt: new Date(c.ends_at), busy: !!c.busy, why: c.why ?? null })),
  };
}
/** tutor_makeup_suggestions (20261111160000) 결과를 보강 요청 카드에 붙임 */
export function withSuggestions(s: TutorScreen, rows: any[]): TutorScreen {
  const by = new Map(rows.map((r) => [r.id as string, r]));
  return {
    ...s,
    makeups: s.makeups.map((m) => {
      const r = by.get(m.id);
      if (!r) return m;
      return { ...m, stage: r.stage, suggested: (r.suggested ?? []).map((x: any) => ({ startsAt: new Date(x.starts_at), endsAt: new Date(x.ends_at), ok: !!x.ok })) };
    }),
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
/** '9:00–9:40 AM' 강사 현지 */
export function timeRange(l: { startsAt: Date; endsAt: Date }, tz: string): string {
  return rangeText(formatInZone(l.startsAt, tz).time, formatInZone(l.endsAt, tz).time);
}
/** 한국 시각 범위 '3:00–3:40 PM *KST*' (강사가 한국 시간대면 null). 시차로 날짜가 다르면 'Tue, 4 Nov 1:00–1:40 AM *KST*' */
export function kstRange(l: { startsAt: Date; endsAt: Date }, tz: string): string | null {
  if (tz === 'Asia/Seoul') return null;
  const a = formatInZone(l.startsAt, 'Asia/Seoul');
  const b = formatInZone(l.endsAt, 'Asia/Seoul');
  const day = localDate(l.startsAt, tz) === a.date ? '' : `${dayLabel(a.date)} `;
  return `${day}${rangeText(a.time, b.time)} ${bold('KST')}`;
}
/** 'Mon, 3 Nov 9:00 AM' 강사 현지 */
export function whenText(t: Date, tz: string): string {
  return `${dayLabel(localDate(t, tz))} ${ampmEn(formatInZone(t, tz).time)}`;
}
/**
 * 시간대 이름 (11/2 점검 ⑤): '[도시] Time' — 'Asia/Manila' → 'Manila Time', 한국은 'KST'.
 * 강사 화면 머리글은 '[도시] Time / KST' 로 통일
 */
export const KOREA_TIME = 'KST';
export const tzTimeLabel = cityTime;
export function tzHeader(tz: string): string {
  return tz === 'Asia/Seoul' ? KOREA_TIME : `${tzTimeLabel(tz)} / ${KOREA_TIME}`;
}
/** 한국 쪽 시각 '8:00 AM *KST*' (날짜가 다르면 'Tue, 10 Nov 1:30 AM *KST*'). 강사가 한국 시간대면 null */
export function kstText(t: Date, tz: string): string | null {
  if (tz === 'Asia/Seoul') return null;
  const k = formatInZone(t, 'Asia/Seoul');
  return `${localDate(t, tz) === k.date ? '' : `${dayLabel(k.date)} `}${ampmEn(k.time)} ${bold('KST')}`;
}
/**
 * 기준 이름까지 붙인 시각 (11/3 대표: 시각마다 어디 기준인지 꼭, 11/8 대표: 통일) —
 * 'Mon, 3 Nov 9:00 AM *Melbourne Time* / 7:00 AM *KST*' (한국 강사면 'Mon, 3 Nov 9:00 AM *KST*'). *…* = 굵게 (화면은 <Rich>)
 */
export function whenFull(t: Date, tz: string): string {
  const k = kstText(t, tz);
  return `${whenText(t, tz)} ${bold(tzTimeLabel(tz))}${k ? ` / ${k}` : ''}`;
}
/** 수업 시각 범위 + 기준: 'Mon, 9 Nov 4:00–4:50 PM *Sydney Time* / 2:00–2:50 PM *KST*' (한국 강사는 '… *KST*' 하나). *…* = 굵게 (화면은 <Rich>) */
export function rangeFull(l: { startsAt: Date; endsAt: Date }, tz: string): string {
  const k = kstRange(l, tz);
  return `${dayLabel(localDate(l.startsAt, tz))} ${timeRange(l, tz)} ${bold(tzTimeLabel(tz))}${k ? ` / ${k}` : ''}`;
}
/** 같은 글, 날짜 없이 (오늘 목록처럼 날짜가 이미 보일 때) */
export function rangeFullNoDay(l: { startsAt: Date; endsAt: Date }, tz: string): string {
  const k = kstRange(l, tz);
  return `${timeRange(l, tz)} ${bold(tzTimeLabel(tz))}${k ? ` / ${k}` : ''}`;
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
export function daysOf(lessons: TutorLesson[], tz: string | ((t: Date) => string), week: { from: string; to: string }): Day[] {
  const days = new Map<string, TutorLesson[]>();
  for (const l of [...lessons].sort((a, b) => +a.startsAt - +b.startsAt)) {
    // 이동 기간이면 그 수업 날짜에 있는 지역 날짜 (H26(176))
    const d = localDate(l.startsAt, typeof tz === 'string' ? tz : tz(l.startsAt));
    if (d < week.from || d > week.to) continue;
    days.set(d, [...(days.get(d) ?? []), l]);
  }
  return [...days.entries()].map(([date, ls]) => ({ date, lessons: ls }));
}

/** 강사가 보는 결과 문구 (14개 상태 전부) */
export const TUTOR_STATUS_TEXT: Record<ClassStatus, string> = {
  Normal: 'Held',
  'Make-up completed': 'Held',
  'Covered by another tutor': 'Held · substitute',
  'Tutor Late - Student Present': 'Held',   // 지각은 lateText 로 따로 붙임 (4400)
  'Student no-show': 'Student no-show',
  // 취소 상태는 강사 시트 Status 이름 그대로 (H26(138))
  'Student canceled in advance': 'Student canceled in advance',
  'Student canceled in advance (public holiday)': 'Student canceled in advance (public holiday)',
  'Student canceled late': 'Student canceled late',
  'No change credits left': 'No change credits left',
  'Tutor canceled in advance': 'Tutor canceled in advance',
  'Tutor canceled late': 'Tutor canceled late',
  'Tutor no-show': 'Tutor no-show',
  'Tutor long-term leave': 'Tutor on leave',
  'Student long-term leave': 'Student on leave',
};

/** 강사 Home To-do '취소된 수업': 수강생이 취소한 앞으로의 수업 (tutor_canceled_classes) */
export type TutorCanceled = { id: string; startsAt: Date; endsAt: Date; kind: LessonKind; classStatus: ClassStatus | null; student: string; studentId?: string };
/* eslint-disable @typescript-eslint/no-explicit-any -- DB JSON → 화면 모양 */
export const parseCanceled = (j: any): TutorCanceled[] =>
  ((j ?? []) as any[]).map((x) => ({ id: x.id, startsAt: new Date(x.starts_at), endsAt: new Date(x.ends_at), kind: x.kind, classStatus: x.class_status ?? null, student: x.student, studentId: x.student_id ?? undefined }));
/* eslint-enable @typescript-eslint/no-explicit-any */

export type LessonPhase = 'upcoming' | 'to_record' | 'before_lms' | 'on_leave' | 'recorded' | 'canceled' | 'covered';
export function phaseOf(l: TutorLesson, now: Date): LessonPhase {
  if (l.coveredByOther) return 'covered';
  if (l.state === 'canceled') return 'canceled';
  if (l.state === 'done') return 'recorded';
  if (l.leaveOpen) return 'on_leave';
  if (l.beforeLms) return 'before_lms';
  return l.startsAt <= now ? 'to_record' : 'upcoming';
}
export function statusText(l: TutorLesson, now: Date): string {
  const p = phaseOf(l, now);
  if (p === 'upcoming') return 'Upcoming';
  if (p === 'to_record') return 'Not recorded';
  if (p === 'before_lms') return 'Before LMS';
  if (p === 'on_leave') return TUTOR_STATUS_TEXT['Tutor long-term leave'];
  if (p === 'covered') return COVERED_TEXT;
  if (l.classStatus === 'Tutor no-show' && l.compensation && l.compensation !== 'voided') return 'Tutor no-show · +1 Compensation';
  return l.classStatus ? TUTOR_STATUS_TEXT[l.classStatus] : '';
}

/** 원래 강사 화면의 대체된 수업 (H26(138)) */
export const COVERED_TEXT = 'Covered by another tutor';
export const COVERED_NOTE = 'Another tutor is covering this class';
export const COVERING_NOTE = "You're covering for another tutor";

/** 저장된 결과 → 강사가 고른 버튼 (고칠 때 처음 선택). 예전 'Tutor Late - Student Present' 는 Held + 강사 지각 (4400) */
export function resultOf(s: ClassStatus | null): TutorResult | null {
  if (s === 'Student no-show') return 'student_no_show';
  if (s === 'Tutor no-show') return 'tutor_no_show';
  if (s === 'Normal' || s === 'Make-up completed' || s === 'Covered by another tutor' || s === 'Tutor Late - Student Present') return 'held';
  return null;
}
/** 저장 뒤 결과 이름 — DB tutor_record_class 와 같은 규칙 (강사 지각 → 'Tutor Late - Student Present', 대체 수업 → Normal(H26(138) 시트 규칙), 보강 → Make-up completed) */
export function savedStatus(l: Pick<TutorLesson, 'kind' | 'covering'>, r: TutorResult, tutorLate = false): ClassStatus {
  if (r === 'student_no_show') return 'Student no-show';
  if (r === 'tutor_no_show') return 'Tutor no-show';
  if (tutorLate) return 'Tutor Late - Student Present';
  if (l.covering) return 'Normal';
  if (l.kind === 'makeup' || l.kind === 'migrated_makeup' || l.kind === 'compensation') return 'Make-up completed';
  return 'Normal';
}
export const RESULT_TEXT: Record<TutorResult, string> = { held: 'Held', student_no_show: 'Student no-show', tutor_no_show: 'Tutor no-show' };

/** 저장할 지각 — Held 가 아니면 지각 없음 */
export function lateToSave(r: TutorResult, late: Late): Late {
  if (r !== 'held') return NO_LATE;
  return { student: late.student, studentMin: late.student ? late.studentMin : null, tutor: late.tutor, tutorMin: late.tutor ? late.tutorMin : null };
}
/** '· Student late 10 min · Tutor late' 같은 꼬리 (없으면 '') */
export function lateText(late: Late): string {
  const part = (who: string, min: number | null) => ` · ${who} late${min ? ` ${min} min` : ''}`;
  return (late.student ? part('Student', late.studentMin) : '') + (late.tutor ? part('Tutor', late.tutorMin) : '');
}
/** 화면에서 저장 버튼을 누를 수 있는지 (DB가 다시 확인) — 다룬 내용 필수, 강사 지각은 분·사유(Remarks) 필수, 수강생 지각은 분 필수 (POL-TU-01) */
export function recordReady(r: TutorResult | null, topics: string, remarks: string, late: Late = NO_LATE): boolean {
  if (!r) return false;
  if (r === 'student_no_show' || r === 'tutor_no_show') return true;
  if (!topics.trim()) return false;
  if (late.student && !(late.studentMin && late.studentMin > 0)) return false;
  if (late.tutor && !(late.tutorMin && late.tutorMin > 0)) return false;
  return !late.tutor || !!remarks.trim();
}
/**
 * 기록할 수 있는 수업. due = 서버가 '기록할 수업'(to_record, 서버 시각으로 시작 지남)으로 준 수업 —
 * 강사 기기 시계가 늦어도 열림 (11/9 Maria: 수업 전에 열어 둔 화면에서 Save 가 계속 잠김)
 */
export function canRecord(l: TutorLesson, now: Date, due = false): boolean {
  return l.state !== 'canceled' && !l.coveredByOther && !l.leaveOpen && (due || l.startsAt <= now) && !l.locked;
}

// 수업 종류 = 강사 시트 Class Type 이름 (H26(138)). 대체 수업이 먼저: 시트 보강을 대체강사가 맡아도 그 강사에게는 Cover class (R6)
export function kindTag(l: Pick<TutorLesson, 'kind' | 'covering' | 'type'>): string {
  return CLASS_TYPE_EN[l.type ?? typeFromKind(l.kind, l.covering)];
}

/** Class Record 'Student canceled' (H26(138)): 학생 취소로 기록할 수 있는 수업 — 기록 전·보상 수업 아님 (DB tutor_student_cancel 이 다시 확인) */
export function canStudentCancel(l: TutorLesson): boolean {
  return l.state === 'scheduled' && l.kind !== 'compensation' && !l.coveredByOther && !l.leaveOpen && !l.locked;
}
/** 학생 취소 미리 판정 결과 (lms_change_core) */
export type StudentCancelDecision = { status: ClassStatus; timing: 'advance' | 'late' };

/** 보강 신청의 원래 수업 ('Mon 3 Nov 09:00', 시트에서 옮겨 온 보강은 날짜만) */
export function makeupOrigin(m: TutorMakeup, tz: string): string {
  if (m.originalAt) return whenFull(m.originalAt, tz);
  return m.originalDate ? dayLabel(m.originalDate) : '';
}
/** 보강 답을 보낼 수 있는지: 가능한 시간이 하나 이상이거나, 모두 안 되면 다른 가능 시간 메모 */
export function answerReady(yes: ReadonlySet<string>, note: string): boolean {
  return yes.size > 0 || !!note.trim();
}

/** 강사 화면 '못 고르는 이유' 한 줄 (R-25). 쉽고 짧게, 실제 원인만 */
export function busyText(why: ConflictWhy | null | undefined, city: string): string {
  switch (why) {
    case 'closed': return 'Not in your open hours. Open this time in Schedule to accept it.';
    case 'busy': return 'You have another class then.';
    case 'leave': return 'You are on leave then.';
    case 'hours': return `Outside class hours (06:00–22:30 ${city}).`;
    case 'b2b': return 'Too many classes in a row without a break.';
    default: return 'This time is not available.';
  }
}
