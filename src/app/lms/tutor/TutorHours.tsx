'use client';

// 강사 매주 가능 시간 [Availability] (예전 My hours, 시안 docs/lms/previews/tutor-hours-drafts.html, 대표 확정 10/29)
//  매주 수업 시작 가능 칸 (다음 주 월요일부터). 2026-11-04 H26(50): 'One week only' 탭 없앰 → 날짜별 막기·열기는 Schedule 에서
//  화면 잠금은 편의일 뿐, 고정 수업 칸 검사는 DB 함수 tutor_hours_save 가 다시 함 (migration 3100)

import { TUTOR_MENU } from '@/lms/tutor/navigation';
import { useEffect, useRef, useState, type CSSProperties, type ReactNode } from 'react';
import {
  classFill, describeChanges, describeChangesIn, diff, applyFromText, fromText, hhmm, plusDays, rangeText, timeText, toMin, WEEK_DAYS, weeklyClassAt, type HoursData,
} from '@/lms/tutor/hours';
import { KOREA_TIME } from '@/lms/tutor/screen';
import { useSavedValue } from './useSaved';

import { ALL_HOURS, cityTime, sourceCell } from '@/lms/tutor/hours-view';

export type HoursActions = {
  load: () => Promise<HoursData>;
  save: (weekly: string[] | null, close: string[], open: string[]) => Promise<void>;
};

const SHORT = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];
const FULL = ['Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday'];
const btnMain = 'min-h-[44px] rounded-[10px] bg-[#5b3fe0] px-4 text-[15px] font-semibold text-white disabled:opacity-40';
const btnSub = 'min-h-[44px] rounded-[10px] border border-[#e6e3ef] bg-white px-4 text-[15px] font-semibold text-[#1d1b2b] disabled:opacity-40';
const cellBase = 'block h-[26px] w-full overflow-hidden whitespace-nowrap rounded-[5px] p-0 text-[10.5px] font-semibold lg:h-[24px] lg:text-[11.5px]';
const span = (start: string, min: number) => rangeText(start, hhmm(toMin(start) + min));
/** 수업 시작 칸 글 (대표 10/29): 휴대폰 = 수강생 이름(칸이 좁아 이름 앞부분), PC = 이름 + 길이. 정확한 시각은 누르면 창에 */
const lessonLabel = (student: string, min: number) => (
  <><span className="[color:inherit] lg:hidden">{student.split(' ')[0]}</span><span className="hidden [color:inherit] lg:inline">{student} · {min}m</span></>
);
/** 같은 수업의 다음 칸은 위 칸과 붙여 한 덩어리로 */
const cont = '-mt-[2px] h-[28px] rounded-t-none lg:h-[26px]';
/** 수업 칸 색: 실제 수업 분만큼만 보라, 같은 칸의 나머지는 닫힘 회색 (40분 수업 → 둘째 칸 위 10분만 보라). 투명이면 칸이 빈 것처럼 보임 (대표 11/4) */
const fillStyle = (f: { from: number; to: number }, dark: string, pale: string): CSSProperties => (f.from <= 0 && f.to >= 1
  ? { background: dark }
  : { background: `linear-gradient(to bottom, ${pale} ${f.from * 100}%, ${dark} ${f.from * 100}%, ${dark} ${f.to * 100}%, ${pale} ${f.to * 100}%)` });
/** 바꿀 수 없는 칸: 닫힘(회색)과 헷갈리지 않게 빗금 (대표 11/4) */
const cantChange: CSSProperties = { background: 'repeating-linear-gradient(-45deg,#e3e1ea,#e3e1ea 2px,#fafafd 2px,#fafafd 7px)' };

type Dialog =
  | { kind: 'info'; title: string; body: string[] }
  | { kind: 'save' }
  | { kind: 'saved'; weekly: boolean; from: string };

