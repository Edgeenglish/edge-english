import { describe, expect, it } from 'vitest';
import { tutorLateBand, tutorLateOpen, tutorLateSent } from './late';

const l = (startsAt: Date, extra: Partial<{ state: 'scheduled' | 'canceled' | 'done'; leaveOpen: boolean; coveredByOther: boolean }> = {}) =>
  ({ state: 'scheduled' as const, startsAt, leaveOpen: false, coveredByOther: false, ...extra });
const now = new Date('2026-11-14T10:00:00Z');
const at = (min: number) => new Date(now.getTime() + min * 60_000);

describe('강사 늦어요 알림', () => {
  it('시작 2시간 전부터 시작 전까지만', () => {
    expect(tutorLateOpen(l(at(121)), now)).toBe(false);
    expect(tutorLateOpen(l(at(120)), now)).toBe(true);
    expect(tutorLateOpen(l(at(1)), now)).toBe(true);
    expect(tutorLateOpen(l(at(0)), now)).toBe(false);
    expect(tutorLateOpen(l(at(-5)), now)).toBe(false);
  });
  it('취소·휴무 처리 중·대체된 수업은 안 됨', () => {
    expect(tutorLateOpen(l(at(30), { state: 'canceled' }), now)).toBe(false);
    expect(tutorLateOpen(l(at(30), { leaveOpen: true }), now)).toBe(false);
    expect(tutorLateOpen(l(at(30), { coveredByOther: true }), now)).toBe(false);
  });
  it('문구', () => {
    expect(tutorLateSent(10)).toBe('Sent ✓ · about 10 min late');
    expect(tutorLateSent(20)).toBe('Sent ✓ · 20+ min late');
    expect(tutorLateBand(10, 'internet')).toBe('⚠️ 강사님이 약 10분 늦을 예정이에요 · 인터넷 연결에 문제가 생겼어요');
    expect(tutorLateBand(20, null)).toBe('⚠️ 강사님이 20분 이상 늦을 예정이에요');
  });
});

import { sendTutorLate } from './live';
describe('강사 늦어요 알림 보내기 (QA 11/14 ②)', () => {
  it('다른 창에서 먼저 보냈으면(repeated) 화면에는 DB 에 저장된 값을 돌려줌', async () => {
    const calls: string[] = [];
    const sb = { rpc: async (fn: string) => {
      calls.push(fn);
      if (fn === 'tutor_late_notice') return { data: { repeated: true }, error: null };
      return { data: [{ lesson_id: 'L1', minutes: 10, reason: 'internet', at: '2026-11-14T10:00:00Z' }], error: null };
    } } as unknown as Parameters<typeof sendTutorLate>[0];
    const r = await sendTutorLate(sb, null, 'L1', 20, 'power');
    expect(r).toEqual({ minutes: 10, reason: 'internet', at: new Date('2026-11-14T10:00:00Z') });
    expect(calls).toEqual(['tutor_late_notice', 'tutor_late_notices']);
  });
});
