import { describe, expect, it } from 'vitest';
import { creditFor, parseCreditHistory, resultText, subText, timingText, type CreditItem } from './credit-history';
import { historyLines, type ProcessingEvent } from './processing-history';

const item = (x: Partial<CreditItem>): CreditItem => ({
  id: 'i', at: '2026-11-11T12:07:25Z', kind: 'use', delta: -1, lesson_at: '2026-11-19T10:00:00Z',
  cancel_at: '2026-11-11T12:07:25Z', timing: 'advance', holiday: false, after: 0, ...x,
});
const ev = (x: Partial<ProcessingEvent>): ProcessingEvent => ({
  id: 'e', at: '2026-11-11T12:07:25Z', kind: 'lesson_canceled', request_id: null, lesson_at: '2026-11-19T10:00:00Z',
  original_date: null, tutor: null, compensation: false, tutor_fault: false, booked_at: null, cancel_reason: 'student', slots: [], ...x,
});

describe('변경권 내역 (대표 11/18)', () => {
  it('남은 시간 문구: 6시간 이상 / 미만 남기고 취소', () => {
    expect(timingText(item({}))).toBe('6시간 이상 남기고 취소');
    expect(timingText(item({ kind: 'late', timing: 'late', delta: 0 }))).toBe('6시간 미만 남기고 취소');
    expect(timingText(item({ kind: 'return', timing: null }))).toBeNull();
  });
  it('결과·처리 후', () => {
    expect(resultText(item({ kind: 'late', delta: 0 }))).toBe('변경권 사용 안 함 · 수업 1회 차감');
    expect(subText(item({ kind: 'late', timing: 'late', delta: 0, after: 1 }))).toBe('6시간 미만 남기고 취소 · 수업 1회 차감 · 처리 후 1개');
    expect(subText(item({ kind: 'return', timing: null, delta: 1, after: 2 }))).toBe('처리 후 2개');
  });
  it('처리 내역 줄에 맞는 기록: 같은 수업·가까운 처리 시각, 강사 취소는 없음', () => {
    const periods = parseCreditHistory([{ start: '2026-11-12', end: '2026-12-09', granted: 2, left: 0, current: true,
      items: [item({ id: 'a' }), item({ id: 'b', kind: 'return', delta: 1, at: '2026-11-12T00:00:00Z', after: 1, timing: null })] }]);
    expect(creditFor(ev({}), periods)?.id).toBe('a');
    expect(creditFor(ev({ kind: 'lesson_restored', at: '2026-11-12T00:00:00Z' }), periods)?.id).toBe('b');
    expect(creditFor(ev({ cancel_reason: 'tutor_canceled' }), periods)).toBeNull();
    expect(creditFor(ev({ at: '2026-11-11T13:07:25Z' }), periods)).toBeNull();
  });
  it('처리 내역 수강생 취소 줄: 수업 시각 · 남은 시간 · 결과 · 처리 후, 상태 줄 없음', () => {
    const l = historyLines(ev({}), 'Australia/Sydney', null, item({}));
    expect(l.detail).toBe('취소한 수업 : 11/19(목) 오후 9:00');
    expect(l.extra).toEqual(['6시간 이상 남기고 취소', '변경권 1개 사용', '처리 후 변경권 0개']);
    expect(l.status).toBeNull();
  });
});
