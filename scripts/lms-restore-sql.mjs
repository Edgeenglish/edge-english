// LMS 백업 CSV(supabase/backup/backup.sql 결과를 SQL Editor 에서 Download CSV) → 복구 SQL
// 사용: node scripts/lms-restore-sql.mjs <백업.csv> > restore.sql
// 복구 SQL이 하는 일 (한 묶음 — 오류가 나면 전체 취소):
//   ① 백업에 있는 표가 지금 DB에 모두 있는지 확인 (없으면 멈춤 — 표 만들기(01-schema)를 먼저)
//   ② 그 표들의 사용자 트리거(변경 이력·수정 금지)를 잠시 끔
//   ③ 참조 제약을 잠시 내리고, 지금 내용을 지운 뒤 백업 내용을 넣음. 자동 계산 열은 DB가 다시 계산
//   ④ 트리거·참조 제약을 다시 켬 (이때 전체 참조를 다시 검사) → 번호 순서(학생 번호 등) 되돌림
// 같은 프로젝트에 쓰면 지금 데이터가 백업 시점으로 돌아간다. 대표 승인 후, 실행 직전 백업을 한 번 더 받고 쓸 것
// 새 프로젝트로 옮길 때: 로그인 계정 번호가 달라지므로 app_users 는 _auth_users(이메일)로 다시 연결해야 함 (그때 Claude가 따로)
import { readFileSync } from 'node:fs';
import { randomBytes } from 'node:crypto';

export function parseCsv(text) {
  const rows = [];
  let row = [];
  let field = '';
  let quoted = false;
  for (let i = 0; i < text.length; i++) {
    const c = text[i];
    if (quoted) {
      if (c === '"' && text[i + 1] === '"') { field += '"'; i++; }
      else if (c === '"') quoted = false;
      else field += c;
    } else if (c === '"') quoted = true;
    else if (c === ',') { row.push(field); field = ''; }
    else if (c === '\n' || c === '\r') {
      if (c === '\r' && text[i + 1] === '\n') i++;
      row.push(field); rows.push(row); row = []; field = '';
    } else field += c;
  }
  if (field !== '' || row.length) { row.push(field); rows.push(row); }
  return rows.filter((r) => r.length > 1 || r[0] !== '');
}

export function readBackup(text) {
  const [header, ...rows] = parseCsv(text.replace(/^﻿/, ''));
  const col = (name) => header.indexOf(name);
  const [iTable, iCount, iBody] = [col('표'), col('행수'), col('내용')];
  if (iTable < 0 || iBody < 0) throw new Error('LMS 백업 CSV가 아닙니다 (표·내용 열이 없음)');
  const out = new Map();
  for (const r of rows) out.set(r[iTable], { count: Number(r[iCount]), body: JSON.parse(r[iBody]) });
  if (out.get('_meta')?.body?.format !== 'edge-lms-backup-1') throw new Error('백업 형식을 알 수 없습니다 (_meta 없음)');
  for (const [t, v] of out) {
    if (!t.startsWith('_') && v.body.length !== v.count) throw new Error(`${t}: 행 수(${v.count})와 내용(${v.body.length})이 다름 — 파일이 잘렸을 수 있음`);
  }
  return out;
}

