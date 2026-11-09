// 수업 변경·보강 실제 데이터 (migration 1700). 읽기는 운영자 RLS, 쓰기는 DB 함수만 (판정·중복 방지·이력은 DB)

import type { SupabaseClient } from '@supabase/supabase-js';
import { compensationUseUntil } from '../rules/change';
import type { KstDate } from '../rules/dates';
import type { ClassStatus } from '../rules/status';
import type { ChangeDecision, ChChange, ChCompensation, ChEnrollment, ChLesson, ChMakeupRequest, ChMigratedOpen, ChNotice, ChStudent, MakeupLog, MakeupReason } from './lesson-change';

const NOT_APPLIED = '수업 변경 기능이 아직 이 DB에 적용되지 않았어요 (migration 1700).';

function friendly(error: { code?: string; message: string }): string {
  if (error.code === 'PGRST202' || error.code === '42P01' || error.code === '42703') return NOT_APPLIED;
  if (error.code === '42501') return '운영자 추가 인증(TOTP)이 필요해요. 다시 로그인해 주세요.';
  return error.message;
}
function check<T>(r: { data: T | null; error: { code?: string; message: string } | null }): T {
  if (r.error) throw new Error(friendly(r.error));
  return r.data as T;
}

export async function loadChangeStudents(sb: SupabaseClient): Promise<ChStudent[]> {
  const rows = check(await sb.from('students').select('id, code, name_ko, name_en, timezone').order('name_ko')) as
    { id: string; code: string; name_ko: string; name_en: string; timezone: string }[];
  return rows.map((s) => ({ id: s.id, code: s.code, nameKo: s.name_ko, nameEn: s.name_en, timezone: s.timezone }));
}

export type StudentLessonData = {
  enrollment: ChEnrollment | null;
  lessons: ChLesson[];
  changes: ChChange[];
  makeupRequests: ChMakeupRequest[];
  migrated: ChMigratedOpen[];
  notices: ChNotice[];
  /** 강사 노쇼 무료 보상수업 (4100 전 DB는 빈 목록) */
  compensations?: ChCompensation[];
};

type NoticeRow = {
  id: string; change_request_id: string | null; makeup_request_id: string | null; event: ChNotice['event']; recipient_kind: 'student' | 'tutor';
  status: ChNotice['status']; sent_at: string | null; created_at: string;
  email_status?: 'queued' | 'sent' | 'failed' | 'no_address' | null; email_to?: string | null; email_intended?: string | null;
  email_sent_at?: string | null; email_error?: string | null; email_attempts?: number | null;
};
type LessonRow = {
  id: string; kind: ChLesson['kind']; seq: number | null; starts_at: string; state: ChLesson['state']; class_status: ClassStatus | null;
  makeup_of: string | null; voided_at: string | null; tutor_id: string; tutor: { name: string; timezone: string } | null;
};

type MakeupRow = {
  id: string; source_lesson_id: string | null; migrated_item_id: string | null; status: ChMakeupRequest['status']; confirmed_lesson_id: string | null;
  tutor_note?: string | null; tutor_answered_at?: string | null; candidates: { starts_at: string; tutor_answer?: 'yes' | 'no' | null }[];
  compensation_id?: string | null;
  requested_at?: string | null; via?: string | null;
  confirmed_in_tutor_screen?: boolean;
};
/** 새 칸(보상권 4100, 강사 답 2000)이 없는 DB면 그 칸 없이 다시 읽음 */
async function loadMakeupRequests(sb: SupabaseClient, studentId: string) {
  const q = (cols: string) => sb.from('makeup_requests').select(cols).eq('student_id', studentId).order('created_at');
  const missing = (r: { error: { code?: string } | null }) => r.error?.code === '42703' || r.error?.code === 'PGRST200';
  // 강사 화면 확정 칸(20261108000000)이 없는 DB면 그 칸 없이
  let r = await q('id, source_lesson_id, migrated_item_id, compensation_id, status, requested_at, via, confirmed_lesson_id, confirmed_in_tutor_screen, tutor_note, tutor_answered_at, candidates:makeup_candidates(starts_at, tutor_answer)');
  if (missing(r)) r = await q('id, source_lesson_id, migrated_item_id, compensation_id, status, requested_at, via, confirmed_lesson_id, tutor_note, tutor_answered_at, candidates:makeup_candidates(starts_at, tutor_answer)');
  if (missing(r)) r = await q('id, source_lesson_id, migrated_item_id, status, requested_at, via, confirmed_lesson_id, tutor_note, tutor_answered_at, candidates:makeup_candidates(starts_at, tutor_answer)');
  if (missing(r)) r = await q('id, source_lesson_id, migrated_item_id, status, confirmed_lesson_id, candidates:makeup_candidates(starts_at)');
  return r;
}

