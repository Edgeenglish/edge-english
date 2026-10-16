// 운영 규칙 값 — 기준은 정책 기준표 docs/lms/policy/register.md
// - CONFIRMED: 기준표에서 '확정'인 값. CONFIRMED_REFS 에 정책 ID를 적고, 자동 테스트가 기준표 상태를 확인함
// - PendingPolicy: 기준표에서 '검토 중'인 규칙 (docs/lms/07-decisions.md)
//   → 기본값을 두지 않는다. 운영자가 정한 값을 넘겨주지 않으면 계산 자체가 되지 않게 해서
//     정해지지 않은 규칙이 몰래 적용되는 일을 막는다.
// - 정책 원본(Google Docs, SRC-POLICY-V1) 규칙은 둘로 나눔 (POL-OP-16·17)
//   FAVORABLE_FOR_ALL: 학생에게 유리 → 기존 학생 포함 전원
//   POLICY_V1: 기존 계약보다 불리할 수 있음 → '정책 원본 적용' 등록(enrollments.policy_basis = 'policy_v1')만. 소급 금지
// - 아래 CONFIRMED 값은 수강계약서 2판(SC2) 이후 기준. 1판(SC1) 학생 규칙은 D-16 결정 후 판본별로 추가

export const CONFIRMED = {
  /** 1기간 = 28일 (시작일 포함) */
  periodDays: 28,
  /** 수강 단위(주) */
  courseWeeks: [4, 12, 24] as const,
  /** 정상 변경 기준: 수업 시작 6시간 전까지 (6시간 정각 포함) */
  changeNoticeHours: 6,
  /** 주 횟수 */
  weeklyCounts: [1, 2, 3, 5] as const,
  /** 수업 길이(분) */
  durations: [20, 40, 50] as const,
} as const;

/** CONFIRMED 각 값의 근거 정책 ID (기준표에서 '확정'이어야 함 — policy-register.test.ts) */
export const CONFIRMED_REFS = {
  periodDays: 'POL-PER-02',
  courseWeeks: 'POL-PER-01',
  changeNoticeHours: 'POL-CHG-01',
  weeklyCounts: 'POL-PAY-08',
  durations: 'POL-PAY-08',
  creditsPerPeriod: 'POL-CHG-03',
} as const;

/**
 * 이 등록에 어떤 규칙을 자동 적용하는지 (POL-OP-16)
 * - 'policy_v1': 정책 원본 v1.0 조건을 안내·동의받은 등록 (신규·갱신)
 * - 'legacy': 그 밖의 등록 (예전 계약서·예전 안내서·미확인). 판본마다 다를 수 있는 규칙은 자동 판정하지 않고
 *   운영자가 정한 값(PendingPolicy)을 넘겨야만 계산된다.
 */
export type RuleBasis = 'policy_v1' | 'legacy';

/**
 * 학생에게 유리한 정책 원본 규칙 — 기존 학생을 포함해 **모든 등록**에 적용 (POL-OP-17, 2026-10-16 대표 결정)
 * 기존 계약에 이보다 유리한 조건이 있으면 그 조건을 유지한다(현재 확인된 판본 중 해당 없음). 시행일은 배포·안내 전에 별도 확정.
 */
export const FAVORABLE_FOR_ALL = {
  /** 이미 예약한 보강도 정규 수업과 같은 규칙으로 반복 변경 가능 (A03) */
  makeupRecancel: 'same_as_regular',
  /** 강사가 6시간 미만에 취소하면 학생 적립금 2,000원 (A16·A17), 유효기간 없음 (A18) */
  tutorLateCancelRewardWon: 2000,
} as const;

