'use client';

// 강사 Schedule (2026-11-04 대표 결정 H26(49)+(50), 시안 docs/lms/previews/tutor-schedule-drafts.html 시안 2 승인본)
//  Month = 한 달 수업(칸마다 수업 시각·학생, 다른 날 짧은 글자) / Week = 30분 칸 격자
//  수업은 보기만(옮기기·추가·삭제 없음, 누르면 창 → Class Record). 강사 본인 가능 시간만 날짜별로:
//  초록 칸 Block time · 회색 칸 Make available(그날만) · 막은 칸 Save note / Remove block
//  PC = 드래그 또는 클릭, 휴대폰 = 빈 칸 누름 → 끝 시간 → 메모(선택) → Block
//  화면 판정은 편의, 수업·6시간·12주·100자 검사는 DB 함수 tutor_schedule_save 가 다시 함 (migration 4403)

import { useCallback, useEffect, useRef, useState, type CSSProperties, type ReactNode } from 'react';
import { ALL_HOURS, cityTime, localToInstant } from '@/lms/tutor/hours-view';
import { classFill, plusDays, toMin } from '@/lms/tutor/hours';
import {
  addMonth, blockAt, cellKind, dayItems, dayTag, dayText, inZone, lessonTag, localInstant, mondayOf, monthGrid, monthTitle, NOTE_HELP, NOTE_MAX, otherZone,
  runFrom, slotText, slotTime, sourceKey, spanText, weekTitle, whenSpan, type CellKind, type DayItem, type ScheduleAction, type ScheduleBlock, type ScheduleData, isExtraCell,
} from '@/lms/tutor/schedule';
import { KOREA_TIME, minutesOf, statusText, type TutorLesson } from '@/lms/tutor/screen';
import { useSavedValue } from './useSaved';
import { ampmEn } from '@/lms/rules/dates';

export type ScheduleActions = {
  load: (from: string, to: string, cells: boolean) => Promise<ScheduleData>;
  save: (action: ScheduleAction, cells: string[] | null, note: string | null, blockId: string | null) => Promise<void>;
};

const btnMain = 'min-h-[44px] rounded-[10px] bg-[#5b3fe0] px-4 text-[15px] font-semibold text-white disabled:opacity-40';
const btnSub = 'min-h-[44px] rounded-[10px] border border-[#e6e3ef] bg-white px-4 text-[15px] font-semibold text-[#1d1b2b] disabled:opacity-40';
const cellBase = 'block h-[26px] w-full overflow-hidden whitespace-nowrap rounded-[5px] p-0 text-left text-[10.5px] font-semibold leading-[12px] lg:h-[24px] lg:text-[11px]';
const cont = '-mt-[2px] h-[28px] rounded-t-none lg:h-[26px]';
/** 바꿀 수 없는 칸 (지난 시간·6시간 안·시작 가능 시간 밖·12주 밖) — My hours 와 같은 흰 빗금 */
const cantChange: CSSProperties = { background: 'repeating-linear-gradient(-45deg,#e3e1ea,#e3e1ea 2px,#fafafd 2px,#fafafd 7px)' };
/** 막은 시간: 진한 빗금 + 테두리 */
const blockedStyle: CSSProperties = { background: 'repeating-linear-gradient(-45deg,#d6d2e4,#d6d2e4 3px,#f1eff7 3px,#f1eff7 7px)', boxShadow: 'inset 0 0 0 1px #a9a4bd' };
const fillStyle = (f: { from: number; to: number }, dark: string, pale: string): CSSProperties => (f.from <= 0 && f.to >= 1
  ? { background: dark }
  : { background: `linear-gradient(to bottom, ${pale} ${f.from * 100}%, ${dark} ${f.from * 100}%, ${dark} ${f.to * 100}%, ${pale} ${f.to * 100}%)` });
const WEEK_HEAD = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
const MONTH_HEAD = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];

/** xs = 칸마다 그날만 연 칸(x)인지 — Block 창에서 전부 x 면 '추가 개방 철회' (QA-03) */
type Pick = { kind: 'pick'; mode: 'block' | 'open'; date: string; kinds: CellKind[]; xs: boolean[]; start: number; end: number; note: string };
type Dialog =
  | Pick
  | { kind: 'blocked'; block: ScheduleBlock; note: string }
  | { kind: 'lesson'; lesson: TutorLesson }
  | { kind: 'info'; title: string; body: string };

