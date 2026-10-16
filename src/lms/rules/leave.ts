// 휴무·장기 연기
// - 강사 휴무 일괄 처리: 영향받는 수업 미리보기 → 학생과 보강 협의 → 기간 안에 어려우면 필요한 만큼만 연장 (POL-LV-02, 정책 원본 A19·A20)
// - 학생 장기 연기 신청 검사 (POL-LV-01, 정책 원본 A09~A12 — 'policy_v1' 등록만 자동 판정)

import { addDays, diffDays, instantToKstDate, weekdayOf, type KstDate } from './dates';
import { POLICY_V1, type CourseWeeks, type RuleBasis } from './policy';

export type LessonForLeave = {
  id: string;
  tutorId: string;
  studentId: string;
  kstDate: KstDate;
  state: 'scheduled' | 'canceled' | 'done';
};

export type LeaveImpact = { studentId: string; lessonIds: string[]; dates: KstDate[] };

/** from~to (KST 날짜, 양 끝 포함) 사이 해당 강사의 예정 수업을 학생별로 묶음 */
export function previewTutorLeave(lessons: LessonForLeave[], tutorId: string, from: KstDate, to: KstDate): LeaveImpact[] {
  if (diffDays(from, to) < 0) throw new Error('휴무 종료일이 시작일보다 빠릅니다.');
  const byStudent = new Map<string, LeaveImpact>();
  for (const l of lessons) {
    if (l.tutorId !== tutorId || l.state !== 'scheduled') continue;
    if (diffDays(from, l.kstDate) < 0 || diffDays(l.kstDate, to) < 0) continue;
    const item = byStudent.get(l.studentId) ?? { studentId: l.studentId, lessonIds: [], dates: [] };
    item.lessonIds.push(l.id);
    item.dates.push(l.kstDate);
    byStudent.set(l.studentId, item);
  }
  return [...byStudent.values()].map((i) => ({ ...i, dates: [...i.dates].sort() }));
}

/**
 * 종료일 뒤 학생의 정규 요일에 맞춘 보강 후보 날짜 n개 (A20 예: 화·목 학생 → 종료일 뒤 화·목).
 * blocked: 강사가 못 하는 날 등 제외할 날짜. 실제 보강 시각은 운영자가 학생·강사와 정함.
 */
export function suggestDatesAfterEnd(finalEnd: KstDate, weekdays: number[], n: number, blocked: ReadonlySet<KstDate> = new Set()): KstDate[] {
  if (weekdays.length === 0 || weekdays.some((w) => !Number.isInteger(w) || w < 0 || w > 6)) throw new Error('정규 요일이 올바르지 않습니다.');
  const out: KstDate[] = [];
  let d = finalEnd;
  while (out.length < n) {
    d = addDays(d, 1);
    if (weekdays.includes(weekdayOf(d)) && !blocked.has(d)) out.push(d);
  }
  return out;
}

/**
 * 강사 장기 휴무 연장 일수 (A20): 휴무 일수나 1주 단위가 아니라, 기간 밖으로 잡은 보강 중 '마지막 실제 보강 수업일'까지만.
 * 기간 안에 모두 잡았으면 0.
 */
export function tutorLeaveExtensionDays(finalEnd: KstDate, makeupDates: KstDate[]): number {
  return makeupDates.reduce((max, d) => Math.max(max, diffDays(finalEnd, d)), 0);
}

export type LongLeaveReason = 'health' | 'family_emergency' | 'business_trip' | 'other_special' | 'personal';

export type LongLeaveInput = {
  basis: RuleBasis;
  weeks: CourseWeeks | null; // 옛 상품이면 null
  enrollmentStart: KstDate;
  finalEnd: KstDate;
  leaveStart: KstDate;
  days: number;
  reason: LongLeaveReason;
  now: Date;
  /** 이 등록에서 이미 승인됐거나 심사 중인 장기 연기 (거절·철회 제외) */
  earlier: { days: number }[];
};

export type LongLeaveDecision =
  | { ok: true; status: 'pending_admin_approval'; from: KstDate; to: KstDate; needsEvidence: true; message: string }
  | {
      ok: false;
      reason: 'manual_review' | 'not_24_weeks' | 'reason_not_eligible' | 'invalid_days' | 'too_late' | 'outside_enrollment' | 'limit_exceeded';
      message: string;
    };

/**
 * 학생 장기 연기 신청 검사 — 기한·대상·남은 일수는 시스템이 막고, 증빙은 운영자가 확인 후 승인 (A11·A12)
 * - 24주 상품만, 총 14일, 7일 단위로 최대 2회 (A09·A12)
 * - 증빙 가능한 특별 사유만, 임의 개인 사정 불가 (A10)
 * - 연기 시작일 4일 전 날(KST)까지 신청 (A11). 예: 11/20 시작 → 11/16 23:59까지
 * - 'legacy' 등록은 계약 판본마다 조건이 달라(SC1·SC2는 전 상품 28~30일) 자동 판정하지 않음 (POL-OP-16)
 */
export function evaluateLongLeaveRequest(input: LongLeaveInput): LongLeaveDecision {
  const rule = POLICY_V1.longLeave;
  if (input.basis !== 'policy_v1') {
    return { ok: false, reason: 'manual_review', message: '등록하신 조건을 확인해야 해요. 엣지영어 카카오톡 채널로 문의해 주세요.' };
  }
  if (input.weeks !== rule.weeks) {
    return { ok: false, reason: 'not_24_weeks', message: '장기 연기는 24주 수강권에서만 신청할 수 있어요.' };
  }
  if (input.reason === 'personal') {
    return {
      ok: false,
      reason: 'reason_not_eligible',
      message: '장기 연기는 건강·가족 긴급 사정·출장처럼 증빙할 수 있는 특별한 사유가 있을 때만 가능해요.',
    };
  }
  if (!Number.isInteger(input.days) || input.days <= 0 || input.days % rule.unitDays !== 0) {
    return { ok: false, reason: 'invalid_days', message: `연기 기간은 ${rule.unitDays}일 단위로 신청할 수 있어요.` };
  }
  const usedDays = input.earlier.reduce((sum, e) => sum + e.days, 0);
  if (input.earlier.length + 1 > rule.maxRequests || usedDays + input.days > rule.maxTotalDays) {
    const left = Math.max(rule.maxTotalDays - usedDays, 0);
    return {
      ok: false,
      reason: 'limit_exceeded',
      message: `장기 연기는 수강기간 동안 최대 ${rule.maxTotalDays}일(${rule.maxRequests}회)까지예요. 남은 일수: ${input.earlier.length >= rule.maxRequests ? 0 : left}일`,
    };
  }
  if (diffDays(input.enrollmentStart, input.leaveStart) < 0 || diffDays(input.leaveStart, input.finalEnd) < 0) {
    return { ok: false, reason: 'outside_enrollment', message: '연기 시작일은 수강기간 안이어야 해요.' };
  }
  const lastDay = addDays(input.leaveStart, -rule.applyDaysBefore);
  if (diffDays(instantToKstDate(input.now), lastDay) < 0) {
    return {
      ok: false,
      reason: 'too_late',
      message: `연기 시작일 ${rule.applyDaysBefore}일 전(${lastDay})까지 신청해야 해요. 시작일을 늦춰서 다시 신청해 주세요.`,
    };
  }
  return {
    ok: true,
    status: 'pending_admin_approval',
    from: input.leaveStart,
    to: addDays(input.leaveStart, input.days - 1),
    needsEvidence: true,
    message: '신청이 접수됐어요. 증빙 자료를 확인한 뒤 승인되면 수강 종료일이 늘어나요.',
  };
}
