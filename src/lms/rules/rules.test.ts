// 수강기간·변경권·보강 규칙 자동 테스트 (가짜 데이터만 사용)
// 실행: npm test

import { describe, expect, it } from 'vitest';
import { addDays, formatInZone, kstToInstant, weekdayOf } from './dates';
import { computePeriods, finalEndDate, periodOf, renewalStartDate } from './period';
import { generateRegularLessons, totalLessons } from './schedule';
import { creditsPerPeriod, isOfferedPlan, type PendingPolicy } from './policy';
import { evaluateStudentChange, evaluateTutorCancel, isMakeupSlotAllowed } from './change';
import { CLASS_STATUSES, STATUS_RULES, grantsMakeup } from './status';
import { CreditLedger } from './credits';
import { previewTutorLeave } from './leave';

const H = 60 * 60 * 1000;
const POLICY_A: PendingPolicy = { compensationRecancel: 'no_rebook' };
const POLICY_B: PendingPolicy = { compensationRecancel: 'same_as_regular' };

describe('수강기간 계산', () => {
  it('4주 = 시작일 포함 28일 (종료일 = 시작일 + 27)', () => {
    expect(computePeriods('2026-07-30', 4)).toEqual([{ index: 1, start: '2026-07-30', end: '2026-08-26' }]);
  });

  it('12주 = 28일 × 3기간, 끊김 없이 이어짐 (Master Sheet STU-0001 예시와 동일)', () => {
    expect(computePeriods('2026-07-30', 12)).toEqual([
      { index: 1, start: '2026-07-30', end: '2026-08-26' },
      { index: 2, start: '2026-08-27', end: '2026-09-23' },
      { index: 3, start: '2026-09-24', end: '2026-10-21' },
    ]);
  });

  it('24주 = 28일 × 6기간 (Master Sheet는 현재 3기간까지만 계산함)', () => {
    const p = computePeriods('2026-07-30', 24);
    expect(p).toHaveLength(6);
    expect(p[5]).toEqual({ index: 6, start: '2026-12-17', end: '2027-01-13' });
    expect(finalEndDate('2026-07-30', 24)).toBe('2027-01-13');
  });

  it('주말에 시작해도 같은 규칙 (토요일 시작)', () => {
    expect(weekdayOf('2026-10-17')).toBe(6);
    expect(finalEndDate('2026-10-17', 4)).toBe('2026-11-13');
  });

  it('공휴일에 시작해도 같은 규칙 (2026-10-09 한글날)', () => {
    expect(finalEndDate('2026-10-09', 4)).toBe('2026-11-05');
  });

  it('윤년·연말을 넘어가도 정확함', () => {
    expect(finalEndDate('2028-02-10', 4)).toBe('2028-03-08'); // 2028년 2월은 29일
    expect(finalEndDate('2026-12-20', 4)).toBe('2027-01-16');
  });

  it('4·12·24주 외에는 받지 않음', () => {
    // @ts-expect-error 8주는 없는 단위
    expect(() => computePeriods('2026-07-30', 8)).toThrow();
  });

  it('날짜가 몇 번째 기간인지', () => {
    expect(periodOf('2026-08-26', '2026-07-30', 12)?.index).toBe(1);
    expect(periodOf('2026-08-27', '2026-07-30', 12)?.index).toBe(2);
    expect(periodOf('2026-10-22', '2026-07-30', 12)).toBeNull();
    expect(periodOf('2026-07-29', '2026-07-30', 12)).toBeNull();
  });

  it('연장된 날짜는 마지막 기간에 포함', () => {
    expect(periodOf('2026-10-25', '2026-07-30', 12, 7)?.index).toBe(3);
  });

  describe('재등록 시작일', () => {
    const input = { previousFinalEnd: '2026-10-21', paidOn: '2026-10-24', firstLessonAfterPayment: '2026-10-27', firstLessonAfterPreviousEnd: '2026-10-23' };
    it('종료 후 결제 → 결제 후 첫 정규 수업일부터 (A21 확정)', () => {
      expect(renewalStartDate(input)).toBe('2026-10-27');
    });
    it('종료일까지 결제 → 종료일 다음 날이 아니라 종료 뒤 첫 정규 수업일부터 (A25 확정)', () => {
      expect(renewalStartDate({ ...input, paidOn: '2026-10-21' })).toBe('2026-10-23');
      expect(renewalStartDate({ ...input, paidOn: '2026-10-15' })).toBe('2026-10-23');
    });
    it('정책 원본 A25 예시: 10월 20일 종료, 다음 정규 수업 10월 22일 → 10월 22일 시작', () => {
      expect(
        renewalStartDate({ previousFinalEnd: '2026-10-20', paidOn: '2026-10-20', firstLessonAfterPayment: '2026-10-22', firstLessonAfterPreviousEnd: '2026-10-22' }),
      ).toBe('2026-10-22');
    });
    it('첫 수업일이 결제일보다 앞이면 오류', () => {
      expect(() => renewalStartDate({ ...input, firstLessonAfterPayment: '2026-10-23' })).toThrow();
    });
    it('종료일까지 결제했는데 첫 수업일이 종료일 이전이면 오류', () => {
      expect(() => renewalStartDate({ ...input, paidOn: '2026-10-21', firstLessonAfterPreviousEnd: '2026-10-21' })).toThrow();
    });
  });
});

