'use client';

// 강사용 Student profile (영어, H26(44) ③·④·⑥): Profile / About & preferences / Class / Enrollment 네 칸.
// 정규 담당 강사 = 레벨·자기소개·선호 수정, 대체강사 = 열람만(이메일 없음). 권한은 DB 함수가 확인. 닫으면 보던 주로 그대로
import { useEffect, useRef, useState, type ReactNode } from 'react';
import { enZone } from '@/lms/admin/students';
import { formatInZone } from '@/lms/rules/dates';
import { CLASS_STYLE_EN, CORRECTION_EN, dstNote, enAt, enDate, enDateYear, finalEndLines, nextLesson, RUBRIC, slotsIn, todayKst, type TutorStudentProfile } from '@/lms/tutor/profile';

export type ProfileActions = { load: (studentId: string) => Promise<TutorStudentProfile>; save: (studentId: string, fields: Record<string, string | null>) => Promise<void> };

const btnMain = 'min-h-[44px] rounded-[10px] bg-[#5b3fe0] px-4 text-[15px] font-semibold text-white disabled:opacity-40';
const btnSub = 'min-h-[44px] rounded-[10px] border border-[#e6e3ef] bg-white px-4 text-[15px] font-semibold text-[#1d1b2b] disabled:opacity-40';
const btnSmall = 'min-h-[36px] rounded-[8px] border border-[#e6e3ef] bg-white px-3 text-[13px] font-semibold text-[#5b3fe0] disabled:opacity-40';
const input = 'w-full rounded-[10px] border border-[#d9d5e6] bg-white px-3 py-2.5 text-[16px] text-[#1d1b2b]';
const label = 'mb-1 block text-[13px] font-semibold text-[#55526a]';
const NA = <i className="text-[#b9b6c8]">No answer yet</i>;
const NP = <i className="text-[#b9b6c8]">Not provided</i>;

function Row({ k, v }: { k: string; v: ReactNode }) {
  return (
    <div className="grid grid-cols-[120px_1fr] gap-2 border-b border-[#f0eef6] py-2 text-[14px] last:border-0 lg:grid-cols-[160px_1fr]">
      <span className="text-[#6b6880]">{k}</span>
      <span className="min-w-0 break-words text-[#1d1b2b]">{v}</span>
    </div>
  );
}
function Section({ title, action, children }: { title: string; action?: ReactNode; children: ReactNode }) {
  return (
    <section className="rounded-[14px] border border-[#e6e3ef] bg-white px-4 py-3">
      <div className="mb-1 flex items-center justify-between gap-2">
        <h3 className="text-[12px] font-extrabold tracking-wider text-[#6b6880]">{title}</h3>
        {action}
      </div>
      {children}
    </section>
  );
}
async function copy(text: string): Promise<boolean> {
  try { await navigator.clipboard.writeText(text); return true; } catch { return false; }
}

