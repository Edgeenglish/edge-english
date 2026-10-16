// 운영 규칙 값
// - CONFIRMED: 기획서·홈페이지 FAQ·수강계약서·Master Sheet가 모두 같은 내용이라 확정된 값
// - PendingPolicy: 문서끼리 서로 다르거나 아직 정하지 않은 규칙 (docs/lms/07-decisions.md)
//   → 기본값을 두지 않는다. 운영자가 정한 값을 넘겨주지 않으면 계산 자체가 되지 않게 해서
//     정해지지 않은 규칙이 몰래 적용되는 일을 막는다.

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
  /**
   * 확정된 보강 수업을 학생이 다시 취소할 때 (D-2)
   * - 'no_rebook': 재보강 불가 (현재 홈페이지 FAQ 문구)
   * - 'same_as_regular': 정규 수업과 똑같이 처리 (기존 기획서 3-3)
   */
  makeupRecancel: 'no_rebook' | 'same_as_regular';
  /** 강사 노쇼 보상 수업을 학생이 다시 취소할 때 (D-2와 같은 선택지) */
  compensationRecancel: 'no_rebook' | 'same_as_regular';
};