/** 강사 노쇼 무료 보상수업과 사용 기한 (DB lms_comp_use_until 과 같은 판정: 종료일 23:59 KST까지 결제한 재등록이면 이월) */
async function loadCompensations(sb: SupabaseClient, studentId: string): Promise<ChCompensation[]> {
  const [c, en] = await Promise.all([
    sb.from('compensations').select('id, status, source_lesson_id, enrollment_id').eq('student_id', studentId),
    sb.from('enrollments').select('id, previous_enrollment_id, final_end_date, status, payments(paid_at)').eq('student_id', studentId),
  ]);
  if (c.error || en.error) return [];
  const rows = en.data as unknown as { id: string; previous_enrollment_id: string | null; final_end_date: KstDate; status: string; payments: { paid_at: string }[] | null }[];
  const until = (enrollmentId: string): KstDate => {
    const start = rows.find((e) => e.id === enrollmentId);
    if (!start) return '' as KstDate;
    const chain: { finalEnd: KstDate; paidAt: Date[] }[] = [];
    for (let cur = start, i = 0; i < 50; i++) {
      const next = rows.find((e) => e.previous_enrollment_id === cur.id && ['confirmed', 'active', 'completed'].includes(e.status));
      if (!next) break;
      chain.push({ finalEnd: next.final_end_date, paidAt: (next.payments ?? []).map((p) => new Date(p.paid_at)) });
      cur = next;
    }
    return compensationUseUntil(start.final_end_date, chain);
  };
  return (c.data as { id: string; status: ChCompensation['status']; source_lesson_id: string; enrollment_id: string }[])
    .map((x) => ({ id: x.id, status: x.status, sourceLessonId: x.source_lesson_id, useUntil: until(x.enrollment_id) }));
}

