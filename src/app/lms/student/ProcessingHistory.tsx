'use client';

import { useState } from 'react';
import { historyLines, historySlots, historyTime, requestStatus, visibleEvents, type ProcessingEvent } from '@/lms/student/processing-history';

export default function ProcessingHistory({ events, error, timezone }: {
  events: ProcessingEvent[]; error?: boolean; timezone: string;
  requestIds?: string[]; onRequest?: (id: string) => void;
}) {
  const [limit, setLimit] = useState(30);
  const [oldestFirst, setOldestFirst] = useState(false);
  if (error) return <p role="alert" className="rounded-[16px] border border-[#e6e3ef] bg-white p-5 text-[14px] text-[#b3261e]">처리 내역을 불러오지 못했어요. 새로고침해 주세요.</p>;
  const rows = visibleEvents(events);
  if (!rows.length) return <p className="rounded-[16px] border border-[#e6e3ef] bg-white p-5 text-center text-[14px] text-[#6b6880]">아직 처리 내역이 없어요.</p>;
  const when = (at: string) => historyTime(at, timezone);
  // 같은 시각 기록은 순서를 뒤집어 '신청 → 확인 대기 → 확정' 순으로 (오래된 순)
  const ordered = oldestFirst ? [...rows].reverse() : rows;
  const shown = oldestFirst ? ordered : ordered.slice(0, limit);
  const sortBtn = (asc: boolean, text: string) => (
    <button type="button" aria-pressed={oldestFirst === asc} onClick={() => setOldestFirst(asc)}
      className={`min-h-[32px] rounded-full px-3 text-[12px] font-semibold ${oldestFirst === asc ? 'bg-[#5b3df0] text-white' : 'border border-[#d9d5e8] text-[#55526a]'}`}>{text}</button>
  );
  return (
    <>
    <div className="flex justify-end gap-1.5 pb-2">{sortBtn(false, '최신순')}{sortBtn(true, '오래된순')}</div>
    <section aria-label="처리 기록" className="overflow-hidden rounded-[16px] border border-[#e6e3ef] bg-white">
      {shown.map((e) => {
        const lines = historyLines(e, timezone, requestStatus(e, events));
        const sl = historySlots(e, events);
        const head = (
          <>
            <span className="text-[14px] font-bold leading-5 text-[#1d1b2b]">{lines.title}</span>
            <time dateTime={e.at} className="whitespace-nowrap text-right text-[11px] leading-5 text-[#6b6880]">{when(e.at)}</time>
          </>
        );
        const text = <span>{lines.detail}{lines.status && <><br />상태 : {lines.status}</>}</span>;
        if (sl.requested.length === 0 && sl.suggested.length === 0 && !sl.confirmedExtra) {
          return (
            <div key={e.id} className="grid min-h-[64px] grid-cols-[minmax(0,1fr)_auto] items-start gap-x-2 gap-y-1 border-b border-[#eeecf4] px-3 py-2.5 last:border-0 sm:px-4">
              {head}
              <span className="col-span-2 text-[12px] leading-[18px] text-[#55526a]">{text}</span>
            </div>
          );
        }
        const list = (items: { at: string; ok: boolean }[]) => (
          <ol className="grid gap-1">
            {items.map((x, i) => (
              <li key={i} className={`flex items-baseline gap-1.5 ${x.ok ? 'font-bold' : ''}`}>
                <span aria-hidden="true">{'①②③'[i] ?? i + 1}</span><span>{when(x.at)}</span>
                {x.ok && <span className="text-[12px] font-bold text-[#1f7a4d]">✓ 확정</span>}
              </li>
            ))}
          </ol>
        );
        return (
          <details key={e.id} className="group border-b border-[#eeecf4] last:border-0">
            <summary className="grid min-h-[64px] cursor-pointer list-none grid-cols-[minmax(0,1fr)_auto] items-start gap-x-2 gap-y-1 px-3 py-2.5 sm:px-4 focus-visible:outline focus-visible:outline-2 focus-visible:outline-[#5b3df0] [&::-webkit-details-marker]:hidden">
              {head}
              <span className="col-span-2 flex items-start justify-between gap-2 text-[12px] leading-[18px] text-[#55526a]">
                {text}
                <span aria-hidden="true" className="shrink-0 text-[#8b88a0] group-open:rotate-90">›</span>
              </span>
            </summary>
            <div className="grid gap-2 bg-[#faf9fc] px-3 py-2.5 text-[13px] sm:px-4">
              {sl.requested.length > 0 && <div className="grid gap-1"><p className="text-[12px] text-[#6b6880]">신청한 보강 시간</p>{list(sl.requested)}</div>}
              {sl.suggested.length > 0 && <div className="grid gap-1"><p className="text-[12px] text-[#6b6880]">강사가 제안한 시간</p>{list(sl.suggested.map((at) => ({ at, ok: false })))}</div>}
              {sl.confirmedExtra && <div className="grid gap-1"><p className="text-[12px] text-[#6b6880]">확정된 보강 시간</p><p className="font-bold">{when(sl.confirmedExtra)} <span className="text-[12px] text-[#1f7a4d]">✓ 확정</span></p></div>}
            </div>
          </details>
        );
      })}
      {!oldestFirst && rows.length > limit && <button type="button" onClick={() => setLimit((n) => n + 30)} className="min-h-[48px] w-full text-[14px] font-semibold text-[#5b3df0]">더 보기</button>}
    </section>
    </>
  );
}
