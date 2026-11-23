// 학생 재등록 신청 — 운영진 쪽 (대표 11/21, migration 20261121100000)
// 학생 신청(입금 확인 중) → 운영진 [입금 확인됨] → 지금 재등록 창(기간·결제를 신청대로 채움) [저장] 때만 새 수강권
import type { SupabaseClient } from '@supabase/supabase-js';
import { instantToKstDate, type KstDate } from '../rules/dates';
import type { RenewInput, RenewResult } from './renewal-live';

export type AdminRenewalRequest = {
  id: string; status: 'draft' | 'submitted'; weeks: number; price: number; points: number;
  method: 'bank_transfer' | 'card_link' | null; payerName: string | null; submittedAt: Date | null; updatedAt: Date;
  studentId: string; studentCode: string; studentName: string; durationMin: number; weeklyCount: number;
  finalEndDate: KstDate; lastLessonAt: Date | null;
};

/* eslint-disable @typescript-eslint/no-explicit-any */
export function parseAdminRenewalRequests(j: any): AdminRenewalRequest[] {
  return ((j ?? []) as any[]).map((r) => ({
    id: r.id, status: r.status, weeks: Number(r.weeks), price: Number(r.price), points: Number(r.points ?? 0),
    method: r.method ?? null, payerName: r.payer_name ?? null, submittedAt: r.submitted_at ? new Date(r.submitted_at) : null,
    updatedAt: new Date(r.updated_at), studentId: r.student_id, studentCode: r.student_code, studentName: r.student_name ?? '',
    durationMin: Number(r.duration_min), weeklyCount: Number(r.weekly_count), finalEndDate: r.final_end_date,
    lastLessonAt: r.last_lesson_at ? new Date(r.last_lesson_at) : null,
  }));
}
/* eslint-enable @typescript-eslint/no-explicit-any */

/** 결제 금액: 계좌이체 = 정가 − 적립금, 카드 = 정가 */
export const requestAmount = (r: Pick<AdminRenewalRequest, 'price' | 'points'>, method: 'bank_transfer' | 'card_link') =>
  method === 'bank_transfer' ? r.price - r.points : r.price;
/** 재등록 창 결제일 기본값 = 학생이 신청한 한국 날짜 (오늘 뒤면 오늘) */
export const requestPaidOn = (r: Pick<AdminRenewalRequest, 'submittedAt'>, today: KstDate): KstDate | '' => {
  if (!r.submittedAt) return '';
  const d = instantToKstDate(r.submittedAt);
  return d > today ? today : d;
};
const PERIOD: Record<number, string> = { 4: '1개월(4주)', 12: '3개월(12주)', 24: '6개월(24주)' };
export const periodText = (weeks: number) => PERIOD[weeks] ?? `${weeks}주`;

function check<T>(r: { data: T | null; error: { code?: string; message: string } | null }): T {
  if (r.error) {
    if (r.error.code === '42501') throw new Error('운영자 추가 인증(TOTP)이 필요해요. 다시 로그인해 주세요.');
    throw new Error(r.error.message);
  }
  return r.data as T;
}

/** 열린 신청 전부. 함수가 없는 옛 DB 면 빈 목록 */
export async function loadRenewalRequests(sb: SupabaseClient): Promise<AdminRenewalRequest[]> {
  const r = await sb.rpc('admin_renewal_requests');
  if (r.error) return [];
  return parseAdminRenewalRequests(r.data);
}
export async function closeRenewalRequest(sb: SupabaseClient, id: string): Promise<void> {
  check(await sb.rpc('admin_renewal_request_close', { p_request: id, p_note: null }));
}
/** [입금 확인됨] 창 저장: noSchedule = '일정 미정' (정규 일정 없이 수강권·결제만) */
export async function confirmRenewalRequest(sb: SupabaseClient, requestId: string, ids: { request: string; plan: string }, x: RenewInput, noSchedule: boolean): Promise<RenewResult> {
  const r = check(await sb.rpc('admin_renewal_request_confirm', {
    p_request: requestId,
    p_request_id: ids.request,
    p: {
      student_code: x.studentCode, plan_id: ids.plan, slots: x.slots, no_schedule: noSchedule,
      course: { weeks: x.weeks, weekly_count: x.weekly, duration_min: x.dur, start_date: x.start },
      payment: { method: x.method, amount: x.amount, paid_on: x.paidOn, payer_name: x.payer.trim() },
    },
  })) as { enrollment_id: string; seq: number; start_date: KstDate; end_date: KstDate; plan_id?: string; plan_state?: string; wait?: string | null };
  return { enrollmentId: r.enrollment_id, seq: r.seq, startDate: r.start_date, endDate: r.end_date, planId: r.plan_id ?? '', planState: noSchedule ? 'none' : r.plan_state ?? '', wait: r.wait ?? null };
}
