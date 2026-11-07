// 학생 홈 미리보기용 가상 데이터 (실제 학생·강사 아님). 시각은 '지금' 기준으로 만들어
// 오늘 수업(6시간 이내 취소 확인)과 며칠 뒤 수업(6시간 전 취소 확인)을 모두 눌러 볼 수 있게 함

import { addDays, instantToKstDate, kstToInstant, type KstDate, type KstTime } from '../rules/dates';
import type { PaymentSummary, PointsEvent, StudentLesson, StudentRequest } from './home';
import type { StudentActions, StudentView } from './live';

const H = 60 * 60 * 1000;

export type FakeStudent = {
  name: string;
  product: string;
  weeklyCount: number;
  periodStart: KstDate;
  finalEndDate: KstDate;
  totalLessons: number;
  creditsLeft: number;
  creditsPerPeriod: number;
  makeupsOwed: number;
  textbook: { title: string; lastUnit: number };
  lessons: StudentLesson[];
  requests: StudentRequest[];
  payments: PaymentSummary[];
  points: PointsEvent[];
  pendingConsents: { id: string; title: string }[];
};

export function fakeStudent(now: Date): FakeStudent {
  const today = instantToKstDate(now);
  const at = (days: number, time: KstTime) => kstToInstant(addDays(today, days), time);
  // 오늘 수업은 '지금부터 약 4시간 뒤' 정각 → 6시간 이내 취소 화면을 볼 수 있음
  const soon = new Date(Math.ceil((now.getTime() + 4 * H) / H) * H);
  const lesson = (id: string, startsAt: Date, state: StudentLesson['state'], kind: StudentLesson['kind'] = 'regular'): StudentLesson => ({
    id,
    kind,
    startsAt,
    minutes: 50,
    tutorName: '가상강사 Alex',
    state,
  });
  return {
    name: '가상학생일',
    product: '50분 · 주 2회 · 4주',
    weeklyCount: 2,
    periodStart: addDays(today, -22),
    finalEndDate: addDays(today, 5),
    totalLessons: 8,
    creditsLeft: 1,
    creditsPerPeriod: 2,
    makeupsOwed: 1,
    textbook: { title: 'Speak now 2', lastUnit: 7 },
    lessons: [
      lesson('l1', at(-21, '20:00'), 'done'),
      lesson('l2', at(-19, '20:00'), 'done'),
      lesson('l3', at(-14, '20:00'), 'done'),
      lesson('l4', at(-12, '20:00'), 'done'),
      lesson('l5', at(-7, '20:00'), 'canceled'),
      lesson('l6', at(-5, '20:00'), 'done'),
      lesson('l7', soon, 'scheduled'),
      lesson('l8', at(3, '20:00'), 'scheduled'),
    ],
    requests: [
      {
        id: 'q1',
        kind: 'makeup',
        title: `보강 신청 · ${md(addDays(today, -7))} 수업분`,
        status: 'tutor_reviewing',
        candidates: [at(4, '19:00'), at(5, '10:00')],
        createdAt: new Date(at(-6, '09:14')),
        note: '변경권 1개 사용',
      },
      {
        id: 'q2',
        kind: 'change',
        title: `수업 변경 · ${md(addDays(today, -7))}`,
        status: 'completed',
        candidates: [],
        createdAt: new Date(at(-8, '11:02')),
        note: '변경권 1개 사용 · 보강 가능',
      },
    ],
    payments: [
      {
        id: 'p2',
        product: '50분 · 주 2회 · 4주 (8회)',
        periodStart: addDays(today, -22),
        periodEnd: addDays(today, 5),
        method: 'card_imweb',
        confirmedOn: addDays(today, -24),
        current: true,
      },
      {
        id: 'p1',
        product: '50분 · 주 2회 · 4주 (8회)',
        periodStart: addDays(today, -50),
        periodEnd: addDays(today, -23),
        method: 'bank_transfer',
        confirmedOn: addDays(today, -52),
        current: false,
      },
    ],
    points: [
      { id: 'r1', on: addDays(today, -37), kind: 'grant', amount: 2000, reason: '강사 사정 취소 보상 (시작 6시간 이내)' },
      { id: 'r2', on: addDays(today, -24), kind: 'use', amount: 2000, reason: '재등록 결제에 사용 (결제 확인 후 확정)' },
      { id: 'r3', on: addDays(today, -9), kind: 'grant', amount: 2000, reason: '강사 사정 취소 보상 (시작 6시간 이내)' },
    ],
    pendingConsents: [{ id: 'g1', title: '새 수업 안내' }],
  };
}

