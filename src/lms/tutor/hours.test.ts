import { describe, expect, it } from 'vitest';
import { applyFromText, classFill, describeChanges, describeChangesIn, diff, lessonAt, parseHours, runs, weekText, weeklyClassAt } from './hours';

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
      'Every Saturday 10:00–10:30 AM → open',
      'Every Monday 9:00–10:00 AM → closed',
      'Mon 2 Nov 10:00–11:00 AM → blocked',
      'Tue 3 Nov 8:00–8:30 AM → block removed',
    ]);
    expect(describeChanges(ch, 'ko')).toEqual(['매주 토 오전 10:00–10:30 → 열림', '매주 월 오전 9:00–10:00 → 닫음', '11/2(월) 오전 10:00–11:00 → 그날만 막음', '11/3(화) 오전 8:00–8:30 → 막기 풂']);
  });
  it('주 표시와 DB 값 읽기', () => {
    expect(weekText('2026-11-02')).toBe('2 – 8 Nov');
    expect(weekText('2026-11-30')).toBe('30 Nov – 6 Dec');
    const h = parseHours({ tutor: { id: 't', name: 'T', timezone: 'Asia/Tokyo' }, from: '2026-11-02', monday: '2026-10-26', times: ['09:00'], weekly_open: ['1:09:00'],
      weekly_classes: [], cells: { '2026-10-26T09:00': 'p' }, lessons: [], history: [{ at: '2026-10-29T01:00:00Z', by_admin: true, changes: { from: '2026-11-02', weekly_open: ['1:09:00'] } }] });
    expect(h.history?.[0].changes.weeklyClose).toEqual([]);
    expect(parseHours({ tutor: { id: 't', name: 'T', timezone: 'Asia/Tokyo' }, history: null }).history).toBeNull();
  });
  it('Every week 적용일 안내: 강사 현지 월요일 날짜 그대로', () => {
    expect(applyFromText('2026-11-09')).toBe('Changes apply from Mon, Nov 9.');
  });
  it('바뀐 내용: 고른 시간대 먼저, 다른 시간대 보조 (날짜·요일 달라짐, 서머타임)', () => {
    const none = { weeklyOpen: [], weeklyClose: [], onceClose: [], onceOpen: [] };
    // 호치민(UTC+7) 월 15:30–16:00 = KST 월 17:30–18:00
    const a = describeChangesIn({ ...none, weeklyOpen: ['1:15:30'] }, '2026-11-09', 'Asia/Ho_Chi_Minh', 'Asia/Seoul');
    expect(a).toEqual([{ main: 'Every Monday 5:30–6:00 PM KST → open', sub: 'Every Monday 3:30–4:00 PM Ho Chi Minh Time' }]);
    const b = describeChangesIn({ ...none, weeklyOpen: ['1:15:30'] }, '2026-11-09', 'Asia/Ho_Chi_Minh', 'Asia/Ho_Chi_Minh');
    expect(b[0].main).toBe('Every Monday 3:30–4:00 PM Ho Chi Minh Time → open');
    expect(b[0].sub).toBe('Every Monday 5:30–6:00 PM KST');
    // 멜버른 월 01:00(서머타임 UTC+11) = KST 일 23:00 → 요일이 달라짐
    const c = describeChangesIn({ ...none, weeklyClose: ['1:01:00'] }, '2026-11-09', 'Australia/Melbourne', 'Asia/Seoul');
    expect(c[0].main).toBe('Every Sunday 11:00–11:30 PM KST → closed');
    expect(c[0].sub).toBe('Every Monday 1:00–1:30 AM Melbourne Time');
    // 그 주만, 자정을 걸치는 칸 묶음
    const d = describeChangesIn({ ...none, onceClose: ['2026-11-10T21:30', '2026-11-10T22:00'] }, '2026-11-09', 'Asia/Ho_Chi_Minh', 'Asia/Seoul');
    expect(d[0].main).toBe('Tue 10 Nov 11:30 PM – Wed 11 Nov 12:30 AM KST → blocked');
    expect(d[0].sub).toBe('Tue 10 Nov 9:30–10:30 PM Ho Chi Minh Time');
    // 강사가 한국이면 보조 줄 없음
    expect(describeChangesIn({ ...none, weeklyOpen: ['1:09:00'] }, '2026-11-09', 'Asia/Seoul', 'Asia/Seoul')[0].sub).toBeNull();
  });
  it('40분 수업: 두 번째 칸은 위 1/3만 수업', () => {
    expect(classFill(60, 40, 60)).toEqual({ from: 0, to: 1 });
    expect(classFill(60, 40, 90)).toEqual({ from: 0, to: 10 / 30 });
    expect(classFill(615, 20, 600)).toEqual({ from: 0.5, to: 1 });
  });
});
