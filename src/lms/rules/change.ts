// 수업 변경(취소) 규칙 검사 — 기획서 3-3 검사 순서
// 정책: POL-CHG-01(6시간) POL-CHG-02(늦은 변경) POL-CHG-04(변경권 0개) POL-CHG-06(공휴일) POL-CHG-08(보강 재취소, 미확정) POL-PER-06(보강 기한) POL-TU-05(강사 취소)
// 1. 수강기간 안인지  2. 시작 전인지  3. 6시간 전까지면 정상 변경(변경권 사용)
// 4. 6시간 미만이면 늦은 변경(보강 없음, 수업 1회 소진, 변경권 유지)
// 5. 변경권 0개면 사전 변경이어도 보강 없음, 수업 1회 소진
// 공휴일(한국): 6시간 전까지면 변경권 차감 없이 보강 가능 (변경권 0개여도 가능)
//
// 이 함수는 판정만 한다. 실제 저장(상태 기록·변경권 차감·이력)은 서버에서 한 번에(트랜잭션) 처리.

import { endOfKstDay, hoursBetween, type KstDate } from './dates';
import { CONFIRMED, type PendingPolicy } from './policy';
import type { ClassStatus } from './status';

export type LessonKind = 'regular' | 'makeup' | 'compensation';

export type StudentChangeInput = {
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
  const { lesson, now, finalEndDate, creditsLeft, isKoreanPublicHoliday } = input;

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

  // 이미 보강·보상으로 잡힌 수업을 다시 취소하는 경우 — 규칙 미확정이라 운영자가 정한 값을 따름
  if (lesson.kind !== 'regular') {
    const rule = lesson.kind === 'makeup' ? policy.makeupRecancel : policy.compensationRecancel;
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

/** 보강 시간이 기한 안인지: 최종 종료일(KST) 23:59까지 '시작'하는 수업 */
export function isMakeupSlotAllowed(slotStartsAt: Date, finalEndDate: KstDate, now: Date): boolean {
  return slotStartsAt.getTime() > now.getTime() && slotStartsAt.getTime() <= endOfKstDay(finalEndDate).getTime();
}
