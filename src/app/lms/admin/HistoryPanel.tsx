'use client';

// 처리 내역 (3900): 카드 닫음(예전 이름 '처리 종료', QA C-05 2026-11-07) · 자동 제외 · 수강 종료한 카드 보기, [다시 열기]
import { useEffect, useState } from 'react';
import { HISTORY_REASON, HISTORY_STATUS, TASK_KIND_TEXT, type HistoryRow } from '@/lms/admin/task-history';

const when = (d: Date | null) =>
  d ? new Intl.DateTimeFormat('ko-KR', { timeZone: 'Asia/Seoul', month: 'numeric', day: 'numeric', hour: 'numeric', minute: '2-digit', hourCycle: 'h12' }).format(d) : '';

export default function HistoryPanel({ load, reopen, onClose, onReopened }: {
  load: () => Promise<HistoryRow[]>;
  reopen: (r: HistoryRow) => Promise<void>;
  onClose: () => void;
  onReopened: () => Promise<void>;
}) {
  const [rows, setRows] = useState<HistoryRow[] | null>(null);
  const [busy, setBusy] = useState<string | null>(null);
  const [err, setErr] = useState<string | null>(null);
  const refresh = () => load().then(setRows, (e) => setErr(e instanceof Error ? e.message : '읽지 못했어요.'));
  useEffect(() => { void refresh(); }, []); // eslint-disable-line react-hooks/exhaustive-deps

  async function open(r: HistoryRow) {
    if (!window.confirm(`${r.name ?? ''} ${TASK_KIND_TEXT[r.kind] ?? r.kind} 다시 열까요?`)) return;
    setBusy(`${r.source}:${r.taskId}`);
    setErr(null);
    try {
      await reopen(r);
      await refresh();
      await onReopened();
    } catch (e) {
      setErr(e instanceof Error ? e.message : '다시 열지 못했어요.');
    } finally {
      setBusy(null);
    }
  }

  return (
    <div className="fixed inset-0 z-40 flex items-end justify-center bg-black/40 lg:items-center" onClick={onClose}>
      <div role="dialog" aria-modal="true" aria-label="처리 내역" onClick={(e) => e.stopPropagation()}
        className="relative max-h-[88vh] w-full max-w-[640px] overflow-y-auto rounded-t-[20px] bg-[#f6f5fa] p-4 pb-8 lg:rounded-[20px]">
        <button type="button" aria-label="닫기" onClick={onClose} className="absolute right-3 top-3 h-10 w-10 rounded-full bg-white text-[18px]">✕</button>
        <h2 className="mb-3 pr-12 text-[17px] font-bold text-[#1d1b2b]">처리 내역</h2>
        {err && <p className="mb-2 text-[13px] text-[#b3261e]">{err}</p>}
        {rows === null && !err && <p className="text-[14px] text-[#6b6880]">불러오는 중…</p>}
        {rows?.length === 0 && <p className="text-[14px] text-[#6b6880]">없어요.</p>}
        <ul className="grid gap-2">
          {rows?.map((r) => (
            <li key={`${r.source}:${r.kind}:${r.taskId}`} className="grid gap-1 rounded-[12px] border border-[#e6e3ef] bg-white px-3 py-2.5">
              <div className="flex flex-wrap items-center gap-2">
                <b className="text-[15px] text-[#1d1b2b]">{r.name ?? '—'}</b>
                <span className="text-[13px] text-[#55526a]">{TASK_KIND_TEXT[r.kind] ?? r.kind}</span>
                <span className={`rounded-full px-2 py-0.5 text-[12px] font-bold ${r.source === 'auto' ? 'bg-[#fff1d6] text-[#8a5300]' : r.source === 'checked' ? 'bg-[#e3f5ea] text-[#13623a]' : 'bg-[#efebff] text-[#2b1c7a]'}`}>{r.source === 'closed' && r.kind === 'extension_review' ? '연장 안 함' : HISTORY_STATUS[r.source]}</span>
              </div>
              <p className="text-[12.5px] text-[#6b6880]">{[when(r.at), r.by ?? (r.source === 'auto' ? '자동' : ''), r.source === 'closed' && r.kind === 'extension_review' ? '' : HISTORY_REASON[r.source]].filter(Boolean).join(' · ')}</p>
              <button type="button" disabled={!!busy} onClick={() => void open(r)}
                className="min-h-[40px] justify-self-start rounded-[10px] border border-[#e6e3ef] px-3 text-[13.5px] font-semibold text-[#1d1b2b] disabled:opacity-50">
                {busy === `${r.source}:${r.taskId}` ? '여는 중…' : '다시 열기'}
              </button>
            </li>
          ))}
        </ul>
      </div>
    </div>
  );
}
