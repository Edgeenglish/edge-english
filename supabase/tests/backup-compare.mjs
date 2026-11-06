// 백업 CSV 두 개의 표별 내용 비교 (행 순서 무시). 백업 시각·로그인 계정 줄은 제외. 다르면 종료 코드 1
import { readFileSync } from 'node:fs';
import { readBackup } from '../../scripts/lms-restore-sql.mjs';

const [a, b] = process.argv.slice(2).map((f) => readBackup(readFileSync(f, 'utf8')));
const norm = (rows) => rows.map((r) => JSON.stringify(r, Object.keys(r).sort())).sort();
const bad = [];
for (const t of new Set([...a.keys(), ...b.keys()])) {
  if (t === '_meta' || t === '_auth_users') continue;
  const x = a.get(t)?.body;
  const y = b.get(t)?.body;
  const same = Array.isArray(x) ? JSON.stringify(norm(x)) === JSON.stringify(norm(y ?? [])) : JSON.stringify(x) === JSON.stringify(y);
  if (!same) bad.push(t);
}
if (bad.length) { console.log(`❌ 백업·복구 내용 다름: ${bad.join(', ')}`); process.exit(1); }
console.log(`백업 비교: 표 ${[...a.keys()].filter((t) => !t.startsWith('_')).length}개 내용 같음, 학생 ${a.get('_meta').body.students}명`);
