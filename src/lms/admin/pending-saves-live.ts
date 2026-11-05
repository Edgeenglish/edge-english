// 저장 중 기록(R-20)을 띠에서 바로 서버 기록과 대조 — 수업 변경 화면을 열지 않아도 Home 등 어디서나 판정
import type { SupabaseClient } from '@supabase/supabase-js';
import { settlePending, verifyWith, type PendingSave } from './pending-saves';

async function one<T>(q: PromiseLike<{ data: unknown; error: unknown }>): Promise<T | null> {
  const { data, error } = await q;
  if (error) throw error;
  return (data as T) ?? null;
}

/** 한 줄을 서버에서 확인해 기록. 조회 자체가 실패하면 그대로(확인 필요) */
export async function verifyPending(sb: SupabaseClient, p: PendingSave): Promise<void> {
  const v = p.verify;
  try {
    if (v.kind === 'revert') {
      const r = await one<{ status: 'applied' | 'reverted' }>(sb.from('change_requests').select('status').eq('id', v.changeId).maybeSingle());
      return settlePending(p.id, r ? verifyWith(p, { changes: [{ id: v.changeId, status: r.status }], lessons: [], requests: [] }) : null);
    }
    if (v.kind === 'cancel' || v.kind === 'void_makeup') {
      const l = await one<{ state: 'scheduled' | 'canceled' | 'done'; voided_at: string | null }>(sb.from('lessons').select('state, voided_at').eq('id', v.lessonId).maybeSingle());
      return settlePending(p.id, l ? verifyWith(p, { changes: [], lessons: [{ id: v.lessonId, state: l.state, voided: !!l.voided_at }], requests: [] }) : null);
    }
    if (v.kind === 'confirm_makeup' || v.kind === 'withdraw_makeup') {
      const r = await one<{ status: string }>(sb.from('makeup_requests').select('status').eq('id', v.requestId).maybeSingle());
      return settlePending(p.id, r ? verifyWith(p, { changes: [], lessons: [], requests: [{ id: v.requestId, status: r.status }] }) : null);
    }
    if (v.kind === 'request_makeup') {
      let q = sb.from('makeup_requests').select('id, status, source_lesson_id, migrated_item_id, compensation_id, requested_at');
      q = v.compId ? q.eq('compensation_id', v.compId) : v.lessonId ? q.eq('source_lesson_id', v.lessonId) : q.eq('migrated_item_id', v.itemId ?? '');
      const rows = (await one<{ id: string; status: string; source_lesson_id: string | null; migrated_item_id: string | null; compensation_id: string | null; requested_at: string | null }[]>(q)) ?? [];
      return settlePending(p.id, verifyWith(p, { changes: [], lessons: [], requests: rows.map((r) => ({ id: r.id, status: r.status, sourceLessonId: r.source_lesson_id, migratedItemId: r.migrated_item_id, compensationId: r.compensation_id, requestedAt: r.requested_at ? new Date(r.requested_at) : null })) }));
    }
    if (v.kind === 'mark_sent') {
      const n = await one<{ status: string }>(sb.from('lesson_notices').select('status').eq('id', v.noticeId).maybeSingle());
      return settlePending(p.id, n ? verifyWith(p, { changes: [], lessons: [], requests: [], notices: [{ id: v.noticeId, status: n.status }] }) : null);
    }
    if (v.kind === 'adjust_credit') {
      const { data, error } = await sb.rpc('admin_credits', { p_student: v.studentId });
      if (error) return;
      const uses = ((data as { uses?: { reason: string; note?: string | null; at: string; delta: number }[] })?.uses ?? []).map((u) => ({ reason: u.reason, note: u.note ?? null, at: new Date(u.at), delta: u.delta }));
      return settlePending(p.id, verifyWith(p, { changes: [], lessons: [], requests: [], creditUses: uses, studentId: v.studentId }));
    }
  } catch { /* 조회 실패 → 확인 필요 그대로 */ }
}
