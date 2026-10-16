// 정책 기준표(docs/lms/policy/register.md) ↔ 코드 일관성 검사
// - 코드가 참조하는 정책 ID가 기준표에 있는지
// - 코드가 확정 값으로 쓰는 규칙이 기준표에서 '확정'인지
// - 운영자 결정을 기다리는 규칙(PendingPolicy)이 기준표에서 아직 '검토 중'/'변경 제안'인지
// - 상태매핑표 14개가 TypeScript 와 DB 기준값에서 같은지
// 실패하면: 기준표와 코드 중 어느 쪽이 맞는지 확인하고 함께 고친다 (docs/lms/policy/process.md)

import { readdirSync, readFileSync } from 'node:fs';
import { join } from 'node:path';
import { describe, expect, it } from 'vitest';
import { CONFIRMED_REFS, PENDING_REFS } from './policy';
import { CLASS_STATUSES, STATUS_RULES } from './status';

const ROOT = join(__dirname, '..', '..', '..');
const register = readFileSync(join(ROOT, 'docs/lms/policy/register.md'), 'utf8');

const STATUSES = ['확정', '검토 중', '변경 제안', '폐지'] as const;

function parseRegister(): Map<string, string> {
  const map = new Map<string, string>();
  const blocks = register.split(/^### /m).slice(1);
  for (const block of blocks) {
    const id = /^(POL-[A-Z]+-\d{2}) · /.exec(block)?.[1];
    if (!id) continue;
    const line = /^- \*\*상태\*\*: (.+)$/m.exec(block)?.[1] ?? '';
    const status = STATUSES.find((s) => line.startsWith(s));
    if (!status) throw new Error(`${id}: 상태 줄을 읽을 수 없습니다 → "${line}"`);
    if (map.has(id)) throw new Error(`정책 ID 중복: ${id}`);
    map.set(id, status);
  }
  return map;
}

const policies = parseRegister();

describe('정책 기준표 형식', () => {
  it('정책이 비어 있지 않음', () => expect(policies.size).toBeGreaterThan(50));

  it('요약표 합계가 실제 항목 수와 같음', () => {
    const m = /\*\*합계 \((\d+)개\)\*\* \| \*\*(\d+)\*\* \| \*\*(\d+)\*\* \| \*\*(\d+)\*\* \| \*\*(\d+)\*\*/.exec(register);
    expect(m, '요약표 합계 줄이 없음').not.toBeNull();
    const count = (s: string) => [...policies.values()].filter((v) => v === s).length;
    expect(m!.slice(1).map(Number)).toEqual([policies.size, count('확정'), count('검토 중'), count('변경 제안'), count('폐지')]);
  });
});

describe('코드 ↔ 기준표', () => {
  it('코드가 확정 값으로 쓰는 규칙은 기준표에서 확정', () => {
    for (const [key, id] of Object.entries(CONFIRMED_REFS)) {
      expect(policies.get(id), `${key} → ${id}`).toBe('확정');
    }
  });

  it('운영자 결정을 기다리는 규칙은 기준표에서 아직 미확정 (확정되면 코드를 갱신할 차례)', () => {
    for (const [key, id] of Object.entries(PENDING_REFS)) {
      expect(['검토 중', '변경 제안'], `${key} → ${id} 가 ${policies.get(id)} 로 바뀜. PendingPolicy 에서 빼고 확정 값으로 옮기세요`).toContain(
        policies.get(id),
      );
    }
  });

  it('LMS 코드·DB가 언급하는 정책 ID는 모두 기준표에 있음', () => {
    const files = [
      ...readdirSync(join(ROOT, 'src/lms/rules')).map((f) => join(ROOT, 'src/lms/rules', f)),
      ...readdirSync(join(ROOT, 'supabase/migrations')).map((f) => join(ROOT, 'supabase/migrations', f)),
    ];
    const missing: string[] = [];
    for (const f of files) {
      for (const [id] of readFileSync(f, 'utf8').matchAll(/POL-[A-Z]+-\d{2}/g)) {
        if (!policies.has(id)) missing.push(`${id} (${f.replace(ROOT + '/', '')})`);
      }
    }
    expect(missing).toEqual([]);
  });
});

describe('상태매핑표 14개: TypeScript ↔ DB 기준값', () => {
  const sql = readdirSync(join(ROOT, 'supabase/migrations'))
    .map((f) => readFileSync(join(ROOT, 'supabase/migrations', f), 'utf8'))
    .join('\n');
  const rows = [...sql.matchAll(/\('([^']+)', '([^']+)', (true|false), (true|false), (true|false), '([a-z_]+)', '[a-z]+'\)/g)];

  it('DB에도 14개', () => expect(rows.map((r) => r[1]).sort()).toEqual([...CLASS_STATUSES].sort()));

  it('학생 문구·수강권·변경권·급여·인센티브가 같음', () => {
    for (const [, status, label, consumes, credit, paid, incentive] of rows) {
      const r = STATUS_RULES[status as keyof typeof STATUS_RULES];
      expect({ status, label, consumes, credit, paid, incentive }).toEqual({
        status,
        label: r.studentLabel,
        consumes: String(r.consumesLesson),
        credit: String(r.usesCredit),
        paid: String(r.tutorPaid),
        incentive: r.incentive,
      });
    }
  });
});
