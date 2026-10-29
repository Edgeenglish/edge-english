'use client';

// 강사 가능 시간 고치기 [My hours] (시안 docs/lms/previews/tutor-hours-drafts.html, 대표 확정 10/29)
//  Every week = 매주 수업 시작 가능 칸 (다음 주 월요일부터) · One week only = 그 주만 빈 칸 닫기 (4주, 6시간 전까지)
//  화면 잠금은 편의일 뿐, 수업·보강·답 대기 칸 검사는 DB 함수 tutor_hours_save 가 다시 함 (migration 3100)

import { useEffect, useRef, useState, type CSSProperties, type ReactNode } from 'react';
import {
  dateText, describeChanges, diff, fromText, lessonAt, plusDays, timeText, toMin, WEEK_DAYS, weekText, weeklyClassAt, type CellCode, type HoursData,
} from '@/lms/tutor/hours';

export type HoursActions = {
  load: () => Promise<HoursData>;
  save: (weekly: string[] | null, close: string[], open: string[]) => Promise<void>;
};

const SHORT = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];
const FULL = ['Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday'];
const WEEKS = 4;
const btnMain = 'min-h-[44px] rounded-[10px] bg-[#5b3fe0] px-4 text-[15px] font-semibold text-white disabled:opacity-40';
const btnSub = 'min-h-[44px] rounded-[10px] border border-[#e6e3ef] bg-white px-4 text-[15px] font-semibold text-[#1d1b2b] disabled:opacity-40';
const cellBase = 'h-[26px] w-full overflow-hidden whitespace-nowrap rounded-[5px] p-0 text-[10.5px] font-semibold lg:h-[24px] lg:text-[11.5px]';
const span = (start: string, min: number) => `${timeText(toMin(start))}–${timeText(toMin(start) + min)}`;
/** 수업 시작 칸 글 (대표 10/29): 휴대폰 = 학생 이름(칸이 좁아 이름 앞부분), PC = 이름 + 길이. 정확한 시각은 누르면 창에 */
const lessonLabel = (student: string, min: number) => (
  <><span className="[color:inherit] lg:hidden">{student.split(' ')[0]}</span><span className="hidden [color:inherit] lg:inline">{student} · {min}m</span></>
);
/** 같은 수업의 다음 칸은 위 칸과 붙여 한 덩어리로 */
const cont = '-mt-[2px] h-[28px] rounded-t-none lg:h-[26px]';
const hatch = { background: 'repeating-linear-gradient(-45deg,#fdecea,#fdecea 4px,#fff 4px,#fff 7px)', boxShadow: 'inset 0 0 0 1px #b3261e' };

type Dialog =
  | { kind: 'info'; title: string; body: string[] }
  | { kind: 'day'; date: string; free: string[]; allShut: boolean }
  | { kind: 'save' }
  | { kind: 'saved' };

