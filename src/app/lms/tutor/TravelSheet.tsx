'use client';

// Regular Working Hours 창: [Add Temporary Location] · [Set end date] (정책 원본 H26(173), 시안 8차 장면 1·5)
//  도시(영어 검색, 고르면 시간대 자동)·시작일·종료일(선택)만. 시간대를 고르는 칸은 없음. 저장은 DB 함수 tutor_location_save

import { useState } from 'react';
import { cityTime } from '@/lms/tutor/hours-view';
import { NO_END_TEXT, returnText, searchCity, zoneBadge, type CityHit, type TravelLocation } from '@/lms/tutor/travel';
import { formatInZone } from '@/lms/rules/dates';

export type Sheet = { kind: 'add' } | { kind: 'end'; loc: TravelLocation };
type Actions = { saveLocation: (id: string | null, city: string | null, country: string | null, timezone: string | null, from: string | null, to: string | null) => Promise<TravelLocation> };

const btnMain = 'min-h-[44px] flex-1 rounded-[10px] bg-[#5b3fe0] px-4 text-[15px] font-semibold text-white disabled:opacity-40';
const btnSub = 'min-h-[44px] flex-1 rounded-[10px] border border-[#e6e3ef] bg-white px-4 text-[15px] font-semibold text-[#1d1b2b] disabled:opacity-40';
const field = 'min-h-[44px] w-full rounded-[10px] border border-[#e6e3ef] bg-white px-3 text-[15px] text-[#1d1b2b]';
const label = 'grid gap-1 text-[13px] font-semibold text-[#55526a]';

