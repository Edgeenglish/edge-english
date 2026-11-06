import { describe, expect, it } from 'vitest';
import { isKstDate } from './dates';

// 브라우저 날짜 칸이 연도를 치는 중에 주는 중간값은 날짜로 받지 않음 (QA A-02)
describe('isKstDate', () => {
  it('완성된 실제 날짜만 참', () => {
    expect(isKstDate('2026-11-18')).toBe(true);
    expect(isKstDate('2026-02-28')).toBe(true);
    expect(isKstDate('2099-12-31')).toBe(true);
  });
  it('연도 치는 중·없는 날·형식 오류·빈 값은 거짓', () => {
    expect(isKstDate('0002-11-20')).toBe(false);
    expect(isKstDate('0202-11-20')).toBe(false);
    expect(isKstDate('2026-02-30')).toBe(false);
    expect(isKstDate('2026-13-01')).toBe(false);
    expect(isKstDate('26-11-18')).toBe(false);
    expect(isKstDate('')).toBe(false);
    expect(isKstDate('2026-11-18T00:00')).toBe(false);
  });
});