export default function TutorSchedule({ actions, loadLessons, tz, now, onRecord, openProfile, onSaved }: {
  actions: ScheduleActions;
  /** 막기·열기 저장 성공 뒤 — Home 의 보강 요청 가능 여부 등을 다시 읽게 (R-13) */
  onSaved?: () => void | Promise<void>;
  /** 수업 (tutor_screen, 한국 날짜 범위) */
  loadLessons: (kstFrom: string, kstTo: string) => Promise<TutorLesson[]>;
  tz: string;
  now: Date;
  /** 수업 창 [Class Record] → 그 수업을 Class Record 에서 펼침 */
  onRecord: (l: TutorLesson) => void;
  openProfile?: ((studentId: string) => void) | null;
}) {
  // 마지막 보기·시간대를 이 기기에 기억 (H26(49) ④). 시간대는 Availability 와 같은 선택
  const [view, setView] = useSavedValue<'month' | 'week'>('lms_tutor_schedule_view', 'month', ['month', 'week']);
  const [zonePref, setZone] = useSavedValue<'local' | 'kst'>('lms_tutor_hours_zone', 'local', ['local', 'kst']);
  const korea = zonePref === 'kst' && tz !== 'Asia/Seoul';
  const viewZone = korea ? 'Asia/Seoul' : tz;
  const viewLabel = korea ? KOREA_TIME : cityTime(tz);
  const other = otherZone(viewZone, tz);
  const todayView = inZone(now, viewZone).date;
  const [anchor, setAnchor] = useState(todayView);
  const [selected, setSelected] = useState(todayView);
  const [data, setData] = useState<ScheduleData | null>(null);
  const [lessons, setLessons] = useState<TutorLesson[]>([]);
  const [err, setErr] = useState('');
  const [loading, setLoading] = useState(false);
  const [dialog, setDialog] = useState<Dialog | null>(null);
  const [busy, setBusy] = useState(false);
  const [saveErr, setSaveErr] = useState('');
  const [toast, setToast] = useState('');
  const scroller = useRef<HTMLDivElement>(null);
  // 휴대폰: 날짜를 누르면 아래 그날 목록이 보이게
  const dayRef = useRef<HTMLElement>(null);

  const month = anchor.slice(0, 7);
  const monday = mondayOf(anchor);
  const grid = view === 'month' ? monthGrid(month) : Array.from({ length: 7 }, (_, i) => plusDays(monday, i));
  const from = grid[0];
  const to = grid[grid.length - 1];

  const load = useCallback(async () => {
    setLoading(true);
    setErr('');
    try {
      // 보는 시간대 날짜 ±1일 (강사 현지·한국 날짜가 하루씩 다를 수 있음)
      const [d, ls] = await Promise.all([actions.load(plusDays(from, -1), plusDays(to, 1), view === 'week'), loadLessons(plusDays(from, -1), plusDays(to, 1))]);
      setData(d);
      setLessons(ls);
    } catch (e) {
      setErr(e instanceof Error ? e.message : 'Could not load. Please try again.');
    } finally {
      setLoading(false);
    }
  }, [actions, loadLessons, from, to, view]);
  useEffect(() => { void load(); }, [load]);
  useEffect(() => {
    if (!toast) return;
    const t = setTimeout(() => setToast(''), 2500);
    return () => clearTimeout(t);
  }, [toast]);

  const live = lessons.filter((l) => l.state !== 'canceled');
  /** 그 칸(보는 시간대 date·time 부터 30분)에 걸친 수업 */
  const lessonIn = (date: string, time: string) => {
    const a = +localToInstant(date, time, viewZone);
    return live.find((l) => +l.startsAt < a + 30 * 60000 && a < +l.endsAt) ?? null;
  };
  const kindsOf = (date: string, src: ScheduleData): CellKind[] =>
    ALL_HOURS.map((t) => cellKind(sourceKey(date, t, viewZone, tz), src, !!lessonIn(date, t)));
  const xsOf = (date: string, src: ScheduleData): boolean[] => ALL_HOURS.map((t) => isExtraCell(sourceKey(date, t, viewZone, tz), src));
  const keysOf = (date: string, a: number, b: number) => Array.from({ length: b - a }, (_, i) => sourceKey(date, slotTime(a + i), viewZone, tz));
  const at = (date: string, i: number) => localToInstant(date, slotTime(i), viewZone);
  const lastLocal = data?.last ?? to;

  function move(n: number) {
    setAnchor(view === 'month' ? `${addMonth(month, n)}-01` : plusDays(monday, n * 7));
  }
  function goToday() {
    setAnchor(todayView);
    setSelected(todayView);
  }

  function openPick(mode: 'block' | 'open', date: string, src: ScheduleData, start: number, end?: number) {
    setSaveErr('');
    const kinds = kindsOf(date, src);
    setDialog({ kind: 'pick', mode, date, kinds, xs: xsOf(date, src), start, end: end ?? start + 1, note: '' });
  }
  /** span: 그날 목록의 '추가 개방' 줄에서 열 때 그 시간 범위(QA-03: 추가 개방 줄에서 바로 철회) */
  async function pickFromMonth(mode: 'block' | 'open', date: string, span?: { at: Date; end: Date }) {
    // Month 에서는 칸 판정을 그날만 따로 읽음
    setBusy(true);
    try {
      const src = await actions.load(plusDays(date, -1), plusDays(date, 1), true);
      const kinds = kindsOf(date, src);
      const want = mode === 'block' ? 'free' : 'closed';
      const first = span ? Math.max(0, Math.round((toMin(inZone(span.at, viewZone).time) - toMin(ALL_HOURS[0])) / 30)) : kinds.indexOf(want);
      const last = span ? first + Math.max(1, Math.round((+span.end - +span.at) / 1800000)) : first + 1;
      if (kinds.every((k) => k === 'far' || k === 'outside')) {
        // 12주 밖 날짜 (R-21): '닫힌 시간 없음' 이 아니라 기간 제한 안내 (저장 함수도 같은 이유로 거절)
        setDialog({ kind: 'info', title: 'Can’t change yet', body: `You can change times up to 12 weeks ahead (until ${dayText(src.last)}).` });
      } else if (kinds.every((k) => k === 'past' || k === 'outside')) {
        setDialog({ kind: 'info', title: dayText(date), body: 'This day has passed.' });
      } else if (first < 0 || (span && kinds[first] !== want)) {
        // 추가 개방 줄에서 왔는데 그 칸이 비어 있지 않음 → 왜 못 거두는지 (R-16: 답 보낸 요청 등)
        const why = span ? lockReason(kinds[first]) : null;
        setDialog({ kind: 'info', title: why ? why.title : dayText(date), body: why ? why.body : mode === 'block' ? 'No available time to block on this day.' : 'No closed time to open on this day.' });
      } else {
        setSaveErr('');
        setDialog({ kind: 'pick', mode, date, kinds, xs: xsOf(date, src), start: first, end: Math.min(last, kinds.length), note: '' });
      }
    } catch (e) {
      setDialog({ kind: 'info', title: dayText(date), body: e instanceof Error ? e.message : 'Could not load. Please try again.' });
    } finally {
      setBusy(false);
    }
  }
  async function save(action: ScheduleAction, cells: string[] | null, note: string | null, blockId: string | null, done: string) {
    setBusy(true);
    setSaveErr('');
    try {
      await actions.save(action, cells, note, blockId);
      setDialog(null);
      setToast(done);
      await load();
      void onSaved?.();
    } catch (e) {
      setSaveErr(e instanceof Error ? e.message : 'Could not save. Please try again.');
    } finally {
      setBusy(false);
    }
  }

  function cellClick(date: string, i: number, k: CellKind) {
    if (!data) return;
    const t = slotTime(i);
    if (k === 'free') return openPick('block', date, data, i);
    if (k === 'closed') return openPick('open', date, data, i);
    if (k === 'class') { const l = lessonIn(date, t); if (l) setDialog({ kind: 'lesson', lesson: l }); return; }
    if (k === 'blocked') {
      const b = blockAt(data.blocks.filter((x) => x.kind === 'block'), at(date, i), tz);
      if (b) setDialog({ kind: 'blocked', block: b, note: b.note ?? '' });
      return;
    }
    if (k === 'leave') return setDialog({ kind: 'info', title: 'Leave', body: 'This time is in your leave.' });
    if (k === 'request' || k === 'answered') { const r = lockReason(k)!; return setDialog({ kind: 'info', title: r.title, body: r.body }); }
    if (k === 'locked') return setDialog({ kind: 'info', title: 'Can’t change', body: 'Can’t change: less than 6 hours away.' });
    if (k === 'outside') {
      return setDialog({ kind: 'info', title: 'Can’t change', body: `Classes can only start ${ampmEn(data.times[0])}–${ampmEn(data.times[data.times.length - 1])} ${cityTime(tz)}.` });
    }
    if (k === 'far') return setDialog({ kind: 'info', title: 'Can’t change yet', body: `You can change times up to 12 weeks ahead (until ${dayText(data.last)}).` });
  }

  // PC 드래그: 마우스로 초록(또는 회색) 칸을 끌면 이어진 같은 칸까지 선택 → 놓으면 창. 수업·다른 칸에서 멈춤
  const [drag, setDrag] = useState<{ date: string; want: CellKind; a: number; b: number } | null>(null);
  const pointer = useRef<string>('');
  useEffect(() => {
    if (!drag) return;
    const up = () => {
      if (data) openPick(drag.want === 'free' ? 'block' : 'open', drag.date, data, Math.min(drag.a, drag.b), Math.max(drag.a, drag.b) + 1);
      setDrag(null);
    };
    window.addEventListener('pointerup', up);
    return () => window.removeEventListener('pointerup', up);
  }, [drag, data]); // eslint-disable-line react-hooks/exhaustive-deps
  function dragOver(date: string, i: number, kinds: CellKind[]) {
    if (!drag || drag.date !== date) return;
    let b = drag.a;
    const step = i >= drag.a ? 1 : -1;
    while (b !== i && kinds[b + step] === drag.want) b += step;
    setDrag({ ...drag, b });
  }

  // Week: 처음·주를 바꿀 때 첫 시작 가능 시각으로 스크롤
  const weekKinds = view === 'week' && data ? grid.map((d) => kindsOf(d, data)) : null;
  const firstRow = weekKinds ? Math.min(...weekKinds.map((ks) => ks.findIndex((k) => k !== 'outside' && k !== 'past')).filter((x) => x >= 0), 48) : 48;
  useEffect(() => {
    if (view !== 'week' || !scroller.current || firstRow >= 48) return;
    const row = scroller.current.querySelector<HTMLElement>(`[data-row="${firstRow}"]`);
    if (row) scroller.current.scrollTop = Math.max(0, row.offsetTop - 36);
  }, [view, monday, viewZone, firstRow]);

  function weekCell(date: string, i: number, kinds: CellKind[]) {
    const k = kinds[i];
    const t = slotTime(i);
    const label = `${dayText(date)} ${ampmEn(t)} ${viewLabel}`;
    const sel = drag && drag.date === date && i >= Math.min(drag.a, drag.b) && i <= Math.max(drag.a, drag.b);
    const handlers = {
      onPointerDown: (e: React.PointerEvent) => {
        pointer.current = e.pointerType;
        if (e.pointerType === 'mouse' && (k === 'free' || k === 'closed')) { e.preventDefault(); setDrag({ date, want: k, a: i, b: i }); }
      },
      onPointerEnter: () => dragOver(date, i, kinds),
      onClick: () => {
        if (pointer.current === 'mouse' && (k === 'free' || k === 'closed')) return;   // 마우스는 드래그 놓을 때 창
        cellClick(date, i, k);
      },
    };
    if (k === 'class') {
      const l = lessonIn(date, t);
      if (!l) return <span className={cellBase} style={{ background: '#5b3fe0' }} />;
      const s = inZone(l.startsAt, viewZone);
      const sMin = s.date === date ? toMin(s.time) : -1440;
      const first = sMin >= i * 30;
      const f = classFill(sMin, minutesOf(l), i * 30);
      const makeup = l.kind !== 'regular' || l.covering;
      return (
        <button type="button" {...handlers} aria-label={`${label} class with ${l.student}`}
          className={`${cellBase} truncate px-1 ${makeup ? 'text-[#0f5f56]' : 'text-white'} ${first ? (f.to >= 1 && minutesOf(l) > 30 - (sMin - i * 30) ? 'rounded-b-none' : '') : cont}`}
          style={fillStyle(f, makeup ? '#9fe0d6' : '#5b3fe0', '#ecebf1')}>
          {first ? <span className="[color:inherit]">{l.student.split(' ')[0]} <span className="hidden font-medium [color:inherit] lg:inline">{ampmEn(s.time)}</span></span> : ''}
        </button>
      );
    }
    if (k === 'past' || k === 'outside' || k === 'far' || k === 'locked') {
      if (k === 'past') return <span aria-hidden className={cellBase} style={cantChange} />;
      return <button type="button" {...handlers} aria-label={`${label} can’t change`} className={cellBase} style={cantChange} />;
    }
    if (k === 'blocked') {
      const b = data ? blockAt(data.blocks.filter((x) => x.kind === 'block'), at(date, i), tz) : null;
      const firstOf = !b || i === 0 || kinds[i - 1] !== 'blocked' || blockAt(data!.blocks.filter((x) => x.kind === 'block'), at(date, i - 1), tz)?.id !== b.id;
      return (
        <button type="button" {...handlers} aria-label={`${label} blocked${b?.note ? `: ${b.note}` : ''}`}
          className={`${cellBase} truncate px-1 text-[#3d3a52] ${firstOf ? '' : cont}`} style={blockedStyle}>
          {firstOf ? (b?.note || 'Blocked') : ''}
        </button>
      );
    }
    if (k === 'request') {
      return <button type="button" {...handlers} aria-label={`${label} request waiting`} className={`${cellBase} border border-dashed border-[#5b3fe0] bg-white px-1 text-[#5b3fe0]`}>Request</button>;
    }
    if (k === 'answered') {
      // 가능 답을 보냈고 운영진 확정 대기 (R-16): 답 대기와 구분
      return <button type="button" {...handlers} aria-label={`${label} answer sent, waiting for Edge English`} className={`${cellBase} border border-[#5b3fe0] bg-[#efebff] px-1 text-[#5b3fe0]`}>Sent ✓</button>;
    }
    if (k === 'leave') return <button type="button" {...handlers} aria-label={`${label} leave`} className={`${cellBase} bg-[#ecebf1] px-1 text-[#8a879c]`}>Leave</button>;
    const free = k === 'free';
    return (
      <button type="button" {...handlers} aria-label={`${label} ${free ? 'available' : 'not available'}`}
        className={`${cellBase} ${sel ? 'bg-[#c9bfff]' : free ? 'bg-[#e6f6ec] hover:bg-[#cdeedb]' : 'bg-[#ecebf1] hover:bg-[#e0dee8]'}`} />
    );
  }

  const header = (
    <div className="mb-2 grid gap-2 lg:flex lg:flex-wrap lg:items-center">
      <div className="flex items-center justify-between gap-2 lg:mr-auto">
        <h1 className="text-[20px] font-bold text-[#1d1b2b] lg:mr-3">Schedule</h1>
        <Seg value={view} onChange={(v) => setView(v)} options={[['month', 'Month'], ['week', 'Week']]} className="lg:hidden" />
      </div>
      <div className="flex items-center gap-2">
        <button type="button" aria-label={view === 'month' ? 'Previous month' : 'Previous week'} disabled={loading} onClick={() => move(-1)} className={`${btnSub} shrink-0 px-3`}>‹</button>
        <p aria-live="polite" className="min-w-0 flex-1 text-center text-[15px] font-semibold text-[#1d1b2b] lg:min-w-[150px]">
          {view === 'month' ? monthTitle(month) : <>{weekTitle(monday)}<span className="font-normal text-[#6b6880] lg:hidden"> · {korea ? 'KST' : cityTime(tz)}</span></>}
        </p>
        <button type="button" aria-label={view === 'month' ? 'Next month' : 'Next week'} disabled={loading} onClick={() => move(1)} className={`${btnSub} shrink-0 px-3`}>›</button>
        <button type="button" onClick={goToday} className={`${btnSub} shrink-0 px-3 text-[14px]`}>Today</button>
      </div>
      <div className="flex flex-wrap items-center gap-2">
        <Seg value={view} onChange={(v) => setView(v)} options={[['month', 'Month'], ['week', 'Week']]} className="hidden lg:inline-flex" />
        {tz !== 'Asia/Seoul' && (
          <Seg value={korea ? 'kst' : 'local'} onChange={(v) => setZone(v)} options={[['local', cityTime(tz)], ['kst', KOREA_TIME]]} check />
        )}
      </div>
    </div>
  );

  const legend = (
    <div className="mb-1.5 flex flex-wrap gap-x-3 gap-y-1 text-[12px] text-[#6b6880]">
      <Legend color="bg-[#e6f6ec]">Available</Legend>
      <Legend color="bg-[#ecebf1]">Not available</Legend>
      <Legend color="bg-[#5b3fe0]">Class</Legend>
      <Legend style={blockedStyle}>Blocked</Legend>
      <Legend style={cantChange}>Can’t change</Legend>
      <Legend color="bg-[#efebff] border border-[#5b3fe0]">Sent ✓ (waiting for Edge English)</Legend>
    </div>
  );

  // 그날 목록 (Month 에서 날짜 누름)
  const items = dayItems(selected, viewZone, lessons, data);
  const inRange = data ? selected >= todayView && selected <= plusDays(lastLocal, korea ? 1 : 0) : false;
  const dayPanel = (
    <section ref={dayRef} aria-label={`${dayText(selected)} schedule`} className="scroll-mb-[90px] rounded-[14px] border border-[#e6e3ef] bg-white p-3">
      <h2 className="mb-2 text-[16px] font-bold text-[#1d1b2b]">{dayText(selected)}{selected === todayView ? ' · Today' : ''}</h2>
      {items.length === 0 && <p className="mb-2 text-[14px] text-[#6b6880]">No classes</p>}
      <ul className="mb-3 grid gap-1.5">
        {items.map((it) => <DayRow key={`${it.kind}-${+it.at}-${it.kind === 'lesson' ? it.lesson.id : ''}`} item={it} zone={viewZone} onOpen={() => {
          if (it.kind === 'lesson') setDialog({ kind: 'lesson', lesson: it.lesson });
          else if (it.kind === 'block' && it.block.kind === 'block') { setSaveErr(''); setDialog({ kind: 'blocked', block: it.block, note: it.block.note ?? '' }); }
          else if (it.kind === 'block') setDialog({ kind: 'info', title: 'Leave', body: 'This time is in your leave.' });
          else if (it.kind === 'open') void pickFromMonth('block', selected, { at: it.at, end: it.end });
        }} />)}
      </ul>
      <div className="grid grid-cols-2 gap-2">
        <button type="button" disabled={!inRange || busy} onClick={() => pickFromMonth('block', selected)} className={`${btnMain} whitespace-nowrap px-2 text-[14px]`}>+ Block time</button>
        <button type="button" disabled={!inRange || busy} onClick={() => pickFromMonth('open', selected)} className={`${btnSub} whitespace-nowrap px-2 text-[14px]`}>+ Make available</button>
      </div>
      {!inRange && data && selected > todayView && <p className="mt-2 text-[12.5px] text-[#6b6880]">You can change times up to 12 weeks ahead (until {dayText(data.last)}).</p>}
    </section>
  );

  const monthView = (
    <div className="grid gap-3 lg:grid-cols-[minmax(0,1fr)_300px] lg:items-start">
      <div className="overflow-hidden rounded-[12px] border border-[#e6e3ef] bg-white">
        <div className="grid grid-cols-7 border-b border-[#e6e3ef] bg-[#efebff] text-[12px] font-bold text-[#2b1c7a]">
          {MONTH_HEAD.map((d) => <span key={d} className="px-1.5 py-1.5 text-center lg:text-left">{d}</span>)}
        </div>
        <div className="grid grid-cols-7">
          {grid.map((date) => {
            const its = dayItems(date, viewZone, lessons, data);
            const tag = dayTag(its);
            const out = date.slice(0, 7) !== month;
            const ls = its.filter((x) => x.kind === 'lesson');
            return (
              <button key={date} type="button" onClick={() => { setSelected(date); if (window.innerWidth < 1024) setTimeout(() => dayRef.current?.scrollIntoView({ behavior: 'smooth', block: 'nearest' }), 50); }} aria-pressed={selected === date}
                aria-label={`${dayText(date)}: ${ls.length} class${ls.length === 1 ? '' : 'es'}${tag ? `, ${tag}` : ''}`}
                className={`min-h-[64px] min-w-0 border-b border-r border-[#f0eef5] px-1 pb-1 pt-1 text-left align-top lg:min-h-[104px] lg:px-1.5 ${selected === date ? 'bg-[#f3efff]' : 'hover:bg-[#faf9fd]'} ${out ? 'text-[#b4b1c2]' : 'text-[#1d1b2b]'}`}>
                <span className={`mx-auto flex h-[24px] w-[24px] items-center justify-center rounded-full text-[13px] font-bold lg:mx-0 ${date === todayView ? 'bg-[#5b3fe0] text-white' : ''}`}>{Number(date.slice(8))}</span>
                {/* 휴대폰: 점 + 짧은 글자 (H26(49) ⑦) */}
                <span className="mt-0.5 flex justify-center gap-[3px] lg:hidden">
                  {ls.slice(0, 3).map((x) => <i key={+x.at} className={`block h-[5px] w-[5px] rounded-full ${x.kind === 'lesson' && x.lesson.state === 'canceled' ? 'bg-[#c4c1d1]' : 'bg-[#5b3fe0]'}`} />)}
                </span>
                {tag && <span className={`mt-0.5 block overflow-hidden rounded-[4px] py-px text-center text-[9px] font-bold leading-[10px] tracking-[-0.02em] lg:hidden ${tagColor(tag)}`}>{tag}</span>}
                {/* PC: 칸마다 수업 시각·학생 (H26(50) ⑥ A안) */}
                <span className="mt-1 hidden gap-0.5 lg:grid">
                  {its.map((x) => <MonthLine key={`${x.kind}-${+x.at}-${x.kind === 'lesson' ? x.lesson.id : ''}`} item={x} zone={viewZone} />)}
                </span>
              </button>
            );
          })}
        </div>
      </div>
      {dayPanel}
    </div>
  );

  const weekView = data && weekKinds && (
    <div>
      {legend}
      <p className="mb-1.5 text-[12.5px] text-[#6b6880]">
        <span className="hidden lg:inline">Drag or click a green time to block it. Click a grey time to open it for that day only.</span>
        <span className="lg:hidden">Tap a green time to block it, or a grey time to open it for that day only.</span>
      </p>
      <div ref={scroller} className="max-h-[62vh] overflow-y-auto rounded-[12px] border border-[#e6e3ef] bg-white lg:max-h-[600px]">
        <div className="grid select-none grid-cols-[42px_repeat(7,minmax(0,1fr))] gap-[2px] px-0.5 pb-2 tabular-nums lg:grid-cols-[52px_repeat(7,minmax(0,1fr))]">
          <div className="sticky top-0 z-[2] bg-white pr-1 pt-1 text-right text-[10px] font-bold leading-tight text-[#2b1c7a]">{korea ? 'KST' : ''}</div>
          {grid.map((d, i) => (
            <div key={d} className={`sticky top-0 z-[2] py-1 text-center text-[12px] font-bold leading-tight ${d === todayView ? 'rounded-b-[6px] bg-[#5b3fe0] text-white' : 'bg-[#efebff] text-[#2b1c7a]'}`}>
              {WEEK_HEAD[i]}<small className="block text-[11px] font-semibold">{Number(d.slice(8))}</small>
            </div>
          ))}
          {ALL_HOURS.map((t, i) => (
            <div key={t} className="contents">
              <div data-row={i} className="pr-1 text-right text-[11px] leading-[26px] text-[#1d1b2b] lg:leading-[24px]">{t.endsWith('00') ? ampmEn(t).replace(':00', '') : ''}</div>
              {grid.map((d, c) => <div key={d}>{weekCell(d, i, weekKinds[c])}</div>)}
            </div>
          ))}
        </div>
      </div>
    </div>
  );

  return (
    <section aria-label="Schedule" className="relative">
      {header}
      {err && <p className="mb-3 rounded-[10px] bg-[#fdecea] px-3 py-2 text-[14px] text-[#b3261e]">{err}</p>}
      {!data && !err && <p className="py-6 text-[15px] text-[#6b6880]">Loading…</p>}
      {data && view === 'month' && monthView}
      {data && view === 'week' && weekView}

      {toast && (
        <div role="status" className="fixed inset-x-0 bottom-[84px] z-50 flex justify-center lg:bottom-8">
          <span className="rounded-[12px] bg-[#1d1b2b] px-4 py-2.5 text-[14.5px] font-semibold text-white shadow-lg">{toast}</span>
        </div>
      )}

      {dialog && (
        <div className="fixed inset-0 z-50 flex items-end justify-center bg-black/40 lg:items-center" onClick={(e) => { if (e.target === e.currentTarget && !busy) setDialog(null); }}>
          <div role="dialog" aria-modal="true" className="grid max-h-[90vh] w-full gap-2.5 overflow-y-auto rounded-t-[18px] bg-white p-4 pb-6 lg:max-w-[440px] lg:rounded-[16px]">
            {dialog.kind === 'info' && (
              <>
                <strong className="text-[16px] text-[#1d1b2b]">{dialog.title}</strong>
                <p className="rounded-[10px] bg-[#fdecea] px-3 py-2 text-[14.5px] text-[#b3261e]">{dialog.body}</p>
                <button type="button" onClick={() => setDialog(null)} className={btnSub}>Close</button>
              </>
            )}
            {dialog.kind === 'pick' && pickBody(dialog)}
            {dialog.kind === 'blocked' && (() => {
              const b = dialog.block;
              const a = localInstant(b.start, tz);
              const e = localInstant(b.end, tz);
              const over = +e <= +now;
              return (
                <>
                  <span className="w-fit rounded-[6px] bg-[#ecebf1] px-1.5 py-0.5 text-[12px] font-bold text-[#55526a]">Blocked</span>
                  <p className="text-[15px] font-semibold text-[#1d1b2b]">{whenSpan(a, e, viewZone)}</p>
                  {other && <p className="-mt-2 text-[13px] text-[#6b6880]">{whenSpan(a, e, other)}</p>}
                  {!over && (
                    <>
                      <NoteField value={dialog.note} onChange={(v) => setDialog({ ...dialog, note: v })} />
                      {saveErr && <p role="alert" className="rounded-[10px] bg-[#fdecea] px-3 py-2 text-[14px] text-[#b3261e]">{saveErr}</p>}
                      <div className="grid grid-cols-2 gap-2">
                        <button type="button" disabled={busy || dialog.note.trim() === (b.note ?? '')} onClick={() => save('note', null, dialog.note, b.id, 'Note saved ✓')} className={btnMain}>Save note</button>
                        <button type="button" disabled={busy} onClick={() => save('unblock', null, null, b.id, 'Block removed ✓')} className={btnSub}>Remove block</button>
                      </div>
                    </>
                  )}
                  {over && b.note && <p className="text-[14.5px] text-[#1d1b2b]">{b.note}</p>}
                  <button type="button" disabled={busy} onClick={() => setDialog(null)} className={btnSub}>Close</button>
                </>
              );
            })()}
            {dialog.kind === 'lesson' && (() => {
              const l = dialog.lesson;
              const tag = lessonTag(l);
              return (
                <>
                  <strong className="text-[17px] text-[#1d1b2b]">{l.student}</strong>
                  <p className="text-[15px] text-[#1d1b2b]"><b>{dayText(inZone(l.startsAt, tz).date)} {spanText(l.startsAt, l.endsAt, tz)}</b></p>
                  {tz !== 'Asia/Seoul' && <p className="-mt-2 text-[13px] text-[#6b6880]">{whenSpan(l.startsAt, l.endsAt, 'Asia/Seoul')}</p>}
                  <p className="text-[14px] text-[#55526a]">
                    {minutesOf(l)} min{tag ? ` · ${tag}` : ''}{l.count ? ` · Class ${l.count.n}/${l.count.total}` : ''} · {statusText(l, now)}
                  </p>
                  <button type="button" onClick={() => { setDialog(null); onRecord(l); }} className={btnMain}>Class Record ›</button>
                  <div className="flex flex-wrap gap-2">
                    {l.studentId && openProfile && <button type="button" onClick={() => { setDialog(null); openProfile(l.studentId!); }} className={`${btnSub} flex-1`}>Student profile</button>}
                    {l.noteUrl && <a href={l.noteUrl} target="_blank" rel="noreferrer" className={`${btnSub} inline-flex flex-1 items-center justify-center`}>Class notes</a>}
                  </div>
                  <button type="button" onClick={() => setDialog(null)} className={btnSub}>Close</button>
                </>
              );
            })()}
          </div>
        </div>
      )}
    </section>
  );

  // 창 안 글자 칸이 다시 그려질 때 초점을 잃지 않게 컴포넌트가 아니라 함수로
  function pickBody(d: Pick) {
    const setD = (x: Pick) => setDialog(x);
    const want: CellKind = d.mode === 'block' ? 'free' : 'closed';
    const starts = d.kinds.flatMap((k, i) => (k === want ? [i] : []));
    const run = runFrom(d.kinds, d.start, want);
    const a = at(d.date, d.start);
    const b = d.end === 48 ? localToInstant(plusDays(d.date, 1), '00:00', viewZone) : at(d.date, d.end);
    const hit = d.mode === 'block' && run.cutBy !== null && d.end === run.ends[run.ends.length - 1] ? lessonIn(d.date, slotTime(run.cutBy)) : null;
    const isOpen = d.mode === 'open';
    // 고른 칸이 모두 '그날만 연 칸'이면 막기가 아니라 추가 개방 철회 — 메모를 받지 않음 (DB 가 그 열기만 거둠, QA-03)
    const removeExtra = !isOpen && d.end > d.start && d.xs.slice(d.start, d.end).every(Boolean);
    const mixedExtra = !isOpen && !removeExtra && d.xs.slice(d.start, d.end).some(Boolean);
    return (
      <>
        <strong className="text-[17px] text-[#1d1b2b]">{isOpen ? 'Make available' : removeExtra ? 'Remove extra hours' : 'Block time'}</strong>
        <div>
          <p className="text-[15px] text-[#1d1b2b]"><b>{dayText(d.date)}</b> · {isOpen ? 'This day only' : removeExtra ? 'Back to your usual weekly hours (closed)' : viewLabel}</p>
          <p className="text-[13px] text-[#6b6880]">{spanText(a, b, viewZone)}{other ? ` · ${whenSpan(a, b, other)}` : ''}</p>
        </div>
        <div className="grid grid-cols-2 gap-2">
          <label className="block">
            <span className="mb-1 block text-[13px] font-semibold text-[#55526a]">Start</span>
            <select value={d.start} onChange={(e) => { const s = Number(e.target.value); setD({ ...d, start: s, end: s + 1 }); }}
              className="min-h-[44px] w-full rounded-[10px] border border-[#d9d5e6] bg-white px-2 text-[16px] text-[#1d1b2b]">
              {starts.map((i) => <option key={i} value={i}>{slotText(i)}</option>)}
            </select>
          </label>
          <label className="hidden lg:block">
            <span className="mb-1 block text-[13px] font-semibold text-[#55526a]">End</span>
            <select value={d.end} onChange={(e) => setD({ ...d, end: Number(e.target.value) })}
              className="min-h-[44px] w-full rounded-[10px] border border-[#d9d5e6] bg-white px-2 text-[16px] text-[#1d1b2b]">
              {run.ends.map((i) => <option key={i} value={i}>{slotText(i)}</option>)}
            </select>
          </label>
        </div>
        {/* 휴대폰: 끝 시간 칩 */}
        <div className="lg:hidden">
          <span className="mb-1 block text-[13px] font-semibold text-[#55526a]">End</span>
          <div className="flex flex-wrap gap-1.5">
            {run.ends.map((i) => (
              <button key={i} type="button" aria-pressed={d.end === i} onClick={() => setD({ ...d, end: i })}
                className={`min-h-[42px] min-w-[64px] rounded-[10px] border px-2 text-[15px] font-semibold tabular-nums ${d.end === i ? 'border-[#5b3fe0] bg-[#5b3fe0] text-white' : 'border-[#e6e3ef] bg-white text-[#1d1b2b]'}`}>
                {slotText(i)}
              </button>
            ))}
          </div>
        </div>
        {hit && (
          <p className="rounded-[10px] bg-[#fdecea] px-3 py-2 text-[14px] text-[#b3261e]">
            You have a class at {ampmEn(inZone(hit.startsAt, viewZone).time)} {viewLabel}. Classes can’t be blocked.
          </p>
        )}
        {!isOpen && !removeExtra && <NoteField value={d.note} onChange={(v) => setD({ ...d, note: v })} />}
        {mixedExtra && <p className="text-[13px] text-[#6b6880]">Part of this time is extra hours for this day only. That part just goes back to closed (no note is kept for it).</p>}
        {saveErr && <p role="alert" className="rounded-[10px] bg-[#fdecea] px-3 py-2 text-[14px] text-[#b3261e]">{saveErr}</p>}
        <div className="grid grid-cols-[1fr_auto] gap-2">
          <button type="button" disabled={busy || d.end <= d.start} className={btnMain}
            onClick={() => save(d.mode, keysOf(d.date, d.start, d.end), isOpen || removeExtra ? null : d.note, null, isOpen ? 'Made available ✓' : removeExtra ? 'Extra hours removed ✓' : 'Blocked ✓')}>
            {busy ? 'Saving…' : isOpen ? 'Make available' : removeExtra ? 'Remove' : 'Block'}
          </button>
          <button type="button" disabled={busy} onClick={() => setDialog(null)} className={btnSub}>Cancel</button>
        </div>
      </>
    );
  }
}

