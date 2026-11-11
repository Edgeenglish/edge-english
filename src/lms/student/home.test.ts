import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { describe, expect, it } from 'vitest';
import { kstToInstant } from '../rules/dates';
import {
  cancelPreview,
  lessonsLeft,
  nextLesson,
  pointsHistory,
  regularLessonsLeft,
  RENEWAL_PROMPT_REF,
  renewalPrompt,
  studentTodos,
  type StudentLesson,
} from './home';

const H = 60 * 60 * 1000;
const T0 = kstToInstant('2026-10-01', '09:00'); // 모든 예시 수업보다 앞
const lesson = (id: string, kind: StudentLesson['kind'], date: string, state: StudentLesson['state'] = 'scheduled'): StudentLesson => ({
  id,
  kind,
  startsAt: kstToInstant(date, '20:00'),
  minutes: 50,
  tutorName: 'T',
  state,
});

describe('재등록 안내 (POL-RN-08)', () => {
  const three = [lesson('a', 'regular', '2026-10-15'), lesson('b', 'regular', '2026-10-20'), lesson('c', 'regular', '2026-10-22')];

  it('수업 3회 남으면 숨김', () => expect(renewalPrompt(three, 'not_requested', T0)).toBeNull());

  it('수업 2회 이하면 재등록 신청 버튼', () => {
    expect(renewalPrompt(three.slice(1), 'not_requested', T0)).toEqual({ mode: 'request', left: 2 });
    expect(renewalPrompt([], 'not_requested', T0)).toEqual({ mode: 'request', left: 0 });
  });

  it('보강·보상도 수업으로 셈 (2026-10-27 대표) — 정규 2 + 보강 2면 안 보임, 날짜 미정 보강도 셈', () => {
    const list = [...three.slice(1), lesson('m1', 'makeup', '2026-10-21'), lesson('m2', 'compensation', '2026-10-21')];
    expect(regularLessonsLeft(list, T0)).toBe(2);
    expect(lessonsLeft(list, T0)).toEqual({ total: 4, regular: 2, other: 2 });
    expect(lessonsLeft(list, T0, 1)).toEqual({ total: 5, regular: 2, other: 3 });
    expect(renewalPrompt(list, 'not_requested', T0)).toBeNull();
    expect(renewalPrompt(three.slice(2), 'not_requested', T0, 1)).toEqual({ mode: 'request', left: 2 });
    expect(renewalPrompt(three.slice(2), 'not_requested', T0, 2)).toBeNull();
  });

  it('진행·취소된 정규 수업은 남은 수업이 아님', () => {
    const list = [lesson('x', 'regular', '2026-10-13', 'done'), lesson('y', 'regular', '2026-10-14', 'canceled'), ...three];
    expect(regularLessonsLeft(list, T0)).toBe(3);
  });

  it('시작 시각이 지난 예정 수업은 기록 전이어도 남은 수업이 아님 (대시보드와 같은 기준)', () => {
    const after = new Date(kstToInstant('2026-10-20', '20:00').getTime() + 1);
    expect(lessonsLeft(three, after)).toEqual({ total: 1, regular: 1, other: 0 });
    expect(renewalPrompt([three[2]], 'not_requested', kstToInstant('2026-10-22', '21:30'))).toEqual({ mode: 'request', left: 0 });
  });

  it('남은 수업 0회: 마지막 수업이 있는 날까지 보이고 다음 날부터 숨김 (수강생 거주지 날짜, 2026-11-07 대표)', () => {
    expect(renewalPrompt([three[2]], 'not_requested', kstToInstant('2026-10-22', '23:59'))).toEqual({ mode: 'request', left: 0 });
    expect(renewalPrompt([three[2]], 'not_requested', kstToInstant('2026-10-23', '09:00'))).toBeNull();
    // 토론토 수강생: 마지막 수업 한국 10/22 20:00 = 토론토 10/22 07:00 → 한국 10/23 09:00 은 토론토 10/22 20:00 (아직 그날)
    expect(renewalPrompt([three[2]], 'not_requested', kstToInstant('2026-10-23', '09:00'), 0, 'America/Toronto')).toEqual({ mode: 'request', left: 0 });
    // 날짜 미정 보강이 남아 있으면 계속 보임
    expect(renewalPrompt([three[2]], 'not_requested', kstToInstant('2026-10-30', '09:00'), 1)).toEqual({ mode: 'request', left: 1 });
  });

  it('신청했지만 결제 확인 전이면 "결제 확인 중", 결제 확인되면 사라짐', () => {
    expect(renewalPrompt(three.slice(1), 'requested', T0)).toEqual({ mode: 'awaiting_payment', left: 2 });
    expect(renewalPrompt(three.slice(1), 'payment_confirmed', T0)).toBeNull();
  });

  it('기준 정책이 기준표에서 확정·대표 승인', () => {
    const register = readFileSync(join(__dirname, '..', '..', '..', 'docs/lms/policy/register.md'), 'utf8');
    const block = register.split(/^### /m).find((b) => b.startsWith(RENEWAL_PROMPT_REF))!;
    expect(block).toMatch(/^- \*\*상태\*\*: 확정/m);
    expect(block).toMatch(/^- \*\*대표 승인\*\*: ✅/m);
  });
});

describe('다음 수업', () => {
  it('수업이 끝나기 전까지는 다음 수업으로 남음 (입장 버튼)', () => {
    const l = lesson('a', 'regular', '2026-10-15');
    expect(nextLesson([l], new Date(l.startsAt.getTime() + 49 * 60_000))?.id).toBe('a');
    expect(nextLesson([l], new Date(l.startsAt.getTime() + 50 * 60_000))).toBeNull();
  });

  it('가장 이른 예정 수업 (보강 포함)', () => {
    const list = [lesson('r', 'regular', '2026-10-20'), lesson('m', 'makeup', '2026-10-16'), lesson('d', 'regular', '2026-10-15', 'canceled')];
    expect(nextLesson(list, kstToInstant('2026-10-15', '09:00'))?.id).toBe('m');
  });
});

describe('할 일 알림', () => {
  it('수강생이 처리할 일이 없으면 비어 있음 (강사 확인 중은 입력에 없음)', () => {
    expect(studentTodos({ pendingConsents: [] })).toEqual([]);
  });
  it('수업 안내 동의가 필요하면 표시', () => {
    expect(studentTodos({ pendingConsents: [{ id: 'g1', title: '새 수업 안내' }] })).toEqual([
      { kind: 'terms_consent', id: 'g1', label: '새 수업 안내 동의가 필요해요' },
    ]);
  });
});

describe('적립금 이력 (POL-PAY-11·09)', () => {
  it('날짜·금액·사유와 각 줄 뒤 잔액, 최신 순서', () => {
    const { balance, rows } = pointsHistory([
      { id: '1', on: '2026-09-10', kind: 'grant', amount: 2000, reason: '강사 사정 취소 보상' },
      { id: '2', on: '2026-09-20', kind: 'use_pending', amount: 2000, reason: '재등록 결제에 사용 신청' },
      { id: '3', on: '2026-09-23', kind: 'release', amount: 2000, reason: '결제 취소로 되돌림' },
      { id: '4', on: '2026-10-08', kind: 'grant', amount: 2000, reason: '강사 사정 취소 보상' },
    ]);
    expect(balance).toBe(4000);
    expect(rows.map((r) => [r.id, r.signed, r.balanceAfter])).toEqual([
      ['4', 2000, 4000],
      ['3', 2000, 2000],
      ['2', -2000, 0],
      ['1', 2000, 2000],
    ]);
  });

  it('잔액이 음수가 되면 오류 (기록이 잘못됨)', () => {
    expect(() => pointsHistory([{ id: '1', on: '2026-09-10', kind: 'use', amount: 1000, reason: 'x' }])).toThrow();
  });

  it('금액은 양의 정수만', () => {
    expect(() => pointsHistory([{ id: '1', on: '2026-09-10', kind: 'grant', amount: -5, reason: 'x' }])).toThrow();
  });
});

describe('변경·취소 최종 확인 (POL-CHG-01·02)', () => {
  const base = { finalEndDate: '2026-10-22', creditsLeft: 1, holidays: new Set<string>() };
  const l = lesson('a', 'regular', '2026-10-20');

  it('6시간 전: 변경권 1개 사용, 수업 차감 없음, 보강 가능', () => {
    const d = cancelPreview({ ...base, lesson: l, now: new Date(l.startsAt.getTime() - 6 * H) }, null);
    expect(d).toMatchObject({ ok: true, timing: 'advance', usesCredit: true, consumesLesson: false, makeupAllowed: true });
  });

  it('다음 수강권 수업: 그 수업 수강권 종료일로 판정 (지금 수강권 종료일 뒤라도 취소 가능)', () => {
    const next = { ...lesson('n', 'regular', '2026-11-01'), finalEndDate: '2026-11-28' as const };
    const d = cancelPreview({ ...base, lesson: next, now: new Date(next.startsAt.getTime() - 24 * H) }, null);
    expect(d).toMatchObject({ ok: true, timing: 'advance', usesCredit: true });
  });

  it('6시간 이내: 수업 1회 차감, 보강 불가, 변경권 유지', () => {
    const d = cancelPreview({ ...base, lesson: l, now: new Date(l.startsAt.getTime() - 6 * H + 60_000) }, null);
    expect(d).toMatchObject({ ok: true, timing: 'late', usesCredit: false, consumesLesson: true, makeupAllowed: false });
  });

  it('보상 수업은 재취소 규칙(POL-TU-10)이 정해지기 전에는 판정하지 않음', () => {
    const c = { ...l, kind: 'compensation' as const };
    expect(cancelPreview({ ...base, lesson: c, now: new Date(c.startsAt.getTime() - 24 * H) }, null)).toEqual({ ok: false, reason: 'policy_pending' });
  });
});

describe('여러 수업 취소 미리 보기 — 기간별 변경권 (R-12·R-01·R-04)', async () => {
  const { planCancelMany, creditsForDate, creditPeriodFor, cancelManySummary } = await import('./home');
  const now = kstToInstant('2026-11-05', '12:00');
  const periods = [
    { start: '2026-10-14' as const, end: '2026-11-10' as const, granted: 2, left: 1 },
    { start: '2026-11-11' as const, end: '2026-12-08' as const, granted: 2, left: 2 },
    { start: '2026-12-09' as const, end: '2027-01-05' as const, granted: 2, left: 2 },
  ];
  const base = { now, finalEndDate: '2027-01-05' as const, creditsLeft: 1, creditPeriods: periods, holidays: new Set<never>() };

  it('수업 날짜가 속한 기간의 변경권으로 판정 (지금 기간 1개가 아니라 11/11~12/8 기간 2개)', () => {
    expect(creditsForDate(periods, '2026-11-12', 1)).toBe(2);
    expect(creditsForDate(periods, '2026-11-05', 9)).toBe(1);
    expect(creditsForDate([], '2026-11-12', 7)).toBe(7);   // 옛 DB: 기간 목록 없으면 지금 잔여
    // 기간 사이 빈 날짜는 그 전 마지막 기간 (DB lms_lesson_period 와 같음)
    expect(creditPeriodFor(periods, '2027-02-01')?.start).toBe('2026-12-09');
    expect(creditPeriodFor(periods, '2026-01-01')).toBeNull();
  });
  it('11/12·11/17 두 수업: 미래 기간 변경권 2개 → 0개, 둘 다 보강 가능 (실제 DB 결과와 같음)', () => {
    const plan = planCancelMany([lesson('a', 'regular', '2026-11-12'), lesson('b', 'regular', '2026-11-17')], base);
    expect(plan.uses).toBe(2);
    expect(plan.makeups).toBe(2);
    expect(plan.consumes).toBe(0);
    expect(plan.periods).toEqual([{ start: '2026-11-11', end: '2026-12-08', before: 2, after: 0 }]);
  });
  it('기간이 다른 두 수업은 각자 기간에서 차감 (11/10 지금 기간 1개 → 0, 11/12 다음 기간 2개 → 1)', () => {
    const plan = planCancelMany([lesson('b', 'regular', '2026-11-12'), lesson('a', 'regular', '2026-11-10')], base);
    expect(plan.items.map((x) => x.lesson.id)).toEqual(['a', 'b']);   // 시간순
    expect(plan.periods).toEqual([
      { start: '2026-10-14', end: '2026-11-10', before: 1, after: 0 },
      { start: '2026-11-11', end: '2026-12-08', before: 2, after: 1 },
    ]);
  });
  it('같은 기간 수업 3개, 변경권 2개: 세 번째는 변경권 없음 → 1회 차감·보강 없음 (R-04: 보강 수는 2)', () => {
    const plan = planCancelMany([lesson('a', 'regular', '2026-11-12'), lesson('b', 'regular', '2026-11-17'), lesson('c', 'regular', '2026-11-19')], base);
    expect(plan.uses).toBe(2);
    expect(plan.makeups).toBe(2);
    expect(plan.consumes).toBe(1);
    expect(plan.items[2].decision).toMatchObject({ ok: true, usesCredit: false, consumesLesson: true, makeupAllowed: false });
  });
  it('변경권 0 기간의 수업 2개: 보강 0 → 안내 문구 없이 차감만 (R-04)', () => {
    const plan = planCancelMany([lesson('a', 'regular', '2026-11-12'), lesson('b', 'regular', '2026-11-13')], { ...base, creditPeriods: [{ ...periods[1], left: 0 }] });
    expect(plan.makeups).toBe(0);
    expect(plan.consumes).toBe(2);
    expect(plan.uses).toBe(0);
  });
  it('완료 문구는 저장 결과로: 2개 차감·보강 2 → "변경권 2개 사용 · 남은 변경권 0개 · 보강 2회" (R-01)', () => {
    const text = cancelManySummary([{ uses_credit: true, makeup_allowed: true }, { uses_credit: true, makeup_allowed: true }], [{ start: '2026-11-11', left: 0 }]);
    expect(text).toBe('수업 2회를 취소했어요 · 변경권 2개 사용 · 남은 변경권 0개 · 보강 2회는 ‘보강 신청’에서 날짜를 골라 주세요');
    expect(cancelManySummary([{ uses_credit: false, makeup_allowed: false }], [{ start: null, left: 0 }])).toBe('수업 1회를 취소했어요 · 변경권 0개 사용 · 남은 변경권 0개');
    expect(cancelManySummary([{ uses_credit: true, makeup_allowed: true }, { uses_credit: true, makeup_allowed: true }], [{ start: '2026-10-14', left: 0 }, { start: '2026-11-11', left: 1 }]))
      .toContain('남은 변경권 10/14~ 0개, 11/11~ 1개');
  });
});