export default function StudentProfile({ studentId, actions, onClose, now }: { studentId: string; actions: ProfileActions; onClose: () => void; now: Date }) {
  const [p, setP] = useState<TutorStudentProfile | null>(null);
  const [err, setErr] = useState('');
  const [editing, setEditing] = useState(false);
  const [copied, setCopied] = useState<boolean | null>(null);
  useEffect(() => {
    let alive = true;
    setP(null);
    setErr('');
    actions.load(studentId).then((x) => { if (alive) setP(x); }).catch((e) => { if (alive) setErr(e instanceof Error ? e.message : 'Could not load.'); });
    return () => { alive = false; };
  }, [studentId, actions]);
  // 뒤로가기로도 닫히게 (휴대폰): 창을 열 때 history 한 칸, 뒤로 가면 닫기. 닫기 버튼은 그 한 칸을 되돌림
  const onCloseRef = useRef(onClose);
  onCloseRef.current = onClose;
  useEffect(() => {
    const onPop = () => onCloseRef.current();
    if (window.history.state?.profile !== studentId) window.history.pushState({ profile: studentId }, '');
    window.addEventListener('popstate', onPop);
    return () => window.removeEventListener('popstate', onPop);
  }, [studentId]);
  const close = () => { if (window.history.state?.profile === studentId) window.history.back(); else onClose(); };

  const body = (() => {
    if (err) return <p className="rounded-[10px] bg-[#fdecea] px-3 py-2 text-[14px] text-[#b3261e]">{err}</p>;
    if (!p) return <p className="py-8 text-center text-[15px] text-[#6b6880]">Loading…</p>;
    const s = p.student;
    const e = p.enrollment;
    const tz = p.me.timezone;
    const stTz = s.timezone;
    const today = todayKst(now);
    const next = nextLesson(p, now);
    const regular = p.access === 'regular';
    const kst = slotsIn(p.slots, 'Asia/Seoul', today);
    const mine = slotsIn(p.slots, tz, today);
    const theirs = slotsIn(p.slots, stTz, today);
    const notes = [dstNote(tz, now), dstNote(stTz, now)].filter((x): x is string => !!x);
    const shift = (d: 'before' | 'after' | null, city: string) => (d ? <span className="block text-[12.5px] text-[#a35b00]">{d === 'before' ? 'Day before' : 'Next day'} in {city}</span> : null);
    return (
      <>
        <header className="mb-3">
          <h2 className="pr-10 text-[20px] font-bold text-[#1d1b2b]">{s.nameEn}{s.displayName && s.displayName.toLowerCase() !== s.nameEn.toLowerCase() ? <span className="text-[#5b3fe0]"> “{s.displayName}”</span> : null}</h2>
          <p className="text-[13.5px] text-[#6b6880]">
            {regular ? 'Your regular student' : 'Cover class — view only'}{p.slots.length ? ` · ${kst.text.split(' ').slice(0, 1)[0]}` : ''}{e ? ` · ${e.durationMin} min` : ''}
            {!regular && ' · Email and payment details are not shared with cover tutors.'}
          </p>
        </header>
        <div className="grid gap-3 lg:grid-cols-2">
          <Section title="PROFILE">
            <Row k="Student Name" v={s.nameEn} />
            <Row k="Preferred Name" v={s.displayName ?? NP} />
            <Row k="Lives in" v={[s.city, s.country].filter(Boolean).join(', ') ? <>{[s.city, s.country].filter(Boolean).join(', ')} <span className="text-[#6b6880]">· {stTz}</span></> : <>{NP} <span className="text-[#6b6880]">· {stTz}</span></>} />
            <Row k="Gender / age" v={s.genderAge ?? NP} />
            {regular && (
              <Row k="Email" v={s.email ? (
                <span className="inline-flex flex-wrap items-center gap-1.5">
                  <span className="select-all">{s.email}</span>
                  <button type="button" className={btnSmall} onClick={async () => { setCopied(await copy(s.email!)); setTimeout(() => setCopied(null), 1500); }}>{copied === true ? 'Copied ✓' : copied === false ? 'Copy failed' : 'Copy'}</button>
                </span>
              ) : NP} />
            )}
            <Row k="English level" v={
              <>
                {s.level ?? <i className="text-[#b9b6c8]">Not assessed yet</i>}
                {(s.levelBy || s.levelAt) && <span className="block text-[12.5px] text-[#6b6880]">{s.levelBy ? `${s.levelBy}'s assessment` : 'Assessment'}{s.levelAt ? ` · ${enDate(formatInZone(s.levelAt, tz).date)}` : ''}</span>}
                {s.levelNote && <span className="block text-[12.5px] text-[#6b6880]">Earlier note: {s.levelNote}</span>}
              </>
            } />
          </Section>

          <Section title="ABOUT & PREFERENCES · STUDENT'S ANSWERS" action={regular ? <button type="button" className={btnSmall} onClick={() => setEditing(true)}>Edit</button> : undefined}>
            <Row k="Job" v={s.job ?? NA} />
            <Row k="Hobbies" v={s.hobbies ?? NA} />
            <Row k="Interests" v={s.interests ?? NA} />
            <Row k="Wants to improve" v={s.improve ?? NA} />
            <Row k="Hopes for class" v={s.hopes ?? NA} />
            <Row k="Corrections" v={s.correctionStyle ? <>{CORRECTION_EN[s.correctionStyle]}{s.correctionNote && <span className="block text-[12.5px] text-[#6b6880]">{s.correctionNote}</span>}</> : NA} />
            <Row k="Class style" v={s.classStyle ? <>{CLASS_STYLE_EN[s.classStyle]}{s.classStyleNote && <span className="block text-[12.5px] text-[#6b6880]">{s.classStyleNote}</span>}</> : NA} />
            {s.selfIntroEn && (
              <details className="mt-1 text-[13.5px]">
                <summary className="cursor-pointer font-semibold text-[#5b3fe0]">Earlier self-introduction (from the sheet, unchanged)</summary>
                <p className="mt-1 whitespace-pre-wrap text-[#1d1b2b]">{s.selfIntroEn}</p>
              </details>
            )}
          </Section>

          <Section title="CLASS">
            <Row k="Type of class" v={s.classType ?? NP} />
            {s.textbook && <Row k="Textbook" v={s.textbook} />}
            <Row k="Corrections / feedback" v={s.correctionStyle ? CORRECTION_EN[s.correctionStyle] : (s.correctionPref ?? NA)} />
            <Row k="Class duration" v={e ? `${e.durationMin} min` : NP} />
            {p.slots.length > 0 ? (
              <>
                <Row k="Korea Time (KST)" v={kst.text} />
                {tz !== 'Asia/Seoul' && <Row k={`Your time — ${enZone(tz)}`} v={<>{mine.text}{shift(mine.dayShift, enZone(tz).replace(' Time', ''))}</>} />}
                {stTz !== 'Asia/Seoul' && stTz !== tz && <Row k={`Student's time — ${enZone(stTz)}`} v={<>{theirs.text}{shift(theirs.dayShift, enZone(stTz).replace(' Time', ''))}</>} />}
                {p.nextSlots.length > 0 && (() => { const nk = slotsIn(p.nextSlots, 'Asia/Seoul', p.nextSlots[0].from); const nm = slotsIn(p.nextSlots, tz, p.nextSlots[0].from); return (
                  <Row k={`From ${enDate(p.nextSlots[0].from)}`} v={<b className="text-[#5b3fe0]">{nk.text} KST{tz !== 'Asia/Seoul' ? ` · ${nm.text} ${enZone(tz)}` : ''}</b>} />
                ); })()}
                {next && <Row k="Next class" v={<>{enAt(next.startsAt, tz)} {enZone(tz)}{tz !== 'Asia/Seoul' && <span className="text-[#6b6880]"> · {enAt(next.startsAt, 'Asia/Seoul').split(' · ')[1]} KST</span>}{next.substitute ? ' · cover class' : ''}</>} />}
                {notes.map((n) => <p key={n} className="pt-1 text-[12.5px] text-[#a35b00]">{n}</p>)}
              </>
            ) : <Row k="Class days / time" v={next ? <>{enAt(next.startsAt, tz)} {enZone(tz)} (cover class)</> : NP} />}
            <Row k="Google Docs" v={s.classNoteUrl ? <a href={s.classNoteUrl} target="_blank" rel="noreferrer" className="font-semibold text-[#5b3fe0] underline">Open class notes ↗</a> : NP} />
          </Section>

          <Section title="ENROLLMENT">
            {!e ? <p className="py-2 text-[13.5px] text-[#6b6880]">No active enrollment.</p> : regular ? (
              <>
                <Row k="Plan" v={e.weeks ? `${e.weeks / 4} month${e.weeks > 4 ? 's' : ''} (${e.weeks} weeks)` : (e.legacyLabel ?? '—')} />
                <Row k="Enrolled classes" v={`${e.lessonsPurchased}`} />
                <Row k="Rollover classes" v={`${e.lessonsCarriedIn}`} />
                <Row k="Course period" v={`${daysBetween(e.startDate, e.baseEndDate)} days`} />
                <Row k="Start date" v={enDateYear(e.startDate)} />
                <Row k="End date" v={enDateYear(e.baseEndDate)} />
                {e.extensionDays > 0 && <Row k="Extended end date" v={`${enDateYear(e.finalEndDate)} (+${e.extensionDays} days)`} />}
                <Row k="Final end" v={<>{finalEndLines(e.finalEndDate, tz, stTz).map((l) => <span key={l} className="block">{l}</span>)}</>} />
                <Row k="Remaining" v={`${e.leftRegular} regular class${e.leftRegular === 1 ? '' : 'es'}${e.leftAll > e.leftRegular ? ` + ${e.leftAll - e.leftRegular} make-up` : ''}`} />
              </>
            ) : (
              <>
                <Row k="Class duration" v={`${e.durationMin} min`} />
                <Row k="Classes per week" v={`${e.weeklyCount}`} />
                <Row k="Course ends" v={enDateYear(e.finalEndDate)} />
              </>
            )}
          </Section>

          <Section title="RECENT COVERED TOPICS">
            {p.recentTopics.length === 0 ? <p className="py-2 text-[13.5px] text-[#6b6880]">No previous class records</p> : p.recentTopics.map((t, i) => (
              <div key={i} className="border-b border-[#f0eef6] py-2 text-[13.5px] last:border-0">
                <p className="text-[12.5px] text-[#6b6880]">{enDate(formatInZone(t.startsAt, tz).date)} · {t.tutor}{t.substitute ? ' (cover)' : ''}</p>
                <p className="text-[#1d1b2b]">{t.topics}</p>
              </div>
            ))}
          </Section>
        </div>
        {editing && regular && <EditSheet p={p} onClose={() => setEditing(false)} onSaved={async () => { setEditing(false); setP(await actions.load(studentId)); }} save={(f) => actions.save(studentId, f)} />}
      </>
    );
  })();

  return (
    <div className="fixed inset-0 z-40 flex items-end justify-center bg-black/40 lg:items-center" onClick={close}>
      <div role="dialog" aria-modal="true" aria-label="Student profile" onClick={(e) => e.stopPropagation()}
        className="relative max-h-[92vh] w-full max-w-[860px] overflow-y-auto rounded-t-[20px] bg-[#f6f5fa] p-4 pb-8 lg:rounded-[20px]">
        <button type="button" onClick={close} className="mb-2 min-h-[36px] text-[13.5px] font-semibold text-[#5b3fe0]">‹ Back to schedule</button>
        <button type="button" aria-label="Close" onClick={close}
          className="absolute right-3 top-3 flex h-[40px] w-[40px] items-center justify-center rounded-full bg-white text-[18px] text-[#1d1b2b]">✕</button>
        {body}
      </div>
    </div>
  );
}

