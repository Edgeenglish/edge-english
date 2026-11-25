import { describe, expect, it } from 'vitest';
import { alternatives, autoAssign, parseItems, pickProblem, ttlStatus, weekKey, type TtlOptionRow } from './ttl';

// 한국 시간 → Date
const k = (s: string) => new Date(`${s}:00+09:00`);
// 회차: 12/7(월) 주 월·목 19:00, 12/14(월) 주 월·목 19:00. 가능 시각 = 그 주 월·목 21:00, 화 21:00
const row = (key: string, orig: string, cands: string[]): TtlOptionRow => ({ key, orig: k(orig), minutes: 40, state: null, cands: cands.map(k) });
const rows = [
  row('a', '2026-12-07T19:00', ['2026-12-07T21:00', '2026-12-08T21:00', '2026-12-10T21:00']),
  row('b', '2026-12-10T19:00', ['2026-12-07T21:00', '2026-12-08T21:00', '2026-12-10T21:00']),
  row('c', '2026-12-14T19:00', ['2026-12-15T21:00', '2026-12-17T21:00']), // 이 주는 월요일 21:00 없음
];

describe('새 수업 시간 자동 배정 (H26(218))', () => {
  it('매주 월·목 21:00 → 같은 주 안에서 회차마다 다른 시각, 없으면 조정 필요', () => {
    const p = autoAssign(rows, [weekKey(k('2026-12-07T21:00')), weekKey(k('2026-12-10T21:00'))]);
    expect((p.a as Date).getTime()).toBe(k('2026-12-07T21:00').getTime());
    expect((p.b as Date).getTime()).toBe(k('2026-12-10T21:00').getTime());
    expect((p.c as Date).getTime()).toBe(k('2026-12-17T21:00').getTime());
  });
  it('한 주에 고른 시각이 하나뿐이면 두 번째 회차는 비움 (다음 주로 안 넘김)', () => {
    const p = autoAssign(rows, [weekKey(k('2026-12-07T21:00'))]);
    expect(p.b).toBeNull();
    expect(pickProblem(rows[1], rows, p)).toBe('none');
    expect(alternatives(rows[1], rows, p).map((t) => t.getTime())).not.toContain(k('2026-12-07T21:00').getTime());
  });
  it("'나중에'·'운영진에게 맡김'으로 둔 회차는 그대로", () => {
    const p = autoAssign(rows, [weekKey(k('2026-12-07T21:00'))], { a: 'later', b: 'admin' });
    expect(p.a).toBe('later');
    expect(p.b).toBe('admin');
    expect(pickProblem(rows[0], rows, p)).toBeNull();
  });
  it('겹치는 선택은 clash', () => {
    const p = { a: k('2026-12-07T21:00'), b: k('2026-12-07T21:00'), c: 'later' as const };
    expect(pickProblem(rows[1], rows, p)).toBe('clash');
  });
  it('상태: 확정·운영진·학생 확인 대기', () => {
    const [it0] = parseItems([{ tutor_id: 't', tutor: 'Noah', student_id: 's', student: 'A', city: 'Buenos Aires', timezone: 'America/Argentina/Buenos_Aires', from: '2027-01-05', to: null, rc_pending: false,
      rows: [{ key: 'x', orig: '2027-01-07T10:00:00Z', minutes: 40, state: 'confirmed' }, { key: 'y', orig: '2027-01-11T10:00:00Z', minutes: 40, state: 'proposed' }, { key: 'z', orig: '2027-01-14T10:00:00Z', minutes: 40, state: null }] }]);
    expect(ttlStatus(it0)).toMatchObject({ kind: 'proposed', n: 3, confirmed: 1, proposed: 1, open: 1 });
  });
});
