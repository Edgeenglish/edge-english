import { describe, expect, it } from 'vitest';
import { compareRow, defaultPick, fieldsFromChosen, filterRows, splitResidence, type SheetRow } from './sheet-compare';
import type { StudentProfile } from './students';

const row = (x: Partial<SheetRow>): SheetRow => ({
  id: 'r1', sheet: 'Benny_Class record', rowNo: 2, status: 'Active', enrolledClasses: '8', rolloverClasses: null, studentName: '김서연', preferredName: 'Sarah',
  residence: 'Melbourne, Australia', selfIntro: '✅Job: Nurse\n✅Hobbies: Running', genderAge: 'F / 30s', email: 'sy@example.com', level: 'A2/B1', classType: 'free convo',
  correctionPref: 'active immediate corrections', classDuration: '40', daysKst: '화, 목', timeKst: '9am-9:40am', daysLocal: '화, 목', timeLocal: '11:00-11:40',
  docsLink: '김서연_Benny', coursePeriod: '4 weeks', startDate: '2026-03-16', endDate: '2026-04-12', extendedEnd: null,
  studentId: null, matchedAt: null, doneAt: null, doneNote: null, importedAt: new Date(), suggest: null, ...x,
});
const stu = (x: Partial<StudentProfile>): StudentProfile => ({
  id: 's1', code: 'STU-0001', nameKo: '김서연', nameEn: 'Kim Seoyeon', displayName: null, label: 'Kim Seoyeon', country: null, city: null, timezone: 'Asia/Seoul', genderAge: null,
  email: null, phone: null, adminMemo: null, level: null, levelNote: null, levelAt: null, levelBy: null, classType: null, textbook: null, classNoteUrl: null,
  correctionPref: null, selfIntroEn: null, job: null, hobbies: null, interests: null, improve: null, hopes: null, correctionStyle: null, correctionNote: null,
  classStyle: null, classStyleNote: null, tutorClassStyle: null, tutorClassStyleMix: [], tutorMaterialsNote: null, tutorClassStyleAt: null, tutorClassStyleBy: null, improveTutorAt: null, answersAt: null, lmsSince: null, ...x,
});

describe('⑤ 시트 Student Info ↔ LMS 비교', () => {
  it('거주지 나누기', () => {
    expect(splitResidence('Melbourne, Australia')).toEqual({ city: 'Melbourne', country: 'Australia' });
    expect(splitResidence('Korea')).toEqual({ country: 'Korea', city: null });
    expect(splitResidence('Korea (Australia in 3 months)')).toEqual({ country: 'Korea (Australia in 3 months)', city: null });
  });
  it('LMS 가 비어 있으면 기본 체크, 값이 있으면 체크 안 함, 같으면 같음, 문서 이름 링크는 못 넣음', () => {
    const items = compareRow(row({}), stu({ email: 'sy@example.com', genderAge: 'M / 20s' }));
    const by = Object.fromEntries(items.map((i) => [i.field, i]));
    expect(by.email.same).toBe(true);
    expect(defaultPick(by.email)).toBe(false);
    expect(by.gender_age.same).toBe(false);
    expect(defaultPick(by.gender_age)).toBe(false);          // LMS 에 값이 있어 덮어쓰지 않음 (운영진이 직접 골라야)
    expect(defaultPick(by.display_name)).toBe(true);
    expect(defaultPick(by.residence)).toBe(true);
    expect(by.level_note.sheet).toBe('A2/B1');                // 4단계로 바꾸지 않고 참고 칸
    expect(by.class_note_url.importable).toBe(false);
    expect(by.self_intro_en.sheet).toContain('✅Hobbies: Running');   // 원문 그대로
  });
  it('체크한 칸 → 저장 값 (거주지는 도시·국가로)', () => {
    const items = compareRow(row({}), stu({}));
    const chosen = items.filter((i) => ['display_name', 'residence', 'level_note'].includes(i.field));
    expect(fieldsFromChosen(chosen)).toEqual({ display_name: 'Sarah', city: 'Melbourne', country: 'Australia', level_note: 'A2/B1' });
  });
  it('시트에 비어 있는 칸은 비교 목록에 없음', () => {
    const items = compareRow(row({ preferredName: null, email: '' }), stu({}));
    expect(items.map((i) => i.field)).not.toContain('display_name');
    expect(items.map((i) => i.field)).not.toContain('email');
  });
  it('걸러 보기: 할 일 / 끝남 / 수강생별', () => {
    const rows = [row({ id: 'a' }), row({ id: 'b', doneAt: new Date(), studentId: 's1' }), row({ id: 'c', studentName: '박민준', suggest: { studentId: 's9', how: 'name_ko' } })];
    expect(filterRows(rows, 'todo', '').map((r) => r.id)).toEqual(['a', 'c']);
    expect(filterRows(rows, 'done', '').map((r) => r.id)).toEqual(['b']);
    expect(filterRows(rows, 'all', '민준').map((r) => r.id)).toEqual(['c']);
    expect(filterRows(rows, 'all', '', 's9').map((r) => r.id)).toEqual(['c']);
  });
});
