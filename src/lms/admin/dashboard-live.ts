// 운영진 대시보드 5차 — 강사 관리 · 공지 (시험용/운영 Supabase, 운영자 aal2 세션)
import type { SupabaseClient } from '@supabase/supabase-js';
import { instantToKstDate, type KstDate } from '../rules/dates';
import { toLessonItems, tutorItems, type Audience, type LessonItem, type LessonListRow, type Notice, type RegularRow, type TutorItem } from './dashboard';

/** 강사 목록 + 담당 학생 (정규 일정 기준) */
export async function loadTutors(sb: SupabaseClient, now: Date): Promise<TutorItem[]> {
  const today = instantToKstDate(now);
  const [t, r, e] = await Promise.all([
    sb.from('tutors').select('id, name, timezone, active, is_trial_account'),
    sb.from('regular_schedules').select('tutor_id, effective_to, student:students(id, code, name_ko, is_trial_account)'),
    sb.from('enrollments').select('student_id').not('status', 'in', '("completed","canceled")').gte('final_end_date', today),
  ]);
  const error = t.error ?? r.error ?? e.error;
  if (error) throw new Error(`강사 정보를 읽지 못했어요 (${error.code ?? error.message})`);
  return tutorItems(
    (t.data ?? []) as { id: string; name: string; timezone: string; active: boolean; is_trial_account?: boolean }[],
    (r.data ?? []) as unknown as RegularRow[],
    new Set((e.data ?? []).map((x) => x.student_id as string)),
    today,
  );
}

/** 그 강사의 다가오는 예정 수업 (최대 n개) */
export async function loadTutorUpcoming(sb: SupabaseClient, tutorId: string, now: Date, n = 8): Promise<LessonItem[]> {
  const { data, error } = await sb
    .from('lessons')
    .select('id, starts_at, kind, state, class_status, student:students(code, name_ko), tutor:tutors!lessons_tutor_id_fkey(name)')
    .eq('tutor_id', tutorId).eq('state', 'scheduled').gte('starts_at', now.toISOString()).order('starts_at').limit(n);
  if (error) throw new Error('수업을 읽지 못했어요.');
  return toLessonItems((data ?? []) as unknown as LessonListRow[]);
}

type NoticeRow = { id: string; audience: Audience; title: string; body: string; starts_on: string; ends_on: string; ended_at: string | null };
const toNotice = (r: NoticeRow): Notice => ({ id: r.id, audience: r.audience, title: r.title, body: r.body, startsOn: r.starts_on as KstDate, endsOn: r.ends_on as KstDate, endedAt: r.ended_at });

export async function loadNotices(sb: SupabaseClient): Promise<Notice[]> {
  const { data, error } = await sb.rpc('admin_announcements');
  if (error) throw new Error('공지를 읽지 못했어요.');
  return ((data ?? []) as NoticeRow[]).map(toNotice);
}

export async function saveNotice(sb: SupabaseClient, n: { id: string | null; audience: Audience; title: string; body: string; startsOn: string; endsOn: string }): Promise<void> {
  const { error } = await sb.rpc('admin_announcement_save', { p_id: n.id, p_audience: n.audience, p_title: n.title, p_body: n.body, p_starts: n.startsOn, p_ends: n.endsOn });
  if (error) throw new Error(error.message || '저장하지 못했어요.');
}

export async function endNotice(sb: SupabaseClient, id: string, end: boolean): Promise<void> {
  const { error } = await sb.rpc('admin_announcement_end', { p_id: id, p_end: end });
  if (error) throw new Error(error.message || '저장하지 못했어요.');
}

/** 학생·강사 홈: 게시 중인 공지 */
export async function loadLiveNotices(sb: SupabaseClient, who: 'student' | 'tutor'): Promise<{ id: string; title: string; body: string }[]> {
  const { data, error } = await sb.rpc('lms_announcements_live', { p_for: who });
  if (error) return [];
  return (data ?? []) as { id: string; title: string; body: string }[];
}
