// 학생 홈(마이페이지) 화면 판정 — 3차 시안 A-1 최종 (2026-10-17 대표 확정, docs/lms/07-decisions.md D-34·D-35)
// 화면은 이 함수들의 결과만 그린다. 6시간 규칙 판정은 rules/change.ts 를 그대로 쓴다.
//
// - 재등록 안내: 남은 수업(정규·보강·보상·이월 + 날짜 미정 보강) 2회 이하일 때만, 재등록 결제가 확인되면 숨김 (POL-RN-08)
// - 할 일 알림: 학생이 직접 처리해야 할 때만. '강사 확인 중' 같은 기다림은 넣지 않음
// - 결제: 수강권·기간·결제 방법·확인일만. 금액·카드 정보는 다루지 않음 (POL-PAY-11)
// - 적립금: 본인 지급·사용 날짜, 금액, 사유, 잔액 (POL-PAY-11, POL-PAY-09)

import { evaluateStudentChange, type ChangeDecision, type LessonKind } from '../rules/change';
import { instantToKstDate, type KstDate } from '../rules/dates';
import type { PendingPolicy } from '../rules/policy';

export type StudentLesson = {
  id: string;
  kind: LessonKind;
  startsAt: Date;
  minutes: number;
  tutorName: string;
  /** scheduled = 아직 하지 않은 수업. 진행·취소된 수업은 다른 값 */
  state: 'scheduled' | 'done' | 'canceled';
};

/** 남은 수업(정규·보강·보상·이월 + 날짜 미정 보강) 2회 이하일 때 재등록 안내 (POL-RN-08, 2026-10-27 대표: 보강·보상도 다 수업) */
export const RENEWAL_PROMPT = { maxLessonsLeft: 2 } as const;
export const RENEWAL_PROMPT_REF = 'POL-RN-08';

/** 아직 하지 않은 정규 수업 수. 보강·보상 수업은 넣지 않음 (POL-RN-08) */
export function regularLessonsLeft(lessons: readonly StudentLesson[]): number {
  return lessons.filter((l) => l.kind === 'regular' && l.state === 'scheduled').length;
}

/**
 * '남은 수업' 칸 = 예정된 수업(정규 + 보강 + 보상) + 아직 시간을 안 잡은 보강.
 * makeupsOwed: 정상 취소로 생긴 보강 중 아직 예정 수업이 아닌 것 (신청 중 포함)
 */
export function lessonsLeft(lessons: readonly StudentLesson[], makeupsOwed = 0) {
  if (!Number.isInteger(makeupsOwed) || makeupsOwed < 0) throw new Error(`보강 수가 올바르지 않습니다: ${makeupsOwed}`);
  const scheduled = lessons.filter((l) => l.state === 'scheduled');
  const other = scheduled.filter((l) => l.kind !== 'regular').length + makeupsOwed;
  return { total: scheduled.length + makeupsOwed, regular: regularLessonsLeft(lessons), other };
}

/** 지금 들어갈 수 있거나 다음에 올 수업 (끝나기 전까지는 '다음 수업'에 남김 — 수업 입장 버튼) */
export function nextLesson(lessons: readonly StudentLesson[], now: Date): StudentLesson | null {
  return (
    lessons
      .filter((l) => l.state === 'scheduled' && l.startsAt.getTime() + l.minutes * 60_000 > now.getTime())
      .sort((a, b) => a.startsAt.getTime() - b.startsAt.getTime())[0] ?? null
  );
}

/**
 * 재등록 진행 상태 — '신청'과 '결제 확인'을 구분한다.
 * requested: 학생이 재등록을 신청했지만 운영자가 결제를 아직 확인하지 않음 (아임웹·계좌이체는 자동 연동 아님, POL-PAY-11)
 */
export type RenewalState = 'not_requested' | 'requested' | 'payment_confirmed';

export type RenewalPrompt = null | { mode: 'request'; left: number } | { mode: 'awaiting_payment'; left: number };

export function renewalPrompt(lessons: readonly StudentLesson[], renewal: RenewalState, makeupsOwed = 0): RenewalPrompt {
  const left = lessonsLeft(lessons, makeupsOwed).total;
  if (renewal === 'payment_confirmed') return null;
  if (left > RENEWAL_PROMPT.maxLessonsLeft) return null;
  return renewal === 'requested' ? { mode: 'awaiting_payment', left } : { mode: 'request', left };
}

/** 신청 진행 상태. 학생이 기다리기만 하면 되는 단계는 할 일이 아님 */
export type RequestStatus = 'tutor_reviewing' | 'admin_reviewing' | 'confirmed' | 'completed';

