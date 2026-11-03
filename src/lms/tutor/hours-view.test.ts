import { describe, expect, it } from 'vitest';
import { ALL_HOURS, cityTime, sourceCell } from './hours-view';

describe('My hours display zones', () => {
  it('shows every half-hour in the full day', () => {
    expect(ALL_HOURS).toHaveLength(48);
    expect(ALL_HOURS[0]).toBe('00:00');
    expect(ALL_HOURS.at(-1)).toBe('23:30');
    expect(cityTime('America/New_York')).toBe('New York time');
  });
  it('preserves tutor-local save keys', () => {
    expect(sourceCell('2026-11-02', '00:00', 'Asia/Manila', 'Asia/Manila'))
      .toEqual({ date: '2026-11-02', time: '00:00', dow: 1 });
  });
  it('moves Korean midnight into the previous local day and weekday', () => {
    expect(sourceCell('2026-11-02', '00:00', 'Asia/Seoul', 'Asia/Manila'))
      .toEqual({ date: '2026-11-01', time: '23:00', dow: 0 });
  });
  it('moves the Korean evening into the next Australian day', () => {
    expect(sourceCell('2026-11-08', '23:30', 'Asia/Seoul', 'Australia/Melbourne'))
      .toEqual({ date: '2026-11-09', time: '01:30', dow: 1 });
  });
  it('uses the tutor offset for each actual date across daylight saving', () => {
    expect(sourceCell('2026-10-31', '20:00', 'Asia/Seoul', 'America/New_York').time).toBe('07:00');
    expect(sourceCell('2026-11-02', '20:00', 'Asia/Seoul', 'America/New_York').time).toBe('06:00');
  });
});