function md(d: KstDate) {
  return `${Number(d.slice(5, 7))}/${Number(d.slice(8, 10))}`;
}

// ---------------------------------------------------------------------
// 미리보기(?demo=1): 실제 화면과 같은 동작(StudentActions)을 이 브라우저 안에서만 흉내 냄 — 저장·발송 없음
// ---------------------------------------------------------------------
export type PreviewExtras = { textbook: FakeStudent['textbook']; payments: PaymentSummary[]; pendingConsents: FakeStudent['pendingConsents'] };

export function fakeStore(now: Date): { view: StudentView; extras: PreviewExtras; actions: StudentActions } {
  const s = fakeStudent(now);
  const today = instantToKstDate(now);
  const at = (days: number, time: KstTime) => kstToInstant(addDays(today, days), time);
  const offFrom = at(6, '00:00');
  const offTo = at(14, '00:00');
  let view: StudentView = {
    studentId: 'preview',
    name: s.name,
    product: s.product,
    finalEndDate: addDays(today, 20),
    nextRegularFrom: null,
    totalLessons: s.totalLessons,
    creditsLeft: s.creditsLeft,
    creditsPerPeriod: s.creditsPerPeriod,
    renewalPaid: false,
    confirmedOn: s.payments[0].confirmedOn,
    paid: true,
    enrollmentStatus: 'active',
    lessons: [
      ...s.lessons.map((l) => ({ ...l, meetUrl: null, leavePostponed: false, substitute: false })),
      ...[7, 9, 11].map((d, i) => ({ id: `lv${i}`, kind: 'regular' as const, startsAt: at(d, '20:00'), minutes: 50, tutorName: '가상강사 Alex', state: 'scheduled' as const, meetUrl: null, leavePostponed: false, substitute: false })),
    ],
    makeupRights: [{ lessonId: 'l5', itemId: null, originalAt: s.lessons[4].startsAt, tutorLeave: false, requested: false }],
    requests: [],
    leave: [
      { id: 'x1', startsAt: at(7, '20:00'), choice: 'substitute', stage: 'tutor_ok', subTutor: 'Maria', subMeetUrl: null, lessonId: 'lv0', itemId: null, offFrom, offTo },
      { id: 'x2', startsAt: at(9, '20:00'), choice: 'substitute', stage: 'tutor_ok', subTutor: 'Benny', subMeetUrl: null, lessonId: 'lv1', itemId: null, offFrom, offTo },
      { id: 'x3', startsAt: at(11, '20:00'), choice: 'wait', stage: null, subTutor: null, subMeetUrl: null, lessonId: 'lv2', itemId: null, offFrom, offTo },
    ],
    holidays: [],
    creditPeriod: { start: s.periodStart, end: addDays(s.periodStart, 27) },
    creditPeriods: [{ start: s.periodStart, end: addDays(s.periodStart, 27), granted: s.creditsPerPeriod, left: s.creditsLeft }],
    creditUses: [{ at: s.lessons[4].startsAt, reason: 'student_change', delta: -1, lessonAt: s.lessons[4].startsAt }],
    points: s.points,
  };
  view.lessons = view.lessons.map((l) => (l.id === 'lv2' ? { ...l, state: 'canceled' } : l));
  view.makeupRights.push({ lessonId: 'lv2', itemId: null, originalAt: at(11, '20:00'), tutorLeave: true, requested: false });
  // 강사 노쇼(l6): 원래 수업 보강 + 무료 보상수업 1회가 따로 (4100)
  view.lessons = view.lessons.map((l) => (l.id === 'l6' ? { ...l, tutorNoShow: true } : l));
  const noShowAt = s.lessons[5].startsAt;
  view.makeupRights.push(
    { lessonId: 'l6', itemId: null, originalAt: noShowAt, tutor: '가상강사 Alex', tutorNoShow: true, tutorLeave: false, requested: false },
    { lessonId: null, itemId: null, compId: 'c1', useUntil: addDays(today, 20), originalAt: noShowAt, tutor: '가상강사 Alex', tutorNoShow: true, tutorLeave: false, requested: false },
  );
  // 확정된 보강 예: 상세에 원래 수업·담당 강사·확정 날짜 (11/2 점검 ③)
  view.requests = [{
    id: 'q0', kind: 'makeup', title: `보강 · ${md(addDays(today, -26))} 수업분`, status: 'confirmed', candidates: [at(2, '10:00'), at(4, '10:00')],
    createdAt: at(-25, '09:00'), note: '', originalAt: at(-26, '20:00'), originalTutor: '가상강사 Alex', tutor: '가상강사 Alex', confirmedAt: at(2, '10:00'),
  }];
  const set = (v: StudentView) => (view = v);
  let reminders = { regular: true, makeup: true, hasEmail: true };
  let noTimeAt: string | null = null;
  const actions: StudentActions = {
    reload: async () => view,
    reminders: async (change) => (reminders = { ...reminders, ...change }),
    makeupOptions: async (right) => {
      const back = view.makeupRights.find((m) => m.lessonId === right.lessonId)?.tutorLeave ? 14 : 1;
      return Array.from({ length: 18 }, (_, i) => back + i)
        .filter((d) => d % 2 === 0)
        .flatMap((d) => [{ startsAt: at(d, '10:00'), afterEnd: false }, ...(d % 4 === 0 ? [{ startsAt: at(d, '20:00'), afterEnd: false }] : [])]);
    },
    // 미리보기: 휴무·노쇼·보상이 아닌 첫 보강권을 '종료 5일 이내 강사 취소'로 흉내 (실제는 DB 가 강사 취소 기록으로 판정)
    noTimeRights: async () => {
      const m = view.makeupRights.find((x) => x.lessonId && !x.compId && !x.tutorLeave && !x.tutorNoShow);
      return new Map(m?.lessonId ? [[m.lessonId, noTimeAt]] : []);
    },
    noTimeRequest: async () => {
      noTimeAt = new Date().toISOString();
      set({ ...view });   // 화면이 다시 읽도록 새 값
    },
    cancel: async (lessonId) => {
      const l = view.lessons.find((x) => x.id === lessonId)!;
      const late = l.startsAt.getTime() - Date.now() < 6 * H;
      const uses = !late && view.creditsLeft > 0;
      set({
        ...view,
        lessons: view.lessons.map((x) => (x.id === lessonId ? { ...x, state: 'canceled' } : x)),
        creditsLeft: view.creditsLeft - (uses ? 1 : 0),
        creditPeriods: view.creditPeriods.map((p, i) => (i === 0 ? { ...p, left: p.left - (uses ? 1 : 0) } : p)),
        makeupRights: uses ? [...view.makeupRights, { lessonId, itemId: null, originalAt: l.startsAt, tutorLeave: false, requested: false }] : view.makeupRights,
      });
      return { status: '', uses_credit: uses, makeup_allowed: uses };
    },
    requestMakeup: async (right, slots) => {
      set({
        ...view,
        makeupRights: view.makeupRights.map((m) => ((m.compId ?? null) === (right.compId ?? null) && m.lessonId === right.lessonId && m.itemId === right.itemId ? { ...m, requested: true } : m)),
        requests: [{ id: `q${Date.now()}`, kind: 'makeup', title: right.compId ? '무료 보상수업' : '보강', compensation: !!right.compId, status: 'tutor_reviewing', candidates: slots, createdAt: new Date(), note: '' }, ...view.requests],
      });
    },
    answerLeave: async (items, answer) => {
      const rows = view.leave.filter((x) => items.includes(x.id));
      set({
        ...view,
        leave: view.leave.map((x) => (!items.includes(x.id) ? x : answer === 'ok' ? { ...x, stage: 'confirmed' } : { ...x, choice: 'wait', stage: null, subTutor: null })),
        lessons: view.lessons.map((l) => (answer === 'makeup' && rows.some((r) => r.lessonId === l.id) ? { ...l, state: 'canceled' } : l)),
        makeupRights: answer === 'makeup' ? [...view.makeupRights, ...rows.map((r) => ({ lessonId: r.lessonId, itemId: null, originalAt: r.startsAt, tutorLeave: true, requested: false }))] : view.makeupRights,
      });
    },
  };
  return { view, extras: { textbook: s.textbook, payments: s.payments, pendingConsents: s.pendingConsents }, actions };
}
