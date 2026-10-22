// Supabase SQL 편집기에 붙여 넣을 파일 하나 만들기
// supabase/migrations/*.sql 을 순서대로 이어 붙여
//   supabase/test-setup/schema_all.sql  (시험용)
//   supabase/prod-setup/01-schema.sql   (운영용 — 같은 내용 + 빈 프로젝트가 아니면 멈추는 안전장치)
// 사용: node scripts/lms-test-bundle.mjs   (마이그레이션을 고치면 다시 실행 — 테스트가 차이를 잡아 줌)
import { readdirSync, readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';

function migrationParts(root) {
  const dir = join(root, 'supabase/migrations');
  const files = readdirSync(dir).filter((f) => f.endsWith('.sql')).sort();
  return files.map((f) => `-- >>> ${f}\n${readFileSync(join(dir, f), 'utf8').trimEnd()}\n`);
}

export function buildBundle(root) {
  return [
    '-- 자동 생성 파일 (직접 고치지 말 것): node scripts/lms-test-bundle.mjs',
    '-- 시험용 Supabase 프로젝트에만 사용. 빈 프로젝트에 한 번 실행 (두 번 실행하면 "이미 있음" 오류)',
    'begin;',
    ...migrationParts(root),
    'commit;',
    '',
  ].join('\n');
}

// 운영용: 시험용과 마이그레이션 내용은 똑같고, 앞에 안전장치만 붙임 (가상 데이터 없음)
export function buildProdBundle(root) {
  return [
    '-- 자동 생성 파일 (직접 고치지 말 것): node scripts/lms-test-bundle.mjs',
    '-- 운영 Supabase 프로젝트(edgeenglish-lms) 표 만들기. 빈 프로젝트에 한 번만 실행. 가상 데이터 없음',
    '-- 한 묶음 실행: 중간에 오류가 나면 전체 취소 (반쯤 만들어진 상태가 남지 않음)',
    'begin;',
    "do $$",
    'begin',
    "  if exists (select 1 from pg_tables where schemaname = 'public') then",
    "    raise exception '멈춤: public 에 이미 표가 있습니다 (빈 운영 프로젝트가 아님). 아무것도 바꾸지 않았습니다.';",
    '  end if;',
    'end $$;',
    ...migrationParts(root),
    'commit;',
    '',
  ].join('\n');
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const root = join(import.meta.dirname, '..');
  writeFileSync(join(root, 'supabase/test-setup/schema_all.sql'), buildBundle(root));
  writeFileSync(join(root, 'supabase/prod-setup/01-schema.sql'), buildProdBundle(root));
  console.log('supabase/test-setup/schema_all.sql · supabase/prod-setup/01-schema.sql 생성');
}
