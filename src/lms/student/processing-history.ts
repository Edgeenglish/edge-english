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
    result: e.kind === 'lesson_canceled' && e.tutor_fault ? '강사 사정으로 취소 처리 완료' : result,
  };
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

export function historySummary(e: ProcessingEvent, timezone: string): string {
  const original = historyOriginalDay(e, timezone);
  const label = historyLabel(e);
  const result = e.kind === 'makeup_confirmed' && e.booked_at
    ? `${historyDay(e.booked_at, timezone)} ${label.title}` : label.result;
  return `${original ? `${original} 수업분` : '원래 수업 날짜 미기록'} → ${result}`;
}
