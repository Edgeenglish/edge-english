import { ampmKo, formatInZone } from '../rules/dates';
import type { CreditItem } from './credit-history';

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
  /** 취소 일시 = 취소 판정에 쓴 요청 시각 · 6시간 이상(advance)/미만(late) (20261118110000, 옛 응답에는 없음) */
  cancel_at?: string | null;
  timing?: 'advance' | 'late' | null;
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

/**
 * 보강 신청 줄의 상태 (대표 11/13 확정):
 *  - 같은 신청에 확정·강사 제안·다른 일정 요청·철회·만료·되돌림 줄이 있으면 null (상태 줄 없음, 그 줄이 따로 보임)
 *  - 강사가 '맞는 시간 없음'으로 글만 남김(강사 답변 기록만 있음) → '보강 일정 조율 중'
 *  - 강사가 아직 아무 것도 안 함 → '강사 확인 중'
 */
const AFTER_REQUEST: HistoryKind[] = ['tutor_suggested', 'suggestion_declined', 'makeup_confirmed', 'makeup_withdrawn', 'makeup_expired', 'makeup_voided'];
export function requestStatus(e: ProcessingEvent, all: ProcessingEvent[]): string | null {
  if (e.kind !== 'makeup_requested' || !e.request_id) return null;
  const same = all.filter((x) => x.request_id === e.request_id);
  if (same.some((x) => AFTER_REQUEST.includes(x.kind))) return null;
  return same.some((x) => x.kind === 'tutor_answered') ? '보강 일정 조율 중' : '강사 확인 중';
}

/** 학생 처리 내역에 보이는 줄: '강사 답변'은 화면에서만 숨김 (답 내용을 보여 주지 않아 혼란, 대표 11/13) — DB 기록은 그대로 */
export function visibleEvents(all: ProcessingEvent[]): ProcessingEvent[] {
  return all.filter((e) => e.kind !== 'tutor_answered');
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
 * 보강 신청 줄 상태는 requestStatus() 결과 (없으면 상태 줄 없이 두 줄만)
 */
export function historyLines(e: ProcessingEvent, timezone: string, reqStatus: string | null = null): { title: string; detail: string | null; status: string | null } {
  const day = historyOriginalDay(e, timezone);
  const original = day ?? '날짜 미기록';
  const label = historyLabel(e);
  const cancel = e.kind === 'lesson_canceled';
  const reason = cancel ? cancelSubject(e) : null;
  const status = e.kind === 'makeup_confirmed' && e.booked_at ? `${historyDay(e.booked_at, timezone)} ${label.title}`
    : e.kind === 'makeup_requested' ? reqStatus : label.result;
  // 보상수업은 강사 노쇼로 생긴 추가 수업 — 그 노쇼 수업을 '강사 사정으로 취소된 수업'으로, 연결된 수업이 없으면 줄을 뺌 (대표 11/13)
  if (e.compensation && !cancel) return { title: label.title, detail: day ? `강사 사정으로 취소된 수업 : ${day}` : null, status };
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

/**
 * 처리 내역 한 줄 (대표 11/18 확정, 시안 https://claude.ai/artifact/VrFHjbDsD2icJEF9HAWFK6):
 * 제목 → 수업(진하게) → '○○ 일시'(작게) → 구분(작게, 취소만) → 상태·변경권(진하게).
 * 변경권 줄은 수강생 취소·취소 되돌림에만.
 */
export type HistoryRow = {
  title: string; lessonLabel: string | null; lesson: string | null; timeLabel: string; time: string;
  sub: string | null; status: string | null; credit: string | null;
};
const TIME_LABEL: Record<HistoryKind, string> = {
  lesson_canceled: '취소 일시', lesson_restored: '처리 일시', makeup_requested: '신청 일시', tutor_waiting: '처리 일시',
  tutor_answered: '처리 일시', tutor_suggested: '제안 일시', suggestion_declined: '요청 일시', makeup_confirmed: '확정 일시',
  makeup_withdrawn: '취소 일시', makeup_expired: '만료 일시', makeup_voided: '처리 일시',
};
const TIMING_KO = { advance: '6시간 이상 남았을 때', late: '6시간 미만 남았을 때' } as const;

function lessonText(e: ProcessingEvent, timezone: string): string | null {
  if (e.lesson_at) return historyTime(e.lesson_at, timezone);
  return historyOriginalDay(e, timezone);
}
function cancelSub(e: ProcessingEvent, credit: CreditItem | null): string | null {
  const reason = e.cancel_reason ?? (e.tutor_fault ? 'tutor_fault' : null);
  if (reason === 'tutor_leave') return '강사 휴무로 취소';
  if (reason === 'tutor_fault') return '강사 사정으로 취소';
  const timing = e.timing ?? credit?.timing ?? null;
  const who = reason === 'tutor_canceled' ? '강사 취소' : reason === 'student' ? '수강생 취소' : null;
  const parts = [timing ? TIMING_KO[timing] : null, who, credit?.holiday ? '공휴일' : null].filter(Boolean);
  return parts.length ? parts.join(' · ') : null;
}
export function creditText(c: CreditItem): string | null {
  const charged = ' · 수업 1회 차감'; // 그때 결과 그대로 (대표 11/18)
  switch (c.kind) {
    case 'use': return `1개 사용 · ${c.after + 1}개 → ${c.after}개`;
    case 'late': return `사용 안 됨${charged}`;
    case 'no_credit': return `남은 0개${charged}`;
    case 'holiday': return '사용 안 됨 (공휴일)';
    case 'return': return `1개 반환 · ${c.after - 1}개 → ${c.after}개`;
    default: return null;
  }
}
export function historyRow(e: ProcessingEvent, timezone: string, reqStatus: string | null = null, credit: CreditItem | null = null): HistoryRow {
  const label = historyLabel(e);
  const cancel = e.kind === 'lesson_canceled';
  const lesson = lessonText(e, timezone);
  const lessonLabel = cancel ? '취소한 수업' : e.compensation && e.kind !== 'lesson_restored' ? (lesson ? '강사 사정으로 취소된 수업' : null) : '원래 수업';
  const status = e.kind === 'makeup_confirmed' && e.booked_at ? `${historyTime(e.booked_at, timezone)} ${label.title}`
    : e.kind === 'makeup_requested' ? reqStatus : label.result;
  return {
    title: label.title, lessonLabel, lesson: lessonLabel ? lesson ?? '날짜 미기록' : null,
    timeLabel: TIME_LABEL[e.kind], time: historyTime(cancel && e.cancel_at ? e.cancel_at : e.at, timezone),
    sub: cancel ? cancelSub(e, credit) : null, status, credit: credit ? creditText(credit) : null,
  };
}
