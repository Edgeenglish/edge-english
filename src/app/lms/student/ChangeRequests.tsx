'use client';
/*
 * 학생 홈 [정규 시간 변경] · [강사 변경 상담] (정책 원본 H26(208)·보충·보충 2·보충 7(모든 정규 수업 같은 시간), 대표 11/17·11/18 시안
 * docs/lms/previews/student-regular-tutor-change-drafts.html). 신청만 — 확정은 운영진(운영자 홈 할 일).
 * 시각은 모두 학생 거주지 시간(팝업 맨 위 배지). 가능한 시간·적용 주 판정은 DB, 여기서는 미리 보여 주기만.
 */
import { useEffect, useMemo, useState } from 'react';
import { formatInZone } from '@/lms/rules/dates';
import { addDays, mondayOf, sameSlot, slotAt, slotsOf, TUTOR_CHANGE_REASONS, weekFor, weekFor2, weekOk2, type KstSlot } from '@/lms/student/regular-change';
import type { KstDate } from '@/lms/rules/dates';
import type { RcOptions, RcPick, RegularRequest, TutorChangeRequest } from '@/lms/student/live';

const card = 'rounded-[16px] border border-[#e6e3ef] bg-white';
const WD = '일월화수목금토';
const DAY_ORDER = [1, 2, 3, 4, 5, 6, 0];
const ampm = (hhmm: string) => {
  const h = Number(hhmm.slice(0, 2));
  return `${h < 12 ? '오전' : '오후'} ${h % 12 === 0 ? 12 : h % 12}:${hhmm.slice(3, 5)}`;
};
const dowOf = (date: string) => new Date(`${date.slice(0, 10)}T00:00:00Z`).getUTCDay();
/** 그 주 그 정규 시각을 학생 시간대로: { dow, text: '화 오후 9:00' } */
function local(week: string, s: KstSlot, tz: string) {
  const f = formatInZone(slotAt(week, s), tz);
  return { dow: dowOf(f.date), time: f.time, text: `${WD[dowOf(f.date)]} ${ampm(f.time)}` };
}
/** '11/23(월) 주부터' — 한국 날짜 월요일 */
const weekText = (w: string) => `${Number(w.slice(5, 7))}/${Number(w.slice(8, 10))}(월) 주부터`;
const lbl = 'mb-1.5 text-[13px] font-bold text-[#55526a]';
const chip = (on: boolean, off = false) =>
  `min-h-[40px] rounded-[10px] border px-3 text-[14px] font-semibold ${off ? 'border-[#eeecf4] bg-[#f3f1f8] text-[#c9c6d6]' : on ? 'border-[#5b3df0] bg-[#efebff] text-[#5b3df0]' : 'border-[#e6e3ef] bg-white text-[#1d1b2b]'}`;
const btn = 'min-h-[48px] w-full rounded-[12px] text-[15px] font-bold';
const PRI = `${btn} bg-[#5b3df0] text-white disabled:opacity-40`;
const DONE = `${btn} bg-[#ecebf1] text-[#55526a]`;

/** 정규 일정 → 학생 시간 글 '화·금 오후 1:00' (시간이 서로 다르면 요일마다) */
function setText(week: string, slots: KstSlot[], tz: string) {
  const ls = slots.map((x) => local(week, x, tz)).sort((p, q) => DAY_ORDER.indexOf(p.dow) - DAY_ORDER.indexOf(q.dow));
  const times = [...new Set(ls.map((l) => l.time))];
  return times.length === 1 ? `${ls.map((l) => WD[l.dow]).join('·')} ${ampm(times[0])}` : ls.map((l) => l.text).join(' · ');
}
const md = (w: string) => `${Number(w.slice(5, 7))}/${Number(w.slice(8, 10))}`;
type Sel = { days: number[]; time: string; kst: KstSlot[] };
type Rank = 'c1' | 'c2';

