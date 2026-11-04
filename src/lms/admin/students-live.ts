// 운영진 '학생' 메뉴 실제 데이터 (migration 4300). 읽기·쓰기 모두 DB 함수 — 권한(운영자 aal2)·검사·기록은 DB
import type { SupabaseClient } from '@supabase/supabase-js';
import type { KstDate } from '../rules/dates';
import { parseDetail, parsePreview, parseStudentRows, type RegularPreview, type Slot, type StudentDetailData, type StudentRow } from './students';

const NOT_APPLIED = '학생 관리 기능이 아직 이 DB에 적용되지 않았어요 (migration 4300).';
function check<T>(r: { data: T | null; error: { code?: string; message: string; hint?: string; details?: string } | null }): T {
  if (r.error) {
    if (r.error.code === 'PGRST202' || r.error.code === '42883' || r.error.code === '42703' || r.error.code === '42P01') throw new Error(NOT_APPLIED);
    if (r.error.code === '42501') throw new Error('운영자 추가 인증(TOTP)이 필요해요. 다시 로그인해 주세요.');
    throw new Error(r.error.message);
  }
  return r.data as T;
}

export async function loadStudents(sb: SupabaseClient): Promise<StudentRow[]> {
  const j = check(await sb.rpc('admin_students'));
  if (j === null) throw new Error('운영자 추가 인증(TOTP)이 필요해요. 다시 로그인해 주세요.');
  return parseStudentRows(j);
}
export async function loadStudentDetail(sb: SupabaseClient, studentId: string): Promise<StudentDetailData> {
  return parseDetail(check(await sb.rpc('admin_student_detail', { p_student: studentId })));
}
/** 학생 번호(STU-0001)로 id 찾기 — 상세 주소가 번호라서 */
export async function findStudentId(sb: SupabaseClient, code: string): Promise<string | null> {
  const r = await sb.from('students').select('id').eq('code', code).maybeSingle();
  if (r.error) throw new Error(r.error.message);
  return (r.data as { id: string } | null)?.id ?? null;
}
export async function updateStudent(sb: SupabaseClient, studentId: string, fields: Record<string, string | null>): Promise<number> {
  const r = check(await sb.rpc('admin_student_update', { p_student: studentId, p: fields })) as { changed: number };
  return r.changed;
}
export async function previewRegularChange(sb: SupabaseClient, studentId: string, slots: Slot[], from: KstDate): Promise<RegularPreview> {
  return parsePreview(check(await sb.rpc('admin_regular_change', { p_student: studentId, p_slots: slots, p_from: from, p_reason: null, p_dry_run: true })));
}
export async function saveRegularChange(sb: SupabaseClient, studentId: string, slots: Slot[], from: KstDate, reason: string): Promise<{ changeId: string; moved: number }> {
  const r = check(await sb.rpc('admin_regular_change', { p_student: studentId, p_slots: slots, p_from: from, p_reason: reason, p_dry_run: false })) as { change_id: string; moved: number };
  return { changeId: r.change_id, moved: r.moved };
}
export async function markRegularChangeSent(sb: SupabaseClient, changeId: string, who: 'student' | 'tutor', undo = false): Promise<void> {
  check(await sb.rpc('admin_regular_change_sent', { p_change: changeId, p_who: who, p_undo: undo }));
}
export async function extendEnrollment(sb: SupabaseClient, enrollmentId: string, newEnd: KstDate, kind: 'student_long_term_leave' | 'admin_exception' | 'correction', note: string): Promise<{ finalEndDate: KstDate; days: number }> {
  const r = check(await sb.rpc('admin_extend_enrollment', { p_enrollment: enrollmentId, p_new_end: newEnd, p_kind: kind, p_note: note })) as { final_end_date: KstDate; days: number };
  return { finalEndDate: r.final_end_date, days: r.days };
}

// ---- ⑤ 시트 Student Info 비교 (migration 4310) ----
import { parseSheetRows, type SheetRow } from './sheet-compare';
export async function loadSheetRows(sb: SupabaseClient): Promise<SheetRow[]> {
  const r = await sb.rpc('admin_sheet_rows');
  if (r.error?.code === 'PGRST202' || r.error?.code === '42883') throw new Error('시트 비교 기능이 아직 이 DB에 적용되지 않았어요 (migration 4310).');
  const j = check(r);
  if (j === null) throw new Error('운영자 추가 인증(TOTP)이 필요해요. 다시 로그인해 주세요.');
  return parseSheetRows(j);
}
export async function matchSheetRow(sb: SupabaseClient, rowId: string, studentId: string | null): Promise<void> {
  check(await sb.rpc('admin_sheet_row_match', { p_row: rowId, p_student: studentId }));
}
export async function doneSheetRow(sb: SupabaseClient, rowId: string, note: string, undo = false): Promise<void> {
  check(await sb.rpc('admin_sheet_row_done', { p_row: rowId, p_note: note, p_undo: undo }));
}
