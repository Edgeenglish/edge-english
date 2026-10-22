// 기존 학생 간단 입력 (D-52, 정책 원본 H23(3), 2026-10-22 대표 승인)
// - 지금 수업 중인 학생의 고정 시간표만 → 시작일(기본 오늘)~지금 수강 종료일 정규 수업
// - 확정된 미래 보강: 날짜·시각·길이·강사 → 그날 하나만 (정규 시간표에 안 넣음 → 그 요일·시각을 매주 막지 않음)
// - 화면 검사는 편의. 저장 때 DB(admin_import_existing_student)가 같은 규칙으로 다시 검사하고, 충돌이면 아무것도 저장 안 함

import { clashes, type Busy } from '../rules/booking';
import { addDays, diffDays, kstToInstant, weekdayOf, type KstDate, type KstTime } from '../rules/dates';
import type { RegTutor } from './registration';

export type ImportSlot = { weekday: number; time: KstTime };
export type ImportMakeup = { date: KstDate; time: KstTime; durationMin: number; tutorId: string };

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
};

export const emptyImport = (today: KstDate): ImportDraft => ({
  nameKo: '', nameEn: '', email: '', phone: '', timezone: 'Asia/Seoul', memo: '',
  tutorId: '', durationMin: 50, slots: [{ weekday: 1, time: '' }], fromDate: today, endDate: '', makeups: [],
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
    if (!m.date || !isTime(m.time)) out.push(`${n}: 날짜·시각을 넣어 주세요.`);
    else if (m.date < d.fromDate) out.push(`${n}: 시작일 전 보강은 넣지 않아요 (지난 보강은 시트에).`);
    if (!m.tutorId) out.push(`${n}: 강사를 골라 주세요.`);
  });
  return out;
}

export type ImportLesson = { n: number; kind: 'regular' | 'makeup'; tutorId: string; date: KstDate; time: KstTime; startsAt: Date; endsAt: Date };

/** 만들어질 수업 (정규 + 보강), 시간순. DB lms_import_candidates 와 같은 규칙 */
export function importLessons(d: ImportDraft): ImportLesson[] {
  if (!d.endDate || !d.durationMin || d.endDate < d.fromDate) return [];
  const out: Omit<ImportLesson, 'n'>[] = [];
  const days = diffDays(d.fromDate, d.endDate);
  for (let i = 0; i <= days; i++) {
    const date = addDays(d.fromDate, i);
    for (const s of d.slots) {
      if (s.weekday !== weekdayOf(date) || !isTime(s.time)) continue;
      const startsAt = kstToInstant(date, s.time);
      out.push({ kind: 'regular', tutorId: d.tutorId, date, time: s.time, startsAt, endsAt: new Date(startsAt.getTime() + d.durationMin * 60_000) });
    }
  }
  for (const m of d.makeups) {
    if (!m.date || !isTime(m.time)) continue;
    const startsAt = kstToInstant(m.date, m.time);
    out.push({ kind: 'makeup', tutorId: m.tutorId, date: m.date, time: m.time, startsAt, endsAt: new Date(startsAt.getTime() + m.durationMin * 60_000) });
  }
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
    makeups: d.makeups.map((m) => ({ date: m.date, time: m.time, duration_min: m.durationMin, tutor_id: m.tutorId })),
  };
}
