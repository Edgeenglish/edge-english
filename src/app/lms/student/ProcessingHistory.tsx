'use client';

import { useState } from 'react';
import { historyLabel, historyTime, type ProcessingEvent } from '@/lms/student/processing-history';

export default function ProcessingHistory({ events, error, timezone, requestIds, onRequest }: {
  events: ProcessingEvent[]; error?: boolean; timezone: string;
  requestIds: string[]; onRequest: (id: string) => void;
}) {
  const [limit, setLimit] = useState(30);
  if (error) return <p role="alert" className="rounded-[16px] border border-[#e6e3ef] bg-white p-5 text-[14px] text-[#b3261e]">처리 내역을 불러오지 못했어요. 새로고침해 주세요.</p>;
  if (!events.length) return <p className="rounded-[16px] border border-[#e6e3ef] bg-white p-5 text-center text-[14px] text-[#6b6880]">아직 처리 내역이 없어요.</p>;
  const when = (at: string) => historyTime(at, timezone);
  return (
    <section aria-label="처리 기록" className="overflow-hidden rounded-[16px] border border-[#e6e3ef] bg-white">
      {events.slice(0, limit).map((e) => {
        const label = historyLabel(e);
        return (
          <details key={e.id} className="group border-b border-[#eeecf4] last:border-0">
            <summary className="flex min-h-[84px] cursor-pointer list-none items-center justify-between gap-3 px-4 py-4 focus-visible:outline focus-visible:outline-2 focus-visible:outline-[#5b3df0] [&::-webkit-details-marker]:hidden">
              <span className="min-w-0">
                <span className="block text-[16px] font-bold text-[#1d1b2b]">{label.title}</span>
                <time dateTime={e.at} className="mt-1 block text-[12px] text-[#6b6880]">{when(e.at)}</time>
                <span className="mt-0.5 block text-[13px] text-[#55526a]">{label.result}</span>
              </span>
              <span aria-hidden="true" className="shrink-0 text-[#8b88a0] group-open:rotate-90">›</span>
            </summary>
            <div className="grid gap-3 bg-[#faf9fc] px-4 py-4 text-[14px]">
              <dl className="grid gap-3">
                <div><dt className="text-[12px] text-[#6b6880]">처리 일시</dt><dd>{when(e.at)}</dd></div>
                <div><dt className="text-[12px] text-[#6b6880]">처리 결과</dt><dd>{label.result}</dd></div>
                {e.lesson_at && <div><dt className="text-[12px] text-[#6b6880]">{e.request_id ? '원래 수업' : '해당 수업'}</dt><dd>{when(e.lesson_at)}</dd></div>}
                {!e.lesson_at && e.original_date && <div><dt className="text-[12px] text-[#6b6880]">원래 수업 날짜 · 한국 날짜</dt><dd>{e.original_date}</dd></div>}
                {e.tutor && <div><dt className="text-[12px] text-[#6b6880]">담당 강사</dt><dd>{e.tutor}</dd></div>}
                {e.booked_at && <div><dt className="text-[12px] text-[#6b6880]">확정된 수업</dt><dd className="font-semibold">{when(e.booked_at)}</dd></div>}
                {e.slots.length > 0 && <div><dt className="text-[12px] text-[#6b6880]">{e.kind === 'tutor_suggested' ? '제안한 시간' : '신청한 시간'}</dt>
                  <dd className="grid gap-1">{e.slots.map((slot, i) => <span key={i}>{when(slot.at)}{e.kind === 'tutor_answered' && slot.answer ? ` · ${slot.answer === 'yes' ? '가능' : slot.answer === 'no' ? '불가' : '답변 대기'}` : ''}</span>)}</dd>
                </div>}
              </dl>
              {e.request_id && requestIds.includes(e.request_id) && <button type="button" onClick={() => onRequest(e.request_id!)} className="min-h-[44px] rounded-[10px] border border-[#e6e3ef] bg-white px-3 text-left font-semibold text-[#5b3df0]">현재 신청 상태 보기 ›</button>}
            </div>
          </details>
        );
      })}
      {events.length > limit && <button type="button" onClick={() => setLimit((n) => n + 30)} className="min-h-[48px] w-full text-[14px] font-semibold text-[#5b3df0]">더 보기</button>}
    </section>
  );
}
