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
    expect(studentNotice('change', c)).toContain('취소된 수업: 10월 29일(목) 오후 5시\n변경권 1개 사용 (잔여 1개)');
    expect(studentNotice('change', c)).toContain('보강은 수강기간 종료일인 1월 5일(화)까지 진행하실 수 있어요.');
    const conf = studentNotice('makeup_confirmed', c);
    expect(conf).toContain('원래 수업: 10월 29일(목) 오후 5시');
    expect(conf).toContain('보강 수업: 10월 30일(금) 오후 6시');
    expect(tutorNotice('makeup_confirmed', c)).toContain('Make-up: Fri 30 Oct 17:00 your time');
    expect(tutorNotice('makeup_ask', { ...c, candidates: [kstToInstant('2026-10-30', '18:00')] })).toContain('not confirmed yet');
    const abroad = studentNotice('change', { ...c, student: { ...student, timezone: 'America/Toronto' } });
    expect(abroad).toContain('10월 29일(목) 오전 4시 (한국 10월 29일(목) 오후 5시)');
  });

  it('대시보드: 안 보낸 안내·강사 답 대기 보강을 학생마다 한 줄로, 수업이 24시간 안이면 급함', () => {
    const s = { id: 's', name_ko: '김민수', code: 'STU-0001' };
    const tasks = toLessonChanges([
      { created_at: '2026-10-26T10:00:00Z', event: 'change', recipient_kind: 'student', change: { student: s, lesson: { starts_at: kstToInstant('2026-10-27', '08:00').toISOString() } }, makeup: null },
      { created_at: '2026-10-26T10:00:00Z', event: 'change', recipient_kind: 'tutor', change: { student: s, lesson: { starts_at: kstToInstant('2026-10-27', '08:00').toISOString() } }, makeup: null },
    ], [{ created_at: '2026-10-26T10:00:00Z', student: s }], now);
    const [item] = buildBoard(tasks, now);
    // 무슨 일 · 할 일이 맨 위, 수업 날짜·받는 사람이 아래 (2026-10-28 대표: 스치듯 봐도 알게)
    expect(item.tag).toBe('수업 취소 · 안내 보내기');
    expect(item.detail).toBe('10/27(화) 08:00 수업 · 학생·강사 2건 · 보강 강사 답 대기 1건');
    expect(item.severity).toBe('due_soon');
    expect(item.actions[0].href).toBe('/lms/admin/change?student=STU-0001');
  });

  it('대시보드: 수업이 이미 지났어도 안내 카드에 그 수업 날짜가 보임', () => {
    const s = { id: 's', name_ko: '송예나', code: 'STU-0004' };
    const [item] = buildBoard(toLessonChanges([
      { created_at: '2026-10-28T10:00:00Z', event: 'change', recipient_kind: 'student', change: { student: s, lesson: { starts_at: kstToInstant('2026-10-20', '09:00').toISOString() } }, makeup: null },
    ], [], now), now);
    expect(item.tag).toBe('수업 취소 · 안내 보내기');
    expect(item.detail).toBe('10/20(화) 09:00 수업 · 학생 1건');
  });
});

describe('강사 사유 취소 안내·보강 잡는 방법 (2026-10-26 대표)', () => {
  const lesson = L('x1', '2026-10-26', '23:30');
  const tutorLate: ChangeDecision = { ...adv, status: 'Tutor canceled late', who: 'tutor', uses_credit: false, reward_won: 2000, makeup_until: '2026-11-16' };
  const c: NoticeContext = { student, durationMin: 50, lesson, decision: tutorLate, tutorName: 'Alex', tutorTz: 'Asia/Manila' };
  it('학생: 사과 + 적립금 사용처, 당연한 말(변경권 차감 없음) 없음, 보강은 강사와 정해도 됨', () => {
    const t = studentNotice('change', c);
    expect(t).toContain('불편을 드려 정말 죄송합니다. 사과의 마음으로 다음 수강 등록 시 사용하실 수 있는 적립금 2,000원을 드렸어요 (유효기간 없음).');
    expect(t).not.toContain('직전');
    expect(t).not.toContain('변경권');
    expect(t).toContain('강사님과 수업 중에 일정을 정하시거나, 저희에게 말씀해 주세요.');
  });
  it('학생 본인 취소 안내 = 대표 문구 그대로 (2026-10-26)', () => {
    const lesson = L('k', '2026-11-05', '10:00');
    const d: ChangeDecision = { ...adv, credits_after: 1, makeup_until: '2026-11-16' };
    expect(studentNotice('change', { student: { ...student, nameKo: '가상변경' }, durationMin: 50, lesson, decision: d, tutorName: 'A', tutorTz: 'Asia/Seoul' })).toBe(
      '[엣지영어] 가상변경님, 요청하신 수업이 취소됐어요.\n\n취소된 수업: 11월 5일(목) 오전 10시\n변경권 1개 사용 (잔여 1개)\n\n' +
        '보강은 수강기간 종료일인 11월 16일(월)까지 진행하실 수 있어요. 강사님과 수업 중에 일정을 정하시거나, 저희에게 말씀해 주세요.\n\n' +
        '취소된 수업 날짜가 요청하신 날짜와 다르다면 바로 알려주세요.',
    );
  });
  it('강사: 학생과 이야기해도 되지만 직접 확정 금지, 종료일까지', () => {
    const t = tutorNotice('change', c);
    expect(t).toContain('until Mon 16 Nov');
    expect(t).toContain('do NOT confirm it yourself');
    expect(tutorNotice('change', { ...c, decision: { ...adv, status: 'Student canceled late', makeup_allowed: false, makeup_until: null } })).not.toContain('Make-up');
  });
});

describe('보강 시간 입력: 강사 현지 날짜·시각 (2026-10-26 대표)', () => {
  it('한국 시각을 강사 현지로 바꿔 보여 주고 날짜가 바뀌어도 정확히', async () => {
    const { tutorLocalLabel } = await import('./lesson-change');
    expect(tutorLocalLabel(kstToInstant('2026-11-06', '10:00'), 'Asia/Manila')).toBe('11/6 (금) 09:00');
    expect(tutorLocalLabel(kstToInstant('2026-11-06', '10:00'), 'America/Toronto')).toBe('11/5 (목) 20:00');
    expect(tutorLocalLabel(kstToInstant('2026-11-06', '10:00'), 'Asia/Seoul')).toBeNull();
  });
  it('강사 확인 전 보강 신청은 학생에게 확정처럼 안내하지 않음 (학생 안내 없음)', () => {
    const c: NoticeContext = { student, durationMin: 50, lesson: L('x', '2026-10-29', '17:00'), candidates: [kstToInstant('2026-11-06', '10:00')], tutorName: 'A', tutorTz: 'Asia/Manila' };
    expect(studentNotice('makeup_ask', c)).toBe('');
    expect(tutorNotice('makeup_ask', c)).toContain('not confirmed yet');
  });
});
