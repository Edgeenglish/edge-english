// 강사 화면 미리보기용 가짜 데이터 (?demo=1, 저장 안 함). 실제 학생·강사 이름 아님
import type { TutorScreen } from './screen';

export function fakeTutorScreen(now: Date): TutorScreen {
  const h = (hours: number) => new Date(Math.floor(+now / 3600000) * 3600000 + hours * 3600000);
  const lesson = (id: string, start: number, min: number, extra: Partial<TutorScreen['lessons'][number]> = {}) => ({
    id, startsAt: h(start), endsAt: new Date(+h(start) + min * 60000), kind: 'regular' as const, state: 'scheduled' as const, classStatus: null,
    student: 'Hajun Kim', level: null, noteUrl: 'https://docs.google.com/', covering: false, makeupOf: null, count: null,
    topics: null, remarks: null, recordedAt: null, locked: false, ...extra,
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
  };
}
