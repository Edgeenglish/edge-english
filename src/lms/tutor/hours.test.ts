import { describe, expect, it } from 'vitest';
import { describeChanges, diff, lessonAt, parseHours, runs, weekText, weeklyClassAt } from './hours';

describe('My hours', () => {
  it('붙은 30분 칸을 한 묶음으로', () => {
    expect(runs([600, 540, 570, 720])).toEqual([[540, 600], [720, 720]]);
  });
  it('고정 수업·보강이 걸친 칸 (40분 수업은 두 칸)', () => {
    const cls = [{ d: 1, time: '09:00', min: 40, student: 'A' }];
    expect(weeklyClassAt(cls, 1, '09:00')?.first).toBe(true);
    expect(weeklyClassAt(cls, 1, '09:30')?.first).toBe(false);
    expect(weeklyClassAt(cls, 1, '10:00')).toBeNull();
    expect(weeklyClassAt(cls, 2, '09:00')).toBeNull();
    const ls = [{ start: '2026-11-17T10:15', min: 20, student: 'B', makeup: true }];
    expect(lessonAt(ls, '2026-11-17', '10:00')?.first).toBe(true);
    expect(lessonAt(ls, '2026-11-17', '10:30')?.first).toBe(false);
    expect(lessonAt(ls, '2026-11-17', '11:00')).toBeNull();
  });
  it('바뀐 내용을 사람 말로 (영어 확인 창 · 한국어 기록)', () => {
    const w = diff(['1:09:00', '1:09:30', '1:10:00', '2:09:00'], ['1:10:00', '2:09:00', '6:10:00']);
    const ch = { weeklyOpen: w.added, weeklyClose: w.removed, onceClose: ['2026-11-02T10:00', '2026-11-02T10:30'], onceOpen: ['2026-11-03T08:00'] };
    expect(describeChanges(ch, 'en')).toEqual([
      'Every Saturday 10:00–10:30 → open',
      'Every Monday 9:00–10:00 → closed',
      'Mon 2 Nov 10:00–11:00 → unavailable this week',
      'Tue 3 Nov 8:00–8:30 → open again',
    ]);
    expect(describeChanges(ch, 'ko')).toEqual(['매주 토 10:00–10:30 → 열림', '매주 월 9:00–10:00 → 닫음', '11/2(월) 10:00–11:00 → 그 주만 닫음', '11/3(화) 8:00–8:30 → 다시 엶']);
  });
  it('주 표시와 DB 값 읽기', () => {
    expect(weekText('2026-11-02')).toBe('2 – 8 Nov');
    expect(weekText('2026-11-30')).toBe('30 Nov – 6 Dec');
    const h = parseHours({ tutor: { id: 't', name: 'T', timezone: 'Asia/Tokyo' }, from: '2026-11-02', monday: '2026-10-26', times: ['09:00'], weekly_open: ['1:09:00'],
      weekly_classes: [], cells: { '2026-10-26T09:00': 'p' }, lessons: [], history: [{ at: '2026-10-29T01:00:00Z', by_admin: true, changes: { from: '2026-11-02', weekly_open: ['1:09:00'] } }] });
    expect(h.history?.[0].changes.weeklyClose).toEqual([]);
    expect(parseHours({ tutor: { id: 't', name: 'T', timezone: 'Asia/Tokyo' }, history: null }).history).toBeNull();
  });
});
