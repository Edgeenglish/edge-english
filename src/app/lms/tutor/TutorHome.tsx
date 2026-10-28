'use client';

// 강사 화면 (영어, 휴대폰 우선): ① 기록할 수업(Class Record) ② 보강 가능 여부 답 ③ 주간 일정
// 화면 검사는 편의일 뿐, 본인 수업인지·시작했는지·정산 잠김은 DB 함수가 다시 확인 (migration 2000)

import { useEffect, useState, type ReactNode } from 'react';
import {
  answerReady, canRecord, daysOf, dayLabel, kindTag, kstText, makeupOrigin, minutesOf, phaseOf, recordReady, RESULT_TEXT, resultOf, savedStatus,
  statusText, timeRange, weekOf, whenText, type TutorLesson, type TutorMakeup, type TutorResult, type TutorScreen,
} from '@/lms/tutor/screen';

export type TutorActions = {
  load: (kstFrom: string, kstTo: string) => Promise<TutorScreen>;
  record: (lessonId: string, result: TutorResult, topics: string, remarks: string) => Promise<void>;
  answer: (requestId: string, yes: string[], note: string) => Promise<void>;
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
  const week = weekOf(now, tz, offset);

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
  const makeups = [...screen.makeups, ...answeredHere.filter((m) => !screen.makeups.some((x) => x.id === m.id))];
  const days = daysOf(screen.lessons, tz, week);

  return (
    <main className="mx-auto max-w-[680px] px-4 pb-16 pt-4">
      {adminBar}
      <header className="mb-4 flex items-start justify-between gap-3">
        <div>
          <p className="text-[13px] font-semibold text-[#5b3fe0]">Edge English · Tutor</p>
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

      {toRecord.length > 0 && (
        <section className="mb-6">
          <h2 className="mb-2 text-[17px] font-bold text-[#1d1b2b]">
            Class Record <span className="text-[#5b3fe0]">{screen.toRecord.length > 0 ? screen.toRecord.length : ''}</span>
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
        </section>
      )}

      {makeups.length > 0 && (
        <section className="mb-6">
          <h2 className="mb-2 text-[17px] font-bold text-[#1d1b2b]">Make-up requests</h2>
          <div className="grid gap-3">
            {makeups.map((m) => (
              <MakeupCard key={m.id} m={m} tz={tz} actions={actions} closed={!screen.makeups.some((x) => x.id === m.id)}
                onSent={async () => {
                  setAnsweredHere((x) => [...x.filter((y) => y.id !== m.id), m]);
                  await reload();
                }} />
            ))}
          </div>
        </section>
      )}

      <section>
        <div className="mb-2 flex items-center justify-between gap-2">
          <h2 className="text-[17px] font-bold text-[#1d1b2b]">Schedule</h2>
          <div className="flex items-center gap-1.5">
            <button type="button" aria-label="Previous week" disabled={loading} onClick={() => goWeek(offset - 1)} className={`${btnSub} px-3`}>‹</button>
            <button type="button" disabled={loading || offset === 0} onClick={() => goWeek(0)} className={`${btnSub} px-3 text-[14px]`}>This week</button>
            <button type="button" aria-label="Next week" disabled={loading} onClick={() => goWeek(offset + 1)} className={`${btnSub} px-3`}>›</button>
          </div>
        </div>
        <p className="mb-2 text-[14px] font-semibold text-[#55526a]">{dayLabel(week.from)} – {dayLabel(week.to)}</p>
        {days.length === 0 && <p className={`${card} text-[15px] text-[#6b6880]`}>No classes</p>}
        <div className="grid gap-4">
          {days.map((d) => (
            <div key={d.date}>
              <h3 className="mb-1.5 text-[14px] font-bold text-[#1d1b2b]">{dayLabel(d.date)}</h3>
              <div className="grid gap-2">
                {d.lessons.map((l) => (
                  <ScheduleRow key={l.id} lesson={l} tz={tz} now={now} meetUrl={screen.tutor.meetUrl} actions={actions} onSaved={() => reload()}
                    inRecordList={toRecord.some((x) => x.id === l.id)} />
                ))}
              </div>
            </div>
          ))}
        </div>
      </section>
    </main>
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

function ScheduleRow({ lesson: l, tz, now, meetUrl, actions, onSaved, inRecordList }: {
  lesson: TutorLesson; tz: string; now: Date; meetUrl: string | null; actions: TutorActions; onSaved: () => Promise<void>; inRecordList: boolean;
}) {
  const [open, setOpen] = useState(false);
  const phase = phaseOf(l, now);
  const tag = kindTag(l);
  const kst = kstText(l.startsAt, tz);
  const status = statusText(l, now);
  return (
    <div className={`rounded-[12px] border border-[#e6e3ef] bg-white p-3 ${phase === 'canceled' ? 'opacity-60' : ''}`}>
      <div className="flex items-start gap-3">
        <div className="w-[96px] shrink-0">
          <b className="block text-[15px] text-[#1d1b2b]">{timeRange(l, tz)}</b>
          {kst && <span className="text-[12.5px] text-[#6b6880]">{kst}</span>}
        </div>
        <div className="min-w-0 flex-1">
          <div className="flex flex-wrap items-baseline gap-x-2">
            <b className={`text-[15px] text-[#1d1b2b] ${phase === 'canceled' ? 'line-through' : ''}`}>{l.student}</b>
            {tag && <span className="rounded-[6px] bg-[#efebff] px-1.5 text-[12px] font-semibold text-[#5b3fe0]">{tag}</span>}
          </div>
          <p className="text-[13px] text-[#6b6880]">
            {minutesOf(l)} min{l.count ? ` · Class ${l.count.n}/${l.count.total}` : ''}{l.level ? ` · ${l.level}` : ''}
          </p>
          <p className={`text-[13px] font-semibold ${phase === 'to_record' ? 'text-[#b3261e]' : phase === 'recorded' ? 'text-[#1f7a4d]' : 'text-[#55526a]'}`}>
            {phase === 'recorded' ? `✓ ${status}` : status}
          </p>
          {phase === 'recorded' && l.topics && <p className="text-[13px] text-[#55526a]">{l.topics}</p>}
          {l.makeupOf && <p className="text-[12.5px] text-[#6b6880]">Make-up for {whenText(l.makeupOf, tz)}</p>}
        </div>
      </div>
      {(phase !== 'canceled') && (
        <div className="mt-2 flex flex-wrap gap-1.5">
          {phase === 'upcoming' && meetUrl && <a href={meetUrl} target="_blank" rel="noreferrer" className={`${btnSub} inline-flex items-center text-[14px]`}>Classroom</a>}
          {l.noteUrl && <a href={l.noteUrl} target="_blank" rel="noreferrer" className={`${btnSub} inline-flex items-center text-[14px]`}>Class notes</a>}
          {canRecord(l, now) && !inRecordList && (
            <button type="button" onClick={() => setOpen(!open)} className={`${open ? btnDone : phase === 'to_record' ? btnMain : btnSub} text-[14px]`}>
              {phase === 'to_record' ? 'Record' : 'Edit record'}
            </button>
          )}
          {l.locked && <span className="self-center text-[13px] text-[#6b6880]">In payroll</span>}
        </div>
      )}
      {open && <RecordForm lesson={l} now={now} actions={actions} startEditing onSaved={async () => { setOpen(false); await onSaved(); }} />}
    </div>
  );
}

function RecordForm({ lesson: l, now, actions, startEditing, onSaved }: {
  lesson: TutorLesson; now: Date; actions: TutorActions; startEditing: boolean; onSaved: (saved: TutorLesson) => Promise<void>;
}) {
  const [editing, setEditing] = useState(startEditing);
  const [result, setResult] = useState<TutorResult | null>(resultOf(l.classStatus));
  const [topics, setTopics] = useState(l.topics ?? '');
  const [remarks, setRemarks] = useState(l.remarks ?? '');
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
      <div>
        <label className={label} htmlFor={`remarks-${l.id}`}>{result === 'late' ? 'Remarks (reason for being late)' : 'Remarks'}</label>
        <textarea id={`remarks-${l.id}`} rows={result === 'late' ? 2 : 1} value={remarks} onChange={(e) => setRemarks(e.target.value)} className={input} />
      </div>
      {err && <p className="text-[14px] text-[#b3261e]">{err}</p>}
      <div className="flex gap-2">
        <button type="button" disabled={!ready || busy} onClick={save} className={`${btnMain} flex-1`}>{busy ? 'Saving…' : 'Save'}</button>
        {l.state === 'done' && <button type="button" disabled={busy} onClick={() => setEditing(false)} className={btnSub}>Cancel</button>}
      </div>
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
