// 수업 변경·보강 화면 계산 (1순위, migration 1700) — 판정은 DB 함수가 하고, 여기는 목록·보강 권리·안내 문구만
// - 날짜는 사람이 타이핑하지 않고 실제 수업 목록에서 고름 ('다음 주 목요일' 오해 방지, 17번 2절)
// - 안내 문구는 DB에 저장된 원래 수업·바뀐 수업 시각으로 만듦 (원래 날짜와 변경·보강 날짜 모두 표기)

import { formatInZone, instantToKstDate, type KstDate } from '../rules/dates';
import { CONFIRMED } from '../rules/policy';
import { grantsMakeup, type ClassStatus } from '../rules/status';
import { enWhen, koWhen } from './confirm';

export type ChLesson = {
  id: string;
  kind: 'regular' | 'makeup' | 'compensation' | 'carryover' | 'migrated_makeup' | 'migrated_extra';
  seq: number | null;
  startsAt: Date;
  state: 'scheduled' | 'canceled' | 'done';
  classStatus: ClassStatus | null;
  makeupOf: string | null;
  voided: boolean;
  tutorId: string;
  tutorName: string;
  tutorTz: string;
};

export type ChChange = {
  id: string;
  lessonId: string;
  type: 'student_cancel' | 'tutor_cancel';
  status: 'applied' | 'reverted';
  requestedAt: Date | null;
  decidedAt: Date;
  decision: ChangeDecision;
};

/** DB admin_change_lesson 결과 (미리 보기·확정 같은 모양) */
export type ChangeDecision = {
  status: ClassStatus;
  timing: 'advance' | 'late';
  who: 'student' | 'tutor';
  hours_before: number;
  uses_credit: boolean;
  credits_left: number;
  credits_after: number;
  makeup_allowed: boolean;
  makeup_until: KstDate | null;
  reward_won: number;
  holiday: boolean;
  change_request_id?: string;
  repeated?: boolean;
};

export type ChMakeupRequest = {
  id: string;
  sourceLessonId: string | null;
  migratedItemId: string | null;
  status: 'requested' | 'countered' | 'confirmed' | 'declined' | 'expired' | 'withdrawn' | 'voided';
  candidates: Date[];
  confirmedLessonId: string | null;
};

export type ChMigratedOpen = { id: string; originalDate: KstDate | null; tutorLeave: boolean };

export type NoticeEvent = 'change' | 'makeup_ask' | 'makeup_confirmed' | 'makeup_voided' | 'revert';
export type ChNotice = {
  id: string;
  changeRequestId: string | null;
  makeupRequestId: string | null;
  event: NoticeEvent;
  recipient: 'student' | 'tutor';
  status: 'pending' | 'sent' | 'not_needed';
  sentAt: Date | null;
  createdAt: Date;
};

export type ChStudent = { id: string; code: string; nameKo: string; nameEn: string; timezone: string };
export type ChEnrollment = { id: string; finalEndDate: KstDate; durationMin: number };

const WD = ['일', '월', '화', '수', '목', '금', '토'];
/** '10/29 (목) 17:00' 한국 시각 */
export function kstLabel(at: Date): string {
  const f = formatInZone(at, 'Asia/Seoul');
  const d = instantToKstDate(at);
  return `${Number(d.slice(5, 7))}/${Number(d.slice(8))} (${WD[new Date(`${d}T00:00:00Z`).getUTCDay()]}) ${f.time}`;
}
export function dateLabel(d: KstDate): string {
  return `${Number(d.slice(5, 7))}/${Number(d.slice(8))} (${WD[new Date(`${d}T00:00:00Z`).getUTCDay()]})`;
}

export const KIND_TEXT: Record<ChLesson['kind'], string> = {
  regular: '정규', makeup: '보강', migrated_makeup: '보강', compensation: '보상', carryover: '이월', migrated_extra: '추가',
};
export function lessonTag(l: ChLesson): string {
  return l.kind === 'regular' && l.seq ? `정규 ${l.seq}회` : KIND_TEXT[l.kind];
}

/** 고를 수 있는 수업: 아직 진행 전(예정)인 수업, 오늘(한국)부터. 시간순 */
export function changeableLessons(lessons: ChLesson[], now: Date): ChLesson[] {
  const today = instantToKstDate(now);
  return lessons.filter((l) => l.state === 'scheduled' && instantToKstDate(l.startsAt) >= today).sort((a, b) => +a.startsAt - +b.startsAt);
}

export type MakeupRight =
  | { kind: 'lesson'; key: string; source: ChLesson; open: ChMakeupRequest | null }
  | { kind: 'migrated'; key: string; item: ChMigratedOpen; open: ChMakeupRequest | null };

