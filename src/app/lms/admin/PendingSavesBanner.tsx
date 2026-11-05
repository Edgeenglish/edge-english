'use client';

// 저장 중 기록 띠 (R-20): 저장 중에 화면을 떠났거나 응답이 없던 저장의 결과를 운영자 화면 어디서나 보여 줌. [확인]으로 지움
import Link from 'next/link';
import { useEffect, useState } from 'react';
import { listPending, markOrphans, PENDING_STATUS_TEXT, removePending, type PendingSave } from '@/lms/admin/pending-saves';

const when = (t: number) => new Intl.DateTimeFormat('ko-KR', { timeZone: 'Asia/Seoul', hour: '2-digit', minute: '2-digit', hourCycle: 'h23' }).format(new Date(t));

export default function PendingSavesBanner() {
  const [rows, setRows] = useState<PendingSave[]>([]);
  useEffect(() => {
    const read = () => { markOrphans(); setRows(listPending()); };
    read();
    window.addEventListener('lms-pending-saves', read);
    window.addEventListener('storage', read);
    const t = setInterval(read, 2000);
    return () => { window.removeEventListener('lms-pending-saves', read); window.removeEventListener('storage', read); clearInterval(t); };
  }, []);
  if (rows.length === 0) return null;
  return (
    <div role="status" className="grid gap-1.5 border-b border-[#e6e3ef] bg-[#fff8d6] px-4 py-2 lg:px-7">
      {rows.map((p) => {
        const tone = p.status === 'ok' ? 'text-[#1e7a46]' : p.status === 'error' ? 'text-[#b3261e]' : 'text-[#5c4a00]';
        return (
          <div key={p.id} className="flex flex-wrap items-center gap-x-2 gap-y-1 text-[13.5px] text-[#1d1b2b]">
            <b>{when(p.startedAt)} {p.label}</b>
            <span className={tone}>{p.status === 'error' && p.message ? `실패: ${p.message}` : p.status === 'ok' && p.message ? p.message : PENDING_STATUS_TEXT[p.status]}</span>
            {p.status !== 'saving' && <Link href={p.href} className="font-semibold text-[#5b3fe0] underline">열기</Link>}
            {p.status !== 'saving' && (
              <button type="button" onClick={() => removePending(p.id)} className="min-h-[32px] rounded-[8px] border border-[#e6e3ef] bg-white px-2.5 text-[13px] font-semibold text-[#1d1b2b]">확인</button>
            )}
          </div>
        );
      })}
    </div>
  );
}
