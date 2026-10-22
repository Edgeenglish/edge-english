// 대시보드 미리보기용 가상 데이터 (실제 학생·강사 아님). 시험용 Supabase의 seed_fake.sql 과 같은 상황
// 시각은 '지금' 기준으로 만들어 기한 초과·임박·여유가 모두 보이게 함

import { addBusinessDays, addDays, endOfKstDay, instantToKstDate, weekdayOf, type KstDate } from '../rules/dates';
import type { TaskSource } from './board';
import type { PlanView } from './confirm';

const H = 60 * 60 * 1000;

export type FakeLesson = { time: string; student: string; tutor: string; state: '완료' | '예정' | '보강' | '노쇼 신고' | '학생 변경' | '취소' };

const WEEKDAY_KO = ['일', '월', '화', '수', '목', '금', '토'];
const shortDate = (d: KstDate) => `${Number(d.slice(5, 7))}/${Number(d.slice(8, 10))}(${WEEKDAY_KO[weekdayOf(d)]})`;

// 기한 안 재등록의 새 28일 = 이전 종료 뒤 처음 오는 정규 수업일부터 (POL-RN-07, 정책 원본 A25 — 종료 다음 날 무조건 아님)
function renewalPeriod(previousEnd: KstDate, lessonWeekdays: number[]): string {
  let start = addDays(previousEnd, 1);
  while (!lessonWeekdays.includes(weekdayOf(start))) start = addDays(start, 1);
  return `${shortDate(start)}–${shortDate(addDays(start, 27))}`;
}

// 가상 일정안 (H22): 가상학생일 = 뉴욕 학생·시드니 강사, 강사 답 대기 / 가상학생이 = 확정, 학생에게만 보냄 (사고 상황)
function nextWeekday(from: KstDate, wd: number): KstDate {
  let d = addDays(from, 3);
  while (weekdayOf(d) !== wd) d = addDays(d, 1);
  return d;
}
function fakePlans(now: Date): { waiting: PlanView; confirmed: PlanView } {
  const today = instantToKstDate(now);
  const s1 = nextWeekday(today, 3);
  const s2 = nextWeekday(today, 1);
  return {
    waiting: {
      planId: 'plan-1', state: 'proposed', studentNameEn: 'Minji Kim', studentPlace: '미국 뉴욕', studentTz: 'America/New_York',
      tutorName: '가상강사 Alex', tutorPlace: '호주', tutorTz: 'Australia/Sydney',
      slots: [{ weekday: 3, time: '09:00' }, { weekday: 5, time: '09:00' }], startDate: s1, endDate: addDays(s1, 27), lessons: 8, durationMin: 50,
      proposalSentAt: new Date(now.getTime() - 3 * H), confirmedAt: null, tutorNotice: null, studentNotice: null,
    },
    confirmed: {
      planId: 'plan-2', state: 'confirmed', studentNameEn: 'Jiwoo Lee', studentPlace: '한국 서울', studentTz: 'Asia/Seoul',
      tutorName: '가상강사 Blair', tutorPlace: '캐나다', tutorTz: 'America/Toronto',
      slots: [{ weekday: 1, time: '20:00' }, { weekday: 3, time: '20:00' }, { weekday: 5, time: '20:00' }], startDate: s2, endDate: addDays(s2, 24 * 7 - 1), lessons: 72, durationMin: 40,
      proposalSentAt: new Date(now.getTime() - 26 * H), confirmedAt: new Date(now.getTime() - 2 * H),
      tutorNotice: { id: 'n-t2', status: 'pending', sentAt: null }, studentNotice: { id: 'n-s2', status: 'sent', sentAt: new Date(now.getTime() - 1.9 * H) },
    },
  };
}

