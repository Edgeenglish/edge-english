import { describe, expect, it } from 'vitest';
import { kstToInstant } from '../rules/dates';
import { diffFromKst, localTime, upcomingOffsetChange, utcOffsetMinutes, weekOf } from './schedule';

describe('주간 시간표', () => {
  it('월~일', () => {
    expect(weekOf('2026-10-18')).toEqual(['2026-10-12', '2026-10-13', '2026-10-14', '2026-10-15', '2026-10-16', '2026-10-17', '2026-10-18']);
    expect(weekOf('2026-10-19')[0]).toBe('2026-10-19');
  });
});

describe('강사 현지 시간 (서머타임 자동)', () => {
  const kst20 = kstToInstant('2026-10-20', '20:00');
  it('시드니는 10월 초부터 서머타임(+11) → 한국보다 2시간 빠름', () => {
    expect(utcOffsetMinutes(kst20, 'Australia/Sydney')).toBe(660);
    expect(localTime(kst20, 'Australia/Sydney')).toBe('22:00');
    expect(diffFromKst(kst20, 'Australia/Sydney')).toBe('한국보다 2시간 빠름');
  });
  it('토론토 한국 20:00 = 현지 같은 날 07:00, 11/1 서머타임 끝나면 06:00', () => {
    expect(localTime(kst20, 'America/Toronto')).toBe('07:00');
    expect(localTime(kstToInstant('2026-11-03', '20:00'), 'America/Toronto')).toBe('06:00');
  });
  it('날짜가 바뀌면 표시', () => {
    expect(localTime(kstToInstant('2026-10-20', '08:00'), 'America/Toronto')).toBe('19:00 (전날)');
  });
  it('2주 안의 서머타임 변경을 미리 알려 줌', () => {
    const c = upcomingOffsetChange(kstToInstant('2026-10-19', '00:00'), 'Europe/London');
    expect(c).toMatchObject({ on: '2026-10-25', label: '서머타임 끝', from: 'UTC+1', to: 'UTC+0' });
    expect(upcomingOffsetChange(kstToInstant('2026-10-19', '00:00'), 'Asia/Seoul')).toBeNull();
  });
});
