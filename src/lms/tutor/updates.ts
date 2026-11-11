// 강사 Home Updates · To do '신규 수강생 문의' (H26(116)(127)): DB tutor_updates_feed · tutor_new_requests 결과를 화면 글로
// 시각은 time-text.ts 하나만 씀 (강사 현지 / KST, 기준 이름 굵게)
import { enBoth, enDay, enEvery, enZoned } from '../admin/time-text';

export type TutorUpdateKind =
  | 'new_student' | 'renewal' | 'schedule_change' | 'class_moved' | 'cover'
  | 'makeup_new' | 'makeup_moved' | 'makeup_removed' | 'makeup_canceled' | 'cancel_undone' | 'canceled';

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
  makeup_new: ['New make-up', '새 보강'],
  makeup_moved: ['Make-up time changed', '보강 시간 변경'],
  makeup_removed: ['Make-up canceled', '보강 취소'],
  makeup_canceled: ['Make-up canceled', '보강 취소'],
  cancel_undone: ['Cancellation undone', '취소 되돌림'],
  canceled: ['Canceled', '취소'],
};

/** Updates 한 줄의 아래 글 (시안 H26(127)): 시각 줄은 강사 현지 / KST */
export function updateLines(u: TutorUpdate, tz: string): string[] {
  const i = u.info;
  switch (u.kind) {
    case 'new_student':
      return [enEvery(ds(i.every), tz), `First class: ${enDay(d(i.first) ?? u.at, tz)} · ${i.minutes} min · ${i.classes} classes`];
    case 'renewal':
      return [enEvery(ds(i.every), tz), `Next period: ${enDay(d(i.first) ?? u.at, tz)} – ${enDay(d(i.last) ?? u.at, tz)} · ${i.same ? 'same schedule' : 'new schedule'}`];
    case 'schedule_change':
      return [enEvery(ds(i.every), tz), `From ${enDay(d(i.from) ?? u.at, tz)}`];
    case 'class_moved': {
      const was = d(i.was);
      return [enBoth(d(i.to) ?? u.at, tz), ...(was ? [`Was: ${enZoned(was, tz)}`] : [])];
    }
    case 'cover':
      return ds(i.times).map((t) => enBoth(t, tz));
    case 'makeup_new': {
      const o = d(i.origin);
      return [enBoth(u.at, tz), ...(o ? [`Original class: ${enDay(o, tz)}`] : [])];
    }
    case 'makeup_moved': {
      const was = d(i.was);
      return [enBoth(u.at, tz), ...(was ? [`Was: ${enZoned(was, tz)}`] : [])];
    }
    default:
      return [enBoth(u.at, tz)];
  }
}

/** 첫 수업 날짜 변경이면 'First class date changed' */
export function updateTitle(u: TutorUpdate, ko: boolean): string {
  if (u.kind === 'class_moved' && u.info.is_first) return ko ? '첫 수업 날짜 변경' : 'First class date changed';
  return UPDATE_TITLE[u.kind]?.[ko ? 1 : 0] ?? u.kind;
}
