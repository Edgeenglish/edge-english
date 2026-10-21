// 운영자 시간표 계산 — 한국 시간(KST) 기준 주간 시간표 + 강사·학생 현지 시간
// 현지 시간은 IANA 시간대(예: Australia/Sydney)로 계산하므로 서머타임 시작·끝이 자동 반영된다 (고정 시차 저장 안 함)

import { addDays, formatInZone, instantToKstDate, type KstDate } from '../rules/dates';

export const WEEKDAY_KO = ['일', '월', '화', '수', '목', '금', '토'] as const;

/** 그 날짜가 속한 주의 월요일~일요일 (KST) */
export function weekOf(date: KstDate): KstDate[] {
  const dow = new Date(`${date}T00:00:00Z`).getUTCDay();
  const monday = addDays(date, -((dow + 6) % 7));
  return Array.from({ length: 7 }, (_, i) => addDays(monday, i));
}

/** 시간대의 UTC 차이(분). 예: 서울 +540, 시드니 여름 +660 */
export function utcOffsetMinutes(instant: Date, timeZone: string): number {
  const f = formatInZone(instant, timeZone);
  const wall = Date.UTC(Number(f.date.slice(0, 4)), Number(f.date.slice(5, 7)) - 1, Number(f.date.slice(8, 10)), Number(f.time.slice(0, 2)), Number(f.time.slice(3, 5)));
  return Math.round((wall - Math.floor(instant.getTime() / 60000) * 60000) / 60000);
}

const sign = (m: number) => `${m >= 0 ? '+' : '−'}${Math.floor(Math.abs(m) / 60)}${Math.abs(m) % 60 ? `:${String(Math.abs(m) % 60).padStart(2, '0')}` : ''}`;

/** 한국과의 시차 문구. 예: '한국보다 2시간 빠름', '한국보다 13시간 느림' */
export function diffFromKst(instant: Date, timeZone: string): string {
  const d = utcOffsetMinutes(instant, timeZone) - 540;
  if (d === 0) return '한국과 같음';
  const h = Math.abs(d) / 60;
  return `한국보다 ${Number.isInteger(h) ? h : h.toFixed(1)}시간 ${d > 0 ? '빠름' : '느림'}`;
}

/** 수업 시각을 현지 시각으로: '22:00' 또는 날짜가 달라지면 '07:00 (전날)' / '(다음 날)' */
export function localTime(instant: Date, timeZone: string): string {
  const kst = instantToKstDate(instant);
  const f = formatInZone(instant, timeZone);
  if (f.date === kst) return f.time;
  return `${f.time} (${f.date < kst ? '전날' : '다음 날'})`;
}

export type OffsetChange = { on: KstDate; from: string; to: string; label: string };

/** 앞으로 days 일 안에 그 시간대의 시차가 바뀌는지 (서머타임 시작·끝). 바뀌면 그날과 바뀐 시차 */
export function upcomingOffsetChange(from: Date, timeZone: string, days = 14): OffsetChange | null {
  let prev = utcOffsetMinutes(from, timeZone);
  for (let h = 1; h <= days * 24; h++) {
    const t = new Date(from.getTime() + h * 3600_000);
    const cur = utcOffsetMinutes(t, timeZone);
    if (cur !== prev) {
      return {
        on: formatInZone(t, timeZone).date,
        from: `UTC${sign(prev)}`,
        to: `UTC${sign(cur)}`,
        label: cur > prev ? '서머타임 시작' : '서머타임 끝',
      };
    }
    prev = cur;
  }
  return null;
}

/** 날짜 표시: '10/19(월)' */
export function dayLabel(d: KstDate): string {
  return `${Number(d.slice(5, 7))}/${Number(d.slice(8, 10))}(${WEEKDAY_KO[new Date(`${d}T00:00:00Z`).getUTCDay()]})`;
}
