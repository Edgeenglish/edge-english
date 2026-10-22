import { describe, expect, it } from 'vitest';
import { kstToInstant } from '../rules/dates';
import { emptyImport, importIssues, importLessons, importPayload, importProblems, type ImportDraft } from './import';
import type { RegTutor } from './registration';

// 2027-08-02(월) ~ 2027-08-29(일)
const base = (over: Partial<ImportDraft> = {}): ImportDraft => ({
  ...emptyImport('2027-08-02'),
  nameKo: '이관', nameEn: 'Import', tutorId: 'T', durationMin: 50,
  slots: [{ weekday: 2, time: '19:00' }], endDate: '2027-08-29', ...over,
});
const tutor = (busy: RegTutor['busy']): RegTutor => ({ id: 'T', name: 'Tutor', country: 'Korea', timezone: 'Asia/Seoul', availability: [], busy });
const at = (d: string, t: string, min: number) => ({ startsAt: kstToInstant(d, t), endsAt: new Date(kstToInstant(d, t).getTime() + min * 60_000) });

describe('기존 학생 간단 입력 (D-52)', () => {
  it('시작일~종료일 사이 정규 수업 + 보강, 시간순', () => {
    const ls = importLessons(base({ makeups: [{ date: '2027-08-12', time: '21:00', durationMin: 40, tutorId: 'T' }] }));
    expect(ls.filter((l) => l.kind === 'regular').map((l) => l.date)).toEqual(['2027-08-03', '2027-08-10', '2027-08-17', '2027-08-24']);
    expect(ls.find((l) => l.kind === 'makeup')?.endsAt.getTime()).toBe(kstToInstant('2027-08-12', '21:40').getTime());
  });

  it('잘못된 입력은 저장 전에 알려 줌', () => {
    expect(importProblems(base())).toEqual([]);
    expect(importProblems(base({ slots: [1, 2, 3, 4].map((w) => ({ weekday: w, time: '08:00' })) }))).toContain('주 수업 횟수는 1·2·3·5회만 가능해요 (지금 4회).');
    expect(importProblems(base({ endDate: '2027-07-01' }))).toContain('수강 종료일이 시작일보다 빨라요.');
    expect(importProblems(base({ makeups: [{ date: '2027-07-30', time: '10:00', durationMin: 20, tutorId: 'T' }] })).join()).toMatch('지난 보강은 시트에');
  });

  it('기존 학생 정규 수업과 겹치거나 휴식 10분이 안 되면 날짜마다', () => {
    const t = tutor([{ id: 'a', kind: 'regular', label: '기존A', ...at('2027-08-10', '18:00', 50) }]);
    const same = importIssues(importLessons(base({ slots: [{ weekday: 2, time: '18:30' }] })), [t]);
    expect(same).toHaveLength(1);
    expect(same[0]).toMatchObject({ reason: 'tutor_regular', other: '기존A', lesson: { date: '2027-08-10' } });
    expect(importIssues(importLessons(base({ slots: [{ weekday: 2, time: '18:55' }] })), [t])[0].reason).toBe('break');
    expect(importIssues(importLessons(base({ slots: [{ weekday: 2, time: '19:00' }] })), [t])).toEqual([]);
  });

  it('강사 휴무와 겹치면 정규·보강 모두', () => {
    const t = tutor([{ id: 'off', kind: 'time_off', label: '휴가', ...at('2027-08-17', '00:00', 24 * 60) }]);
    const issues = importIssues(importLessons(base({ makeups: [{ date: '2027-08-17', time: '10:00', durationMin: 20, tutorId: 'T' }] })), [t]);
    expect(issues.map((i) => [i.reason, i.lesson.kind])).toEqual([['tutor_time_off', 'makeup'], ['tutor_time_off', 'regular']]);
  });

  it('보강을 자기 정규 수업과 겹치게 넣으면 거절', () => {
    const issues = importIssues(importLessons(base({ makeups: [{ date: '2027-08-03', time: '19:20', durationMin: 20, tutorId: 'T2' }] })), [tutor([])]);
    expect(issues.some((i) => i.reason === 'self')).toBe(true);
  });

  it('보강은 정규 시간표(slots)에 들어가지 않음 — 저장 요청에 따로', () => {
    const p = importPayload(base({ makeups: [{ date: '2027-08-12', time: '21:00', durationMin: 50, tutorId: 'T' }] }));
    expect(p.slots).toEqual([{ weekday: 2, time: '19:00' }]);
    expect(p.makeups).toEqual([{ date: '2027-08-12', time: '21:00', duration_min: 50, tutor_id: 'T' }]);
  });
});
