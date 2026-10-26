import { describe, expect, it } from 'vitest';
import { parseTimeText } from './time-text';

describe('시각 칸 숫자 입력', () => {
  it('숫자만·콜론·오전/오후', () => {
    expect(parseTimeText('1730')).toBe('17:30');
    expect(parseTimeText('930')).toBe('09:30');
    expect(parseTimeText('9')).toBe('09:00');
    expect(parseTimeText('17:30')).toBe('17:30');
    expect(parseTimeText('오후 5:30')).toBe('17:30');
    expect(parseTimeText('오후5시')).toBe('17:00');
    expect(parseTimeText('오전 12:10')).toBe('00:10');
    expect(parseTimeText('5pm')).toBe('17:00');
  });
  it('못 읽으면 null', () => {
    expect(parseTimeText('2560')).toBeNull();
    expect(parseTimeText('abc')).toBeNull();
    expect(parseTimeText('')).toBeNull();
  });
});
