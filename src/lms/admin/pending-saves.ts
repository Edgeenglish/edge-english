// 저장 중 기록 (R-20): 운영진이 저장 중에 화면을 떠나도(뒤로가기·메뉴·새로고침) 결과를 잃지 않게
// - 저장을 시작할 때 이 기기(localStorage)에 '저장 중' 한 줄을 남기고, 끝나면 성공·실패로 바꾼다 (화면을 떠나도 요청은 끝까지 가므로 결과가 기록됨)
// - 20초 안에 답이 없으면 '응답 없음', 화면이 새로 열려 결과를 받을 수 없는 줄은 '확인 필요' → 그 화면을 다시 열어 서버 상태로 판정(reconcile)
// - 운영자 화면 위쪽 띠(AdminHeader)가 이 줄들을 보여 주고 [확인]으로 지운다. 서버·DB 는 건드리지 않음

export type PendingVerify =
  | { kind: 'revert'; changeId: string }
  | { kind: 'cancel'; lessonId: string }
  | { kind: 'confirm_makeup'; requestId: string }
  | { kind: 'withdraw_makeup'; requestId: string }
  | { kind: 'void_makeup'; lessonId: string }
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
/** 다시 열 화면 주소 — 수업 변경 화면이 학생을 고를 때 갱신 */
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
    return all.filter((p) => Date.now() - p.startedAt < KEEP_MS);
  } catch { return []; }
}
function write(list: PendingSave[]) {
  try { store()?.setItem(KEY, JSON.stringify(list)); window.dispatchEvent(new Event('lms-pending-saves')); } catch { /* 저장 안 되는 브라우저 */ }
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
  requests: { id: string; status: string }[];
};
export function reconcile(list: PendingSave[], d: ReconcileData): PendingSave[] {
  const now = Date.now();
  return list.map((p) => {
    if (p.status !== 'timeout' && p.status !== 'unknown') return p;
    const v = p.verify;
    let ok: boolean | null = null;
    if (v.kind === 'revert') { const c = d.changes.find((x) => x.id === v.changeId); ok = c ? c.status === 'reverted' : null; }
    else if (v.kind === 'cancel') { const l = d.lessons.find((x) => x.id === v.lessonId); ok = l ? l.state === 'canceled' : null; }
    else if (v.kind === 'confirm_makeup') { const r = d.requests.find((x) => x.id === v.requestId); ok = r ? r.status === 'confirmed' : null; }
    else if (v.kind === 'withdraw_makeup') { const r = d.requests.find((x) => x.id === v.requestId); ok = r ? r.status !== 'requested' && r.status !== 'countered' : null; }
    else if (v.kind === 'void_makeup') { const l = d.lessons.find((x) => x.id === v.lessonId); ok = l ? l.voided : null; }
    if (ok === null) return p;
    return ok ? { ...p, status: 'ok', endedAt: now, message: '서버에서 확인: 반영됐어요.' } : { ...p, status: 'error', endedAt: now, message: '서버에서 확인: 반영되지 않았어요. 다시 저장해 주세요.' };
  });
}
export function reconcileStored(d: ReconcileData) {
  const list = listPending();
  const next = reconcile(list, d);
  if (next.some((p, i) => p !== list[i])) write(next);
}

export const PENDING_STATUS_TEXT: Record<PendingStatus, string> = {
  saving: '저장 중… 끝나면 여기에 결과가 보여요.',
  ok: '완료됐어요.',
  error: '실패했어요.',
  timeout: '20초 동안 응답이 없어요. [열기]에서 다시 읽으면 서버 결과로 판정해요.',
  unknown: '결과를 받지 못했어요(화면 이동·연결 끊김). 서버에는 저장됐을 수 있어요 — [열기]에서 다시 읽으면 판정해요.',
};
