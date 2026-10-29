// 강사 화면 미리보기용 가짜 데이터 (?demo=1, 저장 안 함). 실제 학생·강사 이름 아님
import { formatInZone } from '../rules/dates';
import { hhmm, lessonAt, plusDays, toMin, type CellCode, type HoursData } from './hours';
import type { TutorScreen } from './screen';

export function fakeTutorScreen(now: Date): TutorScreen {
  const h = (hours: number) => new Date(Math.floor(+now / 3600000) * 3600000 + hours * 3600000);
  const lesson = (id: string, start: number, min: number, extra: Partial<TutorScreen['lessons'][number]> = {}) => ({
    id, startsAt: h(start), endsAt: new Date(+h(start) + min * 60000), kind: 'regular' as const, state: 'scheduled' as const, classStatus: null,
    student: 'Hajun Kim', level: null, noteUrl: 'https://docs.google.com/', covering: false, makeupOf: null, count: null,
    topics: null, remarks: null, studentLate: false, recordedAt: null, locked: false, ...extra,
  });
  return {
    tutor: { id: 'demo', name: 'Emma', timezone: 'Australia/Sydney', meetUrl: 'https://meet.google.com/' },
    lessons: [
      lesson('d1', -26, 40, { student: 'Seoyeon Park', state: 'done', classStatus: 'Normal', topics: 'Travel plans, airports', count: { n: 5, total: 8 } }),
      lesson('d2', -3, 40, { count: { n: 6, total: 8 } }),
      lesson('d3', -1, 20, { student: 'Doyun Lee', kind: 'makeup', makeupOf: h(-74), count: { n: 3, total: 24 } }),
      lesson('d4', 20, 40, { count: { n: 7, total: 8 } }),
      lesson('d5', 22, 20, { student: 'Doyun Lee', state: 'canceled', classStatus: 'Student canceled in advance' }),
      lesson('d6', 46, 40, { student: 'Seoyeon Park', covering: true, count: { n: 6, total: 8 } }),
    ],
    toRecord: ['d2', 'd3'],
    makeups: [{
      id: 'm1', student: 'Doyun Lee', originalAt: h(22), originalDate: null, note: null, answeredAt: null,
      slots: [
        { id: 's1', startsAt: h(70), endsAt: new Date(+h(70) + 20 * 60000), answer: null, busy: false, past: false },
        { id: 's2', startsAt: h(94), endsAt: new Date(+h(94) + 20 * 60000), answer: null, busy: true, past: false },
      ],
    }],
    covers: [
      { id: 'c1', student: 'Minsu Kim', startsAt: h(52), endsAt: new Date(+h(52) + 40 * 60000), busy: false },
      { id: 'c2', student: 'Minsu Kim', startsAt: h(100), endsAt: new Date(+h(100) + 40 * 60000), busy: false },
    ],
  };
}

/** My hours 미리보기 (?demo=1): 시안 견본과 같은 모양, 저장은 이 화면 안에서만 */
export function fakeHours(now: Date): HoursData {
  const tz = 'Australia/Sydney';
  const today = formatInZone(now, tz).date;
  const dow = new Date(`${today}T00:00:00Z`).getUTCDay();
  const monday = plusDays(today, -((dow + 6) % 7));
  const times = Array.from({ length: 29 }, (_, i) => hhmm(8 * 60 + i * 30));
  const open: Record<number, [number, number][]> = { 1: [[540, 960], [1170, 1320]], 2: [[540, 870], [1140, 1320]], 3: [[540, 870], [1110, 1320]], 4: [[540, 1320]], 5: [[540, 1320]], 6: [[540, 720]], 0: [[1020, 1320]] };
  const weeklyOpen = Object.entries(open).flatMap(([d, rs]) => times.filter((t) => rs.some(([a, b]) => toMin(t) >= a && toMin(t) <= b)).map((t) => `${d}:${t}`));
  const cells: Record<string, CellCode> = {};
  for (let i = 0; i < 28; i++) {
    const date = plusDays(monday, i);
    const d = new Date(`${date}T00:00:00Z`).getUTCDay();
    for (const t of times) {
      const k = `${date}T${t}`;
      if (date <= today) cells[k] = 'p';
      else if (!weeklyOpen.includes(`${d}:${t}`)) cells[k] = 's';
    }
  }
  const lessons = [
    { start: `${plusDays(monday, 9)}T12:00`, min: 50, student: 'Minjun Kim', makeup: false },
    { start: `${plusDays(monday, 10)}T18:30`, min: 50, student: 'Seoyeon Lee', makeup: true },
  ];
  for (const l of lessons) for (const t of times) if (lessonAt([l], l.start.slice(0, 10), t)) cells[`${l.start.slice(0, 10)}T${t}`] = 'c';
  cells[`${plusDays(monday, 11)}T10:00`] = 'r';
  cells[`${plusDays(monday, 8)}T10:00`] = 'b';
  cells[`${plusDays(monday, 8)}T10:30`] = 'b';
  return {
    tutor: { id: 'demo', name: 'Emma', timezone: tz }, from: plusDays(monday, 7), monday, times, weeklyOpen,
    weeklyClasses: [{ d: 1, time: '12:00', min: 50, student: 'Minjun Kim' }, { d: 3, time: '20:00', min: 50, student: 'Seoyeon Lee' }, { d: 4, time: '10:00', min: 25, student: 'Jiho Yoon' }],
    cells, lessons, history: null,
  };
}
