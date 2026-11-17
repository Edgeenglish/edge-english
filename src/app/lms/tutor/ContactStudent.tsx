'use client';

// 강사 [학생에게 연락하기] (H26(197), 대표 11/16 시안 3판): 시작 5분 뒤 [Contact student] → 한마디(선택, 150자) → Send → 회색 'Email sent ✓'
// 수업 절반 뒤 [Contact student again] → 'Email sent ✓' 대신 회색 '2nd email sent ✓'. 쓰는 곳: Home 오늘 수업 · Schedule 수업 창 · Class Record 줄 펼침 ('늦어요'와 같은 자리)
import { useEffect, useState } from 'react';
import { Rich } from '@/app/lms/Rich';
import { enBoth } from '@/lms/admin/time-text';
import type { TutorLesson } from '@/lms/tutor/screen';
import { TUTOR_CONTACT, contactGist, contactStageOpen, type ContactSent, type ContactStage } from '@/lms/tutor/contact';

/** 돌려주는 값 = DB 에 저장된 이 수업의 연락 기록 */
export type ContactSend = (lessonId: string, stage: ContactStage, note: string) => Promise<ContactSent[]>;

const sub = 'min-h-[44px] rounded-[10px] border border-[#d9d5e6] bg-white px-4 text-[14px] font-semibold text-[#1d1b2b] disabled:opacity-40';
const main = 'min-h-[44px] rounded-[10px] bg-[#5b3fe0] px-4 text-[14px] font-semibold text-white disabled:opacity-40';

/** 보낼 수 있는 때이거나 이미 보냈을 때만 무언가 보임. full = 버튼을 줄 너비로 (수업 창). admin = 운영자 보기(누가 보냈는지 둘 다 표시) */
export default function ContactStudent({ lesson: l, now, tz, tutorName, send, onSent, full = false, admin = false }: {
  lesson: TutorLesson; now: Date; tz: string; tutorName?: string; send?: ContactSend; onSent?: () => void | Promise<void>; full?: boolean; admin?: boolean;
}) {
  const [sentNow, setSentNow] = useState<ContactSent[] | null>(null);
  const [open, setOpen] = useState(false);
  const [note, setNote] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  const sent = sentNow ?? l.contacts ?? [];
  // 열어 둔 화면도 시각이 흐르게 (30초마다): 시작 5분 뒤·절반 뒤 버튼이 나타나고, 끝나면 사라짐
  const [clock, setClock] = useState(() => Date.now());
  useEffect(() => {
    const id = setInterval(() => setClock(Date.now()), 30_000);
    return () => clearInterval(id);
  }, []);
  const at = new Date(Math.max(now.getTime(), clock));
  const stage = send ? contactStageOpen(l, sent, at) : null;
  if (!sent.length && !stage) return null;

  const w = full ? 'w-full' : 'w-fit';
  const by = (x: ContactSent) => (x.byAdmin ? ' · by Edge English' : admin ? ' · by tutor' : '');
  const two = sent.find((x) => x.stage === 2);

  async function submit() {
    if (!send || !stage) return;
    setBusy(true);
    setError('');
    try {
      setSentNow(await send(l.id, stage, note));
      setOpen(false);
      setNote('');
      await onSent?.();
    } catch (e) { setError(e instanceof Error ? e.message : 'Could not send. Please try again.'); }
    finally { setBusy(false); }
  }

  return (
    <div className="grid gap-2">
      {sent.length > 0 && (
        <div className="grid gap-1">
          <button type="button" disabled className={`${w} min-h-[44px] rounded-[10px] bg-[#ecebf2] px-4 text-[14px] font-semibold text-[#6b6880]`}>{two ? '2nd email sent ✓' : 'Email sent ✓'}</button>
          {[...sent].sort((a, b) => a.stage - b.stage).map((x) => (
            <p key={x.stage} className="text-[13px] text-[#6b6880]">{two ? `${x.stage === 1 ? '1st' : '2nd'} email · ` : ''}Sent <Rich text={enBoth(x.at, tz)} />{by(x)}</p>
          ))}
        </div>
      )}
      {stage && !open && (
        <button type="button" aria-expanded={false} onClick={() => setOpen(true)} className={`${sub} ${w}`}>{stage === 1 ? 'Contact student' : 'Contact student again'}</button>
      )}
      {stage && open && (
        <div className="grid gap-2.5 rounded-[12px] border border-[#d9d5e6] bg-white p-3">
          <span className="text-[13px] font-semibold text-[#55526a]">Email to student (in Korean)</span>
          <p className="rounded-[10px] bg-[#efebff] px-3 py-2 text-[13px] text-[#1d1b2b]">{contactGist(stage, tutorName || 'Your tutor')}</p>
          <label htmlFor={`contact-note-${l.id}`} className="text-[13px] font-semibold text-[#55526a]">Your message (optional, English)</label>
          <textarea id={`contact-note-${l.id}`} value={note} maxLength={TUTOR_CONTACT.noteMax} rows={3} onChange={(e) => setNote(e.target.value.slice(0, TUTOR_CONTACT.noteMax))}
            className="w-full resize-y rounded-[10px] border border-[#d9d5e6] bg-white px-3 py-2 text-[16px] text-[#1d1b2b] lg:text-[14px]" />
          <span className="-mt-1.5 text-right text-[12px] tabular-nums text-[#6b6880]">{note.length} / {TUTOR_CONTACT.noteMax}</span>
          {error && <p role="alert" className="text-[14px] text-[#b3261e]">{error}</p>}
          <div className="grid grid-cols-2 gap-2">
            <button type="button" disabled={busy} onClick={() => void submit()} className={main}>{busy ? 'Sending…' : 'Send'}</button>
            <button type="button" disabled={busy} onClick={() => { setOpen(false); setNote(''); setError(''); }} className={sub}>Back</button>
          </div>
        </div>
      )}
    </div>
  );
}
