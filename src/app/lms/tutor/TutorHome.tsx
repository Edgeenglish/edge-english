'use client';

// 강사 화면 (영어, 휴대폰 우선): ① 기록할 수업(Class Record) ② 보강 가능 여부 답 ③ 일정 목록(시트처럼 한 줄, 누르면 펼침)
// 화면 검사는 편의일 뿐, 본인 수업인지·시작했는지·정산 잠김은 DB 함수가 다시 확인 (migration 2000)

import { useEffect, useState, type ReactNode } from 'react';
import { googleCalendarUrl, icsUrl } from '@/lms/calendar/add';
import { STATUS_RULES } from '@/lms/rules/status';
import {
  answerReady, canRecord, daysOf, dayLabel, kindTag, kstText, makeupOrigin, minutesOf, phaseOf, recordReady, RESULT_TEXT, resultOf, savedStatus,
  statusText, timeRange, weekOf, whenText, type TutorCover, type TutorLesson, type TutorMakeup, type TutorResult, type TutorScreen,
} from '@/lms/tutor/screen';

export type TutorActions = {
  load: (kstFrom: string, kstTo: string) => Promise<TutorScreen>;
  record: (lessonId: string, result: TutorResult, topics: string, remarks: string) => Promise<void>;
  answer: (requestId: string, yes: string[], note: string) => Promise<void>;
  /** 대체 수업 요청 답: items = 답하는 수업 전체, yes = 가능한 수업 */
  answerCover: (items: string[], yes: string[]) => Promise<void>;
};

const card = 'rounded-[14px] border border-[#e6e3ef] bg-white p-4';
const btnMain = 'min-h-[44px] rounded-[10px] bg-[#5b3fe0] px-4 text-[15px] font-semibold text-white disabled:opacity-40';
const btnDone = 'min-h-[44px] rounded-[10px] bg-[#e9e7f0] px-4 text-[15px] font-semibold text-[#6b6880]';
const btnSub = 'min-h-[44px] rounded-[10px] border border-[#e6e3ef] bg-white px-4 text-[15px] font-semibold text-[#1d1b2b] disabled:opacity-40';
const input = 'w-full rounded-[10px] border border-[#d9d5e6] bg-white px-3 py-2.5 text-[16px] text-[#1d1b2b]';
const label = 'mb-1 block text-[13px] font-semibold text-[#55526a]';

