'use client';

// 기존 학생 입력 때 '날짜 확인 필요'로 넣은 보강의 원래 수업 날짜 정리 (D-52 확대판, 2026-10-24 대표 결정 ④)
// 시트에서 날짜를 찾으면 넣고, 끝내 알 수 없으면 '확인 불가'로 정리 (가짜 날짜를 넣지 않음). 입력 시작일 이후 날짜는 DB가 거절

import { useState } from 'react';

export default function OriginFix({ items, onSave }: { items: { id: string; label: string }[]; onSave: (itemId: string, date: string | null) => Promise<void> }) {
  const [dates, setDates] = useState<Record<string, string>>({});
  const [busy, setBusy] = useState<string | null>(null);
  const [error, setError] = useState<Record<string, string>>({});

  async function run(id: string, date: string | null) {
    setBusy(id);
    setError((e) => ({ ...e, [id]: '' }));
    try {
      await onSave(id, date);
    } catch (e) {
      setError((x) => ({ ...x, [id]: e instanceof Error ? e.message : '저장하지 못했어요.' }));
    } finally {
      setBusy(null);
    }
  }

  return (
    <ul className="grid gap-2">
      {items.map((o) => (
        <li key={o.id} className="grid gap-1.5 rounded-[12px] bg-[#f6f5fb] p-2.5">
          <span className="text-[13px] text-[#1d1b2b]">{o.label} · 원래 수업 날짜</span>
          <div className="flex flex-wrap items-center gap-1.5">
            <input
              id={`origin-${o.id}`}
              aria-label={`${o.label} 원래 수업 날짜`}
              type="date"
              value={dates[o.id] ?? ''}
              onChange={(e) => setDates((d) => ({ ...d, [o.id]: e.target.value }))}
              className="min-h-[40px] min-w-0 flex-1 rounded-[10px] border border-[#e6e3ef] bg-white px-3 text-[14px] text-[#1d1b2b]"
            />
            <button
              type="button"
              disabled={!dates[o.id] || busy === o.id}
              onClick={() => run(o.id, dates[o.id])}
              className="min-h-[40px] rounded-[10px] border border-[#7d5fff] bg-[#7d5fff] px-3 text-[13.5px] font-semibold text-white disabled:border-[#cfc4ff] disabled:bg-[#cfc4ff]"
            >
              저장
            </button>
            <button
              type="button"
              disabled={busy === o.id}
              onClick={() => run(o.id, null)}
              className="min-h-[40px] rounded-[10px] border border-[#e6e3ef] bg-white px-3 text-[13.5px] font-semibold text-[#1d1b2b]"
            >
              시트에도 없음
            </button>
          </div>
          {error[o.id] && <span className="text-[12.5px] text-[#b3261e]">{error[o.id]}</span>}
        </li>
      ))}
    </ul>
  );
}
