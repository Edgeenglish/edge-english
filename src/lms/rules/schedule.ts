// 정규 수업 회차 만들기
// - 매주 고정 요일·고정 시각(KST)
// - 28일 안에는 모든 요일이 정확히 4번씩 들어 있으므로, 1기간 회차 = 주 횟수 × 4

import { addDays, kstToInstant, weekdayOf, type KstDate, type KstTime } from './dates';
import { computePeriods } from './period';
import type { CourseWeeks } from './policy';

export type RegularSlot = { weekday: number; time: KstTime }; // weekday: 0=일 … 6=토

export type PlannedLesson = {
  seq: number; // 수강 회차 (1부터)
  periodIndex: number;
  kstDate: KstDate;
  kstTime: KstTime;
  startsAt: Date; // UTC 시점
  endsAt: Date;
};

export function generateRegularLessons(input: {
  startDate: KstDate; // 첫 정규 수업일
  weeks: CourseWeeks;
  slots: RegularSlot[];
  durationMin: number;
}): PlannedLesson[] {
  const { startDate, weeks, slots, durationMin } = input;
  if (slots.length === 0) throw new Error('수업 요일을 1개 이상 정해야 합니다.');
  const days = new Set(slots.map((s) => s.weekday));
  if (days.size !== slots.length) throw new Error('같은 요일에 정규 수업을 2개 넣을 수 없습니다.');
  if (!days.has(weekdayOf(startDate))) {
    throw new Error('수강 시작일은 첫 정규 수업일이어야 합니다 (시작일 요일이 수업 요일에 없음).');
  }

  const lessons: PlannedLesson[] = [];
  for (const period of computePeriods(startDate, weeks)) {
    for (let offset = 0; offset < 28; offset++) {
      const date = addDays(period.start, offset);
      const slot = slots.find((s) => s.weekday === weekdayOf(date));
      if (!slot) continue;
      const startsAt = kstToInstant(date, slot.time);
      lessons.push({
        seq: lessons.length + 1,
        periodIndex: period.index,
        kstDate: date,
        kstTime: slot.time,
        startsAt,
        endsAt: new Date(startsAt.getTime() + durationMin * 60 * 1000),
      });
    }
  }
  return lessons;
}

/** 등록 회차 = 주 횟수 × 주 수 (Master Sheet '등록수업수'와 같은 계산) */
export function totalLessons(weeklyCount: number, weeks: CourseWeeks): number {
  return weeklyCount * weeks;
}
