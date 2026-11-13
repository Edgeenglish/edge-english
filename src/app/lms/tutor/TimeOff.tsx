'use client';
// 강사 휴무 신청 (H26(137), 시안 https://claude.ai/artifact/VijcTWhC9DY52i9FqjHT3A, 대표 11/13 확정)
//  · Home 'Time off' 란: 신청 내역(대기·승인·반려) + [Request time off], 대기 중이면 [Withdraw]
//  · 신청 창: 현지 첫날·마지막 날 → 걸리는 수업 → 종류 → 사유 → [Next] → 확인 창 → [Send request]
//  · 3일 이상만 (1~2일은 Calendar 의 Cancel class) · 계획된 휴무 14일 전보다 늦으면 빨간 경고(신청은 됨)
import { useEffect, useState } from 'react';
import { Rich } from '@/app/lms/Rich';
import { enDateOf, enRangeBoth, enZoneName } from '@/lms/admin/time-text';
import { TIME_OFF_MIN_DAYS, TIME_OFF_NOTICE_DAYS, daysBetween, type TimeOffActions, type TimeOffKind, type TimeOffList, type TimeOffPreview, type TimeOffRow } from '@/lms/tutor/time-off';

const btnMain = 'min-h-[44px] rounded-[10px] bg-[#5b3fe0] px-4 text-[15px] font-semibold text-white disabled:opacity-40';
const btnSub = 'min-h-[44px] rounded-[10px] border border-[#e6e3ef] bg-white px-4 text-[15px] font-semibold text-[#1d1b2b] disabled:opacity-40';
const input = 'w-full min-w-0 rounded-[10px] border border-[#d9d5e6] bg-white px-3 py-2.5 text-[16px] text-[#1d1b2b]';
const label = 'mb-1 block text-[13px] font-semibold text-[#55526a]';
const warn = 'text-[13.5px] font-semibold text-[#b3261e]';

const city = (tz: string) => enZoneName(tz).replace(/ Time$/, '');
const range = (a: string, b: string) => `${enDateOf(a)} – ${enDateOf(b)}`;
const LATE = `Less than ${TIME_OFF_NOTICE_DAYS} days’ notice. Planned time off needs at least ${TIME_OFF_NOTICE_DAYS} days’ notice (Tutor Agreement, Section 10).`;

const TAG: Record<TimeOffRow['status'], { text: string; cls: string }> = {
  pending: { text: 'Waiting for Edge English', cls: 'bg-[#fff4d6] text-[#5c3b00]' },
  approved: { text: 'Approved', cls: 'bg-[#e3f4ea] text-[#1f7a4d]' },
  rejected: { text: 'Not approved', cls: 'bg-[#fdecea] text-[#b3261e]' },
};

/** Home 'Time off' 란 */
export function TimeOffCard({ data, onRequest, onWithdraw }: { data: TimeOffList; onRequest: () => void; onWithdraw: (id: string) => Promise<void> }) {
  const [busy, setBusy] = useState<string | null>(null);
  const [err, setErr] = useState('');
  async function withdraw(id: string) {
    if (!window.confirm('Withdraw this request?')) return;
    setBusy(id);
    setErr('');
    try {
      await onWithdraw(id);
    } catch (e) {
      setErr(e instanceof Error ? e.message : 'Could not withdraw.');
    } finally {
      setBusy(null);
    }
  }
  return (
    <section aria-label="Time off" className="grid gap-3 rounded-[14px] border border-[#e6e3ef] bg-white p-4">
      <div className="flex flex-wrap items-center justify-between gap-2">
        <h2 className="text-[16px] font-bold text-[#1d1b2b]">Time off</h2>
        <button type="button" onClick={onRequest} className={`${btnMain} w-full lg:w-auto`}>Request time off</button>
      </div>
      {err && <p className={warn}>{err}</p>}
      {data.rows.length > 0 && (
        <ul className="grid gap-2.5">
          {data.rows.map((r) => (
            <li key={`${r.source}:${r.id}`} className="flex flex-wrap items-center justify-between gap-x-3 gap-y-1.5 border-t border-[#f0eef5] pt-2.5 first:border-t-0 first:pt-0">
              <div className="min-w-0 text-[14.5px] text-[#1d1b2b]">
                <span className={`mr-1.5 inline-block rounded-[6px] px-1.5 py-0.5 text-[12.5px] font-bold ${TAG[r.status].cls}`}>{TAG[r.status].text}</span>
                <b className="whitespace-nowrap">{range(r.first, r.last)}</b>
                <span className="text-[13px] text-[#6b6880]"> · {city(data.timezone)} dates{r.classes ? ` · ${r.classes} class${r.classes > 1 ? 'es' : ''}` : ''}</span>
                {r.status === 'rejected' && r.rejectReason && <span className="block text-[13.5px] text-[#55526a]">Reason: {r.rejectReason}</span>}
              </div>
              {r.status === 'pending' && r.source === 'request' && (
                <button type="button" disabled={busy === r.id} onClick={() => withdraw(r.id)} className={`${btnSub} min-h-[38px] text-[14px]`}>Withdraw</button>
              )}
            </li>
          ))}
        </ul>
      )}
    </section>
  );
}

