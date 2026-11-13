import { ampmKo, formatInZone } from '../rules/dates';

export const HISTORY_LABELS = {
  lesson_canceled: ['수업 취소', '취소 처리 완료'],
  lesson_restored: ['수업 취소 되돌림', '수업 일정 복구 완료'],
  makeup_requested: ['보강 신청', '신청 접수 완료'],
  tutor_waiting: ['강사 확인 대기', '강사님께 확인 요청됨'],
  tutor_answered: ['강사 답변', '강사님 답변 접수 완료'],
  tutor_suggested: ['강사 제안', '새 보강 시간 제안'],
  suggestion_declined: ['다른 일정 요청', '일정 조율 요청 접수'],
  makeup_confirmed: ['보강 확정', '수업 일정에 반영 완료'],
  makeup_withdrawn: ['보강 신청 취소', '신청 취소 처리 완료'],
  makeup_expired: ['보강 신청 만료', '신청 만료 처리됨'],
  makeup_voided: ['보강 확정 되돌림', '확정 취소 처리 완료'],
} as const;

export type HistoryKind = keyof typeof HISTORY_LABELS;
export type ProcessingEvent = {
  id: string; at: string; kind: HistoryKind; request_id: string | null;
  lesson_at: string | null; original_date: string | null; tutor: string | null;
  compensation: boolean; tutor_fault: boolean | null; booked_at: string | null;
  /** 취소 사유 (옛 응답에는 없음): 학생 취소 · 강사 취소 · 강사 휴무 · 강사 사정(노쇼) */
  cancel_reason?: 'student' | 'tutor_canceled' | 'tutor_leave' | 'tutor_fault' | null;
  slots: { at: string; answer: string | null }[];
};

/**
 * Unknown kinds / missing processing times are never replaced by lesson times or now.
 * 'tutor_waiting' (강사 확인 대기)는 보강 신청 줄의 '상태 : 강사 확인 중'과 같은 정보라 화면에서 뺀다 (대표 11/13) — DB 기록은 그대로.
 */
export function processingEvents(rows: ProcessingEvent[]): ProcessingEvent[] {
  return rows.filter((e) => e.kind !== 'tutor_waiting' && Object.hasOwn(HISTORY_LABELS, e.kind) && Number.isFinite(Date.parse(e.at)))
    .sort((a, b) => Date.parse(b.at) - Date.parse(a.at));
}

export function historyLabel(e: ProcessingEvent) {
  const [title, result] = HISTORY_LABELS[e.kind];
  return {
    title: e.compensation ? title.replace('보강', '보상수업') : title,
    result,
  };
}

/** 학생 '지난 보강권' 줄과 같은 사유 말: 수강생 취소 · 강사가 취소 · 강사 휴무로 취소 · 강사 사정으로 취소 */
const CANCEL_REASON_KO = { student: '수강생 취소', tutor_canceled: '강사가 취소', tutor_leave: '강사 휴무로 취소', tutor_fault: '강사 사정으로 취소' } as const;
function cancelSubject(e: ProcessingEvent): string | null {
  if (e.cancel_reason && e.cancel_reason in CANCEL_REASON_KO) return CANCEL_REASON_KO[e.cancel_reason];
  return e.tutor_fault ? CANCEL_REASON_KO.tutor_fault : null;
}

/** 보강 신청이 아직 강사 답·확정·취소 없이 대기 중인지 (같은 신청의 뒤 단계 기록이 없으면 대기) */
const AFTER_REQUEST: HistoryKind[] = ['tutor_answered', 'tutor_suggested', 'suggestion_declined', 'makeup_confirmed', 'makeup_withdrawn', 'makeup_expired', 'makeup_voided'];
export function isWaitingForTutor(e: ProcessingEvent, all: ProcessingEvent[]): boolean {
  return e.kind === 'makeup_requested' && !!e.request_id && !all.some((x) => x.request_id === e.request_id && AFTER_REQUEST.includes(x.kind));
}

export function historyTime(at: string, timezone: string): string {
  const local = formatInZone(new Date(at), timezone);
  return `${historyDay(at, timezone)} ${ampmKo(local.time)}`;
}

export function historyDay(at: string, timezone: string): string {
  const { date, weekday } = formatInZone(new Date(at), timezone);
  const [, month, day] = date.split('-');
  const weekdays: Record<string, string> = { Sun: '일', Mon: '월', Tue: '화', Wed: '수', Thu: '목', Fri: '금', Sat: '토' };
  return `${Number(month)}/${Number(day)}(${weekdays[weekday]})`;
}

/** Date-only legacy records have no instant to convert. Keep their recorded Korean date. */
export function historyOriginalDay(e: ProcessingEvent, timezone: string): string | null {
  if (e.lesson_at) return historyDay(e.lesson_at, timezone);
  if (e.original_date) return `${historyDay(`${e.original_date}T12:00:00+09:00`, 'Asia/Seoul')}${timezone === 'Asia/Seoul' ? '' : ' (한국 날짜)'}`;
  return null;
}

/**
 * 처리 내역 줄 (대표 11/13 확정): 제목 / '원래 수업 : 11/9(월)'(취소는 '취소한 수업 : 11/9(월) · 수강생 취소') / '상태 : …'
 * 보강 신청 줄은 강사 답이 없을 때만 '상태 : 강사 확인 중', 뒤 단계가 생기면 상태 줄 없이 두 줄만 (status = null)
 */
export function historyLines(e: ProcessingEvent, timezone: string, waiting = false): { title: string; detail: string; status: string | null } {
  const original = historyOriginalDay(e, timezone) ?? '날짜 미기록';
  const label = historyLabel(e);
  const cancel = e.kind === 'lesson_canceled';
  const reason = cancel ? cancelSubject(e) : null;
  const status = e.kind === 'makeup_confirmed' && e.booked_at ? `${historyDay(e.booked_at, timezone)} ${label.title}`
    : e.kind === 'makeup_requested' ? (waiting ? '강사 확인 중' : null) : label.result;
  return { title: label.title, detail: `${cancel ? '취소한 수업' : '원래 수업'} : ${original}${reason ? ` · ${reason}` : ''}`, status };
}

/**
 * 줄을 눌렀을 때 보여 줄 시간: 신청한 보강 시간(확정된 시간에만 ok) · 강사가 제안한 시간.
 * 신청한 시간은 같은 신청의 '보강 신청' 기록에서 가져온다. 시간이 없으면 눌리지 않는 줄.
 */
export type HistorySlots = { requested: { at: string; ok: boolean }[]; suggested: string[]; confirmedExtra: string | null };
export function historySlots(e: ProcessingEvent, all: ProcessingEvent[]): HistorySlots {
  const none: HistorySlots = { requested: [], suggested: [], confirmedExtra: null };
  if (!e.request_id) return none;
  if (e.kind === 'tutor_suggested') return { ...none, suggested: e.slots.map((x) => x.at) };
  const req = all.find((x) => x.request_id === e.request_id && x.kind === 'makeup_requested');
  const base = (e.kind === 'makeup_requested' || e.kind === 'tutor_answered') && e.slots.length ? e.slots : req?.slots ?? [];
  const booked = e.kind === 'makeup_confirmed' && e.booked_at ? Date.parse(e.booked_at) : null;
  const requested = base.map((x) => ({ at: x.at, ok: booked !== null && Date.parse(x.at) === booked }));
  const matched = requested.some((x) => x.ok);
  return { requested, suggested: [], confirmedExtra: booked !== null && !matched && e.booked_at ? e.booked_at : null };
}
