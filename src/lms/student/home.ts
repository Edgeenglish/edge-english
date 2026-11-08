// 수강생 홈(마이페이지) 화면 판정 — 3차 시안 A-1 최종 (2026-10-17 대표 확정, docs/lms/07-decisions.md D-34·D-35)
// 화면은 이 함수들의 결과만 그린다. 6시간 규칙 판정은 rules/change.ts 를 그대로 쓴다.
//
// - 재등록 안내: 남은 수업(정규·보강·보상·이월 + 날짜 미정 보강) 2회 이하일 때부터 마지막 수업이 있는 날(수강생 거주지 날짜)까지, 재등록 결제가 확인되면 숨김 (POL-RN-08, H26(92))
// - 할 일 알림: 수강생이 직접 처리해야 할 때만. '강사 확인 중' 같은 기다림은 넣지 않음
// - 결제: 수강권·기간·결제 방법·확인일만. 금액·카드 정보는 다루지 않음 (POL-PAY-11)
// - 적립금: 본인 지급·사용 날짜, 금액, 사유, 잔액 (POL-PAY-11, POL-PAY-09)

import { evaluateStudentChange, type ChangeDecision, type LessonKind } from '../rules/change';
import { formatInZone, instantToKstDate, type KstDate } from '../rules/dates';
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

/**
 * 아직 하지 않은 수업 = 예정 수업 중 시작 시각이 지금 이후. 시작 시각이 지난 수업은 Class Record 기록 전이어도 한 것으로 셈
 * (대시보드 '수강기간 종료 임박'과 같은 기준, 2026-10-27 대표 결정. 강사가 나중에 강사 사정 취소로 기록하면 보강으로 다시 생김)
 */
const notYet = (l: StudentLesson, now: Date) => l.state === 'scheduled' && l.startsAt.getTime() > now.getTime();

/** 아직 하지 않은 정규 수업 수 (화면 표시용 — 재등록 안내 기준은 보강·보상도 세는 lessonsLeft, POL-RN-08) */
export function regularLessonsLeft(lessons: readonly StudentLesson[], now: Date): number {
  return lessons.filter((l) => l.kind === 'regular' && notYet(l, now)).length;
}

/**
 * '남은 수업' 칸 = 예정된 수업(정규 + 보강 + 보상) + 아직 시간을 안 잡은 보강.
 * makeupsOwed: 정상 취소로 생긴 보강 중 아직 예정 수업이 아닌 것 (신청 중 포함)
 */
