'use client';

// 재등록 넣기 · 보강 이월 · 적립금 넣기/빼기 (시안 5차 승인 2026-11-09 + 대표 수정 4가지, migration 20261109130000)
// 세 창 입력 보존 같게: ✕·바깥·다른 화면 → 입력 남음(이 기기), 다시 열면 '저장하지 않았던 입력을 되살렸어요 [원래대로]'
// [취소] → 입력이 있으면 '입력한 내용을 지울까요? [계속 입력] [지우기]', 없으면 바로 닫힘. 저장하면 남긴 입력 지움
import Link from 'next/link';
import { useEffect, useMemo, useState, type ReactNode } from 'react';
import { addDays, ampmKo, formatInZone, instantToKstDate, kstToInstant, weekdayOf, type KstDate } from '@/lms/rules/dates';
import { courseName } from '@/lms/rules/period';
import { koZone, md, mdw, productText, slotsInZone, slotsText, WD_KO, type Slot } from '@/lms/admin/students';
import {
  creditsPerPeriod, endOfCourse, firstLessonAfter, paidInTime, parseWon, renewBlock, rewardReason, WON_ERROR,
  type CarryItem, type RenewalContext, type RenewDraft, type Rewards,
} from '@/lms/admin/renewal';
import type { RenewInput, RenewResult } from '@/lms/admin/renewal-live';
import { payLabels } from '@/lms/admin/registration';
import DateInput from '../../DateInput';
import TimeInput from '../../TimeInput';
import { btnMain, btnSmall, btnSub, input, label, Row, Sheet } from './parts';

export type RenewalActions = {
  conflicts: (slots: Slot[], start: KstDate, weeks: number, dur: number) => Promise<{ date: KstDate; weekday: number; time: string; reason: string }[]>;
  renew: (ids: { request: string; plan: string }, x: RenewInput) => Promise<RenewResult>;
  confirmPlan: (planId: string) => Promise<void>;
  carryCheck: (items: { originalDate: KstDate; startsAt: string | null }[]) => Promise<Record<string, string>>;
  carry: (requestId: string, items: { originalDate: KstDate; startsAt: string | null }[]) => Promise<number>;
  reward: (requestId: string, amount: number, reason: string) => Promise<{ after: number }>;
  newId: () => string;
};
export type Who = { id: string; code: string; name: string; timezone: string };

export const won = (n: number) => `${n.toLocaleString('ko-KR')}원`;
const chip = (on: boolean) => `min-h-[40px] rounded-[10px] px-3 text-[14px] font-semibold ${on ? 'bg-[#5b3fe0] text-white' : 'border border-[#e6e3ef] bg-white text-[#1d1b2b]'}`;
const err = 'mt-1 block text-[13px] font-semibold text-[#b3261e]';
const bar = 'flex flex-wrap items-center gap-2 rounded-[10px] bg-[#fff4d6] px-3 py-2 text-[13.5px] font-semibold text-[#8a5300]';
const okBar = 'rounded-[10px] bg-[#e3f5ea] px-3 py-2 text-[13.5px] font-semibold text-[#13623a]';
const badBar = 'rounded-[10px] bg-[#fdecea] px-3 py-2 text-[13.5px] font-semibold text-[#b3261e]';
const card = 'rounded-[12px] bg-white px-3 py-2';
const ORDER = [1, 2, 3, 4, 5, 6, 0];

// ---------- 입력 보존 (세 창 공통) ----------
const key = (studentId: string, name: string) => `lms_admin_draft_${studentId}_${name}`;
function read<T>(k: string): T | null {
  try { const s = localStorage.getItem(k); return s ? (JSON.parse(s) as T) : null; } catch { return null; }
}
function write(k: string, v: unknown) {
  try { if (v === null) localStorage.removeItem(k); else localStorage.setItem(k, JSON.stringify(v)); } catch { /* 저장 안 되는 브라우저 */ }
}
function useKept<T>(studentId: string, name: string, initial: T) {
  const k = key(studentId, name);
  const [restored, setRestored] = useState(() => read<T>(k) !== null);
  const [v, setV] = useState<T>(() => read<T>(k) ?? initial);
  const [asking, setAsking] = useState(false);
  const dirty = JSON.stringify(v) !== JSON.stringify(initial);
  const set = (next: T) => { setV(next); setAsking(false); write(k, JSON.stringify(next) === JSON.stringify(initial) ? null : next); };
  const reset = () => { setV(initial); write(k, null); setRestored(false); setAsking(false); };
  return { v, set, dirty, restored: restored && dirty, reset, asking, setAsking, clear: () => write(k, null) };
}

