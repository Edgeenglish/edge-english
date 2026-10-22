// 운영자 대시보드 '처리할 일' 목록 (가상 데이터)
import { describe, expect, it } from 'vitest';
import { buildBoard, categoryCounts, dueSeverity, dueText, filterBoard } from './board';
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
    expect(items[1]).toMatchObject({ id: 'm-2', severity: 'urgent', tag: '강사 안내 안 함' }); // 확정 2시간째 강사 안내 안 함 (D-51-3)
    expect(items[2]).toMatchObject({ id: 'm-1', severity: 'overdue', tag: '강사 답 대기' });
    expect(items.map((i) => i.severity)).toEqual([...items.map((i) => i.severity)].sort((a, b) => ['urgent', 'overdue', 'due_soon', 'open'].indexOf(a) - ['urgent', 'overdue', 'due_soon', 'open'].indexOf(b)));
    expect(items[0].tag).toBe('노쇼 신고');
  });
  it('매칭: 일정안이 있으면 버튼 대신 일정안 카드 (확정·안내 복사)', () => {
    const m2 = items.find((i) => i.id === 'm-2')!;
    expect(m2.plan?.state).toBe('confirmed');
    expect(m2.actions).toEqual([]);
    expect(m2.title).toBe('가상학생이 · 한국');
  });
  it('매칭: 첫 수업 24시간 안인데 안내 미완료면 노쇼 신고보다도 맨 위', () => {
    const tasks = fakeTasks(now).map((t) =>
      t.kind === 'new_student_matching' && t.plan?.state === 'confirmed' ? { ...t, plan: { ...t.plan, startDate: '2026-10-16', slots: [{ weekday: 5, time: '20:00' }] } } : t,
    );
    const top = buildBoard(tasks, now)[0];
    expect(top).toMatchObject({ id: 'm-2', top: true, due: '첫 수업 24시간 안 — 지금 보내 주세요' });
  });
  it('매칭: 일정안 없으면 기존 단계 (강사 배정 → 학생 안내)', () => {
    const m3 = items.find((i) => i.id === 'm-3')!;
    expect(m3.steps.map((s) => s.done)).toEqual([false, false]);
    expect(m3.actions[0].key).toBe('assign_tutor');
  });
  it('재등록: 통보만 했으면 강사 확인이 다음 단계, 미확인 시간 표시', () => {
    const r = items.find((i) => i.id === 'r-1')!;
    expect(r.steps.map((s) => s.done)).toEqual([true, false, false]);
    expect(r.actions.map((a) => a.key)).toEqual(['remind_tutor', 'tutor_ack']);
    expect(r.due).toBe('통보 후 26시간째 미확인');
  });
  it('요약 카드 5칸: 한 업무는 한 칸에만 (합계 = 전체, 중복 없음)', () => {
    const c = categoryCounts(items);
    expect(Object.values(c).reduce((s, x) => s + x.n, 0)).toBe(items.length);
    expect(c).toMatchObject({ matching: { n: 3 }, tutor_ack: { n: 1 }, ending: { n: 2 }, makeup: { n: 1 }, issue: { n: 3 } });
  });
  it('필터: 긴급 = 노쇼·기한 초과·24시간 안, 오류만 = 노쇼 신고·자동 처리 실패 (승인 대기는 제외)', () => {
    expect(filterBoard(items, 'urgent').every((i) => i.severity !== 'open')).toBe(true);
    expect(filterBoard(items, 'error').map((i) => i.kind).sort()).toEqual(['auto_failure', 'no_show_report']);
    expect(filterBoard(items, 'ending').map((i) => i.id)).toEqual(['e-1', 'e-2']);
    expect(filterBoard(items, 'all')).toHaveLength(items.length);
  });
  it('종료 임박은 종료일이 24시간 안이면 긴급, 오류는 늘 긴급', () => {
    expect(items.find((i) => i.id === 'e-1')!.severity).toBe('due_soon');
    expect(items.find((i) => i.id === 'e-2')!.severity).toBe('open');
    expect(items.find((i) => i.id === 'f-1')!.severity).toBe('overdue');
  });
});

describe('재등록 통보의 새 기간 (가상 데이터, 기한 안 재등록 — 정책 원본 A25)', () => {
  const period = (at: string) => {
    const t = fakeTasks(new Date(at)).find((x) => x.kind === 'renewal_tutor_notice');
    return t && t.kind === 'renewal_tutor_notice' ? t.newPeriod : '';
  };
  it('종료 다음 날이 아니라 종료 뒤 처음 오는 정규 수업일(화·목)부터 28일', () => {
    expect(period('2026-10-16T05:00:00Z')).toBe('10/20(화)–11/16(월)'); // 금요일 종료 → 다음 화요일
    expect(period('2026-10-20T05:00:00Z')).toBe('10/22(목)–11/18(수)'); // 원본 예시: 10/20 종료 → 10/22 시작
  });
});