export default function TutorHome({ initial, nowIso, actions, adminBar, onLogout }: {
  initial: TutorScreen;
  nowIso: string;
  actions: TutorActions;
  adminBar?: ReactNode;
  onLogout?: () => void;
}) {
  const [screen, setScreen] = useState(initial);
  const [now, setNow] = useState(() => new Date(nowIso));
  const [offset, setOffset] = useState(0);
  const [loading, setLoading] = useState(false);
  const [err, setErr] = useState('');
  // 이번에 기록·답한 것은 목록에서 빠지지 않고 '✓'로 남음 (2026-10-28 대표: 처리한 것은 사라지지 않게)
  const [recordedHere, setRecordedHere] = useState<TutorLesson[]>([]);
  const [answeredHere, setAnsweredHere] = useState<TutorMakeup[]>([]);
  const tz = screen.tutor.timezone;
  // KST·Paid 칸: 강사가 끌 수 있음, 이 기기에 기억 (대표 10/29). 한국 시간대 강사는 KST 칸 없음
  const [kstPref, setKst] = useSavedToggle('lms_tutor_kst');
  const [paidCol, setPaidCol] = useSavedToggle('lms_tutor_paid');
  const kstOn = tz === 'Asia/Seoul' ? null : kstPref;
  const kst = kstOn === true;
  const week = weekOf(now, tz, offset);
  // 학생별로 보기 (대표 10/29): 학생을 고르면 그 학생의 모든 수업을 날짜순으로 (주 단위 대신)
  const [student, setStudent] = useState('');
  const [allLessons, setAllLessons] = useState<TutorLesson[] | null>(null);
  const studentNames = [...new Set([...(allLessons ?? []), ...screen.lessons].map((l) => l.student))].sort();
  async function loadAll(): Promise<void> {
    if (!allLessons) await refreshAll();
  }
  async function refreshAll(): Promise<void> {
    setLoading(true);
    setErr('');
    try {
      setAllLessons((await actions.load('2000-01-01', '2100-12-31')).lessons);
    } catch (e) {
      setErr(e instanceof Error ? e.message : 'Could not load. Please try again.');
    } finally {
      setLoading(false);
    }
  }

  useEffect(() => setScreen(initial), [initial]);

  async function reload(off = offset) {
    setLoading(true);
    setErr('');
    try {
      const n = new Date();
      const w = weekOf(n, tz, off);
      setScreen(await actions.load(w.kstFrom, w.kstTo));
      setNow(n);
    } catch (e) {
      setErr(e instanceof Error ? e.message : 'Could not load. Please try again.');
    } finally {
      setLoading(false);
    }
  }
  async function goWeek(off: number) {
    setOffset(off);
    await reload(off);
  }

  const byId = new Map(screen.lessons.map((l) => [l.id, l]));
  const toRecord = [
    ...screen.toRecord.map((id) => byId.get(id)).filter((l): l is TutorLesson => !!l),
    ...recordedHere.filter((l) => !screen.toRecord.includes(l.id)).map((l) => byId.get(l.id) ?? l),
  ].sort((a, b) => +a.startsAt - +b.startsAt);
  // 할 일 게시판 (학생 화면과 같은 모양, 대표 10/29): 아직 안 한 것만 세고, 누르면 그 칸으로
  const [panel, setPanel] = useState<'record' | 'cover' | 'makeup' | null>(null);
  const todoCount = [screen.toRecord.length, screen.covers.length, screen.makeups.length].filter((n) => n > 0).length;
  const makeups = [...screen.makeups, ...answeredHere.filter((m) => !screen.makeups.some((x) => x.id === m.id))];
  const days = student
    ? daysOf((allLessons ?? screen.lessons).filter((l) => l.student === student), tz, { from: '1900-01-01', to: '2999-12-31' })
    : daysOf(screen.lessons, tz, week);

  return (
    <main className="mx-auto max-w-[680px] px-4 pb-16 pt-4 lg:max-w-[1080px]">
      <div className="lg:max-w-[680px]">
      {adminBar}
      <header className="mb-4 flex items-start justify-between gap-3">
        <div>
          <p className="mb-1.5 flex items-center gap-1.5">
            <img src="/images/brand/edge-english-logo.svg" alt="엣지영어" className="h-[22px] w-auto" />
            <span className="rounded-[6px] bg-[#27230e] px-[7px] py-[3px] text-[12px] font-extrabold text-[#ffd401]">Tutor</span>
          </p>
          <h1 className="text-[22px] font-bold text-[#1d1b2b]">{screen.tutor.name}</h1>
          <p className="text-[13px] text-[#6b6880]">Your time · {tz}</p>
        </div>
        {onLogout && (
          <button type="button" onClick={onLogout} className="min-h-[40px] rounded-[10px] border border-[#e6e3ef] bg-white px-3 text-[13.5px] text-[#1d1b2b]">
            Sign out
          </button>
        )}
      </header>
      {err && <p className="mb-3 rounded-[10px] bg-[#fdecea] px-3 py-2 text-[14px] text-[#b3261e]">{err}</p>}

      {todoCount > 0 && (
        <section aria-label="To do" className="mb-6 overflow-hidden rounded-[18px] border-2 border-[#f0a33a] bg-white">
          <h2 className="flex items-center gap-2 bg-[#fff4d6] px-4 py-2.5 text-[16px] font-bold text-[#5c3b00]">
            To do <span className="rounded-full bg-[#f0a33a] px-2 py-0.5 text-[13px] text-white">{todoCount}</span>
          </h2>
          <div className="divide-y divide-[#f3e6c4]">
            {screen.toRecord.length > 0 && <TodoBar n={screen.toRecord.length} text="Classes to record" onClick={() => setPanel('record')} />}
            {screen.covers.length > 0 && <TodoBar n={screen.covers.length} text="Cover requests" onClick={() => setPanel('cover')} />}
            {screen.makeups.length > 0 && <TodoBar n={screen.makeups.length} text="Make-up requests" onClick={() => setPanel('makeup')} />}
          </div>
        </section>
      )}

      {panel === 'record' && (
        <Sheet onClose={() => setPanel(null)}>
          <h2 className="mb-2 pr-10 text-[17px] font-bold text-[#1d1b2b]">
            Classes to record <span className="text-[#5b3fe0]">{screen.toRecord.length > 0 ? screen.toRecord.length : ''}</span>
          </h2>
          <div className="grid gap-3">
            {toRecord.map((l) => (
              <div key={l.id} className={card}>
                <LessonHead lesson={l} tz={tz} now={now} />
                <RecordForm key={`${l.id}-${l.state}`} lesson={l} now={now} actions={actions} startEditing={screen.toRecord.includes(l.id)}
                  onSaved={async (saved) => {
                    setRecordedHere((x) => [...x.filter((y) => y.id !== saved.id), saved]);
                    await reload();
                  }} />
              </div>
            ))}
          </div>
        </Sheet>
      )}

      {panel === 'cover' && (
        <Sheet onClose={() => setPanel(null)}>
          <h2 className="mb-2 pr-10 text-[17px] font-bold text-[#1d1b2b]">Cover requests</h2>
          <div className="grid gap-3">
            {groupCovers(screen.covers).map((g) => (
              <CoverCard key={g.map((c) => c.id).join()} covers={g} tz={tz} actions={actions} onSent={() => reload()} />
            ))}
            {screen.covers.length === 0 && <p className="text-[15px] text-[#1f7a4d]">✓ Sent</p>}
          </div>
        </Sheet>
      )}

      {panel === 'makeup' && (
        <Sheet onClose={() => setPanel(null)}>
          <h2 className="mb-2 pr-10 text-[17px] font-bold text-[#1d1b2b]">Make-up requests</h2>
          <div className="grid gap-3">
            {makeups.map((m) => (
              <MakeupCard key={m.id} m={m} tz={tz} actions={actions} closed={!screen.makeups.some((x) => x.id === m.id)}
                onSent={async () => {
                  setAnsweredHere((x) => [...x.filter((y) => y.id !== m.id), m]);
                  await reload();
                }} />
            ))}
          </div>
        </Sheet>
      )}

      </div>

      <section>
        <div className="mb-2 flex flex-wrap items-center justify-between gap-2">
          <h2 className="text-[17px] font-bold text-[#1d1b2b]">Class Record</h2>
          {kstOn !== null && (
            <label className="ml-auto flex min-h-[44px] items-center gap-1.5 text-[14px] font-semibold text-[#55526a]">
              <input type="checkbox" checked={kstOn} onChange={(e) => setKst(e.target.checked)} className="h-[18px] w-[18px] accent-[#5b3fe0]" />
              KST
            </label>
          )}
          <label className={`${kstOn === null ? 'ml-auto ' : ''}flex min-h-[44px] items-center gap-1.5 text-[14px] font-semibold text-[#55526a]`}>
            <input type="checkbox" checked={paidCol} onChange={(e) => setPaidCol(e.target.checked)} className="h-[18px] w-[18px] accent-[#5b3fe0]" />
            Paid
          </label>
          {!student && <div className="flex items-center gap-1.5">
            <button type="button" aria-label="Previous week" disabled={loading} onClick={() => goWeek(offset - 1)} className={`${btnSub} px-3`}>‹</button>
            <button type="button" disabled={loading || offset === 0} onClick={() => goWeek(0)} className={`${btnSub} px-3 text-[14px]`}>This week</button>
            <button type="button" aria-label="Next week" disabled={loading} onClick={() => goWeek(offset + 1)} className={`${btnSub} px-3`}>›</button>
          </div>}
        </div>
        <select
          aria-label="Student"
          value={student}
          onFocus={() => void loadAll()}
          onChange={async (e) => {
            const v = e.target.value;
            if (v) await loadAll();
            setStudent(v);
          }}
          className="mb-2 min-h-[44px] w-full rounded-[10px] border border-[#e6e3ef] bg-white px-3 text-[15px] text-[#1d1b2b] lg:max-w-[680px]"
        >
          <option value="">All students · by week</option>
          {studentNames.map((n) => (
            <option key={n} value={n}>{n} · all classes</option>
          ))}
        </select>
        {!student && <p className="mb-2 text-[14px] font-semibold text-[#55526a]">{dayLabel(week.from)} – {dayLabel(week.to)}</p>}
        {days.length === 0 && <p className={`${card} text-[15px] text-[#6b6880]`}>No classes</p>}
        {days.length > 0 && (
          <div className="overflow-hidden rounded-[12px] border border-[#e6e3ef] bg-white">
            <div className="grid grid-cols-[64px_minmax(0,1fr)_auto] gap-2 border-b-2 border-[#5b3fe0] bg-[#efebff] px-3 py-2 text-[13px] font-bold leading-tight text-[#2b1c7a] lg:hidden">
              <span>Local Time</span><span>Student</span><span>Class Status</span>
            </div>
            <div className={`hidden ${cols(kst, paidCol)} border-b-2 border-[#5b3fe0] bg-[#efebff] px-1 whitespace-nowrap text-[13px] font-bold text-[#2b1c7a] lg:grid [&>*]:flex [&>*]:min-w-0 [&>*]:items-center [&>*]:border-l [&>*]:border-[#e6e3ef] [&>*]:px-2 [&>*:first-child]:border-l-0 [&>*]:py-2`}>
              <span>Local Time</span>{kst && <span>KST</span>}<span>Student</span><span>Class Count</span><span>Min</span><span>Class Type</span><span>Class Status</span>{paidCol && <span>Paid</span>}<span>Covered Topics</span>
            </div>
            {days.map((d) => (
              <div key={d.date}>
                <h3 className="border-b border-[#e6e3ef] bg-[#f7f6fb] px-3 py-1.5 text-[13px] font-bold text-[#1d1b2b]">{dayLabel(d.date)}</h3>
                {d.lessons.map((l) => (
                  <ListRow key={l.id} lesson={l} tz={tz} now={now} kst={kst} paidCol={paidCol} meetUrl={screen.tutor.meetUrl} actions={actions}
                    onSaved={async () => { await reload(); if (student) await refreshAll(); }} />
                ))}
              </div>
            ))}
          </div>
        )}
      </section>
    </main>
  );
}

