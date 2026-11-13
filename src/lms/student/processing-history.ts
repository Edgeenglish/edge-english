import { ampmKo, formatInZone } from '../rules/dates';

export const HISTORY_LABELS = {
  lesson_canceled: ['수업 취소', '취소 처리 완료'],
  lesson_restored: ['수업 취소 되돌림', '수업 일정 복구 완료'],
  makeup_requested: ['보강 신청', '신청 접수 완료'],
  tutor_waiting: ['강사 확인 대기', '강사님께 확인 요청됨'],
  tutor_answered: ['강사 확인', '강사님 답변 접수 완료'],
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

/** Unknown kinds / missing processing times are never replaced by lesson times or now. */
export function processingEvents(rows: ProcessingEvent[]): ProcessingEvent[] {
  return rows.filter((e) => Object.hasOwn(HISTORY_LABELS, e.kind) && Number.isFinite(Date.parse(e.at)))
    .sort((a, b) => Date.parse(b.at) - Date.parse(a.at));
}

export function historyLabel(e: ProcessingEvent) {
  const [title, result] = HISTORY_LABELS[e.kind];
  return {
    title: e.compensation ? title.replace('보강', '보상수업') : title,
    result: e.kind === 'lesson_canceled' ? cancelResult(e, result) : result,
  };
}

/** 학생 '지난 보강권' 줄과 같은 사유 말: 내가 취소 · 강사가 취소 · 강사 휴무로 취소 · 강사 사정으로 취소 */
const CANCEL_REASON_KO = { student: '내가 취소', tutor_canceled: '강사가 취소', tutor_leave: '강사 휴무로 취소', tutor_fault: '강사 사정으로 취소' } as const;
function cancelResult(e: ProcessingEvent, fallback: string): string {
  if (e.cancel_reason && e.cancel_reason in CANCEL_REASON_KO) return `${CANCEL_REASON_KO[e.cancel_reason]} 처리 완료`;
  return e.tutor_fault ? '강사 사정으로 취소 처리 완료' : fallback;
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

export function historySummary(e: ProcessingEvent, timezone: string, waiting = false): string {
  const original = historyOriginalDay(e, timezone);
  const label = historyLabel(e);
  const result = e.kind === 'makeup_confirmed' && e.booked_at
    ? `${historyDay(e.booked_at, timezone)} ${label.title}` : waiting ? `${label.result} (강사 확인 대기 중)` : label.result;
  return `${original ? `${original} 수업분` : '원래 수업 날짜 미기록'} → ${result}`;
}
