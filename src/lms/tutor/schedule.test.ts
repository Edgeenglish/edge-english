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