// 할 일은 화면에 펼쳐 두지 않고 누르면 창으로 (대표 10/29: 할 일이 많아도 Class Record 표가 아래로 밀리지 않게)
function Sheet({ onClose, children }: { onClose: () => void; children: ReactNode }) {
  return (
    <div className="fixed inset-0 z-40 flex items-end justify-center bg-black/40 lg:items-center" onClick={onClose}>
      <div role="dialog" aria-modal="true" onClick={(e) => e.stopPropagation()}
        className="relative max-h-[90vh] w-full max-w-[640px] overflow-y-auto rounded-t-[20px] bg-[#f6f5fa] p-4 pb-8 lg:rounded-[20px]">
        <button type="button" aria-label="Close" onClick={onClose}
          className="absolute right-3 top-3 flex h-[40px] w-[40px] items-center justify-center rounded-full bg-white text-[18px] text-[#1d1b2b]">✕</button>
        {children}
      </div>
    </div>
  );
}

function TodoBar({ n, text, onClick }: { n: number; text: string; onClick: () => void }) {
  return (
    <button type="button" onClick={onClick}
      className="flex min-h-[54px] w-full items-center gap-3 px-4 py-3 text-left">
      <span className="flex-1 text-[15px] font-semibold leading-snug text-[#1d1b2b]">{text}</span>
      <span className="text-[13px] text-[#8a5300]">{n}</span>
      <span className="whitespace-nowrap rounded-[10px] bg-[#5b3fe0] px-3 py-1.5 text-[13px] font-bold text-white">Open ›</span>
    </button>
  );
}

