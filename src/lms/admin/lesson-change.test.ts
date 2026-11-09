import { describe, expect, it } from 'vitest';
import { kstToInstant } from '../rules/dates';
import { canceledUpcoming, changeableLessons, decisionLines, emailStatusText, kstLabel, makeupRights, studentNotice, tutorNotice, type ChangeDecision, type ChLesson, type NoticeContext } from './lesson-change';
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
    expect(kstLabel(list[1].startsAt)).toBe('10/29 (목) 오후 5:00');
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
    expect(decisionLines(adv)).toEqual(['수강생 정상 변경 · 수업 44시간 전 요청', '변경권 2 → 1', '보강 1/5 (화)까지']);
    expect(decisionLines({ ...adv, status: 'Tutor canceled late', who: 'tutor', uses_credit: false, reward_won: 2000 })).toContain('수강생 적립금 2,000원');
  });

  it('안내 문구: 원래 수업 날짜와 보강 날짜를 모두 실제 날짜로 (수강생 한국어, 강사 현지 시각 영어)', () => {
    const lesson = L('x1', '2026-10-29', '17:00');
    const c: NoticeContext = { student, durationMin: 50, lesson, decision: adv, tutorName: 'Alex', tutorTz: 'Asia/Manila', makeupAt: kstToInstant('2026-10-30', '18:00') };
    expect(studentNotice('change', c)).toContain('취소된 수업: 10월 29일(목) 오후 5시 [한국 시간]\n변경권 1개 사용 (잔여 1개)');
    expect(studentNotice('change', c)).toContain('(신청 기한: 1월 5일(화) 오후 11시 59분 [한국 시간]까지)');
    const conf = studentNotice('makeup_confirmed', c);
    expect(conf).toContain('원래 수업: 10월 29일(목) 오후 5시 [한국 시간]');
    expect(conf).toContain('보강 수업: 10월 30일(금) 오후 6시 [한국 시간]');
    expect(tutorNotice('makeup_confirmed', c)).toContain('Make-up: Fri, 30 Oct 5:00 PM *Manila Time* / 6:00 PM *KST*');
    expect(tutorNotice('makeup_ask', { ...c, candidates: [kstToInstant('2026-10-30', '18:00')] })).toContain('not confirmed yet');
    // 운영진이 확정된 보강 시간을 고침 (2026-11-08): 바뀐 시간 + 이전 시간(취소) 둘 다
    const fixed = { ...c, makeupAt: kstToInstant('2026-10-30', '20:00'), oldAt: kstToInstant('2026-10-30', '18:00') };
    expect(tutorNotice('makeup_rescheduled', fixed)).toContain('New time: Fri, 30 Oct 7:00 PM *Manila Time* / 8:00 PM *KST*');
    expect(tutorNotice('makeup_rescheduled', fixed)).toContain('Previous time (canceled): Fri, 30 Oct 5:00 PM *Manila Time*');
    expect(studentNotice('makeup_rescheduled', fixed)).toContain('보강 시간이 바뀌었어요');
    expect(studentNotice('makeup_rescheduled', fixed)).toContain('바뀐 시간: 10월 30일(금) 오후 8시 [한국 시간]');
    expect(studentNotice('makeup_rescheduled', fixed)).toContain('이전 시간: 10월 30일(금) 오후 6시 [한국 시간] (취소)');
    // 운영진 수업 수정에서 강사만 / 시간·강사 둘 다 바꿈 (20261109040000): 학생 1건, 이전 강사에게 취소
    const tutorOnly = { ...c, oldAt: c.makeupAt, oldTutorName: 'Benny' };
    expect(studentNotice('makeup_rescheduled', tutorOnly)).toContain('보강 강사가 바뀌었어요');
    expect(studentNotice('makeup_rescheduled', tutorOnly)).toContain('보강 수업: 10월 30일(금) 오후 6시 [한국 시간]\n이전 강사: Benny');
    const both = { ...fixed, oldTutorName: 'Benny' };
    expect(studentNotice('makeup_rescheduled', both)).toContain('보강 시간·강사가 바뀌었어요');
    expect(studentNotice('makeup_rescheduled', both)).toContain('이전: 10월 30일(금) 오후 6시 [한국 시간] · Benny (취소)');
    expect(tutorNotice('makeup_tutor_removed', { ...fixed, tutorName: 'Benny' })).toBe(
      'CANCELED make-up - Minsu Kim (50 min)\nMake-up: Fri, 30 Oct 5:00 PM *Manila Time* / 6:00 PM *KST*\nNo class at this time. Please remove it from your schedule. Thank you!');
    const abroad = studentNotice('change', { ...c, student: { ...student, timezone: 'America/Toronto' } });
    expect(abroad).toContain('10월 29일(목) 오전 4시 [토론토 시간] / 오후 5시 [한국 시간]');
  });

  it('대시보드: 안 보낸 안내·강사 답 대기 보강을 수강생마다 한 줄로, 수업이 24시간 안이면 급함', () => {
    const s = { id: 's', name_ko: '김민수', code: 'STU-0001' };
    const tasks = toLessonChanges([
      { created_at: '2026-10-26T10:00:00Z', event: 'change', recipient_kind: 'student', change: { student: s, lesson: { starts_at: kstToInstant('2026-10-27', '08:00').toISOString() } }, makeup: null },
      { created_at: '2026-10-26T10:00:00Z', event: 'change', recipient_kind: 'tutor', change: { student: s, lesson: { starts_at: kstToInstant('2026-10-27', '08:00').toISOString() } }, makeup: null },
    ], [{ created_at: '2026-10-26T10:00:00Z', student: s }], now);
    const [item] = buildBoard(tasks, now);
    // 무슨 일 · 할 일이 맨 위, 수업 날짜·받는 사람이 아래 (2026-10-28 대표: 스치듯 봐도 알게)
    expect(item.tag).toBe('수업 취소 안내 보내기');
    expect(item.detail).toBe('10/27(화) 오전 8시 수업 · 수강생·강사 2건 · 보강 강사 답 대기 1건');
    expect(item.severity).toBe('due_soon');
    expect(item.actions[0].href).toBe('/lms/admin/change?student=STU-0001');
  });

  it('대시보드: 강사 답만 기다리는 보강 신청은 할 일에 올리지 않음 (대표 11/9)', () => {
    const s = { id: 's', name_ko: '김민수', code: 'STU-0001' };
    expect(toLessonChanges([], [{ created_at: '2026-10-26T10:00:00Z', student: s }], now)).toEqual([]);
    // 강사가 모두 불가라고 답한 신청(예외)은 그대로
    const [item] = buildBoard(toLessonChanges([], [{ created_at: '2026-10-26T10:00:00Z', tutor_answered_at: '2026-10-27T10:00:00Z', student: s, candidates: [{ tutor_answer: 'no', proposed_by: 'student' }] }], now), now);
    expect(item.tag).toBe('보강 강사 불가 · 재조율');
  });

  it('대시보드: 보강 확정 자동 메일을 못 보낸 수강생은 카드로 (운영진이 직접 보내기)', () => {
    const s = { id: 's', name_ko: '이도연', code: 'STU-0008' };
    const [item] = buildBoard(toLessonChanges([], [], now, [
      { created_at: '2026-11-07T10:00:00Z', recipient_kind: 'tutor', email_status: 'failed', makeup: { student: s } },
    ]), now);
    expect(item.tag).toBe('자동 메일 못 보냄');
    expect(item.detail).toContain('자동 메일 못 보냄 강사 1건 — 직접 보내기');
    expect(item.actions[0].href).toBe('/lms/admin/change?student=STU-0008');
  });

  it('대시보드: 수업 취소 자동 메일(강사 사정 취소 등)을 못 보내도 카드로 (11/9)', () => {
    const s = { id: 's2', name_ko: '김하준', code: 'STU-0009' };
    const [item] = buildBoard(toLessonChanges([], [], now, [
      { created_at: '2026-11-09T10:00:00Z', recipient_kind: 'student', email_status: 'no_address', makeup: null, change: { student: s } },
    ]), now);
    expect(item.tag).toBe('자동 메일 못 보냄');
    expect(item.detail).toContain('자동 메일 못 보냄 수강생 1건 — 직접 보내기');
    expect(item.actions[0].href).toBe('/lms/admin/change?student=STU-0009');
  });

  it('안내 줄 자동 메일 상태 글', () => {
    const lbl = () => '11/7 21:03';
    expect(emailStatusText({ status: 'sent', to: 'support@edgeenglish.kr', intended: 'a@b.kr', sentAt: now, error: null, attempts: 1 }, lbl)).toBe('자동 메일 보냄 11/7 21:03 · support@edgeenglish.kr (시험 · 원래 a@b.kr)');
    expect(emailStatusText({ status: 'failed', to: 'a@b.kr', intended: 'a@b.kr', sentAt: null, error: '422 bad address', attempts: 1 }, lbl)).toBe('자동 메일 실패 · 422 bad address · a@b.kr');
    expect(emailStatusText({ status: 'no_address', to: null, intended: null, sentAt: null, error: '강사 이메일이 없어요', attempts: 0 }, lbl)).toBe('자동 메일 못 보냄 · 강사 이메일이 없어요');
    expect(emailStatusText({ status: 'queued', to: 'a@b.kr', intended: 'a@b.kr', sentAt: null, error: null, attempts: 1 }, lbl)).toBe('자동 메일 보내는 중 · a@b.kr');
  });

  it('대시보드: 수업이 이미 지났어도 안내 카드에 그 수업 날짜가 보임', () => {
    const s = { id: 's', name_ko: '송예나', code: 'STU-0004' };
    const [item] = buildBoard(toLessonChanges([
      { created_at: '2026-10-28T10:00:00Z', event: 'change', recipient_kind: 'student', change: { type: 'student_cancel', student: s, lesson: { starts_at: kstToInstant('2026-10-20', '09:00').toISOString(), kind: 'regular' } }, makeup: null },
      { created_at: '2026-10-28T10:00:00Z', event: 'change', recipient_kind: 'tutor', change: { type: 'student_cancel', student: s, lesson: { starts_at: kstToInstant('2026-10-20', '09:00').toISOString(), kind: 'regular' } }, makeup: null },
    ], [], now), now);
    expect(item.tag).toBe('수업 취소 안내 보내기');
    expect(item.detail).toBe('10/20(화) 오전 9시 정규 수업 수강생측 취소 · 수강생·강사 2건');
  });
});

