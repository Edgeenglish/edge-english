import { describe, expect, it } from 'vitest';
import { LEAVE_SORRY_GENERAL, LEAVE_SORRY_YEAR_END, isYearEndLeave, leaveButtonOk, leaveButtonWait, leaveRecommendLines, leaveSorryText } from './leave-notice';

const d = (s: string) => new Date(s);

describe('휴무 안내 문구 (대표 11/23)', () => {
  it('11월~1월과 겹치면 연말연초 문구', () => {
    expect(leaveSorryText(d('2026-12-22T13:00:00Z'), d('2027-01-04T13:00:00Z'), 'Australia/Sydney')).toBe(LEAVE_SORRY_YEAR_END);
    expect(leaveSorryText(d('2026-11-10T00:00:00Z'), d('2026-11-12T00:00:00Z'), 'Asia/Seoul')).toBe(LEAVE_SORRY_YEAR_END);
    expect(leaveSorryText(d('2027-01-20T00:00:00Z'), d('2027-01-25T00:00:00Z'), 'Asia/Seoul')).toBe(LEAVE_SORRY_YEAR_END);
  });
  it('겹치지 않으면 일반 문구', () => {
    expect(leaveSorryText(d('2027-03-08T15:00:00Z'), d('2027-03-13T15:00:00Z'), 'Asia/Seoul')).toBe(LEAVE_SORRY_GENERAL);
    expect(leaveSorryText(d('2026-10-10T00:00:00Z'), d('2026-10-17T00:00:00Z'), 'Asia/Seoul')).toBe(LEAVE_SORRY_GENERAL);
  });
  it('학생 시간대 날짜 기준: 10/31 23:00 서울은 10월, 같은 시각 시드니는 11/1', () => {
    const from = d('2026-10-31T14:00:00Z');
    const to = d('2026-10-31T14:59:00Z');
    expect(isYearEndLeave(from, to, 'Asia/Seoul')).toBe(false);
    expect(isYearEndLeave(from, to, 'Australia/Sydney')).toBe(true);
  });
  it('끝 시각(미포함)이 다음 달 0시면 그 달은 안 겹침', () => {
    expect(isYearEndLeave(d('2026-10-28T15:00:00Z'), d('2026-10-31T15:00:00Z'), 'Asia/Seoul')).toBe(false);
    expect(isYearEndLeave(d('2026-10-28T15:00:00Z'), d('2026-10-31T15:00:01Z'), 'Asia/Seoul')).toBe(true);
  });
  it('두 문구는 강사 휴무 때문에 기존 일정대로 수업이 어렵다는 설명과 사과를 모두 포함', () => {
    for (const t of [LEAVE_SORRY_GENERAL, LEAVE_SORRY_YEAR_END]) {
      expect(t).toContain('담당 강사님');
      expect(t).toContain('기존 일정대로 수업을 진행하기 어렵습니다');
      expect(t).toContain('불편을 드려 죄송합니다');
    }
  });
  it('추천 상자: 강사 이름은 중복 없이 하나로', () => {
    const r = leaveRecommendLines(['Olivia', 'Olivia']);
    expect(r.lines[1]).toBe('인기 강사님 중 한 분인 Olivia 선생님이 기존 수업 시간에 가능하세요.');
    expect(r.title.startsWith('⭐ 추천')).toBe(true);
  });
  it('추천 상자: 강사가 여러 명이면 이름을 나열', () => {
    expect(leaveRecommendLines(['Maria', 'Benny']).lines[1]).toBe('인기 강사님 중 Maria, Benny 선생님이 기존 수업 시간에 가능하세요.');
  });
  it('버튼 글', () => {
    expect(leaveButtonOk(2)).toBe('대체강사님과 2회 수업할게요');
    expect(leaveButtonWait(1)).toBe('기존 강사님과 1회 보강할게요');
  });
});
