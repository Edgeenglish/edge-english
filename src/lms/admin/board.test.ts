// 운영자 대시보드 '처리할 일' 목록 (가상 데이터)
import { describe, expect, it } from 'vitest';
import { buildBoard, categoryCounts, dueSeverity, dueText, filterBoard, waitText, type TaskSource } from './board';
import { fakeTasks } from './fake-data';

const now = new Date('2026-10-16T05:00:00Z'); // KST 10/16(금) 14:00
const H = 3600e3;

describe('기한 상태 (매칭 3영업일)', () => {
  it('지남 / 24시간 안 / 그 밖', () => {
    expect(dueSeverity(new Date(now.getTime() - 1), now)).toBe('overdue');
    expect(dueSeverity(new Date(now.getTime() + 24 * H), now)).toBe('due_soon');
    expect(dueSeverity(new Date(now.getTime() + 25 * H), now)).toBe('open');
    expect(dueSeverity(null, now)).toBe('open');
  });
  it('문구는 한국 시간 기준', () => {
    expect(dueText(new Date('2026-10-21T14:59:59.999Z'), now)).toBe('10/21(수) 오후 11:59까지');
    expect(dueText(new Date(now.getTime() + 9 * H), now)).toBe('9시간 남음 · 10/16(금) 오후 11:00까지');
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
  it('매칭: 일정안 없으면 [강사·시간 고르기] 화면으로', () => {
    const m3 = items.find((i) => i.id === 'm-3')!;
    expect(m3.steps).toEqual([]); // 할 일 목록은 버튼과 같은 말이라 안 보임
    expect(m3.actions[0]).toMatchObject({ key: 'pick_schedule', href: '/lms/admin/assign?e=demo' });
    expect(m3.actions[1]).toMatchObject({ label: '수업 컨펌 완료', disabled: true });
  });
  it('재등록: 일정 확정됐으면 [강사에게 통보] 하나 (강사 확인 단계 없음, 11/9 A안)', () => {
    const r = items.find((i) => i.id === 'r-1')!;
    expect(r.steps.map((s) => s.done)).toEqual([true, false]);
    expect(r.actions.map((a) => a.key)).toEqual(['notify_tutor']);
    expect(r.due).toBeNull();
  });
  it('칸 5개(보강 미신청 칸 없음 11/9, 강사 휴무 신청 칸 11/13): 한 업무는 한 칸에만 (합계 = 전체, 중복 없음)', () => {
    const c = categoryCounts(items);
    expect(Object.values(c).reduce((s, x) => s + x.n, 0)).toBe(items.length);
    expect(c).toMatchObject({ matching: { n: 3 }, tutor_ack: { n: 1 }, time_off: { n: 0 }, ending: { n: 2 }, issue: { n: 4 } });
    expect(Object.keys(c)).toEqual(['matching', 'tutor_ack', 'time_off', 'ending', 'issue']);
  });
  it('강사 휴무 신청 (H26(137)): 강사 현지 날짜 제목 · 기한 지남 · 한국 날짜가 다르면 한 줄 · [휴무 화면 열기]·[반려]', () => {
    const [it] = buildBoard([{
      kind: 'time_off_request', id: 'req-1', tutorName: 'Emma', tutorTimezone: 'Asia/Manila', first: '2026-11-20', last: '2026-11-24', kstFrom: '2026-11-20', kstTo: '2026-11-25',
      planned: true, reason: 'Family wedding', late: true, classes: 4, createdAt: new Date('2026-11-13T13:35:00Z'),
    }], new Date('2026-11-13T14:00:00Z'));
    expect(it.category).toBe('time_off');
    expect(it.tag).toBe('강사 휴무 신청 · 기한 지남');
    expect(it.title).toBe('Emma · 11/20(금)~11/24(화) 휴무');
    expect(it.detail).toContain('계획된 휴무 · 수업 4회 · 사유: Family wedding · 신청 11/13(금) 오후 10:35 한국 시간');
    expect(it.detail).toContain('한국 날짜 11/20(금)~11/25(수)');
    expect(it.actions.map((a) => a.key)).toEqual(['open_leave', 'reject_time_off']);
    expect(it.actions[0].href).toBe('/lms/admin/leave?new=1&req=req-1');
  });
  it('필터: 전체 · 칸 하나 (긴급만·오류만 필터 없음)', () => {
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

describe('기존 수강생 입력 뒤 시트 대조 (D-52 확대판)', () => {
  const at = new Date('2026-10-24T03:00:00Z');
  const task = (over: Partial<Extract<TaskSource, { kind: 'import_check' }>> = {}): TaskSource => ({
    kind: 'import_check', id: 'e1', studentName: '가상기존', studentCode: 'STU-0101', counts: { lmsLeft: 13, sheetLeft: 12 }, unknownOrigins: [], createdAt: at, ...over,
  });
  it('차이가 있으면 차이를 보이고, 대조 완료 버튼 하나', () => {
    const [i] = buildBoard([task()], at);
    expect(i).toMatchObject({ category: 'issue', error: false, tag: '시트 대조 · 1회 차이', actions: [{ key: 'import_checked' }] });
    expect(i.detail).toMatch('LMS 13회 · 시트 12회 (+1)');
  });
  it('대조는 끝났고 원래 날짜만 남으면 버튼 없이 날짜 칸만', () => {
    const [i] = buildBoard([task({ counts: null, unknownOrigins: [{ id: 'x', label: '미예약 보강' }] })], at);
    expect(i).toMatchObject({ tag: '보강 날짜 확인', actions: [], unknownOrigins: [{ id: 'x' }] });
  });
});

describe('종료일 이유 확인 (D-52 시안 2, 2026-10-26 대표)', () => {
  const at = new Date('2026-10-26T03:00:00Z');
  it('대조를 끝내도 종료일 이유가 없으면 카드가 남고 이유 고르기가 보임', () => {
    const [i] = buildBoard([{ kind: 'import_check', id: 'e1', studentName: '가상', studentCode: 'STU-0101', counts: null, unknownOrigins: [], endReason: { days: 6, weeks: 12 }, createdAt: at }], at);
    expect(i).toMatchObject({ tag: '종료일 이유 확인', actions: [], endReason: { days: 6 } });
    expect(i.detail).toMatch('6일 늦은 이유 확인 필요');
  });
});

describe("요약 칸: '여유' 대신 실제 정보 (C7, 대표 10/30)", () => {
  it('기다린 시간은 하루 넘으면 일 단위', () => {
    expect(waitText(new Date(now.getTime() - 5.5 * H), now)).toBe('5시간째');
    expect(waitText(new Date(now.getTime() - 327 * H), now)).toBe('14일째');
  });
  it('종료 임박 = 잔여 회수 · 종료일, 재등록 통보 = 통보 후 대기 시간', () => {
    const tasks: TaskSource[] = [
      { kind: 'ending_soon', id: 'e', studentName: '김하준', studentCode: 'STU-1', product: '50분 주2회', lessonsLeft: 0, endsAt: new Date('2026-10-17T14:59:00Z'), tutorName: null, durationMin: 50, weeklyCount: 2, noticeSentAt: null },
      { kind: 'renewal_tutor_notice', id: 'r', studentName: '박서연', studentCode: 'STU-2', product: '50분 주2회', newPeriod: '10/20(화)–11/16(월)', tutorName: 'Emma', tutorChangePlanned: false, scheduleConfirmed: false, enrollmentId: 'en1', tutorNotifiedAt: null, tutorAcknowledgedAt: null, scheduleCheckedAt: null, createdAt: new Date(now.getTime() - 400 * H) },
    ];
    const items = buildBoard(tasks, now);
    expect(items.find((i) => i.id === 'e')!.brief).toBe('잔여 0회 · 10/17(토) 종료');
    expect(items.find((i) => i.id === 'r')!.brief).toBe('일정 확정 전');
    expect(items.find((i) => i.id === 'r')!.due).toBeNull();
    expect(items.every((i) => !i.brief.includes('여유'))).toBe(true);
  });
});

describe('재등록 강사 통보 (대표 11/9 A안)', () => {
  const now = new Date('2026-11-09T10:00:00Z');
  const r = (over: Partial<Extract<TaskSource, { kind: 'renewal_tutor_notice' }>>): TaskSource => ({
    kind: 'renewal_tutor_notice', id: 'r', studentName: '송O나', studentCode: 'STU-0004', product: '40분 주2회', newPeriod: '11/18(수)–2/9(화)',
    tutorName: 'Olivia', tutorChangePlanned: false, scheduleConfirmed: true, enrollmentId: 'en1', tutorNotifiedAt: null, tutorAcknowledgedAt: null, scheduleCheckedAt: null, createdAt: now, ...over,
  });
  it('같은 강사·일정(일정 확정됨): [강사에게 통보] 하나만, 강사 확인·일정 조치 단계 없음', () => {
    const [i] = buildBoard([r({})], now);
    expect(i.actions.map((a) => a.label)).toEqual(['강사에게 통보']);
    expect(i.steps.map((x) => x.label)).toEqual(['새 기간 일정 확정', '강사에게 통보']);
  });
  it('일정 확정 전: 일정 확정 버튼만 (확정하면 강사 메일·Updates 가 자동, H26(127))', () => {
    const [i] = buildBoard([r({ scheduleConfirmed: false })], now);
    expect(i.actions[0]).toMatchObject({ label: '새 기간 일정 확정', href: '/lms/admin/assign?e=en1' });
    expect(i.actions).toHaveLength(1);
  });
});
