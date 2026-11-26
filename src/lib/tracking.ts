// 홈페이지 방문 통계 — GA4(숫자) + Microsoft Clarity(화면 흐름), 둘 다 무료 (대표 11/26)
// - 공개 홈페이지에만: /lms 는 보내지 않음
// - 운영 주소(edgeenglish.kr)에서만. 시험 사이트는 ?debugtrack=1 일 때만 GA4 디버그 보기로(운영 통계에 안 섞임)
// - 운영진 기기: ?notrack=1 한 번 열면 그 브라우저는 안 잡힘, ?notrack=0 으로 다시 켬
// - ID 가 비어 있으면 아무것도 불러오지 않음
export const GA_ID = 'G-09WZ0EWZ51';
export const CLARITY_ID = 'zjpnloox4e';

const PROD_HOSTS = ['edgeenglish.kr', 'www.edgeenglish.kr'];
const NOTRACK_KEY = 'edge_notrack';
const DEBUG_KEY = 'edge_debugtrack';

type Mode = 'off' | 'on' | 'debug';

function remember(key: string, v: string | null) {
  try {
    if (v === null) localStorage.removeItem(key);
    else localStorage.setItem(key, v);
  } catch {}
}
function recall(key: string): string | null {
  try {
    return localStorage.getItem(key);
  } catch {
    return null;
  }
}

function isEuropeTz(): boolean {
  try {
    const tz = Intl.DateTimeFormat().resolvedOptions().timeZone || '';
    return tz.startsWith('Europe/') || tz === 'Atlantic/Reykjavik' || tz === 'Atlantic/Canary' || tz === 'Atlantic/Madeira' || tz === 'Atlantic/Azores';
  } catch {
    return false;
  }
}

/** 방문 통계 끄기 버튼 (/privacy) */
export const trackingOff = () => recall(NOTRACK_KEY) === '1';
export function setTrackingOff(off: boolean) {
  remember(NOTRACK_KEY, off ? '1' : null);
}

/** 주소 뒤 ?notrack=1/0, ?debugtrack=1/0 을 기억하고 지금 보낼지 정함 */
export function trackingMode(): Mode {
  if (typeof window === 'undefined') return 'off';
  const q = new URLSearchParams(window.location.search);
  if (q.get('notrack') === '1') remember(NOTRACK_KEY, '1');
  if (q.get('notrack') === '0') remember(NOTRACK_KEY, null);
  if (q.get('debugtrack') === '1') remember(DEBUG_KEY, '1');
  if (q.get('debugtrack') === '0') remember(DEBUG_KEY, null);
  if (recall(NOTRACK_KEY) === '1') return 'off';
  // 유럽(EEA·영국·스위스) 방문자는 동의 창 없이 쓸 수 없어 아예 안 불러옴 — 기기 시간대로 판단 (대표 11/26)
  if (isEuropeTz()) return 'off';
  if (PROD_HOSTS.includes(window.location.hostname)) return 'on';
  return recall(DEBUG_KEY) === '1' ? 'debug' : 'off';
}

export const isPublicPath = (path: string) => !path.startsWith('/lms');

type Gtag = (...args: unknown[]) => void;
declare global {
  interface Window {
    gtag?: Gtag;
    dataLayer?: unknown[];
    clarity?: (...args: unknown[]) => void;
  }
}

/** GA4 이벤트 (불러오지 않았으면 아무 일도 안 함) */
export function track(name: string, params: Record<string, string | number> = {}) {
  if (typeof window === 'undefined' || !window.gtag || !isPublicPath(window.location.pathname)) return;
  window.gtag('event', name, params);
}
