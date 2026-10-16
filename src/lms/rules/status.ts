// Class Status 14개 (POL-ST-01) — Master Sheet '상태매핑표' 탭(2026-10-16 확인)과 같은 값
// DB 기준값(supabase/migrations/…_lms_core.sql 의 class_status_rules)과 같아야 함 — policy-register.test.ts
// 수업 결과만 담는다. 보강 대기·확정 같은 진행 단계는 보강 신청 상태로 따로 관리.
//
// consumesLesson: 학생 수업 1회 소진(수강권 차감)
// usesCredit:     변경권 1개 사용
// tutorPaid:      강사 급여 지급 대상 — 'Covered by another tutor'는 실제로 수업한 대체 강사에게 지급
// incentive:      인센티브 영향

export const CLASS_STATUSES = [
  'Normal',
  'Make-up completed',
  'Student canceled in advance',
  'Student canceled in advance (public holiday)',
  'Tutor canceled in advance',
  'Student canceled late',
  'Tutor canceled late',
  'Student no-show',
  'Tutor no-show',
  'Tutor long-term leave',
  'Student long-term leave',
  'No change credits left',
  'Tutor Late - Student Present',
  'Covered by another tutor',
] as const;

export type ClassStatus = (typeof CLASS_STATUSES)[number];

type Incentive = 'none' | 'late_cancel' | 'no_show' | 'late';

export type StatusRule = {
  studentLabel: string;
  consumesLesson: boolean;
  usesCredit: boolean;
  tutorPaid: boolean;
  incentive: Incentive;
};

export const STATUS_RULES: Record<ClassStatus, StatusRule> = {
  Normal: { studentLabel: '정상 진행', consumesLesson: true, usesCredit: false, tutorPaid: true, incentive: 'none' },
  'Make-up completed': { studentLabel: '보강 완료', consumesLesson: true, usesCredit: false, tutorPaid: true, incentive: 'none' },
  'Student canceled in advance': { studentLabel: '학생 정상 취소 👉 수강기간 내 보강 가능', consumesLesson: false, usesCredit: true, tutorPaid: false, incentive: 'none' },
  'Student canceled in advance (public holiday)': { studentLabel: '공휴일 취소 👉 수강기간 내 보강 가능', consumesLesson: false, usesCredit: false, tutorPaid: false, incentive: 'none' },
  'Tutor canceled in advance': { studentLabel: '강사 정상 취소 👉 수강기간 내 보강 가능', consumesLesson: false, usesCredit: false, tutorPaid: false, incentive: 'none' },
  'Student canceled late': { studentLabel: '학생 늦은 취소 👉 보강 불가', consumesLesson: true, usesCredit: false, tutorPaid: true, incentive: 'none' },
  'Tutor canceled late': { studentLabel: '강사 늦은 취소 👉 수강기간 내 보강 가능', consumesLesson: false, usesCredit: false, tutorPaid: false, incentive: 'late_cancel' },
  'Student no-show': { studentLabel: '학생 노쇼 👉 보강 불가', consumesLesson: true, usesCredit: false, tutorPaid: true, incentive: 'none' },
  'Tutor no-show': { studentLabel: '강사 노쇼 👉 보강 1회 + 보상수업 1회(무료)', consumesLesson: false, usesCredit: false, tutorPaid: false, incentive: 'no_show' },
  'Tutor long-term leave': { studentLabel: '강사 장기 휴식 👉 수강기간 연장', consumesLesson: false, usesCredit: false, tutorPaid: false, incentive: 'none' },
  // 학생용 문구의 '최대 2주·24주만'은 FAQ·수강계약서와 달라 확인 필요 (docs/lms/04-policy-review.md)
  'Student long-term leave': { studentLabel: '학생 장기 연기 👉 수강기간 최대 2주 연장(6개월(24주) 수강 학생만)', consumesLesson: false, usesCredit: false, tutorPaid: false, incentive: 'none' },
  'No change credits left': { studentLabel: '변경권 소진 👉 보강 불가', consumesLesson: true, usesCredit: false, tutorPaid: true, incentive: 'none' },
  'Tutor Late - Student Present': { studentLabel: '강사 지각(정상 진행)', consumesLesson: true, usesCredit: false, tutorPaid: true, incentive: 'late' },
  'Covered by another tutor': { studentLabel: '대타 강사 진행', consumesLesson: true, usesCredit: false, tutorPaid: true, incentive: 'none' },
};

/** 보강을 받을 수 있는 결과인지 (취소됐지만 수업이 소진되지 않은 경우) */
export function grantsMakeup(status: ClassStatus): boolean {
  const r = STATUS_RULES[status];
  return !r.consumesLesson && status !== 'Tutor long-term leave' && status !== 'Student long-term leave';
}
