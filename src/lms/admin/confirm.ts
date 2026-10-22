// 신규 배정 확정 관리 (정책 원본 H22, D-51 2026-10-22 대표: 전부 추천안)
// - 일정안 = 강사·요일·시각·첫 수업일 한 벌. 강사 '가능' 답 전에는 확정하지 않음 (DB migration 1000)
// - 확정 → 학생·강사 최종 안내 2건. 복사한 시각 = 그쪽 '보냄'. 둘 다 보내야 매칭 업무가 끝남
// - 화면에 보이는 시간은 한국 / 강사 현지 / 학생 현지 세 줄. 현지 요일이 다르면 표시 (서머타임은 날짜별로 계산)
// - 경고 시각 (D-51-3): 확정 후 1시간 지나도 한쪽 안 보냄 = 긴급, 첫 수업 24시간 전 = 맨 위, 제안 후 24시간 무응답 = 답 확인 필요
// - 강사 확인 회신은 완료 조건이 아님 (D-51-2). 발송 순서 강제 없음, 강사 줄을 위에 (D-51-5)

import { addDays, formatInZone, hoursBetween, kstToInstant, weekdayOf, WEEKDAY_KO, type KstDate } from '../rules/dates';
import type { RegularSlot } from '../rules/schedule';

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

/** '수·금 09:00' (같은 시각끼리 요일 묶음, 월요일부터) */
function joinSlots(list: { wd: string; time: string; order: number }[]): string {
  const byTime = new Map<string, { wd: string; order: number }[]>();
  for (const x of list) byTime.set(x.time, [...(byTime.get(x.time) ?? []), x]);
  return [...byTime]
    .map(([time, ds]) => `${ds.sort((a, b) => a.order - b.order).map((x) => x.wd).join('·')} ${time}`)
    .join(', ');
}

export type TimeLine = { who: '한국' | '강사' | '학생'; text: string; otherDay: boolean };

/** 한국 / 강사 / 학생 세 줄. 강사·학생이 한국 시간대면 그 줄은 빼고, 현지 요일이 한국과 다르면 otherDay */
export function timeLines(v: Pick<PlanView, 'slots' | 'startDate' | 'tutorTz' | 'studentTz'>): TimeLine[] {
  const slots = [...v.slots].sort((a, b) => monFirst(a.weekday) - monFirst(b.weekday));
  const kst = slots.map((s) => ({ wd: WEEKDAY_KO[s.weekday], time: s.time, order: monFirst(s.weekday) }));
  const out: TimeLine[] = [{ who: '한국', text: joinSlots(kst), otherDay: false }];
  for (const [who, tz] of [['강사', v.tutorTz], ['학생', v.studentTz]] as const) {
    if (!tz || tz === 'Asia/Seoul') continue;
    const loc = slots.map((s, i) => ({ ...slotIn(s, v.startDate, tz), order: i }));
    out.push({ who, text: joinSlots(loc), otherDay: loc.some((l, i) => l.wd !== kst[i].wd) });
  }
  return out;
}

/** 첫 수업 시점 (첫 수업일의 정규 시간) */
export function firstLessonAt(v: Pick<PlanView, 'slots' | 'startDate'>): Date | null {
  const s = v.slots.find((x) => x.weekday === weekdayOf(v.startDate));
  return s ? kstToInstant(v.startDate, s.time) : null;
}

const EN_MON = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
const EN_WD_FULL: Record<string, string> = { 일: 'Sun', 월: 'Mon', 화: 'Tue', 수: 'Wed', 목: 'Thu', 금: 'Fri', 토: 'Sat' };
const enDays = (text: string) => text.replace(/[일월화수목금토]/g, (c) => EN_WD_FULL[c]).replace(/·/g, ' & ');

/** 한 시점을 그 시간대 기준 'Wed 4 Nov 11:00' / '11월 4일(수) 09:00' */
function enWhen(at: Date, tz: string) {
  const f = formatInZone(at, tz);
  return `${f.weekday} ${Number(f.date.slice(8))} ${EN_MON[Number(f.date.slice(5, 7)) - 1]} ${f.time}`;
}
function koWhen(at: Date, tz: string) {
  const f = formatInZone(at, tz);
  return `${Number(f.date.slice(5, 7))}월 ${Number(f.date.slice(8))}일(${EN_WD[f.weekday]}) ${f.time}`;
}
/** 마지막 정규 수업 시점 (기간 끝에서 거꾸로 첫 정규 요일) */
function lastLessonAt(v: Pick<PlanView, 'slots' | 'endDate'>): Date | null {
  for (let i = 0; i < 7; i++) {
    const d = addDays(v.endDate, -i);
    const s = v.slots.find((x) => x.weekday === weekdayOf(d));
    if (s) return kstToInstant(d, s.time);
  }
  return null;
}

function tutorLine(v: PlanView) {
  const tz = v.tutorTz || 'Asia/Seoul';
  const local = timeLines({ ...v, studentTz: '' }).find((l) => l.who === '강사')?.text ?? timeLines(v)[0].text;
  return `Every ${enDays(local)} your time${tz === 'Asia/Seoul' ? ' (KST)' : ''}`;
}

/** 강사 제안 (WhatsApp, 영어). 확정이 아님을 분명히 */
export function proposalMessage(v: PlanView): string {
  const first = firstLessonAt(v);
  return [
    `Hi ${v.tutorName}, new student request (not confirmed yet):`,
    `${v.studentNameEn}, ${v.durationMin} min, ${v.lessons} classes`,
    tutorLine(v),
    first ? `First class: ${enWhen(first, v.tutorTz || 'Asia/Seoul')}` : '',
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
    first ? `First class: ${enWhen(first, tz)}${last ? ` · last ${enWhen(last, tz).replace(/ \d\d:\d\d$/, '')}` : ''}` : '',
    'Please add it to your schedule. Thank you!',
  ]
    .filter(Boolean)
    .join('\n');
}

/** 학생 최종 확정 (카카오톡, 한국어). 해외 학생은 현지 시각을 먼저, 한국 시각을 아래에 */
export function studentConfirmMessage(v: PlanView): string {
  const lines = timeLines({ ...v, tutorTz: '' });
  const kst = lines[0].text;
  const local = lines.find((l) => l.who === '학생');
  const first = firstLessonAt(v);
  const place = v.studentPlace.split(' ').pop() || '현지';
  return [
    '[엣지영어] 수업 일정이 확정됐어요',
    `담당 강사: ${v.tutorName}`,
    local ? `매주 ${local.text} (${place} 시각)\n= 한국 ${kst}` : `매주 ${kst} (한국 시각)`,
    first ? `첫 수업: ${koWhen(first, local ? v.studentTz : 'Asia/Seoul')}${local ? ` (${place})` : ''}` : '',
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

/** 화면 표시용 보낸 시각 '10/21 16:05' (한국) */
export function sentLabel(at: Date): string {
  const f = formatInZone(at, 'Asia/Seoul');
  return `${Number(f.date.slice(5, 7))}/${Number(f.date.slice(8))} ${f.time}`;
}
