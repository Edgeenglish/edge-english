/**
 * 학생 '변경권 내역' (대표 11/18 시안 확정, migration 20261118100000 student_credit_history).
 * 기간마다 지급량·지금 남은 수·내역. 줄의 after = 그 처리 직후 남은 수 (지금 남은 수가 아님).
 */
import type { ProcessingEvent } from './processing-history';

export type CreditItemKind = 'use' | 'late' | 'holiday' | 'no_credit' | 'return' | 'admin_add' | 'admin_remove' | 'migrated';
export type CreditItem = {
  id: string; at: string; kind: CreditItemKind; delta: number;
  lesson_at: string | null; cancel_at: string; timing: 'advance' | 'late' | null; holiday: boolean; after: number;
  /** 이 취소를 나중에 되돌림 (운영진). 되돌린 취소는 '수업 1회 차감'을 쓰지 않음 */
  reverted?: boolean;
};
export type CreditPeriodHistory = { start: string; end: string; granted: number; left: number; current: boolean; items: CreditItem[] };

const KINDS: CreditItemKind[] = ['use', 'late', 'holiday', 'no_credit', 'return', 'admin_add', 'admin_remove', 'migrated'];
export function parseCreditHistory(rows: unknown): CreditPeriodHistory[] {
  if (!Array.isArray(rows)) return [];
  return rows.map((p: CreditPeriodHistory) => ({
    start: p.start, end: p.end, granted: Number(p.granted) || 0, left: Number(p.left) || 0, current: !!p.current,
    items: (p.items ?? []).filter((i) => KINDS.includes(i.kind) && Number.isFinite(Date.parse(i.at))),
  }));
}

const CANCEL_KINDS: CreditItemKind[] = ['use', 'late', 'holiday', 'no_credit'];
export const isCancelItem = (i: CreditItem) => CANCEL_KINDS.includes(i.kind);

/** 수업 시작까지 남은 시간 (대표 11/18: '6시간 이상 / 미만 남기고 취소', 정확히 6시간 전은 '이상') */
export function timingText(i: CreditItem): string | null {
  if (!isCancelItem(i) || !i.timing) return null;
  return i.timing === 'late' ? '6시간 미만 남았을 때' : '6시간 이상 남았을 때';
}

/** 변경권 결과 한 줄: '변경권 1개 사용' · '변경권 사용 안 됨 · 수업 1회 차감' · '1개 반환' 등 */
export function resultText(i: CreditItem): string {
  switch (i.kind) {
    case 'use': return '변경권 1개 사용';
    case 'late': return i.reverted ? '변경권 사용 안 됨' : '변경권 사용 안 됨 · 수업 1회 차감';
    case 'holiday': return '변경권 사용 안 됨 (공휴일)';
    case 'no_credit': return i.reverted ? '남은 0개' : '남은 0개 · 수업 1회 차감';
    case 'return': return '변경권 1개 반환';
    case 'admin_add': return '운영진 추가 1개';
    case 'admin_remove': return '운영진 조정 1개 차감';
    case 'migrated': return 'LMS 시작 전 사용 1개';
  }
}

/** 창 줄의 오른쪽 짧은 결과 */
export function shortResult(i: CreditItem): string {
  switch (i.kind) {
    case 'use': return '1개 사용';
    case 'late': case 'holiday': case 'no_credit': return '사용 안 됨';
    case 'return': return '1개 반환';
    case 'admin_add': return '1개 추가';
    case 'admin_remove': case 'migrated': return '1개 차감';
  }
}

/** 창 줄 아래 작은 글: 남은 시간 · 결과 덧붙임 · 처리 후 */
export function subText(i: CreditItem): string {
  const parts: string[] = [];
  const t = timingText(i);
  if (t) parts.push(t);
  if ((i.kind === 'late' || i.kind === 'no_credit') && !i.reverted) parts.push('수업 1회 차감');
  if (i.kind === 'holiday') parts.push('공휴일');
  if (i.reverted) parts.push('나중에 취소 되돌림');
  parts.push(`처리 후 ${i.after}개`);
  return parts.join(' · ');
}

/**
 * 처리 내역 줄('수업 취소'·'수업 취소 되돌림')에 맞는 변경권 기록 찾기:
 * 같은 수업 시각 + 취소는 취소 줄, 되돌림은 반환 줄, 처리 시각이 가장 가까운 것 (10분 안).
 */
export function creditFor(e: ProcessingEvent, periods: CreditPeriodHistory[]): CreditItem | null {
  if (!e.lesson_at || (e.kind !== 'lesson_canceled' && e.kind !== 'lesson_restored')) return null;
  if (e.kind === 'lesson_canceled' && e.cancel_reason && e.cancel_reason !== 'student') return null;
  const lessonAt = Date.parse(e.lesson_at);
  const at = Date.parse(e.at);
  let best: CreditItem | null = null;
  let gap = 10 * 60 * 1000;
  for (const p of periods) for (const i of p.items) {
    if (!i.lesson_at || Date.parse(i.lesson_at) !== lessonAt) continue;
    if (e.kind === 'lesson_canceled' ? !isCancelItem(i) : i.kind !== 'return') continue;
    const d = Math.abs(Date.parse(i.at) - at);
    if (d <= gap) { best = i; gap = d; }
  }
  return best;
}

/**
 * '변경권 내역' 창 한 줄 (대표 11/18 2차): 처리 내역과 같은 항목명·순서.
 * 수업 줄 → ○○ 일시 → (취소만) 6시간 이상/미만 남았을 때 → 변경권: 결과(진하게 부분 = bold).
 */
export type CreditEntry = {
  lessonLabel: string | null; lessonAt: string | null; timeLabel: string; timeAt: string;
  timing: string | null; result: string; bold: string | null;
};
export function creditEntry(i: CreditItem): CreditEntry {
  const before = i.after - i.delta;
  const arrow = `${before}개 → ${i.after}개`;
  const charged = i.reverted ? '' : ' · 수업 1회 차감';
  const cancel = isCancelItem(i);
  const base = {
    lessonLabel: cancel ? '취소한 수업' : i.kind === 'return' ? '원래 수업' : null,
    lessonAt: cancel || i.kind === 'return' ? i.lesson_at : null,
    timeLabel: cancel ? '취소 일시' : '처리 일시',
    timeAt: cancel ? i.cancel_at : i.at,
    timing: cancel && i.timing ? (i.timing === 'late' ? '6시간 미만 남았을 때' : '6시간 이상 남았을 때') : null,
  };
  switch (i.kind) {
    case 'use': return { ...base, result: '1개 사용 · ', bold: arrow };
    case 'late': return { ...base, result: '', bold: `사용 안 됨${charged}` };
    case 'holiday': return { ...base, result: '', bold: '사용 안 됨 (공휴일)' };
    case 'no_credit': return { ...base, result: '', bold: `남은 0개${charged}` };
    case 'return': return { ...base, result: '1개 반환 · ', bold: arrow };
    case 'admin_add': return { ...base, result: '운영진 지급 1개 · ', bold: arrow };
    case 'admin_remove': return { ...base, result: '운영진 회수 1개 · ', bold: arrow };
    case 'migrated': return { ...base, result: 'LMS 시작 전 사용 1개 · ', bold: arrow };
  }
}
