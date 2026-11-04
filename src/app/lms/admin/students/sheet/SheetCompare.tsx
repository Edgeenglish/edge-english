'use client';

// ⑤ 시트 Student Info 비교·승인 (H26(44) ⑤ B안): 시트 줄마다 LMS 학생을 짝지어 시트 값 ↔ LMS 값을 나란히 → 체크한 칸만 반영.
// 시트는 Claude 가 읽어 넣은 사본(sheet_student_info). LMS 에 값이 있는 칸은 기본 체크 안 함(덮어쓰기 방지). 일정·회차·기간은 참고만
import Link from 'next/link';
import { useEffect, useMemo, useState } from 'react';
import { compareRow, defaultPick, fieldsFromChosen, filterRows, kstDay, referenceLines, type CompareItem, type SheetFilter, type SheetRow } from '@/lms/admin/sheet-compare';
import { md, type StudentDetailData, type StudentRow } from '@/lms/admin/students';
import { AdminHeader, BottomNav, Icon } from '../../ui';
import { btnMain, btnSmall, btnSub, input } from '../[code]/parts';

export type SheetActions = {
  reload: () => Promise<void>;
  detail: (studentId: string) => Promise<StudentDetailData>;
  match: (rowId: string, studentId: string | null) => Promise<void>;
  update: (studentId: string, fields: Record<string, string | null>) => Promise<number>;
  done: (rowId: string, note: string, undo?: boolean) => Promise<void>;
};

const TABS: { key: SheetFilter; label: string }[] = [{ key: 'todo', label: '할 일' }, { key: 'done', label: '끝남' }, { key: 'all', label: '전체' }];