export async function loadStudentLessons(sb: SupabaseClient, studentId: string): Promise<StudentLessonData> {
  const enrolls = check(await sb.from('enrollments').select('id, final_end_date, duration_min, start_date').eq('student_id', studentId)
    .neq('status', 'canceled').order('start_date', { ascending: false }).limit(1)) as { id: string; final_end_date: string; duration_min: number }[];
  const e = enrolls[0];
  const lessonRows = check(await sb.from('lessons')
    .select('id, kind, seq, starts_at, state, class_status, makeup_of, voided_at, tutor_id, tutor:tutors!lessons_tutor_id_fkey(name, timezone)')
    .eq('student_id', studentId).order('starts_at')) as unknown as LessonRow[];
  const lessons: ChLesson[] = lessonRows.map((l) => ({
    id: l.id, kind: l.kind, seq: l.seq, startsAt: new Date(l.starts_at), state: l.state, classStatus: l.class_status, makeupOf: l.makeup_of,
    voided: !!l.voided_at, tutorId: l.tutor_id, tutorName: l.tutor?.name ?? '', tutorTz: l.tutor?.timezone ?? 'Asia/Seoul',
  }));
  const [changes, reqs, migrated] = await Promise.all([
    sb.from('change_requests').select('id, lesson_id, type, status, requested_at, decided_at, decision')
      .eq('student_id', studentId).in('type', ['student_cancel', 'tutor_cancel']).in('status', ['applied', 'reverted']).order('decided_at', { ascending: false }),
    loadMakeupRequests(sb, studentId),
    e ? sb.from('migrated_items').select('id, original_date, tutor_leave').eq('enrollment_id', e.id).eq('kind', 'makeup_open') : Promise.resolve({ data: [], error: null }),
  ]);
  const chRows = check(changes) as { id: string; lesson_id: string; type: ChChange['type']; status: ChChange['status']; requested_at: string | null; decided_at: string; decision: ChangeDecision }[];
  const mkRows = check(reqs) as unknown as MakeupRow[];
  const changeIds = chRows.map((c) => c.id);
  const mkIds = mkRows.map((m) => m.id);
  const notices: ChNotice[] = [];
  // 자동 메일 결과 맞추기 (20261108010000): 보낸 요청의 응답을 기록하고 못 보낸 큐를 다시 시도. 기능 전 DB·권한 오류면 그냥 넘어감
  await sb.rpc('admin_mail_sync').then(() => undefined, () => undefined);
  const base = 'id, change_request_id, makeup_request_id, event, recipient_kind, status, sent_at, created_at';
  const mail = ', email_status, email_to, email_intended, email_sent_at, email_error, email_attempts';
  for (const [col, ids] of [['change_request_id', changeIds], ['makeup_request_id', mkIds]] as const) {
    if (ids.length === 0) continue;
    let r: { data: unknown; error: { code?: string; message: string } | null } = await sb.from('lesson_notices').select(base + mail).in(col, ids);
    if (r.error?.code === '42703') r = await sb.from('lesson_notices').select(base).in(col, ids);   // 자동 메일 칸이 없는 DB
    const rows = check(r) as unknown as NoticeRow[];
    notices.push(...rows.map((n) => ({
      id: n.id, changeRequestId: n.change_request_id, makeupRequestId: n.makeup_request_id, event: n.event, recipient: n.recipient_kind,
      status: n.status, sentAt: n.sent_at ? new Date(n.sent_at) : null, createdAt: new Date(n.created_at),
      email: n.email_status ? {
        status: n.email_status, to: n.email_to ?? null, intended: n.email_intended ?? null, sentAt: n.email_sent_at ? new Date(n.email_sent_at) : null,
        error: n.email_error ?? null, attempts: n.email_attempts ?? 0,
      } : null,
    })));
  }
  return {
    enrollment: e ? { id: e.id, finalEndDate: e.final_end_date, durationMin: e.duration_min } : null,
    lessons,
    changes: chRows.map((c) => ({ id: c.id, lessonId: c.lesson_id, type: c.type, status: c.status, requestedAt: c.requested_at ? new Date(c.requested_at) : null, decidedAt: new Date(c.decided_at), decision: c.decision })),
    makeupRequests: mkRows.map((m) => ({
      id: m.id, sourceLessonId: m.source_lesson_id, migratedItemId: m.migrated_item_id, status: m.status, confirmedLessonId: m.confirmed_lesson_id,
      confirmedInTutorScreen: !!m.confirmed_in_tutor_screen,
      candidates: m.candidates.map((c) => new Date(c.starts_at)).sort((a, b) => +a - +b),
      tutorAnswers: Object.fromEntries(m.candidates.filter((c) => c.tutor_answer).map((c) => [+new Date(c.starts_at), c.tutor_answer!])),
      tutorNote: m.tutor_note ?? null,
      tutorAnsweredAt: m.tutor_answered_at ? new Date(m.tutor_answered_at) : null,
      compensationId: m.compensation_id ?? null,
      requestedAt: m.requested_at ? new Date(m.requested_at) : null,
      via: m.via ?? null,
    })),
    compensations: await loadCompensations(sb, studentId),
    migrated: (check(migrated) as { id: string; original_date: string | null; tutor_leave: boolean | null }[]).map((m) => ({ id: m.id, originalDate: m.original_date, tutorLeave: !!m.tutor_leave })),
    notices: notices.sort((a, b) => +a.createdAt - +b.createdAt),
  };
}