describe('정규 수업 회차 만들기', () => {
  it('화·목 주 2회 4주 = 8회, 모두 기간 안, 시작일 포함', () => {
    // 2026-07-30(목) 시작, 화(2)·목(4) 17:00 KST
    const lessons = generateRegularLessons({
      startDate: '2026-07-30',
      weeks: 4,
      slots: [
        { weekday: 2, time: '17:00' },
        { weekday: 4, time: '17:00' },
      ],
      durationMin: 50,
    });
    expect(lessons).toHaveLength(totalLessons(2, 4));
    expect(lessons[0].kstDate).toBe('2026-07-30');
    expect(lessons[1].kstDate).toBe('2026-08-04');
    expect(lessons.at(-1)!.kstDate).toBe('2026-08-25');
    expect(lessons.every((l) => l.kstDate >= '2026-07-30' && l.kstDate <= '2026-08-26')).toBe(true);
  });

  it('어느 요일에 시작해도 기간마다 주 횟수 × 4회', () => {
    for (let i = 0; i < 7; i++) {
      const start = addDays('2026-11-01', i);
      const wd = weekdayOf(start);
      const lessons = generateRegularLessons({
        startDate: start,
        weeks: 12,
        slots: [
          { weekday: wd, time: '09:00' },
          { weekday: (wd + 2) % 7, time: '09:00' },
          { weekday: (wd + 4) % 7, time: '21:30' },
        ],
        durationMin: 20,
      });
      expect(lessons).toHaveLength(36);
      for (const p of [1, 2, 3]) expect(lessons.filter((l) => l.periodIndex === p)).toHaveLength(12);
    }
  });

  it('시작일이 수업 요일이 아니면 거부 (최초 시작일 = 첫 정규 수업일)', () => {
    expect(() =>
      generateRegularLessons({ startDate: '2026-07-29', weeks: 4, slots: [{ weekday: 4, time: '17:00' }], durationMin: 50 }),
    ).toThrow(/첫 정규 수업일/);
  });

  it('저장 시각은 UTC — KST 17:00 = UTC 08:00', () => {
    const [l] = generateRegularLessons({ startDate: '2026-07-30', weeks: 4, slots: [{ weekday: 4, time: '17:00' }], durationMin: 50 });
    expect(l.startsAt.toISOString()).toBe('2026-07-30T08:00:00.000Z');
    expect(l.endsAt.toISOString()).toBe('2026-07-30T08:50:00.000Z');
  });

  it('KST 자정 넘는 시간대도 한국 날짜 기준 (00:30 수업 = 전날 UTC 15:30)', () => {
    expect(kstToInstant('2026-11-02', '00:30').toISOString()).toBe('2026-11-01T15:30:00.000Z');
  });
});

