import { describe, expect, it } from 'vitest';
import { paidStatus, productLabel } from './live';
import { tzHeader, tzTimeLabel } from '../tutor/screen';
import { makeupRights, type ChLesson } from '../admin/lesson-change';

describe('수강생 수강·결제 칸 (11/2 점검 ⑥: 내부 문구 노출)', () => {
  it('시트에서 옮긴 수강권은 운영 메모 대신 주 수만', () => {
    expect(productLabel({ duration_min: 40, weekly_count: 2, weeks: null, legacy_label: '기존 수강생 이관 · 4주 (결제는 시트)' })).toBe('40분 · 주 2회 · 4주');
    expect(productLabel({ duration_min: 20, weekly_count: 3, weeks: null, legacy_label: '기존 수강생 이관 (남은 기간만, 결제·변경권은 시트)' })).toBe('20분 · 주 3회');
    expect(productLabel({ duration_min: 50, weekly_count: 1, weeks: 12, legacy_label: null })).toBe('50분 · 주 1회 · 12주');
  });
  it('결제 확인 기록이 있거나 수강 중·확정 수강권이면 결제 완료, 결제 대기만 확인 중', () => {
    expect(paidStatus({ status: 'active', confirmed_on: null })).toBe(true);
    expect(paidStatus({ status: 'pending_payment', confirmed_on: null })).toBe(false);
    expect(paidStatus({ status: 'pending_payment', confirmed_on: '2026-11-01' })).toBe(true);
  });
});

describe('강사 화면 시간대 이름 (11/2 점검 ⑤)', () => {
  it("'[도시] Time / KST'", () => {
    expect(tzTimeLabel('Asia/Manila')).toBe('Manila Time');
    expect(tzTimeLabel('America/New_York')).toBe('New York Time');
    expect(tzHeader('Australia/Sydney')).toBe('Sydney Time / KST');
    expect(tzHeader('Asia/Seoul')).toBe('KST');
  });
});

describe('운영진 보강 칸: 강사 노쇼 수업의 원래 수업 보강과 무료 보상수업은 따로 (4100)', () => {
  const noShow = {
    id: 'L1', kind: 'regular', seq: 1, startsAt: new Date('2026-11-02T09:00:00Z'), state: 'done', classStatus: 'Tutor no-show', makeupOf: null,
    voided: false, tutorId: 'T', tutorName: 'Maria', tutorTz: 'Asia/Manila',
  } as ChLesson;
  const comp = { id: 'C1', sourceLessonId: 'L1', status: 'available' as const, useUntil: '2026-11-30' as const };
  it('신청이 없으면 두 줄, 보상 신청은 보상 줄에만 붙음', () => {
    const rights = makeupRights([noShow], [], [{ id: 'R1', sourceLessonId: 'L1', migratedItemId: null, compensationId: 'C1', status: 'requested', candidates: [], confirmedLessonId: null }], [comp]);
    expect(rights.map((r) => r.kind)).toEqual(['lesson', 'compensation']);
    expect(rights[0].open).toBeNull();
    expect(rights[1].open?.id).toBe('R1');
  });
  it('쓴 보상권(used)은 안 보임', () => {
    expect(makeupRights([noShow], [], [], [{ ...comp, status: 'used' }]).map((r) => r.kind)).toEqual(['lesson']);
  });
});