export type StudentRequest = {
  id: string;
  kind: 'makeup' | 'change';
  title: string;
  status: RequestStatus;
  /** 보강 신청: 학생이 고른 후보 시각 */
  candidates: Date[];
  createdAt: Date;
  note: string;
};

export const REQUEST_STATUS_LABEL: Record<RequestStatus, string> = {
  tutor_reviewing: '강사 확인 중',
  admin_reviewing: '운영자 확인 중',
  confirmed: '확정',
  completed: '처리 완료',
};

/** 학생이 직접 처리해야 하는 일. 지금은 수업 안내 확인·동의뿐 (POL-OP-12). 규칙이 정해지면 종류를 추가 */
export type StudentTodo = { kind: 'terms_consent'; id: string; label: string };

export function studentTodos(input: { pendingConsents: readonly { id: string; title: string }[] }): StudentTodo[] {
  return input.pendingConsents.map((c) => ({ kind: 'terms_consent', id: c.id, label: `${c.title} 동의가 필요해요` }));
}

/** 결제 내역 한 줄 — 금액·카드 정보 필드는 일부러 두지 않음 (POL-PAY-11) */
export type PaymentSummary = {
  id: string;
  product: string;
  periodStart: KstDate;
  periodEnd: KstDate;
  method: 'card_imweb' | 'bank_transfer';
  /** 운영자가 결제를 확인한 날. null = 확인 전 */
  confirmedOn: KstDate | null;
  current: boolean;
};

export const PAYMENT_METHOD_LABEL: Record<PaymentSummary['method'], string> = {
  card_imweb: '카드 (아임웹)',
  bank_transfer: '계좌이체',
};

/**
 * 적립금 사건 (POL-PAY-09). amount 는 양수, 방향은 kind 로 정함.
 * use_pending = 결제에 쓰려고 예약(아직 결제 확인 전), use = 결제 확인 후 확정, release = 예약 취소로 되돌림, restore = 환불로 복구
 */
export type PointsEvent = {
  id: string;
  on: KstDate;
  kind: 'grant' | 'use_pending' | 'use' | 'release' | 'restore';
  amount: number;
  reason: string;
};

export type PointsRow = PointsEvent & { signed: number; balanceAfter: number };

const POINTS_SIGN: Record<PointsEvent['kind'], 1 | -1> = { grant: 1, use_pending: -1, use: -1, release: 1, restore: 1 };

/** 오래된 순서로 받은 사건 → 최신 순서 + 각 줄 뒤 잔액. 잔액은 쓸 수 있는 금액(예약 중 금액 제외, RewardLedger.balance 와 같음) */
export function pointsHistory(events: readonly PointsEvent[]): { balance: number; rows: PointsRow[] } {
  let balance = 0;
  const rows = events.map((e) => {
    if (!Number.isInteger(e.amount) || e.amount <= 0) throw new Error(`적립금 금액이 올바르지 않습니다: ${e.id}`);
    const signed = POINTS_SIGN[e.kind] * e.amount;
    balance += signed;
    if (balance < 0) throw new Error(`적립금 잔액이 음수가 됩니다: ${e.id}`);
    return { ...e, signed, balanceAfter: balance };
  });
  return { balance, rows: rows.reverse() };
}

/** 보상 수업 재취소 규칙(POL-TU-10)이 정해지지 않았을 때 넘기는 값 — 읽히면 판정을 멈춤 */
const POLICY_NOT_DECIDED: PendingPolicy = {
  get compensationRecancel(): never {
    throw new Error('POL-TU-10 미결정');
  },
};

export type CancelPreview = ChangeDecision | { ok: false; reason: 'policy_pending' };

/**
 * 변경·취소 최종 확인창에 보여 줄 결과. 판정은 rules/change.ts (POL-CHG-01·02·04·06)
 * 보상 수업은 재취소 규칙이 미결정이라 운영자가 값을 정하기 전에는 판정하지 않음
 */
export function cancelPreview(
  input: { lesson: StudentLesson; now: Date; finalEndDate: KstDate; creditsLeft: number; holidays: ReadonlySet<KstDate> },
  policy: PendingPolicy | null,
): CancelPreview {
  const { lesson } = input;
  if (lesson.kind === 'compensation' && !policy) return { ok: false, reason: 'policy_pending' };
  return evaluateStudentChange(
    {
      lesson: { kind: lesson.kind, kstDate: instantToKstDate(lesson.startsAt), startsAt: lesson.startsAt },
      now: input.now,
      finalEndDate: input.finalEndDate,
      creditsLeft: input.creditsLeft,
      isKoreanPublicHoliday: input.holidays.has(instantToKstDate(lesson.startsAt)),
    },
    policy ?? POLICY_NOT_DECIDED,
  );
}