export function RegularChangeSheet(props: {
  tz: string;
  load: (from?: KstDate | null) => Promise<RcOptions>;
  pending: RegularRequest | null;
  busy: boolean;
  onSubmit: (items: { c1: RcPick; c2: RcPick | null }[], reason: string, start: KstDate | null) => Promise<boolean>;
  onWithdraw: (id: string) => Promise<boolean>;
}) {
  const { tz, busy } = props;
  const [o, setO] = useState<RcOptions | null>(null);
  const [base, setBase] = useState<RcOptions | null>(null);
  const [err, setErr] = useState(false);
  const [start, setStart] = useState<KstDate | null>(null);
  const [picks, setPicks] = useState<Record<Rank, Sel | null>>({ c1: null, c2: null });
  const [editing, setEditing] = useState<Rank | null>('c1');
  const [draft, setDraft] = useState<number[]>([]);
  const [msg, setMsg] = useState<string | null>(null);
  const [reason, setReason] = useState('');
  const [sent, setSent] = useState(false);
  const [withdrawn, setWithdrawn] = useState(false);
  // 연 순간의 신청 상태로 고정 (신청 직후 '신청했어요 ✓' 화면에 머묾)
  const [pending] = useState(props.pending);

  useEffect(() => {
    if (pending) return;
    props.load().then((x) => { setO(x); setBase(x); }).catch(() => setErr(true));
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  const ok = o?.state === 'ok' ? o : null;
  const n = ok?.slots.length ?? 0;
  const refWeek = ok ? (start ?? addDays(mondayOf(ok.today), 7)) : '';
  const ctx = ok ? { today: ok.today, finalEnd: ok.finalEnd, periods: ok.periods } : null;
  const weekOf = (news: KstSlot[]) => (!ctx || !ok ? null : start ? (weekOk2(ctx, ok.slots, news, start) ? start : null) : weekFor2(ctx, ok.slots, news));

  // 학생 시간 (요일·시각) → 한국 정규 시각. 지금 정규 수업 + 비어 있는 시간
  const byLocal = useMemo(() => {
    const m = new Map<string, KstSlot>();
    if (!ok) return m;
    for (const x of [...ok.slots, ...ok.free]) { const l = local(refWeek, x, tz); m.set(`${l.dow}|${l.time}`, x); }
    return m;
  }, [ok, refWeek, tz]);
  const daysWith = useMemo(() => new Set([...byLocal.keys()].map((k) => Number(k.split('|')[0]))), [byLocal]);
  const times = useMemo(() => {
    if (draft.length !== n) return [];
    const all = [...new Set([...byLocal.keys()].map((k) => k.split('|')[1]))].sort();
    return all.filter((t) => draft.every((d) => byLocal.has(`${d}|${t}`)))
      .map((t) => ({ t, kst: draft.map((d) => byLocal.get(`${d}|${t}`)!) }))
      .filter((x) => sameSet(x.kst, ok!.slots) || weekOf(x.kst));
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [draft, n, byLocal, start]);

  const changeStart = (w: KstDate | null) => {
    setStart(w);
    setPicks({ c1: null, c2: null });
    setEditing('c1');
    setDraft([]);
    setMsg(null);
    if (!w) { setO(base); return; }
    setO(null);
    props.load(w).then(setO).catch(() => setErr(true));
  };

  // 신청해 둔 것이 있으면: 신청 내용 + [신청 취소]
  if (pending) {
    const r = pending;
    const it = r.items[0];
    const cands = it ? ([['1순위', it.c1], ['2순위', it.c2]] as const).filter(([, c]) => c) : [];
    const weeks = [...new Set(cands.map(([, c]) => c!.week))];
    const w0 = weeks[0] ?? addDays(mondayOf(new Date().toISOString().slice(0, 10)), 7);
    return (
      <div className="grid gap-3">
        <h2 className="text-[18px] font-bold">정규 시간 변경</h2>
        <p className="text-[14px] font-bold text-[#5b3df0]">{withdrawn ? '신청 취소함' : '변경 신청 확인 중'}</p>
        <p className="flex justify-between gap-2 rounded-[10px] bg-[#f3f1f8] px-3 py-2.5 text-[14px]"><span>현재 정규 수업</span><b>{setText(w0, r.oldSlots, tz)}</b></p>
        {weeks.length === 1 && <p className="flex justify-between gap-2 rounded-[10px] bg-[#f3f1f8] px-3 py-2.5 text-[14px]"><span>변경 시작 주</span><b className="text-[#5b3df0]">{weekText(weeks[0])}</b></p>}
        {cands.map(([k, c]) => (
          <p key={k} className="flex justify-between gap-2 rounded-[10px] bg-[#efebff] px-3 py-2.5 text-[14px]">
            <span>{k} · {setText(c!.week, slotsOf(c!.days, c!.time), tz)}</span>
            {weeks.length > 1 && <b className="shrink-0 text-[#5b3df0]">{weekText(c!.week)}</b>}
          </p>
        ))}
        {r.reason && <p className="text-[13.5px] text-[#55526a]">변경 사유: {r.reason}</p>}
        <button type="button" disabled={busy || withdrawn} className={withdrawn ? DONE : `${btn} border border-[#5b3df0] text-[#5b3df0] disabled:opacity-40`}
          onClick={async () => { if (await props.onWithdraw(r.id)) setWithdrawn(true); }}>
          {withdrawn ? '취소함 ✓' : '신청 취소'}
        </button>
      </div>
    );
  }

  if (err) return <p className="text-[14px] font-bold text-[#b3261e]">불러오지 못했어요. 다시 열어 주세요.</p>;
  if (!o) return <p className="py-6 text-center text-[14px] text-[#6b6880]">불러오는 중…</p>;
  if (!ok) {
    const why = o.state === 'pending' ? '변경 신청 확인 중' : o.state === 'scheduled' ? '정규 시간 변경 예정' : o.state === 'ending' ? '수강기간이 곧 끝나 지금은 바꿀 수 없어요' : '지금은 신청할 수 없어요';
    return <div className="grid gap-3"><h2 className="text-[18px] font-bold">정규 시간 변경</h2><p className="text-[14px] font-bold text-[#55526a]">{why}</p></div>;
  }

  // 가장 빠른 주: 처음 읽은 값에서 한 수업만 바꾸는 경우 중 가장 빠른 주
  const b = base?.state === 'ok' ? base : ok;
  const bctx = { today: b.today, finalEnd: b.finalEnd, periods: b.periods };
  const earliest = b.slots.flatMap((x) => b.free.map((f) => weekFor(bctx, [{ old: x, new: f }]))).filter(Boolean).sort()[0] ?? null;
  const weeks: KstDate[] = [];
  for (let w = earliest; w && w <= b.finalEnd; w = addDays(w, 7)) weeks.push(w);

  const choose = (x: { t: string; kst: KstSlot[] }) => {
    if (!editing) return;
    if (sameSet(x.kst, ok.slots)) return setMsg('지금 일정과 같아요');
    const other = picks[editing === 'c1' ? 'c2' : 'c1'];
    if (other && sameSet(other.kst, x.kst)) return setMsg('1순위와 같아요');
    setPicks((p) => ({ ...p, [editing]: { days: [...draft], time: x.t, kst: x.kst } }));
    setEditing(null);
    setDraft([]);
    setMsg(null);
  };
  const toggleDay = (d: number) => {
    setMsg(null);
    setDraft((cur) => (cur.includes(d) ? cur.filter((x) => x !== d) : cur.length < n ? [...cur, d] : cur));
  };
  const edit = (k: Rank) => { setEditing(k); setDraft(picks[k]?.days ?? []); setMsg(null); };
  const picker = (
    <div className="grid gap-2">
      <div className="grid grid-cols-7 gap-1">
        {DAY_ORDER.map((d) => {
          const on = draft.includes(d);
          const can = daysWith.has(d) && (on || draft.length < n);
          return (
            <button key={d} type="button" disabled={!can} onClick={() => toggleDay(d)} aria-pressed={on}
              className={`min-h-[44px] rounded-[8px] border text-[14px] font-bold ${!daysWith.has(d) ? 'border-[#eeecf4] text-[#c9c6d6]' : on ? 'border-[#5b3df0] bg-[#5b3df0] text-white' : 'border-[#e6e3ef] bg-white disabled:text-[#c9c6d6]'}`}>
              {WD[d]}
            </button>
          );
        })}
      </div>
      {draft.length === n && (times.length === 0
        ? <p className="text-[13.5px] font-bold text-[#b3261e]">가능한 시간이 없어요</p>
        : <div className="grid grid-cols-3 gap-1.5 lg:grid-cols-4">
            {times.map((x) => {
              const on = !!editing && picks[editing]?.time === x.t && sameSet(picks[editing]!.kst, x.kst);
              return <button key={x.t} type="button" onClick={() => choose(x)} className={chip(on)}>{ampm(x.t)}</button>;
            })}
          </div>)}
      {msg && <p className="text-[13.5px] font-bold text-[#b3261e]">{msg}</p>}
    </div>
  );
  const row = (k: Rank) => {
    const p = picks[k];
    const name = k === 'c1' ? '1순위' : '2순위';
    if (editing === k) return (
      <div key={k} className={`${card} grid gap-2 p-3`}>
        <p className={lbl.replace('mb-1.5 ', '')}>{name} · 요일 {n}개</p>
        {picker}
      </div>
    );
    if (!p) return null;
    const wk = start ? null : weekOf(p.kst);
    return (
      <div key={k} className="flex min-h-[48px] items-center justify-between gap-2 rounded-[10px] bg-[#efebff] px-3 text-[14px]">
        <button type="button" disabled={sent} className="min-w-0 flex-1 py-2 text-left" onClick={() => edit(k)}>
          {name} · {setText(refWeek, p.kst, tz)}
        </button>
        {wk && <b className="shrink-0 text-[13px] text-[#5b3df0]">{weekText(wk)}</b>}
        {k === 'c2' && !sent && <button type="button" aria-label="빼기" className="-mr-2 h-11 w-10 shrink-0 text-[#5b3df0]"
          onClick={() => setPicks((q) => ({ ...q, c2: null }))}>✕</button>}
      </div>
    );
  };

  return (
    <div className="grid gap-3.5">
      <h2 className="text-[18px] font-bold">정규 시간 변경</h2>
      <p className="flex justify-between gap-2 rounded-[10px] bg-[#f3f1f8] px-3 py-2.5 text-[14px]"><span>현재 정규 수업</span><b>{setText(refWeek, ok.slots, tz)}</b></p>
      {!earliest && <p className="text-[14px] font-bold text-[#b3261e]">이번 수강기간에는 더 바꿀 수 없어요</p>}
      {earliest && (
        <>
          <label className="grid gap-1.5">
            <span className={lbl.replace('mb-1.5 ', '')}>변경 시작 주</span>
            <select value={start ?? ''} disabled={sent} onChange={(e) => changeStart((e.target.value || null) as KstDate | null)}
              className="min-h-[44px] rounded-[10px] border border-[#e6e3ef] bg-white px-3 text-[14px] font-semibold">
              <option value="">가장 빠른 주 ({md(earliest)}(월)부터)</option>
              {weeks.slice(1).map((w) => <option key={w} value={w}>{weekText(w)}</option>)}
            </select>
          </label>
          {row('c1')}
          {row('c2')}
          {picks.c1 && !picks.c2 && editing !== 'c2' && !sent && (
            <button type="button" onClick={() => edit('c2')}
              className="flex min-h-[48px] items-center justify-between rounded-[10px] bg-[#f3f1f8] px-3 text-left text-[14px] text-[#55526a]">
              <span>＋ 2순위 일정 (선택)</span>
            </button>
          )}
          <div>
            <p className={lbl}>변경 사유 (선택)</p>
            <textarea value={reason} disabled={sent} onChange={(e) => setReason(e.target.value)} rows={2} maxLength={300}
              className="w-full rounded-[10px] border border-[#e6e3ef] bg-white px-3 py-2 text-[14px]" />
          </div>
          {sent && <p className="rounded-[10px] bg-[#e6f6ec] px-3 py-2.5 text-[14px] font-bold text-[#1f7a4d]">신청했어요 ✓ · 확정 전까지 기존 시간 그대로</p>}
          <button type="button" disabled={busy || sent || !picks.c1 || editing !== null} className={sent ? DONE : PRI}
            onClick={async () => {
              const pick = (x: Sel | null): RcPick | null => (x ? { days: x.kst.map((k) => k.weekday), time: x.kst[0].time } : null);
              if (await props.onSubmit([{ c1: pick(picks.c1)!, c2: pick(picks.c2) }], reason.trim(), start)) { setSent(true); setEditing(null); }
            }}>
            {sent ? '신청함 ✓' : '신청하기'}
          </button>
        </>
      )}
    </div>
  );
}

const sameSet = (a: KstSlot[], b: KstSlot[]) => a.length === b.length && a.every((x) => b.some((y) => sameSlot(x, y)));

/** 강사 변경 상담 안내 (대표 11/18 최종 문구): 늘 보이는 한 줄 + ⓘ 누르면 아래에 펼침 */
function TutorChangeInfo() {
  const [open, setOpen] = useState(false);
  return (
    <div className="grid gap-2">
      <p className="flex items-center gap-1.5 text-[14px] text-[#3d3a52]">
        강사 변경은 언제든 편하게 요청해 주세요.
        <button type="button" aria-label="강사 변경 안내" aria-expanded={open} onClick={() => setOpen((v) => !v)}
          className="-my-2 grid h-11 w-11 place-items-center rounded-full text-[17px] leading-none text-[#8b88a0] hover:text-[#55526a] focus-visible:outline focus-visible:outline-2 focus-visible:outline-[#5b3df0]">ⓘ</button>
      </p>
      {open && (
        <div className="grid gap-2 rounded-[12px] bg-[#f3f1f8] px-3.5 py-3 text-[13.5px] leading-relaxed text-[#3d3a52]">
          <p>엣지영어 강사님들은 공동운영자 2명이 직접 <b>서류 심사, 면접, 강의 교육 2회, 실제 수업 평가 2회</b>까지 총 <b>6단계</b>를 거쳐 뽑아요. 수업 실력은 기본이고, 학생을 대하는 마음과 수업 태도를 가장 중요하게 보기 때문에 어느 강사님과 수업하셔도 좋답니다.👍</p>
          <p>다만 학생마다 잘 맞는 수업 스타일이 다르다는 걸 저희도 강사님들도 너무 잘 이해하고 있어요. 수강생이 요청하면 언제든 강사 변경이 가능하다는 것도 모두 알고 계시니, 부담 없이 말씀해 주세요.☺️</p>
        </div>
      )}
    </div>
  );
}

export function TutorChangeSheet(props: {
  open: TutorChangeRequest | null;
  busy: boolean;
  onSubmit: (reasons: string[], note: string) => Promise<boolean>;
}) {
  const [codes, setCodes] = useState<string[]>(props.open?.reasons ?? []);
  const [note, setNote] = useState(props.open?.note ?? '');
  const [sent, setSent] = useState(!!props.open);
  return (
    <div className="grid gap-3.5">
      <h2 className="text-[18px] font-bold">강사 변경 상담</h2>
      <TutorChangeInfo />
      <div>
        <p className={lbl}>상담 내용 (선택 · 여러 개 가능)</p>
        <div className="grid gap-1.5">
          {TUTOR_CHANGE_REASONS.map((r) => {
            const on = codes.includes(r.code);
            return (
              <button key={r.code} type="button" disabled={sent} aria-pressed={on} className={`${chip(on)} text-left`}
                onClick={() => setCodes((c) => (on ? c.filter((x) => x !== r.code) : [...c, r.code]))}>
                {r.label}
              </button>
            );
          })}
        </div>
      </div>
      <div>
        <p className={lbl}>추가로 전하고 싶은 말 (선택)</p>
        <textarea value={note} disabled={sent} onChange={(e) => setNote(e.target.value)} rows={3} maxLength={500}
          className="w-full rounded-[10px] border border-[#e6e3ef] bg-white px-3 py-2 text-[14px]" />
      </div>
      <p className="text-[13px] text-[#55526a]">신청 내용은 담당 강사님께 전달되지 않아요.</p>
      {sent && <p className="rounded-[10px] bg-[#e6f6ec] px-3 py-2.5 text-[14px] font-bold text-[#1f7a4d]">요청했어요 ✓</p>}
      <button type="button" disabled={props.busy || sent} className={sent ? DONE : PRI}
        onClick={async () => { if (await props.onSubmit(codes, note.trim())) setSent(true); }}>
        {sent ? '요청함 ✓' : '상담 요청하기'}
      </button>
    </div>
  );
}

/** 처리 내역 탭 맨 위: 정규 시간 변경 신청·강사 변경 상담 (처리해도 사라지지 않음) */
export function ChangeRequestRows({ data, tz, onOpenRegular }: { data: { regular: RegularRequest[]; tutor: TutorChangeRequest[] }; tz: string; onOpenRegular: () => void }) {
  const day = (d: Date) => { const f = formatInZone(d, tz); return `${Number(f.date.slice(5, 7))}/${Number(f.date.slice(8, 10))}(${WD[dowOf(f.date)]})`; };
  const rows = [
    ...data.regular.map((r) => ({
      at: r.createdAt, key: r.id, title: '정규 시간 변경 신청',
      state: r.status === 'pending' ? '확인 중' : r.status === 'confirmed' ? `확정 · ${r.effectiveFrom ? weekText(r.effectiveFrom) : ''}` : r.status === 'rejected' ? '반려' : '신청 취소',
      open: r.status === 'pending',
    })),
    ...data.tutor.map((t) => ({ at: t.createdAt, key: t.id, title: '강사 변경 상담', state: t.status === 'open' ? '요청함' : '상담 완료', open: false })),
  ].sort((a, b) => b.at.getTime() - a.at.getTime());
  if (rows.length === 0) return null;
  return (
    <section className={`${card} px-4`}>
      {rows.map((r) => (
        <button key={r.key} type="button" disabled={!r.open} onClick={onOpenRegular}
          className="flex min-h-[48px] w-full items-center justify-between gap-2 border-b border-[#eeecf4] text-left text-[14px] last:border-b-0 disabled:cursor-default">
          <span><b className="font-semibold">{r.title}</b> <span className="text-[#6b6880]">· {day(r.at)}</span></span>
          <span className={`shrink-0 font-semibold ${r.open ? 'text-[#5b3df0]' : 'text-[#55526a]'}`}>{r.state}{r.open ? ' ›' : ''}</span>
        </button>
      ))}
    </section>
  );
}
