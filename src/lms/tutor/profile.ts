// 강사용 Student profile (H26(44) ③·④·⑥, migration 4300) — 데이터는 DB 함수 tutor_student_profile 하나
// 시간은 'Korea Time (KST) / Your time — [도시] Time / Student's time — [도시] Time' 처럼 누구 시간인지 항상 함께 (H26(43)).
// 'Local'·'Your time' 한 단어만 쓰지 않는다. 실제 다음 수업 날짜로 계산해 서머타임·날짜·요일 변화를 반영한다

import { enZone, nextDateOf, parseEnrollment, parseProfile, parseSlots, parseTopics, parseUpcoming, type EnrollmentInfo, type RecentTopic, type SlotFull, type StudentProfile, type Upcoming } from '../admin/students';
import { formatInZone, instantToKstDate, kstToInstant, weekdayOf, type KstDate } from '../rules/dates';

export type TutorAccess = 'regular' | 'substitute';
export type TutorStudentProfile = {
  student: StudentProfile; enrollment: EnrollmentInfo | null; slots: SlotFull[]; upcoming: Upcoming[]; recentTopics: RecentTopic[];
  access: TutorAccess; me: { id: string | null; timezone: string };
};
/* eslint-disable @typescript-eslint/no-explicit-any -- DB JSON → 화면 모양 */
export function parseTutorProfile(j: any): TutorStudentProfile {
  return {
    student: parseProfile(j.student), enrollment: parseEnrollment(j.enrollment && j.enrollment.id ? j.enrollment : j.enrollment ? { ...j.enrollment, id: '', seq: 0, status: '' } : null),
    slots: parseSlots(j.slots), upcoming: parseUpcoming(j.upcoming), recentTopics: parseTopics(j.recent_topics),
    access: j.access === 'substitute' ? 'substitute' : 'regular', me: { id: j.me?.id ?? null, timezone: j.me?.timezone ?? 'Asia/Seoul' },
  };
}
/* eslint-enable @typescript-eslint/no-explicit-any */

export const RUBRIC = ['Beginner', 'Pre-Intermediate', 'Intermediate', 'Advanced'] as const;
export const CORRECTION_EN: Record<string, string> = { immediate: 'Correct me right away', major_only: 'Big mistakes only, with explanation' };
export const CLASS_STYLE_EN: Record<string, string> = { textbook: 'Textbook', free_talking: 'Free talking', not_sure: 'Not sure yet' };

const WD = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];
const MON = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
export const en12 = (hhmm: string) => {
  const [h, m] = hhmm.split(':').map(Number);
  return `${h % 12 === 0 ? 12 : h % 12}:${String(m).padStart(2, '0')} ${h < 12 ? 'AM' : 'PM'}`;
};
export const enDate = (d: KstDate) => `${WD[weekdayOf(d)]}, ${MON[Number(d.slice(5, 7)) - 1]} ${Number(d.slice(8))}`;
export const enDateYear = (d: KstDate) => `${MON[Number(d.slice(5, 7)) - 1]} ${Number(d.slice(8))}, ${d.slice(0, 4)}`;
export function enAt(t: Date, tz: string): string {
  const f = formatInZone(t, tz);
  return `${enDate(f.date)} · ${en12(f.time)}`;
}

/**
 * 정규 일정을 한 시간대로: 요일마다 다음 실제 수업 날짜로 계산.
 * 결과: 'Tue/Thu 10:00 AM' 또는 요일이 어긋나면 'Mon/Wed 8:00 PM' + note '(day before in Toronto)'
 */
export function slotsIn(slots: { weekday: number; time: string }[], tz: string, from: KstDate): { text: string; dayShift: 'before' | 'after' | null } {
  if (slots.length === 0) return { text: '—', dayShift: null };
  let shift: 'before' | 'after' | null = null;
  const local = [...slots].sort((a, b) => a.weekday - b.weekday).map((s) => {
    const d = nextDateOf(s.weekday, from);
    const f = formatInZone(kstToInstant(d, s.time), tz);
    if (f.date < d) shift = 'before';
    if (f.date > d) shift = 'after';
    return { weekday: weekdayOf(f.date), time: en12(f.time) };
  });
  const times = new Set(local.map((x) => x.time));
  const text = times.size === 1 ? `${local.map((x) => WD[x.weekday]).join('/')} ${local[0].time}` : local.map((x) => `${WD[x.weekday]} ${x.time}`).join(' · ');
  return { text, dayShift: shift };
}

/** 앞으로 14일 안에 그 시간대의 시차가 바뀌면 (서머타임 시작·끝) 안내 한 줄 */
export function dstNote(tz: string, now: Date): string | null {
  if (tz === 'Asia/Seoul') return null;
  const off = (t: Date) => {
    const f = formatInZone(t, tz);
    return Date.UTC(+f.date.slice(0, 4), +f.date.slice(5, 7) - 1, +f.date.slice(8, 10), +f.time.slice(0, 2), +f.time.slice(3, 5)) - Math.floor(t.getTime() / 60000) * 60000;
  };
  const a = off(now);
  for (let h = 1; h <= 14 * 24; h++) {
    const t = new Date(now.getTime() + h * 3600_000);
    const b = off(t);
    if (b !== a) {
      const city = enZone(tz).replace(' Time', '');
      return `${city} clocks ${b > a ? 'go forward' : 'go back'} on ${enDate(formatInZone(t, tz).date)} — times after that shift by an hour in ${city}.`;
    }
  }
  return null;
}

/** 다음 수업 (강사 본인이 맡은 것 중 가장 가까운) */
export function nextLesson(p: TutorStudentProfile, now: Date): Upcoming | null {
  return p.upcoming.find((l) => l.startsAt > now && (!p.me.id || l.tutorId === p.me.id)) ?? p.upcoming.find((l) => l.startsAt > now) ?? null;
}

/** 최종 종료 'Jan 26, 11:59 PM Korea Time (KST) = Jan 27, 1:59 AM Melbourne Time = Jan 26, 9:59 AM Toronto Time (student)' */
export function finalEndLines(finalEnd: KstDate, tutorTz: string, studentTz: string): string[] {
  const at = kstToInstant(finalEnd, '23:59');
  const line = (tz: string, who: string) => `${enAt(at, tz).replace(' · ', ', ')} ${enZone(tz)}${who}`;
  const out = [line('Asia/Seoul', '')];
  if (tutorTz !== 'Asia/Seoul') out.push(line(tutorTz, ' (your time)'));
  if (studentTz !== 'Asia/Seoul' && studentTz !== tutorTz) out.push(line(studentTz, " (student's time)"));
  return out;
}

export const todayKst = (now: Date) => instantToKstDate(now);
