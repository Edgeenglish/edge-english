// 강사 화면 실제 데이터 (migration 2000). 읽기·쓰기 모두 DB 함수 — 본인 강사 확인·검사·이력은 DB

import type { SupabaseClient } from '@supabase/supabase-js';
import { parseScreen, type TutorResult, type TutorScreen } from './screen';

const NOT_APPLIED = 'The tutor page is not ready on this database yet (migration 2000).';

function check<T>(r: { data: T | null; error: { code?: string; message: string } | null }): T {
  if (r.error) {
    if (r.error.code === 'PGRST202' || r.error.code === '42883' || r.error.code === '42703') throw new Error(NOT_APPLIED);
    throw new Error(r.error.message);
  }
  return r.data as T;
}

/** tutorId: 운영자가 고른 강사 (강사 본인은 비움) */
export async function loadTutorScreen(sb: SupabaseClient, tutorId: string | null, kstFrom: string, kstTo: string): Promise<TutorScreen> {
  return parseScreen(check(await sb.rpc('tutor_screen', { p_tutor: tutorId, p_from: kstFrom, p_to: kstTo })));
}
export async function recordClass(sb: SupabaseClient, lessonId: string, result: TutorResult, topics: string, remarks: string): Promise<void> {
  check(await sb.rpc('tutor_record_class', { p_lesson: lessonId, p_result: result, p_topics: topics, p_remarks: remarks }));
}
export async function answerMakeup(sb: SupabaseClient, requestId: string, yes: string[], note: string): Promise<void> {
  check(await sb.rpc('tutor_makeup_answer', { p_request: requestId, p_yes: yes, p_note: note }));
}

/** 대체 수업 요청 답 (2600): items = 이번에 답하는 수업 전체, yes = 그중 가능한 수업 */
export async function answerCover(sb: SupabaseClient, items: string[], yes: string[]): Promise<void> {
  check(await sb.rpc('tutor_sub_answer', { p_items: items, p_yes: yes }));
}

export type TutorAccount = { id: string; name: string; timezone: string; active: boolean; hasLogin: boolean };
/** 운영자: 강사 화면을 열 강사 목록 */
export async function loadTutorAccounts(sb: SupabaseClient): Promise<TutorAccount[]> {
  const rows = check(await sb.rpc('admin_tutor_accounts')) as { tutor_id: string; name: string; timezone: string; active: boolean; has_login: boolean }[];
  return rows.map((r) => ({ id: r.tutor_id, name: r.name, timezone: r.timezone, active: r.active, hasLogin: r.has_login }));
}

export type MissingRecord = { lessonId: string; tutorId: string; tutorName: string; studentName: string; studentCode: string; startsAt: Date };
/** 운영자 대시보드: 강사 LMS 계정이 있는 강사의 Class Record 미기록 (끝나고 10분 지남, POL-TU-06). 2000 적용 전 DB면 null */
export async function loadMissingRecords(sb: SupabaseClient): Promise<MissingRecord[] | null> {
  const r = await sb.rpc('admin_class_record_missing');
  if (r.error) return null;
  return (r.data as { lesson_id: string; tutor_id: string; tutor_name: string; student_name: string; student_code: string; starts_at: string }[]).map((x) => ({
    lessonId: x.lesson_id, tutorId: x.tutor_id, tutorName: x.tutor_name, studentName: x.student_name, studentCode: x.student_code, startsAt: new Date(x.starts_at),
  }));
}

/** 대표: 강사 로그인 계정 만들기 + 강사 연결 (migration 2100). 이미 같은 이메일로 연결돼 있으면 그대로 */
export async function createTutorLogin(sb: SupabaseClient, tutorId: string, email: string): Promise<{ created: boolean }> {
  const rows = check(await sb.rpc('admin_tutor_login', { p_tutor: tutorId, p_email: email })) as { created: boolean }[];
  return { created: rows[0]?.created ?? false };
}
