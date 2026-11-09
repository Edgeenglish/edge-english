import { describe, expect, it } from 'vitest';
import { STATUS_RULES, tutorPaidFor } from './status';

describe('강사 급여 대상 (R-19)', () => {
  it('정규·보강은 상태 규칙 그대로 (Normal 유급, 수강생 정상 취소 무급)', () => {
    expect(tutorPaidFor('regular', 'Normal')).toBe(true);
    expect(tutorPaidFor('makeup', 'Make-up completed')).toBe(true);
    expect(tutorPaidFor('regular', 'Student canceled in advance')).toBe(false);
    expect(tutorPaidFor('regular', 'Tutor no-show')).toBe(false);
  });
  it('보상수업은 결과가 무엇이든 무급 (강사 노쇼 보상, 4000)', () => {
    for (const s of Object.keys(STATUS_RULES) as (keyof typeof STATUS_RULES)[]) expect(tutorPaidFor('compensation', s)).toBe(false);
  });
  it('기록 전(상태 없음)은 판정 없음', () => {
    expect(tutorPaidFor('regular', null)).toBeNull();
    expect(tutorPaidFor('compensation', null)).toBeNull();
  });
});
