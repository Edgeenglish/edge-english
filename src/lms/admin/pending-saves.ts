// 저장 중 기록 (R-20): 운영진이 저장 중에 화면을 떠나도(뒤로가기·메뉴·새로고침) 결과를 잃지 않게
// - 저장을 시작할 때 이 기기(localStorage)에 '저장 중' 한 줄을 남기고, 끝나면 성공·실패로 바꾼다 (화면을 떠나도 요청은 끝까지 가므로 결과가 기록됨)
// - 20초 안에 답이 없으면 '응답 없음', 화면이 새로 열려 결과를 받을 수 없는 줄은 '확인 필요' → 그 화면을 다시 열어 서버 상태로 판정(reconcile)
// - 운영자 화면 위쪽 띠(AdminHeader)가 이 줄들을 보여 주고 [확인]으로 지운다. 서버·DB 는 건드리지 않음
// - '저장 완료'(바로 성공·서버에서 확인 모두)는 기록하자마자 지움 — '저장되지 않았어요'·'확인 필요'만 [확인]까지 남김 (대표 11/10)

export type PendingVerify =
  | { kind: 'revert'; changeId: string }
  | { kind: 'cancel'; lessonId: string }
  | { kind: 'confirm_makeup'; requestId: string }
  | { kind: 'withdraw_makeup'; requestId: string }
  | { kind: 'void_makeup'; lessonId: string }
  /** 보강 신청: 어느 권리(원래 수업·시트 보강·보상권)인지 — 시작 뒤 생긴 열린 신청이 있으면 반영 */
  | { kind: 'request_makeup'; lessonId?: string | null; itemId?: string | null; compId?: string | null }
  | { kind: 'mark_sent'; noticeId: string }
  /** 변경권 조정: 같은 사유의 조정 기록이 시작 뒤에 생겼으면 반영 */
  | { kind: 'adjust_credit'; studentId: string; delta: 1 | -1; reason: string }
  | { kind: 'none' };

export type PendingStatus = 'saving' | 'ok' | 'error' | 'timeout' | 'unknown';
export type PendingSave = {
  id: string;
  label: string;
  /** 다시 열어 확인할 화면 */
  href: string;
  startedAt: number;
  endedAt?: number;
  status: PendingStatus;
  message?: string;
  verify: PendingVerify;
};

const KEY = 'lms_admin_pending_saves';
/** 다시 열 화면 주소 — 수업 변경 화면이 수강생을 고를 때 갱신 */
let currentHref = '/lms/admin/change';
export const setPendingHref = (h: string) => { currentHref = h; };
export const pendingHref = () => currentHref;
export const PENDING_TIMEOUT_MS = 20_000;
const KEEP_MS = 6 * 60 * 60 * 1000;   // 6시간 지난 줄은 버림

const store = () => (typeof window === 'undefined' ? null : window.localStorage);
export function listPending(): PendingSave[] {
  try {
    const raw = store()?.getItem(KEY);
    const all = raw ? (JSON.parse(raw) as PendingSave[]) : [];
    return keepRows(all).filter((p) => Date.now() - p.startedAt < KEEP_MS);
  } catch { return []; }
}
/** 띠에 남길 줄: '저장 완료' 는 자동으로 지움 (순수 함수 — 시험용) */
export const keepRows = (list: PendingSave[]) => list.filter((p) => p.status !== 'ok');
function write(list: PendingSave[]) {
  try { store()?.setItem(KEY, JSON.stringify(keepRows(list))); window.dispatchEvent(new Event('lms-pending-saves')); } catch { /* 저장 안 되는 브라우저 */ }
}
export function updatePending(id: string, patch: Partial<PendingSave>) {
  write(listPending().map((p) => (p.id === id ? { ...p, ...patch } : p)));
}
export function removePending(id: string) {
  write(listPending().filter((p) => p.id !== id));
}

/** 이 화면(페이지 수명) 안에서 시작한 저장 — 새로 열린 화면에서는 비어 있으므로 '저장 중' 줄을 '확인 필요' 로 바꿀 수 있음 */
const alive = new Set<string>();

/** 저장 한 번을 기록하며 실행. 결과는 화면을 떠나도 기록됨 */
export async function trackSave<T>(entry: { label: string; href: string; verify?: PendingVerify }, fn: () => Promise<T>): Promise<T> {
  const id = crypto.randomUUID();
  alive.add(id);
  write([...listPending(), { id, label: entry.label, href: entry.href, startedAt: Date.now(), status: 'saving', verify: entry.verify ?? { kind: 'none' } }]);
  const timer = setTimeout(() => { if (listPending().find((p) => p.id === id)?.status === 'saving') updatePending(id, { status: 'timeout' }); }, PENDING_TIMEOUT_MS);
  try {
    const r = await fn();
    updatePending(id, { status: 'ok', endedAt: Date.now() });
    return r;
  } catch (e) {
    // 화면 이동·연결 끊김으로 응답을 못 받은 것은 '실패' 가 아니라 '확인 필요' — 서버에는 반영됐을 수 있음 → 다시 열면 서버 결과로 판정
    const msg = e instanceof Error ? e.message : '저장하지 못했어요.';
    const lost = (e instanceof TypeError) || /Failed to fetch|NetworkError|Load failed|AbortError|network/i.test(msg) || (e instanceof Error && e.name === 'AbortError');
    updatePending(id, lost ? { status: 'unknown', endedAt: Date.now(), message: '연결이 끊겨 결과를 받지 못했어요.' } : { status: 'error', endedAt: Date.now(), message: msg });
    throw e;
  } finally {
    clearTimeout(timer);
    alive.delete(id);
  }
}

