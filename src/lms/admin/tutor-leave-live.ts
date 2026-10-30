// 강사 휴무·대체강사 실제 데이터 (migration 1800). 읽기는 운영자 RLS, 쓰기는 DB 함수만 (검사·중복 방지·이력은 DB)

import type { SupabaseClient } from '@supabase/supabase-js';
import { addDays, instantToKstDate, type KstDate } from '../rules/dates';
import type { LvChoice, LvItem, LvMakeupOption, LvNotice, LvRenewal, LvStage, LvSubOption, LvTimeOff } from './tutor-leave';

const NOT_APPLIED = '강사 휴무 기능이 아직 이 DB에 적용되지 않았어요 (migration 1800).';

function friendly(error: { code?: string; message: string }): string {
  if (error.code === 'PGRST202' || error.code === 'PGRST205' || error.code === '42P01' || error.code === '42703') return NOT_APPLIED;
  if (error.code === '42501') return '운영자 추가 인증(TOTP)이 필요해요. 다시 로그인해 주세요.';
  return error.message;
}
function check<T>(r: { data: T | null; error: { code?: string; message: string } | null }): T {
  if (r.error) throw new Error(friendly(r.error));
  return r.data as T;
}

export type LvTutor = { id: string; name: string; timezone: string };

export async function loadTutors(sb: SupabaseClient): Promise<LvTutor[]> {
  return check(await sb.from('tutors').select('id, name, timezone').eq('active', true).order('name')) as LvTutor[];
}

/** 끝난 지 7일 안 된 휴무 (최근 것부터) */
export async function loadLeaves(sb: SupabaseClient, now: Date): Promise<LvTimeOff[]> {
  const rows = check(await sb.from('tutor_time_off').select('id, tutor_id, starts_at, ends_at, reason, tutor:tutors(name)')
    .eq('kind', 'leave').gte('ends_at', new Date(now.getTime() - 7 * 86400000).toISOString()).order('starts_at', { ascending: false })) as unknown as
    { id: string; tutor_id: string; starts_at: string; ends_at: string; reason: string | null; tutor: { name: string } | null }[];
  return rows.map((r) => ({
    id: r.id, tutorId: r.tutor_id, tutorName: r.tutor?.name ?? '', reason: r.reason,
    from: instantToKstDate(new Date(r.starts_at)), to: addDays(instantToKstDate(new Date(r.ends_at)), -1),
  }));
}

type ItemRow = {
  id: string; time_off_id: string; student_id: string; lesson_id: string | null; migrated_item_id: string | null; starts_at: string;
  choice: LvChoice; sub_tutor_id: string | null; sub_stage: LvStage | null; lesson_gone_at: string | null;
  student: { name_ko: string; name_en: string; code: string; timezone: string } | null;
  enrollment: { duration_min: number } | null;
  sub: { name: string; timezone: string } | null;
};

export async function loadLeaveItems(sb: SupabaseClient, timeOffId: string): Promise<{ items: LvItem[]; notices: LvNotice[] }> {
  const rows = check(await sb.from('leave_items')
    .select('id, time_off_id, student_id, lesson_id, migrated_item_id, starts_at, choice, sub_tutor_id, sub_stage, lesson_gone_at, student:students(name_ko, name_en, code, timezone), enrollment:enrollments(duration_min), sub:tutors!leave_items_sub_tutor_id_fkey(name, timezone)')
    .eq('time_off_id', timeOffId).order('starts_at')) as unknown as ItemRow[];
  const lessonIds = rows.flatMap((r) => (r.lesson_id ? [r.lesson_id] : []));
  const migIds = rows.flatMap((r) => (r.migrated_item_id ? [r.migrated_item_id] : []));
  const ids = rows.map((r) => r.id);
  const [mk, mig, nt, rq] = await Promise.all([
    lessonIds.length ? sb.from('lessons').select('makeup_of, starts_at').in('makeup_of', lessonIds).neq('state', 'canceled') : Promise.resolve({ data: [], error: null }),
    migIds.length ? sb.from('migrated_items').select('id, lesson:lessons(starts_at)').in('id', migIds) : Promise.resolve({ data: [], error: null }),
    ids.length ? sb.from('lesson_notices').select('id, leave_item_id, event, recipient_kind, recipient_id, status, sent_at').in('leave_item_id', ids) : Promise.resolve({ data: [], error: null }),
    ids.length ? sb.from('makeup_requests').select('source_lesson_id, migrated_item_id').in('status', ['requested', 'countered']) : Promise.resolve({ data: [], error: null }),
  ]);
  const requested = new Set((check(rq) as { source_lesson_id: string | null; migrated_item_id: string | null }[]).map((r) => r.source_lesson_id ?? r.migrated_item_id));
  const makeupOf = new Map((check(mk) as { makeup_of: string; starts_at: string }[]).map((m) => [m.makeup_of, new Date(m.starts_at)]));
  const migLesson = new Map((check(mig) as unknown as { id: string; lesson: { starts_at: string } | null }[]).map((m) => [m.id, m.lesson ? new Date(m.lesson.starts_at) : null]));
  const items: LvItem[] = rows.map((r) => ({
    id: r.id, timeOffId: r.time_off_id, studentId: r.student_id,
    studentName: r.student?.name_ko ?? '', studentNameEn: r.student?.name_en ?? '', studentCode: r.student?.code ?? '', studentTz: r.student?.timezone ?? 'Asia/Seoul',
    durationMin: r.enrollment?.duration_min ?? 0, isLesson: !!r.lesson_id, startsAt: new Date(r.starts_at),
    choice: r.choice, subTutorId: r.sub_tutor_id, subTutorName: r.sub?.name ?? null, subTutorTz: r.sub?.timezone ?? null, subStage: r.sub_stage,
    makeupAt: r.choice !== 'wait' ? null : r.lesson_id ? makeupOf.get(r.lesson_id) ?? null : migLesson.get(r.migrated_item_id ?? '') ?? null,
    makeupRequested: requested.has(r.lesson_id ?? r.migrated_item_id),
    lessonId: r.lesson_id, migratedItemId: r.migrated_item_id, lessonGone: !!r.lesson_gone_at,
  }));
  const notices = (check(nt) as { id: string; leave_item_id: string; event: LvNotice['event']; recipient_kind: 'student' | 'tutor'; recipient_id: string; status: LvNotice['status']; sent_at: string | null }[])
    .map((n) => ({ id: n.id, itemId: n.leave_item_id, event: n.event, recipientKind: n.recipient_kind, recipientId: n.recipient_id, status: n.status, sentAt: n.sent_at ? new Date(n.sent_at) : null }));
  return { items, notices };
}

