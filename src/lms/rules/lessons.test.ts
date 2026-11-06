import { describe, expect, it } from 'vitest';
import { checkLessonList, type AvailabilityWindow, type Busy } from './booking';
import { baseLessons, buildLessons, lessonPayload, needsLessonList, regularDiff } from './lessons';
import { kstToInstant } from './dates';

const TT = [{ weekday: 2, time: '13:00' }, { weekday: 4, time: '13:00' }]; // 화·목
const dates = (p: ReturnType<typeof buildLessons>) => p.lessons.map((l) => `${l.date.slice(5)} ${l.time}`);

describe('등록 수업 날짜 목록', () => {
  it('첫 수업일이 정규 요일이면 정규 요일대로 8회, 기간은 그날부터 28일', () => {
    const p = buildLessons({ firstDate: '2026-11-10', weeks: 4, weeklyCount: 2, slots: TT });
    expect(dates(p)).toEqual(['11-10 13:00', '11-12 13:00', '11-17 13:00', '11-19 13:00', '11-24 13:00', '11-26 13:00', '12-01 13:00', '12-03 13:00']);
    expect([p.startDate, p.endDate, p.extraFirst, p.problems]).toEqual(['2026-11-10', '2026-12-07', false, []]);
    expect(needsLessonList(p)).toBe(false);
  });
  it('첫 수업일이 정규 요일이 아니면 그날이 1회, 총 8회 유지(마지막 정규 1회 줄어듦), 시각은 다음 정규 수업 시각', () => {
    const p = buildLessons({ firstDate: '2026-11-06', weeks: 4, weeklyCount: 2, slots: TT });
    expect(dates(p)).toEqual(['11-06 13:00', '11-10 13:00', '11-12 13:00', '11-17 13:00', '11-19 13:00', '11-24 13:00', '11-26 13:00', '12-01 13:00']);
    expect([p.startDate, p.endDate, p.extraFirst, p.problems]).toEqual(['2026-11-06', '2026-12-03', true, []]);
    expect(needsLessonList(p)).toBe(true);
  });
  it('특정 회차만 바꾸면 날짜순으로 다시 번호가 붙고 원래 날짜를 기억함', () => {
    const p = buildLessons({ firstDate: '2026-11-10', weeks: 4, weeklyCount: 2, slots: TT, edits: { '2026-11-12': { date: '2026-11-13', time: '13:00' }, '2026-11-24': { date: '2026-11-23', time: '19:30' } } });
    expect(dates(p).slice(0, 7)).toEqual(['11-10 13:00', '11-13 13:00', '11-17 13:00', '11-19 13:00', '11-23 19:30', '11-26 13:00', '12-01 13:00']);
    expect(p.lessons[1].original).toEqual({ date: '2026-11-12', time: '13:00' });
    expect(p.lessons[4].original).toEqual({ date: '2026-11-24', time: '13:00' });
    expect(p.lessons[0].original).toBeNull();
    expect(needsLessonList(p)).toBe(true);
    expect(lessonPayload(p)[4]).toEqual({ date: '2026-11-23', time: '19:30' });
  });
  it('첫 회차를 더 앞으로 옮기면 수강 기간 시작도 따라 옮겨짐 (실제 첫 수업일 기준)', () => {
    const p = buildLessons({ firstDate: '2026-11-10', weeks: 4, weeklyCount: 2, slots: TT, edits: { '2026-11-10': { date: '2026-11-09', time: '13:00' } } });
    expect([p.startDate, p.endDate, p.problems]).toEqual(['2026-11-09', '2026-12-06', []]);
  });
  it('기간 밖·같은 날 겹침은 문제로 알려 줌', () => {
    const out = buildLessons({ firstDate: '2026-11-06', weeks: 4, weeklyCount: 2, slots: TT, edits: { '2026-12-01': { date: '2026-12-04', time: '13:00' } } });
    expect(out.problems).toEqual(['12/4는 수강 기간(~12/3) 밖이에요']);
    const dup = buildLessons({ firstDate: '2026-11-10', weeks: 4, weeklyCount: 2, slots: TT, edits: { '2026-11-12': { date: '2026-11-17', time: '19:00' } } });
    expect(dup.problems).toEqual(['11/17에 수업이 2개예요']);
  });
  it('정규 시간이 없으면 목록을 만들지 않음, 12주 주 1회는 12회', () => {
    expect(buildLessons({ firstDate: '2026-11-10', weeks: 4, weeklyCount: 2, slots: [] }).lessons).toEqual([]);
    expect(baseLessons('2026-11-10', 12, [{ weekday: 2, time: '20:00' }]).list).toHaveLength(12);
  });
});

describe('정규 요일과 다른 날 (안내문용)', () => {
  it('첫 수업 금요일 + 3회차 목→금: 다른 날 2개, 수업 없는 정규일 2개(11/12, 12/3)', () => {
    const p = buildLessons({ firstDate: '2026-11-06', weeks: 4, weeklyCount: 2, slots: TT, edits: { '2026-11-12': { date: '2026-11-13', time: '13:00' } } });
    const d = regularDiff(lessonPayload(p), TT, p.startDate!, p.endDate!);
    expect(d.added.map((x) => x.date)).toEqual(['2026-11-06', '2026-11-13']);
    expect(d.removed.map((x) => x.date)).toEqual(['2026-11-12', '2026-12-03']);
  });
  it('정규대로면 다른 날 없음', () => {
    const p = buildLessons({ firstDate: '2026-11-10', weeks: 4, weeklyCount: 2, slots: TT });
    expect(regularDiff(lessonPayload(p), TT, p.startDate!, p.endDate!)).toEqual({ added: [], removed: [] });
  });
});

describe('회차 목록 충돌 검사 (정규 검사와 같은 규칙)', () => {
  const seoul: AvailabilityWindow[] = [1, 2, 3, 4, 5].map((weekday) => ({ weekday, startLocal: '09:00', endLocal: '22:00', timezone: 'Asia/Seoul', effectiveFrom: '2026-01-01', effectiveTo: null }));
  const busy = (date: string, time: string, min: number, kind: Busy['kind'] = 'regular'): Busy => ({ id: date + time, startsAt: kstToInstant(date, time), endsAt: new Date(kstToInstant(date, time).getTime() + min * 60000), kind });
  it('바꾼 날짜가 다른 수업과 겹치거나 가능 시간 밖이면 그 회차만 알려 줌', () => {
    const issues = checkLessonList({
      lessons: [{ date: '2026-11-06', time: '13:00' }, { date: '2026-11-13', time: '13:00' }, { date: '2026-11-17', time: '23:00' }],
      durationMin: 50, tutorBusy: [busy('2026-11-13', '13:30', 50)], availability: seoul,
    });
    expect(issues.map((i) => `${i.seq}:${i.reason}`)).toEqual(['2:tutor_regular', '3:outside_availability']);
  });
  it('휴식 10분 규칙도 그대로', () => {
    const ok = checkLessonList({ lessons: [{ date: '2026-11-13', time: '14:00' }], durationMin: 50, tutorBusy: [busy('2026-11-13', '13:00', 50)], availability: seoul });
    expect(ok).toEqual([]);
    const tight = checkLessonList({ lessons: [{ date: '2026-11-13', time: '13:55' }], durationMin: 50, tutorBusy: [busy('2026-11-13', '13:00', 50)], availability: seoul });
    expect(tight.map((i) => i.reason)).toEqual(['break']);
  });
});
