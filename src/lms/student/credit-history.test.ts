import { describe, expect, it } from 'vitest';
import { creditFor, parseCreditHistory, resultText, subText, timingText, type CreditItem } from './credit-history';
import { historyRow, type ProcessingEvent } from './processing-history';

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
    expect(timingText(item({}))).toBe('6시간 이상 남았을 때');
    expect(timingText(item({ kind: 'late', timing: 'late', delta: 0 }))).toBe('6시간 미만 남았을 때');
    expect(timingText(item({ kind: 'return', timing: null }))).toBeNull();
  });
  it('결과·처리 후', () => {
    expect(resultText(item({ kind: 'late', delta: 0 }))).toBe('변경권 사용 안 됨 · 수업 1회 차감');
    expect(subText(item({ kind: 'late', timing: 'late', delta: 0, after: 1 }))).toBe('6시간 미만 남았을 때 · 수업 1회 차감 · 처리 후 1개');
    expect(subText(item({ kind: 'return', timing: null, delta: 1, after: 2 }))).toBe('처리 후 2개');
    expect(subText(item({ kind: 'no_credit', delta: 0, reverted: true }))).toBe('6시간 이상 남았을 때 · 나중에 취소 되돌림 · 처리 후 0개');
    expect(resultText(item({ kind: 'no_credit', delta: 0, reverted: true }))).toBe('남은 0개');
  });
  it('처리 내역 줄에 맞는 기록: 같은 수업·가까운 처리 시각, 강사 취소는 없음', () => {
    const periods = parseCreditHistory([{ start: '2026-11-12', end: '2026-12-09', granted: 2, left: 0, current: true,
      items: [item({ id: 'a' }), item({ id: 'b', kind: 'return', delta: 1, at: '2026-11-12T00:00:00Z', after: 1, timing: null })] }]);
    expect(creditFor(ev({}), periods)?.id).toBe('a');
    expect(creditFor(ev({ kind: 'lesson_restored', at: '2026-11-12T00:00:00Z' }), periods)?.id).toBe('b');
    expect(creditFor(ev({ cancel_reason: 'tutor_canceled' }), periods)).toBeNull();
    expect(creditFor(ev({ at: '2026-11-11T13:07:25Z' }), periods)).toBeNull();
  });
  it('처리 내역 줄 (대표 11/18): 수업 시각 · 취소 일시 · 구분 · 상태 · 변경권', () => {
    const r = historyRow(ev({ cancel_at: '2026-11-11T12:00:00Z', timing: 'advance' }), 'Australia/Sydney', null, item({ after: 1 }));
    expect(r).toEqual({ title: '수업 취소', lessonLabel: '취소한 수업', lesson: '11/19(목) 오후 9:00', timeLabel: '취소 일시', time: '11/11(수) 오후 11:00',
      sub: '6시간 이상 남았을 때 · 수강생 취소', status: '취소 처리 완료', credit: '1개 사용 · 2개 → 1개' });
    expect(historyRow(ev({ timing: 'late' }), 'Asia/Seoul', null, item({ kind: 'late', delta: 0, timing: 'late' })).credit).toBe('사용 안 됨 · 수업 1회 차감');
    expect(historyRow(ev({}), 'Asia/Seoul', null, item({ kind: 'no_credit', delta: 0 })).credit).toBe('남은 0개 · 수업 1회 차감');
    const t = historyRow(ev({ cancel_reason: 'tutor_canceled', timing: 'late' }), 'Asia/Seoul');
    expect([t.sub, t.credit]).toEqual(['6시간 미만 남았을 때 · 강사 취소', null]);
    expect(historyRow(ev({ cancel_reason: 'tutor_leave', timing: null }), 'Asia/Seoul').sub).toBe('강사 휴무로 취소');
    expect(historyRow(ev({ kind: 'lesson_restored' }), 'Asia/Seoul', null, item({ kind: 'return', delta: 1, after: 2, timing: null })).credit).toBe('1개 반환 · 1개 → 2개');
    const c = historyRow(ev({ kind: 'makeup_confirmed', booked_at: '2026-11-20T10:00:00Z', cancel_reason: null }), 'Asia/Seoul');
    expect([c.lessonLabel, c.timeLabel, c.status, c.sub]).toEqual(['원래 수업', '확정 일시', '11/20(금) 오후 7:00 보강 확정', null]);
  });
});
