// 운영자 화면 미리보기용 가상 강사·학생·주간 수업 (실제 사람 아님). '지금' 기준으로 만든다
// 강사 시간대: 시드니(10월 초 서머타임 시작) · 토론토(11/1 끝) · 런던(10/25 끝) → 서머타임 표시 확인용

import { addDays, formatInZone, instantToKstDate, kstToInstant, type KstDate } from '../rules/dates';
import type { FakeLesson } from './fake-data';
import { weekOf } from './schedule';

export type DirTutor = { id: string; name: string; country: string; timezone: string };

export type DirLesson = {
  id: string;
  startsAt: Date;
  minutes: number;
  tutorId: string;
  studentCode: string;
  kind: 'regular' | 'makeup';
  state: 'scheduled' | 'done' | 'canceled';
  note?: string;
  noShow?: boolean; // 노쇼 신고가 열려 있는 수업
};

export type DirStudent = {
  code: string;
  name: string;
  nameEn: string;
  email: string;
  phone: string;
  timezone: string;
  status: 'active' | 'ending' | 'waiting_match';
  product: string;
  periodStart: KstDate;
  periodEnd: KstDate;
  regularLeft: number;
  lessonsTotal: number;
  creditsLeft: number;
  creditsPerPeriod: number;
  tutorId: string | null;
  slots: { weekday: number; time: string }[]; // 고정 요일(0=일)·한국 시각
  renewal: '없음' | '신청함 · 결제 확인 전' | '결제 확인';
  payments: { on: KstDate; product: string; method: string; amount: number; confirmed: boolean }[];
  points: number;
  consent: '동의 완료' | '동의 필요';
  memo: string;
  requests: { title: string; status: string }[];
};

export const TUTORS: DirTutor[] = [
  { id: 't-alex', name: 'Alex', country: '호주 시드니', timezone: 'Australia/Sydney' },
  { id: 't-blair', name: 'Blair', country: '캐나다 토론토', timezone: 'America/Toronto' },
  { id: 't-chloe', name: 'Chloe', country: '영국 런던', timezone: 'Europe/London' },
];