export default function SheetCompare({ rows, students, actions, studentFilter }: { rows: SheetRow[]; students: StudentRow[]; actions: SheetActions; studentFilter: string | null }) {
  const [tab, setTab] = useState<SheetFilter>('todo');
  const [q, setQ] = useState('');
  const [open, setOpen] = useState<string | null>(null);
  const byId = useMemo(() => new Map(students.map((s) => [s.id, s])), [students]);
  // 이 화면에서 끝낸 줄은 '할 일'에서 바로 사라지지 않고 ✓ 로 남음 (대표 10/28: 처리한 것은 사라지지 않게)
  const [todoAtStart] = useState(() => new Set(rows.filter((r) => !r.doneAt).map((r) => r.id)));
  // 학생 한 명 보기(?student=)는 끝난 줄도 모두
  const list = studentFilter ? filterRows(rows, 'all', '', studentFilter) : tab === 'todo' ? filterRows(rows, 'all', q).filter((r) => !r.doneAt || todoAtStart.has(r.id)) : filterRows(rows, tab, q);
  const counts = { todo: rows.filter((r) => !r.doneAt).length, done: rows.filter((r) => !!r.doneAt).length, all: rows.length };
  const sheets = [...new Set(list.map((r) => r.sheet))];
  const student = studentFilter ? byId.get(studentFilter) : null;
  const imported = rows.length ? rows.reduce((a, r) => (r.importedAt > a ? r.importedAt : a), rows[0].importedAt) : null;
  return (
    <div className="mx-auto min-h-dvh max-w-[1280px] pb-24 lg:pb-8">
      <AdminHeader active="students" demo={false} />
      <div className="grid gap-3 px-4 pt-3 lg:px-7">
        <Link href={student ? `/lms/admin/students/${student.code}` : '/lms/admin/students'} className="flex min-h-[36px] w-fit items-center gap-1 text-[13px] font-semibold text-[#5b3fe0]">
          <Icon name="chevron" className="h-4 w-4 rotate-180" /> {student ? `${student.nameKo} 상세` : '학생 목록'}
        </Link>
        <div>
          <h1 className="text-[18px] font-bold text-[#1d1b2b]">시트 Student Info 비교{student ? ` · ${student.nameKo}` : ''}</h1>
          <p className="text-[12.5px] text-[#6b6880]">강사 Class Record 시트 ‘Student Info’ 사본{imported ? ` (${md(kstDay(imported))} 읽음)` : ''} · 시트는 읽기만, 체크한 칸만 LMS에 넣어요</p>
        </div>
        {!studentFilter && (
          <>
            <div role="tablist" aria-label="상태" className="flex flex-wrap gap-1.5">
              {TABS.map((t) => (
                <button key={t.key} type="button" role="tab" aria-selected={tab === t.key} onClick={() => setTab(t.key)}
                  className={`min-h-[40px] rounded-full px-3.5 text-[13.5px] font-semibold ${tab === t.key ? 'bg-[#1b1442] text-white' : 'border border-[#e6e3ef] bg-white text-[#1d1b2b]'}`}>
                  {t.label} <span className={tab === t.key ? 'text-[#c9c0ff]' : 'text-[#6b6880]'}>{counts[t.key]}</span>
                </button>
              ))}
            </div>
            <label className="flex min-h-[48px] items-center gap-2 rounded-[12px] border border-[#e6e3ef] bg-white px-3">
              <Icon name="search" className="h-[18px] w-[18px] text-[#6b6880]" />
              <span className="sr-only">찾기</span>
              <input type="search" value={q} onChange={(e) => setQ(e.target.value)} placeholder="시트 이름, 학생 이름, 이메일" className="min-w-0 flex-1 bg-transparent text-[16px] text-[#1d1b2b] outline-none" />
            </label>
          </>
        )}
        {rows.length === 0 && <p className="rounded-[14px] border border-[#e6e3ef] bg-white px-4 py-8 text-center text-[14px] text-[#6b6880]">읽어 둔 시트 줄이 없어요. (Claude가 시트를 읽어 넣으면 여기에 보여요)</p>}
        {rows.length > 0 && list.length === 0 && <p className="rounded-[14px] border border-[#e6e3ef] bg-white px-4 py-8 text-center text-[14px] text-[#6b6880]">해당하는 줄이 없어요.</p>}
        {sheets.map((sh) => (
          <section key={sh} className="grid min-w-0 grid-cols-[minmax(0,1fr)] gap-2">
            <h2 className="text-[13px] font-extrabold tracking-wider text-[#6b6880]">{sh}</h2>
            {list.filter((r) => r.sheet === sh).map((r) => (
              <RowCard key={r.id} r={r} students={students} byId={byId} actions={actions} open={open === r.id} onToggle={() => setOpen(open === r.id ? null : r.id)} />
            ))}
          </section>
        ))}
      </div>
      <BottomNav active="students" demo={false} />
    </div>
  );
}

