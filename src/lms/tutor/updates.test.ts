import { describe, expect, it } from 'vitest';
import { updateLines, updateTitle, type TutorUpdate } from './updates';

const base: Omit<TutorUpdate, 'info'> = { id: 'u1', kind: 'student_late', student: 'Hajun', at: new Date('2026-11-16T12:00:00Z') };

describe('강사 Updates · 학생 지각 알림 (대표 11/13 확정 문구)', () => {
  it('이유를 고르면 Reason 줄이 들어감, 수업 시각은 현지 / KST', () => {
    const lines = updateLines({ ...base, info: { minutes: 10, reason: 'traffic' } }, 'Asia/Manila');
    expect(lines[0]).toContain('KST');
    expect(lines).toContain('The student may be approximately 10 minutes late.');
    expect(lines).toContain("Reason: I'm stuck in traffic.");
    expect(lines.at(-1)).toBe('Please join the class on time and stay until the scheduled end time, as the student may arrive earlier than expected.');
  });
  it('이유가 없으면 Reason 줄이 없고, 20분 이상은 20 or more', () => {
    const lines = updateLines({ ...base, info: { minutes: 20, reason: null } }, 'Asia/Manila');
    expect(lines.some((l) => l.startsWith('Reason'))).toBe(false);
    expect(lines).toContain('The student may be approximately 20 or more minutes late.');
  });
  it('수업 연장·남은 시간 말은 강사에게 보내지 않음', () => {
    const text = updateLines({ ...base, info: { minutes: 15, reason: 'transit' } }, 'Asia/Manila').join(' ');
    expect(text).not.toMatch(/extend|remaining/i);
  });
  it('제목', () => {
    expect(updateTitle({ ...base, info: {} }, false)).toBe('Running late');
    expect(updateTitle({ ...base, info: {} }, true)).toBe('지각 알림');
  });
});

describe('Updates 시각 = 그 시각의 지역 (이동 기간, H26(176))', () => {
  it('대체 수업 시각마다 지역 함수로 고름', () => {
    const at = new Date('2026-12-28T10:00:00Z');
    const lines = updateLines({ id: 'c', kind: 'cover', student: 'S', at, info: { times: [at.toISOString()] } }, (t) => (t >= new Date('2026-12-24T03:00:00Z') ? 'America/Argentina/Buenos_Aires' : 'Australia/Sydney'));
    expect(lines[0]).toContain('7:00 AM');
    expect(lines[0]).toContain('Buenos Aires Time');
  });
});
