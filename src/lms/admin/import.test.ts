import { describe, expect, it } from 'vitest';
import { kstToInstant } from '../rules/dates';
import { autoEndDate, emptyImport, withAutoEnd, importCount, importIssues, importLessons, importPayload, importPeriods, importProblems, importWarnings, type ImportDraft, type ImportMakeup } from './import';
import type { RegTutor } from './registration';

// 2027-08-02(월) ~ 2027-08-29(일)
const base = (over: Partial<ImportDraft> = {}): ImportDraft => ({
  ...emptyImport('2027-08-02'),
  nameKo: '이관', nameEn: 'Import', tutorId: 'T', durationMin: 50,
  slots: [{ weekday: 2, time: '19:00' }], endDate: '2027-08-29',
  weeks: 4, periodIdx: 1, periodStart: '2027-08-02', creditsLeft: 1, sheetTotal: 4, sheetUsed: 0, ...over,
});
const mk = (date: string, time: string, durationMin: number, tutorId: string, more: Partial<ImportMakeup> = {}): ImportMakeup => ({
  status: 'booked', originalDate: '', originUnknown: true, date, time, durationMin, tutorId, ...more,
});
const tutor = (busy: RegTutor['busy']): RegTutor => ({ id: 'T', name: 'Tutor', country: 'Korea', timezone: 'Asia/Seoul', availability: [], busy });
const at = (d: string, t: string, min: number) => ({ startsAt: kstToInstant(d, t), endsAt: new Date(kstToInstant(d, t).getTime() + min * 60_000) });

describe('기존 학생 간단 입력 (D-52)', () => {
  it('시작일~종료일 사이 정규 수업 + 보강, 시간순', () => {
    const ls = importLessons(base({ makeups: [mk('2027-08-12', '21:00', 40, 'T')] }));
    expect(ls.filter((l) => l.kind === 'regular').map((l) => l.date)).toEqual(['2027-08-03', '2027-08-10', '2027-08-17', '2027-08-24']);
    expect(ls.find((l) => l.kind === 'makeup')?.endsAt.getTime()).toBe(kstToInstant('2027-08-12', '21:40').getTime());
  });

  it('잘못된 입력은 저장 전에 알려 줌', () => {
    expect(importProblems(base())).toEqual([]);
    expect(importProblems(base({ slots: [1, 2, 3, 4].map((w) => ({ weekday: w, time: '08:00' })) }))).toContain('주 수업 횟수는 1·2·3·5회만 가능해요 (지금 4회).');
    expect(importProblems(base({ endDate: '2027-07-01' }))).toContain('수강 종료일이 시작일보다 빨라요.');
    expect(importProblems(base({ makeups: [mk('2027-07-30', '10:00', 20, 'T')] })).join()).toMatch('지난 보강은 시트에');
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
    const issues = importIssues(importLessons(base({ makeups: [mk('2027-08-17', '10:00', 20, 'T')] })), [t]);
    expect(issues.map((i) => [i.reason, i.lesson.kind])).toEqual([['tutor_time_off', 'makeup'], ['tutor_time_off', 'regular']]);
  });

  it('보강을 자기 정규 수업과 겹치게 넣으면 거절', () => {
    const issues = importIssues(importLessons(base({ makeups: [mk('2027-08-03', '19:20', 20, 'T2')] })), [tutor([])]);
    expect(issues.some((i) => i.reason === 'self')).toBe(true);
  });

  it('보강은 정규 시간표(slots)에 들어가지 않음 — 저장 요청에 따로', () => {
    const p = importPayload(base({ makeups: [mk('2027-08-12', '21:00', 50, 'T')] }));
    expect(p.slots).toEqual([{ weekday: 2, time: '19:00' }]);
    expect(p.makeups).toEqual([{ status: 'booked', origin_unknown: true, date: '2027-08-12', time: '21:00', duration_min: 50, tutor_id: 'T' }]);
  });
});

