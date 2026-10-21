// 시험용 Supabase SQL 편집기에 붙여 넣을 파일 하나 만들기
// supabase/migrations/*.sql 을 순서대로 이어 붙여 supabase/test-setup/schema_all.sql 생성
// 사용: node scripts/lms-test-bundle.mjs   (마이그레이션을 고치면 다시 실행 — 테스트가 차이를 잡아 줌)
import { readdirSync, readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';

export function buildBundle(root) {
  const dir = join(root, 'supabase/migrations');
  const files = readdirSync(dir).filter((f) => f.endsWith('.sql')).sort();
  const parts = files.map((f) => `-- >>> ${f}\n${readFileSync(join(dir, f), 'utf8').trimEnd()}\n`);
  return [
    '-- 자동 생성 파일 (직접 고치지 말 것): node scripts/lms-test-bundle.mjs',
    '-- 시험용 Supabase 프로젝트에만 사용. 빈 프로젝트에 한 번 실행 (두 번 실행하면 "이미 있음" 오류)',
    'begin;',
    ...parts,
    'commit;',
    '',
  ].join('\n');
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const root = join(import.meta.dirname, '..');
  writeFileSync(join(root, 'supabase/test-setup/schema_all.sql'), buildBundle(root));
  console.log('supabase/test-setup/schema_all.sql 생성');
}
