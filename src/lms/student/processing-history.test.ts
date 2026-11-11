import { describe, expect, it } from 'vitest';
import { historyLabel, historyTime, processingEvents, type ProcessingEvent } from './processing-history';

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
  it('does not invent processing times and preserves the database tie order', () => {
    const at = '2026-11-11T01:00:00Z';
    expect(processingEvents([event('waiting', at, 'tutor_waiting'), event('request', at, 'makeup_requested'), event('missing', '', 'makeup_confirmed')]).map((e) => e.id)).toEqual(['waiting', 'request']);
  });
  it('does not describe historical waiting as the current state', () => {
    expect(historyLabel(event('waiting', '2026-11-11T01:00:00Z', 'tutor_waiting')).result).toBe('강사님께 확인 요청됨');
  });
  it('uses student timezone across a date boundary and DST', () => {
    expect(historyTime('2026-11-11T16:00:00Z', 'Asia/Seoul')).toContain('2026. 11. 12.');
    expect(historyTime('2026-11-11T16:00:00Z', 'America/Toronto')).toContain('오전 11:00');
    expect(historyTime('2026-07-11T16:00:00Z', 'America/Toronto')).toContain('오후 12:00');
  });
  it('labels compensation and tutor cancellations without exposing internal status names', () => {
    expect(historyLabel({ ...event('comp', '2026-11-11T01:00:00Z', 'makeup_confirmed'), compensation: true }).title).toBe('보상수업 확정');
    expect(historyLabel({ ...event('cancel', '2026-11-11T01:00:00Z', 'lesson_canceled'), tutor_fault: true }).result).toBe('강사 사정으로 취소 처리 완료');
  });
});
