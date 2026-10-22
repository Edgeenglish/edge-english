import { describe, expect, it } from 'vitest';
import { firstLessonAt, planAlert, proposalMessage, studentConfirmMessage, timeLines, tutorConfirmMessage, type PlanView } from './confirm';

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
      { who: '한국', text: '수·금 09:00', otherDay: false },
      { who: '강사', text: '수·금 11:00', otherDay: false },
      { who: '학생', text: '화·목 19:00', otherDay: true },
    ]);
  });
  it('한국에 사는 학생·강사 줄은 빼요', () => {
    expect(timeLines({ ...base, studentTz: 'Asia/Seoul', tutorTz: 'Asia/Seoul' })).toEqual([{ who: '한국', text: '수·금 09:00', otherDay: false }]);
  });
  it('첫 수업 시점 = 첫 수업일의 정규 시각 (한국)', () => {
    expect(firstLessonAt(base)?.toISOString()).toBe('2026-11-04T00:00:00.000Z');
  });
});

describe('복사 문구', () => {
  it('강사 제안은 확정 아님을 밝히고 강사 현지 시각으로', () => {
    expect(proposalMessage(base)).toBe(
      'Hi Alex, new student request (not confirmed yet):\nMinji Kim, 50 min, 8 classes\nEvery Wed & Fri 11:00 your time\nFirst class: Wed 4 Nov 11:00\nCan you take this?',
    );
  });
  it('강사 확정: 첫·마지막 수업', () => {
    expect(tutorConfirmMessage(base)).toBe(
      'CONFIRMED - new student\nMinji Kim, 50 min, 8 classes\nEvery Wed & Fri 11:00 your time\nFirst class: Wed 4 Nov 11:00 · last Fri 27 Nov\nPlease add it to your schedule. Thank you!',
    );
  });
  it('학생 확정: 현지 시각 먼저, 한국 시각 아래', () => {
    expect(studentConfirmMessage(base)).toBe(
      '[엣지영어] 수업 일정이 확정됐어요\n담당 강사: Alex\n매주 화·목 19:00 (뉴욕 시각)\n= 한국 수·금 09:00\n첫 수업: 11월 3일(화) 19:00 (뉴욕)\n정규 8회 · 50분',
    );
  });
  it('한국 학생은 한국 시각만', () => {
    expect(studentConfirmMessage({ ...base, studentTz: 'Asia/Seoul', studentPlace: '한국 서울' })).toContain('매주 수·금 09:00 (한국 시각)\n첫 수업: 11월 4일(수) 09:00\n');
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
