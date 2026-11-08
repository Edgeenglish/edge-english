// 시각 글 한 곳 (대표 2026-11-08: '통일, 간단명료'). 화면·메일·WhatsApp·카톡 모든 시각이 이 규칙을 따른다.
//  - 시각 바로 뒤에 그 시각의 기준 이름. 두 시간대는 ' / ' 로 잇고, 보는 사람 시간대가 먼저, 한국이 뒤
//  - 영어: 'Mon, 9 Nov 6:00 PM Ho Chi Minh Time / 8:00 PM KST' (날짜가 다르면 'Tue, 10 Nov 1:30 AM KST')
//  - 한국어(학생 카톡·메일): '11월 9일(월) 오후 6시 [호치민 시간] / 오후 8시 [한국 시간]' (한국 거주: '… [한국 시간]')
//  - 기준 이름 강조: 굵게 되는 곳(화면·메일 HTML)은 굵게, WhatsApp 은 *별표*, 카톡은 [대괄호]. 영어 글은 *별표* 표시를 넣고,
//    굵게 안 되는 곳(메일 제목·일반 글)은 stripBold 로 별표를 뺌

import { ampmEn, formatInZone } from '../rules/dates';
import { koZoneCity } from './places';

const EN_WD = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];
const EN_MON = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
const KO_WD = ['일', '월', '화', '수', '목', '금', '토'];

export const isKst = (tz?: string | null) => !tz || tz === 'Asia/Seoul';
const cityOf = (tz: string) => tz.split('/').at(-1)?.replaceAll('_', ' ') || tz;
const wdOf = (date: string) => new Date(`${date}T00:00:00Z`).getUTCDay();

/** 기준 이름 강조 표시 (*…*): WhatsApp 은 굵게, 화면·메일 HTML 은 굵게로 바꿔 보여 줌 */
export const bold = (s: string) => `*${s}*`;
/** 굵게 안 되는 곳(메일 제목·일반 글)은 별표를 뺌 */
export const stripBold = (s: string) => s.replace(/\*([^*\n]+)\*/g, '$1');

// ---------------------------------------------------------------- 영어 (강사)
/** 'Ho Chi Minh Time' / 'KST' */
export const enZoneName = (tz?: string | null) => (isKst(tz) ? 'KST' : `${cityOf(tz as string)} Time`);
/** 'Mon, 9 Nov' */
export function enDay(at: Date, tz: string): string {
  const f = formatInZone(at, tz);
  return `${EN_WD[wdOf(f.date)]}, ${Number(f.date.slice(8))} ${EN_MON[Number(f.date.slice(5, 7)) - 1]}`;
}
/** '6:00 PM' */
export const enClock = (at: Date, tz: string) => ampmEn(formatInZone(at, tz).time);
/** 'Mon, 9 Nov 6:00 PM *Ho Chi Minh Time*' */
export const enZoned = (at: Date, tz: string) => `${enDay(at, tz)} ${enClock(at, tz)} ${bold(enZoneName(tz))}`;
/** 한국 쪽 뒤 절: 같은 날이면 '8:00 PM *KST*', 날짜가 다르면 'Tue, 10 Nov 1:30 AM *KST*' */
function enKstPart(at: Date, tz: string): string {
  const same = formatInZone(at, tz).date === formatInZone(at, 'Asia/Seoul').date;
  return `${same ? '' : `${enDay(at, 'Asia/Seoul')} `}${enClock(at, 'Asia/Seoul')} ${bold('KST')}`;
}
/** 강사에게 보이는 시각 하나: 'Mon, 9 Nov 6:00 PM *Ho Chi Minh Time* / 8:00 PM *KST*' (한국 강사는 'Mon, 9 Nov 8:00 PM *KST*') */
export function enBoth(at: Date, tz?: string | null): string {
  if (isKst(tz)) return enZoned(at, 'Asia/Seoul');
  return `${enZoned(at, tz as string)} / ${enKstPart(at, tz as string)}`;
}
/** 시각 범위(시작–끝): '4:00–4:50 PM' / 오전·오후가 바뀌면 '11:30 AM–12:20 PM' */
export function enRange(start: Date, end: Date, tz: string): string {
  const a = enClock(start, tz);
  const b = enClock(end, tz);
  return a.slice(-2) === b.slice(-2) ? `${a.slice(0, -3)}–${b}` : `${a}–${b}`;
}
/** 시각 범위 + 기준: 'Mon, 9 Nov 4:00–4:50 PM *Sydney Time* / 2:00–2:50 PM *KST*' */
export function enRangeBoth(start: Date, end: Date, tz?: string | null): string {
  if (isKst(tz)) return `${enDay(start, 'Asia/Seoul')} ${enRange(start, end, 'Asia/Seoul')} ${bold('KST')}`;
  const same = formatInZone(start, tz as string).date === formatInZone(start, 'Asia/Seoul').date;
  return `${enDay(start, tz as string)} ${enRange(start, end, tz as string)} ${bold(enZoneName(tz))} / ${same ? '' : `${enDay(start, 'Asia/Seoul')} `}${enRange(start, end, 'Asia/Seoul')} ${bold('KST')}`;
}

