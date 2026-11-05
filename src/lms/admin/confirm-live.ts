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

/** 기존 배정이 있는 신규 매칭 (R-10, 4520): 일정안 없이 강사·정규 수업이 이미 있는 등록의 지금 배정 */
export type MatchingCurrent = {
  task: { id: string; status: 'open' | 'done' | 'canceled'; tutorAssignedAt: Date | null; studentNotifiedAt: Date | null } | null;
  plan: { id: string; state: 'proposed' | 'confirmed' } | null;
  tutor: { id: string; name: string; timezone: string } | null;
  slots: RegularSlot[];
  scheduled: number;
  /** 앞으로 수업 / 지난 미기록(시작했지만 Class Record 전) / 끝난 수업 (R-22, 4530) */
  upcoming: number;
  pastUnrecorded: number;
  doneCount: number;
  /** 다음 수업(앞으로 첫 수업) / 이 등록의 첫 수업(지난 것 포함) */
  nextAt: Date | null;
  firstAt: Date | null;
  startDate: string;
  finalEndDate: string;
  durationMin: number;
  weeklyCount: number;
  lessonsTotal: number;
};
export async function loadMatchingCurrent(sb: SupabaseClient, enrollmentId: string): Promise<MatchingCurrent | null> {
  const { data, error } = await sb.rpc('admin_matching_current', { p_enrollment: enrollmentId });
  if (error) return null;   // 4520 전 DB 면 함수가 없음 → 기존 흐름(새 배정)으로
  const r = data as {
    task: { id: string; status: 'open' | 'done' | 'canceled'; tutor_assigned_at: string | null; student_notified_at: string | null } | null;
    plan: { id: string; state: 'proposed' | 'confirmed' } | null;
    tutor: { id: string; name: string; timezone: string } | null;
    slots: { weekday: number; time: string }[]; scheduled: number; first_at: string | null;
    upcoming?: number; past_unrecorded?: number; done_count?: number; next_at?: string | null;
    start_date: string; final_end_date: string; duration_min: number; weekly_count: number; lessons_total: number;
  };
  return {
    task: r.task ? { id: r.task.id, status: r.task.status, tutorAssignedAt: r.task.tutor_assigned_at ? new Date(r.task.tutor_assigned_at) : null, studentNotifiedAt: r.task.student_notified_at ? new Date(r.task.student_notified_at) : null } : null,
    plan: r.plan,
    tutor: r.tutor,
    slots: (r.slots ?? []).map((s) => ({ weekday: s.weekday, time: s.time })),
    scheduled: r.scheduled,
    upcoming: r.upcoming ?? r.scheduled,
    pastUnrecorded: r.past_unrecorded ?? 0,
    doneCount: r.done_count ?? 0,
    nextAt: r.next_at ? new Date(r.next_at) : null,
    firstAt: r.first_at ? new Date(r.first_at) : null,
    startDate: r.start_date, finalEndDate: r.final_end_date, durationMin: r.duration_min, weeklyCount: r.weekly_count, lessonsTotal: r.lessons_total,
  };
}
/** '수업 컨펌 완료' 기록 (R-10): 지금 배정을 강사·학생에게 확인했음 → 신규 매칭 업무 완료 */
export const markMatchingNotified = (sb: SupabaseClient, enrollmentId: string) =>
  call<{ task_id: string; repeated: boolean; student_notified_at: string }>(sb, 'admin_matching_notified', { p_enrollment: enrollmentId });
