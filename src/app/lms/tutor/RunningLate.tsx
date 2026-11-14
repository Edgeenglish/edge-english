'use client';

// 강사 '늦어요' 알림 (대표 11/14 시안 확정): [Running late] + ⓘ → 지각 시간 + 이유(선택) → Send → 회색 'Sent ✓ · about 10 min late'
// 쓰는 곳: Schedule 수업 창(Cancel class 아래) · Home 오늘 수업 줄 · Class Record 줄 펼침(Cancel class 옆)
import { useEffect, useState } from 'react';
import { Rich } from '@/app/lms/Rich';
import { enBoth } from '@/lms/admin/time-text';
import type { TutorLesson } from '@/lms/tutor/screen';
import { TUTOR_LATE, tutorLateChip, tutorLateOpen, tutorLateReasonEn, tutorLateSent, type TutorLateMinutes, type TutorLateReason } from '@/lms/tutor/late';

/** 돌려주는 값 = DB 에 저장된 기록 (다른 창에서 먼저 보냈으면 그 값) */
export type LateSend = (lessonId: string, minutes: number, reason: string | null) => Promise<{ minutes: number; reason: string | null; at: Date }>;

const sub = 'min-h-[44px] rounded-[10px] border border-[#d9d5e6] bg-white px-4 text-[14px] font-semibold text-[#1d1b2b] disabled:opacity-40';
const main = 'min-h-[44px] rounded-[10px] bg-[#5b3fe0] px-4 text-[14px] font-semibold text-white disabled:opacity-40';
const chip = (on: boolean) =>
  `min-h-[36px] rounded-full border px-3 text-[13.5px] ${on ? 'border-[#5b3fe0] bg-[#5b3fe0] font-semibold text-white' : 'border-[#d9d5e6] bg-white text-[#1d1b2b]'}`;

/** 보낼 수 있는 때(시작 2시간 전~시작 전)이거나 이미 보냈을 때만 무언가 보임. full = 버튼을 줄 너비로 (수업 창) */
export default function RunningLate({ lesson: l, now, tz, send, onSent, full = false }: {
  lesson: TutorLesson; now: Date; tz: string; send?: LateSend; onSent?: () => void | Promise<void>; full?: boolean;
}) {
  const [sentNow, setSentNow] = useState<{ minutes: number; reason: string | null; at: Date } | null>(null);
  const [open, setOpen] = useState(false);
  const [help, setHelp] = useState(false);
  const [minutes, setMinutes] = useState<TutorLateMinutes | null>(null);
  const [reason, setReason] = useState<TutorLateReason | null>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  const sent = sentNow ?? l.lateNotice ?? null;
  // 열어 둔 화면도 시각이 흐르게 (30초마다): 2시간 전이 되면 버튼이 나타나고, 시작하면 사라짐 (QA 11/14 ①)
  const [clock, setClock] = useState(() => Date.now());
  useEffect(() => {
    const id = setInterval(() => setClock(Date.now()), 30_000);
    return () => clearInterval(id);
  }, []);
  const at = new Date(Math.max(now.getTime(), clock));

  if (sent) {
    const why = tutorLateReasonEn(sent.reason);
    return (
      <div className="grid gap-1">
        <button type="button" disabled className={`${full ? 'w-full' : 'w-fit'} min-h-[44px] rounded-[10px] bg-[#ecebf2] px-4 text-[14px] font-semibold text-[#6b6880]`}>{tutorLateSent(sent.minutes)}</button>
        <p className="text-[13px] text-[#6b6880]">{why ? `${why} · ` : ''}Sent <Rich text={enBoth(sent.at, tz)} /></p>
      </div>
    );
  }
  if (!send || !tutorLateOpen(l, at)) return null;

  async function submit() {
    if (!minutes || !send) return;
    setBusy(true);
    setError('');
    try {
      setSentNow(await send(l.id, minutes, reason));
      setOpen(false);
      await onSent?.();
    } catch (e) { setError(e instanceof Error ? e.message : 'Could not send. Please try again.'); }
    finally { setBusy(false); }
  }

  return (
    <div className="grid gap-2">
      <div className="flex items-center gap-2">
        <button type="button" aria-expanded={open} onClick={() => setOpen(true)} className={`${sub} ${full ? 'flex-1' : ''}`}>Running late</button>
        <button type="button" aria-label="Info" aria-expanded={help} onClick={() => setHelp(!help)}
          className="relative inline-grid h-[20px] w-[20px] place-items-center before:absolute before:-inset-3 before:content-['']">
          <svg viewBox="0 0 20 20" className={`h-[20px] w-[20px] ${help ? 'text-[#5b3fe0]' : 'text-[#8a879c]'}`} fill="none" stroke="currentColor" strokeWidth="1.6" aria-hidden>
            <circle cx="10" cy="10" r="8.2" fill={help ? 'currentColor' : 'none'} />
            <path d="M10 9v5" stroke={help ? '#fff' : 'currentColor'} strokeLinecap="round" />
            <circle cx="10" cy="6.3" r="0.4" stroke={help ? '#fff' : 'currentColor'} strokeWidth="1.4" />
          </svg>
        </button>
      </div>
      {help && <p className="rounded-[10px] bg-[#efebff] px-3 py-2 text-[12.5px] text-[#1d1b2b]">{TUTOR_LATE.help}</p>}
      {open && (
        <div className="grid gap-2.5 rounded-[12px] border border-[#d9d5e6] bg-white p-3">
          <span className="text-[13px] font-semibold text-[#55526a]">How late?</span>
          <div className="flex flex-wrap gap-1.5">
            {TUTOR_LATE.minutes.map((m) => (
              <button key={m} type="button" aria-pressed={minutes === m} onClick={() => setMinutes(m)} className={chip(minutes === m)}>{tutorLateChip(m)}</button>
            ))}
          </div>
          <span className="text-[13px] font-semibold text-[#55526a]">Reason (optional)</span>
          <div className="flex flex-wrap gap-1.5">
            {TUTOR_LATE.reasons.map((r) => (
              <button key={r.code} type="button" aria-pressed={reason === r.code} onClick={() => setReason(reason === r.code ? null : r.code)} className={chip(reason === r.code)}>{r.label}</button>
            ))}
          </div>
          {error && <p role="alert" className="text-[14px] text-[#b3261e]">{error}</p>}
          <div className="grid grid-cols-2 gap-2">
            <button type="button" disabled={busy || !minutes} onClick={() => void submit()} className={main}>{busy ? 'Sending…' : 'Send'}</button>
            <button type="button" disabled={busy} onClick={() => { setOpen(false); setMinutes(null); setReason(null); setError(''); }} className={sub}>Back</button>
          </div>
        </div>
      )}
    </div>
  );
}
