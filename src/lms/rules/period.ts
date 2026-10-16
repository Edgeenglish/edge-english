// 수강기간 계산 (POL-PER-01~04, 수강계약서 2판 이후 기준)
// - 최초 시작일 = 첫 정규 수업일 (주말·공휴일이어도 같은 규칙)
// - 1기간 = 시작일 포함 28일 → 종료일 = 시작일 + 27일
// - 12주 = 28일 × 3기간, 24주 = 28일 × 6기간 (기간은 끊김 없이 이어짐)
// - 옛 상품(1판 계약 30일, 2개월 등)은 다시 계산하지 않고 시트의 실제 날짜를 그대로 이관 (CF-04)

import { addDays, diffDays, type KstDate } from './dates';
import { CONFIRMED, type CourseWeeks, type PendingPolicy } from './policy';

export type Period = { index: number; start: KstDate; end: KstDate };

export function periodCount(weeks: CourseWeeks): number {
  if (!(CONFIRMED.courseWeeks as readonly number[]).includes(weeks)) {
    throw new Error(`수강 단위는 4·12·24주만 가능합니다: ${weeks}`);
  }
  return weeks / 4;
}

export function computePeriods(startDate: KstDate, weeks: CourseWeeks): Period[] {
  const n = periodCount(weeks);
  const periods: Period[] = [];
  let start = startDate;
  for (let i = 0; i < n; i++) {
    const end = addDays(start, CONFIRMED.periodDays - 1);
    periods.push({ index: i + 1, start, end });
    start = addDays(end, 1);
  }
  return periods;
}

/** 최종 종료일 (연장 일수가 있으면 더함 — 연장 규칙 자체는 운영자 결정 사항) */
export function finalEndDate(startDate: KstDate, weeks: CourseWeeks, extensionDays = 0): KstDate {
  if (!Number.isInteger(extensionDays) || extensionDays < 0) throw new Error('연장 일수가 올바르지 않습니다.');
  const periods = computePeriods(startDate, weeks);
  return addDays(periods[periods.length - 1].end, extensionDays);
}

/** 이 날짜가 몇 번째 기간에 속하는지 (기간 밖이면 null). 연장된 날짜는 마지막 기간에 포함 */
export function periodOf(date: KstDate, startDate: KstDate, weeks: CourseWeeks, extensionDays = 0): Period | null {
  const periods = computePeriods(startDate, weeks);
  if (diffDays(startDate, date) < 0) return null;
  if (diffDays(date, finalEndDate(startDate, weeks, extensionDays)) < 0) return null;
  const found = periods.find((p) => diffDays(p.start, date) >= 0 && diffDays(date, p.end) >= 0);
  if (found) return found;
  const last = periods[periods.length - 1];
  return { ...last, end: finalEndDate(startDate, weeks, extensionDays) };
}

/** 재등록 시 새 수강 시작일 (POL-RN-04 미확정 → 운영자가 정한 방식을 넘겨야 계산됨) */
export function renewalStartDate(
  input: { previousFinalEnd: KstDate; renewedOn: KstDate; firstLessonAfterRenewal: KstDate },
  policy: Pick<PendingPolicy, 'renewalStart'>,
): KstDate {
  const continuous =
    policy.renewalStart === 'day_after_previous_end' ||
    (policy.renewalStart === 'continuous_if_before_end' && diffDays(input.renewedOn, input.previousFinalEnd) >= 0);
  if (continuous) return addDays(input.previousFinalEnd, 1);
  if (diffDays(input.previousFinalEnd, input.firstLessonAfterRenewal) <= 0) {
    throw new Error('재등록 후 첫 수업일은 이전 종료일 이후여야 합니다.');
  }
  return input.firstLessonAfterRenewal;
}
