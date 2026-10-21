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

  it('정규 3회 남으면 숨김', () => expect(renewalPrompt(three, 'not_requested')).toBeNull());

  it('정규 2회 이하면 재등록 신청 버튼', () => {
    expect(renewalPrompt(three.slice(1), 'not_requested')).toEqual({ mode: 'request', regularLeft: 2 });
    expect(renewalPrompt([], 'not_requested')).toEqual({ mode: 'request', regularLeft: 0 });
  });

  it('보강·보상 수업은 세지 않음 — 정규 2 + 보강 2 이어도 보임', () => {
    const list = [...three.slice(1), lesson('m1', 'makeup', '2026-10-21'), lesson('m2', 'compensation', '2026-10-21')];
    expect(regularLessonsLeft(list)).toBe(2);
    expect(lessonsLeft(list)).toEqual({ total: 4, regular: 2, other: 2 });
    expect(lessonsLeft(list, 1)).toEqual({ total: 5, regular: 2, other: 3 });
    expect(renewalPrompt(list, 'not_requested')).toMatchObject({ mode: 'request' });
  });

  it('진행·취소된 정규 수업은 남은 수업이 아님', () => {
    const list = [lesson('x', 'regular', '2026-10-13', 'done'), lesson('y', 'regular', '2026-10-14', 'canceled'), ...three];
    expect(regularLessonsLeft(list)).toBe(3);
  });

  it('신청했지만 결제 확인 전이면 "결제 확인 중", 결제 확인되면 사라짐', () => {
    expect(renewalPrompt(three.slice(1), 'requested')).toEqual({ mode: 'awaiting_payment', regularLeft: 2 });
    expect(renewalPrompt(three.slice(1), 'payment_confirmed')).toBeNull();
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
  it('학생이 처리할 일이 없으면 비어 있음 (강사 확인 중은 입력에 없음)', () => {
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

  it('6시간 이내: 수업 1회 차감, 보강 불가, 변경권 유지', () => {
    const d = cancelPreview({ ...base, lesson: l, now: new Date(l.startsAt.getTime() - 6 * H + 60_000) }, null);
    expect(d).toMatchObject({ ok: true, timing: 'late', usesCredit: false, consumesLesson: true, makeupAllowed: false });
  });

  it('보상 수업은 재취소 규칙(POL-TU-10)이 정해지기 전에는 판정하지 않음', () => {
    const c = { ...l, kind: 'compensation' as const };
    expect(cancelPreview({ ...base, lesson: c, now: new Date(c.startsAt.getTime() - 24 * H) }, null)).toEqual({ ok: false, reason: 'policy_pending' });
  });
});
