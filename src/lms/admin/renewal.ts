// 재등록·보강 이월·적립금 운영자 화면 (시안 5차 승인 + 대표 11/9 수정 4가지, migration 20261109130000)
// 계산·읽기 모양만. 저장·검사는 DB 함수(admin_renew · admin_carry_over_makeups · admin_reward_adjust)가 다시 함
import { addDays, weekdayOf, type KstDate } from '../rules/dates';
import type { Slot } from './students';

export type RenewalContext = {
  prev: {
    id: string; seq: number; weeks: number | null; legacyLabel: string | null; weeklyCount: number; durationMin: number;
    finalEndDate: KstDate; leftRegular: number; lastAmount: number | null; lastMethod: string | null;
  } | null;
  next: {
    id: string; seq: number; weeks: number; weeklyCount: number; durationMin: number; startDate: KstDate; finalEndDate: KstDate;
    carriedIn: number; paidOn: KstDate | null; method: string | null; planConfirmed: boolean; planProposed: string | null;
  } | null;
  tutor: { id: string; name: string; timezone: string } | null;
  slots: Slot[];
  carryOk: boolean;
  carry: CarryItem[];
};
export type CarryItem = { originalDate: KstDate; from: 'sheet' | 'lms'; tutorLeave: boolean };

/* eslint-disable @typescript-eslint/no-explicit-any */
export function parseRenewalContext(j: any): RenewalContext {
  const p = j?.prev;
  const n = j?.next;
  return {
    prev: p ? {
      id: p.id, seq: p.seq, weeks: p.weeks, legacyLabel: p.legacy_label, weeklyCount: p.weekly_count, durationMin: p.duration_min,
      finalEndDate: p.final_end_date, leftRegular: Number(p.left_regular ?? 0), lastAmount: p.last_amount ?? null, lastMethod: p.last_method ?? null,
    } : null,
    next: n ? {
      id: n.id, seq: n.seq, weeks: n.weeks, weeklyCount: n.weekly_count, durationMin: n.duration_min, startDate: n.start_date, finalEndDate: n.final_end_date,
      carriedIn: n.carried_in ?? 0, paidOn: n.paid_on ?? null, method: n.method ?? null, planConfirmed: !!n.plan_confirmed, planProposed: n.plan_proposed ?? null,
    } : null,
    tutor: j?.tutor ?? null,
    slots: ((j?.slots ?? []) as any[]).map((s) => ({ weekday: Number(s.weekday), time: String(s.time) })),
    carryOk: !!j?.carry_ok,
    carry: ((j?.carry ?? []) as any[]).map((c) => ({ originalDate: c.original_date, from: c.from === 'lms' ? 'lms' : 'sheet', tutorLeave: !!c.tutor_leave })),
  };
}

export type RewardRow = { id: string; at: Date; kind: string; amount: number; note: string | null };
export type Rewards = { balance: number; rows: RewardRow[] };
export function parseRewards(j: any): Rewards {
  return {
    balance: Number(j?.balance ?? 0),
    rows: ((j?.rows ?? []) as any[]).map((r) => ({ id: r.id, at: new Date(r.at), kind: r.kind, amount: Number(r.amount), note: r.note ?? null })),
  };
}
/* eslint-enable @typescript-eslint/no-explicit-any */

/** 학생 화면과 같은 사유 글 (student/live.ts POINT_REASON 과 같게: 적은 사유가 있으면 그대로) */
const REWARD_KIND: Record<string, string> = {
  grant_tutor_late_cancel: '강사 사정 취소 보상 (시작 6시간 이내)',
  grant_admin: '적립금 지급',
  hold: '재등록 결제에 사용',
  release: '결제 취소로 돌아옴',
  refund_restore: '환불로 돌아옴',
  admin_adjust: '적립금 조정',
};
export const rewardReason = (r: Pick<RewardRow, 'kind' | 'note'>) => r.note || REWARD_KIND[r.kind] || '적립금';

/** 수강 기간 끝 (28일 × 4주 단위) */
export const endOfCourse = (start: KstDate, weeks: number): KstDate => addDays(start, (weeks / 4) * 28 - 1);

/** 지난 종료일 다음 날부터 첫 정규 수업일 (요일이 하나도 없으면 '') */
export function firstLessonAfter(prevEnd: KstDate, slots: readonly Slot[]): KstDate | '' {
  const days = new Set(slots.map((s) => s.weekday));
  for (let i = 1; i <= 7; i++) {
    const d = addDays(prevEnd, i);
    if (days.has(weekdayOf(d))) return d;
  }
  return '';
}

/** 28일마다 변경권 (주1회 1·주2회 2·주3회 이상 3 — admin_register_renewal 과 같음) */
export const creditsPerPeriod = (weekly: number) => (weekly === 1 ? 1 : weekly === 2 ? 2 : 3);

/** 마감 판정 (POL-RN-01): 결제일이 지난 종료일과 같거나 앞이면 이월 가능 (종료일 오후 11:59 KST 안) */
export const paidInTime = (paidOn: KstDate | '' | null, prevEnd: KstDate) => !!paidOn && paidOn <= prevEnd;

export type RenewDraft = {
  weeks: number; weekly: number; dur: number; prodOpen: boolean;
  slots: Slot[]; start: KstDate | ''; manual: boolean;
  method: 'bank_transfer' | 'card_link'; amount: string; paidOn: KstDate | ''; payer: string;
};

/** 저장 막는 까닭 (화면 버튼 글). 없으면 '' — 순서는 화면 위에서 아래 */
export function renewBlock(d: RenewDraft, prevEnd: KstDate, conflictCount: number, today: KstDate): string {
  const dup = d.slots.some((s, i) => d.slots.findIndex((x) => x.weekday === s.weekday) !== i);
  const amt = Number(d.amount.replace(/\D/g, '')) || 0;
  if (d.slots.length !== d.weekly) return `요일 ${d.weekly}개를 맞춰 주세요`;
  if (dup) return '같은 요일이 두 번 있어요';
  if (d.slots.some((s) => !/^\d\d:\d\d$/.test(s.time))) return '시간을 골라 주세요';
  if (conflictCount > 0) return '겹치는 시간을 바꿔 주세요';
  const start = d.start;
  if (!start || start <= prevEnd) return '시작일을 골라 주세요';
  if (!d.slots.some((s) => s.weekday === weekdayOf(start))) return '시작일을 정규 요일로 맞춰 주세요';
  if (amt <= 0) return '받은 금액을 넣어 주세요';
  if (!d.paidOn) return `${d.method === 'card_link' ? '결제일' : '입금 날짜'}를 넣어 주세요`;
  if (d.paidOn > today) return '오늘 뒤 날짜는 넣을 수 없어요';
  return '';
}
