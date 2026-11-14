'use client';

// Calendar & One-Time Changes [Set Multiple Days] (정책 원본 H26(173) ④, 시안 8차 장면 3·4)
//  1 Days → 2 Time → 3 Review 단계마다 화면을 나눔. 시간은 그 날짜에 있는 지역 현지 시간만 (시작 06:00~22:30), 한국 시간은 참고 줄
//  두 지역에 걸치면 [Split by location] → 지역마다 시간. 막힌 날은 빼고 이유 표시, 되는 날만 [Apply]
//  판정·저장은 DB 함수 tutor_schedule_multi (미리보기 p_apply=false → 적용 true)

import { useState } from 'react';
import { ampmEn, formatInZone } from '@/lms/rules/dates';
import { cityTime, localToInstant } from '@/lms/tutor/hours-view';
import { hhmm } from '@/lms/tutor/hours';
import { dayText } from '@/lms/tutor/schedule';
import {
  dayCount, daysText, dowDayMonth, groupDays, groupText, whyText, zoneBadge, type DayGroup, type MultiResult, type TravelPeriod,
} from '@/lms/tutor/travel';

export type MultiAction = (from: string, to: string, start: string, end: string, apply: boolean) => Promise<MultiResult>;

const btnMain = 'min-h-[44px] flex-1 rounded-[10px] bg-[#5b3fe0] px-4 text-[15px] font-semibold text-white disabled:opacity-40';
const btnSub = 'min-h-[44px] flex-1 rounded-[10px] border border-[#e6e3ef] bg-white px-4 text-[15px] font-semibold text-[#1d1b2b] disabled:opacity-40';
const field = 'min-h-[44px] w-full rounded-[10px] border border-[#e6e3ef] bg-white px-3 text-[15px] text-[#1d1b2b]';
const STARTS = Array.from({ length: 34 }, (_, i) => hhmm(360 + i * 30));      // 6:00 AM ~ 10:30 PM
const ENDS = Array.from({ length: 34 }, (_, i) => hhmm(390 + i * 30));        // 6:30 AM ~ 11:00 PM
const STEPS = ['Days', 'Time', 'Review'] as const;

type Plan = DayGroup & { start: string; end: string; leave: boolean };
type Reviewed = Plan & { result: MultiResult | null };

