import { describe, expect, it } from 'vitest';
import { kstToInstant } from '../rules/dates';
import { holdBusy, type HoldSchedule } from './holds';
import { importIssues, importLessons, emptyImport } from './import';

// 가상이관일: Alex 월 18:30 50분, 11/19(목) 종료
const row: HoldSchedule = { id: 'r1', tutorId: 'A', studentName: '가상이관일', weekday: 1, time: '18:30', durationMin: 50, effectiveFrom: '2026-10-22', effectiveTo: null, lastEnd: '2026-11-19' };

describe('재등록 대기 자리 맡아 두기 (A22)', () => {
  it('종료일 23:59 전에는 종료 뒤 월요일 18:30 을 막음', () => {
    const b = holdBusy([row], kstToInstant('2026-10-22', '17:00'), '2026-12-10').get('A')!;
    expect(b.map((x) => x.startsAt.getTime())).toEqual(['2026-11-23', '2026-11-30', '2026-12-07'].map((d) => kstToInstant(d, '18:30').getTime()));
    expect(b[0].label).toBe('재등록 대기 · 가상이관일 (11/19 23:59까지)');
  });
  it('종료일 23:59 까지는 맡아 두고, 그 뒤엔 풀림', () => {
    expect(holdBusy([row], kstToInstant('2026-11-19', '23:59'), '2026-12-10').get('A')?.length).toBe(3);
    expect(holdBusy([row], kstToInstant('2026-11-20', '00:00'), '2026-12-10').get('A')).toBeUndefined();
  });
  it('신규·기존 입력의 충돌 검사에 재등록 대기로 나옴', () => {
    const tutors = [{ id: 'A', name: 'Alex', country: 'AU', timezone: 'Australia/Sydney', availability: [], busy: holdBusy([row], kstToInstant('2026-10-22', '17:00'), '2026-12-31').get('A')! }];
    const d = { ...emptyImport('2026-11-23'), nameKo: 'x', nameEn: 'x', tutorId: 'A', slots: [{ weekday: 1, time: '18:30' }], endDate: '2026-12-20' };
    const issues = importIssues(importLessons(d), tutors);
    expect(issues).toHaveLength(4);
    expect(issues.every((i) => i.reason === 'tutor_hold')).toBe(true);
  });
});
