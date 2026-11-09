import { describe, expect, it } from 'vitest';
import { monthEnd, monthRegistrations, noticeError, noticeState, rangeDates, sortNotices, toLessonItems, tutorItems, type Notice } from './dashboard';

describe('대시보드 5차 — 숫자 칸·명단', () => {
  it('이번 달 등록: 결제 확인일(한국 날짜) 이번 달만, 신규/재등록, 체험용 뺌, 같은 수강권 한 번', () => {
    const e = (prev: string | null, code: string, trial = false) => ({ previous_enrollment_id: prev, weeks: 12, legacy_label: null, weekly_count: 2, duration_min: 40, student: { code, name_ko: '가상', is_trial_account: trial } });
    const rows = [
      { enrollment_id: 'a', confirmed_at: '2026-11-08T03:00:00Z', paid_at: '2026-11-05T03:00:00Z', received_on: null, enrollment: e('old', 'STU-0004') },
      { enrollment_id: 'b', confirmed_at: '2026-10-31T16:00:00Z', paid_at: null, received_on: '2026-11-01', enrollment: e(null, 'STU-0013') }, // 11/1 01:00 KST
      { enrollment_id: 'c', confirmed_at: '2026-10-31T14:00:00Z', paid_at: null, received_on: null, enrollment: e(null, 'STU-0020') }, // 10/31 23:00 KST
      { enrollment_id: 'd', confirmed_at: '2026-11-02T00:00:00Z', paid_at: null, received_on: null, enrollment: e(null, 'STU-0014', true) },
      { enrollment_id: 'a', confirmed_at: '2026-11-09T00:00:00Z', paid_at: null, received_on: null, enrollment: e('old', 'STU-0004') },
    ];
    const r = monthRegistrations(rows, '2026-11-09');
    expect(r.map((x) => [x.studentCode, x.fresh, x.paidOn, x.confirmedOn])).toEqual([
      ['STU-0013', true, '2026-11-01', '2026-11-01'],
      ['STU-0004', false, '2026-11-05', '2026-11-08'],
    ]);
    expect(r[1].plan).toBe('3개월(12주) · 주 2회 · 40분');
  });
  it('이달 말일·기간 버튼(이번 주 = 월~일)', () => {
    expect(monthEnd('2026-11-09')).toBe('2026-11-30');
    expect(monthEnd('2028-02-03')).toBe('2028-02-29');
    expect(rangeDates('week', '2026-11-09')).toEqual({ from: '2026-11-09', to: '2026-11-15' });
    expect(rangeDates('next', '2026-11-15')).toEqual({ from: '2026-11-16', to: '2026-11-22' });
    expect(rangeDates('tomorrow', '2026-11-30')).toEqual({ from: '2026-12-01', to: '2026-12-01' });
    expect(rangeDates('pick', '2026-11-09', { from: '2026-11-20', to: '2026-11-16' })).toBeNull();
  });
  it('수업 줄: 한국 시각·종류·상태(수강생 사정 취소 = 수강생 변경, 노쇼 신고)', () => {
    const l = (id: string, at: string, kind: string, state: 'scheduled' | 'canceled' | 'done', cs: string | null = null) => ({ id, starts_at: at, kind, state, class_status: cs, student: { code: 'STU-0001', name_ko: '가상' }, tutor: { name: 'Olivia' } });
    const items = toLessonItems([l('2', '2026-11-09T11:00:00Z', 'regular', 'canceled', 'Student canceled'), l('1', '2026-11-08T23:00:00Z', 'makeup', 'done'), l('3', '2026-11-09T12:00:00Z', 'compensation', 'scheduled')], new Set(['3']));
    expect(items.map((i) => [i.date, i.time, i.kind, i.state])).toEqual([
      ['2026-11-09', '오전 8:00', '보강', '완료'], ['2026-11-09', '오후 8:00', '정규', '수강생 변경'], ['2026-11-09', '오후 9:00', '보상 수업', '노쇼 신고'],
    ]);
  });
  it('강사 담당 학생: 이어지는 정규 일정 + 수강 중·예정 학생만, 체험용 강사는 아래', () => {
    const st = (id: string, code: string) => ({ id, code, name_ko: '가상', is_trial_account: false });
    const t = tutorItems(
      [{ id: 'sk', name: 'Sera Kara', timezone: 'Europe/Berlin', active: true, is_trial_account: true }, { id: 'ol', name: 'Olivia', timezone: 'Asia/Tokyo', active: true }, { id: 'x', name: 'Gone', timezone: 'Asia/Tokyo', active: false }],
      [{ tutor_id: 'ol', effective_to: null, student: st('s1', 'STU-0001') }, { tutor_id: 'ol', effective_to: null, student: st('s1', 'STU-0001') },
        { tutor_id: 'ol', effective_to: '2026-11-01', student: st('s2', 'STU-0002') }, { tutor_id: 'ol', effective_to: null, student: st('s6', 'STU-0006') }],
      new Set(['s1', 's2']), '2026-11-09');
    expect(t.map((x) => [x.name, x.students.map((s) => s.code)])).toEqual([['Olivia', ['STU-0001']], ['Sera Kara', []]]);
  });
});

describe('공지', () => {
  const n = (over: Partial<Notice>): Notice => ({ id: 'n', audience: 'both', title: 't', body: 'b', startsOn: '2026-11-09', endsOn: '2026-11-30', endedAt: null, ...over });
  it('상태: 게시 예정·게시 중·게시 종료(종료일 지남 또는 게시 종료)', () => {
    expect(noticeState(n({}), '2026-11-09')).toBe('live');
    expect(noticeState(n({ startsOn: '2026-11-10' }), '2026-11-09')).toBe('wait');
    expect(noticeState(n({ endsOn: '2026-11-08', startsOn: '2026-11-01' }), '2026-11-09')).toBe('end');
    expect(noticeState(n({ endedAt: '2026-11-09T01:00:00Z' }), '2026-11-09')).toBe('end');
    expect(sortNotices([n({ id: 'old', endedAt: 'x', startsOn: '2026-11-20' }), n({ id: 'a', startsOn: '2026-11-01' }), n({ id: 'b', startsOn: '2026-11-05' })], '2026-11-09').map((x) => x.id)).toEqual(['b', 'a', 'old']);
  });
  it('저장 전 검사 = DB 함수와 같은 글', () => {
    expect(noticeError({ title: ' ', body: 'x', startsOn: '2026-11-09', endsOn: '2026-11-10' })).toBe('제목과 내용을 넣어 주세요.');
    expect(noticeError({ title: 'x'.repeat(61), body: 'x', startsOn: '2026-11-09', endsOn: '2026-11-10' })).toBe('제목은 60자까지예요.');
    expect(noticeError({ title: 'x', body: 'x', startsOn: '2026-11-09', endsOn: '' })).toBe('게시일과 종료일을 넣어 주세요.');
    expect(noticeError({ title: 'x', body: 'x', startsOn: '2026-11-09', endsOn: '2026-11-08' })).toBe('종료일이 게시일보다 빨라요.');
    expect(noticeError({ title: 'x', body: 'x', startsOn: '2026-11-09', endsOn: '2026-11-09' })).toBeNull();
  });
});
