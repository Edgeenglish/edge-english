// 기존 학생 간단 입력: 저장은 DB 함수 admin_import_existing_student 하나 (운영자 aal2, migration 1300)
import type { SupabaseClient } from '@supabase/supabase-js';
import type { importPayload } from './import';

export type ImportConflict = { date: string; time: string; kind: 'regular' | 'migrated_makeup'; reason: string; other: string | null };
export type ImportResult =
  | { kind: 'saved'; studentCode: string; lessons: number; makeups: number; repeated: boolean }
  | { kind: 'preview' }
  | { kind: 'error'; message: string; conflicts?: ImportConflict[] };

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
    if (error.code === 'PGRST202') return { kind: 'error', message: '기존 학생 입력 함수가 아직 이 DB에 적용되지 않았어요 (migration 1300).' };
    if (error.code === '42501') return { kind: 'error', message: '운영자 추가 인증(TOTP)이 필요해요. 다시 로그인해 주세요.' };
    return { kind: 'error', message: error.message };
  }
  const r = data as { student_code: string; lessons: number; makeups: number; repeated?: boolean };
  return { kind: 'saved', studentCode: r.student_code, lessons: r.lessons, makeups: r.makeups, repeated: !!r.repeated };
}