describe('강사 사유 취소 안내·보강 잡는 방법 (2026-10-26 대표)', () => {
  const lesson = L('x1', '2026-10-26', '23:30');
  const tutorLate: ChangeDecision = { ...adv, status: 'Tutor canceled late', who: 'tutor', uses_credit: false, reward_won: 2000, makeup_until: '2026-11-16' };
  const c: NoticeContext = { student, durationMin: 50, lesson, decision: tutorLate, tutorName: 'Alex', tutorTz: 'Asia/Manila' };
  it('수강생: 사과 + 적립금 사용처, 당연한 말(변경권 차감 없음) 없음, 보강은 강사와 정해도 됨', () => {
    const t = studentNotice('change', c);
    expect(t).toContain('불편을 드려 정말 죄송합니다. 사과의 마음으로 다음 수강 등록 시 사용하실 수 있는 적립금 2,000원을 드렸어요 (유효기간 없음).');
    expect(t).not.toContain('직전');
    expect(t).not.toContain('변경권');
    // 11/8 대표: 수강생이 LMS 바로가기에서 직접 신청 (수업 중에 강사와 정한 시간도)
    expect(t).not.toContain('저희에게 말씀해 주세요');
    expect(t).toContain('아래 링크에서 보강 날짜를 신청해 주세요. 강사님이 확인하면 확정돼요.\n수업 중에 강사님과 정한 시간이 있다면 그 시간을 골라 주세요.\n(신청 기한: 11월 16일(월) 오후 11시 59분 [한국 시간]까지)\n/lms/student?makeup=x1');
  });
  it('해외 수강생 신청 기한: (도시 시간) = [한국 시간]', () => {
    const t = studentNotice('change', { ...c, student: { ...student, timezone: 'America/Toronto' } });
    expect(t).toContain('(신청 기한: 11월 16일(월) 오전 9시 59분 [토론토 시간] / 오후 11시 59분 [한국 시간]까지)');
  });
  it('수강생 본인 취소 안내 = 대표 문구 그대로 (2026-10-26)', () => {
    const lesson = L('k', '2026-11-05', '10:00');
    const d: ChangeDecision = { ...adv, credits_after: 1, makeup_until: '2026-11-16' };
    expect(studentNotice('change', { student: { ...student, nameKo: '가상변경' }, durationMin: 50, lesson, decision: d, tutorName: 'A', tutorTz: 'Asia/Seoul' })).toBe(
      '[엣지영어] 가상변경님, 요청하신 수업이 취소됐어요.\n\n취소된 수업: 11월 5일(목) 오전 10시 [한국 시간]\n변경권 1개 사용 (잔여 1개)\n\n' +
        '아래 링크에서 보강 날짜를 신청해 주세요. 강사님이 확인하면 확정돼요.\n수업 중에 강사님과 정한 시간이 있다면 그 시간을 골라 주세요.\n(신청 기한: 11월 16일(월) 오후 11시 59분 [한국 시간]까지)\n/lms/student?makeup=k\n\n' +
        '취소된 수업 날짜가 요청하신 날짜와 다르다면 바로 알려주세요.',
    );
  });
  it('강사: 수업 중에 정해도 되고, 수강생이 LMS 로 신청 → Confirm make-up (11/8 대표), 기한은 강사 현지 + KST', () => {
    const t = tutorNotice('change', c);
    expect(t).toContain('(until Mon, 16 Nov 10:59 PM *Manila Time* / 11:59 PM *KST*)');
    expect(t).toContain('Availability');
    expect(t).toContain('tap "Confirm make-up"');
    expect(t).not.toContain('do NOT confirm');
    expect(tutorNotice('change', { ...c, decision: { ...adv, status: 'Student canceled late', makeup_allowed: false, makeup_until: null } })).not.toContain('Make-up');
  });
  it('강사 WhatsApp: 수강생 취소는 대화체 (대표 11/8 문구)', () => {
    const lesson = L('k', '2026-11-09', '20:00');
    const base = { student, durationMin: 50, lesson, tutorName: 'Maria', tutorTz: 'Asia/Ho_Chi_Minh' };
    expect(tutorNotice('change', { ...base, decision: { ...adv, makeup_until: '2026-11-16' } })).toBe(
      `Hi Maria,\n\n${student.nameEn} cancelled their class on Mon, 9 Nov 6:00 PM *Ho Chi Minh Time* / 8:00 PM *KST*.\n\n` +
        `For the make-up, ${student.nameEn.split(' ')[0]} can request a time in the LMS. If you agree on a time during class, just make sure it's open in your Availability and ask ${student.nameEn.split(' ')[0]} to request it in the LMS.\n\nThanks!`,
    );
    expect(tutorNotice('change', { ...base, decision: { ...adv, status: 'Student canceled late', makeup_allowed: false, makeup_until: null } }))
      .toBe(`Hi Maria,\n\n${student.nameEn} cancelled their class on Mon, 9 Nov 6:00 PM *Ho Chi Minh Time* / 8:00 PM *KST*.\n\nThanks!`);
    expect(tutorNotice('change', { ...base, decision: { ...adv, makeup_until: '2026-11-16' }, makeup: { state: 'confirmed', at: L('m', '2026-11-12', '20:00').startsAt } }))
      .toContain('Make-up already confirmed: Thu, 12 Nov 6:00 PM *Ho Chi Minh Time* / 8:00 PM *KST*');
  });
});

