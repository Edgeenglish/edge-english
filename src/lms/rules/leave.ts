// 강사 휴무 일괄 처리 — 영향받는 수업 미리보기
// 처리 방식(대체 강사 / 기간 연장 / 보강)은 운영자 결정 사항이라 여기서는 정하지 않는다.
// 미리보기 → 운영자가 학생별 처리 방식을 고름 → 서버에서 한 번에 반영.

import { diffDays, type KstDate } from './dates';

export type LessonForLeave = {
  id: string;
  tutorId: string;
  studentId: string;
  kstDate: KstDate;
  state: 'scheduled' | 'canceled' | 'done';
};

export type LeaveImpact = { studentId: string; lessonIds: string[]; dates: KstDate[] };

/** from~to (KST 날짜, 양 끝 포함) 사이 해당 강사의 예정 수업을 학생별로 묶음 */
export function previewTutorLeave(lessons: LessonForLeave[], tutorId: string, from: KstDate, to: KstDate): LeaveImpact[] {
  if (diffDays(from, to) < 0) throw new Error('휴무 종료일이 시작일보다 빠릅니다.');
  const byStudent = new Map<string, LeaveImpact>();
  for (const l of lessons) {
    if (l.tutorId !== tutorId || l.state !== 'scheduled') continue;
    if (diffDays(from, l.kstDate) < 0 || diffDays(l.kstDate, to) < 0) continue;
    const item = byStudent.get(l.studentId) ?? { studentId: l.studentId, lessonIds: [], dates: [] };
    item.lessonIds.push(l.id);
    item.dates.push(l.kstDate);
    byStudent.set(l.studentId, item);
  }
  return [...byStudent.values()].map((i) => ({ ...i, dates: [...i.dates].sort() }));
}