/** 재등록 규칙 (계약서에 정한 조항이 없어 전원 같음) */
export const RENEWAL = {
  /** 종료 후(늦은) 재등록의 새 수강 시작일 = 결제 후 첫 정규 수업일, 잔여 수업 이월 없음 (POL-RN-04, 정책 원본 A21) */
  lateStart: 'first_lesson_after_payment',
  /**
   * 종료일까지 결제한 재등록의 새 수강 시작일 = 이전 종료일 뒤 처음 오는 정규 수업일 (POL-RN-07, 정책 원본 A25, 2026-10-17)
   * '종료 다음 날부터 무조건'이 아님. 이월 자격(A01·A02)과는 별도 규칙
   */
  onTimeStart: 'first_lesson_after_previous_end',
  /** 기존 고정 요일·시간은 종료일 23:59 KST까지 결제하면 우선 확보 (POL-RN-02, 정책 원본 A22, 이월 마감과는 별도 규칙) */
  holdFixedSlotUntilEndOfDay: true,
} as const;

/** 정책 원본 v1.0 (2026-10-16 대표확정) 중 기존 조건보다 불리할 수 있는 규칙 — 'policy_v1' 등록에만 적용 (소급 금지) */
export const POLICY_V1 = {
  /** 이월: 종료일 23:59 KST까지 실제 결제 완료 (A01·A02) — 판정은 period.ts canCarryOver */
  carryOverPaidByEndOfDay: true,
  /** 장기 연기: 24주 상품만, 총 14일, 7일 단위 최대 2회, 시작 4일 전까지 신청 (A09~A12) */
  longLeave: { weeks: 24 as CourseWeeks, maxTotalDays: 14, unitDays: 7, maxRequests: 2, applyDaysBefore: 4 },
  /** 강사 노쇼 무료 보상 수업: 지급일로부터 7일 안에 수업 완료 (A14) */
  compensationCompleteWithinDays: 7,
} as const;

/** POLICY_V1 각 값의 근거 정책 ID (기준표에서 '확정'이어야 함 — policy-register.test.ts) */
export const POLICY_V1_REFS: Record<keyof typeof POLICY_V1 | keyof typeof FAVORABLE_FOR_ALL | `renewal.${keyof typeof RENEWAL}`, string> = {
  makeupRecancel: 'POL-CHG-08',
  tutorLateCancelRewardWon: 'POL-TU-04',
  carryOverPaidByEndOfDay: 'POL-RN-01',
  longLeave: 'POL-LV-01',
  compensationCompleteWithinDays: 'POL-TU-03',
  'renewal.lateStart': 'POL-RN-04',
  'renewal.onTimeStart': 'POL-RN-07',
  'renewal.holdFixedSlotUntilEndOfDay': 'POL-RN-02',
};

export type CourseWeeks = (typeof CONFIRMED.courseWeeks)[number];

/** 4주(1기간)마다 주는 변경권: 주 1회=1, 주 2회=2, 주 3회 이상=3. 기간이 바뀌면 새로 지급(이월 없음) */
export function creditsPerPeriod(weeklyCount: number): number {
  if (!Number.isInteger(weeklyCount) || weeklyCount < 1) throw new Error(`주 횟수가 올바르지 않습니다: ${weeklyCount}`);
  return Math.min(weeklyCount, 3);
}

/** 50분은 주 1회부터, 20·40분은 주 2회부터 (수업료 페이지·FAQ 기준) */
export function isOfferedPlan(durationMin: number, weeklyCount: number): boolean {
  if (!(CONFIRMED.durations as readonly number[]).includes(durationMin)) return false;
  if (!(CONFIRMED.weeklyCounts as readonly number[]).includes(weeklyCount)) return false;
  if (durationMin === 50) return weeklyCount !== 5;
  return weeklyCount !== 1;
}

/**
 * 아직 확정되지 않은 규칙 (운영자 결정 필요).
 * 각 항목의 선택지와 추천안은 docs/lms/07-decisions.md 참고.
 */
export type PendingPolicy = {
  /** 강사 노쇼 보상 수업을 학생이 다시 취소할 때 (POL-TU-10, 정책 원본 C03 — 원본 A03은 '보강'만 언급) */
  compensationRecancel: 'no_rebook' | 'same_as_regular';
};

/** PendingPolicy 각 항목의 정책 ID (기준표에서 아직 '검토 중'이어야 함 — 결정되면 테스트가 알려 줌) */
export const PENDING_REFS: Record<keyof PendingPolicy, string> = {
  compensationRecancel: 'POL-TU-10',
};
