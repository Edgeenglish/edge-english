import { describe, expect, it } from 'vitest';
import { kstToInstant } from './dates';
import { cellState, checkRegularPlan, clashes, firstLessonDateOnOrAfter, withinAvailability, type AvailabilityWindow, type Busy } from './booking';

const at = (d: string, t: string) => kstToInstant(d, t);
const plus = (x: Date, m: number) => new Date(x.getTime() + m * 60000);
const lesson = (id: string, d: string, t: string, min: number, kind: Busy['kind'] = 'regular'): Busy => ({ id, startsAt: at(d, t), endsAt: plus(at(d, t), min), kind });

// 서울 강사: 화·목 18:00–22:00 (서머타임 없음) — 판정 규칙만 보기 위한 단순 예
const seoul: AvailabilityWindow[] = [2, 4].map((weekday) => ({ weekday, startLocal: '18:00', endLocal: '22:00', timezone: 'Asia/Seoul', effectiveFrom: '2026-01-01', effectiveTo: null }));

describe('휴식 10분 · 실제 수업 길이로 판정', () => {
  it('50분 수업 20:00 뒤에는 21:00 시작 가능, 20:55 는 휴식 부족', () => {
    const busy = [lesson('a', '2026-11-03', '20:00', 50)];
    expect(clashes(at('2026-11-03', '21:00'), plus(at('2026-11-03', '21:00'), 40), busy)).toEqual([]);
    expect(clashes(at('2026-11-03', '20:55'), plus(at('2026-11-03', '20:55'), 20), busy)[0].reason).toBe('break');
  });
  it('40분 수업 20:00 → 20:50 시작은 가능 (30분 칸 표시와 별개)', () => {
    const busy = [lesson('a', '2026-11-03', '20:00', 40)];
    expect(clashes(at('2026-11-03', '20:50'), plus(at('2026-11-03', '20:50'), 20), busy)).toEqual([]);
    // 화면 칸으로는 20:30 칸이 '수업 있음'
    expect(cellState('2026-11-03', '20:30', 30, busy, seoul).state).toBe('regular');
  });
  it('새 수업 끝과 다음 수업 시작 사이도 10분 필요', () => {
    const busy = [lesson('a', '2026-11-03', '21:00', 50)];
    expect(clashes(at('2026-11-03', '20:00'), plus(at('2026-11-03', '20:00'), 50), busy)).toEqual([]); // 20:50 끝 → 10분
    expect(clashes(at('2026-11-03', '20:10'), plus(at('2026-11-03', '20:10'), 50), busy)[0].reason).toBe('break');
  });
  it('휴무는 겹칠 때만 (휴식 시간 적용 안 함)', () => {
    const busy = [lesson('off', '2026-11-03', '21:00', 120, 'time_off')];
    expect(clashes(at('2026-11-03', '20:00'), plus(at('2026-11-03', '20:00'), 60), busy)).toEqual([]);
  });
});

describe('일회성 보강은 그날만 막는다', () => {
  const makeup = lesson('mk', '2026-11-03', '20:00', 50, 'makeup'); // 11/3(화) 20:00 보강
  it('11/3 은 충돌, 이후 화요일 20:00 은 모두 가능', () => {
    const r = checkRegularPlan({ startDate: '2026-11-03', weeks: 4, slots: [{ weekday: 2, time: '20:00' }, { weekday: 4, time: '20:00' }], durationMin: 50, tutorBusy: [makeup], availability: seoul });
    expect(r.lessons).toHaveLength(8);
    expect(r.issues.map((i) => [i.kstDate, i.reason])).toEqual([['2026-11-03', 'tutor_makeup']]);
  });
  it('주간 칸: 11/3 은 보강 있음, 11/10 같은 시각은 가능', () => {
    expect(cellState('2026-11-03', '20:00', 30, [makeup], seoul).state).toBe('makeup');
    expect(cellState('2026-11-10', '20:00', 30, [makeup], seoul).state).toBe('available');
  });
  it('첫 수업일을 11/5 로 하면 11/3 보강과 상관없음', () => {
    const r = checkRegularPlan({ startDate: '2026-11-05', weeks: 4, slots: [{ weekday: 2, time: '20:00' }, { weekday: 4, time: '20:00' }], durationMin: 50, tutorBusy: [makeup], availability: seoul });
    expect(r.issues).toEqual([]);
  });
});

