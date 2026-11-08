// 강사 화면 실제 데이터 (migration 2000). 읽기·쓰기 모두 DB 함수 — 본인 강사 확인·검사·이력은 DB

import type { SupabaseClient } from '@supabase/supabase-js';
import { parseHours, type HoursData } from './hours';
import { parseSchedule, type ScheduleAction, type ScheduleData } from './schedule';
import { parseCanceled, parseScreen, type Late, type TutorCanceled, type TutorResult, type TutorScreen } from './screen';
import { parseTutorProfile, type TutorStudentProfile } from './profile';
import { parseFollowup, parseFollowupTodos, type Followup, type FollowupTodo } from './followup';
import type { TutorStudentRow } from '@/app/lms/tutor/TutorHome';

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
/** 결과 + 지각 (4400). 인자 8개를 모두 보내야 DB 함수가 하나로 정해짐 */
export async function recordClass(sb: SupabaseClient, lessonId: string, result: TutorResult, topics: string, remarks: string, late: Late): Promise<void> {
  check(await sb.rpc('tutor_record_class', {
    p_lesson: lessonId, p_result: result, p_topics: topics, p_remarks: remarks,
    p_student_late: late.student, p_student_late_min: late.student ? late.studentMin : null, p_tutor_late: late.tutor, p_tutor_late_min: late.tutor ? late.tutorMin : null,
  }));
}
export async function answerMakeup(sb: SupabaseClient, requestId: string, yes: string[], note: string): Promise<void> {
  check(await sb.rpc('tutor_makeup_answer', { p_request: requestId, p_yes: yes, p_note: note }));
}

