// 수업 변경·보강 화면 계산 (1순위, migration 1700) — 판정은 DB 함수가 하고, 여기는 목록·보강 권리·안내 문구만
// - 날짜는 사람이 타이핑하지 않고 실제 수업 목록에서 고름 ('다음 주 목요일' 오해 방지, 17번 2절)
// - 안내 문구는 DB에 저장된 원래 수업·바뀐 수업 시각으로 만듦 (원래 날짜와 변경·보강 날짜 모두 표기)

import { ampmKo, formatInZone, instantToKstDate, type KstDate } from '../rules/dates';
import { CONFIRMED } from '../rules/policy';
import { grantsMakeup, type ClassStatus } from '../rules/status';
import { enBoth, koBoth } from './time-text';

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
  /** 강사가 강사 화면에서 확정한 보강 (H26(82)) */
  confirmedInTutorScreen?: boolean;
  /** 강사 LMS 답 (migration 2000): 시각(ms)별 가능/불가, 메모. 답 전이면 비어 있음 */
  tutorAnswers?: Record<number, 'yes' | 'no'>;
  tutorNote?: string | null;
  tutorAnsweredAt?: Date | null;
  /** 강사 노쇼 무료 보상수업 신청이면 보상권 id (4100). 같은 노쇼 수업의 원래 수업 보강과 따로 */
  compensationId?: string | null;
  /** 신청 시각·경로 (QA B-04): admin_on_behalf = 운영진 대신, student_app = 학생 LMS */
  requestedAt?: Date | null;
  via?: string | null;
};

/** 강사 노쇼 무료 보상수업 (4100). useUntil = 사용 기한(수강 종료일, 기한 안 재등록이면 이월) */
export type ChCompensation = { id: string; sourceLessonId: string; status: 'available' | 'used' | 'expired' | 'voided'; useUntil: KstDate };

export type ChMigratedOpen = { id: string; originalDate: KstDate | null; tutorLeave: boolean };

export type NoticeEvent = 'change' | 'makeup_ask' | 'makeup_confirmed' | 'makeup_voided' | 'revert' | 'makeup_rescheduled';
export type ChNotice = {
  id: string;
  changeRequestId: string | null;
  makeupRequestId: string | null;
  event: NoticeEvent;
  recipient: 'student' | 'tutor';
  status: 'pending' | 'sent' | 'not_needed';
  sentAt: Date | null;
  createdAt: Date;
  /** 자동 메일 (20261108010000, 보강 확정만). 없으면 자동 메일 대상이 아님(또는 기능 전 DB) */
  email?: ChNoticeEmail | null;
};
export type ChNoticeEmail = {
  status: 'queued' | 'sent' | 'failed' | 'no_address';
  /** 실제로 보낸 주소 (시험 단계에서는 support@) · 원래 받는 사람 주소 */
  to: string | null;
  intended: string | null;
  sentAt: Date | null;
  error: string | null;
  attempts: number;
};
/** 안내 줄의 자동 메일 상태 한 줄 (운영진 화면) */
export function emailStatusText(e: ChNoticeEmail, sentLabel: (d: Date) => string): string {
  const to = e.to && e.intended && e.to !== e.intended ? `${e.to} (시험 · 원래 ${e.intended})` : (e.to ?? e.intended ?? '');
  if (e.status === 'sent') return `자동 메일 보냄${e.sentAt ? ` ${sentLabel(e.sentAt)}` : ''} · ${to}`;
  if (e.status === 'failed') return `자동 메일 실패 · ${e.error ?? '발송 서비스 오류'} · ${to}`;
  if (e.status === 'no_address') return `자동 메일 못 보냄 · ${e.error ?? '이메일이 없어요'}`;
  return e.error ? `자동 메일 대기 · ${e.error}` : `자동 메일 보내는 중 · ${to}`;
}

export type ChStudent = { id: string; code: string; nameKo: string; nameEn: string; timezone: string };
export type ChEnrollment = { id: string; finalEndDate: KstDate; durationMin: number };

