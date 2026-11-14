import { describe, expect, it } from 'vitest';
import { groupDays, homeText, returnText, searchCity, tabLabel, zoneAt, zoneBadge, zoneOn, type TravelPeriod } from './travel';
import { cellKind, keyOf, type ScheduleData } from './schedule';
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
  it('Calendar 칸: 키 = 실제 시각(UTC). DB 가 준 칸만 시작 가능, 없는 키·n = 시작 못 함 (재검증 11/14)', () => {
    const d: ScheduleData = { tutor: { id: 't', name: 'Ben', timezone: 'Australia/Sydney', country: 'Australia' }, locations: [ba], today: '2027-01-01', last: '2027-03-26',
      times: ['06:00', '22:30'], cells: { '2027-01-10T12:00Z': 'o', '2027-01-10T13:00Z': 's', '2027-01-10T14:00Z': 'n' }, blocks: [], opens: [] };
    expect(cellKind('2027-01-10T12:00Z', d, false, '2027-01-10')).toBe('free');
    expect(cellKind('2027-01-10T13:00Z', d, false, '2027-01-10')).toBe('closed');
    expect(cellKind('2027-01-10T14:00Z', d, false, '2027-01-10')).toBe('outside');
    expect(cellKind('2027-01-10T15:00Z', d, false, '2027-01-10')).toBe('outside');
    expect(cellKind('2027-01-10T12:00Z', d, false, '2026-12-31')).toBe('past');
  });
  it('QA①: Sydney 서머타임 끝나는 날에도 BA 12:30·13:30 은 서로 다른 키 (현지·한국 시간 보기 같은 키)', () => {
    const a = keyOf('2027-04-03', '12:30', 'America/Argentina/Buenos_Aires');
    const b = keyOf('2027-04-03', '13:30', 'America/Argentina/Buenos_Aires');
    expect(a).toBe('2027-04-03T15:30Z');
    expect(b).toBe('2027-04-03T16:30Z');
    expect(keyOf('2027-04-04', '01:30', 'Asia/Seoul')).toBe(b);
  });
  it('재검증①: 출발일 경계 — 한국 12/4 07:00 = Sydney 12/4 09:00 은 Sydney 보기와 같은 키', () => {
    expect(keyOf('2026-12-04', '07:00', 'Asia/Seoul')).toBe(keyOf('2026-12-04', '09:00', 'Australia/Sydney'));
  });
  it('강사 Home: 수업 날짜에 설정된 지역 시간으로 (지금 있는 곳 아님, H26(176))', () => {
    // BA 1/6 오후 4시 수업 = UTC 19:00. Sydney 로는 1/7 오전 6시
    const l = { id: 'x', startsAt: new Date('2027-01-06T19:00:00Z'), endsAt: new Date('2027-01-06T19:40:00Z') } as TutorLesson;
    const z = (t: Date) => zoneAt([ba], t, 'Australia/Sydney');
    expect(rangeFull(l, z(l.startsAt))).toContain('Wed, 6 Jan 4:00–4:40 PM *Buenos Aires Time*');
    expect(daysOf([l], z, { from: '2027-01-04', to: '2027-01-10' }).map((d) => d.date)).toEqual(['2027-01-06']);
    expect(daysOf([l], 'Australia/Sydney', { from: '2027-01-04', to: '2027-01-10' }).map((d) => d.date)).toEqual(['2027-01-07']);
  });
});