function LessonHead({ lesson: l, tz, now }: { lesson: TutorLesson; tz: string; now: Date }) {
  const tag = kindTag(l);
  const kst = kstText(l.startsAt, tz);
  return (
    <div>
      <div className="flex flex-wrap items-baseline gap-x-2">
        <b className="text-[16px] text-[#1d1b2b]">{l.student}</b>
        {tag && <span className="rounded-[6px] bg-[#efebff] px-1.5 text-[12.5px] font-semibold text-[#5b3fe0]">{tag}</span>}
        {l.count && <span className="text-[13px] text-[#6b6880]">Class {l.count.n}/{l.count.total}</span>}
      </div>
      <p className="text-[14.5px] text-[#1d1b2b]">
        {whenText(l.startsAt, tz).replace(/ \d\d:\d\d$/, '')} · {timeRange(l, tz)} · {minutesOf(l)} min
        {kst && <span className="text-[#6b6880]"> · {kst}</span>}
      </p>
      {l.makeupOf && <p className="text-[13px] text-[#6b6880]">Make-up for {whenText(l.makeupOf, tz)}</p>}
      {phaseOf(l, now) === 'canceled' && <p className="text-[13px] font-semibold text-[#b3261e]">{statusText(l, now)}</p>}
    </div>
  );
}

/** PC 표 칸 (KST 칸은 강사가 끌 수 있음) */
const cols = (kst: boolean, paid: boolean) => kst
  ? (paid ? 'lg:grid-cols-[80px_84px_minmax(120px,1.1fr)_100px_44px_104px_minmax(120px,1fr)_56px_minmax(160px,1.6fr)]'
    : 'lg:grid-cols-[80px_84px_minmax(120px,1.1fr)_100px_44px_104px_minmax(120px,1fr)_minmax(160px,1.6fr)]')
  : (paid ? 'lg:grid-cols-[80px_minmax(120px,1.1fr)_100px_44px_104px_minmax(120px,1fr)_56px_minmax(160px,1.6fr)]'
    : 'lg:grid-cols-[80px_minmax(120px,1.1fr)_100px_44px_104px_minmax(120px,1fr)_minmax(160px,1.6fr)]');