describe('보강 시간 입력: 강사 현지 날짜·시각 (2026-10-26 대표)', () => {
  it('한국 시각을 강사 현지로 바꿔 보여 주고 날짜가 바뀌어도 정확히', async () => {
    const { tutorLocalLabel } = await import('./lesson-change');
    expect(tutorLocalLabel(kstToInstant('2026-11-06', '10:00'), 'Asia/Manila')).toBe('11/6 (금) 오전 9:00');
    expect(tutorLocalLabel(kstToInstant('2026-11-06', '10:00'), 'America/Toronto')).toBe('11/5 (목) 오후 8:00');
    expect(tutorLocalLabel(kstToInstant('2026-11-06', '10:00'), 'Asia/Seoul')).toBeNull();
  });
  it('강사 확인 전 보강 신청은 수강생에게 확정처럼 안내하지 않음 (수강생 안내 없음)', () => {
    const c: NoticeContext = { student, durationMin: 50, lesson: L('x', '2026-10-29', '17:00'), candidates: [kstToInstant('2026-11-06', '10:00')], tutorName: 'A', tutorTz: 'Asia/Manila' };
    expect(studentNotice('makeup_ask', c)).toBe('');
    expect(tutorNotice('makeup_ask', c)).toContain('not confirmed yet');
  });
});

