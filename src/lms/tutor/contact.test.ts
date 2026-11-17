import { describe, expect, it } from 'vitest';
import { contactGist, contactStageOpen, type ContactSent } from './contact';

// 50분 수업 10:00~10:50 UTC
const lesson = { state: 'scheduled' as const, startsAt: new Date('2026-11-16T10:00:00Z'), endsAt: new Date('2026-11-16T10:50:00Z') };
const at = (hm: string) => new Date(`2026-11-16T${hm}:00Z`);
const s1: ContactSent = { stage: 1, at: at('10:06'), byAdmin: false };
const s2: ContactSent = { stage: 2, at: at('10:26'), byAdmin: false };

describe('강사 [학생에게 연락하기] 버튼 시간 창 (대표 11/16)', () => {
  it('1차: 시작 5분 뒤부터 끝나기 전까지', () => {
    expect(contactStageOpen(lesson, [], at('10:04'))).toBeNull();
    expect(contactStageOpen(lesson, [], at('10:05'))).toBe(1);
    expect(contactStageOpen(lesson, [], at('10:49'))).toBe(1);
    expect(contactStageOpen(lesson, [], at('10:50'))).toBeNull();
  });
  it('2차: 1차를 보냈고 수업 절반 뒤부터 끝나기 전까지', () => {
    expect(contactStageOpen(lesson, [s1], at('10:24'))).toBeNull();
    expect(contactStageOpen(lesson, [s1], at('10:25'))).toBe(2);
    expect(contactStageOpen(lesson, [s1], at('10:50'))).toBeNull();
    expect(contactStageOpen(lesson, [s1, s2], at('10:30'))).toBeNull();
  });
  it('1차를 안 보냈으면 절반 뒤에도 1차', () => {
    expect(contactStageOpen(lesson, [], at('10:30'))).toBe(1);
  });
  it('예정 수업이 아니거나 휴무 처리 중·다른 강사 대체면 없음', () => {
    expect(contactStageOpen({ ...lesson, state: 'done' as never }, [], at('10:10'))).toBeNull();
    expect(contactStageOpen({ ...lesson, leaveOpen: true }, [], at('10:10'))).toBeNull();
    expect(contactStageOpen({ ...lesson, coveredByOther: true }, [], at('10:10'))).toBeNull();
  });
  it('강사 화면 요약에 강사 이름', () => {
    expect(contactGist(1, 'Emma')).toContain('Emma is waiting for you');
    expect(contactGist(2, 'Emma')).toContain('You can still join the class. Emma is waiting until the class ends.');
  });
});
