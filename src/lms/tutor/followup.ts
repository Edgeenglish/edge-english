// 첫 수업 후 강사 To-do (First Lesson Follow-up, migration 4600, H26(67)·(68)·(71))
// 완료 판정은 DB(lms_first_lesson_todo)가 저장된 값으로 함 — 화면은 받은 상태를 그대로 보여 주고, 저장하면 DB 가 준 새 상태로 바꿈
import books from '../../data/books.json';

export type FollowupDone = { level: boolean; improve: boolean; style: boolean; record: boolean };
export type Followup = {
  firstLesson: { id: string; startsAt: Date; status: string | null; topics: string | null; recordedAt: Date | null } | null;
  done: FollowupDone;
  pending: number;
};
export type FollowupTodo = { studentId: string; student: string; firstLessonAt: Date | null; pending: number; done: FollowupDone };

/* eslint-disable @typescript-eslint/no-explicit-any -- DB JSON → 화면 모양 */
const doneOf = (d: any): FollowupDone => ({ level: !!d?.level, improve: !!d?.improve, style: !!d?.style, record: !!d?.record });
export function parseFollowup(j: any): Followup | null {
  if (!j || !j.first_lesson) return null;
  const f = j.first_lesson;
  return {
    firstLesson: { id: f.id, startsAt: new Date(f.starts_at), status: f.status ?? null, topics: f.topics ?? null, recordedAt: f.recorded_at ? new Date(f.recorded_at) : null },
    done: doneOf(j.done),
    pending: Number(j.pending ?? 0),
  };
}
export function parseFollowupTodos(j: any): FollowupTodo[] {
  return ((j ?? []) as any[]).map((x) => ({
    studentId: x.student_id, student: x.student, firstLessonAt: x.first_lesson_at ? new Date(x.first_lesson_at) : null, pending: Number(x.pending ?? 0), done: doneOf(x.done),
  }));
}
/* eslint-enable @typescript-eslint/no-explicit-any */

/** 실제 수업 방식 (강사 확인). 수강생의 희망(class_style: textbook·free_talking·not_sure)과는 다른 칸 */
export const CLASS_STYLES = ['conversation', 'textbook', 'student_materials', 'mixed'] as const;
export type TutorClassStyle = (typeof CLASS_STYLES)[number];
export const MIX_OPTIONS = ['conversation', 'textbook', 'student_materials', 'other'] as const;
export type MixOption = (typeof MIX_OPTIONS)[number];
export const CLASS_STYLE_TEXT: Record<TutorClassStyle, { en: string; ko: string }> = {
  conversation: { en: 'Conversation', ko: '회화' },
  textbook: { en: 'Textbook-based', ko: '교재 중심' },
  student_materials: { en: 'Student-provided Materials', ko: '수강생 제공 자료' },
  mixed: { en: 'Mixed', ko: '혼합' },
};
export const MIX_TEXT: Record<MixOption, { en: string; ko: string }> = {
  conversation: { en: 'Conversation', ko: '회화' },
  textbook: { en: 'Textbook', ko: '교재' },
  student_materials: { en: 'Student Materials', ko: '수강생 자료' },
  other: { en: 'Other', ko: '기타' },
};
/** 홈페이지 교재 페이지(src/data/books.json)의 실제 교재 목록 그대로 — 임의 목록 금지 */
export const TEXTBOOKS: readonly string[] = (books as { title: string }[]).map((b) => b.title);
export const OTHER_TEXTBOOK = '__other__';

export const needsTextbook = (style: TutorClassStyle | '', mix: readonly string[]) => style === 'textbook' || (style === 'mixed' && mix.includes('textbook'));
export const needsMaterials = (style: TutorClassStyle | '', mix: readonly string[]) => style === 'student_materials' || (style === 'mixed' && mix.includes('student_materials'));

/** 수강생 희망(class_style)을 실제 방식의 처음 값으로: 교재 → Textbook-based, 프리토킹 → Conversation, 모름 → 비움 */
export function initialStyleFromWish(wish: string | null): TutorClassStyle | '' {
  return wish === 'textbook' ? 'textbook' : wish === 'free_talking' ? 'conversation' : '';
}

/** 'Mixed: Conversation + Textbook (Speak now 2) + Student Materials (work emails)' */
export function styleText(p: { tutorClassStyle: string | null; tutorClassStyleMix: string[]; textbook: string | null; tutorMaterialsNote: string | null }, lang: 'en' | 'ko' = 'en'): string | null {
  const st = p.tutorClassStyle as TutorClassStyle | null;
  if (!st) return null;
  const book = p.textbook ? ` (${p.textbook})` : '';
  const mat = p.tutorMaterialsNote ? ` (${p.tutorMaterialsNote})` : '';
  if (st === 'textbook') return `${CLASS_STYLE_TEXT.textbook[lang]}${book}`;
  if (st === 'student_materials') return `${CLASS_STYLE_TEXT.student_materials[lang]}${mat}`;
  if (st === 'conversation') return CLASS_STYLE_TEXT.conversation[lang];
  const parts = (p.tutorClassStyleMix as MixOption[]).filter((m) => MIX_TEXT[m]).map((m) => `${MIX_TEXT[m][lang]}${m === 'textbook' ? book : m === 'student_materials' ? mat : ''}`);
  return `${CLASS_STYLE_TEXT.mixed[lang]}: ${parts.join(' + ')}`;
}
