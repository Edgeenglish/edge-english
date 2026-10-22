// 신규 배정 확정: 시험용 Supabase 읽기·쓰기 (운영자 aal2 세션). 쓰기는 DB 함수로만 (POL-AC-07, migration 1000)

import type { SupabaseClient } from '@supabase/supabase-js';
import type { RegularSlot } from '../rules/schedule';
import type { Notice, NoticeStatus, PlanView } from './confirm';

type PlanRow = {
  id: string;
  enrollment_id: string;
  state: 'proposed' | 'confirmed';
  slots: RegularSlot[];
  start_date: string;
  proposal_sent_at: string | null;
  confirmed_at: string | null;
  tutor: { name: string; country: string | null; timezone: string } | null;
  enrollment: {
    base_end_date: string;
    lessons_purchased: number;
    duration_min: number;
    student: { name_en: string; country: string | null; city: string | null; timezone: string } | null;
  } | null;
  notices: { id: string; recipient_kind: 'student' | 'tutor'; status: NoticeStatus; sent_at: string | null }[];
};

const notice = (r: PlanRow, kind: 'student' | 'tutor'): Notice | null => {
  const n = r.notices.find((x) => x.recipient_kind === kind);
  return n ? { id: n.id, status: n.status, sentAt: n.sent_at ? new Date(n.sent_at) : null } : null;
};

export function toPlanView(r: PlanRow): PlanView {
  const st = r.enrollment?.student;
  return {
    planId: r.id,
    state: r.state,
    studentNameEn: st?.name_en ?? '',
    studentPlace: [st?.country, st?.city].filter(Boolean).join(' '),
    studentTz: st?.timezone ?? 'Asia/Seoul',
    tutorName: r.tutor?.name ?? '(강사)',
    tutorPlace: r.tutor?.country ?? '',
    tutorTz: r.tutor?.timezone ?? 'Asia/Seoul',
    slots: r.slots,
    startDate: r.start_date,
    endDate: r.enrollment?.base_end_date ?? r.start_date,
    lessons: r.enrollment?.lessons_purchased ?? 0,
    durationMin: r.enrollment?.duration_min ?? 50,
    proposalSentAt: r.proposal_sent_at ? new Date(r.proposal_sent_at) : null,
    confirmedAt: r.confirmed_at ? new Date(r.confirmed_at) : null,
    tutorNotice: notice(r, 'tutor'),
    studentNotice: notice(r, 'student'),
  };
}

/** 열린 신규 매칭 업무의 등록들에 걸린 일정안 (답 대기·확정). 등록 번호 → 일정안 */
export async function loadPlans(sb: SupabaseClient, enrollmentIds: string[]): Promise<Map<string, PlanView>> {
  const out = new Map<string, PlanView>();
  if (enrollmentIds.length === 0) return out;
  const { data, error } = await sb
    .from('schedule_plans')
    .select(
      'id, enrollment_id, state, slots, start_date, proposal_sent_at, confirmed_at, tutor:tutors(name, country, timezone), enrollment:enrollments(base_end_date, lessons_purchased, duration_min, student:students(name_en, country, city, timezone)), notices:schedule_notices(id, recipient_kind, status, sent_at)',
    )
    .in('enrollment_id', enrollmentIds)
    .in('state', ['proposed', 'confirmed']);
  // 시험용 DB에 migration 1000 적용 전이면 표가 없음 → 일정안 없이 보여 줌
  if (error) return out;
  for (const r of (data ?? []) as unknown as PlanRow[]) out.set(r.enrollment_id, toPlanView(r));
  return out;
}

async function call<T>(sb: SupabaseClient, fn: string, args: Record<string, unknown>): Promise<T> {
  const { data, error } = await sb.rpc(fn, args);
  if (error) {
    if (error.hint === 'schedule_conflict') throw new Error(`${error.message} 강사 일정이 그 사이 바뀌었어요. 다른 시간으로 다시 제안해 주세요.`);
    if (error.code === '42501') throw new Error('운영자 추가 인증(TOTP)이 필요해요. 다시 로그인해 주세요.');
    throw new Error(error.message);
  }
  return data as T;
}

export const planActions = (sb: SupabaseClient) => ({
  confirm: (planId: string) => call<{ tutor_notice_id: string; student_notice_id: string }>(sb, 'admin_confirm_schedule', { p_plan_id: planId }),
  decline: (planId: string) => call<unknown>(sb, 'admin_close_plan', { p_plan_id: planId, p_state: 'declined', p_reason: '강사가 안 된다고 함' }),
  proposalSent: (planId: string) => call<string>(sb, 'admin_mark_proposal_sent', { p_plan_id: planId }),
  noticeSent: (noticeId: string) => call<{ all_sent: boolean }>(sb, 'admin_mark_notice_sent', { p_notice_id: noticeId }),
});
export type PlanActions = ReturnType<typeof planActions>;

/** 강사·시간 고르기 화면: 등록 하나의 학생·상품 정보 */
export async function loadAssignInfo(sb: SupabaseClient, enrollmentId: string) {
  const { data, error } = await sb
    .from('enrollments')
    .select('id, weeks, weekly_count, duration_min, start_date, status, student:students(code, name_ko, name_en, country, city, timezone)')
    .eq('id', enrollmentId)
    .maybeSingle();
  if (error) throw new Error(error.message);
  if (!data) throw new Error('수강등록을 찾지 못했어요.');
  const r = data as unknown as {
    id: string;
    weeks: 4 | 12 | 24 | null;
    weekly_count: number;
    duration_min: number;
    start_date: string;
    status: string;
    student: { code: string; name_ko: string; name_en: string; country: string | null; city: string | null; timezone: string } | null;
  };
  if (!r.weeks) throw new Error('옛 상품 등록은 이 화면에서 고를 수 없어요.');
  if (r.status === 'pending_payment') throw new Error('결제 확인 전이라 강사·시간을 정할 수 없어요 (POL-OP-13).');
  return {
    enrollmentId: r.id,
    studentCode: r.student?.code ?? '',
    studentName: r.student?.name_ko ?? '(학생)',
    nameEn: r.student?.name_en ?? '',
    place: [r.student?.country, r.student?.city].filter(Boolean).join(' '),
    timezone: r.student?.timezone ?? 'Asia/Seoul',
    weeks: r.weeks,
    weeklyCount: r.weekly_count,
    durationMin: r.duration_min,
    startWish: r.start_date,
  };
}

/** 저장된 등록에 일정안 제안 (tutor_answer = 'accepted' 면 확정까지) */
export async function proposeSchedule(
  sb: SupabaseClient,
  enrollmentId: string,
  planId: string,
  p: { tutor_id: string; slots: RegularSlot[]; start_date: string; tutor_answer: 'accepted' | null },
) {
  const r = await call<{ plan_id: string; state: 'proposed' | 'confirmed'; tutor_notice_id?: string | null; student_notice_id?: string | null }>(sb, 'admin_propose_schedule', {
    p_plan_id: planId,
    p_enrollment: enrollmentId,
    p: { ...p, slots: p.slots.map((s) => ({ weekday: s.weekday, time: s.time })) },
  });
  return { planId: r.plan_id, state: r.state, tutorNoticeId: r.tutor_notice_id ?? null, studentNoticeId: r.student_notice_id ?? null };
}