/** 켬/끔을 이 기기에 기억 (기본 켬) */
function useSavedToggle(key: string): [boolean, (on: boolean) => void] {
  const [on, setOn] = useState(true);
  useEffect(() => {
    try { if (localStorage.getItem(key) === '0') setOn(false); } catch { /* 저장 안 되는 브라우저 */ }
  }, [key]);
  return [on, (v: boolean) => {
    setOn(v);
    try { localStorage.setItem(key, v ? '1' : '0'); } catch { /* 저장 안 되는 브라우저 */ }
  }];
}

/** 일정 한 줄 (Class Record 시트처럼). 누르면 그 아래에 기록칸·링크가 펼쳐짐. 휴대폰은 칸을 줄여 한 줄 */
function ListRow({ lesson: l, tz, now, kst, paidCol, meetUrl, actions, onSaved }: {
  lesson: TutorLesson; tz: string; now: Date; kst: boolean; paidCol: boolean; meetUrl: string | null; actions: TutorActions; onSaved: () => Promise<void>;
}) {
  const [open, setOpen] = useState(false);
  const phase = phaseOf(l, now);
  const status = statusText(l, now);
  const k = kst ? kstText(l.startsAt, tz) : null;
  const time = timeRange(l, tz).split('–')[0];
  const count = l.count ? `${l.count.n}/${l.count.total}` : '—';
  const canOpen = phase !== 'canceled';
  const stColor = phase === 'to_record' ? 'text-[#b3261e]' : phase === 'recorded' ? 'text-[#1f7a4d]' : 'text-[#6b6880]';
  const stText = phase === 'recorded' ? `✓ ${status}` : status;
  // 페이 대상 Y/N (상태 규칙 tutorPaid, 대표 10/29 가안). 기록 전은 빈칸, 정산 끝난 수업은 'Y ✓'
  const paid = l.classStatus ? (STATUS_RULES[l.classStatus].tutorPaid ? (l.locked ? 'Y ✓' : 'Y') : 'N') : '';
  const name = <span className={phase === 'canceled' ? 'line-through' : ''}>{l.student}</span>;
  const remarksChip = l.remarks ? <span className="ml-1 inline-block rounded-[6px] border border-[#e6e3ef] px-1 text-[11.5px] font-semibold text-[#6b6880]">Remarks</span> : null;
  const links = (
    <>
      {phase === 'upcoming' && meetUrl && <a href={meetUrl} target="_blank" rel="noreferrer" className={`${btnSub} inline-flex items-center text-[14px]`}>Classroom</a>}
      {l.noteUrl && <a href={l.noteUrl} target="_blank" rel="noreferrer" className={`${btnSub} inline-flex items-center text-[14px]`}>Class notes</a>}
      {phase === 'upcoming' && kindTag(l) === 'Make-up' && (() => {
        const ev = { title: `Edge English make-up · ${l.student}`, start: l.startsAt, end: l.endsAt, details: meetUrl };
        return (
          <>
            <a href={googleCalendarUrl(ev)} target="_blank" rel="noreferrer" className={`${btnSub} inline-flex items-center text-[14px]`}>Google Calendar</a>
            <a href={icsUrl(ev)} className={`${btnSub} inline-flex items-center text-[14px]`}>Apple / Samsung Calendar</a>
          </>
        );
      })()}
    </>
  );
  return (
    <div className={`border-b border-[#e6e3ef] last:border-b-0 ${phase === 'canceled' ? 'text-[#8a879c]' : 'text-[#1d1b2b]'}`}>
      <button type="button" disabled={!canOpen} aria-expanded={open} onClick={() => setOpen(!open)}
        className={`w-full cursor-pointer px-3 py-2 text-left lg:px-1 disabled:cursor-default ${open ? 'bg-[#f3f1f8]' : 'enabled:hover:bg-[#f7f6fb]'}`}>
        <div className="grid grid-cols-[64px_minmax(0,1fr)_auto] items-start gap-2 lg:hidden">
          <span className="text-[14px] font-bold tabular-nums">
            {time}{k && <span className="block text-[11.5px] font-medium text-[#6b6880]">{k}</span>}
          </span>
          <span className="min-w-0">
            <span className="block truncate text-[14.5px] font-semibold">{name}</span>
            <span className="block text-[12.5px] text-[#6b6880]">
              {l.count ? `Class ${count} · ` : ''}{minutesOf(l)} min{kindTag(l) ? ` · ${kindTag(l)}` : ''}{paidCol && paid ? ` · Paid ${paid}` : ''}
            </span>
            {l.topics && <span className="block truncate text-[12.5px]">{l.topics}</span>}
          </span>
          <span className={`text-right text-[13px] font-semibold ${stColor}`}>{stText}{remarksChip && <span className="block">{remarksChip}</span>}</span>
        </div>
        <div className={`-my-2 hidden text-[14px] tabular-nums lg:grid ${cols(kst, paidCol)} [&>*]:flex [&>*]:min-w-0 [&>*]:items-center [&>*]:border-l [&>*]:border-[#e6e3ef] [&>*]:px-2 [&>*:first-child]:border-l-0 [&>*]:py-2`}>
          <span className="font-semibold">{time}</span>
          {kst && <span className="text-[#6b6880]">{k?.replace(/^KST /, '')}</span>}
          <span className="font-semibold"><span className="truncate">{name}</span></span>
          <span>{count}</span>
          <span>{minutesOf(l)}</span>
          <span>{kindTag(l) ?? 'Regular'}</span>
          <span className={`font-semibold ${stColor}`}>{stText}</span>
          {paidCol && <span>{paid}</span>}
          <span className="flex-wrap text-[13px]">{l.topics}{remarksChip}</span>
        </div>
      </button>
      {open && (
        <div className="border-t border-[#e6e3ef] bg-[#f7f6fb] px-3 pb-3 lg:pl-[92px]">
          {l.makeupOf && <p className="pt-2 text-[13px] text-[#6b6880]">Make-up for {whenText(l.makeupOf, tz)}</p>}
          {canRecord(l, now) ? (
            <div className="lg:max-w-[560px]">
              <RecordForm key={`${l.id}-${l.state}`} lesson={l} now={now} actions={actions} startEditing extra={links}
                onSaved={async () => { setOpen(false); await onSaved(); }} />
            </div>
          ) : (
            <div className="grid gap-2 pt-2">
              {l.remarks && <p className="text-[14px]"><b className="text-[13px] text-[#55526a]">Remarks</b> {l.remarks}</p>}
              <div className="flex flex-wrap items-center gap-1.5">
                {links}
                {l.locked && <span className="text-[13px] text-[#6b6880]">In payroll</span>}
              </div>
            </div>
          )}
        </div>
      )}
    </div>
  );
}