export function TravelSheet({ sheet, inline, actions, onClose, onSaved }: {
  sheet: Sheet; inline?: boolean; actions: Actions; onClose: () => void; onSaved: (l: TravelLocation) => void | Promise<void>;
}) {
  const [q, setQ] = useState('');
  const [city, setCity] = useState<CityHit | null>(null);
  const [from, setFrom] = useState('');
  const [hasEnd, setHasEnd] = useState(true);
  const [to, setTo] = useState(sheet.kind === 'end' ? '' : '');
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState('');

  const zone = sheet.kind === 'end' ? sheet.loc.timezone : city?.timezone ?? null;
  const today = zone ? formatInZone(new Date(), zone).date : '';
  const start = sheet.kind === 'end' ? sheet.loc.from : from;
  const hits = city ? [] : searchCity(q);
  const endOk = !to || !start || to >= start;
  const can = sheet.kind === 'end'
    ? !!to && endOk && to >= today
    : !!city && !!from && from >= today && (!hasEnd || (!!to && endOk));

  async function save() {
    setBusy(true);
    setErr('');
    try {
      const l = sheet.kind === 'end'
        ? await actions.saveLocation(sheet.loc.id, null, null, null, null, to)
        : await actions.saveLocation(null, city!.city, city!.country, city!.timezone, from, hasEnd ? to : null);
      await onSaved(l);
    } catch (e) {
      setErr(e instanceof Error ? e.message : 'Could not save. Please try again.');
    } finally {
      setBusy(false);
    }
  }

  return (
    <div className={`${inline ? 'fixed z-50' : 'absolute z-10'} inset-0 flex items-end justify-center bg-black/40 lg:items-center`} onClick={(e) => { if (e.target === e.currentTarget && !busy) onClose(); }}>
      <div role="dialog" aria-modal="true" aria-label={sheet.kind === 'add' ? 'Add Temporary Location' : 'Set end date'}
        className="grid max-h-[90vh] w-full gap-3 overflow-y-auto rounded-t-[18px] bg-white p-4 pb-5 lg:max-w-[440px] lg:rounded-[16px]">
        <strong className="text-[17px] text-[#1d1b2b]">{sheet.kind === 'add' ? 'Add Temporary Location' : 'Set end date'}</strong>

        {sheet.kind === 'add' && (
          <>
            <label className={label}>City
              <input type="search" value={city ? `${city.city}, ${city.country}` : q} placeholder="e.g. Buenos Aires" autoComplete="off"
                onChange={(e) => { setCity(null); setQ(e.target.value); }} className={field} />
            </label>
            {!city && q.trim() !== '' && (
              hits.length > 0
                ? (
                  <ul className="grid gap-1" aria-label="Cities">
                    {hits.map((c) => (
                      <li key={`${c.city}-${c.timezone}`}>
                        <button type="button" onClick={() => setCity(c)} className="flex min-h-[44px] w-full items-center justify-between gap-2 rounded-[10px] border border-[#e6e3ef] px-3 text-left text-[14.5px] text-[#1d1b2b] hover:bg-[#f6f4fb]">
                          <span><b>{c.city}</b>, {c.country}</span>
                          <span className="text-[12.5px] text-[#6b6880]">{cityTime(c.timezone)}</span>
                        </button>
                      </li>
                    ))}
                  </ul>
                )
                : <p className="text-[13.5px] text-[#6b6880]">No match. Try the English city name.</p>
            )}
            {city && (
              <div className="flex items-center justify-between gap-2 rounded-[12px] bg-[#f6f4fb] px-3 py-2 text-[14px] text-[#1d1b2b]">
                <span><b>{city.city}</b> · {city.country}<br /><span className="text-[13px] text-[#55526a]">{cityTime(city.timezone)} · {zoneBadge(city.timezone, from || today)}</span></span>
                <button type="button" onClick={() => { setCity(null); setQ(''); }} className="shrink-0 text-[13.5px] font-semibold text-[#5b3fe0] underline">Change</button>
              </div>
            )}
            <div className="flex flex-wrap gap-2">
              <label className={`${label} min-w-[130px] flex-1`}>From
                <input type="date" value={from} min={today || undefined} onChange={(e) => setFrom(e.target.value)} className={field} />
              </label>
              {hasEnd && (
                <label className={`${label} min-w-[130px] flex-1`}>To (optional)
                  <input type="date" value={to} min={from || today || undefined} onChange={(e) => setTo(e.target.value)} className={field} />
                </label>
              )}
            </div>
            <div className="flex gap-2" role="group" aria-label="End date">
              {[true, false].map((x) => (
                <button key={String(x)} type="button" aria-pressed={hasEnd === x} onClick={() => setHasEnd(x)}
                  className={`min-h-[40px] flex-1 rounded-full border px-3 text-[14px] font-semibold ${hasEnd === x ? 'border-[#5b3fe0] bg-[#5b3fe0] text-white' : 'border-[#e6e3ef] bg-white text-[#1d1b2b]'}`}>
                  {x ? 'With end date' : 'No end date'}
                </button>
              ))}
            </div>
            {from && today && from < today && <p role="alert" className="text-[13.5px] text-[#b3261e]">The start date has passed.</p>}
            {hasEnd && !endOk && <p role="alert" className="text-[13.5px] text-[#b3261e]">The end date must be on or after the start date.</p>}
            {hasEnd ? (to && endOk && <p className="text-[13.5px] font-semibold text-[#1f7a4d]">{returnText(to)}</p>)
              : <p className="text-[13.5px] font-semibold text-[#b3261e]">{NO_END_TEXT}</p>}
          </>
        )}

        {sheet.kind === 'end' && (
          <>
            <label className={label}>To
              <input type="date" value={to} min={sheet.loc.from > today ? sheet.loc.from : today} onChange={(e) => setTo(e.target.value)} className={field} />
            </label>
            {to && !endOk && <p role="alert" className="text-[13.5px] text-[#b3261e]">The end date must be on or after the start date.</p>}
            {to && endOk && to < today && <p role="alert" className="text-[13.5px] text-[#b3261e]">The end date has passed.</p>}
            {to && endOk && to >= today && <p className="text-[13.5px] font-semibold text-[#1f7a4d]">{returnText(to)}</p>}
          </>
        )}

        {err && <p role="alert" className="text-[14px] text-[#b3261e]">{err}</p>}
        <div className="flex gap-2">
          <button type="button" disabled={busy} onClick={onClose} className={btnSub}>Cancel</button>
          <button type="button" disabled={!can || busy} onClick={() => void save()} className={btnMain}>{busy ? 'Saving…' : 'Save'}</button>
        </div>
      </div>
    </div>
  );
}
