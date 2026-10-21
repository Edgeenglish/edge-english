// 시험용 Supabase 묶음 파일이 마이그레이션과 같은지 (마이그레이션만 고치고 묶음을 안 만들면 실패)
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { describe, expect, it } from 'vitest';
import { buildBundle } from '../../../scripts/lms-test-bundle.mjs';

describe('시험용 Supabase 묶음 SQL', () => {
  it('supabase/test-setup/schema_all.sql 이 최신 (다르면 node scripts/lms-test-bundle.mjs)', () => {
    const root = join(__dirname, '..', '..', '..');
    expect(readFileSync(join(root, 'supabase/test-setup/schema_all.sql'), 'utf8')).toBe(buildBundle(root));
  });
});
