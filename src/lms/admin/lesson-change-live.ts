// 수업 변경·보강 실제 데이터 (migration 1700). 읽기는 운영자 RLS, 쓰기는 DB 함수만 (판정·중복 방지·이력은 DB)

import type { SupabaseClient } from '@supabase/supabase-js';
import type { ClassStatus } from '../rules/status';
import type { ChangeDecision, ChChange, ChEnrollment, ChLesson, ChMakeupRequest, ChMigratedOpen, ChNotice, ChStudent } from './lesson-change';

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
};

type LessonRow = {
  id: string; kind: ChLesson['kind']; seq: number | null; starts_at: string; state: ChLesson['state']; class_status: ClassStatus | null;
  makeup_of: string | null; voided_at: string | null; tutor_id: string; tutor: { name: string; timezone: string } | null;
};

type MakeupRow = {
  id: string; source_lesson_id: string | null; migrated_item_id: string | null; status: ChMakeupRequest['status']; confirmed_lesson_id: string | null;
  tutor_note?: string | null; tutor_answered_at?: string | null; candidates: { starts_at: string; tutor_answer?: 'yes' | 'no' | null }[];
};
/** 강사 답 칸(migration 2000)이 없는 DB면 그 칸 없이 다시 읽음 */
async function loadMakeupRequests(sb: SupabaseClient, studentId: string) {
  const q = (cols: string) => sb.from('makeup_requests').select(cols).eq('student_id', studentId).order('created_at');
  const r = await q('id, source_lesson_id, migrated_item_id, status, confirmed_lesson_id, tutor_note, tutor_answered_at, candidates:makeup_candidates(starts_at, tutor_answer)');
  return r.error?.code === '42703' || r.error?.code === 'PGRST200'
    ? q('id, source_lesson_id, migrated_item_id, status, confirmed_lesson_id, candidates:makeup_candidates(starts_at)')
    : r;
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
  for (const [col, ids] of [['change_request_id', changeIds], ['makeup_request_id', mkIds]] as const) {
    if (ids.length === 0) continue;
    const rows = check(await sb.from('lesson_notices').select('id, change_request_id, makeup_request_id, event, recipient_kind, status, sent_at, created_at').in(col, ids)) as
      { id: string; change_request_id: string | null; makeup_request_id: string | null; event: ChNotice['event']; recipient_kind: 'student' | 'tutor'; status: ChNotice['status']; sent_at: string | null; created_at: string }[];
    notices.push(...rows.map((n) => ({
      id: n.id, changeRequestId: n.change_request_id, makeupRequestId: n.makeup_request_id, event: n.event, recipient: n.recipient_kind,
      status: n.status, sentAt: n.sent_at ? new Date(n.sent_at) : null, createdAt: new Date(n.created_at),
    })));
  }
  return {
    enrollment: e ? { id: e.id, finalEndDate: e.final_end_date, durationMin: e.duration_min } : null,
    lessons,
    changes: chRows.map((c) => ({ id: c.id, lessonId: c.lesson_id, type: c.type, status: c.status, requestedAt: c.requested_at ? new Date(c.requested_at) : null, decidedAt: new Date(c.decided_at), decision: c.decision })),
    makeupRequests: mkRows.map((m) => ({
      id: m.id, sourceLessonId: m.source_lesson_id, migratedItemId: m.migrated_item_id, status: m.status, confirmedLessonId: m.confirmed_lesson_id,
      candidates: m.candidates.map((c) => new Date(c.starts_at)).sort((a, b) => +a - +b),
      tutorAnswers: Object.fromEntries(m.candidates.filter((c) => c.tutor_answer).map((c) => [+new Date(c.starts_at), c.tutor_answer!])),
      tutorNote: m.tutor_note ?? null,
      tutorAnsweredAt: m.tutor_answered_at ? new Date(m.tutor_answered_at) : null,
    })),
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
export async function requestMakeup(sb: SupabaseClient, source: { lessonId?: string; itemId?: string }, slots: Date[]): Promise<void> {
  check(await sb.rpc('admin_makeup_request', {
    p_lesson: source.lessonId ?? null, p_item: source.itemId ?? null, p_slots: slots.map((t) => ({ starts_at: t.toISOString() })), p_requested_at: new Date().toISOString(),
  }));
}
export async function confirmMakeup(sb: SupabaseClient, requestId: string, at: Date): Promise<void> {
  check(await sb.rpc('admin_makeup_confirm', { p_makeup_request: requestId, p_starts_at: at.toISOString() }));
}
export async function withdrawMakeup(sb: SupabaseClient, requestId: string): Promise<void> {
  check(await sb.rpc('admin_makeup_withdraw', { p_makeup_request: requestId }));
}
export async function voidMakeup(sb: SupabaseClient, lessonId: string, note: string): Promise<void> {
  check(await sb.rpc('admin_void_makeup', { p_lesson: lessonId, p_note: note }));
}
export async function markLessonNoticeSent(sb: SupabaseClient, noticeId: string): Promise<void> {
  check(await sb.rpc('admin_mark_lesson_notice_sent', { p_notice: noticeId }));
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
