// 신규 배정 확정 관리 (정책 원본 H22, D-51 2026-10-22 대표: 전부 추천안)
// - 일정안 = 강사·요일·시각·첫 수업일 한 벌. 강사 '가능' 답 전에는 확정하지 않음 (DB migration 1000)
// - 확정 → 학생·강사 최종 안내 2건. [보냄]를 누른 시각 = 그쪽 '보냄' ([복사]만으로는 기록 안 함). 둘 다 보내야 매칭 업무가 끝남
// - 화면에 보이는 시간은 한국 / 강사 현지 / 학생 현지 세 줄. 현지 요일이 다르면 표시 (서머타임은 날짜별로 계산)
// - 경고 시각 (D-51-3): 확정 후 1시간 지나도 한쪽 안 보냄 = 긴급, 첫 수업 24시간 전 = 맨 위, 제안 후 24시간 무응답 = 답 확인 필요
// - 강사 확인 회신은 완료 조건이 아님 (D-51-2). 발송 순서 강제 없음, 강사 줄을 위에 (D-51-5)

import { addDays, ampmEn, ampmKo, formatInZone, hoursBetween, kstToInstant, weekdayOf, WEEKDAY_KO, type KstDate } from '../rules/dates';
import type { RegularSlot } from '../rules/schedule';
import { regularDiff, type LessonDate } from '../rules/lessons';
import { bold, enBoth, enDay, enZoneName, koBoth, koDay, koSi, koZoneBracket } from './time-text';

export const CONFIRM_ALERT = {
  unsentAfterConfirmH: 1, // 확정 후 이 시간이 지나도 한쪽이 '안 보냄'이면 긴급
  firstLessonWithinH: 24, // 첫 수업이 이 시간 안이면 맨 위
  noReplyAfterH: 24, // 강사 제안 후 이 시간 답이 없으면 '답 확인 필요'
} as const;

export type NoticeStatus = 'pending' | 'sent' | 'failed' | 'unknown';
export type Notice = { id: string; status: NoticeStatus; sentAt: Date | null };

export type PlanView = {
  planId: string;
  state: 'proposed' | 'confirmed';
  studentNameEn: string;
  studentPlace: string; // '미국 뉴욕' (모르면 '')
  studentTz: string;
  tutorName: string;
  tutorPlace: string; // '호주 시드니'
  tutorTz: string;
  slots: RegularSlot[];
  startDate: KstDate;
  endDate: KstDate;
  lessons: number;
  /** 회차별로 날짜를 정한 일정안이면 그 목록 (KST, 날짜순). 없으면 정규 요일대로 */
  lessonList?: LessonDate[] | null;
  durationMin: number;
  proposalSentAt: Date | null;
  confirmedAt: Date | null;
  tutorNotice: Notice | null;
  studentNotice: Notice | null;
};

const EN_WD: Record<string, string> = { Sun: '일', Mon: '월', Tue: '화', Wed: '수', Thu: '목', Fri: '금', Sat: '토' };
const monFirst = (wd: number) => (wd + 6) % 7;

/** 정규 시간 하나를 그 요일 첫 수업 날짜 기준으로 어느 시간대의 요일·시각으로 */
function slotIn(s: RegularSlot, start: KstDate, tz: string) {
  let d = start;
  while (weekdayOf(d) !== s.weekday) d = addDays(d, 1);
  const f = formatInZone(kstToInstant(d, s.time), tz);
  return { wd: EN_WD[f.weekday] ?? f.weekday, time: f.time };
}

/** '수·금 오전 9:00' (같은 시각끼리 요일 묶음, 월요일부터). 영어 문구용은 '수·금 9:00 AM' (요일은 enDays 가 바꿈) */
function joinSlots(list: { wd: string; time: string; order: number }[], lang: 'ko' | 'en'): string {
  const byTime = new Map<string, { wd: string; order: number }[]>();
  for (const x of list) byTime.set(x.time, [...(byTime.get(x.time) ?? []), x]);
  return [...byTime]
    .map(([time, ds]) => `${ds.sort((a, b) => a.order - b.order).map((x) => x.wd).join('·')} ${lang === 'en' ? ampmEn(time) : ampmKo(time)}`)
    .join(', ');
}

export type TimeLine = { who: '한국' | '강사' | '학생'; text: string; otherDay: boolean };