export async function changeLesson(sb: SupabaseClient, requestId: string, lessonId: string, who: 'student' | 'tutor', requestedAt: Date, dryRun: boolean): Promise<ChangeDecision> {
  return check(await sb.rpc('admin_change_lesson', { p_request_id: requestId, p_lesson: lessonId, p_who: who, p_requested_at: requestedAt.toISOString(), p_dry_run: dryRun }));
}
export async function revertChange(sb: SupabaseClient, changeId: string, note: string): Promise<void> {
  check(await sb.rpc('admin_revert_change', { p_change: changeId, p_note: note }));
}
/** compId = 강사 노쇼 무료 보상수업 (4100). 보상수업이 아니면 예전과 같은 인자 */
/** repeated = 같은 수업에 이미 열린 신청이 있어 새로 만들지 않음 (DB lms_makeup_request_core) */
export async function requestMakeup(sb: SupabaseClient, source: { lessonId?: string; itemId?: string; compId?: string }, slots: Date[]): Promise<{ repeated: boolean }> {
  const r = check(await sb.rpc('admin_makeup_request', {
    p_lesson: source.lessonId ?? null, p_item: source.itemId ?? null, p_slots: slots.map((t) => ({ starts_at: t.toISOString() })), p_requested_at: null,   // 신청 시각 = 서버 시각 (A-01 과 같은 이유: 기기 시계 차이)
    ...(source.compId ? { p_comp: source.compId } : {}),
  })) as { repeated?: boolean } | null;
  return { repeated: !!r?.repeated };
}
/** 이미 진행한 보강 기록 (지난 시각, 사유 필수) — 강사 '기록할 수업'에 뜸. migration 20261107050000 */
export async function recordPastMakeup(sb: SupabaseClient, source: { lessonId?: string; itemId?: string }, at: Date, note: string): Promise<void> {
  check(await sb.rpc('admin_makeup_record_past', { p_lesson: source.lessonId ?? null, p_item: source.itemId ?? null, p_starts_at: at.toISOString(), p_note: note }));
}
/** 운영진 확정 — 사유 필수(운영 기록, 운영진만 보임). migration 20261108120000 */
export async function confirmMakeup(sb: SupabaseClient, requestId: string, at: Date, reason: MakeupReason, note: string): Promise<void> {
  check(await sb.rpc('admin_makeup_confirm', { p_makeup_request: requestId, p_starts_at: at.toISOString(), p_reason: reason, p_note: note || null }));
}
/** 신청이 없을 때 신청 + 확정을 한 번에 (수강생·강사 화면에 바로 확정) */
export async function confirmMakeupNow(sb: SupabaseClient, source: { lessonId?: string; itemId?: string; compId?: string }, at: Date, reason: MakeupReason, note: string): Promise<void> {
  check(await sb.rpc('admin_makeup_confirm_now', {
    p_lesson: source.lessonId ?? null, p_item: source.itemId ?? null, p_comp: source.compId ?? null, p_starts_at: at.toISOString(), p_reason: reason, p_note: note || null,
  }));
}
/** 확정된 보강·보상수업 시간 고치기 — 변경권 차감 없음, 수강생·강사 '보강 시간 변경' 안내가 새로 생김 */
export async function rescheduleMakeup(sb: SupabaseClient, lessonId: string, at: Date, reason: MakeupReason, note: string): Promise<void> {
  check(await sb.rpc('admin_makeup_reschedule', { p_lesson: lessonId, p_starts_at: at.toISOString(), p_reason: reason, p_note: note || null }));
}
/** 운영 기록 (수강생별, 최근 순). 기능 전 DB 면 빈 목록 */
export async function loadMakeupLogs(sb: SupabaseClient, studentId: string): Promise<MakeupLog[]> {
  const r = await sb.rpc('admin_makeup_logs_for', { p_student: studentId });
  if (r.error?.code === 'PGRST202' || r.error?.code === '42883') return [];
  const rows = (check(r) ?? []) as { id: string; makeup_request_id: string; lesson_id: string | null; action: MakeupLog['action']; reason: MakeupLog['reason']; note: string | null; old_starts_at: string | null; new_starts_at: string; created_at: string; old_tutor?: string | null; old_tutor_tz?: string | null; new_tutor?: string | null }[];
  return rows.map((g) => ({
    id: g.id, makeupRequestId: g.makeup_request_id, lessonId: g.lesson_id, action: g.action, reason: g.reason, note: g.note,
    oldAt: g.old_starts_at ? new Date(g.old_starts_at) : null, newAt: new Date(g.new_starts_at), createdAt: new Date(g.created_at),
    oldTutor: g.old_tutor ?? null, oldTutorTz: g.old_tutor_tz ?? null, newTutor: g.new_tutor ?? null,
  }));
}
export async function withdrawMakeup(sb: SupabaseClient, requestId: string): Promise<void> {
  check(await sb.rpc('admin_makeup_withdraw', { p_makeup_request: requestId }));
}
export async function voidMakeup(sb: SupabaseClient, lessonId: string, note: string): Promise<void> {
  check(await sb.rpc('admin_void_makeup', { p_lesson: lessonId, p_note: note }));
}
/** 변경권 (4500): 지금 기간·지급·잔여·기록. period 가 null 이면 진행 중인 기간 없음 */
export type AdminCredits = {
  period: { id: string; idx: number; start: string; end: string } | null;
  granted: number;
  left: number;
  uses: { at: Date; reason: 'student_change' | 'admin_restore' | 'admin_adjust'; delta: number; note: string | null; lessonAt: Date | null }[];
};
export async function loadCredits(sb: SupabaseClient, studentId: string): Promise<AdminCredits | null> {
  const r = await sb.rpc('admin_credits', { p_student: studentId });
  if (r.error?.code === 'PGRST202' || r.error?.code === '42883') return null;   // 4500 전 DB
  const j = check(r) as { period: AdminCredits['period']; granted?: number; left?: number; uses?: { at: string; reason: AdminCredits['uses'][number]['reason']; delta: number; note: string | null; lesson_at: string | null }[] };
  return {
    period: j.period ?? null, granted: j.granted ?? 0, left: j.left ?? 0,
    uses: (j.uses ?? []).map((u) => ({ at: new Date(u.at), reason: u.reason, delta: u.delta, note: u.note, lessonAt: u.lesson_at ? new Date(u.lesson_at) : null })),
  };
}
/** 운영진 변경권 수동 조정 (4500): 한 번에 ±1, 사유 필수 — 이력은 DB(credit_ledger)에 남음 */
export async function adjustCredit(sb: SupabaseClient, studentId: string, delta: 1 | -1, reason: string): Promise<{ before: number; after: number }> {
  return check(await sb.rpc('admin_credit_adjust', { p_student: studentId, p_delta: delta, p_reason: reason }));
}
export async function markLessonNoticeSent(sb: SupabaseClient, noticeId: string): Promise<void> {
  check(await sb.rpc('admin_mark_lesson_notice_sent', { p_notice: noticeId }));
}
/** 자동 메일 다시 보내기 (실패·주소 없음만 새 요청, 보낸 것은 그대로) — 20261108010000 */
export async function resendNoticeEmail(sb: SupabaseClient, noticeId: string): Promise<{ status: string; error: string | null; repeated: boolean }> {
  const r = check(await sb.rpc('admin_resend_notice_email', { p_notice: noticeId })) as { status: string; error?: string | null; repeated: boolean };
  return { status: r.status, error: r.error ?? null, repeated: r.repeated };
}
/** 여러 안내를 한 묶음으로 '보냄' (3300): 보낸 시각이 같아 보낸 글 원문을 그대로 다시 보여 줄 수 있음 */
export async function markLessonNoticesSent(sb: SupabaseClient, noticeIds: string[]): Promise<void> {
  check(await sb.rpc('admin_mark_lesson_notices_sent', { p_notices: noticeIds }));
}

