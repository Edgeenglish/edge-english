import { describe, expect, it } from 'vitest';
import { reconcile, type PendingSave } from './pending-saves';

const base = (over: Partial<PendingSave>): PendingSave => ({ id: 'x', label: 'l', href: '/lms/admin/change', startedAt: 0, status: 'timeout', verify: { kind: 'none' }, ...over });

describe('저장 중 기록 판정 (R-20)', () => {
  const data = {
    changes: [{ id: 'c1', status: 'reverted' as const }, { id: 'c2', status: 'applied' as const }],
    lessons: [{ id: 'l1', state: 'canceled' as const, voided: false }, { id: 'l2', state: 'scheduled' as const, voided: false }, { id: 'm1', state: 'canceled' as const, voided: true }],
    requests: [{ id: 'r1', status: 'confirmed' }, { id: 'r2', status: 'requested' }],
  };
  it('응답 없음·확인 필요 줄만 서버 자료로 판정, 나머지는 그대로', () => {
    const out = reconcile([
      base({ id: 'a', verify: { kind: 'revert', changeId: 'c1' } }),
      base({ id: 'b', verify: { kind: 'revert', changeId: 'c2' }, status: 'unknown' }),
      base({ id: 'c', verify: { kind: 'cancel', lessonId: 'l1' } }),
      base({ id: 'd', verify: { kind: 'cancel', lessonId: 'l2' } }),
      base({ id: 'e', verify: { kind: 'confirm_makeup', requestId: 'r1' } }),
      base({ id: 'f', verify: { kind: 'withdraw_makeup', requestId: 'r2' } }),
      base({ id: 'g', verify: { kind: 'void_makeup', lessonId: 'm1' } }),
      base({ id: 'h', verify: { kind: 'none' } }),
      base({ id: 'i', verify: { kind: 'revert', changeId: 'c2' }, status: 'saving' }),
    ], data).map((p) => `${p.id}:${p.status}`);
    expect(out).toEqual(['a:ok', 'b:error', 'c:ok', 'd:error', 'e:ok', 'f:error', 'g:ok', 'h:timeout', 'i:saving']);
  });
  it('자료에 없는 대상은 판정하지 않음', () => {
    expect(reconcile([base({ verify: { kind: 'revert', changeId: 'zzz' } })], data)[0].status).toBe('timeout');
  });
});
