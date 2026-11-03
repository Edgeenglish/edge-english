import { describe, expect, it } from 'vitest';
import { finalEndText, koZone, kstWithZones, matchStudent, nextDateOf, regularNoticeEn, regularNoticeKo, slotsInZone, slotsText, type StudentRow } from './students';

describe('학생 관리 시간 표기 (H26(43): 기준 시간대 이름을 항상 함께)', () => {
  it('시간대 이름', () => {
    expect(koZone('Asia/Seoul')).toBe('한국 시간');
    expect(koZone('America/Toronto')).toBe('Toronto 시간');
    expect(koZone('Asia/Ho_Chi_Minh')).toBe('Ho Chi Minh 시간');
  });
  it('한국 시간 + 학생·강사 도시 시간, 한국 시간대는 한 번만', () => {
    const at = new Date('2026-11-05T13:00:00Z'); // 한국 22:00 목
    expect(kstWithZones(at, [{ label: '학생', tz: 'America/Toronto' }, { label: '강사 Maria', tz: 'Asia/Ho_Chi_Minh' }]))
      .toBe('11/5(목) 22:00 (한국 시간) · 학생 Toronto 11/5(목) 08:00 · 강사 Maria Ho Chi Minh 11/5(목) 20:00');
    expect(kstWithZones(at, [{ label: '학생', tz: 'Asia/Seoul' }])).toBe('11/5(목) 22:00 (한국 시간)');
  });
  it('최종 종료 23:59 한국 시간 = 해외 학생 현지', () => {
    expect(finalEndText('2027-01-26', 'Asia/Seoul')).toBe('1/26(화) 23:59 (한국 시간)');
    expect(finalEndText('2027-01-26', 'America/Toronto')).toBe('1/26(화) 23:59 (한국 시간) = 1/26(화) 09:59 (Toronto 시간)');
  });
  it('정규 일정을 다른 시간대로 — 서머타임은 실제 다음 수업 날짜로', () => {
    const slots = [{ weekday: 2, time: '22:00' }, { weekday: 4, time: '22:00' }];
    expect(slotsText(slots)).toBe('화·목 22:00');
    // 10/26(월) 기준: 토론토 서머타임 끝(11/1) 전 → 09:00, 11/2 기준 → 08:00
    expect(slotsInZone(slots, 'America/Toronto', '2026-10-26')).toBe('화·목 09:00');
    expect(slotsInZone(slots, 'America/Toronto', '2026-11-02')).toBe('화·목 08:00');
    // 시드니(한국 +2, 여름) 22:00 → 다음 날 00:00 → 현지 요일 수·금
    expect(slotsInZone(slots, 'Australia/Sydney', '2026-11-02')).toBe('수·금 00:00');
    expect(slotsInZone(slots, 'Asia/Seoul', '2026-11-02', 'en')).toBe('Tue/Thu 10:00 PM');
    expect(nextDateOf(2, '2026-11-02')).toBe('2026-11-03');
    expect(nextDateOf(1, '2026-11-02')).toBe('2026-11-02');
  });
});

describe('③ 정규 일정 변경 안내 문구', () => {
  const ctx = {
    studentNameKo: '김서연', studentNameEn: 'Kim Seoyeon', studentTz: 'America/Toronto', tutorName: 'Maria', tutorTz: 'Asia/Ho_Chi_Minh', durationMin: 40,
    effectiveFrom: '2026-11-05', newSlots: [{ weekday: 2, time: '22:30' }, { weekday: 4, time: '22:30' }],
    moved: [{ lessonId: 'a', seq: 3, from: new Date('2026-11-05T13:00:00Z'), fromEnd: new Date('2026-11-05T13:40:00Z'), to: new Date('2026-11-05T13:30:00Z'), toEnd: new Date('2026-11-05T14:10:00Z'), problem: null }],
  };
  it('학생 카카오톡: 학생 도시 시간 + 한국 시간', () => {
    const ko = regularNoticeKo(ctx);
    expect(ko).toContain('[엣지영어] 김서연님, 정규 수업 시간이 11/5(목)부터 바뀌어요.');
    expect(ko).toContain('화·목 08:30 (Toronto 시간) · 한국 시간 화·목 22:30 · 40분 · Maria 강사님');
    expect(ko).toContain('- 11/5(목) 08:30 (Toronto 시간) · 한국 11/5(목) 22:30');
  });
  it('국내 학생: 한국 시간만', () => {
    const ko = regularNoticeKo({ ...ctx, studentTz: 'Asia/Seoul' });
    expect(ko).toContain('새 정규 수업: 화·목 22:30 (한국 시간) · 40분');
    expect(ko).toContain('- 11/5(목) 22:30');
    expect(ko).not.toContain('Toronto');
  });
  it('강사 WhatsApp: 강사 도시 시간 + KST, 영문 이름', () => {
    const en = regularNoticeEn(ctx);
    expect(en).toContain('SCHEDULE CHANGE - Kim Seoyeon (40 min), from Thu Nov 5');
    expect(en).toContain('New regular time: Tue/Thu 8:30 PM Ho Chi Minh Time (Tue/Thu 10:30 PM KST)');
    expect(en).toContain('- Thu, Nov 5, 8:30 PM Ho Chi Minh Time (Thu, Nov 5, 10:30 PM KST)');
  });
});

describe('학생 목록 검색', () => {
  const row = { nameKo: '김서연', nameEn: 'Kim Seoyeon', displayName: 'Sarah', code: 'STU-0013', email: 'sy@example.com', tutor: 'Maria' } as StudentRow;
  it('이름·영문·Preferred·번호·이메일·강사, 띄어쓰기·대소문자 무시', () => {
    expect(matchStudent(row, '서연')).toBe(true);
    expect(matchStudent(row, 'kimseo')).toBe(true);
    expect(matchStudent(row, 'sarah')).toBe(true);
    expect(matchStudent(row, '0013')).toBe(true);
    expect(matchStudent(row, 'maria')).toBe(true);
    expect(matchStudent(row, '박')).toBe(false);
    expect(matchStudent(row, '')).toBe(true);
  });
});
