// 기존 학생 자동 등록 (2026-10-27 대표 요청, handoff '기존 학생 등록 자동화')
// 시트에서 읽은 값(JSON) → 입력 화면과 같은 계산(src/lms/admin/import.ts) → 운영 SQL Editor에 1번 붙여 넣을 SQL + 대표 확인용 요약
// 저장은 화면과 같은 DB 함수 admin_import_existing_student (대표 운영자 계정으로 실행), 시트와 남은 수 같으면 대조 완료까지
// 실제 이름이 들어가므로 입력·결과 파일은 저장소에 두지 않음 (scratchpad)
//   npx vite-node scripts/lms-import-existing.ts <input.json> <out-dir>
//   → <out-dir>/paste.sql, <out-dir>/summary.md, <out-dir>/expected.json (로컬 검증 scripts/lms-import-verify.sh 가 씀)
import { createHash } from 'node:crypto';
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import {
  emptyImport, importCount, importPayload, importProblems, importPeriods, currentPeriod, autoEndDate, regularRows,
  type ImportDraft, type ImportMakeup, type EndReason, type ImportWeeks,
} from '../src/lms/admin/import';
import { creditsPerPeriod } from '../src/lms/rules/policy';
import type { KstDate, KstTime } from '../src/lms/rules/dates';

type Input = {
  today: KstDate;
  tutor: { name: string; country: string; timezone: string; timeOff: { from: KstDate; to: KstDate; reason: string }[] };
  students: {
    nameKo: string; nameEn: string; timezone: string;
    weeks: ImportWeeks; courseStart: KstDate; slots: { weekday: number; time: KstTime }[]; durationMin: number;
    fromDate: KstDate; endDate: KstDate; endReason?: EndReason; endNote?: string;
    sheetTotal: number; sheetUsed: number;
    /** 시트 머리의 남은 변경권 (비교만, 쓰지 않음 — 21번 8절) */
    sheetCredits: number;
    /** 학생 정상 취소 날짜 (변경권 사용). 지금 기간 안의 것만 셈 */
    studentCancels: KstDate[];
    makeups: { status: 'open'; originalDate: KstDate; tutorLeave: boolean; note: string }[];
    extras: { date: KstDate; time: KstTime; reason: string }[];
    /** 시트에서 아직 진행 안 된 줄의 날짜 (첫 정규 수업일부터). LMS 수업·휴가 보강과 1:1 대조 */
    sheetFuture: KstDate[];
  }[];
};

const [inPath, outDir] = process.argv.slice(2);
if (!inPath || !outDir) throw new Error('사용: vite-node scripts/lms-import-existing.ts <input.json> <out-dir>');
const input: Input = JSON.parse(readFileSync(inPath, 'utf8'));
const TUTOR = '00000000-0000-4000-8000-00000000f00d'; // SQL 안에서 실제 강사 id로 바꿈
const inLeave = (d: KstDate) => input.tutor.timeOff.some((o) => o.from <= d && d <= o.to);
const uuidOf = (s: string) => {
  const h = createHash('sha256').update(`lms-import-existing:${s}`).digest('hex');
  return `${h.slice(0, 8)}-${h.slice(8, 12)}-4${h.slice(13, 16)}-8${h.slice(17, 20)}-${h.slice(20, 32)}`;
};
const q = (s: string) => `'${s.replace(/'/g, "''")}'`;
const md = (d: string) => `${+d.slice(5, 7)}/${+d.slice(8, 10)}`;

type Row = { nameKo: string; requestId: string; payload: ReturnType<typeof importPayload>; summary: string[]; expected: Record<string, unknown> };
const rows: Row[] = [];
const stop: string[] = [];