const WD = ['일', '월', '화', '수', '목', '금', '토'];
/** '10/29 (목) 오후 5:00' 한국 시각 (12시간 표기, 대표 2026-11-08) */
export function kstLabel(at: Date): string {
  const f = formatInZone(at, 'Asia/Seoul');
  const d = instantToKstDate(at);
  return `${Number(d.slice(5, 7))}/${Number(d.slice(8))} (${WD[new Date(`${d}T00:00:00Z`).getUTCDay()]}) ${ampmKo(f.time)}`;
}
/** 강사 현지 '11/6 (금) 오전 9:00' — 한국과 날짜가 달라도 그 나라 날짜로. 강사가 한국 시간대면 null (같은 시각이라 표시 안 함) */
export function tutorLocalLabel(at: Date, tz: string): string | null {
  if (!tz || tz === 'Asia/Seoul') return null;
  const f = formatInZone(at, tz);
  return `${Number(f.date.slice(5, 7))}/${Number(f.date.slice(8))} (${WD[new Date(`${f.date}T00:00:00Z`).getUTCDay()]}) ${ampmKo(f.time)}`;
}

/** 운영진 보강 확정 사유 (대표 2026-11-08, 운영진만 보임) */
export const CONFIRM_REASONS = [
  { value: 'kakao_agreed', label: '카톡으로 학생·강사와 이미 정함' },
  { value: 'student_request', label: '학생 요청' },
  { value: 'tutor_request', label: '강사 요청' },
  { value: 'other', label: '기타 (직접 적기)' },
] as const;
/** 확정된 보강 시간 고치기 사유 */
export const FIX_REASONS = [
  { value: 'admin_mistake', label: '운영진 입력 실수 정정' },
  { value: 'student_request', label: '학생 요청' },
  { value: 'tutor_request', label: '강사 요청' },
  { value: 'other', label: '기타 (직접 적기)' },
] as const;
export type MakeupReason = (typeof CONFIRM_REASONS)[number]['value'] | (typeof FIX_REASONS)[number]['value'];
export const REASON_TEXT: Record<MakeupReason, string> = {
  kakao_agreed: '카톡으로 학생·강사와 이미 정함', admin_mistake: '운영진 입력 실수 정정', student_request: '학생 요청', tutor_request: '강사 요청', other: '기타',
};
/** 운영 기록 한 줄 (admin_makeup_logs) */
export type MakeupLog = { id: string; makeupRequestId: string; lessonId: string | null; action: 'confirm' | 'reschedule'; reason: MakeupReason; note: string | null; oldAt: Date | null; newAt: Date; createdAt: Date };
export function dateLabel(d: KstDate): string {
  return `${Number(d.slice(5, 7))}/${Number(d.slice(8))} (${WD[new Date(`${d}T00:00:00Z`).getUTCDay()]})`;
}

/** 보강 시간은 한 수업당 강사에게 최대 2개 (2026-10-27 대표: 학생에게 2개 권장, 1개도 허용) */
export const MAKEUP_SLOTS_MAX = 2;

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

/** 앞으로의 취소된 수업 (오늘 한국 날짜부터, 시간순). 시간 고치기 대상이 아닌 지움(voided) 수업은 뺌 */
export function canceledUpcoming(lessons: ChLesson[], now: Date): ChLesson[] {
  const today = instantToKstDate(now);
  return lessons.filter((l) => l.state === 'canceled' && !l.voided && instantToKstDate(l.startsAt) >= today).sort((a, b) => +a.startsAt - +b.startsAt);
}

export type MakeupRight =
  | { kind: 'lesson'; key: string; source: ChLesson; open: ChMakeupRequest | null }
  | { kind: 'migrated'; key: string; item: ChMigratedOpen; open: ChMakeupRequest | null }
  | { kind: 'compensation'; key: string; comp: ChCompensation; source: ChLesson | null; open: ChMakeupRequest | null };

