// 정책 원본 v1.0 (2026-10-16 대표확정) 규칙 테스트 — 가짜 데이터만 사용
// 실행: npm test

import { describe, expect, it } from 'vitest';
import { addBusinessDays, addDays, kstToInstant } from './dates';
import { canCarryOver, isFixedSlotHeld } from './period';
import { compensationDeadline, isCompensationSlotAllowed, tutorCancelOutcome } from './change';
import { evaluateLongLeaveRequest, suggestDatesAfterEnd, tutorLeaveExtensionDays, type LongLeaveInput } from './leave';
import { RewardLedger } from './rewards';

const H = 60 * 60 * 1000;

describe('이월: 종료일 23:59 KST까지 실제 결제 완료 (A01·A02)', () => {
  it('종료일 23:59 결제는 이월, 다음 날 00:00 결제는 이월 불가', () => {
    expect(canCarryOver(kstToInstant('2026-11-26', '23:59'), '2026-11-26')).toBe(true);
    expect(canCarryOver(kstToInstant('2026-11-27', '00:00'), '2026-11-26')).toBe(false);
  });
  it('해외에서 결제해도 한국 시간 기준 (시드니 11/27 01:30 = KST 11/26 23:30 → 이월)', () => {
    // 2026-11-26 서머타임 중 시드니 UTC+11 → KST(UTC+9)보다 2시간 빠름
    expect(canCarryOver(new Date('2026-11-26T14:30:00Z'), '2026-11-26')).toBe(true);
  });
});

describe('고정 요일·시간 유지 (POL-RN-02: 종료일 23:59 KST까지 결제)', () => {
  it('종료일 23:59 결제는 유지, 다음 날 00:00 결제·미결제는 유지 안 함', () => {
    expect(isFixedSlotHeld(kstToInstant('2026-11-26', '23:59'), '2026-11-26')).toBe(true);
    expect(isFixedSlotHeld(kstToInstant('2026-11-26', '11:59'), '2026-11-26')).toBe(true);
    expect(isFixedSlotHeld(kstToInstant('2026-11-27', '00:00'), '2026-11-26')).toBe(false);
    expect(isFixedSlotHeld(null, '2026-11-26')).toBe(false);
  });
});

describe('강사 사유 취소 (A15·A16)', () => {
  const startsAt = kstToInstant('2026-11-03', '20:00');
  it('6시간 이상 전: 보강만, 적립금 없음, 변경권 차감 없음', () => {
    expect(tutorCancelOutcome(new Date(startsAt.getTime() - 6 * H), startsAt)).toEqual({
      status: 'Tutor canceled in advance', makeupRequired: true, usesCredit: false, rewardWon: 0,
    });
  });
  it('6시간 미만: 보강 + 적립금 2,000원', () => {
    expect(tutorCancelOutcome(new Date(startsAt.getTime() - 6 * H + 60_000), startsAt)).toMatchObject({
      status: 'Tutor canceled late', rewardWon: 2000, usesCredit: false,
    });
  });
  it('학생에게 유리한 규칙이라 기존 학생에게도 같은 금액 (POL-OP-17)', () => {
    expect(tutorCancelOutcome(new Date(startsAt.getTime() - H), startsAt).rewardWon).toBe(2000);
  });
});

describe('강사 노쇼 무료 보상 수업 기한 (A14: 지급일부터 7일 안에 수업 완료)', () => {
  const grantedAt = kstToInstant('2026-11-03', '15:00');
  it('11/3 지급 → 11/10 23:59(KST)까지', () => {
    expect(compensationDeadline(grantedAt).getTime()).toBe(kstToInstant('2026-11-11', '00:00').getTime() - 1);
  });
  it('기한 안에 끝나는 수업만 가능 (예약만 기한 안이고 끝나는 시각이 넘으면 불가)', () => {
    const now = kstToInstant('2026-11-04', '10:00');
    expect(isCompensationSlotAllowed({ startsAt: kstToInstant('2026-11-10', '23:00'), endsAt: kstToInstant('2026-11-10', '23:50') }, grantedAt, now)).toBe(true);
    expect(isCompensationSlotAllowed({ startsAt: kstToInstant('2026-11-10', '23:30'), endsAt: kstToInstant('2026-11-11', '00:20') }, grantedAt, now)).toBe(false);
  });
});

