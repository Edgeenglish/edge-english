import { describe, expect, it } from 'vitest';
import { parseWon, renewBlock, type RenewDraft } from './renewal';

describe('금액 칸 (대표 시험 11/11: 1.5 가 15원으로 저장됨)', () => {
  it('숫자·쉼표만 받고, 소수점·마이너스·글자는 지우지 않고 오류', () => {
    expect(parseWon('1000')).toBe(1000);
    expect(parseWon('290,000')).toBe(290000);
    expect(parseWon('')).toBe(0);
    expect(parseWon('1.5')).toBeNull();
    expect(parseWon('-100')).toBeNull();
    expect(parseWon('100원')).toBeNull();
  });
  it('재등록 저장 버튼도 막힘', () => {
    const d: RenewDraft = { weeks: 4, weekly: 1, dur: 40, prodOpen: false, slots: [{ weekday: 1, time: '15:00' }], start: '2026-11-16', manual: false,
      method: 'bank_transfer', amount: '1.5', paidOn: '2026-11-10', payer: '' };
    expect(renewBlock(d, '2026-11-15', 0, '2026-11-11')).toBe('숫자만 넣어 주세요 (소수점·− 안 됨)');
    expect(renewBlock({ ...d, amount: '290,000' }, '2026-11-15', 0, '2026-11-11')).toBe('');
  });
});