function RowCard({ r, students, byId, actions, open, onToggle }: { r: SheetRow; students: StudentRow[]; byId: Map<string, StudentRow>; actions: SheetActions; open: boolean; onToggle: () => void }) {
  const matched = r.studentId ? byId.get(r.studentId) ?? null : null;
  const suggested = !r.studentId && r.suggest ? byId.get(r.suggest.studentId) ?? null : null;
  const [busy, setBusy] = useState('');
  const [err, setErr] = useState('');
  const [pickId, setPickId] = useState('');
  async function run(label: string, f: () => Promise<void>) {
    setBusy(label);
    setErr('');
    try { await f(); await actions.reload(); } catch (e) { setErr(e instanceof Error ? e.message : '처리하지 못했어요.'); } finally { setBusy(''); }
  }
  const head = (
    <button type="button" onClick={onToggle} aria-expanded={open} className="flex w-full items-center gap-3 px-4 py-3 text-left">
      <span className="min-w-0 flex-1">
        <span className="flex flex-wrap items-center gap-1.5">
          <b className="text-[15px] text-[#1d1b2b]">{r.studentName || '(이름 없음)'}</b>
          {r.preferredName && <span className="text-[12.5px] text-[#6b6880]">“{r.preferredName}”</span>}
          <span className="text-[12px] text-[#6b6880]">{r.sheet} {r.rowNo}줄 · {r.status ?? ''}</span>
          {r.doneAt ? <span className="rounded-full bg-[#e3f5ea] px-2 py-0.5 text-[11.5px] font-bold text-[#13623a]">✓ {r.doneNote ?? '끝'}</span>
            : matched ? <span className="rounded-full bg-[#efebff] px-2 py-0.5 text-[11.5px] font-bold text-[#5b3fe0]">짝: {matched.nameKo} ({matched.code})</span>
            : suggested ? <span className="rounded-full bg-[#fff1d6] px-2 py-0.5 text-[11.5px] font-bold text-[#8a5300]">짝 확인 필요: {suggested.nameKo} ({suggested.code})?</span>
            : <span className="rounded-full bg-[#f0eef6] px-2 py-0.5 text-[11.5px] font-bold text-[#6b6880]">LMS 학생 고르기</span>}
        </span>
        <span className="block truncate text-[12.5px] text-[#6b6880]">{[r.residence, r.email, r.level ? `레벨 ${r.level}` : null, r.classType].filter(Boolean).join(' · ')}</span>
      </span>
      <Icon name="chevron" className={`h-4 w-4 text-[#b9b6c8] ${open ? 'rotate-90' : ''}`} />
    </button>
  );
  return (
    <div className="min-w-0 overflow-hidden rounded-[14px] border border-[#e6e3ef] bg-white">
      {head}
      {open && (
        <div className="border-t border-[#f0eef6] px-4 pb-4 pt-3">
          {!matched && (
            <div className="grid gap-2">
              {suggested && (
                <div className="flex flex-wrap items-center gap-2 rounded-[10px] bg-[#fff8e6] px-3 py-2 text-[13.5px]">
                  <span>{r.suggest?.how === 'name_ko' ? '한국 이름이 같은' : '영문 이름이 같은'} LMS 학생: <b>{suggested.nameKo} ({suggested.nameEn} · {suggested.code})</b></span>
                  <button type="button" className={btnSmall} disabled={!!busy} onClick={() => run('match', () => actions.match(r.id, suggested.id))}>이 학생 맞음</button>
                </div>
              )}
              <div className="flex flex-wrap items-center gap-2">
                <select value={pickId} onChange={(e) => setPickId(e.target.value)} className={`${input} max-w-[360px]`} aria-label="LMS 학생 고르기">
                  <option value="">LMS 학생 고르기…</option>
                  {students.map((s) => <option key={s.id} value={s.id}>{s.nameKo} ({s.nameEn} · {s.code})</option>)}
                </select>
                <button type="button" className={btnSub} disabled={!pickId || !!busy} onClick={() => run('match', () => actions.match(r.id, pickId))}>짝 정하기</button>
                {!r.doneAt && <button type="button" className={btnSub} disabled={!!busy} onClick={() => run('done', () => actions.done(r.id, 'LMS 학생 없음 · 반영 안 함'))}>LMS에 없는 학생 (반영 안 함)</button>}
              </div>
            </div>
          )}
          {matched && <Compare r={r} student={matched} actions={actions} busy={busy} run={run} />}
          <details className="mt-3 text-[12.5px] text-[#6b6880]">
            <summary className="cursor-pointer font-semibold">시트의 일정·회차·기간 (참고 — LMS 값이 원본이라 넣지 않아요)</summary>
            <ul className="mt-1 grid gap-0.5">{referenceLines(r).map(([k, v]) => <li key={k}><span className="text-[#8a879c]">{k}:</span> {v}</li>)}</ul>
          </details>
          {err && <p className="mt-2 rounded-[10px] bg-[#fdecea] px-3 py-2 text-[13.5px] text-[#b3261e]">{err}</p>}
        </div>
      )}
    </div>
  );
}

