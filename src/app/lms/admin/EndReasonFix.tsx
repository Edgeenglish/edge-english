'use client';

// 기존 학생 입력 때 종료일이 기간 계산과 다른데 이유를 안 고른 경우 (D-52, 2026-10-26 대표: 기록만 남기고 끝내지 않음)
// 이유 3가지 중 하나를 고르면 처리할 일에서 사라짐. 학생 장기 연기는 24주만, 기타는 메모 필수 — DB가 다시 확인

import { useState } from 'react';
import { END_REASON_TEXT, type EndReason } from '@/lms/admin/import';

export default function EndReasonFix({ weeks, onSave }: { weeks: number | null; onSave: (reason: EndReason, note: string) => Promise<void> }) {
  const [reason, setReason] = useState<EndReason | null>(null);
  const [note, setNote] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const options: EndReason[] = weeks === 24 ? ['tutor_long_term_leave', 'student_long_term_leave', 'admin_exception'] : ['tutor_long_term_leave', 'admin_exception'];
  const ready = reason !== null && (reason !== 'admin_exception' || note.trim() !== '');

  async function save() {
    if (!reason || !ready) return;
    setBusy(true);
    setError(null);
    try {
      await onSave(reason, note.trim());
    } catch (e) {
      setError(e instanceof Error ? e.message : '저장하지 못했어요.');
    } finally {
      setBusy(false);
    }
  }

  return (
    <div className="grid gap-1.5 rounded-[12px] bg-[#f6f5fb] p-2.5">
      <span className="text-[13px] text-[#1d1b2b]">종료일 변경 이유</span>
      <div className="flex flex-wrap gap-1.5">
        {options.map((r) => (
          <button
            key={r}
            type="button"
            aria-pressed={reason === r}
            onClick={() => setReason(r)}
            className={`min-h-[40px] rounded-[10px] border px-3 text-[13.5px] ${reason === r ? 'border-[#7d5fff] bg-[#efebff] font-bold text-[#5b3fe0]' : 'border-[#e6e3ef] bg-white text-[#1d1b2b]'}`}
          >
            {END_REASON_TEXT[r]}
          </button>
        ))}
      </div>
      {reason === 'admin_exception' && (
        <input
          aria-label="기타 메모"
          value={note}
          onChange={(e) => setNote(e.target.value)}
          placeholder="메모 (예: 대표 승인 연장)"
          className="min-h-[40px] rounded-[10px] border border-[#e6e3ef] bg-white px-3 text-[14px] text-[#1d1b2b]"
        />
      )}
      <button
        type="button"
        disabled={!ready || busy}
        onClick={save}
        className="min-h-[40px] w-fit rounded-[10px] border border-[#7d5fff] bg-[#7d5fff] px-3 text-[13.5px] font-semibold text-white disabled:border-[#cfc4ff] disabled:bg-[#cfc4ff]"
      >
        저장
      </button>
      {error && <span className="text-[12.5px] text-[#b3261e]">{error}</span>}
    </div>
  );
}
