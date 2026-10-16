// 수업 변경(취소) 규칙 검사 — 기획서 3-3 검사 순서
// 정책: POL-CHG-01(6시간) POL-CHG-02(늦은 변경) POL-CHG-04(변경권 0개) POL-CHG-06(공휴일) POL-CHG-08(보강 재변경)
//       POL-PER-06(보강 기한) POL-TU-03(노쇼 보상 기한) POL-TU-04·05(강사 취소) POL-OP-16·17(적용 범위)
// 1. 수강기간 안인지  2. 시작 전인지  3. 6시간 전까지면 정상 변경(변경권 사용)
// 4. 6시간 미만이면 늦은 변경(보강 없음, 수업 1회 소진, 변경권 유지)
// 5. 변경권 0개면 사전 변경이어도 보강 없음, 수업 1회 소진
// 공휴일(한국): 6시간 전까지면 변경권 차감 없이 보강 가능 (변경권 0개여도 가능)
//
// 이 함수는 판정만 한다. 실제 저장(상태 기록·변경권 차감·이력)은 서버에서 한 번에(트랜잭션) 처리.

import { addDays, endOfKstDay, hoursBetween, instantToKstDate, type KstDate } from './dates';
import { CONFIRMED, POLICY_V1, type PendingPolicy, type RuleBasis } from './policy';
import type { ClassStatus } from './status';

export type LessonKind = 'regular' | 'makeup' | 'compensation';

export type StudentChangeInput = {
  basis: RuleBasis; // 이 등록에 자동 적용할 규칙 (POL-OP-16)
  lesson: { kind: LessonKind; kstDate: KstDate; startsAt: Date };
  now: Date;
  finalEndDate: KstDate; // 수강 최종 종료일 (연장 포함)
  creditsLeft: number; // 수업 날짜가 속한 기간의 남은 변경권
  isKoreanPublicHoliday: boolean; // 수업 날짜(KST)가 운영자가 등록한 공휴일인지
};

export type ChangeDecision =
  | { ok: false; reason: 'already_started' | 'outside_enrollment' }
  | {
      ok: true;
      timing: 'advance' | 'late';
      /** null = 상태매핑표에 맞는 값이 없음 (운영자 결정 필요 항목) */
      status: ClassStatus | null;
      usesCredit: boolean;
      consumesLesson: boolean;
      makeupAllowed: boolean;
      makeupDeadline: Date | null; // 보강 수업 시작 시각의 한계 (KST 종료일 23:59)
      studentMessage: string;
    };

const LATE_MESSAGE =
  '수업 시작까지 6시간이 남지 않았어요. 지금 취소하면 보강 없이 수업 1회가 소진돼요. (변경권은 차감되지 않아요) 그래도 미리 알려주시면 강사님이 기다리지 않아도 돼요.';

