// 강사 해외 이동 기간 (정책 원본 H26(173), 시안 8차 docs/lms/previews/tutor-travel-location.html, 대표 11/14)
//  판정·저장은 DB 함수 tutor_location_save · tutor_location_hours_save · tutor_schedule_multi (migration 20261114120000)
//  여기는 이름·날짜 글·도시 검색·날짜별 시간대만

import { COUNTRY_LIST, CITY_LIST } from '../admin/places';
import { formatInZone } from '../rules/dates';
import { cityTime, localToInstant } from './hours-view';
import { plusDays, type WeeklyClass } from './hours';

/** 이동 기간 (날짜는 그 지역 현지, to = 마지막 날 포함, null = 종료일 없음) */
export type TravelPeriod = { id: string; city: string; country: string; timezone: string; from: string; to: string | null };
/** Regular Working Hours 탭 하나 = 이동 기간 + 그 기간 매주 시간 ('요일:HH:MM', 그 지역 현지) */
export type TravelLocation = TravelPeriod & { monday: string; weeklyOpen: string[]; weeklyClasses: WeeklyClass[] };

/* eslint-disable @typescript-eslint/no-explicit-any -- DB 함수가 돌려주는 JSON 을 화면 모양으로 바꾸는 곳 */
export const parsePeriod = (j: any): TravelPeriod => ({ id: j.id, city: j.city, country: j.country ?? '', timezone: j.timezone, from: j.from, to: j.to ?? null });
export const parseLocation = (j: any): TravelLocation => ({
  ...parsePeriod(j), monday: j.monday, weeklyOpen: j.weekly_open ?? [], weeklyClasses: j.weekly_classes ?? [],
});
/* eslint-enable @typescript-eslint/no-explicit-any */

/** 여러 날 등록 미리보기 한 줄 (why: c 수업 · p 6시간 안 · r 요청 대기 · a 답 보냄 · l 휴무 · far 12주 넘음 · past 지남 · open 이미 열림) */
export type MultiDay = { date: string; ok: boolean; why: string | null; classAt: string | null };
export type MultiResult = { timezone: string; days: MultiDay[]; ok: number };
/* eslint-disable-next-line @typescript-eslint/no-explicit-any */
export const parseMulti = (j: any): MultiResult => ({
  timezone: j.timezone, ok: j.ok ?? 0,
  days: (j.days ?? []).map((d: { date: string; ok: boolean; why: string | null; class: string | null }) => ({ date: d.date, ok: d.ok, why: d.why, classAt: d.class ?? null })),
});

const SHORT = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];
const MONTHS = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
const p = (date: string) => { const d = new Date(`${date}T00:00:00Z`); return { dow: d.getUTCDay(), day: d.getUTCDate(), month: d.getUTCMonth() }; };
/** '5 Jan' */
export const dayMonth = (date: string) => { const x = p(date); return `${x.day} ${MONTHS[x.month]}`; };
/** 'Wed, 24 Mar' */
export const dowDayMonth = (date: string) => { const x = p(date); return `${SHORT[x.dow]}, ${x.day} ${MONTHS[x.month]}`; };
/** 'Wed, 20 Jan – Fri, 22 Jan' (하루면 하나만) */
export const daysText = (from: string, to: string) => (from === to ? dowDayMonth(from) : `${dowDayMonth(from)} – ${dowDayMonth(to)}`);

/** 탭 이름 (대표 확정): 'Buenos Aires · 5 Jan – 23 Mar' / 종료일 없으면 'Buenos Aires · from 5 Jan' */
export const tabLabel = (l: TravelPeriod) => (l.to ? `${l.city} · ${dayMonth(l.from)} – ${dayMonth(l.to)}` : `${l.city} · from ${dayMonth(l.from)}`);
/** 종료일이 있으면 다음 날부터 Regular 자동 복귀 */
export const returnText = (to: string) => `Regular hours apply again from ${dowDayMonth(plusDays(to, 1))}`;
export const NO_END_TEXT = 'No end date. Regular hours will not return automatically.';

/** 시간대 짧은 이름: 그날 기준 'AEDT' (서머타임 반영). 약자가 없으면 'UTC-3' */
export function zoneBadge(timezone: string, date: string): string {
  const at = localToInstant(date, '12:00', timezone);
  let name = '';
  try {
    name = new Intl.DateTimeFormat('en-AU', { timeZone: timezone, timeZoneName: 'short' }).formatToParts(at).find((x) => x.type === 'timeZoneName')?.value ?? '';
  } catch { /* 시간대 이름을 모르는 브라우저 */ }
  if (name && !/^(GMT|UTC)/.test(name)) return name;
  const f = formatInZone(at, timezone);
  const off = Math.round((Date.parse(`${f.date}T${f.time}:00Z`) - +at) / 60000);
  const h = Math.trunc(Math.abs(off) / 60);
  const m = Math.abs(off) % 60;
  return `UTC${off < 0 ? '-' : '+'}${h}${m ? `:${String(m).padStart(2, '0')}` : ''}`;
}

