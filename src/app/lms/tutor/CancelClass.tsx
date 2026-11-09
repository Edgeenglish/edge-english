'use client';

import { useRef, useState } from 'react';
import type { TutorCancelDecision } from '@/lms/tutor/live';

export type CancelAction = (lessonId: string, requestId: string, reason: string, dryRun: boolean) => Promise<TutorCancelDecision>;

export default function CancelClass({ lessonId, cancel, onSaved, onDirty }: {
  lessonId: string; cancel: CancelAction; onSaved: () => Promise<void>; onDirty: (dirty: boolean) => void;
}) {
  const request = useRef<string | null>(null);
  const [decision, setDecision] = useState<TutorCancelDecision | null>(null);
  const [reason, setReason] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  async function submit(dryRun: boolean) {
    setBusy(true);
    setError('');
    try {
      request.current ??= crypto.randomUUID();
      const result = await cancel(lessonId, request.current, reason, dryRun);
      if (dryRun) setDecision(result);
      else { onDirty(false); await onSaved(); }
    } catch (e) { setError(e instanceof Error ? e.message : 'Could not cancel. Please try again.'); }
    finally { setBusy(false); }
  }
  return (
    <div className="grid gap-3">
      {!decision ? <button type="button" disabled={busy} onClick={() => void submit(true)} className="min-h-[44px] w-fit rounded-[10px] border border-[#d9d5e6] bg-white px-4 text-[14px] font-semibold disabled:opacity-40">{busy ? 'Loading…' : 'Cancel class'}</button> : <>
        <p className="text-[14px] font-semibold">{decision.status}</p>
        <label className="grid gap-1 text-[13px] font-semibold text-[#55526a]">Reason
          <textarea aria-label="Cancellation reason" rows={2} maxLength={500} value={reason} onChange={(e) => { setReason(e.target.value); onDirty(!!e.target.value.trim()); }} className="w-full rounded-[10px] border border-[#d9d5e6] bg-white px-3 py-2.5 text-[16px] font-normal text-[#1d1b2b]" />
        </label>
        <div className="flex flex-wrap gap-2">
          <button type="button" disabled={busy || !reason.trim()} onClick={() => void submit(false)} className="min-h-[44px] rounded-[10px] bg-[#5b3fe0] px-4 text-[14px] font-semibold text-white disabled:opacity-40">{busy ? 'Saving…' : 'Confirm cancellation'}</button>
          <button type="button" disabled={busy} onClick={() => { setDecision(null); setReason(''); onDirty(false); }} className="min-h-[44px] rounded-[10px] border border-[#d9d5e6] bg-white px-4 text-[14px] font-semibold">Back</button>
        </div>
      </>}
      {error && <p role="alert" className="text-[14px] text-[#b3261e]">{error}</p>}
    </div>
  );
}
