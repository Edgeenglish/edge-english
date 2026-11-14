import { describe, expect, it } from 'vitest';
import { groupDays, homeText, returnText, searchCity, tabLabel, zoneAt, zoneBadge, zoneOn, type TravelPeriod } from './travel';
import { cellKind, type ScheduleData } from './schedule';
import { daysOf, rangeFull, type TutorLesson } from './screen';

const ba: TravelPeriod = { id: 'l1', city: 'Buenos Aires', country: 'Argentina', timezone: 'America/Argentina/Buenos_Aires', from: '2027-01-05', to: '2027-03-23' };

describe('강사 해외 이동 기간 (H26(173))', () => {
  it('탭 이름·복귀 문구 (대표 확정)', () => {
    expect(tabLabel(ba)).toBe('Buenos Aires · 5 Jan – 23 Mar');
    expect(tabLabel({ ...ba, to: null })).toBe('Buenos Aires · from 5 Jan');
    expect(returnText('2027-03-23')).toBe('Regular hours apply again from Wed, 24 Mar');
    expect(homeText('Australia', 'Australia/Sydney')).toBe('Australia · Sydney');
  });
  it('시간대 약자는 그날 서머타임 반영, 약자 없으면 UTC', () => {
    expect(zoneBadge('Australia/Sydney', '2027-01-10')).toBe('AEDT');
    expect(zoneBadge('Australia/Sydney', '2027-07-10')).toBe('AEST');
    expect(zoneBadge('America/Argentina/Buenos_Aires', '2027-01-10')).toBe('UTC-3');
  });
  it('날짜·시각별 시간대: 기간 안이면 이동 지역, 종료일 다음 날부터 평소', () => {
    expect(zoneOn([ba], '2027-01-04', 'Australia/Sydney')).toBe('Australia/Sydney');
    expect(zoneOn([ba], '2027-01-05', 'Australia/Sydney')).toBe('America/Argentina/Buenos_Aires');
    expect(zoneOn([ba], '2027-03-24', 'Australia/Sydney')).toBe('Australia/Sydney');
    // BA 1/5 00:00 = UTC 03:00 → 이동 기간 / BA 1/4 23:00 → 평소
    expect(zoneAt([ba], new Date('2027-01-05T03:00:00Z'), 'Australia/Sydney')).toBe('America/Argentina/Buenos_Aires');
    expect(zoneAt([ba], new Date('2027-01-05T02:00:00Z'), 'Australia/Sydney')).toBe('Australia/Sydney');
  });
  it('여러 날 등록: 두 지역에 걸치면 둘로 나눔', () => {
    const g = groupDays([ba], '2027-01-04', '2027-01-07', 'Australia/Sydney');
    expect(g.map((x) => [x.timezone, x.from, x.to])).toEqual([
      ['Australia/Sydney', '2027-01-04', '2027-01-04'],
      ['America/Argentina/Buenos_Aires', '2027-01-05', '2027-01-07'],
    ]);
    expect(groupDays([ba], '2027-01-20', '2027-01-22', 'Australia/Sydney')).toHaveLength(1);
  });
  it('도시 검색: 영어·나라 이름·악센트 없이, 고르면 시간대 자동', () => {
    expect(searchCity('buenos')[0]).toEqual({ city: 'Buenos Aires', country: 'Argentina', timezone: 'America/Argentina/Buenos_Aires' });
    expect(searchCity('cordoba')[0]?.city).toBe('Córdoba');
    expect(searchCity('argentina').length).toBeGreaterThanOrEqual(3);
    expect(searchCity('los angeles')[0]?.city).toBe('Los Angeles');
    expect(searchCity('zzzz')).toEqual([]);
  });
  it('Calendar 칸: DB 가 준 n = 시작 못 함 (이동 기간은 강사 시간대 06~22:30 과 다름)', () => {
    const d: ScheduleData = { tutor: { id: 't', name: 'Ben', timezone: 'Australia/Sydney', country: 'Australia' }, locations: [ba], today: '2027-01-01', last: '2027-03-26',
      times: ['06:00', '22:30'], cells: { '2027-01-10T06:00': 'n' }, blocks: [], opens: [] };
    expect(cellKind('2027-01-10T06:00', d, false)).toBe('outside');
    expect(cellKind('2027-01-10T23:00', d, false)).toBe('free');   // Sydney 23:00 = BA 09:00 → 열림
  });
  it('강사 Home: 수업 날짜에 설정된 지역 시간으로 (지금 있는 곳 아님, H26(175))', () => {
    // BA 1/6 오후 4시 수업 = UTC 19:00. Sydney 로는 1/7 오전 6시
    const l = { id: 'x', startsAt: new Date('2027-01-06T19:00:00Z'), endsAt: new Date('2027-01-06T19:40:00Z') } as TutorLesson;
    const z = (t: Date) => zoneAt([ba], t, 'Australia/Sydney');
    expect(rangeFull(l, z(l.startsAt))).toContain('Wed, 6 Jan 4:00–4:40 PM *Buenos Aires Time*');
    expect(daysOf([l], z, { from: '2027-01-04', to: '2027-01-10' }).map((d) => d.date)).toEqual(['2027-01-06']);
    expect(daysOf([l], 'Australia/Sydney', { from: '2027-01-04', to: '2027-01-10' }).map((d) => d.date)).toEqual(['2027-01-07']);
  });
});