/** 보강 받을 권리: 보강 받는 결과로 끝났는데 살아 있는 보강이 없는 수업 + 강사 휴무 '기다림' 수업(1800) + 이관한 미예약 보강 */
/** + 강사 노쇼 무료 보상수업(4100): 날짜 안 잡은 보상권, 원래 수업 보강과 따로 신청 */
export function makeupRights(lessons: ChLesson[], migrated: ChMigratedOpen[], requests: ChMakeupRequest[], comps: ChCompensation[] = []): MakeupRight[] {
  // 보강 수업이 한 번 잡힌 원래 수업은 그 보강이 '없애기(voided)' 되지 않는 한 다시 권리가 아님 — 취소된 보강도 포함 (QA-13·R-24, student_screen 과 같은 규칙)
  const live = new Set(lessons.filter((l) => l.makeupOf && !l.voided).map((l) => l.makeupOf));
  const openFor = (f: (r: ChMakeupRequest) => boolean) => requests.find((r) => (r.status === 'requested' || r.status === 'countered') && f(r)) ?? null;
  const fromLessons: MakeupRight[] = lessons
    .filter((l) => !l.voided && l.classStatus && (grantsMakeup(l.classStatus) || l.classStatus === 'Tutor long-term leave') && !live.has(l.id))
    .sort((a, b) => +a.startsAt - +b.startsAt)
    .map((l) => ({ kind: 'lesson', key: l.id, source: l, open: openFor((r) => !r.compensationId && r.sourceLessonId === l.id) }));
  const fromSheet: MakeupRight[] = migrated.map((m) => ({ kind: 'migrated', key: m.id, item: m, open: openFor((r) => r.migratedItemId === m.id) }));
  const fromComps: MakeupRight[] = comps
    .filter((c) => c.status === 'available')
    .map((c) => ({ kind: 'compensation', key: `comp-${c.id}`, comp: c, source: lessons.find((l) => l.id === c.sourceLessonId) ?? null, open: openFor((r) => r.compensationId === c.id) }));
  return [...fromLessons, ...fromSheet, ...fromComps];
}

export const STATUS_SHORT: Partial<Record<ClassStatus, string>> = {
  'Student canceled in advance': '학생 정상 변경',
  'Student canceled in advance (public holiday)': '공휴일 정상 변경',
  'Student canceled late': '학생 늦은 변경',
  'No change credits left': '변경권 없음',
  'Tutor canceled in advance': '강사 정상 취소',
  'Tutor canceled late': '강사 늦은 취소',
  'Tutor long-term leave': '강사 휴무',
};

/** 취소된 수업 줄·변경 기록의 '누가 취소했는지' (처음 보는 사람도 바로 읽히게, 대표 11/8) */
export const STATUS_PLAIN: Partial<Record<ClassStatus, string>> = {
  'Student canceled in advance': '학생 미리 취소',
  'Student canceled in advance (public holiday)': '공휴일 취소',
  'Student canceled late': '학생 늦게 취소',
  'No change credits left': '학생 취소 (변경권 없음)',
  'Tutor canceled in advance': '강사 미리 취소',
  'Tutor canceled late': '강사 늦게 취소',
  'Tutor long-term leave': '강사 휴무',
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

/** 학생 안내 시각 (카톡·메일) — 시각 바로 뒤 [기준 이름], 두 시간대는 ' / ' (time-text.ts, 대표 2026-11-08)
 *  한국 거주 '11월 5일(목) 오전 10시 [한국 시간]' / 해외 '11월 4일(수) 오후 9시 [토론토 시간] / 오전 10시 [한국 시간]' */
export const koAt = (at: Date, tz: string) => koBoth(at, tz);
const koDate = (d: KstDate) => `${Number(d.slice(5, 7))}월 ${Number(d.slice(8))}일(${['일', '월', '화', '수', '목', '금', '토'][new Date(`${d}T00:00:00Z`).getUTCDay()]})`;
/** 강사 안내 시각 (WhatsApp·메일) — 'Mon, 9 Nov 6:00 PM *Ho Chi Minh Time* / 8:00 PM *KST*' (time-text.ts, 대표 2026-11-08) */
export const enAt = (at: Date, tz: string) => enBoth(at, tz);

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
  /** 강사 노쇼 무료 보상수업 안내 (4100) */
  compensation?: boolean;
  /** 보강 시간 변경 안내: 고치기 전 시각 */
  oldAt?: Date | null;
  /** 취소 안내를 보내는 시점의 보강 진행 상태 (추가 요청 6: 취소만 / 신청 중 / 강사 확인 끝 / 전부 불가 / 확정) */
  makeup?: { state: 'none' | 'requested' | 'tutor_answered' | 'declined' | 'confirmed'; candidates?: Date[]; at?: Date | null };
};