// ---------------------------------------------------------------- 한국어 (학생 카톡·메일)
/** '[호치민 시간]' / '[한국 시간]' */
export const koZoneBracket = (tz?: string | null) => `[${isKst(tz) ? '한국 시간' : `${koZoneCity(tz as string)} 시간`}]`;
/** '11월 9일(월)' */
export function koDay(at: Date, tz: string): string {
  const f = formatInZone(at, tz);
  return `${Number(f.date.slice(5, 7))}월 ${Number(f.date.slice(8))}일(${KO_WD[wdOf(f.date)]})`;
}
/** '오후 6시' / '오후 5시 30분' */
export function koHour(at: Date, tz: string): string {
  const [h, m] = formatInZone(at, tz).time.split(':').map(Number);
  return `${h < 12 ? '오전' : '오후'} ${h % 12 === 0 ? 12 : h % 12}시${m ? ` ${m}분` : ''}`;
}
/** 학생 안내 시각: 한국 거주 '11월 9일(월) 오후 8시 [한국 시간]' / 해외 '11월 9일(월) 오후 6시 [호치민 시간] / 오후 8시 [한국 시간]' */
export function koBoth(at: Date, tz?: string | null): string {
  if (isKst(tz)) return `${koDay(at, 'Asia/Seoul')} ${koHour(at, 'Asia/Seoul')} ${koZoneBracket('Asia/Seoul')}`;
  const same = formatInZone(at, tz as string).date === formatInZone(at, 'Asia/Seoul').date;
  return `${koDay(at, tz as string)} ${koHour(at, tz as string)} ${koZoneBracket(tz)} / ${same ? '' : `${koDay(at, 'Asia/Seoul')} `}${koHour(at, 'Asia/Seoul')} ${koZoneBracket('Asia/Seoul')}`;
}

/** 'Thu, 5 Nov' (한국 날짜 글자 그대로) */
export function enDateOf(d: string): string {
  return `${EN_WD[wdOf(d)]}, ${Number(d.slice(8))} ${EN_MON[Number(d.slice(5, 7)) - 1]}`;
}
/** '오전 9:00' → '오전 9시' / '오전 9:30' → '오전 9시 30분' (카톡·메일은 시 모양) */
export const koSi = (text: string) => text.replace(/(\d{1,2}):00/g, '$1시').replace(/(\d{1,2}):(\d\d)/g, '$1시 $2분');
/** 운영자 화면 한국어 시간대 이름: '한국 시간' / '토론토 시간' */
export const koZoneName = (tz?: string | null) => (isKst(tz) ? '한국 시간' : `${koZoneCity(tz as string)} 시간`);
