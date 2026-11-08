import { describe, expect, it } from 'vitest';
import { firstLessonAt, planAlert, prestartMoveNotices, proposalMessage, studentConfirmMessage, timeLines, tutorConfirmMessage, type PlanView } from './confirm';

// 시안 2차 예시: 뉴욕 학생 · 시드니 강사 · 한국 수·금 09:00, 첫 수업 2026-11-04(수)
const base: PlanView = {
  planId: 'p1',
  state: 'confirmed',
  studentNameEn: 'Minji Kim',
  studentPlace: '미국 뉴욕',
  studentTz: 'America/New_York',
  tutorName: 'Alex',
  tutorPlace: '호주 시드니',
  tutorTz: 'Australia/Sydney',
  slots: [
    { weekday: 5, time: '09:00' },
    { weekday: 3, time: '09:00' },
  ],
  startDate: '2026-11-04',
  endDate: '2026-12-01',
  lessons: 8,
  durationMin: 50,
  proposalSentAt: null,
  confirmedAt: new Date('2026-10-21T07:00:00Z'),
  tutorNotice: { id: 't', status: 'pending', sentAt: null },
  studentNotice: { id: 's', status: 'sent', sentAt: new Date('2026-10-21T07:05:00Z') },
};

describe('한국·강사·학생 시간 세 줄', () => {
  it('학생 현지 요일이 다르면 표시 (뉴욕은 하루 전 저녁)', () => {
    expect(timeLines(base)).toEqual([
      { who: '한국', text: '수·금 오전 9:00', otherDay: false },
      { who: '강사', text: '수·금 오전 11:00', otherDay: false },
      { who: '학생', text: '화·목 오후 7:00', otherDay: true },
    ]);
  });
  it('한국에 사는 학생·강사 줄은 빼요', () => {
    expect(timeLines({ ...base, studentTz: 'Asia/Seoul', tutorTz: 'Asia/Seoul' })).toEqual([{ who: '한국', text: '수·금 오전 9:00', otherDay: false }]);
  });
  it('첫 수업 시점 = 첫 수업일의 정규 시각 (한국)', () => {
    expect(firstLessonAt(base)?.toISOString()).toBe('2026-11-04T00:00:00.000Z');
  });
});

describe('복사 문구', () => {
  it('강사 제안은 확정 아님을 밝히고 강사 현지 시각으로', () => {
    expect(proposalMessage(base)).toBe(
      'Hi Alex, new student request (not confirmed yet):\nMinji Kim, 50 min, 8 classes\nEvery Wed & Fri 11:00 AM Sydney Time (Wed & Fri 9:00 AM KST)\nFirst class: Wed 4 Nov 11:00 AM\nCan you take this?',
    );
  });
  it('강사 확정: 첫·마지막 수업', () => {
    expect(tutorConfirmMessage(base)).toBe(
      'CONFIRMED - new student\nMinji Kim, 50 min, 8 classes\nEvery Wed & Fri 11:00 AM Sydney Time (Wed & Fri 9:00 AM KST)\nFirst class: Wed 4 Nov 11:00 AM · last Fri 27 Nov\nPlease add it to your schedule. Thank you!',
    );
  });
  it('학생 확정: 현지 시각 먼저, 한국 시각 아래', () => {
    expect(studentConfirmMessage(base)).toBe(
      '[엣지영어] 수업 일정이 확정됐어요\n담당 강사: Alex\n매주 화·목 오후 7:00 (뉴욕 시각)\n= 한국 수·금 오전 9:00\n첫 수업: 11월 3일(화) 오후 7:00 (뉴욕)\n정규 8회 · 50분',
    );
  });
  it('한국 학생은 한국 시각만', () => {
    expect(studentConfirmMessage({ ...base, studentTz: 'Asia/Seoul', studentPlace: '한국 서울' })).toContain('매주 수·금 오전 9:00 (한국 시각)\n첫 수업: 11월 4일(수) 오전 9:00\n');
  });
});