/** Regular Working Hours · Calendar & One-Time Changes 맨 위 한 줄 */
export function TimeOffLine({ onClick }: { onClick: () => void }) {
  return (
    <div className="mb-3 flex flex-wrap items-center justify-between gap-2 rounded-[12px] border border-[#e6e3ef] bg-white px-3.5 py-2.5 text-[14.5px] text-[#1d1b2b]">
      <span>Taking 3 or more days off? Request it as time off.</span>
      <button type="button" onClick={onClick} className={`${btnSub} min-h-[40px] w-full text-[14px] lg:w-auto`}>Request time off ›</button>
    </div>
  );
}

/** 신청 창 (Sheet 안): 1 입력 → 2 확인 */
export function TimeOffForm({ actions, data, onCalendar, onSent, onDirty }: {
  actions: TimeOffActions;
  data: TimeOffList;
  onCalendar: () => void;
  onSent: () => Promise<void> | void;
  onDirty?: (dirty: boolean) => void;
}) {
  const tz = data.timezone;
  const [first, setFirst] = useState('');
  const [last, setLast] = useState('');
  const [kind, setKind] = useState<TimeOffKind | null>(null);
  const [reason, setReason] = useState('');
  const [preview, setPreview] = useState<TimeOffPreview | null>(null);
  const [step, setStep] = useState<'form' | 'confirm'>('form');
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState('');

  useEffect(() => { onDirty?.(!!(first || last || kind || reason.trim())); }, [first, last, kind, reason, onDirty]);

  const datesOk = !!first && !!last && last >= first;
  const days = datesOk ? daysBetween(first, last) + 1 : 0;
  const short = datesOk && days < TIME_OFF_MIN_DAYS;
  const late = datesOk && kind === 'planned' && daysBetween(data.today, first) < TIME_OFF_NOTICE_DAYS;

  useEffect(() => {
    setPreview(null);
    if (!datesOk || short) return;
    let live = true;
    actions.preview(first, last).then((p) => live && setPreview(p), (e) => live && setErr(e instanceof Error ? e.message : 'Could not load classes.'));
    return () => { live = false; };
  }, [first, last, datesOk, short, actions]);

  const ready = datesOk && !short && !!kind && reason.trim() !== '' && !!preview;
  const classes = preview?.classes ?? [];

  async function send() {
    if (!kind) return;
    setBusy(true);
    setErr('');
    try {
      await actions.request(first, last, kind, reason.trim());
      onDirty?.(false);
      await onSent();
    } catch (e) {
      setErr(e instanceof Error ? e.message : 'Could not send.');
    } finally {
      setBusy(false);
    }
  }

  if (step === 'confirm' && kind) {
    return (
      <div className="grid gap-3">
        <h2 className="pr-10 text-[17px] font-bold text-[#1d1b2b]">Before you send</h2>
        <div>
          <span className={label}>This request</span>
          <p className="text-[15.5px] font-bold text-[#1d1b2b]">{range(first, last)} <span className="font-normal text-[#6b6880]">{city(tz)} dates · {classes.length} class{classes.length === 1 ? '' : 'es'}</span></p>
          {late && <p className={warn}>Less than {TIME_OFF_NOTICE_DAYS} days’ notice</p>}
        </div>
        <div className="border-t border-[#e6e3ef] pt-2.5">
          <span className={label}>Your time off this year</span>
          {data.year.length === 0 ? <p className="text-[14.5px] text-[#1d1b2b]">None</p> : (
            <ul className="grid gap-0.5 text-[14.5px] text-[#1d1b2b]">
              {data.year.map((y) => <li key={y.first}>{range(y.first, y.last)} <span className="text-[13px] text-[#6b6880]">{city(tz)} dates</span></li>)}
            </ul>
          )}
        </div>
        <p className="rounded-[12px] border border-[#f0d58a] bg-[#fff8e6] px-3 py-2.5 text-[14px] text-[#1d1b2b]">
          Time off breaks your students’ weekly routine and pushes their course end date back. Please keep time off to a minimum.
        </p>
        {err && <p className={warn}>{err}</p>}
        <div className="grid gap-2 lg:flex">
          <button type="button" disabled={busy} onClick={send} className={btnMain}>Send request</button>
          <button type="button" disabled={busy} onClick={() => setStep('form')} className={btnSub}>Back</button>
        </div>
      </div>
    );
  }

  return (
    <div className="grid gap-3">
      <div className="pr-10">
        <h2 className="text-[17px] font-bold text-[#1d1b2b]">Request time off</h2>
        <p className="text-[13.5px] text-[#6b6880]"><Rich text={`All dates are in *${enZoneName(tz)}*`} /></p>
      </div>
      <div className="grid grid-cols-2 items-end gap-2">
        <label className="min-w-0">
          <span className={label}>First day off</span>
          <input type="date" value={first} min={data.today} onChange={(e) => { setFirst(e.target.value); if (!last || last < e.target.value) setLast(e.target.value); }} className={input} />
        </label>
        <label className="min-w-0">
          <span className={label}>Last day off</span>
          <input type="date" value={last} min={first || data.today} onChange={(e) => setLast(e.target.value)} className={input} />
        </label>
      </div>
      {short && (
        <div className="grid gap-2">
          <p className={warn}>For 1–2 days off, cancel each class in Calendar.</p>
          <button type="button" onClick={onCalendar} className={`${btnSub} w-full lg:w-auto lg:justify-self-start`}>Go to Calendar ›</button>
        </div>
      )}
      {late && !short && <p className={warn}>{LATE}</p>}
      {datesOk && !short && (
        <div>
          <span className={label}>Classes on these days{preview ? ` (${classes.length})` : ''}</span>
          {!preview && <p className="text-[14px] text-[#6b6880]">Loading…</p>}
          {preview && classes.length === 0 && <p className="text-[14px] text-[#6b6880]">No classes</p>}
          {classes.length > 0 && (
            <ul className="grid gap-1 text-[14px] text-[#1d1b2b]">
              {classes.map((c) => <li key={c.startsAt.toISOString()}><Rich text={enRangeBoth(c.startsAt, c.endsAt, tz)} /> · {c.student}</li>)}
            </ul>
          )}
        </div>
      )}
      <div role="radiogroup" aria-label="Type">
        <span className={label}>Type</span>
        <div className="grid gap-1.5">
          {([['planned', 'Planned (trip, personal plans)'], ['urgent', 'Urgent (illness, family emergency)']] as const).map(([k, text]) => (
            <button key={k} type="button" role="radio" aria-checked={kind === k} onClick={() => setKind(k)}
              className={`min-h-[44px] rounded-[10px] border px-3 text-left text-[15px] text-[#1d1b2b] ${kind === k ? 'border-2 border-[#5b3fe0] bg-[#efecfd] font-semibold' : 'border-[#e6e3ef] bg-white'}`}>
              {text}
            </button>
          ))}
        </div>
        {kind === 'urgent' && <p className="mt-1.5 text-[13.5px] text-[#55526a]">Please send proof (e.g. a medical note) if Edge English asks.</p>}
      </div>
      <label>
        <span className={label}>Reason</span>
        <input value={reason} onChange={(e) => setReason(e.target.value)} className={input} />
      </label>
      {err && <p className={warn}>{err}</p>}
      <button type="button" disabled={!ready} onClick={() => setStep('confirm')} className={btnMain}>Next</button>
    </div>
  );
}
