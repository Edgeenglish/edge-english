import { describe, expect, it } from 'vitest';
import { initialStyleFromWish, needsMaterials, needsTextbook, OTHER_TEXTBOOK, parseFollowup, parseFollowupTodos, styleText, TEXTBOOKS } from './followup';

describe('첫 수업 후 To-do (4600)', () => {
  it('교재 목록은 홈페이지 교재 데이터 그대로', () => {
    expect(TEXTBOOKS.length).toBeGreaterThan(10);
    expect(TEXTBOOKS).toContain('Speak now 2');
    expect(TEXTBOOKS).not.toContain(OTHER_TEXTBOOK);
  });
  it('교재·수강생 자료 칸은 방식에 따라 조건부', () => {
    expect(needsTextbook('textbook', [])).toBe(true);
    expect(needsTextbook('mixed', ['conversation'])).toBe(false);
    expect(needsTextbook('mixed', ['conversation', 'textbook'])).toBe(true);
    expect(needsTextbook('conversation', [])).toBe(false);
    expect(needsMaterials('student_materials', [])).toBe(true);
    expect(needsMaterials('mixed', ['student_materials'])).toBe(true);
    expect(needsMaterials('textbook', [])).toBe(false);
  });
  it('수강생 희망 → 처음 값', () => {
    expect(initialStyleFromWish('textbook')).toBe('textbook');
    expect(initialStyleFromWish('free_talking')).toBe('conversation');
    expect(initialStyleFromWish('not_sure')).toBe('');
    expect(initialStyleFromWish(null)).toBe('');
  });
  it('실제 방식 글', () => {
    expect(styleText({ tutorClassStyle: null, tutorClassStyleMix: [], textbook: 'Speak now 2', tutorMaterialsNote: null })).toBeNull();
    expect(styleText({ tutorClassStyle: 'textbook', tutorClassStyleMix: [], textbook: 'Speak now 2', tutorMaterialsNote: null })).toBe('Textbook-based (Speak now 2)');
    expect(styleText({ tutorClassStyle: 'mixed', tutorClassStyleMix: ['conversation', 'textbook', 'student_materials'], textbook: 'Speak now 2', tutorMaterialsNote: 'work emails' }))
      .toBe('Mixed: Conversation + Textbook (Speak now 2) + Student Materials (work emails)');
    expect(styleText({ tutorClassStyle: 'mixed', tutorClassStyleMix: ['conversation', 'other'], textbook: null, tutorMaterialsNote: null }, 'ko')).toBe('혼합: 회화 + 기타');
  });
  it('DB JSON 읽기', () => {
    expect(parseFollowup(null)).toBeNull();
    expect(parseFollowup({ first_lesson: null })).toBeNull();
    const f = parseFollowup({ first_lesson: { id: 'l1', starts_at: '2026-11-04T00:30:00Z', status: 'Normal', topics: 'Intro', recorded_at: '2026-11-04T01:20:00Z' }, done: { level: true, improve: false, style: false, record: true }, pending: 2 });
    expect(f?.pending).toBe(2);
    expect(f?.done).toEqual({ level: true, improve: false, style: false, record: true });
    expect(f?.firstLesson?.topics).toBe('Intro');
    const todos = parseFollowupTodos([{ student_id: 's1', student: 'Haeun Jang', first_lesson_at: '2026-11-04T00:30:00Z', pending: 3, done: { level: false } }]);
    expect(todos[0]).toMatchObject({ studentId: 's1', student: 'Haeun Jang', pending: 3 });
    expect(todos[0].done.record).toBe(false);
  });
});