function originKo(c: NoticeContext): string {
  if (c.lesson) return koAt(c.lesson.startsAt, c.student.timezone);
  return c.originalDate ? `${Number(c.originalDate.slice(5, 7))}월 ${Number(c.originalDate.slice(8))}일` : '시트 기록 보강';
}
function originEn(c: NoticeContext): string {
  if (c.lesson) return enAt(c.lesson.startsAt, c.tutorTz);
  return c.originalDate ? c.originalDate : 'earlier class';
}

/** 톡으로 보내는 '보강 날짜 고르기' 바로가기 (11/8 대표): 학생 본인 LMS 에서 그 수업 날짜 고르기가 바로 열림 */
export const makeupLink = (id: string) => `${typeof window === 'undefined' ? '' : window.location.origin}/lms/student?makeup=${id}`;
/** 신청 기한(수강 종료일 한국 23:59): 학생 안내 시각 모양 그대로 + '까지' (time-text.ts) */
const untilKo = (until: KstDate, tz: string) => `${koAt(new Date(`${until}T23:59:00+09:00`), tz)}까지`;
/**
 * 보강은 학생이 LMS 에서 직접 신청 → 강사 확정 (11/8 대표: 수업 중에 강사와 정한 시간도 학생이 LMS 로 신청).
 * 링크가 없으면(이관 보강 등) 링크 줄만 빠짐
 */
const makeupLineKo = (until: KstDate, tz: string, lessonId?: string) => [
  '아래 링크에서 보강 날짜를 신청해 주세요. 강사님이 확인하면 확정돼요.',
  '수업 중에 강사님과 정한 시간이 있다면 그 시간을 골라 주세요.',
  `(신청 기한: ${untilKo(until, tz)})`,
  lessonId ? makeupLink(lessonId) : '',
].filter(Boolean).join('\n');
/** 취소 안내의 보강 줄 — 보내는 시점의 실제 상태에 맞게 (추가 요청 6). 상태를 모르면 예전 문구 */
function makeupStateKo(c: NoticeContext, until: KstDate): string {
  const m = c.makeup;
  const tz = c.student.timezone;
  if (!m || m.state === 'none') return makeupLineKo(until, tz, c.lesson?.id);
  if (m.state === 'confirmed' && m.at) return `보강 수업(확정): ${koAt(m.at, tz)}`;
  const picked = m.candidates && m.candidates.length > 0 ? `신청하신 날짜: ${m.candidates.map((t) => koAt(t, tz)).join(' / ')}` : '보강 날짜를 신청하셨어요.';
  if (m.state === 'requested') return `${picked}\n강사님 확인 후 확정 안내 드릴게요.`;
  if (m.state === 'tutor_answered') return `${picked}\n강사님 확인이 끝나 곧 확정 안내 드릴게요.`;
  return `${picked}\n강사님이 그 날짜에는 어렵다고 해요. 다른 날짜를 알려 주시면 조율해 드릴게요 (종료일 ${koDate(until)}까지).`;
}
/** 강사는 수업 중에 학생과 시간을 정해도 되고, 학생이 LMS 로 신청 → 강사가 Confirm make-up (11/8 대표). 기한 = 수강 종료일 한국 23:59 → 강사 현지 + KST */
const makeupLinesEn = (until: KstDate, tutorTz: string) => [
  `Make-up: you can agree on a make-up time with your student during class (until ${enAt(new Date(`${until}T23:59:00+09:00`), tutorTz)}). Make sure that time is open in your Availability, then ask the student to request it in the LMS.`,
  'When the request comes in, tap "Confirm make-up". If the student can\'t find the time, let us know.',
];