function RecordForm({ lesson: l, now, actions, startEditing, onSaved, extra }: {
  lesson: TutorLesson; now: Date; actions: TutorActions; startEditing: boolean; onSaved: (saved: TutorLesson) => Promise<void>; extra?: ReactNode;
}) {
  const [editing, setEditing] = useState(startEditing);
  const [result, setResult] = useState<TutorResult | null>(resultOf(l.classStatus));
  const [topics, setTopics] = useState(l.topics ?? '');
  const [remarks, setRemarks] = useState(l.remarks ?? '');
  // Remarks 칸은 이슈 있을 때만 꺼내 씀 (대표 10/29). Late는 이유가 필요해서 바로 보임
  const [remarksOpen, setRemarksOpen] = useState(!!l.remarks);
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState('');
  const ready = recordReady(result, topics, remarks) && canRecord(l, now);

  if (!editing) {
    return (
      <div className="mt-2 flex items-center justify-between gap-2 rounded-[10px] bg-[#f3f1f8] px-3 py-2">
        <span className="text-[14px] font-semibold text-[#1f7a4d]">✓ {statusText(l, now)}{l.topics ? ` · ${l.topics}` : ''}</span>
        {canRecord(l, now) && <button type="button" onClick={() => setEditing(true)} className={`${btnSub} min-h-[36px] text-[13.5px]`}>Edit</button>}
      </div>
    );
  }

  async function save() {
    if (!result) return;
    setBusy(true);
    setErr('');
    try {
      const t = result === 'student_no_show' ? '' : topics.trim();
      await actions.record(l.id, result, t, remarks);
      setEditing(false);
      await onSaved({ ...l, state: 'done', classStatus: savedStatus(l, result), topics: t || null, remarks: remarks.trim() || null });
    } catch (e) {
      setErr(e instanceof Error ? e.message : 'Could not save. Please try again.');
    } finally {
      setBusy(false);
    }
  }

  return (
    <div className="mt-3 grid gap-3">
      <div role="radiogroup" aria-label="How did the class go?" className="grid grid-cols-3 gap-1.5">
        {(['held', 'late', 'student_no_show'] as const).map((r) => (
          <button key={r} type="button" role="radio" aria-checked={result === r} onClick={() => setResult(r)}
            className={`min-h-[48px] rounded-[10px] border px-2 text-[14px] font-semibold ${
              result === r ? 'border-[#5b3fe0] bg-[#5b3fe0] text-white' : 'border-[#d9d5e6] bg-white text-[#1d1b2b]'}`}>
            {RESULT_TEXT[r]}
          </button>
        ))}
      </div>
      {result !== 'student_no_show' && (
        <div>
          <label className={label} htmlFor={`topics-${l.id}`}>Covered topics</label>
          <textarea id={`topics-${l.id}`} rows={2} value={topics} onChange={(e) => setTopics(e.target.value)} className={input} />
        </div>
      )}
      {(remarksOpen || result === 'late') ? <div>
        <label className={label} htmlFor={`remarks-${l.id}`}>{result === 'late' ? 'Remarks (reason for being late)' : 'Remarks'}</label>
        <textarea id={`remarks-${l.id}`} rows={result === 'late' ? 2 : 1} value={remarks} onChange={(e) => setRemarks(e.target.value)} className={input} />
      </div> : (
        <button type="button" onClick={() => setRemarksOpen(true)} className={`${btnSub} justify-self-start text-[14px]`}>+ Remarks</button>
      )}
      {err && <p className="text-[14px] text-[#b3261e]">{err}</p>}
      <div className="flex flex-wrap gap-2">
        <button type="button" disabled={!ready || busy} onClick={save} className={`${btnMain} flex-1`}>{busy ? 'Saving…' : 'Save'}</button>
        {l.state === 'done' && !extra && <button type="button" disabled={busy} onClick={() => setEditing(false)} className={btnSub}>Cancel</button>}
        {extra}
      </div>
    </div>
  );
}