describe('시간대·서머타임 (한국 시간은 고정, 현지 시간만 바뀜)', () => {
  const lesson = (date: string) => kstToInstant(date, '17:00');

  it('시드니: 서머타임 시작(2026-10-04) 전후로 현지 시각이 1시간 바뀜', () => {
    expect(formatInZone(lesson('2026-10-01'), 'Australia/Sydney').time).toBe('18:00');
    expect(formatInZone(lesson('2026-10-08'), 'Australia/Sydney').time).toBe('19:00');
  });

  it('브리즈번(퀸즐랜드)은 서머타임 없음', () => {
    expect(formatInZone(lesson('2026-10-01'), 'Australia/Brisbane').time).toBe('18:00');
    expect(formatInZone(lesson('2026-10-08'), 'Australia/Brisbane').time).toBe('18:00');
  });

  it('토론토: 서머타임 종료(2026-11-01) 전후, 현지 날짜도 정확히', () => {
    // KST 2026-10-30 09:00 = 토론토 10-29 20:00 (EDT, UTC-4)
    expect(formatInZone(kstToInstant('2026-10-30', '09:00'), 'America/Toronto')).toMatchObject({ date: '2026-10-29', time: '20:00' });
    // KST 2026-11-06 09:00 = 토론토 11-05 19:00 (EST, UTC-5)
    expect(formatInZone(kstToInstant('2026-11-06', '09:00'), 'America/Toronto')).toMatchObject({ date: '2026-11-05', time: '19:00' });
  });
});

describe('변경권 개수', () => {
  it('주 1회=1, 주 2회=2, 주 3회 이상=3', () => {
    expect(creditsPerPeriod(1)).toBe(1);
    expect(creditsPerPeriod(2)).toBe(2);
    expect(creditsPerPeriod(3)).toBe(3);
    expect(creditsPerPeriod(5)).toBe(3);
  });

  it('판매 중인 상품 조합만 허용 (50분 주 1회 가능, 20·40분은 주 2회부터)', () => {
    expect(isOfferedPlan(50, 1)).toBe(true);
    expect(isOfferedPlan(20, 1)).toBe(false);
    expect(isOfferedPlan(40, 5)).toBe(true);
    expect(isOfferedPlan(50, 5)).toBe(false);
    expect(isOfferedPlan(30, 2)).toBe(false);
  });

  it('같은 수업은 두 번 눌러도 한 번만 차감', () => {
    const ledger = new CreditLedger(2);
    expect(ledger.record({ periodIndex: 1, lessonId: 'L1', reason: 'student_change', delta: -1 })).toBe(true);
    expect(ledger.record({ periodIndex: 1, lessonId: 'L1', reason: 'student_change', delta: -1 })).toBe(false);
    expect(ledger.balance(1)).toBe(1);
  });

  it('0개 밑으로 내려가지 않고, 기간끼리 섞이지 않음', () => {
    const ledger = new CreditLedger(1);
    ledger.record({ periodIndex: 1, lessonId: 'L1', reason: 'student_change', delta: -1 });
    expect(() => ledger.record({ periodIndex: 1, lessonId: 'L2', reason: 'student_change', delta: -1 })).toThrow();
    expect(ledger.balance(2)).toBe(1);
  });

  it('운영자 복구는 지급 개수를 넘지 않음', () => {
    const ledger = new CreditLedger(1);
    expect(() => ledger.record({ periodIndex: 1, lessonId: 'L1', reason: 'restore_by_admin', delta: 1 })).toThrow();
  });
});

