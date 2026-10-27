import { describe, expect, it } from 'vitest';
import { kstToInstant } from '../rules/dates';
import { buildBoard } from './board';
import { makeupRights, type ChLesson } from './lesson-change';
import { toTutorLeaves } from './live';
import { groupByStudent, groupChoice, itemStatus, leaveMessages, leaveSummary, type LvItem, type LvNotice } from './tutor-leave';

const I = (id: string, student: string, date: string, extra: Partial<LvItem> = {}): LvItem => ({
  id, timeOffId: 'off', studentId: student, studentName: student === 's1' ? '김민수' : '이지은', studentNameEn: student === 's1' ? 'Minsu Kim' : 'Jieun Lee',
  studentCode: student === 's1' ? 'STU-0001' : 'STU-0002', studentTz: 'Asia/Seoul', durationMin: 40, isLesson: true,
  startsAt: kstToInstant(date, '20:00'), choice: 'undecided', subTutorId: null, subTutorName: null, subTutorTz: null, subStage: null, makeupAt: null, makeupRequested: false, lessonId: id, migratedItemId: null, ...extra,
});
const sub = { choice: 'substitute' as const, subTutorId: 'b', subTutorName: 'Benny', subTutorTz: 'Asia/Manila' };
const now = kstToInstant('2026-10-27', '12:00');

