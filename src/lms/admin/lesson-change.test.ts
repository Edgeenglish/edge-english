import { describe, expect, it } from 'vitest';
import { kstToInstant } from '../rules/dates';
import { changeableLessons, decisionLines, kstLabel, makeupRights, studentNotice, tutorNotice, type ChangeDecision, type ChLesson, type NoticeContext } from './lesson-change';
import { toLessonChanges } from './live';
import { buildBoard } from './board';

const L = (id: string, date: string, time: string, extra: Partial<ChLesson> = {}): ChLesson => ({
  id, kind: 'regular', seq: 1, startsAt: kstToInstant(date, time), state: 'scheduled', classStatus: null, makeupOf: null, voided: false,
  tutorId: 't', tutorName: 'Alex', tutorTz: 'Asia/Manila', ...extra,
});
const now = kstToInstant('2026-10-26', '21:00');
const student = { id: 's', code: 'STU-0001', nameKo: '김민수', nameEn: 'Minsu Kim', timezone: 'Asia/Seoul' };
const adv: ChangeDecision = {
  status: 'Student canceled in advance', timing: 'advance', who: 'student', hours_before: 44, uses_credit: true, credits_left: 2, credits_after: 1,
  makeup_allowed: true, makeup_until: '2027-01-05', reward_won: 0, holiday: false,
};

describe('수업 변경 화면 계산 (1순위)', () => {
  it('고를 수 있는 수업 = 오늘(한국)부터 예정 수업, 시간순 — 날짜를 타이핑하지 않음', () => {
    const list = changeableLessons([
      L('b', '2026-10-29', '17:00'), L('a', '2026-10-26', '08:00'), L('past', '2026-10-25', '17:00'),
      L('c', '2026-10-28', '17:00', { state: 'canceled', classStatus: 'Student canceled in advance' }),
    ], now);
    expect(list.map((l) => l.id)).toEqual(['a', 'b']);
    expect(kstLabel(list[1].startsAt)).toBe('10/29 (목) 17:00');
  });

  it('보강 권리: 보강 받는 결과 + 살아 있는 보강 없음 (늦은 변경·되돌려 없앤 보강 제외), 이관 미예약 보강 포함', () => {
    const lessons = [
      L('x1', '2026-10-20', '17:00', { state: 'canceled', classStatus: 'Student canceled in advance' }),
      L('x2', '2026-10-21', '17:00', { state: 'canceled', classStatus: 'Tutor canceled late' }),
      L('m2', '2026-10-30', '17:00', { kind: 'makeup', seq: null, makeupOf: 'x2' }),
      L('x3', '2026-10-22', '17:00', { state: 'canceled', classStatus: 'Student canceled late' }),
      L('x4', '2026-10-23', '17:00', { state: 'canceled', classStatus: 'Tutor canceled in advance' }),
      L('m4', '2026-10-31', '17:00', { kind: 'makeup', seq: null, makeupOf: 'x4', state: 'canceled', voided: true }),
    ];
    const r = makeupRights(lessons, [{ id: 'mi', originalDate: '2026-10-01', tutorLeave: true }], [
      { id: 'r1', sourceLessonId: 'x1', migratedItemId: null, status: 'requested', candidates: [], confirmedLessonId: null },
    ]);
    expect(r.map((x) => x.key)).toEqual(['x1', 'x4', 'mi']);
    expect(r[0].open?.id).toBe('r1');
  });

  it('미리 보기 줄: 정상 변경 · 변경권 2→1 · 보강 기한', () => {
    expect(decisionLines(adv)).toEqual(['학생 정상 변경 · 수업 44시간 전 요청', '변경권 2 → 1', '보강 1/5 (화)까지']);
    expect(decisionLines({ ...adv, status: 'Tutor canceled late', who: 'tutor', uses_credit: false, reward_won: 2000 })).toContain('학생 적립금 2,000원');
  });

  it('안내 문구: 원래 수업 날짜와 보강 날짜를 모두 실제 날짜로 (학생 한국어, 강사 현지 시각 영어)', () => {
    const lesson = L('x1', '2026-10-29', '17:00');
    const c: NoticeContext = { student, durationMin: 50, lesson, decision: adv, tutorName: 'Alex', tutorTz: 'Asia/Manila', makeupAt: kstToInstant('2026-10-30', '18:00') };
    expect(studentNotice('change', c)).toContain('변경한 수업: 10월 29일(목) 17:00');
    expect(studentNotice('change', c)).toContain('보강: 1/5 (화)까지');
    const conf = studentNotice('makeup_confirmed', c);
    expect(conf).toContain('원래 수업: 10월 29일(목) 17:00');
    expect(conf).toContain('보강 수업: 10월 30일(금) 18:00');
    expect(tutorNotice('makeup_confirmed', c)).toContain('Make-up: Fri 30 Oct 17:00 your time');
    expect(tutorNotice('makeup_ask', { ...c, candidates: [kstToInstant('2026-10-30', '18:00')] })).toContain('not confirmed yet');
    const abroad = studentNotice('change', { ...c, student: { ...student, timezone: 'America/Toronto' } });
    expect(abroad).toContain('10월 29일(목) 04:00 (한국 10월 29일(목) 17:00)');
  });

  it('대시보드: 안 보낸 안내·강사 답 대기 보강을 학생마다 한 줄로, 수업이 24시간 안이면 급함', () => {
    const s = { id: 's', name_ko: '김민수', code: 'STU-0001' };
    const tasks = toLessonChanges([
      { created_at: '2026-10-26T10:00:00Z', change: { student: s, lesson: { starts_at: kstToInstant('2026-10-27', '08:00').toISOString() } }, makeup: null },
      { created_at: '2026-10-26T10:00:00Z', change: { student: s, lesson: { starts_at: kstToInstant('2026-10-27', '08:00').toISOString() } }, makeup: null },
    ], [{ created_at: '2026-10-26T10:00:00Z', student: s }], now);
    const [item] = buildBoard(tasks, now);
    expect(item.tag).toBe('안내 안 보냄 2건');
    expect(item.severity).toBe('due_soon');
    expect(item.actions[0].href).toBe('/lms/admin/change?student=STU-0001');
  });
});