export function buildRestoreSql(backup) {
  const tag = `bk_${randomBytes(6).toString('hex')}`;
  const lit = (s) => {
    if (s.includes(`$${tag}$`)) throw new Error('내용에 구분 문자열이 있음 — 다시 실행');
    return `$${tag}$${s}$${tag}$`;
  };
  const tables = [...backup.keys()].filter((t) => !t.startsWith('_'));
  const meta = backup.get('_meta').body;
  const values = tables.map((t) => `  (${lit(t)}, ${lit(JSON.stringify(backup.get(t).body))}::jsonb)`);
  return `-- 자동 생성: node scripts/lms-restore-sql.mjs — LMS 복구 (백업 시각 ${meta.at}, 학생 ${meta.students}명, 표 ${tables.length}개)
-- 한 묶음 실행: 오류가 나면 아무것도 바뀌지 않음
begin;
create temp table lms_restore_input (tbl text primary key, rows jsonb not null) on commit drop;
insert into lms_restore_input values
${values.join(',\n')};
create temp table lms_restore_seq (seq text primary key, last_value bigint) on commit drop;
insert into lms_restore_seq select key, value::bigint from jsonb_each_text(${lit(JSON.stringify(backup.get('_sequences')?.body ?? {}))}::jsonb) where value is not null;

do $$
declare
  missing text;
  t record;
  cols text;
  i int;
begin
  select string_agg(tbl, ', ') into missing from lms_restore_input where to_regclass('public.' || quote_ident(tbl)) is null;
  if missing is not null then raise exception '멈춤: 지금 DB에 없는 표 — % (표 만들기를 먼저)', missing; end if;

  -- 넣는 순서: 참조하는 표는 참조받는 표 뒤 (판본 확인 같은 검사 함수가 다른 표를 읽기 때문).
  -- 서로 가리키는 표(수업↔보상권)는 반복 횟수 제한으로 끝냄 — 참조 제약은 아래에서 잠시 내리므로 문제없음
  create temp table lms_restore_order on commit drop as select tbl, 0 as depth from lms_restore_input;
  for i in 1 .. 50 loop
    update lms_restore_order o set depth = d.depth from (
      select o2.tbl, max(p.depth) + 1 as depth
      from lms_restore_order o2
      join pg_constraint c on c.contype = 'f' and c.conrelid = ('public.' || quote_ident(o2.tbl))::regclass
      join lms_restore_order p on ('public.' || quote_ident(p.tbl))::regclass = c.confrelid and p.tbl <> o2.tbl
      group by o2.tbl) d
    where o.tbl = d.tbl and o.depth < d.depth and d.depth <= 50;
    exit when not found;
  end loop;

  -- 참조 제약(수업↔보상권처럼 서로 가리키는 것 포함)을 잠시 내렸다가 끝에 다시 걸어 전체를 한 번에 검사
  create temp table lms_restore_fk on commit drop as
  select c.conrelid::regclass as tbl, c.conname, pg_get_constraintdef(c.oid) as def
  from pg_constraint c join pg_namespace s on s.oid = c.connamespace
  where s.nspname = 'public' and c.contype = 'f';
  for t in select * from lms_restore_fk loop
    execute format('alter table %s drop constraint %I', t.tbl, t.conname);
  end loop;

  for t in select tbl from lms_restore_order order by depth desc, tbl loop
    execute format('alter table public.%I disable trigger user', t.tbl);
    execute format('delete from public.%I', t.tbl);
  end loop;
  for t in select o.tbl, inp.rows from lms_restore_order o join lms_restore_input inp using (tbl) order by o.depth, o.tbl loop
    select string_agg(quote_ident(column_name), ', ' order by ordinal_position) into cols
    from information_schema.columns
    where table_schema = 'public' and table_name = t.tbl and is_generated = 'NEVER';
    execute format('insert into public.%I (%s) overriding system value select %s from jsonb_populate_recordset(null::public.%I, $1)',
                   t.tbl, cols, cols, t.tbl) using t.rows;
  end loop;
  for t in select tbl from lms_restore_input loop
    execute format('alter table public.%I enable trigger user', t.tbl);
  end loop;
  for t in select * from lms_restore_fk loop
    execute format('alter table %s add constraint %I %s', t.tbl, t.conname, t.def);   -- 어긋난 참조가 있으면 여기서 오류 → 전체 취소
  end loop;

  -- 번호 순서(학생 번호·변경 이력 번호)를 백업 시점 값으로
  perform setval(('public.' || quote_ident(seq))::regclass, last_value) from lms_restore_seq
  where to_regclass('public.' || quote_ident(seq)) is not null;
end $$;

-- 확인: 표별 행 수가 백업과 같아야 함 (다르면 '다름')
create or replace function pg_temp.lms_count(t text) returns bigint language plpgsql as $f$
declare n bigint; begin execute format('select count(*) from public.%I', t) into n; return n; end $f$;
select tbl as 표, jsonb_array_length(rows) as 백업_행수, pg_temp.lms_count(tbl) as 복구_행수,
       case when jsonb_array_length(rows) = pg_temp.lms_count(tbl) then '같음' else '다름' end as 결과
from lms_restore_input order by 결과, tbl;
commit;
`;
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const file = process.argv[2];
  if (!file) { console.error('사용: node scripts/lms-restore-sql.mjs <백업.csv> > restore.sql'); process.exit(1); }
  process.stdout.write(buildRestoreSql(readBackup(readFileSync(file, 'utf8'))));
}
