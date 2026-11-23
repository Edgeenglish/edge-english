import { describe, expect, it } from 'vitest';
import { firstDate, firstDate2, mondayOf, slotsOf, weekFor, weekFor2, weekOk, type RcContext } from './regular-change';

// 대표 11/17 확정 예시 (H26(208) 보충 2). 화(2) 수업을 바꿈
const ctx = (today: string, used = false): RcContext => ({
  today: today as never, finalEnd: '2026-12-31' as never,
  periods: [{ start: '2026-11-11' as never, end: '2026-12-08' as never, used }, { start: '2026-12-09' as never, end: '2027-01-05' as never, used: false }],
});
const tue = { weekday: 2, time: '21:00' };

describe('정규 시간 변경 적용 주', () => {
  it('월요일 시작 주', () => {
    expect(mondayOf('2026-11-17')).toBe('2026-11-16');
    expect(mondayOf('2026-11-22')).toBe('2026-11-16');
    expect(mondayOf('2026-11-23')).toBe('2026-11-23');
  });
  it('그 주 첫 바뀌는 수업 = 옛·새 날짜 중 빠른 날', () => {
    expect(firstDate('2026-11-23', [{ old: tue, new: { weekday: 3, time: '20:00' } }])).toBe('2026-11-24');
    expect(firstDate('2026-11-23', [{ old: tue, new: { weekday: 1, time: '19:30' } }])).toBe('2026-11-23');
  });
  it('11/17(화) 신청 → 11/23 주', () => {
    expect(weekFor(ctx('2026-11-17'), [{ old: tue, new: { weekday: 1, time: '19:30' } }])).toBe('2026-11-23');
  });
  it('11/20(금) 신청: 월 후보는 11/30 주, 수 후보는 11/23 주', () => {
    expect(weekFor(ctx('2026-11-20'), [{ old: tue, new: { weekday: 1, time: '19:30' } }])).toBe('2026-11-30');
    expect(weekFor(ctx('2026-11-20'), [{ old: tue, new: { weekday: 3, time: '20:00' } }])).toBe('2026-11-23');
  });
  it('11/21(토) 신청: 화→수 는 11/30 주', () => {
    expect(weekFor(ctx('2026-11-21'), [{ old: tue, new: { weekday: 3, time: '20:00' } }])).toBe('2026-11-30');
  });
  it('같은 요일 시간만 바꿈', () => {
    expect(weekFor(ctx('2026-11-17'), [{ old: tue, new: { weekday: 2, time: '20:00' } }])).toBe('2026-11-23');
  });
  it('이번 수강기간에 이미 바꿨으면 다음 수강기간 첫 주부터', () => {
    expect(weekFor(ctx('2026-11-17', true), [{ old: tue, new: { weekday: 3, time: '20:00' } }])).toBe('2026-12-14');
  });
  it('수강 종료일 안에 맞는 주가 없으면 null', () => {
    expect(weekFor({ ...ctx('2026-11-17'), finalEnd: '2026-11-22' as never }, [{ old: tue, new: { weekday: 3, time: '20:00' } }])).toBeNull();
  });
  it('변경 시작 주를 고르면 그 주에 적용 가능한지', () => {
    const c = ctx('2026-11-20');
    expect(weekOk(c, [{ old: tue, new: { weekday: 1, time: '19:30' } }], '2026-11-23')).toBe(false);
    expect(weekOk(c, [{ old: tue, new: { weekday: 1, time: '19:30' } }], '2026-12-14')).toBe(true);
    expect(weekOk(c, [{ old: tue, new: { weekday: 1, time: '19:30' } }], '2026-12-15')).toBe(false);
  });
  it('옮기면 마지막 수업이 종료일 뒤로 밀리는 후보는 안 됨 (종료 12/9 수, 월→목)', () => {
    const c = { ...ctx('2026-11-17'), finalEnd: '2026-12-09' as never };
    expect(weekFor(c, [{ old: { weekday: 1, time: '19:00' }, new: { weekday: 4, time: '20:00' } }])).toBeNull();
    expect(weekFor(c, [{ old: { weekday: 4, time: '19:00' }, new: { weekday: 2, time: '20:00' } }])).toBe('2026-11-23');
  });
  it('일정 전체(같은 시간 규칙): 화·금 오후 1:00 → 수·금 1:00 은 화요일만 바뀜, 같은 일정은 null', () => {
    const old = slotsOf([2, 5], '13:00');
    expect(firstDate2('2026-11-23', old, slotsOf([3, 5], '13:00'))).toBe('2026-11-24');
    expect(firstDate2('2026-11-23', old, slotsOf([5, 2], '13:00'))).toBeNull();
    expect(firstDate2('2026-11-23', old, slotsOf([2, 5], '12:30'))).toBe('2026-11-24');
    expect(weekFor2(ctx('2026-11-20'), old, slotsOf([1, 3], '12:30'))).toBe('2026-11-30');
    expect(weekFor2(ctx('2026-11-20'), old, slotsOf([3, 5], '13:00'))).toBe('2026-11-23');
  });
});
