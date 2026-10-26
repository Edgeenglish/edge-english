// Supabase 묶음 파일(시험용·운영용)이 마이그레이션과 같은지 (마이그레이션만 고치고 묶음을 안 만들면 실패)
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { describe, expect, it } from 'vitest';
import { buildBundle, buildProdBundle } from '../../../scripts/lms-test-bundle.mjs';

const root = join(__dirname, '..', '..', '..');

describe('Supabase 묶음 SQL', () => {
  it('supabase/test-setup/schema_all.sql 이 최신 (다르면 node scripts/lms-test-bundle.mjs)', () => {
    expect(readFileSync(join(root, 'supabase/test-setup/schema_all.sql'), 'utf8')).toBe(buildBundle(root));
  });
  it('supabase/prod-setup/01-schema.sql 이 최신 (다르면 node scripts/lms-test-bundle.mjs)', () => {
    expect(readFileSync(join(root, 'supabase/prod-setup/01-schema.sql'), 'utf8')).toBe(buildProdBundle(root));
  });
  it('운영용 묶음에는 가상 데이터가 없음', () => {
    const sql = buildProdBundle(root);
    expect(sql).not.toMatch(/가상강사|example\.com|seed_fake/);
  });
});

describe('운영 DB 만들기 복사 버튼 페이지', () => {
  it('docs/lms/previews/prod-setup.html 이 최신 (다르면 node scripts/lms-prod-page.mjs 후 다시 발행)', async () => {
    const { buildPage } = await import('../../../scripts/lms-prod-page.mjs');
    expect(readFileSync(join(root, 'docs/lms/previews/prod-setup.html'), 'utf8')).toBe(buildPage(root));
  });
});

describe('[보냈어요]·기존 학생 입력 적용 안내 페이지', () => {
  it('docs/lms/previews/d52-apply.html 이 최신 (다르면 node scripts/lms-d52-page.mjs 후 다시 발행)', async () => {
    const { buildD52Page } = await import('../../../scripts/lms-d52-page.mjs');
    expect(readFileSync(join(root, 'docs/lms/previews/d52-apply.html'), 'utf8')).toBe(buildD52Page(root));
  });
  it('docs/lms/previews/d52x-apply.html 이 최신 (다르면 node scripts/lms-d52x-page.mjs 후 다시 발행)', async () => {
    const { buildD52xPage } = await import('../../../scripts/lms-d52x-page.mjs');
    expect(readFileSync(join(root, 'docs/lms/previews/d52x-apply.html'), 'utf8')).toBe(buildD52xPage(root));
  });
  it('docs/lms/previews/d52y-apply.html 이 최신 (다르면 node scripts/lms-d52y-page.mjs 후 다시 발행)', async () => {
    const { buildD52yPage } = await import('../../../scripts/lms-d52y-page.mjs');
    expect(readFileSync(join(root, 'docs/lms/previews/d52y-apply.html'), 'utf8')).toBe(buildD52yPage(root));
  });
});
