// 등록 때 정하는 수업 날짜 목록 (2026-11-06 대표 요청, 정책 원본 H26(60)·(61))
// - 기본: 첫 수업일부터 정규 요일대로 등록 회차(주 횟수 × 주수)만큼
// - 첫 수업일이 정규 요일이 아니면 그날이 1회 (시각은 다음 정규 수업의 시각), 총 횟수는 그대로라 마지막 정규 1회가 줄어듦
// - 특정 회차만 다른 날·시각으로 바꿀 수 있음 (변경권 사용 없음). 바꾼 목록 전체를 DB가 같은 규칙으로 다시 검사
// - 수강 기간은 실제 첫 수업일부터 28일 단위 (POL-PER-01~03), 모든 수업은 그 기간 안

import { addDays, weekdayOf, type KstDate, type KstTime } from './dates';
import { computePeriods } from './period';
import type { CourseWeeks } from './policy';
import type { RegularSlot } from './schedule';

export type LessonDate = { date: KstDate; time: KstTime };
/** 바꾼 회차: 기본 목록의 원래 날짜 → 새 날짜·시각 */
export type LessonEdits = Readonly<Record<KstDate, LessonDate>>;

export type PlanLesson = {
  n: number; // 날짜순 회차
  date: KstDate;
  time: KstTime;
  /** 바꾼 회차면 원래 날짜·시각 */
  original: LessonDate | null;
  /** 기본 목록에서의 키(원래 날짜) — 바꾸기·되돌리기에 씀 */
  key: KstDate;
};

export type LessonPlan = {
  lessons: PlanLesson[];
  startDate: KstDate | null;
  endDate: KstDate | null;
  /** 첫 수업일이 정규 요일이 아니라서 추가된 1회가 있는지 */
  extraFirst: boolean;
  problems: string[];
};

const md = (d: KstDate) => `${Number(d.slice(5, 7))}/${Number(d.slice(8, 10))}`;

/** 기본 목록 (바꾸기 전) */
export function baseLessons(firstDate: KstDate, count: number, slots: readonly RegularSlot[]): { list: LessonDate[]; extraFirst: boolean } {
  const byDay = new Map(slots.map((s) => [s.weekday, s.time] as const));
  if (byDay.size === 0 || count <= 0) return { list: [], extraFirst: false };
  const list: LessonDate[] = [];
  let extraFirst = false;
  if (!byDay.has(weekdayOf(firstDate))) {
    let d = firstDate;
    while (!byDay.has(weekdayOf(d))) d = addDays(d, 1);
    list.push({ date: firstDate, time: byDay.get(weekdayOf(d))! });
    extraFirst = true;
  }
  for (let d = firstDate, guard = 0; list.length < count && guard < 7 * count + 14; d = addDays(d, 1), guard++) {
    const t = byDay.get(weekdayOf(d));
    if (t) list.push({ date: d, time: t });
  }
  return { list, extraFirst };
}

/** 첫 수업일 + 정규 시간 + 바꾼 회차 → 실제 수업 목록 (날짜순) 과 문제 */
export function buildLessons(input: { firstDate: KstDate; weeks: CourseWeeks; weeklyCount: number; slots: readonly RegularSlot[]; edits?: LessonEdits }): LessonPlan {
  const { firstDate, weeks, weeklyCount, slots } = input;
  const edits = input.edits ?? {};
  const { list, extraFirst } = baseLessons(firstDate, weeks * weeklyCount, slots);
  if (list.length === 0) return { lessons: [], startDate: null, endDate: null, extraFirst: false, problems: ['정규 요일·시간을 정해 주세요'] };

  const merged = list.map((b) => {
    const e = edits[b.date];
    const changed = !!e && (e.date !== b.date || e.time !== b.time);
    return { key: b.date, date: changed ? e.date : b.date, time: changed ? e.time : b.time, original: changed ? b : null };
  });
  merged.sort((a, b) => (a.date === b.date ? a.time.localeCompare(b.time) : a.date.localeCompare(b.date)));
  const lessons: PlanLesson[] = merged.map((m, i) => ({ n: i + 1, ...m }));

  const startDate = lessons[0].date;
  const periods = computePeriods(startDate, weeks);
  const endDate = periods[periods.length - 1].end;
  const problems: string[] = [];
  const seen = new Set<KstDate>();
  for (const l of lessons) {
    if (seen.has(l.date)) problems.push(`${md(l.date)}에 수업이 2개예요`);
    seen.add(l.date);
    if (l.date > endDate) problems.push(`${md(l.date)}는 수강 기간(~${md(endDate)}) 밖이에요`);
  }
  return { lessons, startDate, endDate, extraFirst, problems };
}

/** DB·강사 제안문에 보낼 목록 — 정규 요일 반복과 다를 때만 필요 (같으면 예전 방식으로 저장) */
export const needsLessonList = (plan: LessonPlan) => plan.extraFirst || plan.lessons.some((l) => l.original);
export const lessonPayload = (plan: LessonPlan): LessonDate[] => plan.lessons.map((l) => ({ date: l.date, time: l.time }));

/**
 * 수업 목록이 정규 요일 반복과 어디가 다른지 (안내문용): 수강 기간 안 정규 요일 날짜와 비교.
 * added = 정규와 다른 날·시각에 있는 수업, removed = 정규 요일인데 수업이 없는 날
 */
export function regularDiff(list: readonly LessonDate[], slots: readonly RegularSlot[], startDate: KstDate, endDate: KstDate): { added: LessonDate[]; removed: LessonDate[] } {
  const byDay = new Map(slots.map((s) => [s.weekday, s.time] as const));
  const regular: LessonDate[] = [];
  for (let d = startDate; d <= endDate; d = addDays(d, 1)) {
    const t = byDay.get(weekdayOf(d));
    if (t) regular.push({ date: d, time: t });
  }
  const k = (x: LessonDate) => `${x.date} ${x.time}`;
  const inList = new Set(list.map(k));
  const inRegular = new Set(regular.map(k));
  return { added: list.filter((x) => !inRegular.has(k(x))), removed: regular.filter((x) => !inList.has(k(x))) };
}