/** 같은 학생 대체 수업은 한 카드로 */
function groupCovers(covers: TutorCover[]): TutorCover[][] {
  const m = new Map<string, TutorCover[]>();
  for (const c of covers) m.set(c.student, [...(m.get(c.student) ?? []), c]);
  return [...m.values()];
}

// 대체 수업 요청: 가능한 수업만 체크해 보내기 (체크 안 한 수업 = 불가). 확정은 운영진이 학생 답을 받은 뒤
function CoverCard({ covers, tz, actions, onSent }: { covers: TutorCover[]; tz: string; actions: TutorActions; onSent: () => Promise<void> }) {
  const [yes, setYes] = useState<Set<string>>(() => new Set());
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState('');
  async function send() {
    setBusy(true);
    setErr('');
    try {
      await actions.answerCover(covers.map((c) => c.id), [...yes]);
      await onSent();
    } catch (e) {
      setErr(e instanceof Error ? e.message : 'Could not send. Please try again.');
    } finally {
      setBusy(false);
    }
  }
  return (
    <div className={card}>
      <div className="flex flex-wrap items-baseline gap-x-2">
        <b className="text-[16px] text-[#1d1b2b]">{covers[0].student}</b>
        <span className="text-[13px] text-[#6b6880]">{minutesOf(covers[0])} min · not confirmed yet</span>
      </div>
      <p className="mb-1.5 mt-3 text-[13px] font-semibold text-[#55526a]">Available?</p>
      <div className="grid gap-1.5">
        {covers.map((c) => {
          const on = yes.has(c.id);
          const kst = kstText(c.startsAt, tz);
          return (
            <button key={c.id} type="button" role="checkbox" aria-checked={on} disabled={busy}
              onClick={() => { const n = new Set(yes); if (on) n.delete(c.id); else n.add(c.id); setYes(n); }}
              className={`flex min-h-[52px] items-center gap-3 rounded-[10px] border px-3 py-2 text-left ${on ? 'border-[#5b3fe0] bg-[#efebff]' : 'border-[#d9d5e6] bg-white'}`}>
              <span aria-hidden className={`flex h-6 w-6 shrink-0 items-center justify-center rounded-[6px] border text-[14px] font-bold ${
                on ? 'border-[#5b3fe0] bg-[#5b3fe0] text-white' : 'border-[#b9b4cc] text-transparent'}`}>✓</span>
              <span className="flex-1">
                <b className="block text-[15px] text-[#1d1b2b]">{whenText(c.startsAt, tz).replace(/ \d\d:\d\d$/, '')} · {timeRange(c, tz)}</b>
                {kst && <span className="text-[12.5px] text-[#6b6880]">{kst}</span>}
                {c.busy && <span className="block text-[12.5px] font-semibold text-[#b3261e]">You have another class or time off then</span>}
              </span>
            </button>
          );
        })}
      </div>
      {err && <p className="mt-2 text-[14px] text-[#b3261e]">{err}</p>}
      <button type="button" disabled={busy} onClick={send} className={`${btnMain} mt-3 w-full`}>
        {busy ? 'Sending…' : yes.size === 0 ? 'None of these work' : `Send answer · ${yes.size} available`}
      </button>
    </div>
  );
}

