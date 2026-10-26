import { describe, expect, it } from 'vitest';
import { buildBoard } from './board';
import { toImportChecks, toTaskSources, toTodayLessons, type TaskRow } from './live';

const base: Omit<TaskRow, 'id' | 'kind'> = {
  due_at: null,
  created_at: '2026-10-17T00:00:00Z',
  tutor_assigned_at: null,
  student_notified_at: null,
  tutor_notified_at: null,
  tutor_acknowledged_at: null,
  schedule_checked_at: null,
  tutor_change_planned: false,
  tutor: null,
  enrollment: { weeks: 4, legacy_label: null, weekly_count: 2, duration_min: 50, start_date: '2026-10-20', base_end_date: '2026-11-16', student: { name_ko: '가상학생일', code: 'STU-9001' } },
};

describe('실제 데이터 → 처리할 일', () => {
  it('매칭·재등록 업무를 화면 항목으로 바꿈', () => {
    const src = toTaskSources(
      [
        { ...base, id: 'm', kind: 'new_student_matching', due_at: '2026-10-21T14:59:59Z' },
        { ...base, id: 'r', kind: 'renewal_tutor_notice', tutor: { name: '가상강사 Blair' }, tutor_notified_at: '2026-10-17T01:00:00Z' },
      ],
      [],
      [],
    );
    expect(src.map((s) => s.kind)).toEqual(['new_student_matching', 'renewal_tutor_notice']);
    expect(src[0]).toMatchObject({ studentName: '가상학생일', product: '50분 주2회 1개월(4주)' });
    expect(src[1]).toMatchObject({ newPeriod: '10/20(화)–11/16(월)', tutorName: '가상강사 Blair' });
    const board = buildBoard(src, new Date('2026-10-18T00:00:00Z'));
    expect(board).toHaveLength(2);
  });

  it('장기 연기·노쇼 신고도 포함, 노쇼가 맨 위', () => {
    const src = toTaskSources(
      [{ ...base, id: 'm', kind: 'new_student_matching', due_at: '2026-10-21T14:59:59Z' }],
      [{ id: 'l', leave_start: '2026-11-20', days: 7, reason_kind: 'health', created_at: '2026-10-17T00:00:00Z', enrollment: { student: { name_ko: '가상학생이', code: 'STU-9002' } } }],
      [{ id: 'n', reported_at: '2026-10-18T10:05:00Z', lesson: { starts_at: '2026-10-18T10:00:00Z', student: { name_ko: '가상학생오' }, tutor: { name: 'Alex' } } }],
    );
    expect(src.find((s) => s.kind === 'long_leave_request')).toMatchObject({ from: '11/20(금)', to: '11/26(목)' });
    expect(buildBoard(src, new Date('2026-10-18T10:10:00Z'))[0].kind).toBe('no_show_report');
  });

  it('기한 없는 매칭 행은 건너뜀 (데이터 이상)', () => {
    expect(toTaskSources([{ ...base, id: 'x', kind: 'new_student_matching' }], [], [])).toEqual([]);
  });
});

describe('오늘 수업', () => {
  it('KST 시각·상태 표시, 시간순', () => {
    const rows = toTodayLessons(
      [
        { id: 'b', starts_at: '2026-10-18T11:00:00Z', kind: 'makeup', state: 'scheduled', class_status: null, student: { name_ko: 'B' }, tutor: { name: 'T' } },
        { id: 'a', starts_at: '2026-10-18T10:00:00Z', kind: 'regular', state: 'canceled', class_status: 'Student canceled late', student: { name_ko: 'A' }, tutor: { name: 'T' } },
        { id: 'c', starts_at: '2026-10-18T12:00:00Z', kind: 'regular', state: 'scheduled', class_status: null, student: { name_ko: 'C' }, tutor: { name: 'T' } },
      ],
      new Set(['c']),
    );
    expect(rows.map((r) => [r.time, r.state])).toEqual([
      ['19:00', '학생 변경'],
      ['20:00', '보강'],
      ['21:00', '노쇼 신고'],
    ]);
  });
});

describe('기존 학생 입력 뒤 처리할 일 (import_checks · migrated_items)', () => {
  it('대조 전과 원래 날짜 확인 필요를 학생마다 한 줄로 합침', () => {
    const e = { student: { name_ko: '가상기존', code: 'STU-0101' } };
    const out = toImportChecks(
      [{ enrollment_id: 'e1', sheet_total: 24, sheet_used: 12, lms_left: 13, created_at: '2026-10-24T00:00:00Z', enrollment: e }],
      [
        { id: 'i1', kind: 'makeup_open', enrollment_id: 'e1', created_at: '2026-10-24T00:00:00Z', lesson: null, enrollment: e },
        { id: 'i2', kind: 'makeup_booked', enrollment_id: 'e2', created_at: '2026-10-24T00:00:00Z', lesson: { starts_at: '2026-10-30T10:00:00Z' }, enrollment: e },
      ],
    );
    expect(out).toMatchObject([
      { id: 'e1', counts: { lmsLeft: 13, sheetLeft: 12 }, unknownOrigins: [{ id: 'i1', label: '미예약 보강' }] },
      { id: 'e2', counts: null, unknownOrigins: [{ id: 'i2', label: '예약된 보강 10/30(금)' }] },
    ]);
  });
});

describe('종료일 이유 미확인은 대조 완료와 따로 (migration 1600)', () => {
  it('대조 완료한 학생도 종료일 이유가 없으면 그 항목만 남음', () => {
    const e = { student: { name_ko: '가상', code: 'STU-0102' } };
    const [t] = toImportChecks([{ enrollment_id: 'e3', sheet_total: 24, sheet_used: 3, lms_left: 21, created_at: '2026-10-26T00:00:00Z', checked_at: '2026-10-26T01:00:00Z', end_days: 6, end_reason: null, weeks: 12, enrollment: e }], []);
    expect(t).toMatchObject({ counts: null, endReason: { days: 6, weeks: 12 } });
  });
});