for (const s of input.students) {
  const base: ImportDraft = {
    ...emptyImport(input.today),
    nameKo: s.nameKo, nameEn: s.nameEn, timezone: s.timezone, tutorId: TUTOR, durationMin: s.durationMin,
    slots: s.slots, fromDate: s.fromDate, endDate: s.endDate, endReason: s.endReason ?? '', endNote: s.endNote ?? '',
    weeks: s.weeks, courseStart: s.courseStart, sheetTotal: s.sheetTotal, sheetUsed: s.sheetUsed, extras: s.extras,
  };
  // 강사 휴가에 걸리는 정규 수업 → '강사 휴가 보강(미예약)', 원래 날짜 유지 (21번 7절, A41)
  const leave = regularRows({ ...base, hasMakeups: false }).filter((r) => inLeave(r.date)).map((r): ImportMakeup => ({
    status: 'open', originalDate: r.date, originUnknown: false, tutorLeave: true, date: '', time: '', durationMin: s.durationMin, tutorId: TUTOR,
  }));
  const given = s.makeups.map((m): ImportMakeup => ({
    status: 'open', originalDate: m.originalDate, originUnknown: false, tutorLeave: m.tutorLeave, date: '', time: '', durationMin: s.durationMin, tutorId: TUTOR,
  }));
  // 변경권 = 지금 기간 지급 수 − 지금 기간 안 학생 정상 취소 (시트 머리 숫자는 비교만)
  const d0 = { ...base, hasMakeups: true, makeups: [...given, ...leave] };
  const now = importPeriods(d0).find((p) => p.index === currentPeriod(d0));
  const granted = creditsPerPeriod(s.slots.length);
  const used = now ? s.studentCancels.filter((c) => now.start <= c && c <= now.end).length : 0;
  const d: ImportDraft = { ...d0, creditsLeft: Math.max(granted - used, 0) };

  const problems = importProblems(d);
  const c = importCount(d);
  const keep = regularRows(d).filter((r) => r.state === 'keep').map((r) => r.date);
  const lmsDates = [...keep, ...s.extras.map((x) => x.date), ...leave.map((m) => m.originalDate as KstDate), ...given.filter((m) => m.originalDate >= s.fromDate).map((m) => m.originalDate)].sort();
  const sheetDates = [...s.sheetFuture].sort();
  const missing = sheetDates.filter((x) => !lmsDates.includes(x));
  const extra = lmsDates.filter((x) => !sheetDates.includes(x));
  const calcEnd = autoEndDate(d);

  const sum: string[] = [];
  sum.push(`### ${s.nameKo}`);
  sum.push(`- 상품 ${s.weeks}주 · 주${s.slots.length}회 ${s.slots.map((x) => '일월화수목금토'[x.weekday]).join('/')} ${s.slots[0].time} · ${s.durationMin}분 · 시간대 ${s.timezone}`);
  sum.push(`- 지금 기간 ${now?.index}기간 (${md(now?.start ?? '')}~${md(now?.end ?? '')}) · 변경권 ${d.creditsLeft}/${granted}` +
    (d.creditsLeft !== s.sheetCredits ? ` ⚠️ 시트 머리 ${s.sheetCredits}/${granted}와 다름 (기록 기준 ${d.creditsLeft})` : ' (시트와 같음)'));
  sum.push(`- 종료일 ${md(s.endDate)}` + (s.endDate !== calcEnd ? ` (계산 ${md(calcEnd)} + ${s.endNote ?? '이유 없음'})` : ' (계산과 같음)'));
  sum.push(`- 첫 정규 수업일 ${md(s.fromDate)} · 정규 ${c.regular} · 추가 ${c.extra} · 미예약 보강 ${c.open}` +
    (leave.length ? ` (강사 휴가 ${leave.map((m) => md(m.originalDate)).join('·')}` : ' (') +
    (given.length ? `${leave.length ? ' / ' : ''}그 외 ${given.map((m) => md(m.originalDate)).join('·')})` : ')'));
  sum.push(`- 남은 수업 LMS ${c.lmsLeft} · 시트 ${c.sheetLeft} (${s.sheetTotal}−${s.sheetUsed}) → ${c.diff === 0 ? '같음 → 대조 완료 처리' : `⚠️ 차이 ${c.diff} → 대조 완료 안 함`}`);
  sum.push(`- 시트 남은 줄 날짜와 1:1 대조: ${missing.length + extra.length === 0 ? '같음' : `⚠️ 시트에만 ${missing.map(md).join('·') || '없음'} / LMS에만 ${extra.map(md).join('·') || '없음'}`}`);
  if (problems.length) { sum.push(`- ❌ 입력 문제: ${problems.join(' / ')}`); stop.push(s.nameKo); }

  rows.push({
    nameKo: s.nameKo, requestId: uuidOf(s.nameKo), payload: importPayload(d), summary: sum,
    expected: { name_ko: s.nameKo, regular: c.regular, extras: c.extra, open: c.open, lms_left: c.lmsLeft, sheet_left: c.sheetLeft,
                credits_left: d.creditsLeft, end_date: s.endDate, checked: c.diff === 0, dates: lmsDates },
  });
}