/** 한국 / 강사 / 학생 세 줄. 강사·학생이 한국 시간대면 그 줄은 빼고, 현지 요일이 한국과 다르면 otherDay */
export function timeLines(v: Pick<PlanView, 'slots' | 'startDate' | 'tutorTz' | 'studentTz'>, lang: 'ko' | 'en' = 'ko'): TimeLine[] {
  const slots = [...v.slots].sort((a, b) => monFirst(a.weekday) - monFirst(b.weekday));
  const kst = slots.map((s) => ({ wd: WEEKDAY_KO[s.weekday], time: s.time, order: monFirst(s.weekday) }));
  const out: TimeLine[] = [{ who: '한국', text: joinSlots(kst, lang), otherDay: false }];
  for (const [who, tz] of [['강사', v.tutorTz], ['학생', v.studentTz]] as const) {
    if (!tz || tz === 'Asia/Seoul') continue;
    const loc = slots.map((s, i) => ({ ...slotIn(s, v.startDate, tz), order: i }));
    out.push({ who, text: joinSlots(loc, lang), otherDay: loc.some((l, i) => l.wd !== kst[i].wd) });
  }
  return out;
}

/** 첫 수업 시점 (첫 수업일의 정규 시간) */
export function firstLessonAt(v: Pick<PlanView, 'slots' | 'startDate' | 'lessonList'>): Date | null {
  if (v.lessonList?.length) return kstToInstant(v.lessonList[0].date, v.lessonList[0].time);
  const s = v.slots.find((x) => x.weekday === weekdayOf(v.startDate));
  return s ? kstToInstant(v.startDate, s.time) : null;
}

const EN_WD_FULL: Record<string, string> = { 일: 'Sun', 월: 'Mon', 화: 'Tue', 수: 'Wed', 목: 'Thu', 금: 'Fri', 토: 'Sat' };
const enDays = (text: string) => text.replace(/[일월화수목금토]/g, (c) => EN_WD_FULL[c]).replace(/·/g, ' & ');

/** 마지막 정규 수업 시점 (기간 끝에서 거꾸로 첫 정규 요일) */
function lastLessonAt(v: Pick<PlanView, 'slots' | 'endDate' | 'lessonList'>): Date | null {
  const l = v.lessonList?.at(-1);
  if (l) return kstToInstant(l.date, l.time);
  for (let i = 0; i < 7; i++) {
    const d = addDays(v.endDate, -i);
    const s = v.slots.find((x) => x.weekday === weekdayOf(d));
    if (s) return kstToInstant(d, s.time);
  }
  return null;
}

/** 정규 요일과 다른 날 (회차별 일정안일 때만). 첫 수업은 '첫 수업' 줄에 이미 있으니 빼고 */
function otherDates(v: PlanView) {
  if (!v.lessonList?.length) return { added: [], removed: [] };
  const d = regularDiff(v.lessonList, v.slots, v.startDate, v.endDate);
  const first = v.lessonList[0];
  return { added: d.added.filter((x) => !(x.date === first.date && x.time === first.time)), removed: d.removed };
}
const at = (x: LessonDate) => kstToInstant(x.date, x.time);

/** 강사 안내 (영어): 정규와 다른 날 / 수업 없는 정규 요일 */
function enOtherLines(v: PlanView, tz: string): string[] {
  const d = otherDates(v);
  return [
    d.added.length ? `Other days: ${d.added.map((x) => enBoth(at(x), tz)).join('; ')}` : '',
    d.removed.length ? `No class (regular day): ${d.removed.map((x) => enDay(at(x), tz)).join('; ')}` : '',
  ];
}

function tutorLine(v: PlanView) {
  const tz = v.tutorTz || 'Asia/Seoul';
  const local = timeLines({ ...v, studentTz: '' }, 'en').find((l) => l.who === '강사')?.text ?? timeLines(v, 'en')[0].text;
  // 도시 이름으로 (QA UX: 'your time' 만 쓰지 않음). 해외 강사는 한국 시간도 같이
  const kstLine = timeLines({ ...v, studentTz: '' }, 'en').find((l) => l.who === '한국')?.text;
  return tz === 'Asia/Seoul' ? `Every ${enDays(local)} ${bold('KST')}` : `Every ${enDays(local)} ${bold(enZoneName(tz))}${kstLine ? ` / ${enDays(kstLine)} ${bold('KST')}` : ''}`;
}

/** 강사 제안 (WhatsApp, 영어). 확정이 아님을 분명히 */
export function proposalMessage(v: PlanView): string {
  const first = firstLessonAt(v);
  return [
    `Hi ${v.tutorName}, new student request (not confirmed yet):`,
    `${v.studentNameEn}, ${v.durationMin} min, ${v.lessons} classes`,
    tutorLine(v),
    first ? `First class: ${enBoth(first, v.tutorTz || 'Asia/Seoul')}` : '',
    ...enOtherLines(v, v.tutorTz || 'Asia/Seoul'),
    'Can you take this?',
  ]
    .filter(Boolean)
    .join('\n');
}

