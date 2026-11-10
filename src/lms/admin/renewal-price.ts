/**
 * 수강 코스 가격표 (대표 첨부 이미지 기준, 2026-11-10). 재등록 안내 문자가 이 표로 코스별 가격을 채운다.
 * 가격이 바뀌면 아래 MONTHLY 의 1개월 가격만 고친다. 3개월(5% 할인)·6개월(5% 할인 + 5만 원 추가 할인)은 계산된다.
 * 홈페이지 가격표(src/components/LongTermPrice.tsx)와 같은 값.
 */

/** 1개월(4주) 정가: 수업 분 → 주 횟수 → 원 */
const MONTHLY: Record<number, Record<number, number>> = {
  20: { 2: 178000, 3: 249000, 5: 370000 },
  40: { 2: 290000, 3: 420000, 5: 695000 },
  50: { 1: 195000, 2: 355000, 3: 520000 },
};

export type RenewalPlans = {
  monthly: number;
  three: { total: number; perMonth: number; save: number };
  six: { total: number; perMonth: number; save: number };
};

/** 표에 없는 코스면 null (가격을 짐작하지 않음) */
export function renewalPlans(durationMin: number, weeklyCount: number): RenewalPlans | null {
  const monthly = MONTHLY[durationMin]?.[weeklyCount];
  if (!monthly) return null;
  const three = Math.round(monthly * 3 * 0.95);
  const six = Math.round(monthly * 6 * 0.95) - 50000;
  return {
    monthly,
    three: { total: three, perMonth: Math.round(three / 3), save: monthly * 3 - three },
    six: { total: six, perMonth: Math.round(six / 6), save: monthly * 6 - six },
  };
}
