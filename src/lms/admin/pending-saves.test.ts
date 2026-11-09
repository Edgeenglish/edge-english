import { describe, expect, it } from 'vitest';
import { keepRows, reconcile, verifyWith, type PendingSave } from './pending-saves';

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
  it('저장 완료 줄은 자동으로 지우고 실패·확인 필요·저장 중 줄만 남김', () => {
    const rows = (['ok', 'error', 'timeout', 'unknown', 'saving'] as const).map((status) => base({ id: status, status }));
    expect(keepRows(rows).map((p) => p.id)).toEqual(['error', 'timeout', 'unknown', 'saving']);
  });
  it('자료에 없는 대상은 판정하지 않음', () => {
    expect(reconcile([base({ verify: { kind: 'revert', changeId: 'zzz' } })], data)[0].status).toBe('timeout');
  });
});

describe('저장 종류별 서버 대조 (R-20 보강)', () => {
  const p = (verify: PendingSave['verify'], startedAt = 1000): PendingSave => base({ verify, startedAt, status: 'unknown' });
  it('보강 신청: 시작 뒤 생긴 열린 신청이 있으면 반영, 없으면 미반영', () => {
    const req = (requestedAt: number, status = 'requested') => ({ id: 'r', status, sourceLessonId: 'l1', migratedItemId: null, compensationId: null, requestedAt: new Date(requestedAt) });
    expect(verifyWith(p({ kind: 'request_makeup', lessonId: 'l1' }), { changes: [], lessons: [], requests: [req(2000)] })).toBe(true);
    expect(verifyWith(p({ kind: 'request_makeup', lessonId: 'l1' }), { changes: [], lessons: [], requests: [req(2000, 'withdrawn')] })).toBe(false);
    expect(verifyWith(p({ kind: 'request_makeup', lessonId: 'l1' }), { changes: [], lessons: [], requests: [] })).toBe(false);
    expect(verifyWith(p({ kind: 'request_makeup', compId: 'c1' }), { changes: [], lessons: [], requests: [{ ...req(2000), sourceLessonId: null, compensationId: 'c1' }] })).toBe(true);
  });
  it('안내 보냄: 안내 상태가 sent 면 반영, 자료에 없으면 모름', () => {
    expect(verifyWith(p({ kind: 'mark_sent', noticeId: 'n1' }), { changes: [], lessons: [], requests: [], notices: [{ id: 'n1', status: 'sent' }] })).toBe(true);
    expect(verifyWith(p({ kind: 'mark_sent', noticeId: 'n1' }), { changes: [], lessons: [], requests: [], notices: [{ id: 'n1', status: 'pending' }] })).toBe(false);
    expect(verifyWith(p({ kind: 'mark_sent', noticeId: 'n1' }), { changes: [], lessons: [], requests: [] })).toBeNull();
  });
  it('변경권 조정: 같은 사유·방향의 조정 기록이 시작 뒤에 있으면 반영 (다른 수강생 자료로는 판정 안 함)', () => {
    const d = { changes: [], lessons: [], requests: [], studentId: 's1', creditUses: [{ reason: 'admin_adjust', note: '사전 안내', at: new Date(5000), delta: 1 }] };
    expect(verifyWith(p({ kind: 'adjust_credit', studentId: 's1', delta: 1, reason: '사전 안내' }), d)).toBe(true);
    expect(verifyWith(p({ kind: 'adjust_credit', studentId: 's1', delta: -1, reason: '사전 안내' }), d)).toBe(false);
    expect(verifyWith(p({ kind: 'adjust_credit', studentId: 's2', delta: 1, reason: '사전 안내' }), d)).toBeNull();
    expect(verifyWith(p({ kind: 'adjust_credit', studentId: 's1', delta: 1, reason: '사전 안내' }), { ...d, creditUses: undefined })).toBeNull();
  });
});