/** 강사 최종 확정 (WhatsApp, 영어) */
export function tutorConfirmMessage(v: PlanView): string {
  const tz = v.tutorTz || 'Asia/Seoul';
  const first = firstLessonAt(v);
  const last = lastLessonAt(v);
  return [
    'CONFIRMED - new student',
    `${v.studentNameEn}, ${v.durationMin} min, ${v.lessons} classes`,
    tutorLine(v),
    first ? `First class: ${enBoth(first, tz)}${last ? ` · last ${enDay(last, tz)}` : ''}` : '',
    ...enOtherLines(v, tz),
    'Please add it to your schedule. Thank you!',
  ]
    .filter(Boolean)
    .join('\n');
}

/** 학생 안내 (한국어): 정규와 다른 날 / 수업 없는 정규 요일 */
function koOtherLines(v: PlanView, tz: string): string[] {
  const d = otherDates(v);
  return [
    d.added.length ? `다른 요일 수업: ${d.added.map((x) => koBoth(at(x), tz)).join(' · ')}` : '',
    d.removed.length ? `수업 없는 정규 요일: ${d.removed.map((x) => koDay(at(x), tz)).join(', ')}` : '',
  ];
}

/** 학생 최종 확정 (카카오톡, 한국어). 해외 학생은 현지 시각을 먼저, 한국 시각을 아래에 */
export function studentConfirmMessage(v: PlanView): string {
  const lines = timeLines({ ...v, tutorTz: '' });
  const kst = lines[0].text;
  const local = lines.find((l) => l.who === '학생');
  const first = firstLessonAt(v);
  return [
    '[엣지영어] 수업 일정이 확정됐어요',
    `담당 강사: ${v.tutorName}`,
    local ? `매주 ${koSi(local.text)} ${koZoneBracket(v.studentTz)} / ${koSi(kst)} ${koZoneBracket('Asia/Seoul')}` : `매주 ${koSi(kst)} ${koZoneBracket('Asia/Seoul')}`,
    first ? `첫 수업: ${koBoth(first, local ? v.studentTz : 'Asia/Seoul')}` : '',
    ...koOtherLines(v, local ? v.studentTz : 'Asia/Seoul'),
    `정규 ${v.lessons}회 · ${v.durationMin}분`,
  ]
    .filter(Boolean)
    .join('\n');
}

export type PlanAlert = 'top' | 'urgent' | 'no_reply' | 'check' | 'none';

/** 경고 (D-51-3). top: 첫 수업 24시간 안인데 안내 미완료 / urgent: 확정 1시간 뒤에도 한쪽 안 보냄 /
 *  no_reply: 제안 24시간 무응답 / check: 자동 발송 결과 불명확·실패 (나중) */
export function planAlert(v: PlanView, now: Date): PlanAlert {
  if (v.state === 'proposed') {
    return v.proposalSentAt && hoursBetween(v.proposalSentAt, now) >= CONFIRM_ALERT.noReplyAfterH ? 'no_reply' : 'none';
  }
  const unsent = [v.tutorNotice, v.studentNotice].filter((n) => n?.status !== 'sent');
  if (unsent.length === 0) return 'none';
  const first = firstLessonAt(v);
  if (first && hoursBetween(now, first) <= CONFIRM_ALERT.firstLessonWithinH) return 'top';
  if (unsent.some((n) => n?.status === 'failed' || n?.status === 'unknown')) return 'check';
  if (v.confirmedAt && hoursBetween(v.confirmedAt, now) >= CONFIRM_ALERT.unsentAfterConfirmH) return 'urgent';
  return 'none';
}

/** 화면 표시용 보낸 시각 '10/21 오후 4:05' (한국) */
export function sentLabel(at: Date): string {
  const f = formatInZone(at, 'Asia/Seoul');
  return `${Number(f.date.slice(5, 7))}/${Number(f.date.slice(8))} ${ampmKo(f.time)}`;
}

/** 첫 수업 시작 전 개별 수업 날짜 변경 안내 (H26(62)): 학생 카톡(한국어, 현지 먼저) · 강사 WhatsApp(영어, 강사 현지) */
export function prestartMoveNotices(p: { studentNameEn: string; studentTz: string; studentCity: string | null; tutorTz: string; from: Date; to: Date }): { student: string; tutor: string } {
  const stz = p.studentTz || 'Asia/Seoul';
  const ttz = p.tutorTz || 'Asia/Seoul';
  const student = [
    '[엣지영어] 수업 날짜가 바뀌었어요',
    `이전: ${koBoth(p.from, stz)}`,
    `변경: ${koBoth(p.to, stz)}`,
  ].join('\n');
  const tutor = [
    `Schedule change - ${p.studentNameEn}`,
    `Previous: ${enBoth(p.from, ttz)}`,
    `New: ${enBoth(p.to, ttz)}`,
    'Please update your schedule. Thank you!',
  ].join('\n');
  return { student, tutor };
}