/** 보강 받을 권리: 보강 받는 결과로 끝났는데 살아 있는 보강이 없는 수업 + 이관한 미예약 보강 */
export function makeupRights(lessons: ChLesson[], migrated: ChMigratedOpen[], requests: ChMakeupRequest[]): MakeupRight[] {
  const live = new Set(lessons.filter((l) => l.makeupOf && l.state !== 'canceled').map((l) => l.makeupOf));
  const openFor = (f: (r: ChMakeupRequest) => boolean) => requests.find((r) => (r.status === 'requested' || r.status === 'countered') && f(r)) ?? null;
  const fromLessons: MakeupRight[] = lessons
    .filter((l) => !l.voided && l.classStatus && grantsMakeup(l.classStatus) && !live.has(l.id))
    .sort((a, b) => +a.startsAt - +b.startsAt)
    .map((l) => ({ kind: 'lesson', key: l.id, source: l, open: openFor((r) => r.sourceLessonId === l.id) }));
  const fromSheet: MakeupRight[] = migrated.map((m) => ({ kind: 'migrated', key: m.id, item: m, open: openFor((r) => r.migratedItemId === m.id) }));
  return [...fromLessons, ...fromSheet];
}

export const STATUS_SHORT: Partial<Record<ClassStatus, string>> = {
  'Student canceled in advance': '학생 정상 변경',
  'Student canceled in advance (public holiday)': '공휴일 정상 변경',
  'Student canceled late': '학생 늦은 변경',
  'No change credits left': '변경권 없음',
  'Tutor canceled in advance': '강사 정상 취소',
  'Tutor canceled late': '강사 늦은 취소',
};

/** 미리 보기 결과 줄 (화면 표시용, 짧게) */
export function decisionLines(d: ChangeDecision): string[] {
  const lines = [`${STATUS_SHORT[d.status] ?? d.status} · 수업 ${d.hours_before}시간 전 요청`];
  if (d.who === 'student') {
    if (d.uses_credit) lines.push(`변경권 ${d.credits_left} → ${d.credits_after}`);
    else lines.push(`변경권 ${d.credits_left} (차감 없음)`);
  }
  if (d.makeup_allowed && d.makeup_until) lines.push(`보강 ${dateLabel(d.makeup_until)}까지`);
  else lines.push('보강 없음 · 수업 1회 차감');
  if (d.reward_won > 0) lines.push(`학생 적립금 ${d.reward_won.toLocaleString('ko-KR')}원`);
  return lines;
}

// ---------------------------------------------------------------------
// 안내 문구 (학생: 카카오톡 한국어 / 강사: WhatsApp 영어). 해외 학생은 현지 시각을 앞에, 한국 시각을 괄호로
// ---------------------------------------------------------------------

function koAt(at: Date, tz: string): string {
  const kst = koWhen(at, 'Asia/Seoul');
  if (!tz || tz === 'Asia/Seoul') return kst;
  return `${koWhen(at, tz)} (한국 ${kst})`;
}
const enAt = (at: Date, tz: string) => `${enWhen(at, tz || 'Asia/Seoul')}${!tz || tz === 'Asia/Seoul' ? ' KST' : ' your time'}`;

export type NoticeContext = {
  student: ChStudent;
  durationMin: number;
  /** 변경된(취소된) 수업 또는 보강의 원래 수업 */
  lesson?: ChLesson;
  decision?: ChangeDecision;
  /** 보강: 후보 시간 / 확정된·없앤 보강 수업 시각 */
  candidates?: Date[];
  makeupAt?: Date;
  /** 이관 보강의 원래 수업 날짜 (모르면 null) */
  originalDate?: KstDate | null;
  tutorName: string;
  tutorTz: string;
};

function originKo(c: NoticeContext): string {
  if (c.lesson) return koAt(c.lesson.startsAt, c.student.timezone);
  return c.originalDate ? `${Number(c.originalDate.slice(5, 7))}월 ${Number(c.originalDate.slice(8))}일` : '시트 기록 보강';
}
function originEn(c: NoticeContext): string {
  if (c.lesson) return enAt(c.lesson.startsAt, c.tutorTz);
  return c.originalDate ? c.originalDate : 'earlier class';
}

/** 보강은 학생이 수업 시간에 강사와 정해도 되고 운영진에게 말해도 됨 (확정은 운영진, D-43) */
const makeupLineKo = (until: KstDate) => `보강: ${dateLabel(until)}까지 잡을 수 있어요. 수업 시간에 강사님과 정하셔도 되고, 저희에게 말씀하셔도 돼요.`;
const EN_MON = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
const EN_WD = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];
const enDate = (d: KstDate) => `${EN_WD[new Date(`${d}T00:00:00Z`).getUTCDay()]} ${Number(d.slice(8))} ${EN_MON[Number(d.slice(5, 7)) - 1]}`;
/** 강사가 학생과 보강 시간을 이야기해도 되지만 직접 확정하지 않고 운영진에게 먼저 (2026-10-26 대표) */
const makeupLinesEn = (until: KstDate) => [
  `Make-up: you can agree on a make-up time with the student during class (any day until ${enDate(until)}).`,
  'Please do NOT confirm it yourself. Send us the agreed date and time first, and we will confirm it.',
];

