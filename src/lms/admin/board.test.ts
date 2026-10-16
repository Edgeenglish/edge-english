// 운영자 대시보드 '처리할 일' 목록 (가상 데이터)
import { describe, expect, it } from 'vitest';
import { boardCounts, buildBoard, dueSeverity, dueText } from './board';
import { fakeTasks } from './fake-data';

const now = new Date('2026-10-16T05:00:00Z'); // KST 10/16(금) 14:00
const H = 3600e3;

describe('기한 상태 (매칭 3영업일)', () => {
  it('지남 / 24시간 안 / 여유', () => {
    expect(dueSeverity(new Date(now.getTime() - 1), now)).toBe('overdue');
    expect(dueSeverity(new Date(now.getTime() + 24 * H), now)).toBe('due_soon');
    expect(dueSeverity(new Date(now.getTime() + 25 * H), now)).toBe('open');
    expect(dueSeverity(null, now)).toBe('open');
  });
  it('문구는 한국 시간 기준', () => {
    expect(dueText(new Date('2026-10-21T14:59:59.999Z'), now)).toBe('10/21(수) 23:59까지');
    expect(dueText(new Date(now.getTime() + 9 * H), now)).toBe('9시간 남음 · 10/16(금) 23:00까지');
    expect(dueText(new Date(now.getTime() - 50 * H), now)).toMatch(/^기한 2일 지남/);
  });
});

describe('처리할 일 목록', () => {
  const items = buildBoard(fakeTasks(now), now);
  it('급한 순서: 노쇼 신고 → 기한 초과 → 24시간 안 → 나머지', () => {
    expect(items[0].severity).toBe('urgent');
    expect(items[1]).toMatchObject({ id: 'm-1', severity: 'overdue' });
    expect(items.map((i) => i.severity)).toEqual([...items.map((i) => i.severity)].sort((a, b) => ['urgent', 'overdue', 'due_soon', 'open'].indexOf(a) - ['urgent', 'overdue', 'due_soon', 'open'].indexOf(b)));
    expect(items[0].tag).toBe('노쇼 신고');
  });
  it('매칭: 강사만 배정하면 학생 안내 단계가 남아 있음', () => {
    const m2 = items.find((i) => i.id === 'm-2')!;
    expect(m2.steps.map((s) => s.done)).toEqual([true, false]);
    expect(m2.actions[0].key).toBe('notify_student');
  });
  it('재등록: 통보만 했으면 강사 확인이 다음 단계, 미확인 시간 표시', () => {
    const r = items.find((i) => i.id === 'r-1')!;
    expect(r.steps.map((s) => s.done)).toEqual([true, false, false]);
    expect(r.actions.map((a) => a.key)).toEqual(['remind_tutor', 'tutor_ack']);
    expect(r.due).toBe('통보 후 26시간째 미확인');
  });
  it('숫자 요약', () => {
    expect(boardCounts(items)).toMatchObject({ total: 6, overdue: 2, matching: 3, renewal: 1 });
  });
});