export function studentNotice(event: NoticeEvent, c: NoticeContext): string {
  const name = c.student.nameKo;
  if (event === 'change' && c.lesson && c.decision) {
    const d = c.decision;
    const at = koAt(c.lesson.startsAt, c.student.timezone);
    // 단락 사이 빈 줄 (2026-10-26 대표 문구)
    if (d.who === 'tutor') {
      return [
        `[엣지영어] ${name}님, 강사 사정으로 수업이 취소됐어요.`,
        `취소된 수업: ${at}`,
        d.reward_won > 0
          ? `불편을 드려 정말 죄송합니다. 사과의 마음으로 다음 수강 등록 시 사용하실 수 있는 적립금 ${d.reward_won.toLocaleString('ko-KR')}원을 드렸어요 (유효기간 없음).`
          : '불편을 드려 정말 죄송합니다.',
        d.makeup_until ? makeupStateKo(c, d.makeup_until) : '',
      ].filter(Boolean).join('\n\n');
    }
    const result =
      d.status === 'Student canceled in advance' ? `변경권 1개 사용 (잔여 ${d.credits_after}개)`
      : d.status === 'Student canceled in advance (public holiday)' ? '공휴일 수업이라 변경권은 차감되지 않아요.'
      : d.status === 'Student canceled late' ? `수업 ${CONFIRMED.changeNoticeHours}시간 전이 지나 보강 없이 수업 1회가 차감돼요 (변경권은 그대로).`
      : d.status === 'No change credits left' ? '이번 기간 변경권이 없어 보강 없이 수업 1회가 차감돼요.'
      : '';
    return [
      `[엣지영어] ${name}님, 요청하신 수업이 취소됐어요.`,
      [`취소된 수업: ${at}`, result].filter(Boolean).join('\n'),
      d.makeup_allowed && d.makeup_until ? makeupStateKo(c, d.makeup_until) : '',
      '취소된 수업 날짜가 요청하신 날짜와 다르다면 바로 알려주세요.',
    ].filter(Boolean).join('\n\n');
  }
  if (event === 'makeup_confirmed' && c.makeupAt) {
    if (c.compensation) {
      return [`[엣지영어] ${name}님, 무료 보상수업이 확정됐어요`, `강사 사정으로 진행하지 못한 수업: ${originKo(c)}`, `보상수업: ${koAt(c.makeupAt, c.student.timezone)}`, `강사: ${c.tutorName}`].join('\n');
    }
    return [`[엣지영어] ${name}님, 보강이 확정됐어요`, `원래 수업: ${originKo(c)}`, `보강 수업: ${koAt(c.makeupAt, c.student.timezone)}`, `강사: ${c.tutorName}`].join('\n');
  }
  if (event === 'makeup_rescheduled' && c.makeupAt) {
    return [
      `[엣지영어] ${name}님, ${c.compensation ? '무료 보상수업' : '보강'} 시간이 바뀌었어요`,
      `바뀐 시간: ${koAt(c.makeupAt, c.student.timezone)}`,
      c.oldAt ? `이전 시간: ${koAt(c.oldAt, c.student.timezone)} (취소)` : '',
      `${c.compensation ? '강사 사정으로 진행하지 못한 수업' : '원래 수업'}: ${originKo(c)}`,
      `강사: ${c.tutorName}`,
    ].filter(Boolean).join('\n');
  }
  if (event === 'makeup_voided' && c.makeupAt) {
    const w = c.compensation ? '보상수업' : '보강';
    return [`[엣지영어] ${name}님, ${w} 일정 정정 안내`, `${w} ${koAt(c.makeupAt, c.student.timezone)}은 진행하지 않아요`, `원래 수업: ${originKo(c)}`, `${w} 날짜는 다시 잡아 드릴게요`].join('\n');
  }
  if (event === 'revert' && c.lesson) {
    return [
      `[엣지영어] ${name}님, 수업 취소 정정 안내`,
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
    const m = c.makeup;
    const makeupEn = !d.makeup_allowed || !d.makeup_until ? []
      : m?.state === 'confirmed' && m.at ? [`Make-up already confirmed: ${enAt(m.at, c.tutorTz)}. Please add it to your schedule.`]
      : m?.state === 'requested' && m.candidates?.length ? [`The student asked for a make-up at: ${m.candidates.map((t) => enAt(t, c.tutorTz)).join(' / ')}.`, 'Please confirm it on your Home page (Make-up requests): tap "Confirm make-up".']
      : m?.state === 'tutor_answered' ? ['You already answered the make-up request. Edge English will confirm and let you know.']
      : m?.state === 'declined' ? ['You said the requested make-up times do not work. Edge English will arrange another time with the student.']
      : makeupLinesEn(d.makeup_until, c.tutorTz);
    return [
      d.who === 'tutor' ? `CANCELED (tutor) - ${who}` : `CANCELED - ${who}`,
      `Class: ${enAt(c.lesson.startsAt, c.tutorTz)}`,
      'No class at this time.',
      ...makeupEn,
    ].join('\n');
  }
  if (event === 'makeup_ask' && c.candidates) {
    return [
      `${c.compensation ? 'Compensation class request' : 'Make-up request'} - ${who} (${c.durationMin} min), not confirmed yet`,
      `Original class: ${originEn(c)}`,
      'Are you available at any of these times?',
      ...c.candidates.map((t, i) => `${i + 1}) ${enAt(t, c.tutorTz)}`),
    ].join('\n');
  }
  if (event === 'makeup_confirmed' && c.makeupAt) {
    const w = c.compensation ? 'Compensation class' : 'Make-up';
    return [`CONFIRMED ${w.toLowerCase()} - ${who} (${c.durationMin} min)`, `Original class: ${originEn(c)}`, `${w}: ${enAt(c.makeupAt, c.tutorTz)}`, 'Please add it to your schedule. Thank you!'].join('\n');
  }
  if (event === 'makeup_rescheduled' && c.makeupAt) {
    return [
      `TIME CHANGED ${c.compensation ? 'compensation class' : 'make-up'} - ${who} (${c.durationMin} min)`,
      `New time: ${enAt(c.makeupAt, c.tutorTz)}`,
      c.oldAt ? `Previous time (canceled): ${enAt(c.oldAt, c.tutorTz)}` : '',
      `Original class: ${originEn(c)}`,
      'Please update your schedule. Thank you!',
    ].filter(Boolean).join('\n');
  }
  if (event === 'makeup_voided' && c.makeupAt) {
    const w = c.compensation ? 'Compensation class' : 'Make-up';
    return [`CANCELED ${w.toLowerCase()} - ${who}`, `${w}: ${enAt(c.makeupAt, c.tutorTz)}`, 'No class at this time.'].join('\n');
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

/** 안내 카드 제목: '학생에게 보내는 ○○' / '강사 Maria에게 보내는 ○○' — 누구에게 무슨 안내인지 한눈에 (대표 11/8) */
export const EVENT_TEXT: Record<NoticeEvent, string> = {
  change: '수업 취소·변경 안내', makeup_ask: '보강 가능 여부 확인', makeup_confirmed: '보강 확정 안내', makeup_voided: '보강 취소 안내', revert: '취소 되돌림 안내', makeup_rescheduled: '보강 시간 변경 안내',
};
