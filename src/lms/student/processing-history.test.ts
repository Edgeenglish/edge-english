import { describe, expect, it } from 'vitest';
import { historyLabel, historyOriginalDay, historyLines, historySlots, historyTime, processingEvents, requestStatus, visibleEvents, type ProcessingEvent } from './processing-history';

const event = (id: string, at: string, kind: ProcessingEvent['kind']): ProcessingEvent => ({
  id, at, kind, request_id: 'same-request', lesson_at: '2027-01-01T12:00:00Z',
  original_date: null, tutor: 'Tutor', compensation: false, tutor_fault: false, booked_at: null, slots: [],
});

describe('student processing history', () => {
  it('sorts actual processing times and keeps every stage of the same request', () => {
    const rows = [event('request', '2026-11-11T01:00:00Z', 'makeup_requested'), event('confirm', '2026-11-11T03:00:00Z', 'makeup_confirmed'), event('suggest', '2026-11-11T02:00:00Z', 'tutor_suggested')];
    expect(processingEvents(rows).map((e) => e.id)).toEqual(['confirm', 'suggest', 'request']);
    expect(rows[0].id).toBe('request');
  });
  it('does not invent processing times and hides the duplicate waiting row', () => {
    const at = '2026-11-11T01:00:00Z';
    expect(processingEvents([event('waiting', at, 'tutor_waiting'), event('request', at, 'makeup_requested'), event('missing', '', 'makeup_confirmed')]).map((e) => e.id)).toEqual(['request']); // 강사 확인 대기 줄은 화면에서 뺌
  });
  it('does not describe historical waiting as the current state', () => {
    expect(historyLabel(event('waiting', '2026-11-11T01:00:00Z', 'tutor_waiting')).result).toBe('강사님께 확인 요청됨');
  });
  it('uses student timezone across a date boundary and DST', () => {
    expect(historyTime('2026-11-11T16:00:00Z', 'Asia/Seoul')).toBe('11/12(목) 오전 1:00');
    expect(historyTime('2026-11-11T16:00:00Z', 'America/Toronto')).toBe('11/11(수) 오전 11:00');
    expect(historyTime('2026-07-11T16:00:00Z', 'America/Toronto')).toBe('7/11(토) 오후 12:00');
    expect(historyTime('2026-11-05T07:14:00Z', 'Asia/Seoul')).toBe('11/5(목) 오후 4:14');
  });
  it('identifies the original and confirmed classes before opening details', () => {
    const e = { ...event('confirm', '2026-11-11T01:00:00Z', 'makeup_confirmed'), lesson_at: '2026-11-10T23:30:00Z', booked_at: '2026-11-17T23:30:00Z' };
    expect(historyLines(e, 'Asia/Seoul')).toEqual({ title: '보강 확정', detail: '원래 수업 : 11/11(수)', status: '11/18(수) 보강 확정' });
    expect(historyLines(e, 'America/Toronto')).toEqual({ title: '보강 확정', detail: '원래 수업 : 11/10(화)', status: '11/17(화) 보강 확정' });
    expect(historyLines({ ...e, compensation: true }, 'America/Toronto').status).toContain('보상수업 확정');
  });
  it('keeps date-only records in Korea and never substitutes processing dates for missing class dates', () => {
    const e = { ...event('request', '2026-11-11T01:00:00Z', 'makeup_requested'), lesson_at: null, original_date: '2026-11-10' };
    expect(historyOriginalDay(e, 'America/Toronto')).toBe('11/10(화) (한국 날짜)');
    expect(historyOriginalDay(e, 'Asia/Seoul')).toBe('11/10(화)');
    expect(historyLines({ ...e, original_date: null }, 'Asia/Seoul')).toEqual({ title: '보강 신청', detail: '원래 수업 : 날짜 미기록', status: null });
    expect(historyLines({ ...e, kind: 'makeup_confirmed' }, 'Asia/Seoul')).toEqual({ title: '보강 확정', detail: '원래 수업 : 11/10(화)', status: '수업 일정에 반영 완료' });
  });
  it('labels compensation and tutor cancellations without exposing internal status names', () => {
    expect(historyLabel({ ...event('comp', '2026-11-11T01:00:00Z', 'makeup_confirmed'), compensation: true }).title).toBe('보상수업 확정');
    expect(historyLines({ ...event('cancel', '2026-11-11T01:00:00Z', 'lesson_canceled'), tutor_fault: true, lesson_at: '2026-11-10T01:00:00Z' }, 'Asia/Seoul')).toEqual({ title: '수업 취소', detail: '취소한 수업 : 11/10(화) · 강사 사정으로 취소', status: '취소 처리 완료' });
  });
  it('uses the same cancel reasons as the make-up right cards, without 내가', () => {
    const c = (reason: ProcessingEvent['cancel_reason']) => historyLines({ ...event('c', '2026-11-11T01:00:00Z', 'lesson_canceled'), cancel_reason: reason, lesson_at: '2026-11-09T01:00:00Z' }, 'Asia/Seoul');
    expect(c('student')).toEqual({ title: '수업 취소', detail: '취소한 수업 : 11/9(월) · 수강생 취소', status: '취소 처리 완료' });
    expect(c('tutor_canceled').detail).toBe('취소한 수업 : 11/9(월) · 강사가 취소');
    expect(c('tutor_leave').detail).toBe('취소한 수업 : 11/9(월) · 강사 휴무로 취소');
    expect(c('tutor_fault').detail).toBe('취소한 수업 : 11/9(월) · 강사 사정으로 취소');
    expect(historyLines({ ...event('c', '2026-11-11T01:00:00Z', 'lesson_canceled'), lesson_at: '2026-11-09T01:00:00Z' }, 'Asia/Seoul').detail).toBe('취소한 수업 : 11/9(월)'); // 옛 응답
  });
  it('request row status: 강사 확인 중 → (note only) 보강 일정 조율 중 → none once a later row exists; 강사 답변 hidden', () => {
    const req = { ...event('r', '2026-11-11T01:00:00Z', 'makeup_requested'), request_id: 'q1' };
    const ans = { ...event('a', '2026-11-11T02:00:00Z', 'tutor_answered'), request_id: 'q1' };
    const at = (kind: ProcessingEvent['kind'], id: string) => ({ ...event(id, '2026-11-12T01:00:00Z', kind), request_id: 'q1' });
    expect(requestStatus(req, [req])).toBe('강사 확인 중');
    expect(requestStatus(req, [req, { ...ans, request_id: 'other' }])).toBe('강사 확인 중');
    expect(requestStatus(req, [req, ans])).toBe('보강 일정 조율 중');
    for (const k of ['makeup_confirmed', 'tutor_suggested', 'suggestion_declined', 'makeup_withdrawn', 'makeup_expired', 'makeup_voided'] as const) {
      expect(requestStatus(req, [req, ans, at(k, k)])).toBeNull();
    }
    expect(requestStatus(ans, [req, ans])).toBeNull();
    expect(visibleEvents([req, ans]).map((e) => e.id)).toEqual(['r']);
    expect(historyLines({ ...req, lesson_at: '2026-11-09T01:00:00Z' }, 'Asia/Seoul', '강사 확인 중')).toEqual({ title: '보강 신청', detail: '원래 수업 : 11/9(월)', status: '강사 확인 중' });
    expect(historyLines({ ...req, lesson_at: '2026-11-09T01:00:00Z' }, 'Asia/Seoul').status).toBeNull();
  });
  it('shows requested slots on tap, marks only the confirmed one, and keeps cancel rows static', () => {
    const slot = (at: string) => ({ at, answer: null });
    const req = { ...event('r', '2026-11-08T06:08:00Z', 'makeup_requested'), request_id: 'q', slots: [slot('2026-11-14T11:00:00+00:00'), slot('2026-11-15T12:00:00+00:00')] };
    const conf = { ...event('k', '2026-11-08T11:58:00Z', 'makeup_confirmed'), request_id: 'q', booked_at: '2026-11-15T12:00:00+00:00' };
    const all = [conf, req];
    expect(historySlots(req, all).requested.map((x) => x.ok)).toEqual([false, false]);
    expect(historySlots(conf, all).requested.map((x) => x.ok)).toEqual([false, true]);
    expect(historySlots({ ...conf, booked_at: '2026-11-20T12:00:00+00:00' }, all).confirmedExtra).toBe('2026-11-20T12:00:00+00:00');
    const exp = { ...event('x', '2026-11-09T10:00:00Z', 'makeup_expired'), request_id: 'q' };
    expect(historySlots(exp, [exp, req]).requested).toHaveLength(2);
    const sug = { ...event('s', '2026-11-09T10:00:00Z', 'tutor_suggested'), request_id: 'q', slots: [slot('2026-11-16T11:00:00+00:00')] };
    expect(historySlots(sug, [sug, req])).toEqual({ requested: [], suggested: ['2026-11-16T11:00:00+00:00'], confirmedExtra: null });
    expect(historySlots(event('c', '2026-11-11T01:00:00Z', 'lesson_canceled'), all)).toEqual({ requested: [], suggested: [], confirmedExtra: null });
    expect(historyLabel(event('a', '2026-11-11T01:00:00Z', 'tutor_answered')).title).toBe('강사 답변');
    expect(historyLines(req, 'Asia/Seoul').status).toBeNull();
  });
  it('labels compensation rows by the tutor-fault class, and drops the line when no class is linked', () => {
    const c = { ...event('c', '2026-11-03T13:38:00Z', 'makeup_requested'), request_id: 'q', compensation: true, lesson_at: '2026-11-02T09:30:00Z' };
    expect(historyLines(c, 'Asia/Seoul', '강사 확인 중')).toEqual({ title: '보상수업 신청', detail: '강사 사정으로 취소된 수업 : 11/2(월)', status: '강사 확인 중' });
    expect(historyLines({ ...c, lesson_at: null, original_date: null }, 'Asia/Seoul').detail).toBeNull();
    expect(historyLines({ ...c, compensation: false }, 'Asia/Seoul').detail).toBe('원래 수업 : 11/2(월)');
  });
});