/** 대시보드: 안 보낸 수업 변경·보강 안내, 강사 답을 기다리는 보강 신청 */
export async function loadChangeTasks(sb: SupabaseClient): Promise<{ pendingNotices: number; openMakeups: number } | null> {
  const [n, m] = await Promise.all([
    sb.from('lesson_notices').select('id', { count: 'exact', head: true }).eq('status', 'pending'),
    sb.from('makeup_requests').select('id', { count: 'exact', head: true }).in('status', ['requested', 'countered']),
  ]);
  if (n.error) return null;   // 1700 적용 전 DB
  return { pendingNotices: n.count ?? 0, openMakeups: m.count ?? 0 };
}

/** 학생 상세 수업 관리 (20261109040000): 보강권·보상권 하나로 고른 강사·시간에 바로 확정. 메모는 선택 */
export async function addLessonByAdmin(sb: SupabaseClient, source: { lessonId?: string; itemId?: string; compId?: string }, tutorId: string, at: Date, note: string): Promise<void> {
  check(await sb.rpc('admin_lesson_add', {
    p_lesson: source.lessonId ?? null, p_item: source.itemId ?? null, p_comp: source.compId ?? null, p_tutor: tutorId, p_starts_at: at.toISOString(), p_note: note || null,
  }));
}
/** 확정된 보강·보상수업의 날짜·시간·강사 고치기 (같은 수업, 변경권·보강권 그대로) */
export async function editLessonByAdmin(sb: SupabaseClient, lessonId: string, tutorId: string, at: Date, note: string): Promise<void> {
  check(await sb.rpc('admin_lesson_edit', { p_lesson: lessonId, p_tutor: tutorId, p_starts_at: at.toISOString(), p_note: note || null }));
}
export type TutorPick = { id: string; name: string; timezone: string };
export async function loadActiveTutors(sb: SupabaseClient): Promise<TutorPick[]> {
  return (check(await sb.from('tutors').select('id, name, timezone').eq('active', true).order('name')) as TutorPick[]);
}
