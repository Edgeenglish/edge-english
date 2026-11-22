// 강사 Home Updates · To do '신규 수강생 문의' (H26(116)(127)): DB tutor_updates_feed · tutor_new_requests 결과를 화면 글로
// 시각은 time-text.ts 하나만 씀 (강사 현지 / KST, 기준 이름 굵게)
import { enBoth, enDay, enEvery, enEveryLines, enZoned } from '../admin/time-text';

export type TutorUpdateKind =
  | 'new_student' | 'renewal' | 'schedule_change' | 'class_moved' | 'cover' | 'cover_canceled'
  | 'makeup_new' | 'makeup_moved' | 'makeup_removed' | 'makeup_canceled' | 'cancel_undone' | 'canceled' | 'student_late';

export type TutorUpdate = { id: string; kind: TutorUpdateKind; student: string; studentId?: string; at: Date; info: Record<string, unknown> };
export type NewStudentRequest = { planId: string; student: string; minutes: number; classes: number; first: Date; every: Date[]; answer: 'yes' | 'no' | null };

/* eslint-disable @typescript-eslint/no-explicit-any -- DB JSON → 화면 모양 */
export const parseUpdates = (j: any): TutorUpdate[] =>
  ((j ?? []) as any[]).map((x) => ({ id: String(x.id), kind: x.kind, student: x.student ?? '', studentId: x.student_id ?? undefined, at: new Date(x.at), info: x.info ?? {} }));
export const parseRequests = (j: any): NewStudentRequest[] =>
  ((j ?? []) as any[]).map((x) => ({
    planId: x.plan_id, student: x.student ?? '', minutes: Number(x.minutes), classes: Number(x.classes),
    first: new Date(x.first), every: ((x.every ?? []) as string[]).map((s) => new Date(s)), answer: x.answer ?? null,
  }));
/* eslint-enable @typescript-eslint/no-explicit-any */

const d = (v: unknown) => (typeof v === 'string' ? new Date(v) : null);
const ds = (v: unknown) => (Array.isArray(v) ? (v as string[]).map((s) => new Date(s)) : []);

/** 줄 이름 (영어 = 강사 화면, 한국어 = 운영자 보기) */
export const UPDATE_TITLE: Record<TutorUpdateKind, [string, string]> = {
  new_student: ['New student', '신규 배정'],
  renewal: ['Renewed', '재등록'],
  schedule_change: ['Schedule change', '정규 시간 변경'],
  class_moved: ['Class date changed', '수업 날짜 변경'],
  cover: ['Cover classes', '대체 수업'],
  cover_canceled: ['Cover class canceled', '대체 수업 취소'],
  makeup_new: ['New make-up', '새 보강'],
  makeup_moved: ['Make-up time changed', '보강 시간 변경'],
  makeup_removed: ['Make-up canceled', '보강 취소'],
  makeup_canceled: ['Make-up canceled', '보강 취소'],
  cancel_undone: ['Cancellation undone', '취소 되돌림'],
  canceled: ['Canceled', '취소'],
  student_late: ['Running late', '지각 알림'],
};

/** 학생이 고른 지각 이유 (H26 기록 11/13, 학생 화면 버튼 4개 ↔ 강사에게 가는 영어 문장) */
export const LATE_REASON_EN: Record<string, string> = {
  work_late: 'Work is running late.',
  traffic: "I'm stuck in traffic.",
  transit: 'Public transportation is delayed.',
  unexpected: 'Something unexpected came up.',
};

/** Updates 한 줄의 아래 글 (시안 H26(127)): 시각 줄은 강사 현지 / KST */
export function updateLines(u: TutorUpdate, zone: string | ((t: Date) => string)): string[] {
  const i = u.info;
  // 시각마다 그 시각의 지역 (이동 기간, H26(176)) — 매주 시간은 첫 시각의 지역
  const z = (t: Date) => (typeof zone === 'string' ? zone : zone(t));
  // 매주 시간: 기간 중에 지역이 바뀌면 지역마다 줄을 나눔 (이동 기간 출발·복귀, H26(182))
  const every = (ts: Date[], end: { last?: Date | null; classes?: number | null }) =>
    (typeof zone === 'string' ? [enEvery(ts, zone)] : enEveryLines(ts, zone, end));
  switch (u.kind) {
    case 'new_student':
    {
      // 첫 수업을 학생이 취소했으면 실제 첫 수업 + 취소 줄 (20261122160000, 대표 11/22)
      const first = d(i.first_actual) ?? d(i.first) ?? u.at;
      const gone = d(i.first_canceled);
      return [...every(ds(i.every), { last: d(i.last), classes: Number(i.classes) || null }), `First class: ${enDay(first, z(first))} · ${i.minutes} min · ${i.classes} classes`,
        ...(gone ? [`${enDay(gone, z(gone))} class canceled by student`] : [])];
    }
    case 'renewal': {
      // 기간 끝 = 수강권 종료일(period_end, 20261122150000). 옛 기록은 마지막 수업일
      const end = i.period_end ? new Date(`${i.period_end}T12:00:00+09:00`) : d(i.last);
      return [...every(ds(i.every), { last: d(i.last) }), `Next period: ${enDay(d(i.first) ?? u.at, z(d(i.first) ?? u.at))} – ${enDay(end ?? u.at, z(end ?? u.at))} · ${i.same ? 'same schedule' : 'new schedule'}`];
    }
    case 'schedule_change':
      return [...every(ds(i.every), { last: d(i.last) }), `From ${enDay(d(i.from) ?? u.at, z(d(i.from) ?? u.at))}`];
    case 'class_moved': {
      const was = d(i.was);
      return [enBoth(d(i.to) ?? u.at, z(d(i.to) ?? u.at)), ...(was ? [`Was: ${enZoned(was, z(was))}`] : [])];
    }
    case 'cover':
    case 'cover_canceled':
      return ds(i.times).map((t) => enBoth(t, z(t)));
    case 'makeup_new': {
      const o = d(i.origin);
      return [enBoth(u.at, z(u.at)), ...(o ? [`Original class: ${enDay(o, z(o))}`] : [])];
    }
    case 'makeup_moved': {
      const was = d(i.was);
      return [enBoth(u.at, z(u.at)), ...(was ? [`Was: ${enZoned(was, z(was))}`] : [])];
    }
    case 'student_late': {
      const m = Number(i.minutes);
      const reason = typeof i.reason === 'string' ? LATE_REASON_EN[i.reason] : null;
      return [
        enBoth(u.at, z(u.at)),
        `The student may be approximately ${m >= 20 ? '20 or more' : m} minutes late.`,
        ...(reason ? [`Reason: ${reason}`] : []),
        'Please join the class on time and stay until the scheduled end time, as the student may arrive earlier than expected.',
      ];
    }
    default:
      return [enBoth(u.at, z(u.at))];
  }
}

/** 첫 수업 날짜 변경이면 'First class date changed' */
export function updateTitle(u: TutorUpdate, ko: boolean): string {
  if (u.kind === 'canceled') return u.info.late === true
    ? (ko ? '수강생 늦은 취소' : 'Student canceled late')
    : (ko ? '수강생 사전 취소' : 'Student canceled in advance');
  if (u.kind === 'class_moved' && u.info.is_first) return ko ? '첫 수업 날짜 변경' : 'First class date changed';
  return UPDATE_TITLE[u.kind]?.[ko ? 1 : 0] ?? u.kind;
}