describe('보강 권리 목록 — 보강이 한 번 잡힌 원래 수업은 권리 아님 (QA-13·R-24)', async () => {
  const { makeupRights } = await import('./lesson-change');
  const L = (over: Partial<import('./lesson-change').ChLesson>): import('./lesson-change').ChLesson => ({
    id: 'x', kind: 'regular', startsAt: new Date('2026-10-26T11:00:00Z'), endsAt: new Date('2026-10-26T11:40:00Z'), state: 'scheduled', classStatus: null,
    makeupOf: null, voided: false, ...over,
  } as import('./lesson-change').ChLesson);
  it('취소된 보강(voided 아님)이 달린 원래 수업은 목록에 없고(권리는 그 보강 수업을 따름), 보강을 없애면(voided) 원래 수업이 다시 권리', () => {
    const orig = L({ id: 'o', state: 'canceled', classStatus: 'Student canceled in advance' });
    const canceledMakeup = L({ id: 'm', kind: 'makeup', makeupOf: 'o', state: 'canceled', classStatus: 'Student canceled in advance' });
    expect(makeupRights([orig, canceledMakeup], [], []).map((r) => r.key)).toEqual(['m']);
    expect(makeupRights([orig, { ...canceledMakeup, voided: true }], [], []).map((r) => r.key)).toEqual(['o']);
    expect(makeupRights([orig], [], []).map((r) => r.key)).toEqual(['o']);
  });
});

describe('취소된 수업 목록 (대표 11/8)', () => {
  const now = kstToInstant('2026-11-08', '21:00');
  it('앞으로의 취소된 수업만, 시간순, 지운 수업은 뺌', () => {
    const list = [
      L('a', '2026-11-12', '20:00', { state: 'canceled' }),
      L('b', '2026-11-09', '20:00', { state: 'canceled' }),
      L('c', '2026-11-01', '20:00', { state: 'canceled' }),
      L('d', '2026-11-10', '20:00', { state: 'canceled', voided: true }),
      L('e', '2026-11-11', '20:00', { state: 'scheduled' }),
    ];
    expect(canceledUpcoming(list, now).map((l) => l.id)).toEqual(['b', 'a']);
  });
});
