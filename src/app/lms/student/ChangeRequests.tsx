'use client';
/*
 * 학생 홈 [정규 시간 변경] · [강사 변경 상담] (정책 원본 H26(208)·보충·보충 2, 대표 11/17 최종 시안
 * docs/lms/previews/student-regular-tutor-change-drafts.html). 신청만 — 확정은 운영진(운영자 홈 할 일).
 * 시각은 모두 학생 거주지 시간(팝업 맨 위 배지). 가능한 시간·적용 주 판정은 DB, 여기서는 미리 보여 주기만.
 */
import { useEffect, useMemo, useState } from 'react';
import { formatInZone } from '@/lms/rules/dates';
import { addDays, mondayOf, sameSlot, slotAt, TUTOR_CHANGE_REASONS, weekFor, weekOk, type KstSlot } from '@/lms/student/regular-change';
import type { KstDate } from '@/lms/rules/dates';
import type { RcOptions, RegularRequest, TutorChangeRequest } from '@/lms/student/live';

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

type Pick = { c1: KstSlot | null; c2: KstSlot | null };

export function RegularChangeSheet(props: {
  tz: string;
  load: (from?: KstDate | null) => Promise<RcOptions>;
  pending: RegularRequest | null;
  busy: boolean;
  onSubmit: (items: { old: KstSlot; c1: KstSlot; c2: KstSlot | null }[], reason: string, start: KstDate | null) => Promise<boolean>;
  onWithdraw: (id: string) => Promise<boolean>;
}) {
  const { tz, busy } = props;
  const [o, setO] = useState<RcOptions | null>(null);
  const [err, setErr] = useState(false);
  const [olds, setOlds] = useState<number[]>([]);
  const [picks, setPicks] = useState<Record<number, Pick>>({});
  const [target, setTarget] = useState<{ old: number; rank: 'c1' | 'c2' } | null>(null);
  const [day, setDay] = useState<number | null>(null);
  const [reason, setReason] = useState('');
  const [sent, setSent] = useState(false);
  const [withdrawn, setWithdrawn] = useState(false);
  // 연 순간의 신청 상태로 고정 (신청 직후 '신청했어요 ✓' 화면에 머묾)
  const [pending] = useState(props.pending);
  // 변경 시작 주 (H26(208) 보충 4): null = 후보마다 가장 빠른 주. 처음 읽은 값(base)으로 고를 수 있는 주 목록을 만듦
  const [start, setStart] = useState<KstDate | null>(null);
  const [base, setBase] = useState<RcOptions | null>(null);

  useEffect(() => {
    if (pending) return;
    props.load().then((x) => {
      setO(x);
      setBase(x);
      if (x.state === 'ok' && x.slots.length === 1) { setOlds([x.slots[0].weekday]); setTarget({ old: x.slots[0].weekday, rank: 'c1' }); }
    }).catch(() => setErr(true));
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  const ok = o?.state === 'ok' ? o : null;
  const refWeek = ok ? addDays(mondayOf(ok.today), 7) : '';
  const slotOf = (wd: number) => ok!.slots.find((s) => s.weekday === wd)!;
  const ctx = ok ? { today: ok.today, finalEnd: ok.finalEnd, periods: ok.periods } : null;
  const weekOf = (old: KstSlot, c: KstSlot) => (!ctx ? null : start ? (weekOk(ctx, [{ old, new: c }], start) ? start : null) : weekFor(ctx, [{ old, new: c }]));
  const changeStart = (w: KstDate | null) => {
    setStart(w);
    setPicks({});
    setTarget(olds.length ? { old: olds[0], rank: 'c1' } : null);
    // 고른 주부터 매주 비어 있는 시간으로 다시 읽음 (가장 빠른 주면 처음 값)
    if (!w) { setO(base); return; }
    setO(null);
    props.load(w).then(setO).catch(() => setErr(true));
  };

  /** 이 수업(old)의 새 시간으로 고를 수 있는 것: 남는 다른 정규 요일·다른 수업에서 고른 요일 빼고, 적용 주가 있는 것 */
  const allowed = useMemo(() => {
    if (!ok || !target) return [];
    const kept = ok.slots.filter((s) => !olds.includes(s.weekday)).map((s) => s.weekday);
    const taken = olds.filter((w) => w !== target.old).flatMap((w) => [picks[w]?.c1, picks[w]?.c2]).filter(Boolean).map((s) => s!.weekday);
    const other = picks[target.old]?.[target.rank === 'c1' ? 'c2' : 'c1'];
    const old = slotOf(target.old);
    return ok.free.filter((f) => !kept.includes(f.weekday) && !taken.includes(f.weekday) && !sameSlot(f, old) && !(other && sameSlot(f, other)) && weekOf(old, f));
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [ok, target, olds, picks]);
  const byDay = useMemo(() => {
    const m = new Map<number, { s: KstSlot; time: string; text: string }[]>();
    for (const s of allowed) {
      const l = local(refWeek, s, tz);
      m.set(l.dow, [...(m.get(l.dow) ?? []), { s, time: l.time, text: l.text }]);
    }
    for (const v of m.values()) v.sort((a, b) => a.time.localeCompare(b.time));
    return m;
  }, [allowed, refWeek, tz]);
  useEffect(() => {
    if (day !== null && byDay.has(day)) return;
    setDay(DAY_ORDER.find((d) => byDay.has(d)) ?? null);
  }, [byDay, day]);

  // 신청해 둔 것이 있으면: 신청 내용 + [신청 취소]
  if (pending) {
    const r = pending;
    const w = addDays(mondayOf(new Date().toISOString().slice(0, 10)), 7);
    return (
      <div className="grid gap-3">
        <h2 className="text-[18px] font-bold">정규 시간 변경</h2>
        <p className="text-[14px] font-bold text-[#5b3df0]">{withdrawn ? '신청 취소함' : '변경 신청 확인 중'}</p>
        {r.items.map((it) => (
          <div key={it.old.weekday} className={`${card} grid gap-1.5 p-3`}>
            <p className={lbl}>{local(w, it.old, tz).text} → 새 시간</p>
            {([['1순위', it.c1], ['2순위', it.c2]] as const).map(([k, c]) => c && (
              <p key={k} className="flex justify-between gap-2 rounded-[10px] bg-[#efebff] px-3 py-2 text-[14px]">
                <span>{k} · {local(c.week, c, tz).text}</span><b className="shrink-0 text-[#5b3df0]">{weekText(c.week)}</b>
              </p>
            ))}
          </div>
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

  // 가장 빠른 적용일: 아무것도 고르기 전, 바꿀 수 있는 모든 수업·시간 중 가장 빠른 주 (처음 읽은 값 기준)
  const b = base?.state === 'ok' ? base : ok;
  const bctx = { today: b.today, finalEnd: b.finalEnd, periods: b.periods };
  const earliest = b.slots.flatMap((s) => b.free.filter((f) => !sameSlot(f, s)).map((f) => weekFor(bctx, [{ old: s, new: f }]))).filter(Boolean).sort()[0] ?? null;
  const weeks: KstDate[] = [];
  for (let w = earliest; w && w <= b.finalEnd; w = addDays(w, 7)) weeks.push(w);
  const canSend = olds.length > 0 && olds.every((w) => picks[w]?.c1);
  const pickRow = (w: number, rank: 'c1' | 'c2') => {
    const c = picks[w]?.[rank];
    const on = target?.old === w && target.rank === rank;
    const name = rank === 'c1' ? '1순위' : '2순위 (선택)';
    if (!c) return (
      <button type="button" disabled={sent} onClick={() => setTarget({ old: w, rank })}
        className={`flex min-h-[44px] w-full items-center justify-between rounded-[10px] px-3 text-left text-[14px] ${on ? 'border border-[#5b3df0] bg-white text-[#5b3df0]' : 'bg-[#f3f1f8] text-[#8b88a0]'}`}>
        <span>{name}</span><b>{on ? '아래에서 고르기' : '+'}</b>
      </button>
    );
    const wk = weekOf(slotOf(w), c);
    return (
      <div className={`flex min-h-[44px] items-center justify-between gap-2 rounded-[10px] px-3 text-[14px] ${on ? 'border border-[#5b3df0]' : ''} bg-[#efebff]`}>
        <button type="button" disabled={sent} className="min-w-0 flex-1 text-left" onClick={() => setTarget({ old: w, rank })}>
          {rank === 'c1' ? '1순위' : '2순위'} · {local(refWeek, c, tz).text}
        </button>
        <b className="shrink-0 text-[13px] text-[#5b3df0]">{wk ? weekText(wk) : ''}</b>
        {!sent && <button type="button" aria-label="빼기" className="-mr-2 h-10 w-9 shrink-0 text-[#5b3df0]"
          onClick={() => { setPicks((p) => ({ ...p, [w]: { ...(p[w] ?? { c1: null, c2: null }), [rank]: null } })); setTarget({ old: w, rank }); }}>✕</button>}
      </div>
    );
  };
  const choose = (s: KstSlot) => {
    if (!target) return;
    setPicks((p) => {
      const cur = { ...(p[target.old] ?? { c1: null, c2: null }), [target.rank]: s };
      return { ...p, [target.old]: cur };
    });
    // 1순위를 고르면 2순위 칸으로 (2순위는 안 골라도 됨)
    if (target.rank === 'c1' && !picks[target.old]?.c2) setTarget({ old: target.old, rank: 'c2' });
    else setTarget(null);
  };
  const chosenNow = target ? picks[target.old]?.[target.rank] : null;

  return (
    <div className="grid gap-3.5">
      <h2 className="text-[18px] font-bold">정규 시간 변경</h2>
      <p className="flex justify-between gap-2 rounded-[10px] bg-[#f3f1f8] px-3 py-2.5 text-[14px]">
        <span>가장 빠른 적용일</span><b className="text-[#5b3df0]">{earliest ? weekText(earliest) : '-'}</b>
      </p>
      {weeks.length > 1 && (
        <label className="grid gap-1.5">
          <span className={lbl.replace('mb-1.5 ', '')}>변경 시작 주</span>
          <select value={start ?? ''} disabled={sent} onChange={(e) => changeStart((e.target.value || null) as KstDate | null)}
            className="min-h-[44px] rounded-[10px] border border-[#e6e3ef] bg-white px-3 text-[14px] font-semibold">
            <option value="">가장 빠른 주</option>
            {weeks.slice(1).map((w) => <option key={w} value={w}>{weekText(w)}</option>)}
          </select>
        </label>
      )}
      {!earliest && <p className="text-[14px] font-bold text-[#b3261e]">이번 수강기간에는 더 바꿀 수 없어요</p>}
      {earliest && (
        <>
          {ok.slots.length > 1 && (
            <div>
              <p className={lbl}>지금 정규 수업 · 바꿀 수업 고르기</p>
              <div className="flex flex-wrap gap-1.5">
                {ok.slots.map((s) => {
                  const on = olds.includes(s.weekday);
                  return (
                    <button key={s.weekday} type="button" disabled={sent} className={chip(on)} aria-pressed={on}
                      onClick={() => {
                        const next = on ? olds.filter((x) => x !== s.weekday) : [...olds, s.weekday];
                        setOlds(next);
                        if (on) { setPicks((p) => { const q = { ...p }; delete q[s.weekday]; return q; }); setTarget(next.length ? { old: next[0], rank: 'c1' } : null); }
                        else setTarget({ old: s.weekday, rank: 'c1' });
                      }}>
                      {local(refWeek, s, tz).text}
                    </button>
                  );
                })}
              </div>
            </div>
          )}
          {olds.map((w) => (
            <div key={w} className={`${card} grid gap-1.5 p-3`}>
              <p className={lbl}>{local(refWeek, slotOf(w), tz).text} → 새 시간</p>
              {pickRow(w, 'c1')}
              {pickRow(w, 'c2')}
              {target?.old === w && !sent && (
                <div className="mt-1 grid gap-2">
                  <div className="grid grid-cols-7 gap-1">
                    {DAY_ORDER.map((d) => {
                      const has = byDay.has(d);
                      return (
                        <button key={d} type="button" disabled={!has} onClick={() => setDay(d)} aria-pressed={day === d}
                          className={`min-h-[40px] rounded-[8px] border text-[14px] font-bold ${!has ? 'border-[#eeecf4] text-[#c9c6d6]' : day === d ? 'border-[#5b3df0] bg-[#5b3df0] text-white' : 'border-[#e6e3ef] bg-white'}`}>
                          {WD[d]}
                        </button>
                      );
                    })}
                  </div>
                  {day !== null && (
                    <div className="grid grid-cols-3 gap-1.5 lg:grid-cols-4">
                      {(byDay.get(day) ?? []).map((x) => {
                        const on = !!chosenNow && sameSlot(chosenNow, x.s);
                        return <button key={`${x.s.weekday}${x.s.time}`} type="button" onClick={() => choose(x.s)} className={chip(on)}>{ampm(x.time)}</button>;
                      })}
                    </div>
                  )}
                </div>
              )}
            </div>
          ))}
          <div>
            <p className={lbl}>변경 사유 (선택)</p>
            <textarea value={reason} disabled={sent} onChange={(e) => setReason(e.target.value)} rows={2} maxLength={300}
              className="w-full rounded-[10px] border border-[#e6e3ef] bg-white px-3 py-2 text-[14px]" />
          </div>
          {sent && <p className="rounded-[10px] bg-[#e6f6ec] px-3 py-2.5 text-[14px] font-bold text-[#1f7a4d]">신청했어요 ✓ · 확정 전까지 기존 시간 그대로</p>}
          <button type="button" disabled={busy || sent || !canSend} className={sent ? DONE : PRI}
            onClick={async () => {
              const items = olds.map((w) => ({ old: slotOf(w), c1: picks[w]!.c1!, c2: picks[w]?.c2 ?? null }));
              if (await props.onSubmit(items, reason.trim(), start)) { setSent(true); setTarget(null); }
            }}>
            {sent ? '신청함 ✓' : '신청하기'}
          </button>
        </>
      )}
    </div>
  );
}

/** 강사 변경 상담 안내 (대표 11/18 최종 문구): 늘 보이는 한 줄 + ⓘ 누르면 아래에 펼침 */
function TutorChangeInfo() {
  const [open, setOpen] = useState(false);
  return (
    <div className="grid gap-2">
      <p className="flex items-center gap-1.5 text-[14px] text-[#3d3a52]">
        강사 변경은 언제든 편하게 요청해 주세요.
        <button type="button" aria-label="강사 변경 안내" aria-expanded={open} onClick={() => setOpen((v) => !v)}
          className="grid h-7 w-7 place-items-center rounded-full text-[17px] leading-none text-[#8b88a0] hover:text-[#55526a] focus-visible:outline focus-visible:outline-2 focus-visible:outline-[#5b3df0]">ⓘ</button>
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
