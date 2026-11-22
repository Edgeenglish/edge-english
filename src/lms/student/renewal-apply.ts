// 학생 재등록 신청 (대표 11/21 시안 확정, migration 20261121100000)
// 1단계 기간·적립금 [다음] = 저장(신청 완료 아님) → 2단계 결제 후 결제 방법·입금자명 [재등록 신청하기] = '재등록 신청 완료 · 입금 확인 중'
// → 운영진 [입금 확인됨] 뒤에야 새 수강권. 금액·검사·적립금 예약은 모두 DB 함수가 다시 함
import type { SupabaseClient } from '@supabase/supabase-js';
import type { KstDate } from '../rules/dates';

/** 재등록 메일(lms_renewal_mail)과 같은 결제 정보 — 바뀌면 두 곳 */
export const RENEWAL_PAY = {
  bank: '카카오뱅크 3333-27-7626253',
  holder: '이진솔(탠저린 영어)',
  card: 'https://tangerineenglish.imweb.me/?idx=11',
} as const;
export const KAKAO_CHANNEL = 'https://pf.kakao.com/_blxgib/friend';

export type RenewalWeeks = 4 | 12 | 24;
export type RenewalMethod = 'bank_transfer' | 'card_link';
export type RenewalStatus = 'draft' | 'submitted' | 'paid' | 'closed';
export type RenewalRequest = {
  id: string; status: RenewalStatus; weeks: RenewalWeeks; price: number; points: number;
  method: RenewalMethod | null; payerName: string | null; submittedAt: Date | null;
};
export type RenewalPlan = { weeks: RenewalWeeks; title: string; sub: string | null; price: number; perMonth: number | null; save: string | null; best: boolean };
export type RenewalInfo = {
  /** open = 신청 가능 · late = 수강권 기간 끝이 지남(문의) · renewed = 재등록 완료(다음 수강권 있음) · none = 대상 아님 */
  state: 'open' | 'late' | 'renewed' | 'none';
  durationMin: number; weeklyCount: number;
  /** 학생에게 보이는 '수강 종료일' = 보강·보상수업까지 포함한 마지막 수업 (대표 11/21). 없으면 null */
  lastLessonAt: Date | null;
  finalEndDate: KstDate | null;
  plans: RenewalPlan[];
  pointsBalance: number;
  request: RenewalRequest | null;
  next: { weeks: number | null; startDate: KstDate; finalEndDate: KstDate } | null;
};

const won = (n: number) => `${n.toLocaleString('ko-KR')}원`;

/* eslint-disable @typescript-eslint/no-explicit-any */
export function parsePlans(p: any): RenewalPlan[] {
  if (!p) return [];
  return [
    { weeks: 4, title: '1개월 (4주)', sub: null, price: Number(p.monthly), perMonth: null, save: null, best: false },
    { weeks: 12, title: '3개월 (12주)', sub: '5% 할인', price: Number(p.three.total), perMonth: Number(p.three.per_month), save: `→ ${won(Number(p.three.save))} 절약!`, best: true },
    { weeks: 24, title: '6개월 (24주)', sub: '최대 혜택', price: Number(p.six.total), perMonth: Number(p.six.per_month), save: `→ ${won(Number(p.six.save))} 절약 + Ebook 패키지 무료!`, best: true },
  ];
}
export function parseRequest(r: any): RenewalRequest | null {
  if (!r) return null;
  return {
    id: r.id, status: r.status, weeks: Number(r.weeks) as RenewalWeeks, price: Number(r.price), points: Number(r.points ?? 0),
    method: r.method ?? null, payerName: r.payer_name ?? null, submittedAt: r.submitted_at ? new Date(r.submitted_at) : null,
  };
}
export function parseRenewalInfo(j: any): RenewalInfo {
  return {
    state: j?.state ?? 'none',
    durationMin: Number(j?.duration_min ?? 0), weeklyCount: Number(j?.weekly_count ?? 0),
    lastLessonAt: j?.last_lesson_at ? new Date(j.last_lesson_at) : null,
    finalEndDate: j?.final_end_date ?? null,
    plans: parsePlans(j?.plans),
    pointsBalance: Number(j?.points_balance ?? 0),
    request: parseRequest(j?.request),
    next: j?.next ? { weeks: j.next.weeks ?? null, startDate: j.next.start_date, finalEndDate: j.next.final_end_date } : null,
  };
}
/* eslint-enable @typescript-eslint/no-explicit-any */

/** 쓸 수 있는 적립금 최대 = 보유와 고른 기간 금액 중 작은 것 */
export const maxPoints = (balance: number, price: number | null) => Math.max(0, Math.min(balance, price ?? balance));
/** 적립금 칸 글 → 원. 빈칸 = 0, 숫자·쉼표 말고 섞이면 null */
export function parsePoints(text: string): number | null {
  const t = text.trim();
  if (t === '') return 0;
  if (!/^[\d,]+$/.test(t)) return null;
  return Number(t.replace(/,/g, ''));
}
/** 계좌이체 = 정가 − 적립금, 카드 = 정가 (적립금은 계좌이체에만, 대표 11/21) */
export const bankAmount = (price: number, points: number) => price - points;

/** 홈 재등록 카드·신청 화면 상태 */
export type RenewalStage = 'none' | 'start' | 'draft' | 'submitted' | 'late' | 'renewed';
export function renewalStage(i: RenewalInfo | null): RenewalStage {
  if (!i || i.state === 'none') return 'none';
  if (i.state === 'renewed') return 'renewed';
  if (i.request?.status === 'submitted') return 'submitted';
  if (i.state === 'late') return 'late';
  return i.request?.status === 'draft' ? 'draft' : 'start';
}

export class RenewalError extends Error {
  constructor(message: string, readonly field: string | null) { super(message); }
}
function check<T>(r: { data: T | null; error: { code?: string; message: string; hint?: string | null } | null }): T {
  if (r.error) {
    if (r.error.code === 'PGRST202' || r.error.code === '42883') throw new RenewalError('이 기능이 아직 이 DB에 적용되지 않았어요.', null);
    throw new RenewalError(r.error.message, r.error.hint ?? null);
  }
  return r.data as T;
}

export function renewalActions(sb: SupabaseClient, studentId: string | null) {
  return {
    /** 함수가 없는 옛 DB 면 null (재등록 카드는 예전처럼) */
    info: async (): Promise<RenewalInfo | null> => {
      const r = await sb.rpc('student_renewal_info', { p_student: studentId });
      if (r.error) return null;
      return parseRenewalInfo(r.data);
    },
    save: async (weeks: RenewalWeeks, points: number): Promise<RenewalRequest> =>
      parseRequest(check(await sb.rpc('student_renewal_save', { p_student: studentId, p_weeks: weeks, p_points: points })))!,
    submit: async (requestId: string, method: RenewalMethod, payer: string): Promise<RenewalRequest> =>
      parseRequest(check(await sb.rpc('student_renewal_submit', { p_student: studentId, p_request: requestId, p_method: method, p_payer: payer })))!,
  };
}
export type RenewalActions = ReturnType<typeof renewalActions>;