function RestoreBar({ show, onReset }: { show: boolean; onReset: () => void }) {
  if (!show) return null;
  return (
    <div className={`${bar} mb-3`}>
      <span className="flex-1">저장하지 않았던 입력을 되살렸어요</span>
      <button type="button" className={btnSmall} onClick={onReset}>원래대로</button>
    </div>
  );
}
function CancelBar({ show, onKeep, onDrop }: { show: boolean; onKeep: () => void; onDrop: () => void }) {
  if (!show) return null;
  return (
    <div className={`${bar} mt-3`}>
      <span className="flex-1">입력한 내용을 지울까요?</span>
      <button type="button" className={btnSmall} onClick={onKeep}>계속 입력</button>
      <button type="button" className="min-h-[36px] rounded-[8px] bg-[#5b3fe0] px-3 text-[13px] font-semibold text-white" onClick={onDrop}>지우기</button>
    </div>
  );
}
function Actions({ kept, onClose, children }: { kept: { dirty: boolean; setAsking: (b: boolean) => void }; onClose: () => void; children: ReactNode }) {
  return (
    <div className="mt-4 flex gap-2">
      <button type="button" className={btnSub} onClick={() => (kept.dirty ? kept.setAsking(true) : onClose())}>취소</button>
      {children}
    </div>
  );
}

// ---------- ② 재등록 넣기 ----------
const REASON: Record<string, string> = { lesson: '다른 학생 수업과 겹쳐요', break: '다른 학생 수업과 10분 안이에요', time_off: '휴무와 겹쳐요', hold: '다른 학생 재등록 대기 시간이에요' };