function NoteField({ value, onChange }: { value: string; onChange: (v: string) => void }) {
  return (
    <label className="block">
      <span className="mb-1 block text-[13px] font-semibold text-[#55526a]">Note (optional)</span>
      <input value={value} maxLength={NOTE_MAX} onChange={(e) => onChange(e.target.value)}
        className="w-full rounded-[10px] border border-[#d9d5e6] bg-white px-3 py-2.5 text-[16px] text-[#1d1b2b]" />
      <span className="mt-1 flex justify-between gap-3 text-[12.5px] text-[#6b6880]">
        <span>{NOTE_HELP}</span><span className="shrink-0 tabular-nums">{value.length}/{NOTE_MAX}</span>
      </span>
    </label>
  );
}

const tagColor = (tag: string) => (tag === 'Cancel' ? 'bg-[#fdecea] text-[#b3261e]' : tag === 'Leave' ? 'bg-[#fff4d6] text-[#8a5300]'
  : tag === 'Block' ? 'bg-[#ecebf1] text-[#55526a]' : tag === 'Extra hours' ? 'bg-[#e6f6ec] text-[#1f7a4d]' : tag === 'Last' ? 'bg-[#f3e8ff] text-[#7a2ab0]' : 'bg-[#e3f6f3] text-[#0f5f56]');