describe('기존 학생 입력 확대판 (D-52 · H26, 2026-10-24 대표 결정)', () => {
  // 화 19:00 정규 4회 (8/3·10·17·24)
  it('남은 수업 = 정규 + 예약 보강 + 미예약 보강 + 추가, 보강의 원래 수업 날짜는 정규에서 빠짐 (두 번 세지 않음)', () => {
    const d = base({
      makeups: [mk('2027-08-13', '19:00', 50, 'T', { originalDate: '2027-07-27', originUnknown: false }), { ...mk('', '', 50, 'T', { originalDate: '2027-08-10', originUnknown: false }), status: 'open' }],
      extras: [{ date: '2027-08-27', time: '19:00', reason: '시트 이월 1회' }],
      sheetTotal: 24, sheetUsed: 19,
    });
    expect(importLessons(d).filter((l) => l.kind === 'regular').map((l) => l.date)).toEqual(['2027-08-03', '2027-08-17', '2027-08-24']);
    expect(importCount(d)).toMatchObject({ regular: 3, origin: 1, booked: 1, open: 1, extra: 1, lmsLeft: 6, sheetLeft: 5, diff: 1 });
    expect(importProblems(d)).toEqual([]);
  });

  it('시트보다 많으면 운영진이 뺀 날짜는 만들지 않고 저장 요청에도 그 날짜만', () => {
    const d = base({ sheetTotal: 3, sheetUsed: 0, skipDates: ['2027-08-24', '2027-09-30'] });
    expect(importCount(d)).toMatchObject({ regular: 3, skipped: 1, diff: 0 });
    expect(importPayload(d).skip_dates).toEqual(['2027-08-24']);
  });

  it('원래 수업 날짜가 없으면 날짜 확인 필요를 골라야 함, 추가 수업은 근거 필수, 같은 원래 날짜 보강 두 개 금지', () => {
    const open = (o: Partial<ImportMakeup>): ImportMakeup => ({ ...mk('', '', 50, 'T'), status: 'open', originUnknown: false, ...o });
    expect(importProblems(base({ makeups: [open({})] })).join()).toMatch('날짜 확인 필요');
    expect(importProblems(base({ makeups: [open({ originUnknown: true })] }))).toEqual([]);
    expect(importPayload(base({ makeups: [open({ originUnknown: true })] })).makeups).toEqual([{ status: 'open', origin_unknown: true }]);
    expect(importProblems(base({ extras: [{ date: '2027-08-27', time: '19:00', reason: ' ' }] })).join()).toMatch('근거');
    expect(importProblems(base({ makeups: [open({ originalDate: '2027-07-20' }), open({ originalDate: '2027-07-20' })] })).join()).toMatch('두 개');
  });

  it('지금 기간은 남은 변경권, 다음 기간부터 주 횟수대로 새로 지급 (28일씩)', () => {
    const d = base({ slots: [{ weekday: 2, time: '19:00' }, { weekday: 4, time: '19:00' }], weeks: 12, periodIdx: 2, periodStart: '2027-07-13', creditsLeft: 0, endDate: '2027-09-06' });
    expect(importPeriods(d).map((p) => [p.index, p.start, p.end, p.state, p.credits])).toEqual([
      [1, '2027-06-15', '2027-07-12', 'past', 2],
      [2, '2027-07-13', '2027-08-09', 'now', 0],
      [3, '2027-08-10', '2027-09-06', 'next', 2],
    ]);
    expect(importWarnings(d).endDate).toBeUndefined();
    expect(importWarnings({ ...d, endDate: '2027-09-10' }).endDate).toMatch('4일 달라요');
    expect(importWarnings({ ...d, periodStart: '2027-08-10' }).period).toMatch('밖이에요');
  });
});

describe('종료일 자동 · 기간 시작일 요일 (2026-10-25 대표)', () => {
  const d = base({ weeks: 12, periodIdx: 1, periodStart: '2026-10-27', fromDate: '2026-10-25', endDate: '', slots: [{ weekday: 2, time: '19:00' }] });
  it('4번을 다 넣으면 마지막 28일 기간 끝이 종료일로, 직접 고친 종료일은 그대로', () => {
    expect(autoEndDate(d)).toBe('2027-01-18');
    expect(withAutoEnd({ ...d, periodStart: '' }, d).endDate).toBe('2027-01-18');
    const edited = { ...d, endDate: '2027-01-25' };
    expect(withAutoEnd(edited, { ...edited, periodIdx: 2 }).endDate).toBe('2027-01-25');
  });
  it('기간 시작일이 수업 요일이 아니면 알려 줌', () => {
    expect(importWarnings(d).periodDay).toBeUndefined();
    expect(importWarnings({ ...d, periodStart: '2026-10-25' }).periodDay).toMatch('수업 요일(화)이 아니에요');
  });
});