describe('경고 시각 (D-51-3)', () => {
  const at = (iso: string) => new Date(iso);
  it('확정 1시간 안에는 경고 없음, 지나면 긴급', () => {
    expect(planAlert(base, at('2026-10-21T07:59:00Z'))).toBe('none');
    expect(planAlert(base, at('2026-10-21T08:00:00Z'))).toBe('urgent');
  });
  it('첫 수업 24시간 안이면 맨 위', () => {
    expect(planAlert(base, at('2026-11-03T00:00:00Z'))).toBe('top');
  });
  it('양쪽 다 보내면 경고 없음', () => {
    expect(planAlert({ ...base, tutorNotice: { id: 't', status: 'sent', sentAt: at('2026-10-21T07:06:00Z') } }, at('2026-11-03T12:00:00Z'))).toBe('none');
  });
  it('제안 24시간 무응답이면 답 확인 필요', () => {
    const p = { ...base, state: 'proposed' as const, confirmedAt: null, tutorNotice: null, studentNotice: null, proposalSentAt: at('2026-10-21T06:00:00Z') };
    expect(planAlert(p, at('2026-10-22T05:59:00Z'))).toBe('none');
    expect(planAlert(p, at('2026-10-22T06:00:00Z'))).toBe('no_reply');
    expect(planAlert({ ...p, proposalSentAt: null }, at('2026-10-30T00:00:00Z'))).toBe('none');
  });
});

describe('회차별 날짜를 정한 일정안 (H26(61)·(62))', () => {
  it('시작 전 날짜 변경 안내: 학생은 현지 시각 먼저 + 한국, 강사는 강사 현지', () => {
    const n = prestartMoveNotices({ studentNameEn: 'Minji Kim', studentTz: 'America/New_York', studentCity: '뉴욕', tutorTz: 'Australia/Sydney', from: new Date('2026-11-04T00:00:00Z'), to: new Date('2026-11-05T00:00:00Z') });
    expect(n.student).toBe('[엣지영어] 수업 날짜가 바뀌었어요\n11월 3일(화) 오후 7:00 → 11월 4일(수) 오후 7:00 (뉴욕 시각)\n= 한국 11월 5일(목) 오전 9:00');
    expect(n.tutor).toBe('Schedule change - Minji Kim\nWed 4 Nov 11:00 AM → Thu 5 Nov 11:00 AM Sydney Time\nPlease update your schedule. Thank you!');
    const kr = prestartMoveNotices({ studentNameEn: 'A', studentTz: 'Asia/Seoul', studentCity: null, tutorTz: 'Asia/Seoul', from: new Date('2026-11-04T00:00:00Z'), to: new Date('2026-11-05T00:00:00Z') });
    expect(kr.student).toBe('[엣지영어] 수업 날짜가 바뀌었어요\n11월 4일(수) 오전 9:00 → 11월 5일(목) 오전 9:00 (한국 시각)');
  });
  // 수·금 09:00 인데 첫 수업은 월 11/2, 3회차 수 11/11 → 목 11/12
  const custom: PlanView = {
    ...base,
    startDate: '2026-11-02',
    endDate: '2026-11-29',
    lessonList: [
      { date: '2026-11-02', time: '09:00' },
      { date: '2026-11-04', time: '09:00' },
      { date: '2026-11-06', time: '09:00' },
      { date: '2026-11-12', time: '09:00' },
      { date: '2026-11-13', time: '09:00' },
      { date: '2026-11-18', time: '09:00' },
      { date: '2026-11-20', time: '09:00' },
      { date: '2026-11-25', time: '09:00' },
    ],
  };
  it('강사 제안: 첫 수업은 목록의 첫 날, 정규와 다른 날·수업 없는 날을 강사 현지 시각으로', () => {
    const m = proposalMessage(custom).split('\n');
    expect(m).toContain('First class: Mon 2 Nov 11:00 AM');
    expect(m).toContain('Other days: Thu 12 Nov 11:00 AM');
    expect(m.join('\n')).not.toContain('Other days: Mon 2 Nov');
    expect(m).toContain('No class (regular day): Wed 11 Nov, Fri 27 Nov');
  });
  it('강사 확정: 마지막 수업도 목록 기준', () => {
    expect(tutorConfirmMessage(custom)).toContain('First class: Mon 2 Nov 11:00 AM · last Wed 25 Nov');
  });
  it('학생 확정: 정규와 다른 날·수업 없는 날을 학생 현지 시각으로', () => {
    const m = studentConfirmMessage(custom).split('\n');
    expect(m.some((l) => l.startsWith('다른 요일 수업: 11월 11일(수) 오후 7:00 (뉴욕)'))).toBe(true);
    expect(m.some((l) => l.startsWith('수업 없는 정규 요일: 11월 10일(화), 11월 26일(목)'))).toBe(true);
  });
  it('목록이 없으면 예전 문구 그대로', () => {
    expect(proposalMessage(base)).not.toContain('Other days');
  });
});