describe('강사 장기 휴무 연장 (A19·A20: 마지막 실제 보강 수업일까지만)', () => {
  it('화·목 학생: 종료일(11/26 목) 뒤 화·목 날짜를 제안', () => {
    expect(suggestDatesAfterEnd('2026-11-26', [2, 4], 3)).toEqual(['2026-12-01', '2026-12-03', '2026-12-08']);
  });
  it('강사가 못 하는 날은 건너뜀', () => {
    expect(suggestDatesAfterEnd('2026-11-26', [2, 4], 2, new Set(['2026-12-01']))).toEqual(['2026-12-03', '2026-12-08']);
  });
  it('연장 일수 = 종료일부터 마지막 보강일까지 (기간 안 보강은 연장 없음)', () => {
    expect(tutorLeaveExtensionDays('2026-11-26', ['2026-11-20', '2026-12-03'])).toBe(7);
    expect(tutorLeaveExtensionDays('2026-11-26', ['2026-11-20', '2026-11-24'])).toBe(0);
  });
});

describe('학생 장기 연기 신청 (A09~A12)', () => {
  const base: LongLeaveInput = {
    basis: 'policy_v1',
    weeks: 24,
    enrollmentStart: '2026-09-01',
    finalEnd: '2027-02-15',
    leaveStart: '2026-11-20',
    days: 14,
    reason: 'health',
    now: kstToInstant('2026-11-16', '23:59'),
    earlier: [],
  };
  it('24주 · 특별 사유 · 시작 4일 전 → 운영자 승인 대기 (증빙 필요)', () => {
    expect(evaluateLongLeaveRequest(base)).toMatchObject({ ok: true, status: 'pending_admin_approval', from: '2026-11-20', to: '2026-12-03', needsEvidence: true });
  });
  it('시작 4일 전 날이 지나면 시스템이 막음 (11/17 00:00 신청 → 11/20 시작 불가)', () => {
    expect(evaluateLongLeaveRequest({ ...base, now: kstToInstant('2026-11-17', '00:00') })).toMatchObject({ ok: false, reason: 'too_late' });
  });
  it('4주·12주는 불가 (12주 1주 안은 철회)', () => {
    expect(evaluateLongLeaveRequest({ ...base, weeks: 12 })).toMatchObject({ ok: false, reason: 'not_24_weeks' });
    expect(evaluateLongLeaveRequest({ ...base, weeks: 4 })).toMatchObject({ ok: false, reason: 'not_24_weeks' });
  });
  it('임의 개인 사정은 불가', () => {
    expect(evaluateLongLeaveRequest({ ...base, reason: 'personal' })).toMatchObject({ ok: false, reason: 'reason_not_eligible' });
  });
  it('7일씩 2회 분할 가능, 총 14일·2회 초과 불가', () => {
    expect(evaluateLongLeaveRequest({ ...base, days: 7, earlier: [{ days: 7 }] })).toMatchObject({ ok: true });
    expect(evaluateLongLeaveRequest({ ...base, days: 7, earlier: [{ days: 14 }] })).toMatchObject({ ok: false, reason: 'limit_exceeded' });
    expect(evaluateLongLeaveRequest({ ...base, days: 7, earlier: [{ days: 7 }, { days: 7 }] })).toMatchObject({ ok: false, reason: 'limit_exceeded' });
  });
  it('7일 단위가 아니면 불가', () => {
    expect(evaluateLongLeaveRequest({ ...base, days: 10 })).toMatchObject({ ok: false, reason: 'invalid_days' });
  });
  it('수강기간 밖 시작일은 불가', () => {
    expect(evaluateLongLeaveRequest({ ...base, leaveStart: '2027-02-20', now: kstToInstant('2027-02-01', '10:00') })).toMatchObject({ ok: false, reason: 'outside_enrollment' });
  });
  it('기존 등록(예전 계약·안내서)은 자동 판정하지 않고 운영자 확인 (소급 금지)', () => {
    expect(evaluateLongLeaveRequest({ ...base, basis: 'legacy' })).toMatchObject({ ok: false, reason: 'manual_review' });
  });
});

describe('영업일 계산 (신규 매칭 3영업일, POL-OP-13)', () => {
  it('금요일 결제 확인 → 다음 주 수요일', () => {
    expect(addBusinessDays('2026-10-16', 3, new Set())).toBe('2026-10-21');
  });
  it('공휴일은 빼고 셈 (2026-10-09 한글날)', () => {
    expect(addBusinessDays('2026-10-07', 3, new Set(['2026-10-09']))).toBe('2026-10-13');
  });
});