function MonthLine({ item, zone }: { item: DayItem; zone: string }) {
  const time = ampmEn(inZone(item.at, zone).time);
  if (item.kind === 'lesson') {
    const l = item.lesson;
    const tag = lessonTag(l);
    const off = l.state === 'canceled';
    return (
      <span className={`flex min-w-0 items-center gap-1 text-[12px] leading-[16px] ${off ? 'text-[#a3a0b3] line-through' : 'text-[#1d1b2b]'}`}>
        <i className={`block h-[6px] w-[6px] shrink-0 rounded-full ${off ? 'bg-[#c4c1d1]' : 'bg-[#5b3fe0]'}`} />
        <span className="shrink-0 tabular-nums">{time}</span>
        <span className="truncate">{l.student}{tag && !off ? ` · ${tag}` : ''}</span>
      </span>
    );
  }
  if (item.kind === 'block') {
    return (
      <span className="flex min-w-0 items-center gap-1 text-[12px] leading-[16px] text-[#55526a]">
        <i className="block h-[6px] w-[6px] shrink-0 rounded-[1px] bg-[#55526a]" />
        <span className="shrink-0 tabular-nums">{time}</span>
        <span className="truncate">{item.block.kind === 'leave' ? 'Leave' : item.block.note || 'Blocked'}</span>
      </span>
    );
  }
  return (
    <span className="flex min-w-0 items-center gap-1 text-[12px] leading-[16px] text-[#1f7a4d]">
      <i className="block h-[6px] w-[6px] shrink-0 rounded-full border border-[#1f7a4d]" />
      <span className="shrink-0 tabular-nums">{time}</span>
      <span className="truncate">Extra availability</span>
    </span>
  );
}

