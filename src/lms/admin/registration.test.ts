import { describe, expect, it } from 'vitest';
import { wishText, checkDraft, checkPayment, draftFromForm, EMPTY_DRAFT, EMPTY_PAYMENT, firstDateWarnings, planSummary, slotProblem, suggestTimezone, type FormResponse } from './registration';

const form: FormResponse = {
  ref: 'r1', submittedAt: '2026-10-15 14:22', nameKo: ' 가상학생 ', nameEn: 'Fake Student', email: 'Fake@Example.com ', phone: '010-0000-0000',
  countryCity: '영국 / 런던', ageGroup: '30대', gender: '여', concern: '비즈니스 이메일', duration: '50분', weekly: '주 2회', term: '3개월',
  desiredTime: '화·목 저녁 7시 이후', wishGrid: null, startWish: '2026. 11. 3', payerName: '가상학생', raw: [],
};

describe('신청서 → 등록 초안', () => {
  it('칸을 읽어 채우고 이메일은 소문자·공백 제거', () => {
    const d = draftFromForm(form);
    expect(d).toMatchObject({ source: 'form', nameKo: '가상학생', email: 'fake@example.com', country: '영국', city: '런던', timezone: 'Europe/London', durationMin: 50, weeklyCount: 2, weeks: 12, startWish: '2026-11-03', desiredTime: '화·목 저녁 7시 이후' });
    expect(checkDraft(d)).toEqual([]);
  });
  it('읽지 못한 값은 비워 두고 확인 필요로 표시', () => {
    const d = draftFromForm({ ...form, duration: '30분', weekly: '자주', term: '', countryCity: '미국' });
    expect([d.durationMin, d.weeklyCount, d.weeks, d.timezone]).toEqual([null, null, null, '']);
    expect(checkDraft(d).map((p) => p.field)).toEqual(['timezone', 'durationMin', 'weeklyCount', 'weeks']);
  });
  it('시간대가 여럿인 나라는 추천하지 않음', () => {
    expect(suggestTimezone('미국')).toBe('');
    expect(suggestTimezone('호주 브리즈번')).toBe('Australia/Brisbane');
  });
  it('직접 입력 빈 초안은 필수 칸을 모두 요구', () => {
    expect(checkDraft(EMPTY_DRAFT)).toHaveLength(7);
  });
});

describe('정규 시간 · 첫 수업일 · 요약', () => {
  it('주 횟수와 고른 시간 수가 같아야 함', () => {
    expect(slotProblem([{ weekday: 2, time: '20:00' }], 2)).toMatch('1개 더');
    expect(slotProblem([{ weekday: 2, time: '20:00' }, { weekday: 2, time: '21:00' }], 2)).toMatch('같은 요일');
    expect(slotProblem([{ weekday: 2, time: '20:00' }, { weekday: 4, time: '20:00' }], 2)).toBeNull();
  });
  it('12주 = 28일 × 3, 회차 = 주 횟수 × 주 수', () => {
    expect(planSummary({ weeks: 12, weeklyCount: 2 }, '2026-11-03')).toEqual({ startDate: '2026-11-03', endDate: '2027-01-25', periods: 3, lessons: 24 });
  });
  it('첫 수업일 경고', () => {
    expect(firstDateWarnings('2026-11-03', '2026-10-18', '2026-11-05')).toEqual(['학생 희망 시작일보다 빨라요']);
    expect(firstDateWarnings('2026-10-10', '2026-10-18', '')).toEqual(['첫 수업일이 오늘보다 앞이에요']);
  });
});

describe('결제 확인', () => {
  it('확인 전이면 검사 없음, 확인이면 방법·금액·날짜 필요', () => {
    expect(checkPayment(EMPTY_PAYMENT)).toEqual([]);
    expect(checkPayment({ ...EMPTY_PAYMENT, status: 'confirmed' })).toHaveLength(3);
  });
});

describe('희망 시간 (새 신청서 형식)', () => {
  it('요일 × 시간대 체크를 그대로 가져오고 요약', () => {
    const wishes = [{ weekday: 4, from: '19:00', to: '22:00' }, { weekday: 2, from: '19:00', to: '22:00' }, { weekday: 6, from: '09:00', to: '12:00' }];
    expect(draftFromForm({ ...form, wishGrid: wishes }).wishes).toEqual(wishes);
    expect(wishText(wishes)).toBe('화·목 19:00–22:00, 토 09:00–12:00');
  });
});
