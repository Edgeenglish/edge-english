import { readFileSync, readdirSync, statSync } from 'node:fs';
import { join } from 'node:path';
import { describe, expect, it } from 'vitest';

// 운영 화면에서 학생·강사·처음 온 사람에게 내부용 표시(운영 DB 띠)가 보이면 안 됨 (2026-11-17 대표 긴급, CLAUDE.md)
// 운영 띠는 ProdBand(운영자 화면 머리글)·ProdChip(운영자 보기 막대)로만 그린다.

const root = join(__dirname, '..', '..');
const read = (rel: string) => readFileSync(join(root, rel), 'utf8');

function walk(dir: string): string[] {
  return readdirSync(dir).flatMap((name) => {
    const p = join(dir, name);
    if (statSync(p).isDirectory()) return walk(p);
    return /\.(tsx?|jsx?)$/.test(name) && !/\.test\./.test(name) ? [p] : [];
  });
}

describe('운영 DB 띠는 운영진에게만', () => {
  it('LMS 공통 틀은 시험용 띠만 그린다 (운영 띠 없음)', () => {
    const layout = read('app/lms/layout.tsx');
    expect(layout).toContain("env === 'test'");
    expect(layout).not.toMatch(/DB_ENV_LABEL\.prod|DB_ENV_LABEL\[env\][\s\S]*env &&|bg-red-600/);
  });

  it('운영 띠 문구·ProdBand·ProdChip 은 정해진 운영자 자리에서만 쓴다', () => {
    const allowed: Record<string, RegExp> = {
      'lms/auth/ProdBand.tsx': /./,
      'lms/auth/db-env.ts': /./,
      'app/lms/admin/ui.tsx': /ProdBand/,
      'app/lms/student/StudentLive.tsx': /ProdChip/,
      'app/lms/tutor/TutorLive.tsx': /ProdChip/,
    };
    const offenders = walk(root)
      .map((p) => p.slice(root.length + 1).replace(/\\/g, '/'))
      .filter((rel) => /ProdBand|ProdChip|DB_ENV_LABEL\.prod|운영 DB · 실제 데이터/.test(read(rel)))
      .filter((rel) => !(rel in allowed));
    expect(offenders).toEqual([]);
  });

  it('학생·강사 화면의 ProdChip 은 운영자 보기 막대(state.admin) 안에만 있다', () => {
    for (const rel of ['app/lms/student/StudentLive.tsx', 'app/lms/tutor/TutorLive.tsx']) {
      const src = read(rel);
      const bar = src.indexOf('const adminBar = state.admin && (');
      const chips = [...src.matchAll(/<ProdChip \/>/g)].map((m) => m.index ?? -1);
      expect(bar).toBeGreaterThan(-1);
      expect(chips.length).toBe(1);
      const barEnd = src.indexOf('\n  );', bar);
      expect(chips[0]).toBeGreaterThan(bar);
      expect(chips[0]).toBeLessThan(barEnd);
    }
  });
});