describe('강사 휴무 화면 계산 (2순위 ①)', () => {
  it('학생별로 묶고(첫 수업 빠른 학생부터), 날짜마다 다르게 고르면 mixed', () => {
    const items = [I('c', 's2', '2026-11-04'), I('a', 's1', '2026-11-02', sub), I('b', 's1', '2026-11-03', { choice: 'wait' })];
    const g = groupByStudent(items);
    expect(g.map((x) => [x.studentId, x.items.map((i) => i.id)])).toEqual([['s1', ['a', 'b']], ['s2', ['c']]]);
    expect(groupChoice(g[0].items)).toBe('mixed');
    expect(groupChoice(g[1].items)).toBe('undecided');
  });

  it('상태 글: 미정 → 강사 답 대기 → 학생 OK 대기 → 확정 / 기다림 보강 미정·보강 날짜', () => {
    expect(itemStatus(I('a', 's1', '2026-11-02')).text).toBe('학생 선택 미확인');
    expect(itemStatus(I('a', 's1', '2026-11-02', { ...sub, subStage: 'asked' })).text).toBe('대체 Benny · 강사 답 대기');
    expect(itemStatus(I('a', 's1', '2026-11-02', { ...sub, subStage: 'tutor_ok' })).text).toBe('대체 Benny · 학생 OK 대기');
    expect(itemStatus(I('a', 's1', '2026-11-02', { ...sub, subStage: 'confirmed' })).tone).toBe('done');
    expect(itemStatus(I('a', 's1', '2026-11-02', { choice: 'wait' })).text).toBe('기존 강사 보강 · 날짜 미정');
    expect(itemStatus(I('a', 's1', '2026-11-02', { choice: 'wait', makeupRequested: true })).text).toBe('기존 강사 보강 · 강사 확인 중');
    expect(itemStatus(I('a', 's1', '2026-11-02', { choice: 'wait', makeupAt: kstToInstant('2026-11-20', '20:00') })).text).toBe('기존 강사 보강 · 11/20 20:00');
  });

  it('안내: 같은 학생·같은 대체강사 날짜를 한 메시지로, 강사는 현지 시각, 학생은 한국어', () => {
    const items = [I('a', 's1', '2026-11-02', { ...sub, subStage: 'asked' }), I('b', 's1', '2026-11-05', { ...sub, subStage: 'tutor_ok' })];
    const notices: LvNotice[] = [
      { id: 'n1', itemId: 'a', event: 'sub_ask', recipientId: 'b', status: 'pending', sentAt: null },
      { id: 'n2', itemId: 'b', event: 'sub_ask', recipientId: 'b', status: 'pending', sentAt: null },
      { id: 'n3', itemId: 'b', event: 'sub_student', recipientId: 's1', status: 'pending', sentAt: null },
      { id: 'n4', itemId: 'a', event: 'sub_confirmed', recipientId: 'b', status: 'not_needed', sentAt: null },
      { id: 'n5', itemId: 'a', event: 'leave_options', recipientId: 's1', status: 'pending', sentAt: null },
      { id: 'n6', itemId: 'b', event: 'leave_options', recipientId: 's1', status: 'pending', sentAt: null },
    ];
    const m = leaveMessages(items, notices, 'Olivia');
    expect(m.map((x) => [x.event, x.noticeIds])).toEqual([['sub_ask', ['n1', 'n2']], ['sub_student', ['n3']], ['leave_options', ['n5', 'n6']]]);
    expect(m[0].text).toContain('Substitute request - Minsu Kim (40 min)');
    expect(m[0].text).toContain('Olivia is on leave');
    expect(m[0].text.split('\n').filter((l) => /^\d\)/.test(l))).toHaveLength(2);
    expect(m[0].text).toContain('your time');
    expect(m[1].text).toBe('[엣지영어] 김민수님, 아래 수업은 Benny 강사님과 평소 시간에 진행해요. 괜찮으시면 답장 주세요.\n\n- 11월 5일(목) 오후 8시');
    // 두 가지를 처음부터 함께 안내 (① 대체강사 · 추천 / ② 기존 강사와 보강), 대표 문구 그대로
    expect(m[2].recipient).toBe('student');
    expect(m[2].text).toBe([
      '[엣지영어] 김민수님, Olivia 강사님 휴무로 아래 수업의 진행 방법을 골라 주세요.',
      '- 11월 2일(월) 오후 8시\n- 11월 5일(목) 오후 8시',
      '① 원래 시간에 대체강사와 수업하기 · 추천\n일정을 바꾸지 않고, 평소 수업 시간 그대로 수업하실 수 있어요.\n다른 강사의 영어와 수업 방식도 경험해 보실 수 있습니다.',
      '② 기존 강사와 보강하기\n기존 강사님이 돌아오신 뒤 수업하실 수 있어요. 가능한 보강 시간을 확인해 주세요.',
    ].join('\n\n'));
    expect(leaveSummary(items, notices).pendingNotices).toBe(5);
  });

  it('기다림 수업(강사 장기 휴식)도 보강 권리 — 수업 변경·보강 화면에서 보강을 잡음', () => {
    const L = (id: string, extra: Partial<ChLesson>): ChLesson => ({
      id, kind: 'regular', seq: 1, startsAt: kstToInstant('2026-11-02', '20:00'), state: 'scheduled', classStatus: null, makeupOf: null, voided: false,
      tutorId: 't', tutorName: 'Olivia', tutorTz: 'Asia/Tokyo', ...extra,
    });
    const r = makeupRights([L('w', { state: 'canceled', classStatus: 'Tutor long-term leave' }), L('s', { state: 'canceled', classStatus: 'Student long-term leave' })], [], []);
    expect(r.map((x) => x.key)).toEqual(['w']);
  });

  it('대시보드: 휴무마다 한 줄 (학생 답 대기 명 수 · 강사 답 대기 · 학생 OK 대기 · 안 보낸 안내), 열기 → 휴무 화면', () => {
    const off = { id: 'off1', starts_at: '2026-11-01T15:00:00Z', ends_at: '2026-11-10T15:00:00Z', created_at: '2026-10-27T00:00:00Z', tutor: { name: 'Olivia' } };
    const tasks = toTutorLeaves([
      { student_id: 's1', starts_at: '2026-11-02T11:00:00Z', choice: 'undecided', sub_stage: null, off },
      { student_id: 's1', starts_at: '2026-11-03T11:00:00Z', choice: 'undecided', sub_stage: null, off },
      { student_id: 's2', starts_at: '2026-11-04T03:00:00Z', choice: 'substitute', sub_stage: 'asked', off },
    ], [{ leave: { off } }], now);
    const [item] = buildBoard(tasks, now);
    expect(item.title).toBe('Olivia 휴무 11/2~11/10');
    expect(item.detail).toBe('학생 선택 미확인 1명 · 대체강사 답 대기 1회 · 안내 안 보냄 1건');
    expect(item.actions[0].href).toBe('/lms/admin/leave?off=off1');
  });
});