function MakeupCard({ m, tz, actions, closed, onSent }: { m: TutorMakeup; tz: string; actions: TutorActions; closed: boolean; onSent: () => Promise<void> }) {
  const [yes, setYes] = useState<Set<string>>(() => new Set(m.slots.filter((s) => s.answer === 'yes').map((s) => s.id)));
  const [note, setNote] = useState(m.note ?? '');
  const [sent, setSent] = useState(!!m.answeredAt);
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState('');
  const minutes = m.slots[0] ? minutesOf(m.slots[0]) : null;

  function toggle(id: string) {
    const n = new Set(yes);
    if (n.has(id)) n.delete(id);
    else n.add(id);
    setYes(n);
    setSent(false);
  }
  async function send() {
    setBusy(true);
    setErr('');
    try {
      await actions.answer(m.id, [...yes], note);
      setSent(true);
      await onSent();
    } catch (e) {
      setErr(e instanceof Error ? e.message : 'Could not send. Please try again.');
    } finally {
      setBusy(false);
    }
  }

  return (
    <div className={card}>
      <div className="flex flex-wrap items-baseline gap-x-2">
        <b className="text-[16px] text-[#1d1b2b]">{m.student}</b>
        {minutes && <span className="text-[13px] text-[#6b6880]">{minutes} min</span>}
      </div>
      <p className="text-[13.5px] text-[#55526a]">Original class: {makeupOrigin(m, tz)}</p>
      {closed ? (
        <p className="mt-2 rounded-[10px] bg-[#f3f1f8] px-3 py-2 text-[14px] font-semibold text-[#1f7a4d]">✓ Closed by Edge English</p>
      ) : (
        <>
          <p className="mb-1.5 mt-3 text-[13px] font-semibold text-[#55526a]">Available?</p>
          <div className="grid gap-1.5">
            {m.slots.map((s) => {
              const on = yes.has(s.id);
              const kst = kstText(s.startsAt, tz);
              return (
                <button key={s.id} type="button" role="checkbox" aria-checked={on} disabled={s.past || busy} onClick={() => toggle(s.id)}
                  className={`flex min-h-[52px] items-center gap-3 rounded-[10px] border px-3 py-2 text-left disabled:opacity-40 ${
                    on ? 'border-[#5b3fe0] bg-[#efebff]' : 'border-[#d9d5e6] bg-white'}`}>
                  <span aria-hidden className={`flex h-6 w-6 shrink-0 items-center justify-center rounded-[6px] border text-[14px] font-bold ${
                    on ? 'border-[#5b3fe0] bg-[#5b3fe0] text-white' : 'border-[#b9b4cc] text-transparent'}`}>✓</span>
                  <span className="flex-1">
                    <b className="block text-[15px] text-[#1d1b2b]">{whenText(s.startsAt, tz).replace(/ \d\d:\d\d$/, '')} · {timeRange(s, tz)}</b>
                    {kst && <span className="text-[12.5px] text-[#6b6880]">{kst}</span>}
                    {s.busy && <span className="block text-[12.5px] font-semibold text-[#b3261e]">You have another class or time off then</span>}
                  </span>
                </button>
              );
            })}
          </div>
          <label className={`${label} mt-3`} htmlFor={`note-${m.id}`}>{yes.size === 0 ? 'Other times you are available' : 'Note'}</label>
          <textarea id={`note-${m.id}`} rows={2} value={note} onChange={(e) => { setNote(e.target.value); setSent(false); }} className={input} />
          {err && <p className="mt-2 text-[14px] text-[#b3261e]">{err}</p>}
          <button type="button" disabled={busy || sent || !answerReady(yes, note)} onClick={send}
            className={`${sent ? btnDone : btnMain} mt-3 w-full`}>
            {sent ? 'Sent ✓ · Not confirmed yet' : busy ? 'Sending…' : 'Send answer'}
          </button>
        </>
      )}
    </div>
  );
}
