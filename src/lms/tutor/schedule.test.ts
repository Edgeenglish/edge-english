import { describe, expect, it } from 'vitest';
import { dayTag, monthGrid, runFrom, type DayItem } from './schedule';
import { NO_LATE, type TutorLesson } from './screen';

const lesson = (extra: Partial<TutorLesson>): TutorLesson => ({
  id: 'l', startsAt: new Date('2026-11-10T10:00:00Z'), endsAt: new Date('2026-11-10T10:40:00Z'), kind: 'regular', state: 'scheduled', classStatus: null,
  student: 'S', level: null, noteUrl: null, covering: false, makeupOf: null, count: null, topics: null, remarks: null, studentLate: false, late: NO_LATE,
  recordedAt: null, locked: false, ...extra,
});
const at = new Date('2026-11-10T10:00:00Z');

describe('Schedule', () => {
  it('달력은 일요일 시작, 그 달 마지막 주까지', () => {
    const g = monthGrid('2026-11');
    expect(g[0]).toBe('2026-11-01');
    expect(g.length).toBe(35);
    expect(g.at(-1)).toBe('2026-12-05');
  });
  it('휴대폰 칸 짧은 글자: 보상수업 Extra class, 그날만 연 시간 Extra hours (Comp·Open 대신, 대표 11/4)', () => {
    expect(dayTag([{ kind: 'lesson', at, lesson: lesson({ kind: 'compensation' }) }])).toBe('Extra class');
    const open: DayItem = { kind: 'open', at, end: new Date(+at + 3600000) };
    expect(dayTag([open])).toBe('Extra hours');
    expect(dayTag([open, { kind: 'lesson', at, lesson: lesson({ state: 'canceled' }) }])).toBe('Cancel');
  });
  it('끝 시간은 같은 칸이 이어지는 동안, 수업에서 끊기면 표시', () => {
    expect(runFrom(['free', 'free', 'class', 'free'], 0, 'free')).toEqual({ ends: [1, 2], cutBy: 2 });
    expect(runFrom(['closed', 'closed', 'free'], 0, 'closed')).toEqual({ ends: [1, 2], cutBy: null });
  });
});

describe('Schedule — 재검증 수정 (R-03·R-16)', async () => {
  const { cellKind, dayItems } = await import('./schedule');
  const times = Array.from({ length: 34 }, (_, i) => `${String(6 + Math.floor(i / 2)).padStart(2, '0')}:${i % 2 ? '30' : '00'}`);   // 06:00~22:30
  const data = (cells: Record<string, 'c' | 'r' | 'a' | 'l' | 'p' | 's' | 'b' | 'o' | 'x'>, blocks: { start: string; end: string }[] = []) => ({
    tutor: { id: 't', name: 'Alex', timezone: 'Australia/Sydney' }, today: '2026-11-01', last: '2027-01-24', times, cells,
    blocks: blocks.map((b, i) => ({ id: `b${i}`, kind: 'leave' as const, note: null, ...b })), opens: [],
  });
  it('가능 답을 보낸 칸(a)은 답 대기(r)와 구분 (R-16)', () => {
    const d = data({ '2026-11-13T16:00': 'a', '2026-11-13T16:30': 'r' });
    expect(cellKind('2026-11-13T16:00', d, false)).toBe('answered');
    expect(cellKind('2026-11-13T16:30', d, false)).toBe('request');
    expect(cellKind('2026-11-13T17:00', d, false)).toBe('free');
  });
  it('휴무가 다음 날 새벽(수업 시간 전)에 끝나면 다음 날에는 줄이 없고, 시작한 날에는 그날 부분 + 전체 기간 (R-03)', () => {
    // 한국 11/4 하루 휴무 = Sydney 11/4 02:00 ~ 11/5 02:00
    const d = data({}, [{ start: '2026-11-04T02:00', end: '2026-11-05T02:00' }]);
    expect(dayItems('2026-11-05', 'Australia/Sydney', [], d)).toEqual([]);
    const nov4 = dayItems('2026-11-04', 'Australia/Sydney', [], d);
    expect(nov4).toHaveLength(1);
    const it0 = nov4[0];
    expect(it0.kind).toBe('block');
    if (it0.kind === 'block') {
      expect(it0.at.toISOString()).toBe(new Date('2026-11-04T02:00:00+11:00').toISOString());
      expect(it0.end.toISOString()).toBe(new Date('2026-11-05T00:00:00+11:00').toISOString());   // 그날 끝까지
      expect(it0.spans?.end.toISOString()).toBe(new Date('2026-11-05T02:00:00+11:00').toISOString());   // 전체는 다음 날 02:00 까지
    }
    expect(dayTag(nov4)).toBe('Leave');
    expect(dayTag(dayItems('2026-11-05', 'Australia/Sydney', [], d))).toBeNull();
  });
  it('수업 시간 안에서 끝나는 휴무는 다음 날에도 보임 (그날 부분만)', () => {
    const d = data({}, [{ start: '2026-11-04T02:00', end: '2026-11-05T09:00' }]);
    const nov5 = dayItems('2026-11-05', 'Australia/Sydney', [], d);
    expect(nov5).toHaveLength(1);
    if (nov5[0].kind === 'block') {
      expect(nov5[0].at.toISOString()).toBe(new Date('2026-11-05T00:00:00+11:00').toISOString());
      expect(nov5[0].end.toISOString()).toBe(new Date('2026-11-05T09:00:00+11:00').toISOString());
      expect(nov5[0].spans?.at.toISOString()).toBe(new Date('2026-11-04T02:00:00+11:00').toISOString());
    }
  });
});
