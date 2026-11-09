// 재등록·보강 이월·적립금 — DB 함수 부르기 (migration 20261108050000~080000 · 20261109130000). 권한·검사·기록은 DB
import type { SupabaseClient } from '@supabase/supabase-js';
import type { KstDate } from '../rules/dates';
import type { Slot } from './students';
import { parseRenewalContext, parseRewards, type RenewalContext, type Rewards } from './renewal';

function check<T>(r: { data: T | null; error: { code?: string; message: string } | null }): T {
  if (r.error) {
    if (r.error.code === 'PGRST202' || r.error.code === '42883') throw new Error('이 기능이 아직 이 DB에 적용되지 않았어요 (migration 20261109130000).');
    if (r.error.code === '42501') throw new Error('운영자 추가 인증(TOTP)이 필요해요. 다시 로그인해 주세요.');
    throw new Error(r.error.message);
  }
  return r.data as T;
}
const uuid = () => crypto.randomUUID();

export async function loadRenewalContext(sb: SupabaseClient, studentId: string): Promise<RenewalContext> {
  return parseRenewalContext(check(await sb.rpc('admin_renewal_context', { p_student: studentId })));
}
export async function loadRewards(sb: SupabaseClient, studentId: string): Promise<Rewards> {
  return parseRewards(check(await sb.rpc('admin_student_rewards', { p_student: studentId })));
}
/** 정규 시간 겹침 미리 검사 → 겹치는 요일 (요일별 첫 날짜·까닭) */
export async function renewalConflicts(sb: SupabaseClient, studentId: string, slots: Slot[], start: KstDate, weeks: number, dur: number) {
  const j = check(await sb.rpc('admin_renewal_conflicts', { p_student: studentId, p_slots: slots, p_start: start, p_weeks: weeks, p_dur: dur })) as
    { date: KstDate; weekday: number; time: string; reason: string }[];
  return j ?? [];
}
export type RenewInput = {
  studentCode: string; weeks: number; weekly: number; dur: number; start: KstDate; slots: Slot[];
  method: 'bank_transfer' | 'card_link'; amount: number; paidOn: KstDate; payer: string;
};
export type RenewResult = { enrollmentId: string; seq: number; startDate: KstDate; endDate: KstDate; planId: string; planState: string; wait: string | null };
/** 재등록 + 정규 일정 확정 한 번에. 요청 번호는 창을 연 동안 같게 (두 번 눌러도 한 번) */
export async function saveRenewal(sb: SupabaseClient, ids: { request: string; plan: string }, x: RenewInput): Promise<RenewResult> {
  const r = check(await sb.rpc('admin_renew', {
    p_request_id: ids.request,
    p: {
      student_code: x.studentCode, plan_id: ids.plan, slots: x.slots,
      course: { weeks: x.weeks, weekly_count: x.weekly, duration_min: x.dur, start_date: x.start },
      payment: { method: x.method, amount: x.amount, paid_on: x.paidOn, payer_name: x.payer.trim() },
    },
  })) as { enrollment_id: string; seq: number; start_date: KstDate; end_date: KstDate; plan_id: string; plan_state: string; wait: string | null };
  return { enrollmentId: r.enrollment_id, seq: r.seq, startDate: r.start_date, endDate: r.end_date, planId: r.plan_id, planState: r.plan_state, wait: r.wait ?? null };
}
export async function confirmPlan(sb: SupabaseClient, planId: string): Promise<void> {
  check(await sb.rpc('admin_confirm_schedule', { p_plan_id: planId }));
}
/** 이월 줄 미리 검사 → 문제 있는 줄 {원래 날짜: 까닭} */
export async function carryCheck(sb: SupabaseClient, studentId: string, items: { originalDate: KstDate; startsAt: string | null }[]): Promise<Record<string, string>> {
  const j = check(await sb.rpc('admin_carry_check', { p_student: studentId, p_items: items.map((i) => ({ original_date: i.originalDate, starts_at: i.startsAt })) })) as
    { original_date: string; reason: string }[];
  return Object.fromEntries((j ?? []).map((x) => [x.original_date, x.reason]));
}
export async function saveCarry(sb: SupabaseClient, requestId: string, studentCode: string, items: { originalDate: KstDate; startsAt: string | null }[]): Promise<number> {
  const r = check(await sb.rpc('admin_carry_over_makeups', {
    p_request_id: requestId, p: { student_code: studentCode, items: items.map((i) => ({ original_date: i.originalDate, starts_at: i.startsAt })) },
  })) as { carried: number };
  return r.carried;
}
export async function saveReward(sb: SupabaseClient, requestId: string, studentId: string, amount: number, reason: string): Promise<{ after: number }> {
  const r = check(await sb.rpc('admin_reward_adjust', { p_request_id: requestId, p_student: studentId, p_amount: amount, p_reason: reason })) as { after: number };
  return { after: r.after };
}
export const newId = uuid;
