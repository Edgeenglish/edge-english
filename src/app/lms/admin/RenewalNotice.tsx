'use client';

// 종료 임박 카드: 재등록 안내 문자 [복사] → 문자로 보낸 뒤 [보냄]. 누른 버튼은 회색 '복사함 ✓'·'보냄 ✓'로 남음 (다른 화면과 같게)
// 글은 [글 보기]를 눌렀을 때만 펼침 (대시보드가 글로 길어지지 않게). 복사가 막힌 기기면 자동으로 펼침

import { useState } from 'react';

export default function RenewalNotice({ text, sentAt, onSent }: { text: string; sentAt: Date | null; onSent: () => Promise<void> }) {
  const [copied, setCopied] = useState(false);
  const [open, setOpen] = useState(false);
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  const grey = 'border-[#c9c6d6] bg-[#d9d6e3] font-bold text-[#4a4760]';

  async function copy() {
    try {
      await navigator.clipboard.writeText(text);
      setCopied(true);
    } catch {
      setOpen(true);
      setErr('복사가 안 되는 기기예요. 아래 글을 길게 눌러 복사해 주세요.');
    }
  }
  async function sent() {
    setBusy(true);
    setErr(null);
    try {
      await onSent();
    } catch (e) {
      setErr(e instanceof Error ? e.message : '기록하지 못했어요.');
    } finally {
      setBusy(false);
    }
  }

  return (
    <div className="grid gap-2 rounded-[12px] border border-[#e6e3ef] bg-[#faf9fd] p-3">
      <div className="flex items-center gap-2">
        <b className="text-[14px] text-[#1d1b2b]">재등록 안내 문자</b>
        <button type="button" onClick={() => setOpen(!open)} className="mr-auto min-h-[44px] px-1 text-[13px] font-semibold text-[#5b3fe0]">
          {open ? '글 닫기' : '글 보기'}
        </button>
        <button type="button" onClick={copy} className={`min-h-[44px] rounded-[10px] border px-3 text-[14px] ${copied ? grey : 'border-[#e6e3ef] bg-white text-[#1d1b2b]'}`}>
          {copied ? '복사함 ✓' : '복사'}
        </button>
        {sentAt ? (
          <button type="button" disabled className={`min-h-[44px] rounded-[10px] border px-3 text-[14px] ${grey}`}>
            보냄 ✓
          </button>
        ) : (
          <button type="button" disabled={busy} onClick={sent} className="min-h-[44px] rounded-[10px] bg-[#7d5ffb] px-3 text-[14px] font-bold text-white disabled:bg-[#cfc4ff]">
            보냄
          </button>
        )}
      </div>
      {open && <p className="whitespace-pre-wrap text-[13.5px] leading-relaxed text-[#1d1b2b]">{text}</p>}
      {err && <p className="text-[13px] text-[#b3261e]">{err}</p>}
    </div>
  );
}
