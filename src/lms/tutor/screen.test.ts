import { describe, expect, it } from 'vitest';
import { CLASS_STATUSES } from '../rules/status';
import { lateText, NO_LATE, answerReady, canRecord, daysOf, kindTag, kstText, parseScreen, phaseOf, recordReady, resultOf, savedStatus, statusText, timeRange, TUTOR_STATUS_TEXT, weekOf, type TutorLesson } from './screen';

const base: TutorLesson = {
  id: 'a', startsAt: new Date('2026-11-02T08:00:00Z'), endsAt: new Date('2026-11-02T08:40:00Z'), kind: 'regular', state: 'scheduled', classStatus: null,
  student: 'S', level: null, noteUrl: null, covering: false, makeupOf: null, count: null, topics: null, remarks: null, studentLate: false, late: NO_LATE, recordedAt: null, locked: false,
};

describe('강사 화면 (migration 2000)', () => {
  it('강사 현지 기준 월~일 한 주, DB는 한국 날짜로 하루씩 넓혀 읽음', () => {
    // 시드니 11/2(월) 오전 = 한국 11/2(월) 오전 이전
    const w = weekOf(new Date('2026-11-04T01:00:00Z'), 'Australia/Sydney', 0);
    expect(w).toEqual({ from: '2026-11-02', to: '2026-11-08', kstFrom: '2026-11-01', kstTo: '2026-11-09' });
    expect(weekOf(new Date('2026-11-04T01:00:00Z'), 'Australia/Sydney', -1).from).toBe('2026-10-26');
  });
  it('시간은 강사 현지, 한국 시각은 옆에 (날짜가 다르면 요일까지)', () => {
    const l = { ...base, startsAt: new Date('2026-11-02T12:00:00Z'), endsAt: new Date('2026-11-02T12:40:00Z') };
    expect(timeRange(l, 'Australia/Sydney')).toBe('11:00–11:40 PM');
    expect(kstText(l.startsAt, 'Australia/Sydney')).toBe('9:00 PM *KST*');
    expect(kstText(new Date('2026-11-02T14:00:00Z'), 'Australia/Sydney')).toBe('Mon, 2 Nov 11:00 PM *KST*');
    expect(kstText(l.startsAt, 'Asia/Seoul')).toBeNull();
  });
  it('날짜별 묶음은 강사 현지 날짜, 그 주 밖은 뺌', () => {
    const a = { ...base, id: 'a', startsAt: new Date('2026-11-01T14:30:00Z') }; // 시드니 11/2 01:30
    const b = { ...base, id: 'b', startsAt: new Date('2026-11-09T00:00:00Z') }; // 시드니 11/9 → 다음 주
    expect(daysOf([b, a], 'Australia/Sydney', { from: '2026-11-02', to: '2026-11-08' })).toEqual([{ date: '2026-11-02', lessons: [a] }]);
  });
  it('수업 단계: 예정 → 시작하면 기록할 수업 → 기록됨, 취소는 취소', () => {
    const now = new Date('2026-11-02T08:10:00Z');
    expect(phaseOf({ ...base, startsAt: new Date('2026-11-02T09:00:00Z') }, now)).toBe('upcoming');
    expect(phaseOf(base, now)).toBe('to_record');
    expect(statusText(base, now)).toBe('Not recorded');
    expect(phaseOf({ ...base, state: 'done', classStatus: 'Normal' }, now)).toBe('recorded');
    expect(statusText({ ...base, state: 'canceled', classStatus: 'Student canceled in advance' }, now)).toBe('Student canceled in advance');
    expect(canRecord({ ...base, state: 'canceled', classStatus: 'Tutor long-term leave' }, now)).toBe(false);
    expect(canRecord({ ...base, locked: true, state: 'done', classStatus: 'Normal' }, now)).toBe(false);
    expect(canRecord({ ...base, startsAt: new Date('2026-11-02T09:00:00Z') }, now)).toBe(false);
    // 서버가 '기록할 수업'으로 준 수업은 강사 기기 시계가 늦어도 기록 가능 (11/9 Maria)
    expect(canRecord({ ...base, startsAt: new Date('2026-11-02T09:00:00Z') }, now, true)).toBe(true);
    // 강사 계정 만들기 전 수업은 'Not recorded'가 아님 (R7)
    expect(statusText({ ...base, beforeLms: true }, now)).toBe('Before LMS');
    // 수업 종류 = 강사 시트 Class Type (H26(138)): 대체가 먼저
    expect(kindTag({ ...base, kind: 'migrated_makeup', covering: true })).toBe('Cover class');
    expect(kindTag({ ...base, kind: 'makeup' })).toBe('Makeup');
    expect(kindTag(base)).toBe('Regular');
    expect(kindTag({ ...base, type: 'carry_in' })).toBe('Carryover from previous period');
    // 원래 강사 화면의 대체된 수업: 회색 'Covered by another tutor', 기록 못 함
    expect(phaseOf({ ...base, coveredByOther: true }, now)).toBe('covered');
    expect(statusText({ ...base, coveredByOther: true }, now)).toBe('Covered by another tutor');
    expect(canRecord({ ...base, coveredByOther: true }, now, true)).toBe(false);
  });
  it('14개 상태 모두 강사 문구가 있음', () => {
    for (const s of CLASS_STATUSES) expect(TUTOR_STATUS_TEXT[s]).toBeTruthy();
  });
  it('결과 이름은 DB와 같은 규칙: 보강은 Make-up completed, 대체 진행은 Normal (H26(138))', () => {
    expect(savedStatus(base, 'held')).toBe('Normal');
    expect(savedStatus({ ...base, kind: 'migrated_makeup' }, 'held')).toBe('Make-up completed');
    expect(savedStatus({ ...base, covering: true }, 'held')).toBe('Normal');
    expect(savedStatus({ ...base, kind: 'migrated_makeup', covering: true }, 'held')).toBe('Normal');
    expect(savedStatus({ ...base, kind: 'makeup' }, 'held', true)).toBe('Tutor Late - Student Present');
    expect(resultOf('Tutor Late - Student Present')).toBe('held');
    expect(lateText({ student: true, studentMin: 10, tutor: true, tutorMin: null })).toBe(' · Student late 10 min · Tutor late');
    expect(lateText(NO_LATE)).toBe('');
    expect(resultOf('Covered by another tutor')).toBe('held');
    expect(resultOf('Student no-show')).toBe('student_no_show');
    expect(resultOf('Student canceled in advance')).toBeNull();
  });
  it('저장 가능: 진행은 다룬 내용, 지각은 사유까지, 수강생 노쇼는 바로', () => {
    expect(recordReady(null, 'x', '')).toBe(false);
    expect(recordReady('held', ' ', '')).toBe(false);
    expect(recordReady('held', 'Travel', '')).toBe(true);
    expect(recordReady('held', 'Travel', '', { ...NO_LATE, tutor: true, tutorMin: 5 })).toBe(false);
    expect(recordReady('held', 'Travel', 'Internet down', { ...NO_LATE, tutor: true, tutorMin: 5 })).toBe(true);
    expect(recordReady('held', 'Travel', 'Internet down', { ...NO_LATE, tutor: true, tutorMin: null })).toBe(false);
    expect(recordReady('held', 'Travel', '', { ...NO_LATE, student: true, studentMin: null })).toBe(false);
    expect(recordReady('held', 'Travel', '', { ...NO_LATE, student: true, studentMin: 15 })).toBe(true);
    expect(recordReady('student_no_show', '', '')).toBe(true);
  });
  it('보강 답: 가능 시간 하나 이상, 모두 안 되면 메모', () => {
    expect(answerReady(new Set(), '  ')).toBe(false);
    expect(answerReady(new Set(), 'Fri 7pm')).toBe(true);
    expect(answerReady(new Set(['s1']), '')).toBe(true);
  });
  it('DB 함수 결과를 화면 모양으로', () => {
    const s = parseScreen({
      tutor: { id: 't', name: 'Emma', timezone: 'Asia/Seoul', meet_url: null },
      lessons: [{ id: 'a', starts_at: '2026-11-02T08:00:00Z', ends_at: '2026-11-02T08:40:00Z', kind: 'makeup', state: 'done', class_status: 'Make-up completed',
        student: 'S', covering: false, makeup_of: '2026-10-30T08:00:00Z', count: { n: 3, total: 8 }, topics: 'x', recorded_at: '2026-11-02T08:45:00Z', locked: false }],
      to_record: [], makeups: [{ id: 'm', student: 'S', original_at: null, original_date: '2026-10-07', slots: [{ id: 's', starts_at: '2026-11-05T08:00:00Z', ends_at: '2026-11-05T08:40:00Z', answer: 'yes', busy: false, past: false }] }],
    });
    expect(s.lessons[0].count).toEqual({ n: 3, total: 8 });
    expect(s.lessons[0].makeupOf?.toISOString()).toBe('2026-10-30T08:00:00.000Z');
    expect(s.makeups[0].slots[0].answer).toBe('yes');
  });
});

describe('수업 종류 한국어 (H26(138))', () => {
  it('운영진·학생 화면 이름', async () => {
    const { typeKo, typeKoLong } = await import('../class-type');
    expect(typeKo('carry_out')).toBe('다음 수강기간으로 이월되는 수업');
    expect(typeKo(undefined, 'migrated_extra')).toBe('정규');
    expect(typeKo(undefined, 'compensation')).toBe('보상수업');
    expect(typeKoLong('cover')).toBe('대체 수업');
    expect(typeKoLong('compensation')).toBe('보상수업');
  });
});