export function RenewSheet({ who, ctx, today, actions, onClose, onSaved, onCarry }: {
  who: Who; ctx: RenewalContext; today: KstDate; actions: RenewalActions;
  onClose: () => void; onSaved: () => Promise<void>; onCarry: () => void;
}) {
  const p = ctx.prev!;
  const initial = useMemo<RenewDraft>(() => ({
    weeks: p.weeks ?? 4, weekly: p.weeklyCount, dur: p.durationMin, prodOpen: false,
    slots: ctx.slots.length ? ctx.slots : [], start: '', manual: false,
    method: p.lastMethod === 'card_link' ? 'card_link' : 'bank_transfer', amount: '', paidOn: '', payer: '',
  }), [p, ctx.slots]);
  const kept = useKept(who.id, '재등록 넣기', initial);
  const d = kept.v;
  const set = (x: Partial<RenewDraft>) => kept.set({ ...d, ...x });
  const start: KstDate | '' = d.manual ? d.start : firstLessonAfter(p.finalEndDate, d.slots);
  const [ids] = useState(() => ({ request: actions.newId(), plan: actions.newId() }));
  const [conf, setConf] = useState<Record<number, string>>({});
  const [busy, setBusy] = useState(false);
  const [saveErr, setSaveErr] = useState('');
  const [done, setDone] = useState<RenewResult | null>(null);
  const tutor = ctx.tutor;

  // 정규 시간 겹침 미리 검사 (일정 확정과 같은 검사, 새 수강권 기간 전체)
  const slotsKey = JSON.stringify(d.slots);
  const ready = !!start && start > p.finalEndDate && d.slots.length > 0 && d.slots.every((s) => /^\d\d:\d\d$/.test(s.time));
  useEffect(() => {
    if (!ready || !start) { setConf({}); return; }
    let live = true;
    const t = setTimeout(async () => {
      try {
        const hits = await actions.conflicts(d.slots, start, d.weeks, d.dur);
        if (!live) return;
        const by: Record<number, string> = {};
        for (const h of hits) if (!by[h.weekday]) by[h.weekday] = `${tutor?.name ?? '강사'} ${REASON[h.reason] ?? '일정과 겹쳐요'} (${mdw(h.date)})`;
        setConf(by);
      } catch { if (live) setConf({}); }
    }, 300);
    return () => { live = false; clearTimeout(t); };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [ready, start, slotsKey, d.weeks, d.dur]);

  const block = renewBlock({ ...d, start }, p.finalEndDate, Object.keys(conf).length, today);
  const dupDay = d.slots.some((s, i) => d.slots.findIndex((x) => x.weekday === s.weekday) !== i);
  const badStart = !!start && start <= p.finalEndDate;
  const offDay = !!start && !badStart && !d.slots.some((s) => s.weekday === weekdayOf(start));
  const late = !!d.paidOn && !paidInTime(d.paidOn, p.finalEndDate);
  const lab = payLabels(d.method);
  const nextSeq = p.seq + 1;

  async function save() {
    if (block || !start) return;
    setBusy(true);
    setSaveErr('');
    try {
      const r = await actions.renew(ids, {
        studentCode: who.code, weeks: d.weeks, weekly: d.weekly, dur: d.dur, start, slots: [...d.slots].sort((a, b) => a.weekday - b.weekday),
        method: d.method, amount: parseWon(d.amount) ?? 0, paidOn: d.paidOn as KstDate, payer: d.payer,
      });
      kept.clear();
      setDone(r);
      await onSaved();
    } catch (x) {
      setSaveErr(x instanceof Error ? x.message : '저장하지 못했어요.');
    } finally {
      setBusy(false);
    }
  }

  if (done) {
    return (
      <Sheet title={`재등록 넣기 · ${who.name}`} onClose={onClose} wide>
        <div className="grid gap-3">
          <p className={okBar}>✓ 저장했어요 · {done.seq}차 {courseName(d.weeks)} · 주 {d.weekly}회 · {d.dur}분 · {mdw(done.startDate)} – {mdw(done.endDate)}</p>
          {ctx.carry.length > 0 && (
            <div className={`${card} flex flex-wrap items-center justify-between gap-2`}>
              <span className="text-[14px]">남은 보강 {ctx.carry.length}회{late ? ' · 종료일 뒤 결제라 이월 안 됨' : ''}</span>
              {!late && <button type="button" className={`${btnSmall} !bg-[#5b3fe0] !text-white`} onClick={onCarry}>보강 이월</button>}
            </div>
          )}
          <div className={`${card} flex flex-wrap items-center justify-between gap-2`}>
            <span className="text-[14px]">
              {done.planState === 'confirmed' ? `정규 일정 확정 · ${slotsText(d.slots)} 한국 시간` : '정규 일정 확정 전 · 휴무로 미뤄진 수업 날짜를 먼저 잡아 주세요'}
            </span>
            {done.planState === 'confirmed' && <Link href="/lms/admin" className={`${btnSmall} inline-flex items-center`}>대시보드 ‘재등록 강사 안내’</Link>}
          </div>
          <button type="button" className={btnSub} onClick={onClose}>학생 상세로</button>
        </div>
      </Sheet>
    );
  }

  const productBox = d.prodOpen ? (
    <div className={`${card} grid gap-2`}>
      <div><span className={label}>수강 기간</span><div className="flex flex-wrap gap-1.5">{[4, 12, 24].map((w) => <button key={w} type="button" aria-pressed={d.weeks === w} className={chip(d.weeks === w)} onClick={() => set({ weeks: w })}>{w}주</button>)}</div></div>
      <div><span className={label}>주 수업 횟수</span><div className="flex flex-wrap gap-1.5">{[1, 2, 3, 5].map((w) => <button key={w} type="button" aria-pressed={d.weekly === w} className={chip(d.weekly === w)} onClick={() => set({ weekly: w })}>{w}회</button>)}</div></div>
      <div><span className={label}>수업 길이</span><div className="flex flex-wrap gap-1.5">{[20, 40, 50].map((w) => <button key={w} type="button" aria-pressed={d.dur === w} className={chip(d.dur === w)} onClick={() => set({ dur: w })}>{w}분</button>)}</div></div>
      <button type="button" className={`${btnSmall} justify-self-start`} onClick={() => set({ prodOpen: false })}>접기</button>
    </div>
  ) : (
    <div className={`${card} flex items-center justify-between gap-2`}>
      <b className="text-[14.5px]">{courseName(d.weeks)} · 주 {d.weekly}회 · {d.dur}분</b>
      <button type="button" className={btnSmall} onClick={() => set({ prodOpen: true })}>바꾸기</button>
    </div>
  );

  const used = new Set(d.slots.map((s) => s.weekday));
  const left = (
    <div className="grid min-w-0 gap-3">
      {productBox}
      <div>
        <span className={label}>정규 수업 (한국 시간 KST){tutor ? ` · ${tutor.name}` : ''}</span>
        <div className="grid gap-2">
          {d.slots.map((s, i) => (
            <div key={i} className="grid grid-cols-[76px_minmax(0,1fr)_40px] items-center gap-1.5">
              <select aria-label={`${i + 1}번째 요일`} value={s.weekday} className={`${input} !px-2`}
                onChange={(e) => set({ slots: d.slots.map((x, j) => (j === i ? { ...x, weekday: Number(e.target.value) } : x)), manual: false })}>
                {ORDER.map((w) => <option key={w} value={w}>{WD_KO[w]}</option>)}
              </select>
              <TimeInput aria-label={`${i + 1}번째 시간`} value={s.time} className={input}
                onChange={(v) => set({ slots: d.slots.map((x, j) => (j === i ? { ...x, time: v } : x)) })} />
              <button type="button" aria-label={`${WD_KO[s.weekday]} 지우기`} disabled={d.slots.length <= 1}
                className="h-[44px] w-[40px] rounded-[10px] border border-[#e6e3ef] bg-white text-[18px] text-[#6b6880] disabled:opacity-35"
                onClick={() => set({ slots: d.slots.filter((_, j) => j !== i), manual: false })}>×</button>
              {who.timezone !== 'Asia/Seoul' && /^\d\d:\d\d$/.test(s.time) && (
                <span className="col-start-2 -mt-1 text-[12px] text-[#6b6880]">{koZone(who.timezone)} {slotsInZone([s], who.timezone, start || addDays(p.finalEndDate, 1))}</span>
              )}
              {conf[s.weekday] && <span className={`col-span-3 ${err} !mt-0`}>{conf[s.weekday]}</span>}
            </div>
          ))}
          {d.slots.length < d.weekly && (
            <button type="button" className="min-h-[40px] rounded-[10px] border border-dashed border-[#5b3fe0] font-semibold text-[#5b3fe0]"
              onClick={() => set({ slots: [...d.slots, { weekday: ORDER.find((w) => !used.has(w)) ?? 1, time: d.slots.at(-1)?.time ?? '' }], manual: false })}>+ 요일 더하기</button>
          )}
          {d.slots.length !== d.weekly ? <span className={err}>주 {d.weekly}회 — 지금 {d.slots.length}개</span> : dupDay ? <span className={err}>같은 요일이 두 번 있어요</span> : null}
        </div>
      </div>
      <div>
        <label htmlFor="rn-start" className={label}>
          시작일{' '}
          {d.manual
            ? <button type="button" className={`${btnSmall} ml-1`} onClick={() => set({ manual: false, start: '' })}>첫 수업일로</button>
            : <span className="ml-1 rounded-full bg-[#f0eef6] px-2 py-0.5 text-[11.5px] font-bold text-[#6b6880]">첫 수업일</span>}
        </label>
        <DateInput id="rn-start" value={start} min={addDays(p.finalEndDate, 1)} onChange={(v) => set({ start: v, manual: true })} className={input} />
        {badStart ? <span className={err}>{mdw(p.finalEndDate)} 뒤 날짜를 골라 주세요</span>
          : offDay && start ? <span className={err}>{WD_KO[weekdayOf(start)]}요일이에요 · 정규 요일은 {[...d.slots].sort((a, b) => ORDER.indexOf(a.weekday) - ORDER.indexOf(b.weekday)).map((s) => WD_KO[s.weekday]).join('·')}</span> : null}
      </div>
      <div className="rounded-[12px] bg-[#efebff] px-3 py-1">
        <Row k="종료" v={start ? `${mdw(endOfCourse(start, d.weeks))} 오후 11:59 한국 시간` : '—'} strong />
        <Row k="수업 · 변경권" v={`${d.weeks * d.weekly}회 · 28일마다 ${creditsPerPeriod(d.weekly)}장`} />
      </div>
    </div>
  );

  const right = (
    <div className="grid min-w-0 content-start gap-3">
      <div>
        <span className={label}>결제 방법</span>
        <div className="flex flex-wrap gap-1.5">
          <button type="button" aria-pressed={d.method === 'bank_transfer'} className={chip(d.method === 'bank_transfer')} onClick={() => set({ method: 'bank_transfer' })}>계좌이체</button>
          <button type="button" aria-pressed={d.method === 'card_link'} className={chip(d.method === 'card_link')} onClick={() => set({ method: 'card_link' })}>아임웹 카드</button>
        </div>
      </div>
      <div>
        <label htmlFor="rn-amt" className={label}>받은 금액 (원){p.lastAmount ? ` · 지난 결제 ${won(p.lastAmount)}` : ''}</label>
        <input id="rn-amt" inputMode="numeric" placeholder="직접 입력" value={d.amount} onChange={(e) => set({ amount: e.target.value })} className={input} />
        {parseWon(d.amount) === null && <span className={err}>{WON_ERROR}</span>}
      </div>
      <div>
        <label htmlFor="rn-paid" className={label}>{lab.date} (한국 날짜)</label>
        <DateInput id="rn-paid" value={d.paidOn} max={today} onChange={(v) => set({ paidOn: v })} className={input} />
        {d.paidOn && d.paidOn > today ? <span className={err}>오늘 뒤 날짜는 넣을 수 없어요</span>
          : late ? <span className={err}>종료일 {mdw(p.finalEndDate)} 뒤 {d.method === 'card_link' ? '결제' : '입금'} · 보강 이월 안 됨</span> : null}
      </div>
      <div>
        <label htmlFor="rn-payer" className={label}>{lab.payer} (선택)</label>
        <input id="rn-payer" value={d.payer} onChange={(e) => set({ payer: e.target.value })} className={input} />
      </div>
    </div>
  );

  return (
    <Sheet title={`재등록 넣기 · ${who.name}`} onClose={onClose} wide>
      <RestoreBar show={kept.restored} onReset={kept.reset} />
      <p className={`${card} mb-3 flex flex-wrap gap-x-3 gap-y-1 text-[13.5px]`}>
        <span>지난 수강권 <b>{p.seq}차 {productText({ weeks: p.weeks, legacyLabel: p.legacyLabel, weeklyCount: p.weeklyCount, durationMin: p.durationMin })}</b></span>
        <span>~ {mdw(p.finalEndDate)} 오후 11:59 한국 시간</span>
        <span>남은 정규 {p.leftRegular} · 보강 {ctx.carry.length}</span>
      </p>
      <div className="grid gap-3 lg:grid-cols-2 lg:items-start">{left}{right}</div>
      {saveErr && <p className={`${badBar} mt-3`}>{saveErr}</p>}
      <CancelBar show={kept.asking} onKeep={() => kept.setAsking(false)} onDrop={() => { kept.reset(); onClose(); }} />
      <Actions kept={kept} onClose={onClose}>
        <button type="button" className={`${btnMain} flex-1`} disabled={!!block || busy} onClick={save}>
          {busy ? '저장 중…' : block || `${nextSeq}차 수강권 저장 (${mdw(start as KstDate)} 시작)`}
        </button>
      </Actions>
    </Sheet>
  );
}

// ---------- ③ 보강 이월 ----------
type CarryRow = { on: boolean; date: KstDate | ''; time: string };

export function CarrySheet({ who, ctx, today, actions, onClose, onSaved }: {
  who: Who; ctx: RenewalContext; today: KstDate; actions: RenewalActions; onClose: () => void; onSaved: () => Promise<void>;
}) {
  const p = ctx.prev!;
  const n = ctx.next!;
  const items: CarryItem[] = ctx.carry;
  const initial = useMemo<CarryRow[]>(() => items.map(() => ({ on: true, date: '', time: '' })), [items]);
  const kept = useKept(who.id, '보강 이월', initial);
  const rows = kept.v.length === items.length ? kept.v : initial;
  const setRow = (i: number, x: Partial<CarryRow>) => kept.set(rows.map((r, j) => (j === i ? { ...r, ...x } : r)));
  const [requestId] = useState(actions.newId);
  const [server, setServer] = useState<Record<string, string>>({});
  const [busy, setBusy] = useState(false);
  const [saveErr, setSaveErr] = useState('');
  const [done, setDone] = useState<{ item: CarryItem; row: CarryRow }[] | null>(null);
  const minDate = addDays(p.finalEndDate, 1) > today ? addDays(p.finalEndDate, 1) : addDays(today, 1);

  const at = (r: CarryRow) => (r.on && r.date && /^\d\d:\d\d$/.test(r.time) ? kstToInstant(r.date, r.time).toISOString() : null);
  const payload = items.map((it, i) => ({ originalDate: it.originalDate, startsAt: at(rows[i]) }));
  const chosenKey = JSON.stringify(payload.filter((_, i) => rows[i].on));
  useEffect(() => {
    const q = payload.filter((x, i) => rows[i].on && x.startsAt);
    if (q.length === 0) { setServer({}); return; }
    let live = true;
    const t = setTimeout(async () => {
      try { const r = await actions.carryCheck(q); if (live) setServer(r); } catch { if (live) setServer({}); }
    }, 300);
    return () => { live = false; clearTimeout(t); };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [chosenKey]);

  const errs = items.map((it, i) => {
    const r = rows[i];
    if (!r.on) return '';
    if (r.date && !/^\d\d:\d\d$/.test(r.time)) return '보강 시간을 골라 주세요';
    if (it.from === 'lms' && !r.date) return '보강 날짜를 넣어 주세요';
    if (r.date && r.date > n.finalEndDate) return `새 수강권 종료일(${mdw(n.finalEndDate)}) 뒤예요`;
    const me = at(r);
    if (me && rows.some((o, j) => j < i && at(o) === me)) return '위 줄과 같은 시간이에요';
    return server[it.originalDate] ?? '';
  });
  const count = rows.filter((r) => r.on).length;
  const bad = errs.some(Boolean);

  async function save() {
    setBusy(true);
    setSaveErr('');
    try {
      await actions.carry(requestId, payload.filter((_, i) => rows[i].on));
      if (n.planProposed && !n.planConfirmed) {
        try { await actions.confirmPlan(n.planProposed); } catch (x) { setSaveErr(`보강은 이월했어요. 정규 일정 확정은 못 했어요: ${x instanceof Error ? x.message : ''}`); }
      }
      kept.clear();
      setDone(items.map((item, i) => ({ item, row: rows[i] })).filter((x) => x.row.on));
      await onSaved();
    } catch (x) {
      setSaveErr(x instanceof Error ? x.message : '저장하지 못했어요.');
    } finally {
      setBusy(false);
    }
  }

  if (done) {
    return (
      <Sheet title={`보강 이월 · ${who.name}`} onClose={onClose}>
        <div className="grid gap-3">
          <p className={okBar}>✓ {done.length}회를 {n.seq}차 수강권으로 옮겼어요</p>
          {saveErr && <p className={badBar}>{saveErr}</p>}
          <div className={card}>
            {done.map(({ item, row }) => (
              <Row key={item.originalDate} k={`${mdw(item.originalDate)} 수업분`} v={row.date && row.time ? `${mdw(row.date)} ${ampmKo(row.time)} 한국 시간` : '날짜 미정'} />
            ))}
          </div>
          <button type="button" className={btnSub} onClick={onClose}>학생 상세로</button>
        </div>
      </Sheet>
    );
  }

  return (
    <Sheet title={`보강 이월 · ${who.name}`} onClose={onClose}>
      <RestoreBar show={kept.restored} onReset={kept.reset} />
      <div className="grid gap-3">
        {ctx.carryOk
          ? <p className={okBar}>이월 가능 ✓ {n.seq}차 {n.method === 'card_link' ? '결제' : '입금'} {n.paidOn ? mdw(n.paidOn) : ''} · {p.seq}차 종료 {mdw(p.finalEndDate)} 안</p>
          : <p className={badBar}>{p.seq}차 종료 {mdw(p.finalEndDate)} 뒤 결제 · 보강 이월 안 됨</p>}
        <p className="text-[12.5px] text-[#6b6880]">강사 {ctx.tutor?.name ?? '-'} · {p.durationMin}분 · 시간은 한국 시간 KST</p>
        <div className={`${card} !py-1`}>
          {items.map((it, i) => {
            const r = rows[i];
            const me = at(r);
            return (
              <div key={it.originalDate + i} className="grid grid-cols-[26px_minmax(0,1fr)] items-center gap-x-2 gap-y-1 border-b border-[#f0eef6] py-2.5 last:border-0">
                <input id={`co-${i}`} type="checkbox" checked={r.on} onChange={(e) => setRow(i, { on: e.target.checked })} className="h-[22px] w-[22px] accent-[#5b3fe0]" />
                <label htmlFor={`co-${i}`} className={`font-bold ${r.on ? '' : 'text-[#6b6880] line-through'}`}>{mdw(it.originalDate)} 수업분</label>
                {r.on && (
                  <>
                    <div className="col-start-2 grid gap-1.5 sm:grid-cols-[minmax(0,1fr)_minmax(0,1.4fr)]">
                      <DateInput aria-label="보강 날짜" value={r.date} min={minDate} max={n.finalEndDate} onChange={(v) => setRow(i, { date: v })} className={input} />
                      <TimeInput aria-label="보강 시간" value={r.time} onChange={(v) => setRow(i, { time: v })} className={input} />
                    </div>
                    {me && !errs[i] && who.timezone !== 'Asia/Seoul' && (
                      <span className="col-start-2 text-[12px] text-[#6b6880]">{koZone(who.timezone)} {zoned(new Date(me), who.timezone)}</span>
                    )}
                    {errs[i] && <span className={`col-start-2 ${err} !mt-0`}>{errs[i]}</span>}
                  </>
                )}
              </div>
            );
          })}
        </div>
      </div>
      {saveErr && <p className={`${badBar} mt-3`}>{saveErr}</p>}
      <CancelBar show={kept.asking} onKeep={() => kept.setAsking(false)} onDrop={() => { kept.reset(); onClose(); }} />
      <Actions kept={kept} onClose={onClose}>
        <button type="button" className={`${btnMain} flex-1`} disabled={!ctx.carryOk || !count || bad || busy} onClick={save}>
          {busy ? '저장 중…' : !ctx.carryOk ? '이월 안 됨' : !count ? '이월할 수업을 골라 주세요' : bad ? '빨간 줄을 고쳐 주세요' : `${count}회 이월`}
        </button>
      </Actions>
    </Sheet>
  );
}
function zoned(at: Date, tz: string): string {
  const f = formatInZone(at, tz);
  return `${mdw(f.date)} ${ampmKo(f.time)}`;
}

// ---------- ④ 적립금 넣기/빼기 ----------
type RewardDraft = { mode: 'in' | 'out'; amount: string; reason: string };

export function RewardSheet({ who, rewards, mode, today, actions, onClose, onSaved }: {
  who: Who; rewards: Rewards; mode: 'in' | 'out'; today: KstDate; actions: RenewalActions; onClose: () => void; onSaved: (flash: string) => Promise<void>;
}) {
  const initial = useMemo<RewardDraft>(() => ({ mode, amount: '', reason: '' }), [mode]);
  const kept = useKept(who.id, '적립금', initial);
  // 넣기/빼기 버튼으로 열면 그 방향으로 (남긴 입력이 있어도 방향만 맞춤)
  const d = kept.v.mode === mode || kept.dirty ? kept.v : { ...kept.v, mode };
  const set = (x: Partial<RewardDraft>) => kept.set({ ...d, ...x });
  const [requestId] = useState(actions.newId);
  const [busy, setBusy] = useState(false);
  const [saveErr, setSaveErr] = useState('');
  const parsed = parseWon(d.amount);
  const amt = parsed ?? 0;
  const signed = d.mode === 'in' ? amt : -amt;
  const over = d.mode === 'out' && amt > rewards.balance;
  const ok = parsed !== null && amt > 0 && !!d.reason.trim() && !over;
  const sign = d.mode === 'in' ? '+' : '−';

  async function save() {
    setBusy(true);
    setSaveErr('');
    try {
      const r = await actions.reward(requestId, signed, d.reason.trim());
      kept.clear();
      await onSaved(`✓ 적립금 ${sign}${won(amt)} 저장했어요 · 잔액 ${won(r.after)}`);
    } catch (x) {
      setSaveErr(x instanceof Error ? x.message : '저장하지 못했어요.');
      setBusy(false);
    }
  }
  const seg = (k: 'in' | 'out') => `min-h-[42px] rounded-[9px] text-[15px] font-extrabold ${d.mode === k ? (k === 'in' ? 'bg-[#13623a] text-white' : 'bg-[#b3261e] text-white') : 'bg-transparent text-[#1d1b2b]'}`;
  return (
    <Sheet title={`적립금 · ${who.name}`} onClose={onClose}>
      <RestoreBar show={kept.restored} onReset={kept.reset} />
      <div className="grid gap-3">
        <div className="grid grid-cols-2 gap-1 rounded-[12px] border border-[#e6e3ef] bg-white p-1">
          <button type="button" aria-pressed={d.mode === 'in'} className={seg('in')} onClick={() => set({ mode: 'in' })}>+ 넣기</button>
          <button type="button" aria-pressed={d.mode === 'out'} className={seg('out')} onClick={() => set({ mode: 'out' })}>− 빼기</button>
        </div>
        <div>
          <label htmlFor="rw-amt" className={label}>금액 (원)</label>
          <input id="rw-amt" inputMode="numeric" placeholder="직접 입력" value={d.amount} onChange={(e) => set({ amount: e.target.value })} className={input} />
          {parsed === null && <span className={err}>{WON_ERROR}</span>}
          {over && <span className={err}>잔액({won(rewards.balance)})보다 많이 뺄 수 없어요</span>}
        </div>
        <div>
          <label htmlFor="rw-reason" className={label}>사유 (필수 · 학생 화면에 보임 · 200자까지)</label>
          <input id="rw-reason" maxLength={200} value={d.reason} onChange={(e) => set({ reason: e.target.value })} className={input} />
        </div>
        <div className="rounded-[12px] bg-[#efebff] px-3 py-1">
          <Row k="지금 잔액" v={won(rewards.balance)} />
          <Row k="저장 뒤 잔액" v={<span className={over ? 'text-[#b3261e]' : ''}>{amt ? won(rewards.balance + signed) : '—'}</span>} strong />
        </div>
        <div className="rounded-[12px] border border-dashed border-[#e6e3ef] bg-white px-3 py-2">
          <p className="text-[11.5px] font-extrabold tracking-wider text-[#6b6880]">학생 화면에 이렇게 보여요</p>
          <div className="grid grid-cols-[1fr_auto] gap-x-3 pt-1">
            <span className="text-[14px]">{d.reason.trim() || '(사유)'}</span>
            <b className={`text-right text-[14px] ${d.mode === 'in' ? 'text-[#13623a]' : ''}`}>{sign}{won(amt)}</b>
            <span className="text-[12px] text-[#6b6880]">{md(today)}</span>
          </div>
        </div>
      </div>
      {saveErr && <p className={`${badBar} mt-3`}>{saveErr}</p>}
      <CancelBar show={kept.asking} onKeep={() => kept.setAsking(false)} onDrop={() => { kept.reset(); onClose(); }} />
      <Actions kept={kept} onClose={onClose}>
        <button type="button" className={`${btnMain} flex-1`} disabled={!ok || busy} onClick={save}>
          {busy ? '저장 중…' : parsed === null ? WON_ERROR : !amt ? '금액을 넣어 주세요' : !d.reason.trim() ? '사유를 넣어 주세요' : over ? '잔액보다 많아요' : `${sign}${won(amt)} ${d.mode === 'in' ? '넣기' : '빼기'}`}
        </button>
      </Actions>
    </Sheet>
  );
}

/** 학생 상세 '적립금' 칸: 잔액 + 최근 3줄 (+ 나머지 펼치기) */
export function RewardRows({ rewards }: { rewards: Rewards }) {
  const line = (r: Rewards['rows'][number]) => (
    <Row key={r.id} k={md(instantToKstDate(r.at))} v={<><b className={r.amount > 0 ? 'text-[#13623a]' : 'text-[#b3261e]'}>{r.amount > 0 ? '+' : '−'}{won(Math.abs(r.amount))}</b><span className="block text-[12.5px] text-[#6b6880]">{rewardReason(r)}</span></>} />
  );
  return (
    <>
      <Row k="잔액" v={won(rewards.balance)} strong />
      {rewards.rows.slice(0, 3).map(line)}
      {rewards.rows.length > 3 && (
        <details className="text-[13px]">
          <summary className="cursor-pointer py-1 font-semibold text-[#5b3fe0]">지난 내역 {rewards.rows.length - 3}건</summary>
          {rewards.rows.slice(3).map(line)}
        </details>
      )}
    </>
  );
}
