import { describe, expect, it } from 'vitest';
import { buildBoard } from './board';
import { toEndingSoon, toImportChecks, toTaskSources, toTodayLessons, type EndingRow, type TaskRow } from './live';

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

describe('종료 임박 (POL-RN-08)', () => {
  const now = new Date('2026-10-27T03:00:00Z'); // 10/27 12:00 KST
  const T = { name: 'Olivia' };
  let n = 0;
  const reg = (starts_at: string, state: 'scheduled' | 'canceled' | 'done' = 'scheduled', kind = 'regular', extra: { class_status?: string; makeup_of?: string } = {}) =>
    ({ id: `l${++n}`, kind, state, starts_at, class_status: extra.class_status ?? null, makeup_of: extra.makeup_of ?? null, voided_at: null, tutor: T });
  const row = (over: Partial<EndingRow>): EndingRow => ({
    id: 'e1', student_id: 's1', weeks: 4, legacy_label: null, weekly_count: 2, duration_min: 50, final_end_date: '2026-10-30',
    student: { name_ko: '가상학생일', code: 'STU-9001' }, lessons: [], ...over,
  });

  it('지금 이후 예정 정규 2회 이하 → 한 줄. 지난 예정 수업(Class Record 없음)은 한 것으로 셈, 취소는 안 셈', () => {
    const src = toEndingSoon([row({ lessons: [reg('2026-10-20T10:00:00Z'), reg('2026-10-27T02:00:00Z'), reg('2026-10-28T10:00:00Z'), reg('2026-10-29T10:00:00Z', 'canceled'), reg('2026-10-30T10:00:00Z')] })], now);
    expect(src).toEqual([expect.objectContaining({ kind: 'ending_soon', id: 'e1', lessonsLeft: 2, tutorName: 'Olivia', product: '50분 주2회 1개월(4주)' })]);
    expect((src[0] as { endsAt: Date }).endsAt.toISOString()).toBe('2026-10-30T14:59:59.999Z');
    expect(buildBoard(src, now)[0]).toMatchObject({ category: 'ending', title: '가상학생일 · 수업 2회 남음' });
  });

  it('재등록 안내 문자: 남은 횟수·종료일 23:59 마감, [보냄] 기록이 있으면 보냄 시각', () => {
    const lessons = [reg('2026-10-28T10:00:00Z'), reg('2026-10-30T10:00:00Z')];
    const item = buildBoard(toEndingSoon([row({ lessons })], now, new Map([['e1', '2026-10-27T05:00:00Z']])), now)[0];
    expect(item.actions).toEqual([]);
    expect(item.renewal?.sentAt?.toISOString()).toBe('2026-10-27T05:00:00.000Z');
    expect(item.renewal?.text).toBe(
      '[엣지영어] 가상학생일님, 수업이 2회 남았어요. (종료일 10월 30일(금))\n\n' +
        '종료일 10월 30일(금) 밤 11시 59분까지 재등록 결제를 마치시면 남은 수업은 다음 수강기간으로 이어지고, 지금 수업 요일·시간도 그대로 유지돼요.\n\n' +
        '재등록을 원하시면 편하게 답장 주세요. 😊',
    );
    expect(buildBoard(toEndingSoon([row({ lessons })], now), now)[0].renewal?.sentAt).toBeNull();
  });

  it('3회 이상 남으면 안 나옴', () => {
    expect(toEndingSoon([row({ lessons: [reg('2026-10-28T10:00:00Z'), reg('2026-10-29T10:00:00Z'), reg('2026-10-30T10:00:00Z')] })], now)).toEqual([]);
  });

  it('종료일이 지나도 재등록 결제 확인 전이면 계속 나옴 (0회, 기한 지남)', () => {
    const src = toEndingSoon([row({ final_end_date: '2026-10-24', lessons: [reg('2026-10-23T10:00:00Z')] })], now);
    expect(src).toHaveLength(1);
    expect(buildBoard(src, now)[0]).toMatchObject({ severity: 'overdue', title: '가상학생일 · 수업 0회 남음' });
  });

  it('결제 확인된 재등록 수강권이 있으면 빠짐 (학생마다 마지막 수강권만 봄)', () => {
    const old = row({ lessons: [reg('2026-10-28T10:00:00Z')] });
    const next = row({ id: 'e2', final_end_date: '2026-11-27', lessons: [reg('2026-11-02T10:00:00Z'), reg('2026-11-04T10:00:00Z'), reg('2026-11-06T10:00:00Z')] });
    expect(toEndingSoon([old, next], now)).toEqual([]);
  });

  it('정규 수업이 아직 없는 수강권(신규 매칭 전)은 안 나옴', () => {
    expect(toEndingSoon([row({ lessons: [] })], now)).toEqual([]);
  });

  it('보강·보상·이월도 수업으로 셈, 날짜 미정 보강(취소 수업의 보강 권리·시트 미예약 보강)도 셈 (2026-10-27 대표)', () => {
    const base = [reg('2026-10-28T10:00:00Z'), reg('2026-10-29T10:00:00Z', 'scheduled', 'makeup')];
    expect(toEndingSoon([row({ lessons: base })], now)).toHaveLength(1);
    expect(toEndingSoon([row({ lessons: [...base, reg('2026-10-30T10:00:00Z', 'scheduled', 'compensation')] })], now)).toEqual([]);
    const canceled = reg('2026-10-22T10:00:00Z', 'canceled', 'regular', { class_status: 'Student canceled in advance' });
    expect(toEndingSoon([row({ lessons: [...base, canceled] })], now)).toEqual([]);
    expect(toEndingSoon([row({ lessons: [...base, canceled, reg('2026-10-30T10:00:00Z', 'done', 'makeup', { makeup_of: canceled.id })] })], now)).toHaveLength(1);
    expect(toEndingSoon([row({ lessons: base, migrated: [{ kind: 'makeup_open' }] })], now)).toEqual([]);
  });
});
