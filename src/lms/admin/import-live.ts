// 기존 학생 입력: 저장은 DB 함수 admin_import_existing_student 하나 (운영자 aal2, migration 1300 → 확대 1500)
// 시트 대조 완료·보강 원래 날짜 정리도 DB 함수로만 (admin_import_mark_checked · admin_import_set_origin)
import type { SupabaseClient } from '@supabase/supabase-js';
import type { importPayload } from './import';

export type ImportConflict = { date: string; time: string; kind: 'regular' | 'migrated_makeup' | 'migrated_extra'; reason: string; other: string | null };
export type ImportSaved = {
  kind: 'saved';
  studentCode: string;
  enrollmentId: string;
  lessons: number;
  makeups: number;
  openMakeups: number;
  extras: number;
  lmsLeft: number;
  sheetLeft: number;
  repeated: boolean;
};
export type ImportResult = ImportSaved | { kind: 'preview' } | { kind: 'error'; message: string; conflicts?: ImportConflict[] };

const NOT_APPLIED = '기존 학생 입력 확대 기능이 아직 이 DB에 적용되지 않았어요 (migration 1500).';

function friendly(error: { code?: string; message: string }): string {
  if (error.code === 'PGRST202') return NOT_APPLIED;
  if (error.code === '42501') return '운영자 추가 인증(TOTP)이 필요해요. 다시 로그인해 주세요.';
  return error.message;
}

export async function saveImport(sb: SupabaseClient, requestId: string, payload: ReturnType<typeof importPayload>): Promise<ImportResult> {
  const { data, error } = await sb.rpc('admin_import_existing_student', { p_request_id: requestId, p: payload });
  if (error) {
    if (error.hint === 'schedule_conflict') {
      let conflicts: ImportConflict[] = [];
      try {
        conflicts = JSON.parse(error.details ?? '[]');
      } catch {
        /* 상세를 못 읽어도 메시지는 보여 줌 */
      }
      return { kind: 'error', message: error.message, conflicts };
    }
    return { kind: 'error', message: friendly(error) };
  }
  const r = data as {
    student_code: string; enrollment_id: string; lessons: number; makeups: number;
    open_makeups?: number; extras?: number; lms_left?: number; sheet_left?: number; repeated?: boolean;
  };
  // 1300만 적용된 DB는 새 칸을 모르고 저장함 → 확대판 기록이 빠지므로 알려 줌
  if (r.lms_left === undefined) return { kind: 'error', message: `${NOT_APPLIED} 저장된 ${r.student_code}는 시트 대조 기록이 없어요. Claude에게 알려 주세요.` };
  return {
    kind: 'saved', studentCode: r.student_code, enrollmentId: r.enrollment_id, lessons: r.lessons, makeups: r.makeups,
    openMakeups: r.open_makeups ?? 0, extras: r.extras ?? 0, lmsLeft: r.lms_left, sheetLeft: r.sheet_left ?? 0, repeated: !!r.repeated,
  };
}

/** 시트와 대조 완료 (확인 시각·담당자 기록, 이미 완료면 그대로) */
export async function markImportChecked(sb: SupabaseClient, enrollmentId: string): Promise<void> {
  const { error } = await sb.rpc('admin_import_mark_checked', { p_enrollment: enrollmentId });
  if (error) throw new Error(friendly(error));
}

/** 보강 원래 날짜 '확인 필요' 정리: 날짜를 찾았으면 넣고, 끝내 알 수 없으면 null ('확인 불가') */
export async function setImportOrigin(sb: SupabaseClient, itemId: string, date: string | null): Promise<void> {
  const { error } = await sb.rpc('admin_import_set_origin', { p_item: itemId, p_date: date });
  if (error) throw new Error(friendly(error));
}
