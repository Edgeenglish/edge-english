import { readFileSync } from 'node:fs';
import { describe, expect, it } from 'vitest';
import { MONTHLY, renewalPlans } from './renewal-price';

// 재등록 안내 가격표는 두 곳에 있다: 문자(renewal-price.ts)와 자동 메일(DB 함수 lms_renewal_plans, migration 20261111190000).
// 가격이 한쪽만 바뀌면 이 시험이 실패한다.
const sql = readFileSync('supabase/migrations/20261111190000_lms_renewal_mail.sql', 'utf8');

function sqlMonthly(): Record<number, Record<number, number>> {
  const out: Record<number, Record<number, number>> = {};
  const re = /'(\d+)', jsonb_build_object\(([^)]*)\)/g;
  for (const m of sql.matchAll(re)) {
    const row: Record<number, number> = {};
    for (const p of m[2].matchAll(/'(\d+)', (\d+)/g)) row[Number(p[1])] = Number(p[2]);
    out[Number(m[1])] = row;
  }
  return out;
}

describe('재등록 가격표 — 문자(TS)와 자동 메일(SQL)이 같다', () => {
  it('1개월 가격표가 같다 (분 · 주 횟수 · 금액 모두)', () => {
    expect(sqlMonthly()).toEqual(MONTHLY);
  });
  it('할인 계산식이 같다 (3개월 5%, 6개월 5% + 5만 원)', () => {
    expect(sql).toContain('round(v_monthly * 3 * 0.95)');
    expect(sql).toContain('round(v_monthly * 6 * 0.95)::int - 50000');
    expect(renewalPlans(40, 3)).toEqual({
      monthly: 420000,
      three: { total: 1197000, perMonth: 399000, save: 63000 },
      six: { total: 2344000, perMonth: 390667, save: 176000 },
    });
  });
});