describe('등록기간 전체 검사', () => {
  it('기간 중간의 휴무·다른 학생 정규 수업 날짜를 모두 찾는다', () => {
    const busy = [lesson('off', '2026-11-19', '00:00', 24 * 60, 'time_off'), lesson('r', '2026-11-24', '20:30', 40)];
    const r = checkRegularPlan({ startDate: '2026-11-03', weeks: 4, slots: [{ weekday: 2, time: '20:00' }, { weekday: 4, time: '20:00' }], durationMin: 50, tutorBusy: busy, availability: seoul });
    expect(r.issues.map((i) => [i.kstDate, i.reason])).toEqual([['2026-11-19', 'tutor_time_off'], ['2026-11-24', 'tutor_regular']]);
  });
  it('강사 가능 시간 밖이면 표시', () => {
    const r = checkRegularPlan({ startDate: '2026-11-03', weeks: 4, slots: [{ weekday: 2, time: '21:30' }], durationMin: 50, tutorBusy: [], availability: seoul });
    expect(r.issues).toHaveLength(4);
    expect(r.issues.every((i) => i.reason === 'outside_availability')).toBe(true);
  });
  it('학생 본인 다른 수업도 검사', () => {
    const r = checkRegularPlan({ startDate: '2026-11-03', weeks: 4, slots: [{ weekday: 2, time: '20:00' }], durationMin: 50, tutorBusy: [], studentBusy: [lesson('s', '2026-11-10', '19:00', 55)], availability: seoul });
    expect(r.issues.map((i) => [i.kstDate, i.reason])).toEqual([['2026-11-10', 'student']]);
  });
});

describe('서머타임 자동 반영', () => {
  // 런던 강사: 월 10:00–14:00 (현지). 10/25 서머타임 끝 → 한국 시각이 1시간 늦어짐
  const london: AvailabilityWindow[] = [{ weekday: 1, startLocal: '10:00', endLocal: '14:00', timezone: 'Europe/London', effectiveFrom: '2026-01-01', effectiveTo: null }];
  it('10/19(월) 한국 18:00 = 런던 10:00 가능, 10/26(월) 한국 18:00 = 런던 09:00 불가', () => {
    expect(withinAvailability(at('2026-10-19', '18:00'), plus(at('2026-10-19', '18:00'), 50), london)).toBe(true);
    expect(withinAvailability(at('2026-10-26', '18:00'), plus(at('2026-10-26', '18:00'), 50), london)).toBe(false);
    expect(withinAvailability(at('2026-10-26', '19:00'), plus(at('2026-10-26', '19:00'), 50), london)).toBe(true);
  });
  it('기간 검사에서 서머타임 이후 날짜만 가능 시간 밖으로 잡힌다', () => {
    const r = checkRegularPlan({ startDate: '2026-10-19', weeks: 4, slots: [{ weekday: 1, time: '18:00' }], durationMin: 50, tutorBusy: [], availability: london });
    expect(r.issues.map((i) => i.kstDate)).toEqual(['2026-10-26', '2026-11-02', '2026-11-09']);
  });
});

describe('첫 수업일', () => {
  it('희망 시작일 이후 고른 요일 중 가장 빠른 날', () => {
    expect(firstLessonDateOnOrAfter('2026-11-01', [2, 4])).toBe('2026-11-03'); // 11/1(일) → 11/3(화)
    expect(firstLessonDateOnOrAfter('2026-11-04', [2, 4])).toBe('2026-11-05');
    expect(firstLessonDateOnOrAfter('2026-11-04', [])).toBeNull();
  });
});