/** 화면이 새로 열려 답을 받을 수 없는 '저장 중' 줄 → '확인 필요' */
export function markOrphans(): void {
  const list = listPending();
  const next = list.map((p) => (p.status === 'saving' && !alive.has(p.id) && Date.now() - p.startedAt > 3000 ? { ...p, status: 'unknown' as const } : p));
  if (next.some((p, i) => p !== list[i])) write(next);
}

/** 서버에서 다시 읽은 자료로 '응답 없음·확인 필요' 줄을 판정 (순수 함수 — 시험용) */
export type ReconcileData = {
  changes: { id: string; status: 'applied' | 'reverted' }[];
  lessons: { id: string; state: 'scheduled' | 'canceled' | 'done'; voided: boolean }[];
  requests: { id: string; status: string; sourceLessonId?: string | null; migratedItemId?: string | null; compensationId?: string | null; requestedAt?: Date | null }[];
  notices?: { id: string; status: string }[];
  /** 변경권 조정 기록 (admin_credits 의 uses) */
  creditUses?: { reason: string; note?: string | null; at: Date; delta: number }[];
  /** 이 자료가 어느 수강생 것인지 (변경권 조정 판정에만) */
  studentId?: string | null;
};
export const APPLIED_TEXT = '저장 완료 (서버에서 확인)';
export const NOT_APPLIED_TEXT = '저장되지 않았어요 (서버에서 확인) — 필요하면 다시 저장해 주세요.';
/** 한 줄을 서버 자료로 판정: true 반영 · false 미반영 · null 이 자료로는 알 수 없음 */
export function verifyWith(p: PendingSave, d: ReconcileData): boolean | null {
  const v = p.verify;
  if (v.kind === 'revert') { const c = d.changes.find((x) => x.id === v.changeId); return c ? c.status === 'reverted' : null; }
  if (v.kind === 'cancel') { const l = d.lessons.find((x) => x.id === v.lessonId); return l ? l.state === 'canceled' : null; }
  if (v.kind === 'confirm_makeup') { const r = d.requests.find((x) => x.id === v.requestId); return r ? r.status === 'confirmed' : null; }
  if (v.kind === 'withdraw_makeup') { const r = d.requests.find((x) => x.id === v.requestId); return r ? r.status !== 'requested' && r.status !== 'countered' : null; }
  if (v.kind === 'void_makeup') { const l = d.lessons.find((x) => x.id === v.lessonId); return l ? l.voided : null; }
  if (v.kind === 'request_makeup') {
    const mine = d.requests.filter((r) => (v.compId ? r.compensationId === v.compId : v.lessonId ? r.sourceLessonId === v.lessonId : v.itemId ? r.migratedItemId === v.itemId : false));
    if (mine.length === 0) return false;
    return mine.some((r) => (r.requestedAt ? +r.requestedAt >= p.startedAt - 60_000 : true) && r.status !== 'withdrawn' && r.status !== 'voided');
  }
  if (v.kind === 'mark_sent') { const n = d.notices?.find((x) => x.id === v.noticeId); return n ? n.status === 'sent' : null; }
  if (v.kind === 'adjust_credit') {
    if (!d.creditUses || (d.studentId && d.studentId !== v.studentId)) return null;
    return d.creditUses.some((u) => u.reason === 'admin_adjust' && (u.note ?? '') === v.reason && u.delta === v.delta && +u.at >= p.startedAt - 60_000);
  }
  return null;
}
export function reconcile(list: PendingSave[], d: ReconcileData): PendingSave[] {
  const now = Date.now();
  return list.map((p) => {
    if (p.status !== 'timeout' && p.status !== 'unknown') return p;
    const ok = verifyWith(p, d);
    if (ok === null) return p;
    return ok ? { ...p, status: 'ok', endedAt: now, message: APPLIED_TEXT } : { ...p, status: 'error', endedAt: now, message: NOT_APPLIED_TEXT };
  });
}
/** 띠에서 바로 판정한 결과를 기록 (verifyPending 결과) */
export function settlePending(id: string, ok: boolean | null) {
  if (ok === null) return;
  updatePending(id, ok ? { status: 'ok', endedAt: Date.now(), message: APPLIED_TEXT } : { status: 'error', endedAt: Date.now(), message: NOT_APPLIED_TEXT });
}
export function reconcileStored(d: ReconcileData) {
  const list = listPending();
  const next = reconcile(list, d);
  if (next.some((p, i) => p !== list[i])) write(next);
}

export const PENDING_STATUS_TEXT: Record<PendingStatus, string> = {
  saving: '저장 중… 끝나면 여기에 결과가 보여요.',
  ok: '저장 완료',
  error: '저장되지 않았어요.',
  timeout: '확인 필요 — 20초 동안 응답이 없어요. 서버 기록을 확인하는 중이에요.',
  unknown: '확인 필요 — 결과를 받지 못했어요(화면 이동·연결 끊김). 서버 기록을 확인하는 중이에요.',
};