export default function TutorHours({ actions, onClose }: { actions: HoursActions; onClose: () => void }) {
  const [data, setData] = useState<HoursData | null>(null);
  const [err, setErr] = useState('');
  const [tab, setTab] = useState<'week' | 'once'>('week');
  const [wk, setWk] = useState(0);
  const [weekly, setWeekly] = useState<Set<string>>(new Set());
  const [once, setOnce] = useState<Set<string>>(new Set());
  const [dialog, setDialog] = useState<Dialog | null>(null);
  const [busy, setBusy] = useState(false);
  const [saveErr, setSaveErr] = useState('');
  const scroller = useRef<HTMLDivElement>(null);

  async function load() {
    setErr('');
    try {
      const d = await actions.load();
      setData(d);
      setWeekly(new Set(d.weeklyOpen));
      setOnce(new Set(Object.keys(d.cells).filter((k) => d.cells[k] === 'b')));
    } catch (e) {
      setErr(e instanceof Error ? e.message : 'Could not load. Please try again.');
    }
  }
  useEffect(() => { void load(); }, []); // eslint-disable-line react-hooks/exhaustive-deps

  // 처음 열 때 가장 이른 열린 시각으로 스크롤 (이른 새벽 칸은 위로)
  const firstOpen = data ? Math.min(...data.weeklyOpen.map((k) => toMin(k.slice(2))), 24 * 60) : null;
  useEffect(() => {
    if (!data || !scroller.current || firstOpen === null) return;
    const row = scroller.current.querySelector<HTMLElement>(`[data-row="${firstOpen}"]`);
    if (row) scroller.current.scrollTop = Math.max(0, row.offsetTop - 40);
  }, [data, firstOpen]);

  if (!data) {
    return (
      <Panel onClose={onClose}>
        {err ? <p className="p-4 text-[14px] text-[#b3261e]">{err}</p> : <p className="p-4 text-[15px] text-[#6b6880]">Loading…</p>}
      </Panel>
    );
  }

  const d = data;
  const baseOnce = Object.keys(d.cells).filter((k) => d.cells[k] === 'b');
  const w = diff(d.weeklyOpen, weekly);
  const o = diff(baseOnce, once);
  const lines = describeChanges({ weeklyOpen: w.added, weeklyClose: w.removed, onceClose: o.added, onceOpen: o.removed }, 'en');
  const weeklyChanged = w.added.length + w.removed.length > 0;
  const monday = plusDays(d.monday, wk * 7);
  const dates = WEEK_DAYS.map((_, i) => plusDays(monday, i));
  const code = (k: string): CellCode => d.cells[k] ?? 'o';
  const toggle = (set: Set<string>, k: string, setter: (s: Set<string>) => void) => {
    const n = new Set(set);
    if (n.has(k)) n.delete(k);
    else n.add(k);
    setter(n);
  };

  function close() {
    if (lines.length > 0 && !window.confirm('Discard changes?')) return;
    onClose();
  }
  async function save() {
    setBusy(true);
    setSaveErr('');
    try {
      await actions.save(weeklyChanged ? [...weekly] : null, o.added, o.removed);
      await load();
      setDialog({ kind: 'saved' });
    } catch (e) {
      setSaveErr(e instanceof Error ? e.message : 'Could not save. Please try again.');
    } finally {
      setBusy(false);
    }
  }

  function weekCell(dow: number, t: string) {
    const cl = weeklyClassAt(d.weeklyClasses, dow, t);
    if (cl) {
      return (
        <button type="button" className={`${cellBase} truncate px-0.5 bg-[#5b3fe0] text-white ${cl.first ? '' : cont}`} aria-label={`Every ${FULL[dow]} ${timeText(toMin(t))} class with ${cl.c.student}`}
          onClick={() => setDialog({ kind: 'info', title: `Weekly class · ${cl.c.student}`, body: [
            `Every ${FULL[dow]} ${span(cl.c.time, cl.c.min)} (${cl.c.min} min). You can’t close this time while the class is here.`,
            'To stop teaching this slot, please tell the Edge English team. We’ll move the class with the student first.'] })}>
          {cl.first ? lessonLabel(cl.c.student, cl.c.min) : ''}
        </button>
      );
    }
    const k = `${dow}:${t}`;
    const isOpen = weekly.has(k);
    const changed = isOpen !== d.weeklyOpen.includes(k);
    return (
      <button type="button" aria-label={`Every ${FULL[dow]} ${timeText(toMin(t))} ${isOpen ? 'open' : 'closed'}`} aria-pressed={isOpen}
        onClick={() => toggle(weekly, k, setWeekly)}
        className={`${cellBase} ${isOpen ? 'bg-[#e6f6ec] text-[#1f7a4d]' : 'bg-[#ecebf1] text-[#8a879c]'} ${changed ? 'ring-2 ring-inset ring-[#5b3fe0]' : ''}`} />
    );
  }

  function onceCell(date: string, t: string) {
    const k = `${date}T${t}`;
    const c = code(k);
    const when = `${dateText(date)} ${timeText(toMin(t))}`;
    if (c === 'c') {
      const ls = lessonAt(d.lessons, date, t);
      const name = ls?.l.student ?? '';
      return (
        <button type="button" aria-label={`${when} ${ls?.l.makeup ? 'make-up' : 'class'} with ${name}`}
          className={`${cellBase} truncate px-0.5 ${ls?.l.makeup ? 'bg-[#d9d1ff] text-[#3a2a99]' : 'bg-[#5b3fe0] text-white'} ${ls && !ls.first ? cont : ''}`}
          onClick={() => setDialog({ kind: 'info', title: `${name} · ${ls ? `${dateText(date)} ${span(ls.l.start.slice(11, 16), ls.l.min)}` : when}`, body: [
            `${ls?.l.makeup ? 'Make-up' : 'Class'}${ls ? ` (${ls.l.min} min)` : ''}. This time has a class, so it can’t be closed here.`,
            'Can’t teach this class? Please tell the Edge English team.'] })}>
          {ls?.first ? lessonLabel(ls.l.student, ls.l.min) : ''}
        </button>
      );
    }
    if (c === 'r') {
      return (
        <button type="button" aria-label={`${when} request waiting`} className={`${cellBase} border border-dashed border-[#5b3fe0] bg-white text-[#5b3fe0]`}
          onClick={() => setDialog({ kind: 'info', title: `Request · ${when}`, body: ['A make-up or cover request is waiting for this time, so it can’t be closed here.'] })}>
          Request
        </button>
      );
    }
    if (c === 'l') {
      return (
        <button type="button" aria-label={`${when} leave`} className={`${cellBase} bg-[#ecebf1] text-[#8a879c]`}
          onClick={() => setDialog({ kind: 'info', title: `Leave · ${when}`, body: ['This time is in your leave.'] })}>
          Leave
        </button>
      );
    }
    if (c === 'p') return <span aria-hidden className={`${cellBase} block bg-[#f6f5fa]`} />;
    if (c === 's') {
      return (
        <button type="button" aria-label={`${when} closed every week`} className={`${cellBase} bg-[#ecebf1]`}
          onClick={() => setDialog({ kind: 'info', title: 'Closed every week', body: [`${FULL[new Date(`${date}T00:00:00Z`).getUTCDay()]} ${timeText(toMin(t))} is closed in Every week. Change it there.`] })} />
      );
    }
    const shut = once.has(k);
    const changed = shut !== baseOnce.includes(k);
    return (
      <button type="button" aria-label={`${when} ${shut ? 'unavailable this week' : 'open'}`} aria-pressed={shut}
        onClick={() => toggle(once, k, setOnce)} style={shut ? hatch : undefined}
        className={`${cellBase} ${shut ? 'text-[#b3261e]' : 'bg-[#e6f6ec] text-[#1f7a4d]'} ${changed ? 'ring-2 ring-inset ring-[#5b3fe0]' : ''}`} />
    );
  }

  function dayHead(i: number) {
    const dow = WEEK_DAYS[i];
    if (tab === 'week') return <div className="sticky top-0 z-[1] bg-white py-1 text-center text-[12px] font-bold text-[#1d1b2b]">{SHORT[dow]}</div>;
    const date = dates[i];
    const free = d.times.map((t) => `${date}T${t}`).filter((k) => code(k) === 'o' || code(k) === 'b');
    const allShut = free.length > 0 && free.every((k) => once.has(k));
    return (
      <button type="button" disabled={free.length === 0} onClick={() => setDialog({ kind: 'day', date, free, allShut })}
        aria-label={`${FULL[dow]} ${dateText(date)}: close or open the whole day`}
        className="sticky top-0 z-[1] bg-white py-1 text-center text-[12px] font-bold leading-tight text-[#1d1b2b] disabled:text-[#8a879c]">
        {SHORT[dow]}<small className="block text-[11px] font-medium text-[#6b6880]">{date.slice(8).replace(/^0/, '')}</small>
      </button>
    );
  }

  const changesBox = (
    <div className="grid gap-2 rounded-[12px] border border-[#e6e3ef] bg-white p-3">
      <strong className="text-[15px] text-[#1d1b2b]">Changes</strong>
      {lines.length > 0
        ? <ul className="list-disc pl-5 text-[13.5px] text-[#1d1b2b]">{lines.map((x) => <li key={x}>{x}</li>)}</ul>
        : <p className="text-[13px] text-[#6b6880]">No changes</p>}
      <button type="button" disabled={lines.length === 0} onClick={() => { setSaveErr(''); setDialog({ kind: 'save' }); }} className={btnMain}>
        Save{lines.length > 0 ? ` (${lines.length})` : ''}
      </button>
    </div>
  );

  const history = d.history && (
    <section className="mt-4 rounded-[12px] border border-[#e6e3ef] bg-white p-3">
      <h3 className="mb-1 text-[14px] font-bold text-[#1d1b2b]">바뀐 기록</h3>
      {d.history.length === 0 && <p className="text-[13px] text-[#6b6880]">없음</p>}
      <ul className="grid gap-2">
        {d.history.map((h) => (
          <li key={h.at.toISOString()} className="text-[13px] text-[#1d1b2b]">
            <b>{h.at.toLocaleString('ko-KR', { timeZone: 'Asia/Seoul', month: 'numeric', day: 'numeric', hour: '2-digit', minute: '2-digit' })}</b>
            <span className="text-[#6b6880]"> · {h.byAdmin ? '운영자' : '강사 본인'}</span>
            {(h.changes.weeklyOpen.length + h.changes.weeklyClose.length > 0) && <span className="text-[#6b6880]"> · 매주 변경 {fromText(h.changes.from, 'ko')}</span>}
            <ul className="list-disc pl-5">{describeChanges(h.changes, 'ko').map((x) => <li key={x}>{x}</li>)}</ul>
          </li>
        ))}
      </ul>
    </section>
  );

  return (
    <Panel onClose={close} sub={d.tutor.timezone}>
      <div className="flex min-h-0 flex-1 gap-5 lg:p-1">
        <div className="flex min-h-0 min-w-0 flex-1 flex-col">
          <div role="tablist" className="mb-2 grid grid-cols-2 rounded-[11px] bg-[#ecebf1] p-[3px]">
            {(['week', 'once'] as const).map((t) => (
              <button key={t} type="button" role="tab" aria-selected={tab === t} onClick={() => setTab(t)}
                className={`min-h-[38px] rounded-[9px] text-[14px] font-semibold ${tab === t ? 'bg-white text-[#1d1b2b] shadow-sm' : 'text-[#6b6880]'}`}>
                {t === 'week' ? 'Every week' : 'One week only'}
              </button>
            ))}
          </div>
          <p className="mb-1.5 text-[12.5px] text-[#6b6880]">
            {tab === 'week'
              ? `Tap a time to open or close it every week. Green = students can book a class starting then. ${fromText(d.from, 'en')}`
              : 'Close free times for this week only. Tap a day to close the whole day.'}
          </p>
          {tab === 'once' && (
            <div className="mb-1.5 flex items-center justify-between">
              <button type="button" aria-label="Previous week" disabled={wk === 0} onClick={() => setWk(wk - 1)} className={`${btnSub} min-h-[34px] px-3`}>‹</button>
              <b className="text-[14px] text-[#1d1b2b]">{weekText(monday)}</b>
              <button type="button" aria-label="Next week" disabled={wk === WEEKS - 1} onClick={() => setWk(wk + 1)} className={`${btnSub} min-h-[34px] px-3`}>›</button>
            </div>
          )}
          <div className="mb-1.5 flex flex-wrap gap-x-3 gap-y-1 text-[12px] text-[#6b6880]">
            <Legend color="bg-[#e6f6ec]">Open</Legend>
            <Legend color="bg-[#ecebf1]">Closed</Legend>
            {tab === 'once' && <Legend style={hatch}>Unavailable this week</Legend>}
            <Legend color="bg-[#5b3fe0]">Class</Legend>
            {tab === 'once' && <Legend color="bg-[#d9d1ff]">Make-up</Legend>}
            {tab === 'once' && <Legend color="border border-dashed border-[#5b3fe0]">Request</Legend>}
          </div>
          <div ref={scroller} className="min-h-0 flex-1 overflow-y-auto border-t border-[#e6e3ef] lg:max-h-[560px] lg:flex-none">
            <div className="grid grid-cols-[42px_repeat(7,minmax(0,1fr))] gap-[2px] pb-2 pt-1 tabular-nums">
              <div className="sticky top-0 z-[1] bg-white" />
              {WEEK_DAYS.map((_, i) => <div key={i} className="contents">{dayHead(i)}</div>)}
              {d.times.map((t) => (
                <div key={t} className="contents">
                  <div data-row={toMin(t)} className="pr-1 text-right text-[11px] leading-[26px] text-[#6b6880]">{t.endsWith('00') ? timeText(toMin(t)) : ''}</div>
                  {WEEK_DAYS.map((dow, i) => <div key={dow}>{tab === 'week' ? weekCell(dow, t) : onceCell(dates[i], t)}</div>)}
                </div>
              ))}
            </div>
            <div className="lg:hidden">{history}</div>
          </div>
        </div>
        <aside className="hidden w-[280px] shrink-0 content-start gap-3 lg:grid">
          {changesBox}
          {history}
        </aside>
      </div>
      <div className="flex items-center gap-2 border-t border-[#e6e3ef] bg-white px-1 pb-1 pt-2.5 lg:hidden">
        <span className="flex-1 text-[13px] text-[#6b6880]">{lines.length > 0 ? `${lines.length} change${lines.length > 1 ? 's' : ''} not saved` : 'No changes'}</span>
        <button type="button" disabled={lines.length === 0} onClick={() => { setSaveErr(''); setDialog({ kind: 'save' }); }} className={btnMain}>Save</button>
      </div>

      {dialog && (
        <div className="absolute inset-0 z-10 flex items-end justify-center bg-black/40 lg:items-center" onClick={(e) => { if (e.target === e.currentTarget && !busy) setDialog(null); }}>
          <div role="dialog" aria-modal="true" className="grid w-full gap-2.5 rounded-t-[18px] bg-white p-4 pb-5 lg:max-w-[440px] lg:rounded-[16px]">
            {dialog.kind === 'info' && (
              <>
                <strong className="text-[16px] text-[#1d1b2b]">{dialog.title}</strong>
                {dialog.body.map((x) => <p key={x} className="text-[14.5px] text-[#1d1b2b]">{x}</p>)}
                <button type="button" onClick={() => setDialog(null)} className={btnSub}>Close</button>
              </>
            )}
            {dialog.kind === 'day' && (
              <>
                <strong className="text-[16px] text-[#1d1b2b]">{FULL[new Date(`${dialog.date}T00:00:00Z`).getUTCDay()]} {dateText(dialog.date).slice(4)}</strong>
                <p className="text-[14.5px] text-[#1d1b2b]">{dialog.allShut ? 'Open all free times on this day again?' : 'Close all free times on this day, just this week?'}</p>
                <p className="text-[13px] text-[#6b6880]">Classes stay as they are.</p>
                <button type="button" className={btnMain} onClick={() => {
                  const n = new Set(once);
                  dialog.free.forEach((k) => (dialog.allShut ? n.delete(k) : n.add(k)));
                  setOnce(n);
                  setDialog(null);
                }}>{dialog.allShut ? 'Open the day' : 'Close the day'}</button>
                <button type="button" onClick={() => setDialog(null)} className={btnSub}>Close</button>
              </>
            )}
            {dialog.kind === 'save' && (
              <>
                <strong className="text-[16px] text-[#1d1b2b]">Save these changes?</strong>
                <ul className="list-disc pl-5 text-[14px] text-[#1d1b2b]">{lines.map((x) => <li key={x}>{x}</li>)}</ul>
                {weeklyChanged && <p className="text-[13px] text-[#6b6880]">{fromText(d.from, 'en')}</p>}
                <p className="text-[13px] text-[#6b6880]">Students can no longer pick closed times for make-ups. Your classes don’t change.</p>
                {saveErr && <p role="alert" className="text-[14px] text-[#b3261e]">{saveErr}</p>}
                <button type="button" disabled={busy} onClick={save} className={btnMain}>{busy ? 'Saving…' : 'Save'}</button>
                <button type="button" disabled={busy} onClick={() => setDialog(null)} className={btnSub}>Back</button>
              </>
            )}
            {dialog.kind === 'saved' && (
              <>
                <strong className="text-[16px] text-[#1f7a4d]">Saved ✓</strong>
                <button type="button" onClick={() => setDialog(null)} className={btnSub}>Close</button>
              </>
            )}
          </div>
        </div>
      )}
    </Panel>
  );
}