export function evaluateStudentChange(input: StudentChangeInput, policy: PendingPolicy): ChangeDecision {
  const { basis, lesson, now, finalEndDate, creditsLeft, isKoreanPublicHoliday } = input;

  if (lesson.startsAt.getTime() > endOfKstDay(finalEndDate).getTime()) return { ok: false, reason: 'outside_enrollment' };
  if (now.getTime() >= lesson.startsAt.getTime()) return { ok: false, reason: 'already_started' };

  const advance = hoursBetween(now, lesson.startsAt) >= CONFIRMED.changeNoticeHours;
  const deadline = endOfKstDay(finalEndDate);

  if (!advance) {
    return {
      ok: true,
      timing: 'late',
      status: 'Student canceled late',
      usesCredit: false,
      consumesLesson: true,
      makeupAllowed: false,
      makeupDeadline: null,
      studentMessage: LATE_MESSAGE,
    };
  }

  // 이미 보강·보상으로 잡힌 수업을 다시 바꾸는 경우
  // - 보강: policy_v1 등록은 정규와 같은 규칙(A03, 변경권이 남아 있는 한 반복 가능). 그 밖의 등록은 운영자가 정한 값(POL-OP-17)
  // - 보상 수업: 미확정(POL-TU-10) → 운영자가 정한 값
  if (lesson.kind !== 'regular') {
    const rule =
      lesson.kind === 'compensation'
        ? policy.compensationRecancel
        : basis === 'policy_v1'
          ? POLICY_V1.makeupRecancel
          : policy.legacyMakeupRecancel;
    if (rule === 'no_rebook') {
      return {
        ok: true,
        timing: 'advance',
        status: null,
        usesCredit: false,
        consumesLesson: true,
        makeupAllowed: false,
        makeupDeadline: null,
        studentMessage: '이미 보강으로 잡힌 수업이라 다시 취소하면 재보강 없이 수업 1회가 소진돼요.',
      };
    }
  }

  if (isKoreanPublicHoliday) {
    return {
      ok: true,
      timing: 'advance',
      status: 'Student canceled in advance (public holiday)',
      usesCredit: false,
      consumesLesson: false,
      makeupAllowed: true,
      makeupDeadline: deadline,
      studentMessage: '공휴일 수업이라 변경권이 차감되지 않아요. 수강기간 안에 보강을 신청할 수 있어요.',
    };
  }

  if (creditsLeft <= 0) {
    return {
      ok: true,
      timing: 'advance',
      status: 'No change credits left',
      usesCredit: false,
      consumesLesson: true,
      makeupAllowed: false,
      makeupDeadline: null,
      studentMessage: '이번 기간 변경권을 모두 사용해서, 지금 취소하면 보강 없이 수업 1회가 소진돼요.',
    };
  }

  return {
    ok: true,
    timing: 'advance',
    status: 'Student canceled in advance',
    usesCredit: true,
    consumesLesson: false,
    makeupAllowed: true,
    makeupDeadline: deadline,
    studentMessage: `남은 변경권 ${creditsLeft}개 중 1개를 사용해요. 수강기간 안에 보강을 신청할 수 있어요.`,
  };
}

/** 강사 사유 취소: 6시간 전까지 = 정상 취소, 미만 = 늦은 취소(인센티브 영향). 학생 변경권은 절대 차감하지 않음 */
export function evaluateTutorCancel(now: Date, startsAt: Date): ClassStatus {
  return hoursBetween(now, startsAt) >= CONFIRMED.changeNoticeHours ? 'Tutor canceled in advance' : 'Tutor canceled late';
}

export type TutorCancelOutcome = {
  status: ClassStatus;
  makeupRequired: true; // 원래 수업은 항상 보강 (A15·A16)
  usesCredit: false;
  /** 학생 적립금 지급액(원). legacy 등록은 null = 운영자 결정 대기(POL-OP-17) */
  rewardWon: number | null;
};

/** 강사 사유 취소의 학생 쪽 결과 — 6시간 이상 전: 보강만(A15) / 6시간 미만: 보강 + 2,000원 적립금(A16) */
export function tutorCancelOutcome(now: Date, startsAt: Date, basis: RuleBasis): TutorCancelOutcome {
  const status = evaluateTutorCancel(now, startsAt);
  const late = status === 'Tutor canceled late';
  return {
    status,
    makeupRequired: true,
    usesCredit: false,
    rewardWon: !late ? 0 : basis === 'policy_v1' ? POLICY_V1.tutorLateCancelRewardWon : null,
  };
}

/**
 * 강사 노쇼 무료 보상 수업의 완료 기한 (A14): 지급한 날(KST)부터 7일째 날 23:59 KST까지 수업이 '끝나야' 함.
 * 예: 11/3 지급 → 11/10 23:59까지. 기한 안에 못 받는 경우의 예외는 미확정(POL-TU-10) → 자동 소멸시키지 않고 운영자에게 표시.
 */
export function compensationDeadline(grantedAt: Date): Date {
  return endOfKstDay(addDays(instantToKstDate(grantedAt), POLICY_V1.compensationCompleteWithinDays));
}

/** 보상 수업 시간이 기한 안인지: 시작 전이고, 끝나는 시각이 기한 이내 */
export function isCompensationSlotAllowed(slot: { startsAt: Date; endsAt: Date }, grantedAt: Date, now: Date): boolean {
  return slot.startsAt.getTime() > now.getTime() && slot.endsAt.getTime() <= compensationDeadline(grantedAt).getTime();
}

/** 보강 시간이 기한 안인지: 최종 종료일(KST) 23:59까지 '시작'하는 수업 */
export function isMakeupSlotAllowed(slotStartsAt: Date, finalEndDate: KstDate, now: Date): boolean {
  return slotStartsAt.getTime() > now.getTime() && slotStartsAt.getTime() <= endOfKstDay(finalEndDate).getTime();
}