describe('보상 적립금 장부 (POL-PAY-09)', () => {
  it('같은 강사 늦은 취소 수업에는 한 번만 지급', () => {
    const l = new RewardLedger();
    expect(l.grantForTutorLateCancel('lesson-1', 2000)).toBe(true);
    expect(l.grantForTutorLateCancel('lesson-1', 2000)).toBe(false);
    expect(l.balance()).toBe(2000);
  });
  it('예약하면 잔액에서 빠지고, 결제 확인 후 확정 · 미결제면 복구', () => {
    const l = new RewardLedger();
    l.grantForTutorLateCancel('lesson-1', 2000);
    l.grantForTutorLateCancel('lesson-2', 2000);
    l.hold('use-1', 4000);
    expect(l.balance()).toBe(0);
    expect(() => l.hold('use-2', 1000)).toThrow('잔액이 부족');
    l.release('use-1');
    expect(l.balance()).toBe(4000);
    l.hold('use-3', 2000);
    l.confirm('use-3', 'order-A');
    expect(l.balance()).toBe(2000);
  });
  it('이중 처리 방지: 같은 요청 두 번 예약·확정 불가, 같은 결제에 두 번 적용 불가', () => {
    const l = new RewardLedger();
    l.grantForTutorLateCancel('lesson-1', 2000);
    l.grantForTutorLateCancel('lesson-2', 2000);
    l.hold('use-1', 1000);
    expect(() => l.hold('use-1', 1000)).toThrow();
    l.confirm('use-1', 'order-A');
    expect(() => l.confirm('use-1', 'order-A')).toThrow();
    l.hold('use-2', 1000);
    expect(() => l.confirm('use-2', 'order-A')).toThrow('이미 적립금을 적용');
  });
  it('확정 후 결제 취소·환불되면 되돌림 (한 번만)', () => {
    const l = new RewardLedger();
    l.grantForTutorLateCancel('lesson-1', 2000);
    l.hold('use-1', 2000);
    l.confirm('use-1', 'order-A');
    l.restoreAfterRefund('use-1');
    expect(l.balance()).toBe(2000);
    expect(() => l.restoreAfterRefund('use-1')).toThrow();
  });
});

// 강사 휴가 수업 처리 (정책 원본 A41, 2026-10-26 대표 확정) — 지금 있는 규칙으로 확인할 수 있는 것만
// 대체강사 배정·학생 선택·보강 확정 화면은 H26 순서의 '취소·변경 공통 처리(강사 취소·장기 휴가)' 단계에서 만든다
describe('강사 휴가: 연장은 실제 마지막 보강일까지만 (A20·A41)', () => {
  const baseEnd = '2026-11-26'; // 휴가 연장 전 종료일 (월·수 학생이 휴가 5일 동안 월 11/9·수 11/11 2회를 놓침)
  it('1순위 대체강사가 원래 시간에 수업 → 보강 없음 → 연장 0', () => {
    expect(tutorLeaveExtensionDays(baseEnd, [])).toBe(0);
  });
  it('기존 강사와 기간 안에 보강을 끝냄 → 연장 0', () => {
    expect(tutorLeaveExtensionDays(baseEnd, ['2026-11-20', '2026-11-25'])).toBe(0);
  });
  it('종료일 뒤로 보강이 확정됨 → 마지막 보강일까지만 (휴가 일수·7일·14일 단위 아님)', () => {
    expect(tutorLeaveExtensionDays(baseEnd, ['2026-11-25', '2026-11-30'])).toBe(4);
  });
  it('보강 날짜가 아직 없음 → 지금은 연장하지 않음 (놓친 2회는 미예약 보강으로 남아 있음)', () => {
    expect(tutorLeaveExtensionDays(baseEnd, [])).toBe(0);
  });
  it('보강 날짜를 바꾸면 늘 휴가 연장 전 종료일 기준으로 다시 계산 (연장이 쌓이지 않음)', () => {
    const before = tutorLeaveExtensionDays(baseEnd, ['2026-11-25', '2026-12-02']); // 6일
    const after = tutorLeaveExtensionDays(baseEnd, ['2026-11-25', '2026-11-30']); // 4일
    expect([before, after, after - before]).toEqual([6, 4, -2]); // 차이 -2일은 정정 기록(correction)으로
    expect(tutorLeaveExtensionDays(addDays(baseEnd, before), ['2026-11-30'])).toBe(0); // 연장된 종료일을 넣으면 줄어든 걸 못 잡음 → 쓰면 안 됨
  });
  it('원래 월·수를 보강 후보로 추천만 (확정은 학생·강사 확인 뒤)', () => {
    expect(suggestDatesAfterEnd(baseEnd, [1, 3], 2)).toEqual(['2026-11-30', '2026-12-02']);
  });
});
