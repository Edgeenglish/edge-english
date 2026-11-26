// 홈페이지 방문 통계 — GA4(숫자) + Microsoft Clarity(화면 흐름), 둘 다 무료 (대표 11/26)
// - 방문자가 아래 배너에서 [동의]한 경우에만 불러옴. 동의 전·거부·철회면 아무것도 안 불러옴
// - 공개 홈페이지에만: /lms 는 보내지 않음
// - 운영 주소(edgeenglish.kr)에서만. 시험 사이트는 ?debugtrack=1 일 때만 GA4 디버그 보기로(운영 통계에 안 섞임)
// - 운영진 기기: ?notrack=1 한 번 열면 그 브라우저는 안 잡힘(배너도 안 뜸), ?notrack=0 으로 다시 켬
export const GA_ID = 'G-09WZ0EWZ51';
export const CLARITY_ID = 'zjpnloox4e';

const PROD_HOSTS = ['edgeenglish.kr', 'www.edgeenglish.kr'];
const NOTRACK_KEY = 'edge_notrack';
const DEBUG_KEY = 'edge_debugtrack';
const CONSENT_KEY = 'edge_stats_consent'; // 'yes' | 'no' | 없음(아직 안 고름)

type Mode = 'off' | 'on' | 'debug';
export type Consent = 'yes' | 'no' | null;

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

export function readConsent(): Consent {
  const v = recall(CONSENT_KEY);
  return v === 'yes' || v === 'no' ? v : null;
}

/** 동의·거부·철회. 철회하면 지금 화면에서 바로 GA4 전송을 막고 Clarity 를 멈춤 */
export function setConsent(v: 'yes' | 'no') {
  remember(CONSENT_KEY, v);
  if (v === 'no' && typeof window !== 'undefined') {
    (window as unknown as Record<string, boolean>)[`ga-disable-${GA_ID}`] = true;
    window.clarity?.('consent', false);
    window.clarity?.('stop');
  }
}

/** 운영진 기기·배너를 띄울지 (운영 주소에서 아직 안 골랐을 때만) */
export function needsConsentBanner(): boolean {
  if (typeof window === 'undefined') return false;
  if (recall(NOTRACK_KEY) === '1') return false;
  const host = window.location.hostname;
  const debug = recall(DEBUG_KEY) === '1';
  if (!PROD_HOSTS.includes(host) && !debug) return false;
  return readConsent() === null;
}

/** 주소 뒤 ?notrack=1/0, ?debugtrack=1/0 을 기억하고 지금 보낼지 정함 */
export function trackingMode(): Mode {
  if (typeof window === 'undefined') return 'off';
  const q = new URLSearchParams(window.location.search);
  if (q.get('notrack') === '1') remember(NOTRACK_KEY, '1');
  if (q.get('notrack') === '0') remember(NOTRACK_KEY, null);
  if (q.get('debugtrack') === '1') remember(DEBUG_KEY, '1');
  if (q.get('debugtrack') === '0') remember(DEBUG_KEY, null);
  if (recall(NOTRACK_KEY) === '1' || readConsent() !== 'yes') return 'off';
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
