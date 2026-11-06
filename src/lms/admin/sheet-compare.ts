// ⑤ 기존 Google Sheets 'Student Info' → LMS 이전 (H26(44) ⑤ B안, migration 4310)
// 시트 줄(sheet_student_info 표, Claude 가 시트를 읽어 넣음)과 LMS 학생 값을 칸마다 나란히 놓고, 대표가 체크한 칸만 반영한다.
// 자기소개는 원문 그대로, 예전 레벨은 참고 칸(level_note), 일정·회차·기간은 LMS 가 원본이라 참고로만

import type { KstDate } from '../rules/dates';
import type { StudentProfile } from './students';

export type SheetRow = {
  id: string; sheet: string; rowNo: number; status: string | null; enrolledClasses: string | null; rolloverClasses: string | null;
  studentName: string | null; preferredName: string | null; residence: string | null; selfIntro: string | null; genderAge: string | null; email: string | null;
  level: string | null; classType: string | null; correctionPref: string | null; classDuration: string | null;
  daysKst: string | null; timeKst: string | null; daysLocal: string | null; timeLocal: string | null; docsLink: string | null;
  coursePeriod: string | null; startDate: string | null; endDate: string | null; extendedEnd: string | null;
  studentId: string | null; matchedAt: Date | null; doneAt: Date | null; doneNote: string | null; importedAt: Date;
  suggest: { studentId: string; how: 'name_ko' | 'name_en' } | null;
};
/* eslint-disable @typescript-eslint/no-explicit-any -- DB JSON → 화면 모양 */
export function parseSheetRows(j: any): SheetRow[] {
  return ((j ?? []) as any[]).map((r) => ({
    id: r.id, sheet: r.sheet, rowNo: r.row_no, status: r.status ?? null, enrolledClasses: r.enrolled_classes ?? null, rolloverClasses: r.rollover_classes ?? null,
    studentName: r.student_name ?? null, preferredName: r.preferred_name ?? null, residence: r.residence ?? null, selfIntro: r.self_intro ?? null,
    genderAge: r.gender_age ?? null, email: r.email ?? null, level: r.level ?? null, classType: r.class_type ?? null, correctionPref: r.correction_pref ?? null,
    classDuration: r.class_duration ?? null, daysKst: r.days_kst ?? null, timeKst: r.time_kst ?? null, daysLocal: r.days_local ?? null, timeLocal: r.time_local ?? null,
    docsLink: r.docs_link ?? null, coursePeriod: r.course_period ?? null, startDate: r.start_date ?? null, endDate: r.end_date ?? null, extendedEnd: r.extended_end ?? null,
    studentId: r.student_id ?? null, matchedAt: r.matched_at ? new Date(r.matched_at) : null, doneAt: r.done_at ? new Date(r.done_at) : null, doneNote: r.done_note ?? null,
    importedAt: new Date(r.imported_at), suggest: r.suggest ? { studentId: r.suggest.student_id, how: r.suggest.how } : null,
  }));
}
/* eslint-enable @typescript-eslint/no-explicit-any */

/** 'Melbourne, Australia' → 도시 Melbourne · 국가 Australia / 'Korea' → 국가만 */
export function splitResidence(v: string): { country: string | null; city: string | null } {
  const t = v.trim();
  if (!t) return { country: null, city: null };
  const parts = t.split(',').map((x) => x.trim()).filter(Boolean);
  if (parts.length >= 2) return { city: parts[0], country: parts.slice(1).join(', ') };
  return { country: t, city: null };
}

export type CompareItem = {
  /** LMS 칸 (residence 는 country+city 묶음) */
  field: 'display_name' | 'residence' | 'self_intro_en' | 'gender_age' | 'email' | 'level_note' | 'class_type' | 'correction_pref' | 'class_note_url';
  title: string; sheet: string; lms: string; same: boolean;
  /** 넣을 수 있는 값인지 (Google docs link 가 주소가 아니면 못 넣음) */
  importable: boolean; note?: string;
};
const norm = (v: string | null | undefined) => (v ?? '').replace(/\s+/g, ' ').trim();