if (stop.length) throw new Error(`입력 문제가 있는 학생: ${stop.join(', ')} — summary 확인`);

const t = input.tutor;
const sql = `-- 운영 edgeenglish-lms 에서만 · 기존 학생 자동 등록 (${input.today}) · 강사 ${t.name} + 학생 ${rows.length}명
-- 한 묶음: 하나라도 실패하면 아무것도 저장되지 않음. 다시 실행해도 같은 결과 (이미 있는 학생은 건너뜀)
do $$
declare
  me uuid;
  t uuid;
  p jsonb;
  r jsonb;
begin
  if (select name from lms_backup.project) is distinct from 'edgeenglish-lms' then
    raise exception '멈춤: 운영 DB(edgeenglish-lms)가 아닙니다. 아무것도 바뀌지 않았습니다.';
  end if;
  select auth_user_id into me from app_users where role = 'admin' and admin_level = 'owner';
  if me is null then raise exception '멈춤: 대표 운영자 계정이 없습니다.'; end if;
  -- 대표 운영자 계정(추가 인증 완료)으로 화면과 같은 DB 함수 실행
  perform set_config('request.jwt.claims', json_build_object('sub', me, 'role', 'authenticated', 'aal', 'aal2')::text, true);

  insert into tutors (name, country, timezone) values (${q(t.name)}, ${q(t.country)}, ${q(t.timezone)}) on conflict (name) do nothing;
  select id into t from tutors where name = ${q(t.name)};
${t.timeOff.map((o) => `  insert into tutor_time_off (tutor_id, starts_at, ends_at, kind, reason, created_by)
  select t, timestamptz '${o.from} 00:00+09', timestamptz '${o.to} 00:00+09' + interval '1 day', 'leave', ${q(o.reason)}, me
  where not exists (select 1 from tutor_time_off where tutor_id = t and starts_at = timestamptz '${o.from} 00:00+09');`).join('\n')}
${rows.map((r) => `
  -- ${r.nameKo}
  if exists (select 1 from students where name_ko = ${q(r.nameKo)}) and not exists (select 1 from registration_requests where id = '${r.requestId}') then
    raise notice '% : 이미 있는 학생이라 건너뜀', ${q(r.nameKo)};
  else
    p := jsonb_set(${q(JSON.stringify(r.payload))}::jsonb, '{tutor_id}', to_jsonb(t::text));
    r := admin_import_existing_student('${r.requestId}', p);
    if (r ->> 'lms_left')::int = (r ->> 'sheet_left')::int then perform admin_import_mark_checked((r ->> 'enrollment_id')::uuid); end if;
  end if;`).join('\n')}
end $$;

-- 결과 표
select s.code as 학생_번호, s.name_ko as 이름, e.final_end_date as 종료일,
       count(l.id) filter (where l.kind = 'regular') as 정규,
       count(l.id) filter (where l.kind = 'migrated_extra') as 추가,
       (select count(*) from migrated_items m where m.enrollment_id = e.id and m.kind = 'makeup_open') as 미예약_보강,
       c.lms_left as LMS_남은, c.sheet_total - c.sheet_used as 시트_남은,
       (select p.credits_granted + coalesce(sum(cl.delta), 0) from enrollment_periods p left join credit_ledger cl on cl.period_id = p.id
         where p.enrollment_id = e.id and (now() at time zone 'Asia/Seoul')::date between p.start_date and p.end_date group by p.id, p.credits_granted) as 변경권,
       case when c.checked_at is not null then '대조 완료' else '확인 필요' end as 대조
from students s join enrollments e on e.student_id = s.id join import_checks c on c.enrollment_id = e.id
left join lessons l on l.enrollment_id = e.id
where s.name_ko in (${rows.map((r) => q(r.nameKo)).join(', ')})
group by s.code, s.name_ko, e.id, e.final_end_date, c.lms_left, c.sheet_total, c.sheet_used, c.checked_at
order by s.code;
`;

mkdirSync(outDir, { recursive: true });
writeFileSync(`${outDir}/paste.sql`, sql);
writeFileSync(`${outDir}/summary.md`, rows.map((r) => r.summary.join('\n')).join('\n\n') + '\n');
writeFileSync(`${outDir}/expected.json`, JSON.stringify(rows.map((r) => r.expected), null, 2));
console.log(rows.map((r) => r.summary.join('\n')).join('\n\n'));