export function fakeDirectory(now: Date) {
  const today = instantToKstDate(now);
  const week = weekOf(today);
  const students: DirStudent[] = [
    { code: 'STU-9001', name: '가상학생일', nameEn: 'Fake One', email: 'fake1@example.com', phone: '010-0000-0001', timezone: 'Asia/Seoul', status: 'waiting_match', product: '50분 · 주2회 · 4주', periodStart: addDays(today, 7), periodEnd: addDays(today, 34), regularLeft: 8, lessonsTotal: 8, creditsLeft: 2, creditsPerPeriod: 2, tutorId: null, slots: [], renewal: '없음', payments: [{ on: addDays(today, -8), product: '50분 주2회 4주', method: '계좌이체', amount: 336000, confirmed: true }], points: 0, consent: '동의 필요', memo: '신청서: 화·목 저녁 8시 희망, 발음 교정 원함', requests: [] },
    { code: 'STU-9004', name: '가상학생사', nameEn: 'Fake Four', email: 'fake4@example.com', phone: '010-0000-0004', timezone: 'Asia/Seoul', status: 'active', product: '50분 · 주2회 · 4주', periodStart: addDays(today, -27), periodEnd: today, regularLeft: 1, lessonsTotal: 8, creditsLeft: 1, creditsPerPeriod: 2, tutorId: 't-blair', slots: [{ weekday: 2, time: '20:00' }, { weekday: 4, time: '20:00' }], renewal: '결제 확인', payments: [{ on: addDays(today, -29), product: '50분 주2회 4주', method: '카드(아임웹)', amount: 336000, confirmed: true }, { on: today, product: '50분 주2회 4주 (재등록)', method: '계좌이체', amount: 336000, confirmed: true }], points: 0, consent: '동의 완료', memo: '', requests: [] },
    { code: 'STU-9005', name: '가상학생오', nameEn: 'Fake Five', email: 'fake5@example.com', phone: '010-0000-0005', timezone: 'Asia/Seoul', status: 'active', product: '50분 · 주3회 · 12주', periodStart: addDays(today, -20), periodEnd: addDays(today, 63), regularLeft: 27, lessonsTotal: 36, creditsLeft: 3, creditsPerPeriod: 3, tutorId: 't-alex', slots: [{ weekday: 1, time: '21:00' }, { weekday: 3, time: '21:00' }, { weekday: 5, time: '21:00' }], renewal: '없음', payments: [{ on: addDays(today, -22), product: '50분 주3회 12주', method: '카드(아임웹)', amount: 1450000, confirmed: true }], points: 2000, consent: '동의 완료', memo: '', requests: [] },
    { code: 'STU-9006', name: '가상학생육', nameEn: 'Fake Six', email: 'fake6@example.com', phone: '010-0000-0006', timezone: 'Europe/London', status: 'active', product: '40분 · 주2회 · 4주', periodStart: addDays(today, -5), periodEnd: addDays(today, 22), regularLeft: 6, lessonsTotal: 8, creditsLeft: 2, creditsPerPeriod: 2, tutorId: 't-chloe', slots: [{ weekday: 1, time: '18:00' }, { weekday: 3, time: '18:00' }], renewal: '없음', payments: [{ on: addDays(today, -7), product: '40분 주2회 4주', method: '카드(아임웹)', amount: 280000, confirmed: true }], points: 0, consent: '동의 완료', memo: '런던 거주 — 서머타임 바뀌면 현지 시각 달라짐', requests: [] },
    { code: 'STU-9002', name: '가상학생이', nameEn: 'Fake Two', email: 'fake2@example.com', phone: '010-0000-0002', timezone: 'Asia/Seoul', status: 'active', product: '40분 · 주3회 · 24주', periodStart: addDays(today, -40), periodEnd: addDays(today, 128), regularLeft: 52, lessonsTotal: 72, creditsLeft: 1, creditsPerPeriod: 3, tutorId: 't-blair', slots: [{ weekday: 1, time: '21:00' }, { weekday: 3, time: '21:00' }, { weekday: 5, time: '21:00' }], renewal: '없음', payments: [{ on: addDays(today, -42), product: '40분 주3회 24주', method: '계좌이체', amount: 2400000, confirmed: true }], points: 2000, consent: '동의 완료', memo: '', requests: [{ title: '장기 연기 7일 (11/20~11/26)', status: '승인 대기' }] },
    { code: 'STU-9008', name: '가상학생팔', nameEn: 'Fake Eight', email: 'fake8@example.com', phone: '010-0000-0008', timezone: 'Australia/Brisbane', status: 'ending', product: '50분 · 주2회 · 4주', periodStart: addDays(today, -27), periodEnd: today, regularLeft: 1, lessonsTotal: 8, creditsLeft: 0, creditsPerPeriod: 2, tutorId: 't-alex', slots: [{ weekday: 1, time: '19:00' }, { weekday: 3, time: '19:00' }], renewal: '없음', payments: [{ on: addDays(today, -29), product: '50분 주2회 4주', method: '카드(아임웹)', amount: 336000, confirmed: true }], points: 0, consent: '동의 필요', memo: '해외 거주 (브리즈번)', requests: [] },
    { code: 'STU-9010', name: '가상학생십', nameEn: 'Fake Ten', email: 'fake10@example.com', phone: '010-0000-0010', timezone: 'Asia/Seoul', status: 'active', product: '50분 · 주1회 · 12주', periodStart: addDays(today, -50), periodEnd: addDays(today, 3), regularLeft: 1, lessonsTotal: 12, creditsLeft: 0, creditsPerPeriod: 1, tutorId: 't-chloe', slots: [{ weekday: 6, time: '19:00' }], renewal: '신청함 · 결제 확인 전', payments: [{ on: addDays(today, -52), product: '50분 주1회 12주', method: '계좌이체', amount: 540000, confirmed: true }], points: 0, consent: '동의 완료', memo: '', requests: [{ title: `보강 신청 · ${addDays(today, -6).slice(5).replace('-', '/')} 수업분`, status: '학생 미신청' }] },
    { code: 'STU-9003', name: '가상학생삼', nameEn: 'Fake Three', email: 'fake3@example.com', phone: '010-0000-0003', timezone: 'Australia/Brisbane', status: 'waiting_match', product: '50분 · 주1회 · 12주', periodStart: addDays(today, 10), periodEnd: addDays(today, 93), regularLeft: 12, lessonsTotal: 12, creditsLeft: 1, creditsPerPeriod: 1, tutorId: null, slots: [], renewal: '없음', payments: [{ on: today, product: '50분 주1회 12주', method: '카드(아임웹)', amount: 540000, confirmed: true }], points: 0, consent: '동의 필요', memo: '신청서: 수·금 오전 희망', requests: [] },
  ];
  const lessons: DirLesson[] = [];
  for (const s of students) {
    if (!s.tutorId) continue;
    for (const d of [...week.map((x) => addDays(x, -7)), ...week, ...week.map((x) => addDays(x, 7))]) {
      const dow = new Date(`${d}T00:00:00Z`).getUTCDay();
      for (const slot of s.slots.filter((x) => x.weekday === dow)) {
        const startsAt = kstToInstant(d, slot.time);
        lessons.push({ id: `${s.code}-${d}-${slot.time}`, startsAt, minutes: Number(s.product.slice(0, 2)), tutorId: s.tutorId, studentCode: s.code, kind: 'regular', state: startsAt.getTime() < now.getTime() ? 'done' : 'scheduled' });
      }
    }
  }
  // 보강 1건, 취소 1건 (화면 확인용)
  lessons.push({ id: 'mk-1', startsAt: kstToInstant(week[4], '21:00'), minutes: 40, tutorId: 't-blair', studentCode: 'STU-9002', kind: 'makeup', state: kstToInstant(week[4], '21:00') < now ? 'done' : 'scheduled' });
  const cancel = lessons.find((l) => l.studentCode === 'STU-9005');
  if (cancel) Object.assign(cancel, { state: 'canceled', note: '학생 정상 취소 · 보강 가능' });
  // 홈 '오늘 수업'과 같은 상황이 되도록 오늘 수업 추가 (요일과 상관없이 항상 보이게). 노쇼 신고는 fakeTasks 의 ns-1 과 같은 시각
  const nsAt = new Date(now.getTime() - 0.2 * 3600_000);
  lessons.push({ id: 'ns-lesson', startsAt: nsAt, minutes: 50, tutorId: 't-alex', studentCode: 'STU-9005', kind: 'regular', state: 'done', noShow: true });
  const extra: [string, string, string, DirLesson['kind'], number][] = [
    ['STU-9006', 't-chloe', '18:00', 'regular', 40],
    ['STU-9004', 't-blair', '20:00', 'regular', 50],
    ['STU-9002', 't-blair', '21:00', 'makeup', 40],
  ];
  for (const [code, tutorId, time, kind, minutes] of extra) {
    if (lessons.some((l) => l.studentCode === code && instantToKstDate(l.startsAt) === today)) continue;
    const startsAt = kstToInstant(today, time);
    lessons.push({ id: `${code}-${today}-x`, startsAt, minutes, tutorId, studentCode: code, kind, state: startsAt < now ? 'done' : 'scheduled' });
  }
  return { tutors: TUTORS, students, lessons: lessons.sort((a, b) => a.startsAt.getTime() - b.startsAt.getTime()), week };
}

/** 홈 오른쪽 '오늘 수업' — 일정 화면과 같은 가상 수업에서 만든다 (두 화면 숫자가 어긋나지 않게) */
export function fakeTodayPanel(now: Date): FakeLesson[] {
  const dir = fakeDirectory(now);
  const today = instantToKstDate(now);
  return dir.lessons
    .filter((l) => instantToKstDate(l.startsAt) === today)
    .map((l) => ({
      time: formatInZone(l.startsAt, 'Asia/Seoul').time,
      student: dir.students.find((s) => s.code === l.studentCode)?.name ?? '(학생)',
      tutor: TUTORS.find((t) => t.id === l.tutorId)?.name ?? '(강사)',
      state: l.noShow ? '노쇼 신고' : l.state === 'canceled' ? '취소' : l.state === 'done' ? '완료' : l.kind === 'makeup' ? '보강' : '예정',
    }));
}
