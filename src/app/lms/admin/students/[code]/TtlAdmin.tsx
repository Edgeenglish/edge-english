'use client';

// 강사 임시 근무 지역 변경 → 새 수업 시간 고르기: 운영진 확인 회차 (H26(218), migration 20261123140000)
//  확정 직전 검사에 걸렸거나 학생·강사가 운영진에게 맡긴 회차만. [확정] = 같은 검사로 넣음(같은 주 안), [다른 방법으로 처리함] = 이 목록에서만 뺌
import { useEffect, useState } from 'react';
import { ampmKo, formatInZone, kstToInstant, type KstDate, type KstTime } from '@/lms/rules/dates';
import { ttlConflictText } from '@/app/lms/TtlSheet';
import { btnSmall } from './parts';
import DateInput from '../../DateInput';

export type TtlAdminRow = { id: string; studentId: string; tutor: string; city: string; orig: Date; newAt: Date | null; conflict: string | null };
export type TtlAdminActions = { list: () => Promise<TtlAdminRow[]>; resolve: (id: string, startsAt: string | null) => Promise<void> };

const kstText = (t: Date) => {
  const f = formatInZone(t, 'Asia/Seoul');
  return `${Number(f.date.slice(5, 7))}/${Number(f.date.slice(8))}(${'일월화수목금토'[new Date(`${f.date}T00:00:00Z`).getUTCDay()]}) ${ampmKo(f.time)} 한국 시간`;
};
const TIMES = Array.from({ length: 48 }, (_, i) => `${String(Math.floor(i / 2)).padStart(2, '0')}:${i % 2 ? '30' : '00'}`);

function RowView({ r, actions, onDone }: { r: TtlAdminRow; actions: TtlAdminActions; onDone: () => void }) {
  const start = formatInZone(r.newAt ?? r.orig, 'Asia/Seoul');
  const [date, setDate] = useState<string>(start.date);
  const [time, setTime] = useState<string>(start.time.slice(0, 5));
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState('');
  async function go(iso: string | null) {
    setBusy(true); setErr('');
    try { await actions.resolve(r.id, iso); onDone(); } catch (e) { setErr((e as Error).message); } finally { setBusy(false); }
  }
  return (
    <div className="grid gap-1.5 border-t border-[#f3c9c5] py-2 first:border-0">
      <p className="text-[#1d1b2b]">원래 {kstText(r.orig)} · {r.tutor} ({r.city})</p>
      <p className="text-[12.5px] text-[#55526a]">{r.newAt ? `신청 ${kstText(r.newAt)} · ` : ''}{ttlConflictText(r.conflict, false)}</p>
      <div className="flex flex-wrap items-center gap-1.5">
        <DateInput aria-label="새 날짜" value={date as KstDate} onChange={(d) => setDate(d)} className="min-h-[38px] rounded-[8px] border border-[#e6e3ef] bg-white px-2 text-[14px]" />
        <select aria-label="새 시간" value={time} onChange={(e) => setTime(e.target.value)} className="min-h-[38px] rounded-[8px] border border-[#e6e3ef] bg-white px-2 text-[14px]">
          {TIMES.map((t) => <option key={t} value={t}>{ampmKo(t)}</option>)}
        </select>
        <span className="text-[12.5px] text-[#55526a]">한국 시간</span>
        <button type="button" className={btnSmall} disabled={busy || !date} onClick={() => void go(kstToInstant(date as KstDate, time as KstTime).toISOString())}>확정</button>
        <button type="button" className={btnSmall} disabled={busy} onClick={() => void go(null)}>다른 방법으로 처리함</button>
      </div>
      {err && <p className="text-[12.5px] text-[#b3261e]">{err}</p>}
    </div>
  );
}

export default function TtlAdmin({ studentId, actions }: { studentId: string; actions: TtlAdminActions }) {
  const [rows, setRows] = useState<TtlAdminRow[]>([]);
  const load = () => { actions.list().then((x) => setRows(x.filter((r) => r.studentId === studentId)), () => setRows([])); };
  useEffect(load, [actions, studentId]);
  if (rows.length === 0) return null;
  return (
    <div className="mt-2 rounded-[10px] bg-[#fdecea] px-3 py-2 text-[13px]">
      <p className="font-bold text-[#b3261e]">⚠️ 임시 근무 지역 변경 · 운영진 확인 {rows.length}회</p>
      {rows.map((r) => <RowView key={r.id} r={r} actions={actions} onDone={load} />)}
    </div>
  );
}