/** 보강 확정 (20261108000000, H26(82)): 학생이 보낸 시간 하나로 바로 보강 수업 */
export async function confirmMakeup(sb: SupabaseClient, requestId: string, slotId: string): Promise<void> {
  check(await sb.rpc('tutor_makeup_confirm', { p_request: requestId, p_candidate: slotId }));
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

const HOURS_NOT_APPLIED = 'My hours is not ready on this database yet (migration 3100).';
/** 가능 시간 고치기 (3100). tutorId: 운영자가 고른 강사 (강사 본인은 비움) */
export async function loadHours(sb: SupabaseClient, tutorId: string | null): Promise<HoursData> {
  const r = await sb.rpc('tutor_hours', { p_tutor: tutorId });
  if (r.error?.code === 'PGRST202' || r.error?.code === '42883') throw new Error(HOURS_NOT_APPLIED);
  return parseHours(check(r));
}
/** weekly = 바꾼 뒤 매주 열린 칸 전체 (안 바꾸면 null), close·open = 그 주만 닫을·다시 열 칸 */
export async function saveHours(sb: SupabaseClient, tutorId: string | null, weekly: string[] | null, close: string[], open: string[]): Promise<void> {
  check(await sb.rpc('tutor_hours_save', { p_tutor: tutorId, p_weekly: weekly, p_close: close, p_open: open }));
}

/** 학생 프로필 (4300): 담당 정규 강사·대체강사(열람만)·운영자. 자격은 DB 함수가 확인 (담당 아니면 42501) */
export async function loadStudentProfile(sb: SupabaseClient, studentId: string, tutorId: string | null = null): Promise<TutorStudentProfile> {
  // tutorId: 운영자가 고른 강사 (강사 본인은 비움) — 운영자 보기에서 그 강사의 시간대로 보이게 (QA-07, 4500). 4500 전 DB 는 한 인자 판으로
  let r = await sb.rpc('tutor_student_profile', tutorId ? { p_student: studentId, p_tutor: tutorId } : { p_student: studentId });
  if (tutorId && r.error?.code === 'PGRST202') r = await sb.rpc('tutor_student_profile', { p_student: studentId });
  if (r.error?.code === 'PGRST202' || r.error?.code === '42883') throw new Error('Student profiles are not ready on this database yet (migration 4300).');
  if (r.error?.code === '42501') throw new Error(r.error.message || 'This student is not assigned to you.');
  return parseTutorProfile(check(r));
}
/** 정규 담당 강사만: 레벨·자기소개·선호 (대체강사는 DB 가 거절) */
export async function updateStudentProfile(sb: SupabaseClient, studentId: string, fields: Record<string, string | null>): Promise<void> {
  const r = await sb.rpc('tutor_student_update', { p_student: studentId, p: fields });
  if (r.error?.code === '42501') throw new Error(r.error.message || "Only the student's regular tutor can edit this.");
  check(r);
}

/** Students 메뉴 (4402 tutor_students_list): 정규 담당 학생 + 확정된 대체수업 학생(수업 끝 24시간까지). 누가 보이는지는 DB 가 정함. tutorId: 운영자가 고른 강사 (강사 본인은 비움) */
export async function loadMyStudents(sb: SupabaseClient, tutorId: string | null): Promise<TutorStudentRow[]> {
  const rows = check(await sb.rpc('tutor_students_list', { p_tutor: tutorId })) as { student_id: string; display_name: string; level: string | null; class_type: string | null; timezone: string | null; class_note_url: string | null }[];
  return rows.map((r) => ({ id: r.student_id, name: r.display_name, level: r.level, classType: r.class_type, timezone: r.timezone, noteUrl: r.class_note_url }));
}

/** 취소된 수업 To-do (migration 20261108140000): 학생이 취소한 앞으로의 수업. 옛 DB 면 빈 목록 */
export async function loadCanceledClasses(sb: SupabaseClient, tutorId: string | null): Promise<TutorCanceled[]> {
  const r = await sb.rpc('tutor_canceled_classes', { p_tutor: tutorId });
  if (r.error?.code === 'PGRST202' || r.error?.code === '42883') return [];
  return parseCanceled(check(r));
}
/** 첫 수업 후 To-do (4600): Home 목록. tutorId: 운영자가 고른 강사 (강사 본인은 비움). 4600 전 DB 는 빈 목록 */
export async function loadFollowupTodos(sb: SupabaseClient, tutorId: string | null): Promise<FollowupTodo[]> {
  const r = await sb.rpc('tutor_first_lesson_todos', { p_tutor: tutorId });
  if (r.error?.code === 'PGRST202' || r.error?.code === '42883') return [];
  return parseFollowupTodos(check(r));
}
/** 첫 수업 후 입력 저장 (4600): level · improve · class_style · class_style_mix · textbook · materials_note. 완료 판정은 DB 가 돌려줌 */
export async function saveFollowup(sb: SupabaseClient, studentId: string, fields: Record<string, string | string[] | null>, tutorId: string | null): Promise<Followup | null> {
  const r = await sb.rpc('tutor_first_lesson_save', { p_student: studentId, p: fields, p_tutor: tutorId });
  if (r.error?.code === '42501') throw new Error(r.error.message || "Only the student's regular tutor can edit this.");
  return parseFollowup(check(r));
}

const SCHEDULE_NOT_APPLIED = 'Schedule is not ready on this database yet (migration 4403).';
/** Schedule (4403): 강사 현지 날짜 from~to, cells = Week 칸 판정도. tutorId: 운영자가 고른 강사 (강사 본인은 비움) */
export async function loadSchedule(sb: SupabaseClient, tutorId: string | null, from: string, to: string, cells: boolean): Promise<ScheduleData> {
  const r = await sb.rpc('tutor_schedule', { p_tutor: tutorId, p_from: from, p_to: to, p_cells: cells });
  if (r.error?.code === 'PGRST202' || r.error?.code === '42883') throw new Error(SCHEDULE_NOT_APPLIED);
  return parseSchedule(check(r));
}
/** 막기·그날만 열기(cells = 강사 현지 칸 키) · 메모 고치기·막기 풀기(blockId). 검사는 DB */
export async function saveSchedule(sb: SupabaseClient, tutorId: string | null, action: ScheduleAction, cells: string[] | null, note: string | null, blockId: string | null): Promise<void> {
  check(await sb.rpc('tutor_schedule_save', { p_tutor: tutorId, p_action: action, p_cells: cells, p_note: note, p_block: blockId }));
}