/** 시트 줄 ↔ LMS 학생: 반영할 수 있는 칸만. LMS 값이 비어 있으면 기본 체크(덮어쓰기 아님), 값이 있으면 운영진이 직접 골라야 함 */
export function compareRow(r: SheetRow, s: StudentProfile): CompareItem[] {
  const lmsRes = [s.city, s.country].filter(Boolean).join(', ');
  const docsIsUrl = /^https?:\/\//.test(norm(r.docsLink));
  const raw: Omit<CompareItem, 'same' | 'importable'>[] = [
    { field: 'display_name', title: 'Preferred Name', sheet: norm(r.preferredName), lms: norm(s.displayName) },
    { field: 'residence', title: '거주지 (도시, 국가)', sheet: norm(r.residence), lms: lmsRes, note: '시간대는 따로 확인해 주세요 (자동으로 바꾸지 않아요)' },
    { field: 'gender_age', title: '성별 / 연령대', sheet: norm(r.genderAge), lms: norm(s.genderAge) },
    { field: 'email', title: '이메일', sheet: norm(r.email), lms: norm(s.email) },
    { field: 'level_note', title: '예전 레벨 표기 (참고 칸, 4단계로 바꾸지 않음)', sheet: norm(r.level), lms: norm(s.levelNote) },
    { field: 'class_type', title: 'Type of class', sheet: norm(r.classType), lms: norm(s.classType) },
    { field: 'correction_pref', title: '교정 선호 (시트 글, 참고)', sheet: norm(r.correctionPref), lms: norm(s.correctionPref) },
    { field: 'self_intro_en', title: '자기소개 (원문 그대로, 7개로 나누지 않음)', sheet: (r.selfIntro ?? '').trim(), lms: (s.selfIntroEn ?? '').trim() },
    { field: 'class_note_url', title: 'Google Docs 링크', sheet: norm(r.docsLink), lms: norm(s.classNoteUrl), note: docsIsUrl ? undefined : '시트 값이 문서 이름이라(주소 아님) 넣을 수 없어요' },
  ];
  return raw
    .filter((x) => x.sheet !== '')
    .map((x) => ({ ...x, same: norm(x.sheet) === norm(x.lms), importable: x.field === 'class_note_url' ? docsIsUrl : true }));
}

/** 기본 체크: 다르고, 넣을 수 있고, LMS 가 비어 있는 칸 */
export const defaultPick = (it: CompareItem) => !it.same && it.importable && it.lms === '';

/** 체크한 칸 → admin_student_update 에 줄 값 */
export function fieldsFromChosen(items: CompareItem[]): Record<string, string | null> {
  const out: Record<string, string | null> = {};
  for (const it of items) {
    if (it.field === 'residence') {
      const r = splitResidence(it.sheet);
      out.country = r.country;
      out.city = r.city;
    } else out[it.field] = it.sheet;
  }
  return out;
}

/** 참고(LMS 가 원본이라 넣지 않는 것): 시트의 일정·회차·기간 */
export function referenceLines(r: SheetRow): [string, string][] {
  return ([
    ['Enrollment', r.status], ['Enrolled / Rollover', [r.enrolledClasses, r.rolloverClasses].filter(Boolean).join(' / ')], ['Duration', r.classDuration],
    ['Days · Time (KST)', [r.daysKst, r.timeKst].filter(Boolean).join(' ')], ['Days · Time (강사 현지, 시트 고정값)', [r.daysLocal, r.timeLocal].filter(Boolean).join(' ')],
    ['Period / Start / End / Extended', [r.coursePeriod, r.startDate, r.endDate, r.extendedEnd].filter(Boolean).join(' · ')],
  ] as [string, string | null][]).filter((x): x is [string, string] => !!x[1]);
}

export type SheetFilter = 'todo' | 'done' | 'all';
export function filterRows(rows: SheetRow[], f: SheetFilter, q: string, studentId?: string | null): SheetRow[] {
  const key = q.trim().toLowerCase().replace(/\s+/g, '');
  return rows.filter((r) => {
    if (studentId && r.studentId !== studentId && r.suggest?.studentId !== studentId) return false;
    if (f === 'todo' && r.doneAt) return false;
    if (f === 'done' && !r.doneAt) return false;
    if (!key) return true;
    return [r.studentName, r.preferredName, r.email, r.sheet].filter(Boolean).join(' ').toLowerCase().replace(/\s+/g, '').includes(key);
  });
}
export const kstDay = (d: Date): KstDate => new Date(d.getTime() + 9 * 3600_000).toISOString().slice(0, 10);