/** inline = 메뉴 안에 그대로 (2026-11-04 사이드바), 아니면 창 */
export default function TutorHours({ actions, onClose, onSchedule, inline = false, onDirty, onSaved }: { actions: HoursActions; onClose: () => void; onSchedule?: () => void; inline?: boolean; /** 저장 안 한 변경이 있는지 알림 — 메뉴를 바꿀 때 확인 (QA UX) */ onDirty?: (dirty: boolean) => void; /** 저장 성공 뒤 — Home 의 보강 요청·충돌 자료를 다시 읽게 (R-13) */ onSaved?: () => void | Promise<void> }) {
  const [data, setData] = useState<HoursData | null>(null);
  const [err, setErr] = useState('');
  // 예전 탭 기억(Every week / One week only)은 탭이 없어져 지움
  useEffect(() => { try { localStorage.removeItem('lms_tutor_hours_tab'); } catch { /* 저장 안 되는 브라우저 */ } }, []);
  // 강사 도시 시간 / 한국 시간 따로 보기, 마지막에 고른 쪽을 이 기기에 기억 (2026-11-04 대표)
  const [zone, setZone] = useSavedValue<'local' | 'kst'>('lms_tutor_hours_zone', 'local', ['local', 'kst']);
  const [weekly, setWeekly] = useState<Set<string>>(new Set());
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

  // 저장 안 한 변경 → 바깥(메뉴 바꾸기)에 알리고, 창을 닫거나 떠날 때 브라우저 확인 (QA UX: 미저장 이동 손실)
  const dirtyCount = data ? (() => { const x = diff(data.weeklyOpen, weekly); return x.added.length + x.removed.length; })() : 0;
  useEffect(() => {
    onDirty?.(dirtyCount > 0);
    if (dirtyCount === 0) return;
    const warn = (e: BeforeUnloadEvent) => e.preventDefault();
    window.addEventListener('beforeunload', warn);
    return () => { onDirty?.(false); window.removeEventListener('beforeunload', warn); };
  }, [dirtyCount, onDirty]);

  if (!data) {
    return (
      <Panel onClose={onClose} inline={inline} onSchedule={onSchedule}>
        {err ? <p className="p-4 text-[14px] text-[#b3261e]">{err}</p> : <p className="p-4 text-[15px] text-[#6b6880]">Loading…</p>}
      </Panel>
    );
  }

  const d = data;
  const localLabel = cityTime(d.tutor.timezone);
  const koreaTime = zone === 'kst' && d.tutor.timezone !== 'Asia/Seoul';
  const viewZone = koreaTime ? 'Asia/Seoul' : d.tutor.timezone;
  const viewLabel = koreaTime ? KOREA_TIME : localLabel;
  const w = diff(d.weeklyOpen, weekly);
  // 바뀐 내용은 고른 시간대 기준 + 다른 시간대 보조 (2026-11-04 대표 8번). 저장 키는 강사 현지 그대로
  const lines = describeChangesIn({ weeklyOpen: w.added, weeklyClose: w.removed, onceClose: [], onceOpen: [] }, d.from, d.tutor.timezone, viewZone);
  const lineList = (cls: string) => (
    <ul className={`grid gap-1.5 ${cls}`}>
      {lines.map((x) => (
        <li key={x.main} className="list-none">
          <span className="block font-semibold">{x.main}</span>
          {x.sub && <span className="block text-[12.5px] text-[#6b6880]">{x.sub}</span>}
        </li>
      ))}
    </ul>
  );
  const weeklyChanged = w.added.length + w.removed.length > 0;
  const source = (date: string, t: string) => sourceCell(date, t, viewZone, d.tutor.timezone);
  const unavailable = <span title="Outside editable booking hours" className={`${cellBase} block`} style={cantChange} />;
  function displayCell(i: number, t: string) {
    const c = source(plusDays(d.from, i), t);
    if (!d.times.includes(c.time) && !weekly.has(`${c.dow}:${c.time}`) && !weeklyClassAt(d.weeklyClasses, c.dow, c.time)) return unavailable;
    return weekCell(c.dow, c.time, `Every ${FULL[WEEK_DAYS[i]]} ${timeText(toMin(t))} · ${viewLabel}`);
  }
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
      const saved = { weekly: weeklyChanged, from: d.from };
      await actions.save(weeklyChanged ? [...weekly] : null, [], []);
      await load();
      setDialog({ kind: 'saved', ...saved });
      void onSaved?.();
    } catch (e) {
      setSaveErr(e instanceof Error ? e.message : 'Could not save. Please try again.');
    } finally {
      setBusy(false);
    }
  }

  function weekCell(dow: number, t: string, when: string) {
    const cl = weeklyClassAt(d.weeklyClasses, dow, t);
    if (cl) {
      return (
        <button type="button" className={`${cellBase} truncate px-0.5 text-white ${cl.first ? (cl.c.min > 30 ? 'rounded-b-none' : '') : cont}`} aria-label={`${when} class with ${cl.c.student}`}
          style={fillStyle(classFill(toMin(cl.c.time), cl.c.min, toMin(t)), '#5b3fe0', '#ecebf1')}
          onClick={() => setDialog({ kind: 'info', title: `Weekly class · ${cl.c.student}`, body: [
            `Every ${FULL[dow]} ${span(cl.c.time, cl.c.min)} ${localLabel} (${cl.c.min} min). You can’t close this time while the class is here.`,
            'To stop teaching this slot, please tell the Edge English team. We’ll move the class with the student first.'] })}>
          {cl.first ? lessonLabel(cl.c.student, cl.c.min) : ''}
        </button>
      );
    }
    const k = `${dow}:${t}`;
    const isOpen = weekly.has(k);
    const changed = isOpen !== d.weeklyOpen.includes(k);
    return (
      <button type="button" aria-label={`${when} ${isOpen ? 'open' : 'closed'}`} aria-pressed={isOpen}
        onClick={() => toggle(weekly, k, setWeekly)}
        className={`${cellBase} ${isOpen ? 'bg-[#e6f6ec] text-[#1f7a4d]' : 'bg-[#ecebf1] text-[#8a879c]'} ${changed ? 'ring-2 ring-inset ring-[#5b3fe0]' : ''}`} />
    );
  }

  function dayHead(i: number) {
    return <div className="sticky top-0 z-[1] bg-white py-1 text-center text-[12px] font-bold text-[#1d1b2b]">{SHORT[WEEK_DAYS[i]]}</div>;
  }

  const changesBox = (
    <div className="grid gap-2 rounded-[12px] border border-[#e6e3ef] bg-white p-3">
      <strong className="text-[15px] text-[#1d1b2b]">Changes · {viewLabel}</strong>
      {lines.length > 0
        ? lineList('text-[13.5px] text-[#1d1b2b]')
        : <p className="text-[13px] text-[#6b6880]">No changes</p>}
      <button type="button" disabled={lines.length === 0} onClick={() => { setSaveErr(''); setDialog({ kind: 'save' }); }} className={btnMain}>
        Save{lines.length > 0 ? ` (${lines.length})` : ''}
      </button>
    </div>
  );

  const history = d.history && (
    // 운영자 보기에서만 나옴 → 운영자 보기 막대와 같은 모양으로 강사 화면과 구분 (R9)
    <section className="mt-4 overflow-hidden rounded-[12px] border border-[#1d1b2b] bg-white">
      <h3 className="mb-1 bg-[#1d1b2b] px-3 py-1.5 text-[13px] font-semibold text-white">운영자 보기 · 바뀐 기록</h3>
      <div className="px-3 pb-3">
      {d.history.length === 0 && <p className="text-[13px] text-[#6b6880]">없음</p>}
      <ul className="grid gap-2">
        {d.history.map((h) => (
          <li key={h.at.toISOString()} className="text-[13px] text-[#1d1b2b]">
            <b>{h.at.toLocaleString('ko-KR', { timeZone: 'Asia/Seoul', month: 'numeric', day: 'numeric', hour: 'numeric', minute: '2-digit', hourCycle: 'h12' })}</b>
            <span className="text-[#6b6880]"> · {h.byAdmin ? '운영자' : '강사 본인'}</span>
            {(h.changes.weeklyOpen.length + h.changes.weeklyClose.length > 0) && <span className="text-[#6b6880]"> · 매주 변경 {fromText(h.changes.from, 'ko')}</span>}
            <ul className="list-disc pl-5">{describeChanges(h.changes, 'ko').map((x) => <li key={x}>{x}</li>)}</ul>
          </li>
        ))}
      </ul>
      </div>
    </section>
  );

  return (
    <Panel onClose={close} sub={viewLabel} inline={inline} onSchedule={onSchedule}>
      <div className="flex min-h-0 flex-1 gap-5 lg:p-1">
        <div className="flex min-h-0 min-w-0 flex-1 flex-col">
          {d.tutor.timezone !== 'Asia/Seoul' && (
            <div role="group" aria-label="Timetable time zone" className="mb-2 flex flex-wrap gap-2">
              {[false, true].map((korea) => <button key={String(korea)} type="button" aria-pressed={koreaTime === korea}
                onClick={() => { setZone(korea ? 'kst' : 'local'); if (scroller.current) scroller.current.scrollTop = 0; }}
                className={`min-h-[44px] rounded-[10px] border px-4 text-[15px] font-semibold ${koreaTime === korea ? 'border-[#5b3fe0] bg-[#5b3fe0] text-white' : 'border-[#e6e3ef] bg-white text-[#1d1b2b]'}`}>
                {koreaTime === korea ? '✓ ' : ''}{korea ? KOREA_TIME : localLabel}
              </button>)}
            </div>
          )}
          <p className="mb-1.5 text-[13.5px] font-semibold text-[#1d1b2b]">{applyFromText(d.from)}</p>
          <p className="mb-1.5 text-[12.5px] text-[#6b6880]">Tap a time to open or close it every week. Green = students can book a class starting then.</p>
          {/* 왜 못 여는지 한 줄 (대표 11/4): 범위는 DB 가 준 시작 시각 목록(강사 현지 06:00~22:30, 2026-11-03 대표 결정)에서 읽음 */}
          <p className="mb-1.5 text-[12.5px] text-[#6b6880]">
            Striped = can’t open: outside {timeText(toMin(d.times[0]))}–{timeText(toMin(d.times[d.times.length - 1]))} {localLabel} (classes can only start in these hours).
          </p>
          <div className="mb-1.5 flex flex-wrap gap-x-3 gap-y-1 text-[12px] text-[#6b6880]">
            <Legend color="bg-[#e6f6ec]">Open</Legend>
            <Legend color="bg-[#ecebf1]">Closed</Legend>
            <Legend style={cantChange}>Can’t open</Legend>
            <Legend color="bg-[#5b3fe0]">Class</Legend>
          </div>
          <div ref={scroller} className={`min-h-0 flex-1 overflow-y-auto border-t border-[#e6e3ef] lg:max-h-[560px] lg:flex-none ${inline ? 'max-h-[58vh]' : ''}`}>
            <div className="grid grid-cols-[46px_repeat(7,minmax(0,1fr))] gap-[2px] pb-2 pt-1 tabular-nums">
              <div className="sticky top-0 z-[1] bg-white pr-1 text-right text-[10px] font-bold leading-tight text-[#2b1c7a]">{koreaTime ? 'KST' : localLabel}</div>
              {WEEK_DAYS.map((_, i) => <div key={i} className="contents">{dayHead(i)}</div>)}
              {ALL_HOURS.map((t) => (
                <div key={t} className="contents">
                  <div data-row={toMin(t)} className="pr-1 text-right text-[11px] leading-[26px] lg:leading-[24px] text-[#1d1b2b]">{t.endsWith('00') ? timeText(toMin(t)).replace(':00', '') : ''}</div>
                  {WEEK_DAYS.map((dow, i) => <div key={dow}>{displayCell(i, t)}</div>)}
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
      <div className={`flex items-center gap-2 border-t border-[#e6e3ef] bg-white px-1 pb-1 pt-2.5 lg:hidden ${inline ? 'sticky bottom-[64px] z-10 -mx-1 shadow-[0_64px_0_0_#fff]' : ''}`}>
        <span className="flex-1 text-[13px] text-[#6b6880]">{lines.length > 0 ? `${lines.length} change${lines.length > 1 ? 's' : ''} not saved` : 'No changes'}</span>
        <button type="button" disabled={lines.length === 0} onClick={() => { setSaveErr(''); setDialog({ kind: 'save' }); }} className={btnMain}>Save</button>
      </div>

      {dialog && (
        <div className={`${inline ? 'fixed z-50' : 'absolute z-10'} inset-0 flex items-end justify-center bg-black/40 lg:items-center`} onClick={(e) => { if (e.target === e.currentTarget && !busy) setDialog(null); }}>
          <div role="dialog" aria-modal="true" className="grid w-full gap-2.5 rounded-t-[18px] bg-white p-4 pb-5 lg:max-w-[440px] lg:rounded-[16px]">
            {dialog.kind === 'info' && (
              <>
                <strong className="text-[16px] text-[#1d1b2b]">{dialog.title}</strong>
                {dialog.body.map((x) => <p key={x} className="text-[14.5px] text-[#1d1b2b]">{x}</p>)}
                <button type="button" onClick={() => setDialog(null)} className={btnSub}>Close</button>
              </>
            )}
            {dialog.kind === 'save' && (
              <>
                <strong className="text-[16px] text-[#1d1b2b]">Save these changes?</strong>
                <p className="text-[12px] text-[#6b6880]">Times shown in {viewLabel}</p>
                {lineList('text-[14px] text-[#1d1b2b]')}
                {weeklyChanged && <p className="text-[13px] font-semibold text-[#3a22b0]">{applyFromText(d.from)}</p>}
                <p className="text-[13px] text-[#6b6880]">Students can no longer pick closed times for make-ups. Your classes don’t change.</p>
                {saveErr && <p role="alert" className="text-[14px] text-[#b3261e]">{saveErr}</p>}
                <button type="button" disabled={busy} onClick={save} className={btnMain}>{busy ? 'Saving…' : 'Save'}</button>
                <button type="button" disabled={busy} onClick={() => setDialog(null)} className={btnSub}>Back</button>
              </>
            )}
            {dialog.kind === 'saved' && (
              <>
                <strong className="text-[16px] text-[#1f7a4d]">Saved ✓</strong>
                {dialog.weekly && <p className="text-[14px] text-[#1d1b2b]">{applyFromText(dialog.from)} Until then your current hours stay the same.</p>}
                <button type="button" onClick={() => setDialog(null)} className={btnSub}>Close</button>
              </>
            )}
          </div>
        </div>
      )}
    </Panel>
  );
}

function Panel({ onClose, onSchedule, sub, inline, children }: { onClose: () => void; onSchedule?: () => void; sub?: string; inline?: boolean; children: ReactNode }) {
  const head = (
    <div className="mb-2 flex items-start justify-between gap-2">
      <div>
        <h2 className={`${inline ? 'text-[20px]' : 'text-[18px]'} font-bold text-[#1d1b2b]`}>{TUTOR_MENU.hours}</h2>
        <p className="text-[13.5px] text-[#55526a]">Set your regular weekly teaching hours here. For one-time changes, go to {onSchedule ? <button type="button" onClick={onSchedule} className="font-semibold text-[#5b3fe0] underline">{TUTOR_MENU.schedule}</button> : <>{TUTOR_MENU.schedule}</>}.</p>
        {sub && <p className="text-[12.5px] text-[#6b6880]">{sub}</p>}
      </div>
      {!inline && (
        <button type="button" aria-label="Close" onClick={onClose}
          className="flex h-[40px] w-[40px] items-center justify-center rounded-[10px] border border-[#e6e3ef] text-[18px] text-[#1d1b2b]">✕</button>
      )}
    </div>
  );
  if (inline) {
    return (
      <section aria-label={TUTOR_MENU.hours} className="relative flex min-h-[70vh] flex-col rounded-[16px] bg-white p-3 lg:p-4">
        {head}
        {children}
      </section>
    );
  }
  return (
    <div className="fixed inset-0 z-40 flex justify-center bg-black/40 lg:items-center">
      <div role="dialog" aria-modal="true" aria-label={TUTOR_MENU.hours}
        className="relative flex h-full w-full flex-col bg-white px-3 pt-3 lg:h-auto lg:max-h-[94vh] lg:max-w-[1080px] lg:rounded-[20px] lg:p-5">
        {head}
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