describe('학생 수업 변경 판정', () => {
  const startsAt = kstToInstant('2026-11-10', '22:00'); // 화요일 밤 10시
  const base = {
    lesson: { kind: 'regular' as const, kstDate: '2026-11-10', startsAt },
    finalEndDate: '2026-11-26',
    creditsLeft: 2,
    isKoreanPublicHoliday: false,
  };

  it('정확히 6시간 전(오후 4:00)은 정상 변경 — 변경권 사용, 보강 가능', () => {
    const d = evaluateStudentChange({ ...base, now: new Date(startsAt.getTime() - 6 * H) }, POLICY_A);
    expect(d).toMatchObject({ ok: true, timing: 'advance', status: 'Student canceled in advance', usesCredit: true, consumesLesson: false, makeupAllowed: true });
  });

  it('5시간 59분 전은 늦은 변경 — 수업 1회 소진, 변경권 유지, 보강 없음', () => {
    const d = evaluateStudentChange({ ...base, now: new Date(startsAt.getTime() - 6 * H + 60_000) }, POLICY_A);
    expect(d).toMatchObject({ ok: true, timing: 'late', status: 'Student canceled late', usesCredit: false, consumesLesson: true, makeupAllowed: false });
  });

  it('해외 학생도 현지 시간과 관계없이 같은 기준 (판정은 실제 시점 차이로만)', () => {
    const now = new Date(startsAt.getTime() - 7 * H);
    expect(evaluateStudentChange({ ...base, now }, POLICY_A)).toMatchObject({ timing: 'advance' });
  });

  it('변경권 0개면 사전 변경이어도 보강 없음, 수업 1회 소진', () => {
    const d = evaluateStudentChange({ ...base, creditsLeft: 0, now: new Date(startsAt.getTime() - 24 * H) }, POLICY_A);
    expect(d).toMatchObject({ status: 'No change credits left', usesCredit: false, consumesLesson: true, makeupAllowed: false });
  });

  it('공휴일 수업은 6시간 전까지면 변경권 차감 없음 (변경권 0개여도 가능)', () => {
    const d = evaluateStudentChange({ ...base, creditsLeft: 0, isKoreanPublicHoliday: true, now: new Date(startsAt.getTime() - 24 * H) }, POLICY_A);
    expect(d).toMatchObject({ status: 'Student canceled in advance (public holiday)', usesCredit: false, consumesLesson: false, makeupAllowed: true });
  });

  it('공휴일이라도 6시간 미만이면 늦은 변경', () => {
    const d = evaluateStudentChange({ ...base, isKoreanPublicHoliday: true, now: new Date(startsAt.getTime() - 1 * H) }, POLICY_A);
    expect(d).toMatchObject({ status: 'Student canceled late' });
  });

  it('이미 시작한 수업은 변경 불가', () => {
    expect(evaluateStudentChange({ ...base, now: startsAt }, POLICY_A)).toEqual({ ok: false, reason: 'already_started' });
  });

  it('수강기간 밖 수업은 변경 불가', () => {
    const d = evaluateStudentChange({ ...base, finalEndDate: '2026-11-09', now: new Date(startsAt.getTime() - 24 * H) }, POLICY_A);
    expect(d).toEqual({ ok: false, reason: 'outside_enrollment' });
  });

  it('보강 기한 = 최종 종료일(KST) 23:59까지 시작하는 수업', () => {
    const now = new Date(startsAt.getTime() - 24 * H);
    expect(isMakeupSlotAllowed(kstToInstant('2026-11-26', '23:30'), '2026-11-26', now)).toBe(true);
    expect(isMakeupSlotAllowed(kstToInstant('2026-11-27', '00:00'), '2026-11-26', now)).toBe(false);
    expect(isMakeupSlotAllowed(new Date(now.getTime() - H), '2026-11-26', now)).toBe(false);
  });

  describe('예약한 보강을 다시 변경 (정책 원본 A03 · POL-CHG-08, 기존 학생 포함 전원 — POL-OP-17)', () => {
    const makeup = { ...base, lesson: { ...base.lesson, kind: 'makeup' as const }, now: new Date(startsAt.getTime() - 24 * H) };

    it('정규와 같음 — 변경권 1개 사용 후 다시 보강 가능 (운영자 값과 관계없음)', () => {
      for (const p of [POLICY_A, POLICY_B]) {
        expect(evaluateStudentChange(makeup, p)).toMatchObject({ status: 'Student canceled in advance', usesCredit: true, makeupAllowed: true });
      }
    });

    it('반복 횟수 상한은 없고, 변경권 0개면 일반 규칙(보강 없음)', () => {
      expect(evaluateStudentChange({ ...makeup, creditsLeft: 0 }, POLICY_A)).toMatchObject({ status: 'No change credits left', makeupAllowed: false });
    });

    it('6시간 미만이면 일반 늦은 변경', () => {
      expect(evaluateStudentChange({ ...makeup, now: new Date(startsAt.getTime() - 2 * H) }, POLICY_A)).toMatchObject({ status: 'Student canceled late' });
    });

    it('보상 수업 재변경은 미확정(POL-TU-10) → 운영자 값을 따름', () => {
      const comp = { ...makeup, lesson: { ...makeup.lesson, kind: 'compensation' as const } };
      expect(evaluateStudentChange(comp, POLICY_A)).toMatchObject({ status: null, makeupAllowed: false });
      expect(evaluateStudentChange(comp, POLICY_B)).toMatchObject({ makeupAllowed: true });
    });
  });
});