function Compare({ r, student, actions, busy, run }: { r: SheetRow; student: StudentRow; actions: SheetActions; busy: string; run: (l: string, f: () => Promise<void>) => Promise<void> }) {
  const [detail, setDetail] = useState<StudentDetailData | null>(null);
  const [loadErr, setLoadErr] = useState('');
  const [pick, setPick] = useState<Record<string, boolean>>({});
  useEffect(() => {
    let alive = true;
    setDetail(null);
    actions.detail(student.id).then((d) => { if (alive) setDetail(d); }).catch((e) => { if (alive) setLoadErr(e instanceof Error ? e.message : '불러오지 못했어요.'); });
    return () => { alive = false; };
  }, [student.id, actions, r.doneAt]);
  if (loadErr) return <p className="rounded-[10px] bg-[#fdecea] px-3 py-2 text-[13.5px] text-[#b3261e]">{loadErr}</p>;
  if (!detail) return <p className="py-3 text-[13.5px] text-[#6b6880]">LMS 값 불러오는 중…</p>;
  const items = compareRow(r, detail.student);
  const on = (it: CompareItem) => pick[it.field] ?? defaultPick(it);
  const chosen = items.filter((it) => !it.same && it.importable && on(it));
  const allSame = items.every((it) => it.same);
  return (
    <div className="grid gap-2">
      <div className="flex flex-wrap items-center justify-between gap-2 text-[13.5px]">
        <span>짝: <b>{student.nameKo} ({student.nameEn} · {student.code})</b></span>
        {!r.doneAt && <button type="button" className="text-[12.5px] font-semibold text-[#6b6880] underline" disabled={!!busy} onClick={() => run('match', () => actions.match(r.id, null))}>짝 풀기</button>}
      </div>
      <div className="overflow-hidden rounded-[12px] border border-[#e6e3ef]">
        <div className="grid grid-cols-[64px_1fr_1fr] gap-2 border-b border-[#e6e3ef] bg-[#f7f6fb] px-3 py-2 text-[12.5px] font-bold text-[#6b6880]">
          <span>넣기</span><span>시트 값</span><span>LMS 지금 값</span>
        </div>
        {items.map((it) => (
          <label key={it.field} className={`grid grid-cols-[64px_1fr_1fr] gap-2 border-b border-[#f0eef6] px-3 py-2 text-[13px] last:border-0 ${it.same ? 'text-[#6b6880]' : 'text-[#1d1b2b]'}`}>
            <span>
              {it.same ? <span className="text-[12px]">같음</span> : !it.importable ? <span className="text-[12px]">못 넣음</span>
                : <input type="checkbox" checked={on(it)} disabled={!!r.doneAt} onChange={(e) => setPick({ ...pick, [it.field]: e.target.checked })} className="h-[18px] w-[18px] accent-[#5b3fe0]" />}
              <span className="block text-[11px] font-semibold text-[#6b6880]">{it.title}</span>
            </span>
            <span className="whitespace-pre-wrap break-words">{it.sheet}{it.note && <span className="block text-[11.5px] text-[#a35b00]">{it.note}</span>}</span>
            <span className="whitespace-pre-wrap break-words">{it.lms || <i className="text-[#b9b6c8]">비어 있음</i>}</span>
          </label>
        ))}
        {items.length === 0 && <p className="px-3 py-3 text-[13px] text-[#6b6880]">시트에 넣을 값이 없어요.</p>}
      </div>
      {r.doneAt ? (
        <div className="flex flex-wrap items-center gap-2 text-[13px] text-[#13623a]">
          ✓ {r.doneNote ?? '끝'} · {md(kstDay(r.doneAt))}
          <button type="button" className={btnSmall} disabled={!!busy} onClick={() => run('undo', () => actions.done(r.id, '', true))}>다시 열기</button>
          <Link href={`/lms/admin/students/${student.code}`} className={btnSmall}>학생 상세 ›</Link>
        </div>
      ) : (
        <div className="flex flex-wrap gap-2">
          <button type="button" className={`${btnMain} flex-1`} disabled={chosen.length === 0 || !!busy}
            onClick={() => run('apply', async () => { await actions.update(student.id, fieldsFromChosen(chosen)); await actions.done(r.id, `${chosen.length}칸 반영`); })}>
            {busy === 'apply' ? '넣는 중…' : `체크한 ${chosen.length}칸 LMS에 넣기`}
          </button>
          <button type="button" className={btnSub} disabled={!!busy} onClick={() => run('done', () => actions.done(r.id, allSame ? '이미 같음' : '반영 안 함'))}>{allSame ? '이미 같음 · 끝' : '반영 안 함'}</button>
        </div>
      )}
    </div>
  );
}