function Panel({ onClose, sub, children }: { onClose: () => void; sub?: string; children: ReactNode }) {
  return (
    <div className="fixed inset-0 z-40 flex justify-center bg-black/40 lg:items-center">
      <div role="dialog" aria-modal="true" aria-label="My hours"
        className="relative flex h-full w-full flex-col bg-white px-3 pt-3 lg:h-auto lg:max-h-[94vh] lg:max-w-[1080px] lg:rounded-[20px] lg:p-5">
        <div className="mb-2 flex items-start justify-between gap-2">
          <div>
            <h2 className="text-[18px] font-bold text-[#1d1b2b]">My hours</h2>
            {sub && <p className="text-[12.5px] text-[#6b6880]">Your time · {sub}</p>}
          </div>
          <button type="button" aria-label="Close" onClick={onClose}
            className="flex h-[40px] w-[40px] items-center justify-center rounded-[10px] border border-[#e6e3ef] text-[18px] text-[#1d1b2b]">✕</button>
        </div>
        {children}
      </div>
    </div>
  );
}

function Legend({ color = '', style, children }: { color?: string; style?: CSSProperties; children: ReactNode }) {
  return (
    <span className="inline-flex items-center gap-1">
      <i aria-hidden className={`inline-block h-[12px] w-[14px] rounded-[3px] ${color}`} style={style} />
      {children}
    </span>
  );
}