describe('강사 사유 취소', () => {
  const startsAt = kstToInstant('2026-11-03', '20:00');
  it('6시간 전까지 = 정상 취소, 미만 = 늦은 취소', () => {
    expect(evaluateTutorCancel(new Date(startsAt.getTime() - 6 * H), startsAt)).toBe('Tutor canceled in advance');
    expect(evaluateTutorCancel(new Date(startsAt.getTime() - 2 * H), startsAt)).toBe('Tutor canceled late');
  });
  it('강사 사유 취소는 학생 변경권을 쓰지 않고 보강 가능', () => {
    for (const s of ['Tutor canceled in advance', 'Tutor canceled late', 'Tutor no-show'] as const) {
      expect(STATUS_RULES[s].usesCredit).toBe(false);
      expect(STATUS_RULES[s].consumesLesson).toBe(false);
      expect(grantsMakeup(s)).toBe(true);
    }
  });
});

describe('상태값 14개 (Master Sheet 상태매핑표 2026-10-16 기준)', () => {
  it('14개', () => expect(CLASS_STATUSES).toHaveLength(14));

  it('수강권 차감·변경권 차감·급여 지급이 시트와 같음', () => {
    // [상태, 페이 대상, 수강권 차감, 변경권 차감] — 시트에서 그대로 옮긴 값
    const sheet: [string, string, string, string][] = [
      ['Normal', 'Y', 'Y', 'N'],
      ['Make-up completed', 'Y', 'Y', 'N'],
      ['Student canceled in advance', 'N', 'N', 'Y'],
      ['Student canceled in advance (public holiday)', 'N', 'N', 'N'],
      ['Tutor canceled in advance', 'N', 'N', 'N'],
      ['Student canceled late', 'Y', 'Y', 'N'],
      ['Tutor canceled late', 'N', 'N', 'N'],
      ['Student no-show', 'Y', 'Y', 'N'],
      ['Tutor no-show', 'N', 'N', 'N'],
      ['Tutor long-term leave', 'N', 'N', 'N'],
      ['Student long-term leave', 'N', 'N', 'N'],
      ['No change credits left', 'Y', 'Y', 'N'],
      ['Tutor Late - Student Present', 'Y', 'Y', 'N'],
      ['Covered by another tutor', 'Y', 'Y', 'N'],
    ];
    const yn = (b: boolean) => (b ? 'Y' : 'N');
    for (const [status, pay, lesson, credit] of sheet) {
      const r = STATUS_RULES[status as keyof typeof STATUS_RULES];
      expect([status, yn(r.tutorPaid), yn(r.consumesLesson), yn(r.usesCredit)]).toEqual([status, pay, lesson, credit]);
    }
  });
});

describe('강사 휴무 일괄 처리 미리보기 (예: 11/2~11/10)', () => {
  const lessons = [
    { id: 'a1', tutorId: 'T1', studentId: 'S1', kstDate: '2026-11-01', state: 'scheduled' as const },
    { id: 'a2', tutorId: 'T1', studentId: 'S1', kstDate: '2026-11-02', state: 'scheduled' as const },
    { id: 'a3', tutorId: 'T1', studentId: 'S1', kstDate: '2026-11-05', state: 'scheduled' as const },
    { id: 'b1', tutorId: 'T1', studentId: 'S2', kstDate: '2026-11-10', state: 'scheduled' as const },
    { id: 'b2', tutorId: 'T1', studentId: 'S2', kstDate: '2026-11-11', state: 'scheduled' as const },
    { id: 'c1', tutorId: 'T1', studentId: 'S3', kstDate: '2026-11-04', state: 'canceled' as const },
    { id: 'd1', tutorId: 'T2', studentId: 'S4', kstDate: '2026-11-04', state: 'scheduled' as const },
  ];

  it('시작일·종료일 포함, 해당 강사의 예정 수업만, 학생별로 묶음', () => {
    expect(previewTutorLeave(lessons, 'T1', '2026-11-02', '2026-11-10')).toEqual([
      { studentId: 'S1', lessonIds: ['a2', 'a3'], dates: ['2026-11-02', '2026-11-05'] },
      { studentId: 'S2', lessonIds: ['b1'], dates: ['2026-11-10'] },
    ]);
  });
});
