'use client';

// 저장 중 기록 띠 (R-20): 저장 중에 화면을 떠났거나 응답이 없던 저장의 결과를 운영자 화면 어디서나 보여 줌.
// '확인 필요' 줄은 띠에서 바로 서버 기록과 대조 — 반영됐으면 줄을 지우고, 아니면 '저장되지 않았어요'. 저장 완료 줄은 자동으로 지우고 실패·확인 필요 줄만 [확인]으로 지움 (대표 11/10)
import Link from 'next/link';
import { useEffect, useRef, useState } from 'react';
import { listPending, markOrphans, PENDING_STATUS_TEXT, removePending, type PendingSave } from '@/lms/admin/pending-saves';
import { verifyPending } from '@/lms/admin/pending-saves-live';
import { supabaseBrowser } from '@/lms/auth/client';

const when = (t: number) => new Intl.DateTimeFormat('ko-KR', { timeZone: 'Asia/Seoul', hour: 'numeric', minute: '2-digit', hourCycle: 'h12' }).format(new Date(t));

export default function PendingSavesBanner() {
  const [rows, setRows] = useState<PendingSave[]>([]);
  const checking = useRef(new Set<string>());
  useEffect(() => {
    const read = () => { markOrphans(); setRows(listPending()); };
    read();
    window.addEventListener('lms-pending-saves', read);
    window.addEventListener('storage', read);
    const t = setInterval(read, 2000);
    return () => { window.removeEventListener('lms-pending-saves', read); window.removeEventListener('storage', read); clearInterval(t); };
  }, []);
  // 확인 필요(응답 없음·연결 끊김) 줄은 서버에서 바로 대조 — 한 줄에 한 번씩, 실패하면 10초 뒤 다시
  useEffect(() => {
    const sb = supabaseBrowser();
    if (!sb) return;
    for (const p of rows) {
      if ((p.status !== 'timeout' && p.status !== 'unknown') || p.verify.kind === 'none' || checking.current.has(p.id)) continue;
      checking.current.add(p.id);
      void verifyPending(sb, p).finally(() => setTimeout(() => checking.current.delete(p.id), 10_000));
    }
  }, [rows]);
  if (rows.length === 0) return null;
  return (
    <div role="status" className="grid gap-1.5 border-b border-[#e6e3ef] bg-[#fff8d6] px-4 py-2 lg:px-7">
      {rows.map((p) => {
        const tone = p.status === 'error' ? 'text-[#b3261e]' : 'text-[#5c4a00]';
        const text = p.status === 'error' ? (p.message ?? PENDING_STATUS_TEXT.error)
          : p.verify.kind === 'none' && p.status !== 'saving' ? '확인 필요 — 결과를 받지 못했어요. [열기]에서 직접 확인해 주세요.'
          : PENDING_STATUS_TEXT[p.status];
        return (
          <div key={p.id} className="flex flex-wrap items-center gap-x-2 gap-y-1 text-[13.5px] text-[#1d1b2b]">
            <b>{when(p.startedAt)} {p.label}</b>
            <span className={tone}>{text}</span>
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