export default function SetMultipleDays({ home, homeCountry, periods, today, last, multi, onClose, onSaved }: {
  home: string; homeCountry: string; periods: TravelPeriod[];
  /** 강사 평소 시간대 오늘 · 마지막 날 (12주) */
  today: string; last: string;
  multi: MultiAction; onClose: () => void; onSaved: () => void;
}) {
  const [step, setStep] = useState(1);
  const [from, setFrom] = useState(today);
  const [to, setTo] = useState(today);
  const [split, setSplit] = useState(false);
  const [plans, setPlans] = useState<Plan[]>([]);
  const [review, setReview] = useState<Reviewed[] | null>(null);
  const [applied, setApplied] = useState<number | null>(null);
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState('');

  const daysOk = !!from && !!to && from <= to && from >= today && to <= last;
  const groups = daysOk ? groupDays(periods, from, to, home) : [];
  const two = groups.length > 1;
  const zoneLine = (g: DayGroup) => (
    <div className="flex items-center justify-between gap-2 rounded-[12px] bg-[#f6f4fb] px-3 py-2 text-[14px] text-[#1d1b2b]">
      <span><b>{groupText(g, homeCountry, home)}</b><br />{daysText(g.from, g.to)}</span>
      <span className="shrink-0 rounded-full bg-white px-2 py-0.5 text-[12px] font-semibold text-[#2b1c7a]">{zoneBadge(g.timezone, g.from)}</span>
    </div>
  );
  const kst = (date: string, t: string, tz: string) => {
    const f = formatInZone(localToInstant(date, t, tz), 'Asia/Seoul');
    return { date: f.date, time: ampmEn(f.time) };
  };

  async function toTime(doSplit: boolean) {
    setErr('');
    setBusy(true);
    try {
      // 휴무로 다 막힌 지역은 시간을 묻지 않음 (시안 장면 4 'In your leave. Nothing to save.')
      const ps: Plan[] = [];
      for (const g of groups) {
        let leave = false;
        if (doSplit) {
          const r = await multi(g.from, g.to, '06:00', '23:00', false);
          leave = r.days.length > 0 && r.days.every((d) => d.why === 'l');
        }
        const old = plans.find((p) => p.from === g.from && p.to === g.to);
        ps.push({ ...g, start: old?.start ?? '16:00', end: old?.end ?? '22:00', leave });
      }
      setPlans(ps);
      setSplit(doSplit);
      setStep(2);
    } catch (e) {
      setErr(e instanceof Error ? e.message : 'Could not load. Please try again.');
    } finally {
      setBusy(false);
    }
  }
  async function toReview() {
    setErr('');
    setBusy(true);
    try {
      const out: Reviewed[] = [];
      for (const p of plans) out.push({ ...p, result: p.leave ? null : await multi(p.from, p.to, p.start, p.end, false) });
      setReview(out);
      setStep(3);
    } catch (e) {
      setErr(e instanceof Error ? e.message : 'Could not load. Please try again.');
    } finally {
      setBusy(false);
    }
  }
  async function apply() {
    if (!review) return;
    setErr('');
    setBusy(true);
    try {
      let n = 0;
      for (const p of review) if (p.result && p.result.ok > 0) n += (await multi(p.from, p.to, p.start, p.end, true)).ok;
      setApplied(n);
      onSaved();
    } catch (e) {
      setErr(e instanceof Error ? e.message : 'Could not save. Please try again.');
    } finally {
      setBusy(false);
    }
  }
  const setPlan = (i: number, x: Partial<Plan>) => setPlans(plans.map((p, j) => (j === i ? { ...p, ...x } : p)));
  const okCount = review?.reduce((n, p) => n + (p.result?.ok ?? 0), 0) ?? 0;
  const skipCount = review?.reduce((n, p) => n + (p.result ? p.result.days.length - p.result.ok : dayCount(p.from, p.to)), 0) ?? 0;
  const span = (p: Plan) => `${ampmEn(p.start)} – ${ampmEn(p.end)} ${cityTime(p.timezone)}`;

  const bar = (
    <div className="flex gap-1.5 text-[12.5px] font-semibold" aria-label="Steps">
      {STEPS.map((t, i) => (
        <span key={t} aria-current={step === i + 1 ? 'step' : undefined}
          className={`flex-1 rounded-full px-2 py-1 text-center ${step === i + 1 ? 'bg-[#5b3fe0] text-white' : 'bg-[#f1eefb] text-[#6b6880]'}`}>{i + 1} {t}</span>
      ))}
    </div>
  );

  return (
    <div className="fixed inset-0 z-50 flex items-end justify-center bg-black/40 lg:items-center" onClick={(e) => { if (e.target === e.currentTarget && !busy) onClose(); }}>
      <div role="dialog" aria-modal="true" aria-label="Set Multiple Days" className="grid max-h-[90vh] w-full gap-3 overflow-y-auto rounded-t-[18px] bg-white p-4 pb-6 lg:max-w-[460px] lg:rounded-[16px]">
        {bar}
        {step === 1 && (
          <>
            <strong className="text-[17px] text-[#1d1b2b]">Which days?</strong>
            <div className="flex flex-wrap gap-2">
              <label className="grid min-w-[130px] flex-1 gap-1 text-[13px] font-semibold text-[#55526a]">From
                <input type="date" value={from} min={today} max={last} onChange={(e) => { setFrom(e.target.value); if (to < e.target.value) setTo(e.target.value); }} className={field} />
              </label>
              <label className="grid min-w-[130px] flex-1 gap-1 text-[13px] font-semibold text-[#55526a]">To
                <input type="date" value={to} min={from || today} max={last} onChange={(e) => setTo(e.target.value)} className={field} />
              </label>
            </div>
            {from && to && from > to && <p role="alert" className="text-[13.5px] text-[#b3261e]">The end date must be on or after the start date.</p>}
            {from && from < today && <p role="alert" className="text-[13.5px] text-[#b3261e]">The start date has passed.</p>}
            {to && to > last && <p role="alert" className="text-[13.5px] text-[#b3261e]">You can change times up to 12 weeks ahead (until {dayText(last)}).</p>}
            {daysOk && !two && zoneLine(groups[0])}
            {daysOk && !two && <p className="rounded-[12px] bg-[#f6f4fb] px-3 py-2 text-[13.5px] text-[#1d1b2b]">{dayCount(from, to)} day{dayCount(from, to) > 1 ? 's' : ''} selected</p>}
            {two && (
              <>
                <p role="alert" className="text-[14px] font-semibold text-[#b3261e]">The selected days are in two locations</p>
                {groups.map((g) => <div key={g.from}>{zoneLine(g)}</div>)}
              </>
            )}
            {err && <p role="alert" className="text-[14px] text-[#b3261e]">{err}</p>}
            <div className="flex gap-2">
              <button type="button" disabled={busy} onClick={onClose} className={btnSub}>Cancel</button>
              {two
                ? <button type="button" disabled={busy} onClick={() => void toTime(true)} className={btnMain}>Split by location</button>
                : <button type="button" disabled={!daysOk || busy} onClick={() => void toTime(false)} className={btnMain}>Next</button>}
            </div>
          </>
        )}

        {step === 2 && (
          <>
            <strong className="text-[17px] text-[#1d1b2b]">What time?</strong>
            {plans.map((p, i) => (
              <div key={p.from} className="grid gap-2">
                {split && <p className="text-[13px] font-bold text-[#2b1c7a]">{i + 1} of {plans.length}</p>}
                {zoneLine(p)}
                {p.leave
                  ? <p className="text-[14px] font-semibold text-[#b3261e]">In your leave. Nothing to save.</p>
                  : (
                    <>
                      <div className="flex gap-2">
                        <label className="grid flex-1 gap-1 text-[13px] font-semibold text-[#55526a]">Start
                          <select value={p.start} onChange={(e) => setPlan(i, { start: e.target.value, end: p.end <= e.target.value ? hhmm(Math.min(23 * 60, Number(e.target.value.slice(0, 2)) * 60 + Number(e.target.value.slice(3)) + 30)) : p.end })} className={field}>
                            {STARTS.map((t) => <option key={t} value={t}>{ampmEn(t)}</option>)}
                          </select>
                        </label>
                        <label className="grid flex-1 gap-1 text-[13px] font-semibold text-[#55526a]">End
                          <select value={p.end} onChange={(e) => setPlan(i, { end: e.target.value })} className={field}>
                            {ENDS.filter((t) => t > p.start).map((t) => <option key={t} value={t}>{ampmEn(t)}</option>)}
                          </select>
                        </label>
                      </div>
                      <p className="rounded-[12px] bg-[#f6f4fb] px-3 py-2 text-[13.5px] leading-[1.7] text-[#1d1b2b]">
                        {span(p)}
                        {p.timezone !== 'Asia/Seoul' && (() => { const a = kst(p.from, p.start, p.timezone); const b = kst(p.from, p.end, p.timezone); return <><br /><span className="text-[#6b6880]">= {dowDayMonth(a.date)} {a.time} – {b.date !== a.date ? `${dowDayMonth(b.date)} ` : ''}{b.time} KST</span></>; })()}
                      </p>
                    </>
                  )}
              </div>
            ))}
            {err && <p role="alert" className="text-[14px] text-[#b3261e]">{err}</p>}
            <div className="flex gap-2">
              <button type="button" disabled={busy} onClick={() => { setErr(''); setStep(1); }} className={btnSub}>Back</button>
              <button type="button" disabled={busy || plans.every((p) => p.leave)} onClick={() => void toReview()} className={btnMain}>Next</button>
            </div>
          </>
        )}

        {step === 3 && review && applied === null && (
          <>
            <strong className="text-[17px] text-[#1d1b2b]">Review</strong>
            <div className="grid gap-1 rounded-[12px] bg-[#f6f4fb] px-3 py-2 text-[13.5px] text-[#1d1b2b]">
              {review.filter((p) => !p.leave).map((p) => <span key={p.from}><b>Make available</b> · {span(p)}</span>)}
              <span><b className="text-[#1f7a4d]">{okCount} day{okCount === 1 ? '' : 's'} will be saved</b>{skipCount > 0 && <> · <b className="text-[#b3261e]">{skipCount} skipped</b></>}</span>
            </div>
            <ul className="grid gap-1.5">
              {review.flatMap((p) => (p.result
                ? p.result.days.map((d) => {
                  const k = kst(d.date, p.start, p.timezone);
                  return (
                    <li key={d.date} className={`grid gap-0.5 rounded-[10px] border px-3 py-2 text-[14px] ${d.ok ? 'border-[#cfe8db] bg-[#f3fbf6]' : 'border-[#f2d4d1] bg-[#fdf5f4]'}`}>
                      <span className="font-semibold text-[#1d1b2b]">{d.ok ? `${dowDayMonth(d.date)} ${ampmEn(p.start)} ${cityTime(p.timezone)}` : dowDayMonth(d.date)}</span>
                      <small className={`text-[12.5px] ${d.ok ? 'text-[#1f7a4d]' : 'text-[#b3261e]'}`}>
                        {d.ok ? (p.timezone === 'Asia/Seoul' ? '✓' : `${dowDayMonth(k.date)} ${k.time} KST ✓`) : whyText(d, cityTime(p.timezone), ampmEn)}
                      </small>
                    </li>
                  );
                })
                : [<li key={p.from} className="grid gap-0.5 rounded-[10px] border border-[#f2d4d1] bg-[#fdf5f4] px-3 py-2 text-[14px]">
                  <span className="font-semibold text-[#1d1b2b]">{daysText(p.from, p.to)}</span>
                  <small className="text-[12.5px] text-[#b3261e]">In your leave</small>
                </li>]))}
            </ul>
            {err && <p role="alert" className="text-[14px] text-[#b3261e]">{err}</p>}
            <div className="flex gap-2">
              <button type="button" disabled={busy} onClick={() => { setErr(''); setStep(2); }} className={btnSub}>Back</button>
              <button type="button" disabled={busy || okCount === 0} onClick={() => void apply()} className={btnMain}>{busy ? 'Saving…' : `Apply to ${okCount} day${okCount === 1 ? '' : 's'}`}</button>
            </div>
          </>
        )}

        {step === 3 && applied !== null && review && (
          <>
            <strong className="text-[17px] text-[#1f7a4d]">Saved</strong>
            {review.filter((p) => p.result && p.result.ok > 0).map((p) => (
              <p key={p.from} className="text-[14px] font-semibold text-[#1f7a4d]">✓ {p.result!.ok} day{p.result!.ok === 1 ? '' : 's'} opened · {span(p)}</p>
            ))}
            <div className="flex gap-2"><button type="button" onClick={onClose} className={btnMain}>Done</button></div>
          </>
        )}
      </div>
    </div>
  );
}