function DayRow({ item, zone, onOpen }: { item: DayItem; zone: string; onOpen: () => void }) {
  if (item.kind === 'lesson') {
    const l = item.lesson;
    const tag = lessonTag(l);
    const off = l.state === 'canceled';
    return (
      <li className="list-none">
        <button type="button" onClick={onOpen} className="flex min-h-[48px] w-full items-center gap-2 rounded-[10px] border border-[#e6e3ef] px-3 py-1.5 text-left hover:bg-[#f7f6fb]">
          <i className={`block h-[8px] w-[8px] shrink-0 rounded-full ${off ? 'bg-[#c4c1d1]' : 'bg-[#5b3fe0]'}`} />
          <span className="min-w-0 flex-1">
            <span className={`block truncate text-[14.5px] font-semibold ${off ? 'text-[#8a879c] line-through' : 'text-[#1d1b2b]'}`}>{l.student}</span>
            <span className="block text-[12.5px] text-[#6b6880]">{spanText(l.startsAt, l.endsAt, zone)}</span>
          </span>
          {tag && <span className="shrink-0 rounded-[6px] bg-[#efebff] px-1.5 text-[12px] font-semibold text-[#5b3fe0]">{tag}</span>}
        </button>
      </li>
    );
  }
  const block = item.kind === 'block';
  return (
    <li className="list-none">
      <button type="button" onClick={onOpen} disabled={block && item.block.kind === 'leave' && false}
        className="flex min-h-[48px] w-full items-center gap-2 rounded-[10px] border border-[#e6e3ef] bg-[#faf9fd] px-3 py-1.5 text-left enabled:hover:bg-[#f3f1f8]">
        <span className="min-w-0 flex-1">
          <span className="block truncate text-[14.5px] font-semibold text-[#1d1b2b]">
            {block ? (item.block.kind === 'leave' ? 'Leave' : item.block.note || 'Blocked') : 'Extra availability (this day only)'}
          </span>
          <span className="block text-[12.5px] text-[#6b6880]">
            {spanText(item.at, item.end, zone)}
            {/* 날짜를 넘는 휴무·막기: 이 날 부분만 보이고, 전체 기간은 따로 (R-03) */}
            {item.spans && ` · ${whenSpan(item.spans.at, item.spans.end, zone)}`}
          </span>
        </span>
        <span className={`shrink-0 rounded-[6px] px-1.5 text-[12px] font-bold ${block ? 'bg-[#ecebf1] text-[#55526a]' : 'bg-[#e6f6ec] text-[#1f7a4d]'}`}>
          {block ? (item.block.kind === 'leave' ? 'Leave' : 'Blocked') : 'Extra'}
        </span>
      </button>
    </li>
  );
}