export type LeaveCreateResult = { dry_run: boolean; time_off_id?: string; lessons: number; items: number; students: number; existing?: number };

export async function createLeave(sb: SupabaseClient, tutorId: string, from: KstDate, to: KstDate, reason: string, dryRun: boolean): Promise<LeaveCreateResult> {
  return check(await sb.rpc('admin_leave_create', { p_tutor: tutorId, p_from: from, p_to: to, p_reason: reason, p_dry_run: dryRun }));
}
export async function chooseLeave(sb: SupabaseClient, itemIds: string[], choice: 'substitute' | 'wait', subTutorId: string | null): Promise<void> {
  check(await sb.rpc('admin_leave_choose', { p_items: itemIds, p_choice: choice, p_sub_tutor: subTutorId }));
}
export async function subTutorOk(sb: SupabaseClient, itemIds: string[]): Promise<void> {
  check(await sb.rpc('admin_leave_sub_ok', { p_items: itemIds }));
}
/** 이전 단계로: tutor_ok 확정 전 / asked 강사 답 전 / undecided 학생 답 전 */
export async function leaveBack(sb: SupabaseClient, itemIds: string[], to: 'undecided' | 'asked' | 'tutor_ok'): Promise<void> {
  check(await sb.rpc('admin_leave_back', { p_items: itemIds, p_to: to }));
}
/** 휴무 안내 '보냄' 되돌리기 (모든 날짜가 학생 답 전일 때만 — DB가 확인) */
export async function unsendNotices(sb: SupabaseClient, noticeIds: string[]): Promise<void> {
  check(await sb.rpc('admin_leave_notice_unsend', { p_notices: noticeIds }));
}
export async function studentOk(sb: SupabaseClient, itemIds: string[]): Promise<void> {
  check(await sb.rpc('admin_leave_student_ok', { p_items: itemIds }));
}
export async function subOptions(sb: SupabaseClient, itemIds: string[]): Promise<LvSubOption[]> {
  const [opt, off] = await Promise.all([sb.rpc('admin_leave_sub_options', { p_items: itemIds }), sb.rpc('admin_leave_sub_off_hours', { p_items: itemIds })]);
  const rows = check(opt) as { tutor_id: string; name: string; timezone: string; free: number; busy_dates: string[] }[];
  // 보통 시간 밖 날짜 (2700). 적용 전 DB면 빈 목록
  const hours = new Map(((off.error ? [] : off.data) as { tutor_id: string; off_hours: string[] }[]).map((r) => [r.tutor_id, r.off_hours]));
  return rows.map((r) => ({ tutorId: r.tutor_id, name: r.name, timezone: r.timezone, free: r.free, busyDates: r.busy_dates, offHours: hours.get(r.tutor_id) ?? [] }));
}

export async function makeupOptions(sb: SupabaseClient, itemIds: string[]): Promise<LvMakeupOption[]> {
  const rows = check(await sb.rpc('admin_leave_makeup_options', { p_items: itemIds })) as { section: LvMakeupOption['section']; starts_at: string }[];
  return rows.map((r) => ({ section: r.section, startsAt: new Date(r.starts_at) }));
}

/** 재등록 대기 학생: 재등록하면 이 휴무에 걸리는 날짜 (고정 시간을 맡아 두는 동안만) */
export async function loadRenewals(sb: SupabaseClient, timeOffId: string): Promise<LvRenewal[]> {
  const rows = check(await sb.rpc('admin_leave_renewal_pending', { p_time_off: timeOffId })) as
    { student_id: string; student_name: string; student_code: string; end_date: string; starts_at: string; duration_min: number }[];
  return rows.map((r) => ({ studentId: r.student_id, studentName: r.student_name, studentCode: r.student_code, endDate: r.end_date as KstDate, startsAt: new Date(r.starts_at), durationMin: r.duration_min }));
}
