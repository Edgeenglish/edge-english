import type { SupabaseClient } from '@supabase/supabase-js';
import { levelOf, scoreOf, validPicks } from './logic';

// 가입 전 결과는 이 브라우저에만 보관 → 로그인(가입)하면 그 계정에 붙임 (H26(219) ⑨)
const KEY = 'edge_level_test_last';
export type Taken = { picks: number[]; takenAt: string; saved?: boolean };

export function readTaken(): Taken | null {
  try {
    const v = JSON.parse(localStorage.getItem(KEY) ?? 'null');
    return v && validPicks(v.picks) && typeof v.takenAt === 'string' ? v : null;
  } catch {
    return null;
  }
}
export function writeTaken(t: Taken | null) {
  try {
    if (t) localStorage.setItem(KEY, JSON.stringify(t));
    else localStorage.removeItem(KEY);
  } catch {}
}

/** 로그인돼 있고 아직 안 붙인 결과가 있으면 계정에 저장. 저장했으면 true */
export async function claimTaken(sb: SupabaseClient): Promise<boolean> {
  const t = readTaken();
  if (!t || t.saved) return false;
  const score = scoreOf(t.picks);
  const r = await sb.rpc('level_test_save', { p_picks: t.picks, p_score: score, p_level: levelOf(score).name, p_taken_at: t.takenAt });
  if (r.error) return false;
  writeTaken({ ...t, saved: true });
  return true;
}
