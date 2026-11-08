import { describe, expect, it } from 'vitest';
import { kstToInstant } from '../rules/dates';
import { bold, enBoth, enRangeBoth, koBoth, stripBold } from './time-text';

describe('시각 글 통일 (대표 2026-11-08)', () => {
  const at = kstToInstant('2026-11-09', '20:00'); // 한국 20:00 = 호치민 18:00
  it('영어: 시각 바로 뒤 기준 이름, 호치민 먼저 ' + ' / ' + ' 한국', () => {
    expect(enBoth(at, 'Asia/Ho_Chi_Minh')).toBe('Mon, 9 Nov 6:00 PM *Ho Chi Minh Time* / 8:00 PM *KST*');
  });
  it('영어: 날짜가 다르면 한국 쪽에 날짜까지', () => {
    expect(enBoth(kstToInstant('2026-11-10', '01:30'), 'America/Toronto')).toBe('Mon, 9 Nov 11:30 AM *Toronto Time* / Tue, 10 Nov 1:30 AM *KST*');
  });
  it('영어: 한국 강사는 KST 하나', () => {
    expect(enBoth(at, 'Asia/Seoul')).toBe('Mon, 9 Nov 8:00 PM *KST*');
  });
  it('영어: 시각 범위', () => {
    expect(enRangeBoth(at, new Date(+at + 50 * 60000), 'Australia/Sydney')).toBe('Mon, 9 Nov 10:00–10:50 PM *Sydney Time* / 8:00–8:50 PM *KST*');
  });
  it('한국어: 해외는 대괄호 두 개, 한국 거주는 하나', () => {
    expect(koBoth(at, 'Asia/Ho_Chi_Minh')).toBe('11월 9일(월) 오후 6시 [호찌민 시간] / 오후 8시 [한국 시간]');
    expect(koBoth(at, 'Asia/Seoul')).toBe('11월 9일(월) 오후 8시 [한국 시간]');
  });
  it('굵게 안 되는 곳은 별표를 뺌', () => {
    expect(stripBold(bold('KST'))).toBe('KST');
    expect(stripBold(enBoth(at, 'Asia/Ho_Chi_Minh'))).toBe('Mon, 9 Nov 6:00 PM Ho Chi Minh Time / 8:00 PM KST');
  });
});