function Seg<T extends string>({ value, onChange, options, className = '', check = false }: {
  value: T; onChange: (v: T) => void; options: [T, string][]; className?: string; check?: boolean;
}) {
  return (
    <div role="group" className={`inline-flex overflow-hidden rounded-[10px] border border-[#e6e3ef] bg-white ${className}`}>
      {options.map(([v, label]) => (
        <button key={v} type="button" aria-pressed={value === v} onClick={() => onChange(v)}
          className={`min-h-[42px] px-3 text-[14px] font-semibold ${value === v ? 'bg-[#5b3fe0] text-white' : 'text-[#1d1b2b]'}`}>
          {check && value === v ? '✓ ' : ''}{label}
        </button>
      ))}
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

/** 못 바꾸는 칸의 이유 (R-16: 답 전 요청과 답 보낸 뒤 확정 대기를 구분, 추가 개방 줄에서도 같은 안내) */
function lockReason(k: CellKind | undefined): { title: string; body: string } | null {
  switch (k) {
    case 'request': return { title: 'Request waiting', body: 'A make-up or cover request is waiting for this time. Answer it on Home first.' };
    case 'answered': return { title: 'Answer sent', body: 'Your answer has been sent for this time. Waiting for Edge English to confirm. To change this time, contact Edge English.' };
    case 'class': return { title: 'Class', body: 'You have a class at this time. Classes can’t be blocked.' };
    case 'locked': return { title: 'Can’t change', body: 'Can’t change: less than 6 hours away.' };
    case 'leave': return { title: 'Leave', body: 'This time is in your leave.' };
    default: return null;
  }
}