export function lessonsLeft(lessons: readonly StudentLesson[], now: Date, makeupsOwed = 0) {
  if (!Number.isInteger(makeupsOwed) || makeupsOwed < 0) throw new Error(`보강 수가 올바르지 않습니다: ${makeupsOwed}`);
  const scheduled = lessons.filter((l) => notYet(l, now));
  const other = scheduled.filter((l) => l.kind !== 'regular').length + makeupsOwed;
  return { total: scheduled.length + makeupsOwed, regular: regularLessonsLeft(lessons, now), other };
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
 * requested: 수강생이 재등록을 신청했지만 운영자가 결제를 아직 확인하지 않음 (아임웹·계좌이체는 자동 연동 아님, POL-PAY-11)
 */
export type RenewalState = 'not_requested' | 'requested' | 'payment_confirmed';

export type RenewalPrompt = null | { mode: 'request'; left: number } | { mode: 'awaiting_payment'; left: number };

/** timeZone: 수강생 거주지 시간대 — 남은 수업이 0회면 마지막 수업이 있는 날(그 시간대 날짜)이 지나면 숨김 (2026-11-07 대표) */
export function renewalPrompt(lessons: readonly StudentLesson[], renewal: RenewalState, now: Date, makeupsOwed = 0, timeZone = 'Asia/Seoul'): RenewalPrompt {
  const left = lessonsLeft(lessons, now, makeupsOwed).total;
  if (renewal === 'payment_confirmed') return null;
  if (left > RENEWAL_PROMPT.maxLessonsLeft) return null;
  if (left === 0) {
    const held = lessons.filter((l) => l.state !== 'canceled');
    const last = held.length ? new Date(Math.max(...held.map((l) => l.startsAt.getTime() + l.minutes * 60_000))) : null;
    if (last && formatInZone(now, timeZone).date > formatInZone(last, timeZone).date) return null;
  }
  return renewal === 'requested' ? { mode: 'awaiting_payment', left } : { mode: 'request', left };
}

/** 신청 진행 상태. 수강생이 기다리기만 하면 되는 단계는 할 일이 아님 */
/** rescheduling = 강사가 고른 날짜 모두 불가 → 운영진이 다른 날짜 조율 (QA-08) · canceled = 확정됐던 보강 수업이 취소됨 (QA-13) */
export type RequestStatus = 'tutor_reviewing' | 'admin_reviewing' | 'rescheduling' | 'confirmed' | 'canceled' | 'completed';

export type StudentRequest = {
  id: string;
  kind: 'makeup' | 'change';
  title: string;
  status: RequestStatus;
  /** 보강 신청: 수강생이 고른 후보 시각 */
  candidates: Date[];
  createdAt: Date;
  note: string;
  /** 강사 노쇼 무료 보상수업 신청 (4100) */
  compensation?: boolean;
  /** 원래 수업 시각·담당 강사, 확정된 날짜 (11/2 점검 ③) */
  originalAt?: Date | null;
  originalTimeKnown?: boolean;
  originalTutor?: string | null;
  tutor?: string | null;
  confirmedAt?: Date | null;
  /** 강사 메모 (모든 날짜 불가일 때 수강생에게는 보이지 않음 — 운영진이 조율) */
  tutorDeclinedAll?: boolean;
  /** 어느 권리(원래 수업·시트 보강·보상권)의 신청인지 — 휴무 안내 화면이 같은 상태를 보여 주기 위해 (R-17) */
  lessonId?: string | null;
  itemId?: string | null;
  compId?: string | null;
};

export const REQUEST_STATUS_LABEL: Record<RequestStatus, string> = {
  tutor_reviewing: '강사 확인 중',
  admin_reviewing: '최종 확정 대기',
  rescheduling: '다른 일정 조율 중',
  confirmed: '확정',
  canceled: '취소됨',
  completed: '처리 완료',
};

/** 수강생이 직접 처리해야 하는 일. 지금은 수업 안내 확인·동의뿐 (POL-OP-12). 규칙이 정해지면 종류를 추가 */
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

// ---------------------------------------------------------------------
// 변경권 기간 (R-12): 변경권은 28일 기간마다 따로 지급·차감된다. 미래 수업을 취소할 때는 '지금' 기간이 아니라
// 그 수업 날짜가 속한 기간의 잔여로 판정해야 DB(lms_lesson_period) 와 같다
// ---------------------------------------------------------------------
export type CreditPeriod = { start: KstDate; end: KstDate; granted: number; left: number };

/** 그 날짜가 속한 기간 (없으면 그 날짜 이전에 시작한 마지막 기간 — DB lms_lesson_period 와 같은 규칙), 아무 기간도 없으면 null */
export function creditPeriodFor(periods: readonly CreditPeriod[], date: KstDate): CreditPeriod | null {
  const hit = periods.find((p) => p.start <= date && date <= p.end);
  if (hit) return hit;
  const before = periods.filter((p) => p.start <= date).sort((a, b) => (a.start < b.start ? 1 : -1));
  return before[0] ?? null;
}

/** 그 날짜 수업의 변경권 잔여 (기간 목록이 없으면 fallback = 지금 기간 잔여) */
export function creditsForDate(periods: readonly CreditPeriod[] | undefined, date: KstDate, fallback: number): number {
  if (!periods || periods.length === 0) return fallback;
  return creditPeriodFor(periods, date)?.left ?? 0;
}

export type CancelPlanItem = { lesson: StudentLesson; decision: CancelPreview; /** 그 수업이 속한 기간 (없으면 null) */ period: CreditPeriod | null };
export type CancelPlan = {
  items: CancelPlanItem[];
  /** 변경권을 쓰는 수업 수 */
  uses: number;
  /** 보강 없이 수업 횟수가 차감되는 수 */
  consumes: number;
  /** 새로 생기는 보강 권리 수 */
  makeups: number;
  /** 취소할 수 없는 수업 수 */
  bad: number;
  /** 기간별 변경권 (차감 전 → 후). 기간 목록이 없으면 '지금' 하나 */
  periods: { start: KstDate | null; end: KstDate | null; before: number; after: number }[];
};

/**
 * 여러 수업 한 번에 취소 미리 보기 (추가 요청 2, R-12): 시간순으로 하나씩, 각 수업이 속한 기간의 잔여에서 차례로 차감.
 * DB 도 같은 순서·같은 기간 규칙으로 처리하므로 저장 결과와 같아야 한다
 */
export function planCancelMany(
  lessons: readonly StudentLesson[],
  input: { now: Date; finalEndDate: KstDate; creditsLeft: number; creditPeriods?: readonly CreditPeriod[]; holidays: ReadonlySet<KstDate> },
): CancelPlan {
  const sorted = [...lessons].sort((a, b) => +a.startsAt - +b.startsAt);
  const usePeriods = !!input.creditPeriods && input.creditPeriods.length > 0;
  const left = new Map<string, number>();   // 기간 시작일 → 남은 변경권 (차감하며 갱신)
  const order: { start: KstDate | null; end: KstDate | null; before: number }[] = [];
  const key = (p: CreditPeriod | null) => p?.start ?? '';
  const take = (p: CreditPeriod | null) => {
    const k = key(p);
    if (!left.has(k)) {
      const before = usePeriods ? (p?.left ?? 0) : input.creditsLeft;
      left.set(k, before);
      order.push({ start: p?.start ?? null, end: p?.end ?? null, before });
    }
    return left.get(k)!;
  };
  const items: CancelPlanItem[] = sorted.map((lesson) => {
    const date = instantToKstDate(lesson.startsAt);
    const period = usePeriods ? creditPeriodFor(input.creditPeriods!, date) : null;
    const credits = take(period);
    const decision = cancelPreview({ lesson, now: input.now, finalEndDate: input.finalEndDate, creditsLeft: credits, holidays: input.holidays }, null);
    if (decision.ok && decision.usesCredit) left.set(key(period), credits - 1);
    return { lesson, decision, period };
  });
  const ok = items.map((x) => x.decision).filter((d): d is ChangeDecision & { ok: true } => d.ok);
  return {
    items,
    uses: ok.filter((d) => d.usesCredit).length,
    consumes: ok.filter((d) => d.consumesLesson).length,
    makeups: ok.filter((d) => d.makeupAllowed).length,
    bad: items.length - ok.length,
    periods: order.map((o) => ({ ...o, after: left.get(o.start ?? '') ?? o.before })),
  };
}

/** 취소 저장 결과 한 건 (DB student_change_lesson / admin_change_lesson 반환) */
export type CancelResult = { uses_credit: boolean; makeup_allowed: boolean; credits_after?: number };

/**
 * 여러 수업 취소 완료 문구 (R-01): 미리 보기 예상이 아니라 저장된 결과로. 남은 변경권은 저장 뒤 다시 읽은 기간 잔여로
 * remaining: 취소한 수업들이 속한 기간의 '저장 뒤' 잔여 (기간이 하나면 그 값, 여럿이면 기간별로)
 */
export function cancelManySummary(done: readonly CancelResult[], remaining: { start: KstDate | null; left: number }[]): string {
  const credits = done.filter((r) => r.uses_credit).length;
  const makeups = done.filter((r) => r.makeup_allowed).length;
  const md = (d: KstDate) => `${Number(d.slice(5, 7))}/${Number(d.slice(8, 10))}`;
  const left = remaining.length === 0 ? '' : remaining.length === 1 ? ` · 남은 변경권 ${remaining[0].left}개` : ` · 남은 변경권 ${remaining.map((r) => `${r.start ? `${md(r.start)}~ ` : ''}${r.left}개`).join(', ')}`;
  return `수업 ${done.length}회를 취소했어요 · 변경권 ${credits}개 사용${left}${makeups ? ` · 보강 ${makeups}회는 ‘보강 신청’에서 날짜를 골라 주세요` : ''}`;
}