export function studentNotice(event: NoticeEvent, c: NoticeContext): string {
  const name = c.student.nameKo;
  if (event === 'change' && c.lesson && c.decision) {
    const d = c.decision;
    const at = koAt(c.lesson.startsAt, c.student.timezone);
    if (d.who === 'tutor') {
      return [
        `[엣지영어] ${name}님, 강사 사정으로 수업이 취소됐어요`,
        `취소된 수업: ${at}`,
        d.reward_won > 0 ? '수업 직전에 취소돼 불편을 드려 정말 죄송합니다.' : '불편을 드려 죄송합니다.',
        d.reward_won > 0 ? `사과의 마음으로 적립금 ${d.reward_won.toLocaleString('ko-KR')}원을 드렸어요. 다음 수강 등록 결제 때 사용하실 수 있어요 (유효기간 없음).` : '',
        d.makeup_until ? makeupLineKo(d.makeup_until) : '',
      ].filter(Boolean).join('\n');
    }
    const lines = [`[엣지영어] ${name}님, 수업 변경 처리됐어요`, `변경한 수업: ${at}`];
    if (d.status === 'Student canceled in advance') lines.push(`변경권 1개 사용 (남은 변경권 ${d.credits_after}개)`);
    if (d.status === 'Student canceled in advance (public holiday)') lines.push('공휴일 수업이라 변경권은 차감되지 않아요');
    if (d.status === 'Student canceled late') lines.push(`수업 ${CONFIRMED.changeNoticeHours}시간 전이 지나 보강 없이 수업 1회가 차감돼요 (변경권은 그대로)`);
    if (d.status === 'No change credits left') lines.push('이번 기간 변경권이 없어 보강 없이 수업 1회가 차감돼요');
    if (d.makeup_allowed && d.makeup_until) lines.push(makeupLineKo(d.makeup_until));
    lines.push('요청하신 날짜와 다르면 바로 말씀해 주세요');
    return lines.join('\n');
  }
  if (event === 'makeup_confirmed' && c.makeupAt) {
    return [`[엣지영어] ${name}님, 보강이 확정됐어요`, `원래 수업: ${originKo(c)}`, `보강 수업: ${koAt(c.makeupAt, c.student.timezone)}`, `강사: ${c.tutorName}`].join('\n');
  }
  if (event === 'makeup_voided' && c.makeupAt) {
    return [`[엣지영어] ${name}님, 보강 일정 정정 안내`, `보강 수업 ${koAt(c.makeupAt, c.student.timezone)}은 진행하지 않아요`, `원래 수업: ${originKo(c)}`, '보강 날짜는 다시 잡아 드릴게요'].join('\n');
  }
  if (event === 'revert' && c.lesson) {
    return [
      `[엣지영어] ${name}님, 수업 변경 정정 안내`,
      `${koAt(c.lesson.startsAt, c.student.timezone)} 수업은 그대로 진행해요`,
      c.decision?.uses_credit ? '사용한 변경권은 돌려드렸어요' : '',
      c.makeupAt ? `잡혀 있던 보강 ${koAt(c.makeupAt, c.student.timezone)}은 진행하지 않아요` : '',
    ].filter(Boolean).join('\n');
  }
  return '';
}

export function tutorNotice(event: NoticeEvent, c: NoticeContext): string {
  const who = c.student.nameEn;
  if (event === 'change' && c.lesson && c.decision) {
    const d = c.decision;
    return [
      d.who === 'tutor' ? `CANCELED (tutor) - ${who}` : `CANCELED - ${who}`,
      `Class: ${enAt(c.lesson.startsAt, c.tutorTz)}`,
      'No class at this time.',
      ...(d.makeup_allowed && d.makeup_until ? makeupLinesEn(d.makeup_until) : []),
    ].join('\n');
  }
  if (event === 'makeup_ask' && c.candidates) {
    return [
      `Make-up request - ${who} (${c.durationMin} min), not confirmed yet`,
      `Original class: ${originEn(c)}`,
      'Are you available at any of these times?',
      ...c.candidates.map((t, i) => `${i + 1}) ${enAt(t, c.tutorTz)}`),
    ].join('\n');
  }
  if (event === 'makeup_confirmed' && c.makeupAt) {
    return [`CONFIRMED make-up - ${who} (${c.durationMin} min)`, `Original class: ${originEn(c)}`, `Make-up: ${enAt(c.makeupAt, c.tutorTz)}`, 'Please add it to your schedule. Thank you!'].join('\n');
  }
  if (event === 'makeup_voided' && c.makeupAt) {
    return [`CANCELED make-up - ${who}`, `Make-up: ${enAt(c.makeupAt, c.tutorTz)}`, 'No class at this time.'].join('\n');
  }
  if (event === 'revert' && c.lesson) {
    return [
      `CORRECTION - ${who}`,
      `Class ${enAt(c.lesson.startsAt, c.tutorTz)} will go ahead as scheduled.`,
      c.makeupAt ? `Make-up ${enAt(c.makeupAt, c.tutorTz)} is canceled.` : '',
    ].filter(Boolean).join('\n');
  }
  return '';
}

export const EVENT_TEXT: Record<NoticeEvent, string> = {
  change: '변경 안내', makeup_ask: '보강 가능 확인', makeup_confirmed: '보강 확정 안내', makeup_voided: '보강 정정 안내', revert: '정정 안내',
};
