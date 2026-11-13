// 화면 보기 설정(처리 내역 정렬 · 강사 KST 칸 · Paid 칸)을 학생·강사 계정에 저장 (대표 11/13 A안, migration 20261113080000)
// - 학생·강사 본인이 누르면 계정에 저장 → 기기가 달라도 같게
// - 운영자 보기는 그 사람이 저장한 값을 읽기만 하고, 운영자가 누른 것은 그 화면에서만 잠깐 바뀜(저장 안 함)
import type { SupabaseClient } from '@supabase/supabase-js';

export type ScreenPrefs = Record<string, string>;
export type PrefKey = 'history_order' | 'tutor_kst' | 'tutor_paid';

/** 저장된 설정 읽기. 함수가 아직 없는 DB·일시 오류면 빈 값(기본 화면) */
export async function loadScreenPrefs(sb: SupabaseClient, target: { student?: string | null; tutor?: string | null }): Promise<ScreenPrefs> {
  const { data, error } = await sb.rpc('lms_screen_prefs', { p_student: target.student ?? null, p_tutor: target.tutor ?? null });
  return error || !data || typeof data !== 'object' ? {} : (data as ScreenPrefs);
}

/** 본인 설정 저장 (실패해도 화면은 그대로) */
export async function saveScreenPref(sb: SupabaseClient, key: PrefKey, value: string): Promise<void> {
  await sb.rpc('lms_screen_pref_set', { p_key: key, p_value: value });
}

/** 저장된 값 중 허용된 값만, 없으면 기본값 */
export function prefOf<T extends string>(prefs: ScreenPrefs | null | undefined, key: PrefKey, allowed: readonly T[], fallback: T): T {
  const v = prefs?.[key];
  return v && (allowed as readonly string[]).includes(v) ? (v as T) : fallback;
}
