// 강사 화면 미리보기용 가짜 데이터 (?demo=1, 저장 안 함). 실제 수강생·강사 이름 아님
import { addDays, formatInZone, instantToKstDate } from '../rules/dates';
import type { TutorStudentProfile } from './profile';
import { hhmm, lessonAt, plusDays, toMin, type CellCode, type HoursData } from './hours';
import { NO_LATE, type TutorScreen } from './screen';
import { localToInstant } from './hours-view';
import type { ScheduleAction, ScheduleCode, ScheduleData } from './schedule';
import type { MultiResult } from './travel';

export function fakeTutorScreen(now: Date): TutorScreen {
  const h = (hours: number) => new Date(Math.floor(+now / 3600000) * 3600000 + hours * 3600000);
  const lesson = (id: string, start: number, min: number, extra: Partial<TutorScreen['lessons'][number]> = {}) => ({
    id, startsAt: h(start), endsAt: new Date(+h(start) + min * 60000), kind: 'regular' as const, state: 'scheduled' as const, classStatus: null,
    student: 'Hajun Kim', studentId: 'demo-hajun', level: null, noteUrl: 'https://docs.google.com/', covering: false, makeupOf: null, count: null,
    topics: null, remarks: null, studentLate: false, late: NO_LATE, recordedAt: null, locked: false, ...extra,
  });
  return {
    tutor: { id: 'demo', name: 'Emma', timezone: 'Australia/Sydney', meetUrl: 'https://meet.google.com/' },
    locations: [],
    lessons: [
      lesson('d1', -26, 40, { student: 'Seoyeon Park (Sarah)', studentId: 'demo-seoyeon', state: 'done', classStatus: 'Normal', topics: 'Travel plans, airports', count: { n: 5, total: 8 } }),
      lesson('d2', -3, 40, { count: { n: 6, total: 8 } }),
      lesson('d3', -1, 20, { student: 'Doyun Lee', kind: 'makeup', makeupOf: h(-74), count: { n: 3, total: 24 } }),
      lesson('d4', 20, 40, { count: { n: 7, total: 8 } }),
      lesson('d5', 22, 20, { student: 'Doyun Lee', state: 'canceled', classStatus: 'Student canceled in advance' }),
      lesson('d6', 46, 40, { student: 'Seoyeon Park (Sarah)', studentId: 'demo-seoyeon', covering: true, count: { n: 6, total: 8 } }),
      lesson('d7', 70, 40, { student: 'Minsu Kim', kind: 'compensation' }),
      // 원래 이 강사 수업, 다른 강사가 대체 (H26(138) 회색 줄)
      lesson('d8', 23, 40, { student: 'Jiwoo Han', studentId: 'demo-jiwoo', coveredByOther: true, count: { n: 2, total: 8 } }),
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
    tutor: { id: 'demo', name: 'Emma', timezone: tz, country: 'Australia' }, from: plusDays(monday, 7), monday, times, weeklyOpen,
    weeklyClasses: [{ d: 1, time: '12:00', min: 50, student: 'Minjun Kim' }, { d: 3, time: '20:00', min: 50, student: 'Seoyeon Lee' }, { d: 4, time: '10:00', min: 25, student: 'Jiho Yoon' }],
    cells, lessons, locations: [], history: null,
  };
}

/** 수강생 프로필 미리보기 (?demo=1): 정규 수강생 1명(Toronto)·대체수업 수강생 1명. 가짜 이름 */
export function fakeStudentProfile(studentId: string, now: Date): TutorStudentProfile {
  const today = instantToKstDate(now);
  const start = addDays(today, -14);
  const base = addDays(start, 83);
  const regular = studentId !== 'demo-seoyeon';
  const common = {
    id: studentId, code: null, nameKo: null, nameEn: regular ? 'Hajun Kim' : 'Seoyeon Park', displayName: regular ? null : 'Sarah', label: regular ? 'Hajun Kim' : 'Seoyeon Park (Sarah)',
    country: regular ? 'Korea' : 'Canada', city: regular ? 'Seoul' : 'Toronto', timezone: regular ? 'Asia/Seoul' : 'America/Toronto', genderAge: 'F / 30s',
    email: regular ? 'hajun@example.com' : null, phone: null, adminMemo: null, level: 'Intermediate', levelNote: 'B1 (sheet)', levelAt: new Date(+now - 86400000 * 3), levelBy: 'Emma',
    classType: 'Free conversation', textbook: null, classNoteUrl: null, correctionPref: 'active immediate corrections',
    selfIntroEn: '✅ Job: Software engineer\n✅ Hobbies: Hiking, cooking', job: 'Software engineer', hobbies: 'Hiking, cooking', interests: null, improve: 'Speaking in meetings',
    hopes: 'Relaxed, lots of talking', correctionStyle: 'major_only' as const, correctionNote: null, classStyle: 'free_talking' as const, classStyleNote: null, answersAt: now, lmsSince: null,
    tutorClassStyle: null, tutorClassStyleMix: [], tutorMaterialsNote: null, tutorClassStyleAt: null, tutorClassStyleBy: null, improveTutorAt: null,
  };
  const slots = [1, 4].map((weekday) => ({ weekday, time: '10:00', durationMin: 40, tutorId: 'demo', tutor: 'Emma', tutorTz: 'Australia/Sydney', tutorCountry: 'Australia', from: start, to: null }));
  const up = [1, 4].map((wd, i) => {
    const d = new Date(`${addDays(today, ((wd - new Date(`${today}T00:00:00Z`).getUTCDay() + 7) % 7) || 7)}T01:00:00Z`);
    return { id: `u${i}`, kind: 'regular', seq: 7 + i, startsAt: d, endsAt: new Date(+d + 40 * 60000), tutor: 'Emma', tutorTz: 'Australia/Sydney', tutorId: 'demo', substitute: !regular, leaveOpen: false };
  });
  return {
    student: common,
    enrollment: { id: 'e', seq: 1, status: 'active', weeks: 12, legacyLabel: null, weeklyCount: 2, durationMin: 40, startDate: start, baseEndDate: base, extensionDays: 1, finalEndDate: addDays(base, 1),
      lessonsPurchased: 24, lessonsCarriedIn: 1, sheet: null, done: 4, leftRegular: 20, leftAll: 21, leftUnbooked: 0, extensions: [] },
    slots: regular ? slots : [], nextSlots: [], upcoming: regular ? up : up.slice(0, 1), recentTopics: [{ startsAt: new Date(+now - 86400000 * 2), tutor: 'Emma', topics: 'Travel plans, airports', kind: 'regular', substitute: false }],
    access: regular ? 'regular' : 'substitute', me: { id: 'demo', timezone: 'Australia/Sydney' },
    followup: regular ? { firstLesson: { id: 'd1', startsAt: new Date(+now - 86400000 * 2), status: 'Normal', topics: 'Travel plans, airports', recordedAt: new Date(+now - 86400000 * 2) }, done: { level: false, improve: false, style: false, docs: false }, pending: 4 } : null,
  };
}

/** Schedule 미리보기 (?demo=1): My hours 가짜 매주 시간 + 이 화면 안에서만 막기·열기 */
export function fakeScheduleStore(now: Date, hours: HoursData, lessons: TutorScreen['lessons']) {
  const tz = hours.tutor.timezone;
  const today = formatInZone(now, tz).date;
  const last = plusDays(today, 84);
  const times = Array.from({ length: 34 }, (_, i) => hhmm(6 * 60 + i * 30));
  const blocks: ScheduleData['blocks'] = [{ id: 'b1', kind: 'block', start: `${plusDays(today, 2)}T13:00`, end: `${plusDays(today, 2)}T15:00`, note: 'Dentist' }];
  const opens: ScheduleData['opens'] = [];
  const inst = (k: string) => localToInstant(k.slice(0, 10), k.slice(11, 16), tz);
  const covers = (rs: { start: string; end: string }[], k: string) => rs.find((r) => +inst(r.start) <= +inst(k) && +inst(k) < +inst(r.end));
  const code = (k: string): ScheduleCode => {
    const a = +inst(k);
    if (lessons.some((l) => l.state !== 'canceled' && +l.startsAt < a + 1800000 && a < +l.endsAt)) return 'c';
    if (a < +now + 6 * 3600000) return 'p';
    const weekly = hours.weeklyOpen.includes(`${new Date(`${k.slice(0, 10)}T00:00:00Z`).getUTCDay()}:${k.slice(11)}`);
    if (!weekly && !covers(opens, k)) return 's';
    if (covers(blocks, k)) return 'b';
    return weekly ? 'o' : 'x';
  };
  const end = (k: string) => { const t = toMin(k.slice(11)) + 30; return `${k.slice(0, 10)}T${hhmm(t)}`; };
  return {
    load: async (from: string, to: string, withCells: boolean): Promise<ScheduleData> => {
      const cells: Record<string, ScheduleCode> = {};
      if (withCells) {
        for (let d = from < today ? today : from; d <= to && d <= last; d = plusDays(d, 1)) {
          // 칸 키 = 실제 시각(UTC) — 운영과 같게, 열린 칸 'o' 포함 (재검증 11/14)
          for (const t of times) cells[`${localToInstant(d, t, tz).toISOString().slice(0, 16)}Z`] = code(`${d}T${t}`);
        }
      }
      return { tutor: hours.tutor, today, last, times, cells: withCells ? cells : null, blocks: blocks.map((b) => ({ ...b })), opens: opens.map((o) => ({ ...o })), locations: hours.locations.map(({ id, city, country, timezone, from, to }) => ({ id, city, country, timezone, from, to })) };
    },
    save: async (action: ScheduleAction, keys: string[] | null, note: string | null, id: string | null) => {
      // 화면 키(UTC) → 이 미리보기 안의 강사 현지 키
      const ks = (keys ?? []).map((k) => { const f = formatInZone(new Date(`${k.replace(/Z$/, '')}:00Z`), tz); return `${f.date}T${f.time}`; }).sort();
      if (action === 'block') {
        if (ks.some((k) => code(k) === 'x')) { for (let i = opens.length - 1; i >= 0; i--) if (ks.some((k) => covers([opens[i]], k))) opens.splice(i, 1); }
        else blocks.push({ id: `b${Date.now()}`, kind: 'block', start: ks[0], end: end(ks[ks.length - 1]), note: note?.trim() || null });
      }
      if (action === 'open') opens.push({ start: ks[0], end: end(ks[ks.length - 1]) });
      const b = blocks.find((x) => x.id === id);
      if (action === 'note' && b) b.note = note?.trim() || null;
      if (action === 'unblock' && b) blocks.splice(blocks.indexOf(b), 1);
    },
    /** 여러 날 등록 미리보기: 평소 시간대 날짜만 칸 판정, 이동 기간 날짜는 모두 가능으로 */
    multi: async (from: string, to: string, start: string, endT: string, apply: boolean): Promise<MultiResult> => {
      const days: MultiResult['days'] = [];
      for (let d = from; d <= to; d = plusDays(d, 1)) {
        const ks: string[] = [];
        for (let m = toMin(start); m < toMin(endT); m += 30) ks.push(`${d}T${hhmm(m)}`);
        const cs = ks.map((k) => (d > last ? 'far' : code(k)));
        const bad = cs.find((c) => ['c', 'p', 'far'].includes(c));
        const ok = !bad && cs.some((c) => c === 's');
        days.push({ date: d, ok, why: bad ?? (ok ? null : 'open'), classAt: bad === 'c' ? start : null });
        if (ok && apply) opens.push({ start: ks[0], end: end(ks[ks.length - 1]) });
      }
      return { timezone: tz, days, ok: days.filter((x) => x.ok).length };
    },
  };
}
