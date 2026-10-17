// 대시보드 미리보기용 가상 데이터 (실제 학생·강사 아님). 시험용 Supabase의 seed_fake.sql 과 같은 상황
// 시각은 '지금' 기준으로 만들어 기한 초과·임박·여유가 모두 보이게 함

import { addBusinessDays, addDays, endOfKstDay, instantToKstDate, weekdayOf, type KstDate } from '../rules/dates';
import type { TaskSource } from './board';

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

export function fakeTasks(now: Date): TaskSource[] {
  const t = (h: number) => new Date(now.getTime() + h * H);
  // 매칭 기한 = 결제 확인 다음 날부터 3영업일째 23:59 KST (POL-OP-13, 공휴일은 가상 데이터라 비움)
  const matchDue = (confirmedHoursAgo: number) => endOfKstDay(addBusinessDays(instantToKstDate(t(-confirmedHoursAgo)), 3, new Set()));
  return [
    { kind: 'no_show_report', id: 'ns-1', studentName: '가상학생오', tutorName: '가상강사 Alex', lessonStartsAt: t(-0.2), reportedAt: t(-0.1) },
    {
      kind: 'new_student_matching', id: 'm-1', studentName: '가상학생일', studentCode: 'STU-9001', product: '50분 주2회 4주',
      dueAt: matchDue(24 * 8), tutorName: null, tutorAssignedAt: null, studentNotifiedAt: null,
    },
    {
      kind: 'new_student_matching', id: 'm-2', studentName: '가상학생이', studentCode: 'STU-9002', product: '40분 주3회 24주',
      dueAt: matchDue(24 * 3), tutorName: '가상강사 Blair', tutorAssignedAt: t(-20), studentNotifiedAt: null,
    },
    {
      kind: 'new_student_matching', id: 'm-3', studentName: '가상학생삼', studentCode: 'STU-9003', product: '50분 주1회 12주',
      dueAt: matchDue(0), tutorName: null, tutorAssignedAt: null, studentNotifiedAt: null,
    },
    {
      kind: 'renewal_tutor_notice', id: 'r-1', studentName: '가상학생사', studentCode: 'STU-9004', product: '50분 주2회 4주',
      newPeriod: renewalPeriod(instantToKstDate(now), [2, 4]), tutorName: '가상강사 Blair', tutorChangePlanned: false,
      tutorNotifiedAt: t(-26), tutorAcknowledgedAt: null, scheduleCheckedAt: null, createdAt: t(-26),
    },
    {
      kind: 'long_leave_request', id: 'l-1', studentName: '가상학생이', studentCode: 'STU-9002', from: '11/20(금)', to: '11/26(목)',
      days: 7, reason: 'health', createdAt: t(-5),
    },
  ];
}

export const FAKE_TODAY: FakeLesson[] = [
  { time: '17:00', student: '가상학생일', tutor: 'Alex', state: '완료' },
  { time: '18:00', student: '가상학생육', tutor: 'Blair', state: '완료' },
  { time: '19:00', student: '가상학생오', tutor: 'Alex', state: '노쇼 신고' },
  { time: '20:00', student: '가상학생사', tutor: 'Blair', state: '예정' },
  { time: '20:00', student: '가상학생칠', tutor: 'Alex', state: '학생 변경' },
  { time: '21:00', student: '가상학생이', tutor: 'Blair', state: '보강' },
];