export function fakeTasks(now: Date): TaskSource[] {
  const t = (h: number) => new Date(now.getTime() + h * H);
  const plans = fakePlans(now);
  // 매칭 기한 = 결제 확인 다음 날부터 3영업일째 23:59 KST (POL-OP-13, 공휴일은 가상 데이터라 비움)
  const matchDue = (confirmedHoursAgo: number) => endOfKstDay(addBusinessDays(instantToKstDate(t(-confirmedHoursAgo)), 3, new Set()));
  return [
    { kind: 'no_show_report', id: 'ns-1', studentName: '가상학생오', tutorName: '가상강사 Alex', lessonStartsAt: t(-0.2), reportedAt: t(-0.1) },
    {
      kind: 'new_student_matching', id: 'm-1', studentName: '가상학생일', studentCode: 'STU-9001', product: '50분 주2회 4주',
      dueAt: matchDue(24 * 8), tutorName: null, tutorAssignedAt: null, studentNotifiedAt: null, plan: plans.waiting,
    },
    {
      kind: 'new_student_matching', id: 'm-2', studentName: '가상학생이', studentCode: 'STU-9002', product: '40분 주3회 24주',
      dueAt: matchDue(24 * 3), tutorName: '가상강사 Blair', tutorAssignedAt: t(-2), studentNotifiedAt: t(-1.9), plan: plans.confirmed,
    },
    {
      kind: 'new_student_matching', id: 'm-3', studentName: '가상학생삼', studentCode: 'STU-9003', product: '50분 주1회 12주',
      dueAt: matchDue(0), tutorName: null, tutorAssignedAt: null, studentNotifiedAt: null, enrollmentId: 'demo',
    },
    {
      kind: 'renewal_tutor_notice', id: 'r-1', studentName: '가상학생사', studentCode: 'STU-9004', product: '50분 주2회 4주',
      newPeriod: renewalPeriod(instantToKstDate(now), [2, 4]), tutorName: '가상강사 Blair', tutorChangePlanned: false,
      tutorNotifiedAt: t(-26), tutorAcknowledgedAt: null, scheduleCheckedAt: null, createdAt: t(-26),
    },
    {
      kind: 'ending_soon', id: 'e-1', studentName: '가상학생팔', studentCode: 'STU-9008', product: '50분 주2회 4주',
      regularLeft: 1, endsAt: endOfKstDay(instantToKstDate(now)), tutorName: '가상강사 Alex',
    },
    {
      kind: 'ending_soon', id: 'e-2', studentName: '가상학생구', studentCode: 'STU-9009', product: '40분 주3회 12주',
      regularLeft: 2, endsAt: endOfKstDay(addDays(instantToKstDate(now), 5)), tutorName: '가상강사 Blair',
    },
    {
      kind: 'makeup_unrequested', id: 'mk-1', studentName: '가상학생십', studentCode: 'STU-9010',
      canceledLesson: shortDate(addDays(instantToKstDate(now), -6)) + ' 20:00', deadline: endOfKstDay(addDays(instantToKstDate(now), 3)), tutorName: '가상강사 Alex',
    },
    {
      kind: 'auto_failure', id: 'f-1', what: 'calendar_sync', studentName: '가상학생이',
      detail: '보강 10/22(목) 21:00 이 가상강사 Blair 캘린더에 반영되지 않음 (3번 다시 시도 실패)', occurredAt: t(-2),
    },
    {
      kind: 'long_leave_request', id: 'l-1', studentName: '가상학생이', studentCode: 'STU-9002', from: '11/20(금)', to: '11/26(목)',
      days: 7, reason: 'health', createdAt: t(-5),
    },
  ];
}

/** 상단 운영 현황 3개 (처리할 일과 겹치지 않는 '현재 상태' 숫자) */
export type OpsStats = { activeStudents: number; weekLessons: { done: number; total: number }; monthEnrollments: { fresh: number; renewal: number } };

export const FAKE_STATS: OpsStats = { activeStudents: 42, weekLessons: { done: 38, total: 96 }, monthEnrollments: { fresh: 6, renewal: 11 } };