/** 평소 지역 'Australia · Sydney' (나라는 강사 정보, 도시는 시간대 이름) */
export const homeText = (country: string, timezone: string) => {
  const city = cityTime(timezone).replace(/ Time$/, '');
  return country ? `${country} · ${city}` : city;
};

/** 그 날짜(현지)에 있는 이동 기간 → 없으면 null (평소 지역) */
export const periodOn = (periods: TravelPeriod[], date: string): TravelPeriod | null =>
  periods.filter((l) => l.from <= date && (!l.to || l.to >= date)).sort((a, b) => (a.from < b.from ? 1 : -1))[0] ?? null;
/** 그 날짜의 시간대 */
export const zoneOn = (periods: TravelPeriod[], date: string, home: string) => periodOn(periods, date)?.timezone ?? home;
/** 그 시각이 든 이동 기간의 시간대 (그 지역 현지 날짜가 기간 안이면) → 없으면 평소 시간대 (DB lms_tutor_tz_at 과 같은 규칙) */
export function zoneAt(periods: TravelPeriod[], at: Date, home: string): string {
  const hit = periods.filter((l) => { const d = formatInZone(at, l.timezone).date; return l.from <= d && (!l.to || l.to >= d); })
    .sort((a, b) => (a.from < b.from ? 1 : -1))[0];
  return hit?.timezone ?? home;
}

/** 여러 날 등록: 고른 날짜를 지역별로 나눔 (두 지역에 걸치면 [Split by location]) */
export type DayGroup = { period: TravelPeriod | null; timezone: string; from: string; to: string };
export function groupDays(periods: TravelPeriod[], from: string, to: string, home: string): DayGroup[] {
  const out: DayGroup[] = [];
  for (let d = from; d <= to; d = plusDays(d, 1)) {
    const period = periodOn(periods, d);
    const last = out[out.length - 1];
    if (last && last.period?.id === period?.id) last.to = d;
    else out.push({ period, timezone: period?.timezone ?? home, from: d, to: d });
  }
  return out;
}
/** 지역 이름 'Argentina · Buenos Aires' (평소 지역이면 강사 정보) */
export const groupText = (g: DayGroup, homeCountry: string, home: string) =>
  g.period ? (g.period.country ? `${g.period.country} · ${g.period.city}` : g.period.city) : homeText(homeCountry, home);
/** 고른 날 수 */
export const dayCount = (from: string, to: string) => Math.round((Date.parse(`${to}T00:00:00Z`) - Date.parse(`${from}T00:00:00Z`)) / 86400000) + 1;

/** 막힌 날 이유 (화면 글) */
export function whyText(d: MultiDay, zoneLabel: string, ampm: (t: string) => string): string {
  switch (d.why) {
    case 'c': return d.classAt ? `Class at ${ampm(d.classAt)} ${zoneLabel}` : 'Class at this time';
    case 'p': return 'Less than 6 hours away';
    case 'r': return 'A request is waiting for this time';
    case 'a': return 'Waiting for Edge English to confirm';
    case 'l': return 'In your leave';
    case 'far': return 'More than 12 weeks ahead';
    case 'past': return 'This time has passed';
    case 'open': return 'Already available';
    case 'zone': return 'You are in another location at this time';
    default: return 'Not available';
  }
}

/** 도시 검색 (영어 도시·나라 이름, 한국어도 됨). 고르면 시간대 자동 */
export type CityHit = { city: string; country: string; timezone: string };
const plain = (s: string) => s.normalize('NFD').replace(/[̀-ͯ]/g, '').toLowerCase().replace(/[\s._\-/·,()]/g, '');
/** 'Los Angeles LA 엘에이' → 'Los Angeles' (검색용 다른 이름 빼기) */
const displayCity = (en: string) => en.split(' ').filter((w) => !/[가-힣]/.test(w)).join(' ').replace(/ LA$/, '').trim();
export const CITY_HITS: (CityHit & { keys: string })[] = CITY_LIST.map((c) => {
  const k = COUNTRY_LIST.find((x) => x.ko === c.country);
  return { city: displayCity(c.en), country: k?.en ?? c.country, timezone: c.timezone, keys: plain(`${c.en} ${c.ko} ${k?.en ?? ''} ${k?.alias ?? ''} ${c.country}`) };
});
export function searchCity(q: string): CityHit[] {
  const n = plain(q);
  if (!n) return [];
  return CITY_HITS.filter((c) => c.keys.includes(n)).slice(0, 6).map(({ city, country, timezone }) => ({ city, country, timezone }));
}