function daysBetween(a: string, b: string): number {
  return Math.round((Date.UTC(+b.slice(0, 4), +b.slice(5, 7) - 1, +b.slice(8)) - Date.UTC(+a.slice(0, 4), +a.slice(5, 7) - 1, +a.slice(8))) / 86400000) + 1;
}

const FIELDS: { key: string; title: string; kind?: 'select' | 'textarea'; options?: [string, string][] }[] = [
  { key: 'level', title: 'English level (English Speaking Level Rubric) — your assessment', kind: 'select', options: [['', 'Not assessed yet'], ...RUBRIC.map((l) => [l, l] as [string, string])] },
  { key: 'job', title: 'Job' }, { key: 'hobbies', title: 'Hobbies' }, { key: 'interests', title: 'Interests' },
  { key: 'improve', title: 'What they want to improve', kind: 'textarea' }, { key: 'hopes', title: 'What they hope for in class / atmosphere', kind: 'textarea' },
  { key: 'correction_style', title: 'How they prefer corrections', kind: 'select', options: [['', 'No answer yet'], ['immediate', CORRECTION_EN.immediate], ['major_only', CORRECTION_EN.major_only]] },
  { key: 'correction_note', title: 'Corrections — details (optional)' },
  { key: 'class_style', title: 'Preferred class style', kind: 'select', options: [['', 'No answer yet'], ['textbook', CLASS_STYLE_EN.textbook], ['free_talking', CLASS_STYLE_EN.free_talking], ['not_sure', CLASS_STYLE_EN.not_sure]] },
  { key: 'class_style_note', title: 'Class style — details (optional)' },
];
function EditSheet({ p, save, onClose, onSaved }: { p: TutorStudentProfile; save: (f: Record<string, string | null>) => Promise<void>; onClose: () => void; onSaved: () => Promise<void> }) {
  const s = p.student;
  const init: Record<string, string> = {
    level: s.level ?? '', job: s.job ?? '', hobbies: s.hobbies ?? '', interests: s.interests ?? '', improve: s.improve ?? '', hopes: s.hopes ?? '',
    correction_style: s.correctionStyle ?? '', correction_note: s.correctionNote ?? '', class_style: s.classStyle ?? '', class_style_note: s.classStyleNote ?? '',
  };
  const [v, setV] = useState(init);
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState('');
  const changed = Object.fromEntries(Object.keys(init).filter((k) => (v[k] ?? '').trim() !== init[k].trim()).map((k) => [k, (v[k] ?? '').trim() || null]));
  const n = Object.keys(changed).length;
  async function onSave() {
    setBusy(true);
    setErr('');
    try { await save(changed); await onSaved(); } catch (x) { setErr(x instanceof Error ? x.message : 'Could not save.'); setBusy(false); }
  }
  return (
    <div className="fixed inset-0 z-50 flex items-end justify-center bg-black/40 lg:items-center" onClick={onClose}>
      <div role="dialog" aria-modal="true" aria-label="Edit student profile" onClick={(e) => e.stopPropagation()} className="relative max-h-[92vh] w-full max-w-[640px] overflow-y-auto rounded-t-[20px] bg-[#f6f5fa] p-4 pb-8 lg:rounded-[20px]">
        <h3 className="mb-3 pr-10 text-[17px] font-bold text-[#1d1b2b]">Edit — level & student&apos;s answers</h3>
        <button type="button" aria-label="Close" onClick={onClose} className="absolute right-3 top-3 flex h-[40px] w-[40px] items-center justify-center rounded-full bg-white text-[18px] text-[#1d1b2b]">✕</button>
        <p className="mb-3 text-[12.5px] text-[#6b6880]">Write what the student actually told you. Leave a field empty if they have not answered (it will show as &quot;No answer yet&quot;). Your level assessment is recorded separately from the student&apos;s answers, with your name and the date.</p>
        <div className="grid gap-3">
          {FIELDS.map((f) => (
            <div key={f.key}>
              <label htmlFor={`e-${f.key}`} className={label}>{f.title}</label>
              {f.kind === 'select' ? (
                <select id={`e-${f.key}`} value={v[f.key]} onChange={(e) => setV({ ...v, [f.key]: e.target.value })} className={input}>{f.options!.map(([val, t]) => <option key={val} value={val}>{t}</option>)}</select>
              ) : f.kind === 'textarea' ? (
                <textarea id={`e-${f.key}`} value={v[f.key]} onChange={(e) => setV({ ...v, [f.key]: e.target.value })} rows={3} className={input} />
              ) : (
                <input id={`e-${f.key}`} value={v[f.key]} onChange={(e) => setV({ ...v, [f.key]: e.target.value })} className={input} />
              )}
            </div>
          ))}
        </div>
        {err && <p className="mt-3 rounded-[10px] bg-[#fdecea] px-3 py-2 text-[14px] text-[#b3261e]">{err}</p>}
        <div className="mt-4 flex gap-2">
          <button type="button" className={btnSub} onClick={onClose} disabled={busy}>Cancel</button>
          <button type="button" className={`${btnMain} flex-1`} disabled={n === 0 || busy} onClick={onSave}>{busy ? 'Saving…' : n === 0 ? 'No changes' : `Save ${n} field${n > 1 ? 's' : ''}`}</button>
        </div>
      </div>
    </div>
  );
}
