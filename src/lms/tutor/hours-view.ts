import { formatInZone } from '../rules/dates';

export const ALL_HOURS = Array.from({ length: 48 }, (_, i) => `${String(Math.floor(i / 2)).padStart(2, '0')}:${i % 2 ? '30' : '00'}`);
/** 시간대 이름 '[도시] Time' (한국은 'KST') — 강사 화면 전체 같은 이름 (11/2 점검 ⑤, 11/8 대표: KST 로 통일) */
export const cityTime = (zone: string) =>
  zone === 'Asia/Seoul' ? 'KST' : `${zone.split('/').at(-1)?.replaceAll('_', ' ') || zone} Time`;

/** Display cells map back to the original tutor-local keys; saving never changes zones. */
export function sourceCell(date: string, time: string, viewZone: string, tutorZone: string) {
  if (viewZone === tutorZone) return { date, time, dow: new Date(`${date}T00:00Z`).getUTCDay() };
  // Korea view is an unambiguous fixed-offset wall clock, including on tutor DST days.
  if (viewZone !== 'Asia/Seoul') throw new Error('Unsupported timetable display zone');
  const instant = new Date(`${date}T${time}:00+09:00`);
  const local = formatInZone(instant, tutorZone);
  return { date: local.date, time: local.time, dow: new Date(`${local.date}T00:00Z`).getUTCDay() };
}

/** 강사 현지 날짜·시각 → 그 시각을 보는 시간대의 날짜·시각 (표시 전용, 저장 키는 그대로). 서머타임은 그 날짜의 실제 시각으로 계산 */
export function localToInstant(date: string, time: string, zone: string): Date {
  let t = Date.parse(`${date}T${time}:00Z`);
  for (let i = 0; i < 3; i++) {
    const f = formatInZone(new Date(t), zone);
    t += Date.parse(`${date}T${time}:00Z`) - Date.parse(`${f.date}T${f.time}:00Z`);
  }
  return new Date(t);
}
