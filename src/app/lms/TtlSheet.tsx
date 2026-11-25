'use client';

// 강사 임시 근무 지역 변경 → 새 수업 시간 고르기 창 (정책 원본 H26(218), 시안 docs/lms/previews/tutor-temp-location-new-times.html)
//  강사(영어)·학생(한국어) 같은 창. 1 매주 수업 시간 → 2 날짜별 확인 → 3 신청. 학생 신청 = 바로 확정(확정 직전 DB 다시 검사),
//  강사 신청 = 학생 [이 일정에 동의하기] 뒤 확정. 학생 확인 창(review)은 강사가 보낸 시간 목록 + 동의/다시 조정
import { useEffect, useMemo, useState, type ReactNode } from 'react';
import { Rich } from '@/app/lms/Rich';
import {
  alternatives, autoAssign, CONFLICT, pickProblem,
  type TtlActions, type TtlItem, type TtlOptions, type TtlPick, type TtlResult,
} from '@/lms/ttl';

export type TtlView = {
  en: boolean;
  /** 화면 시각 한 줄 (강사 = 'Mon, 9 Nov 6:00 PM *Buenos Aires Time* / …', 학생 = 거주지 시간) */
  when: (t: Date) => string;
  /** 매주 시간 칸: 요일 묶음 이름·칸 글자 (보는 사람 시간대) */
  day: (t: Date) => { key: number; name: string };
  slot: (t: Date) => { main: string; sub?: string };
  /** 날짜만 ('12/7(월)' · 'Mon, 7 Dec') */
  date: (t: Date) => string;
  /** 창 맨 위 기준 시간 배지 (학생 = 페이지 맨 위 배지와 같은 글 '모든 날짜·시간은 Sydney 기준', 강사 = 'All times: Buenos Aires Time / KST') */
  badge?: string;
  /** 창 제목 아래 한 줄 (강사 = 학생 이름, 학생 = 선생님) */
  who: string;
};

const btnMain = 'min-h-[46px] flex-1 rounded-[10px] bg-[#5b3fe0] px-4 text-[15px] font-bold text-white disabled:opacity-40';
const btnSub = 'min-h-[46px] flex-1 rounded-[10px] border border-[#d9d2fa] bg-white px-4 text-[15px] font-bold text-[#5b3fe0] disabled:opacity-40';
const chip = 'min-h-[40px] rounded-[10px] border border-[#dcd8ea] bg-white px-3 py-1.5 text-[14px] font-semibold text-[#1d1b2b] aria-pressed:border-[#5b3fe0] aria-pressed:bg-[#5b3fe0] aria-pressed:text-white disabled:opacity-35';
const kOrd = (w: { dow: number; time: string }) => ((w.dow + 6) % 7) * 1440 + Number(w.time.slice(0, 2)) * 60 + Number(w.time.slice(3));
const rowBox = 'grid gap-1 border-t border-[#eeecf4] py-3 first:border-0';

function Frame({ title, sub, steps, children, foot, onClose, busy }: { title: string; sub: string; steps?: ReactNode; children: ReactNode; foot?: ReactNode; onClose: () => void; busy?: boolean }) {
  const close = () => { if (!busy) onClose(); };
  return (
    <div className="fixed inset-0 z-50 flex items-end justify-center bg-black/40 lg:items-center" onClick={close}>
      <div role="dialog" aria-modal="true" aria-label={title} onClick={(e) => e.stopPropagation()}
        className="relative flex max-h-[92vh] w-full max-w-[640px] flex-col rounded-t-[20px] bg-[#f6f5fa] lg:rounded-[20px]">
        <div className="px-4 pt-4">
          <button type="button" aria-label="Close" onClick={close} className="absolute right-3 top-3 flex h-[40px] w-[40px] items-center justify-center rounded-full bg-white text-[18px] text-[#1d1b2b]">✕</button>
          <h2 className="pr-10 text-[17px] font-bold text-[#1d1b2b]">{title}</h2>
          <p className="text-[13.5px] text-[#55526a]">{sub}</p>
          {steps}
        </div>
        <div className="min-h-0 flex-1 overflow-y-auto px-4 py-3">{children}</div>
        {foot && <div className="flex gap-2 border-t border-[#e6e3ef] bg-white px-4 py-3 lg:rounded-b-[20px]">{foot}</div>}
      </div>
    </div>
  );
}

function Badge({ text }: { text?: string }) {
  return text ? <p className="mb-2 inline-block rounded-full bg-[#efeaff] px-3 py-1 text-[13px] font-semibold text-[#3a22b0]">{text}</p> : null;
}

function ResultBody({ r, v, sentTo }: { r: TtlResult; v: TtlView; sentTo?: string }) {
  const T = (en: string, ko: string) => (v.en ? en : ko);
  if (sentTo) return <p className="text-[17px] font-bold text-[#1f7a4d]">✓ {T(`Sent to ${sentTo} · ${r.sent} classes`, `${r.sent}회 보냈어요`)}</p>;
  return (
    <div className="grid gap-2">
      {r.ok > 0 && <p className="text-[17px] font-bold text-[#1f7a4d]">✓ {T(`${r.ok} classes confirmed`, `${r.ok}회 확정됐어요`)}</p>}
      {r.admin > 0 && <p className="font-bold text-[#b3261e]">{T(`${r.admin} classes: Edge English is checking`, `${r.admin}회는 운영진이 확인하고 있어요`)}</p>}
      {r.sub > 0 && <p className="text-[17px] font-bold text-[#1f7a4d]">✓ {r.sub}회 대체강사와 수업 신청했어요</p>}
      {r.left > 0 && <p>{T(`${r.left} classes left`, `남은 ${r.left}회`)}</p>}
    </div>
  );
}

/** 고르기 창 (강사·학생) */
export function TtlPickSheet({ item, actions, v, onClose, onDone }: { item: TtlItem; actions: TtlActions; v: TtlView; onClose: () => void; onDone: () => void }) {
  const T = (en: string, ko: string) => (v.en ? en : ko);
  const [opt, setOpt] = useState<TtlOptions | null>(null);
  const [err, setErr] = useState('');
  const [step, setStep] = useState(1);
  const [weekly, setWeekly] = useState<string[]>([]);
  const [picks, setPicks] = useState<Record<string, TtlPick>>({});
  const [edit, setEdit] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [res, setRes] = useState<TtlResult | null>(null);
  useEffect(() => {
    let live = true;
    actions.options(item).then((o) => { if (live) setOpt(o); }).catch((e: Error) => { if (live) setErr(e.message); });
    return () => { live = false; };
  }, [actions, item]);

  const rows = useMemo(() => opt?.rows ?? [], [opt]);
  const need = Math.max(1, opt?.need ?? 1);
  const flagged = useMemo(() => new Set(rows.filter((r) => pickProblem(r, rows, autoAssign(rows, weekly, picks))).map((r) => r.key)), [rows, weekly]); // eslint-disable-line react-hooks/exhaustive-deps
  const bad = rows.filter((r) => pickProblem(r, rows, picks)).length;
  const chosen = rows.filter((r) => picks[r.key] instanceof Date || picks[r.key] === 'admin' || picks[r.key] === 'sub');
  const later = rows.filter((r) => picks[r.key] === 'later').length;

  const goStep2 = () => { setPicks(autoAssign(rows, weekly, picks)); setEdit(null); setStep(2); };
  async function submit() {
    setBusy(true); setErr('');
    try { setRes(await actions.submit(item, picks)); setStep(4); onDone(); } catch (e) { setErr((e as Error).message); } finally { setBusy(false); }
  }

  const names = v.en ? ['Weekly times', 'Check each date', 'Submit'] : ['매주 수업 시간', '날짜별 확인', '신청'];
  const steps = step < 4 && (
    <div className="mt-2 flex flex-wrap items-center gap-1 text-[12.5px]">
      {names.map((n, i) => (
        <span key={n} className="flex items-center gap-1">
          {i > 0 && <span className="text-[#9a97ad]">›</span>}
          <button type="button" disabled={i + 1 >= step} onClick={() => setStep(i + 1)}
            className={i + 1 === step ? 'font-extrabold text-[#3a22b0]' : i + 1 < step ? 'text-[#1d1b2b] underline' : 'text-[#6b6880]'}>{i + 1} {n}</button>
        </span>
      ))}
    </div>
  );
  const title = T('Choose new class times', '새 수업 시간 선택하기');
  const sub = `${v.who} · ${T(`${rows.length} classes`, `${rows.length}회`)}`;

  if (err && !opt) return <Frame title={title} sub={v.who} onClose={onClose}><p className="text-[#b3261e]">{err}</p></Frame>;
  if (!opt) return <Frame title={title} sub={v.who} onClose={onClose}><p className="text-[#6b6880]">{T('Loading…', '불러오는 중…')}</p></Frame>;
  if (res) return <Frame title={title} sub={v.who} onClose={onClose} foot={<button type="button" className={btnMain} onClick={onClose}>{T('Close', '닫기')}</button>}><ResultBody r={res} v={v} sentTo={v.en ? item.student : undefined} /></Frame>;
  if (opt.rcPending || opt.proposed) {
    return (
      <Frame title={title} sub={v.who} onClose={onClose} foot={<button type="button" className={btnMain} onClick={onClose}>{T('Close', '닫기')}</button>}>
        <p>{opt.proposed ? T('Waiting for the student.', '선생님이 신청한 수업 시간을 먼저 확인해 주세요.') : T('The student has a pending regular schedule change.', '정규 시간 변경 신청이 처리된 뒤에 고를 수 있어요.')}</p>
      </Frame>
    );
  }

  const rowView = (r: (typeof rows)[number]) => {
    const p = picks[r.key];
    const prob = pickProblem(r, rows, picks);
    const alts = edit === r.key ? alternatives(r, rows, picks) : [];
    return (
      <div key={r.key} className={rowBox}>
        <div className="flex items-start justify-between gap-2">
          <div className="min-w-0">
            <p className="text-[12.5px] text-[#6b6880] line-through"><Rich text={v.when(r.orig)} /></p>
            {p instanceof Date ? <p className="text-[14.5px] font-bold text-[#1d1b2b]"><Rich text={v.when(p)} /></p>
              : <p className="text-[14px] font-semibold text-[#6b6880]">{p === 'later' ? T('Choose later', '나중에 고르기') : p === 'admin' ? T('Edge English will arrange', '운영진에게 맡김') : p === 'sub' ? '대체강사와 수업' : T('Your weekly times don’t fit this week', '고른 요일·시간이 이 주에 없어요')}</p>}
          </div>
          <button type="button" onClick={() => setEdit(edit === r.key ? null : r.key)} className="whitespace-nowrap text-[14px] font-bold text-[#5b3fe0] underline">
            {edit === r.key ? T('Close', '닫기') : T('Change', '바꾸기')}</button>
        </div>
        {prob === 'clash' && <p className="text-[13px] font-semibold text-[#b3261e]">{T('Overlaps another class · choose another time', '다른 회차와 겹쳐요 · 다른 시간을 골라 주세요')}</p>}
        {prob === 'none' && <p className="text-[13px] font-semibold text-[#b3261e]">{r.cands.length ? T('Choose a time', '시간을 골라 주세요') : T('Ask Edge English or choose later', '운영진에게 맡기거나 나중에 골라 주세요')}</p>}
        {!prob && flagged.has(r.key) && <p className="text-[13px] font-semibold text-[#1f7a4d]">✓ {T('Adjusted', '조정함')}</p>}
        {edit === r.key && (
          <div className="mt-1 flex flex-wrap gap-1.5">
            {alts.map((t) => (
              <button key={t.toISOString()} type="button" className={chip} aria-pressed={p instanceof Date && p.getTime() === t.getTime()}
                onClick={() => { setPicks({ ...picks, [r.key]: t }); setEdit(null); }}><Rich text={v.when(t)} /></button>
            ))}
            {/* 같은 주에 새 시간이 없는 회차만 학생이 대체강사와 수업 (H26(218) 보충3) — 강사 화면엔 없음 */}
            {!v.en && r.cands.length === 0 && <button type="button" className={chip} aria-pressed={p === 'sub'} onClick={() => { setPicks({ ...picks, [r.key]: 'sub' }); setEdit(null); }}>대체강사와 수업할게요</button>}
            {alts.length === 0 && <button type="button" className={chip} aria-pressed={p === 'admin'} onClick={() => { setPicks({ ...picks, [r.key]: 'admin' }); setEdit(null); }}>{T('Ask Edge English', '운영진에게 맡기기')}</button>}
            <button type="button" className={chip} aria-pressed={p === 'later'} onClick={() => { setPicks({ ...picks, [r.key]: 'later' }); setEdit(null); }}>{T('Choose later', '나중에 고르기')}</button>
          </div>
        )}
      </div>
    );
  };

  if (step === 1) {
    const groups = new Map<number, { name: string; list: typeof opt.weekly }>();
    for (const w of opt.weekly) {
      const d = v.day(w.sample);
      const g = groups.get(d.key) ?? { name: d.name, list: [] };
      g.list.push(w); groups.set(d.key, g);
    }
    const order = [...groups.keys()].sort((a, b) => ((a + 6) % 7) - ((b + 6) % 7));
    return (
      <Frame title={title} sub={sub} steps={steps} onClose={onClose}
        foot={<button type="button" className={btnMain} disabled={weekly.length === 0} onClick={goStep2}>{T('Next ›', '다음 ›')}</button>}>
        {/* 학생: 왜 바꾸는지·정규 시간은 그대로인지 (대표 11/25) */}
        {!v.en && <div className="mb-3 grid gap-1 text-[14px] leading-relaxed text-[#1d1b2b]">
          <p>{item.tutor} 강사님의 임시 근무 지역 변경으로 기존 시간에 수업이 어려워졌어요.</p>
          <p>해당 기간에만 수업할 새로운 시간을 골라 주세요. 임시 근무 기간이 끝나면 기존 정규 수업 시간으로 돌아가요.</p>
        </div>}
        {v.en && <p className="mb-3 text-[13.5px] text-[#55526a]">The student can select and request new class times directly through their LMS.<br />If the student asks for your help during class, you can discuss the options together and submit the agreed schedule.<br />Any schedule you submit must be confirmed by the student before it can be finalized.</p>}
        <Badge text={v.badge} />
        <p className="mb-2 text-[14px] font-bold">{T(`Choose ${need} · ${weekly.length}/${need}`, `${need}개 고르기 · ${weekly.length}/${need}`)}</p>
        {opt.weekly.length === 0 && <p className="text-[#b3261e]">{T('No open times. Please open times in Availability first.', '고를 수 있는 시간이 없어요.')}</p>}
        <div className="grid gap-2">
          {order.map((k) => (
            <div key={k} className="grid grid-cols-[44px_1fr] gap-2">
              <span className="pt-2 text-[13.5px] font-bold">{groups.get(k)!.name}</span>
              <div className="flex flex-wrap gap-1.5">
                {groups.get(k)!.list.sort((a, b) => kOrd(a) - kOrd(b)).map((w) => {
                  const key = `${w.dow}-${w.time}`; const on = weekly.includes(key); const s = v.slot(w.sample);
                  return (
                    <button key={key} type="button" className={chip} aria-pressed={on} disabled={!on && weekly.length >= need}
                      onClick={() => setWeekly(on ? weekly.filter((x) => x !== key) : [...weekly, key])}>
                      {s.main}{s.sub && <small className="block text-[11.5px] font-medium opacity-80">{s.sub}</small>}
                    </button>
                  );
                })}
              </div>
            </div>
          ))}
        </div>
      </Frame>
    );
  }
  if (step === 2) {
    const top = rows.filter((r) => flagged.has(r.key) || pickProblem(r, rows, picks));
    const ok = rows.filter((r) => !top.includes(r));
    return (
      <Frame title={title} sub={sub} steps={steps} onClose={onClose}
        foot={<><button type="button" className={btnSub} onClick={() => setStep(1)}>‹ {T('Back', '이전')}</button>
          <button type="button" className={btnMain} disabled={bad > 0 || chosen.length === 0} onClick={() => setStep(3)}>{T('Next ›', '다음 ›')}</button></>}>
        <Badge text={v.badge} />
        <p className="mb-2 text-[14px] font-semibold">{T(`${ok.length} of ${rows.length} set automatically ✓`, `${rows.length}회 중 ${ok.length}회 자동 배정 ✓`)}{bad > 0 && <span className="text-[#b3261e]"> · {T(`${bad} to adjust`, `${bad}회 조정 필요`)}</span>}</p>
        {top.length > 0 && <><p className="mt-2 text-[13.5px] font-bold text-[#55526a]">{T('Dates to adjust', '조정이 필요한 날짜')}</p><div className="rounded-[12px] bg-white px-3">{top.map(rowView)}</div></>}
        {ok.length > 0 && (
          <details className="mt-3"><summary className="min-h-[40px] cursor-pointer py-2 text-[13.5px] font-bold text-[#55526a]">{T(`Set automatically (${ok.length})`, `자동 배정된 회차 ${ok.length}회`)}</summary>
            <div className="rounded-[12px] bg-white px-3">{ok.map(rowView)}</div></details>
        )}
      </Frame>
    );
  }
  const dates = rows.filter((r) => picks[r.key] instanceof Date);
  const adm = rows.filter((r) => picks[r.key] === 'admin').length;
  const subs = rows.filter((r) => picks[r.key] === 'sub').length;
  return (
    <Frame title={title} sub={sub} steps={steps} onClose={onClose} busy={busy}
      foot={<><button type="button" className={btnSub} disabled={busy} onClick={() => setStep(2)}>‹ {T('Back', '이전')}</button>
        <button type="button" className={btnMain} disabled={busy} onClick={() => void submit()}>{busy ? T('Sending…', '확정 전에 다시 확인하고 있어요') : T('Submit agreed class times', `${chosen.length}회 신청하기`)}</button></>}>
      <Badge text={v.badge} />
      <div className="rounded-[12px] bg-white px-3">
        {dates.map((r) => (
          <div key={r.key} className={rowBox}>
            <p className="text-[12.5px] text-[#6b6880] line-through"><Rich text={v.when(r.orig)} /></p>
            <p className="text-[14.5px] font-bold"><Rich text={v.when(picks[r.key] as Date)} /></p>
          </div>
        ))}
      </div>
      {adm > 0 && <p className="mt-2 text-[14px]">{T(`${adm} classes: Edge English will arrange`, `${adm}회는 운영진이 시간을 정해요`)}</p>}
      {subs > 0 && <p className="mt-1 text-[14px]">{subs}회는 대체강사와 수업</p>}
      {later > 0 && <p className="mt-1 text-[14px]">{T(`${later} classes: choose later`, `${later}회는 나중에 고르기`)}</p>}
      {err && <p className="mt-2 text-[13.5px] text-[#b3261e]">{err}</p>}
    </Frame>
  );
}

/** 학생 확인 창: 선생님이 보낸 시간 → [이 일정에 동의하기] / [다시 조정하기] */
export function TtlReviewSheet({ item, actions, v, onClose, onDone, onPick }: { item: TtlItem; actions: TtlActions; v: TtlView; onClose: () => void; onDone: () => void; onPick: () => void }) {
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState('');
  const [res, setRes] = useState<{ r: TtlResult; agree: boolean } | null>(null);
  const rows = item.rows.filter((r) => r.state === 'proposed');
  const adm = rows.filter((r) => !r.newAt).length;
  async function answer(agree: boolean) {
    if (!actions.answer) return;
    setBusy(true); setErr('');
    try { setRes({ r: await actions.answer(item, agree), agree }); onDone(); } catch (e) { setErr((e as Error).message); } finally { setBusy(false); }
  }
  if (res) {
    return (
      <Frame title="선생님이 신청한 수업 시간" sub={v.who} onClose={onClose}
        foot={res.agree ? <button type="button" className={btnMain} onClick={onClose}>닫기</button>
          : <><button type="button" className={btnSub} onClick={onClose}>닫기</button><button type="button" className={btnMain} onClick={onPick}>직접 시간 고르기</button></>}>
        {res.agree ? <ResultBody r={res.r} v={v} /> : <p className="text-[17px] font-bold">다시 조정으로 바꿨어요</p>}
      </Frame>
    );
  }
  const from = rows[0]?.orig; const to = rows[rows.length - 1]?.orig;
  return (
    <Frame title="선생님이 신청한 수업 시간" sub={v.who} onClose={onClose} busy={busy}
      foot={<><button type="button" className={btnSub} disabled={busy} onClick={() => void answer(false)}>다시 조정하기</button>
        <button type="button" className={btnMain} disabled={busy} onClick={() => void answer(true)}>{busy ? '확정 전에 다시 확인하고 있어요' : '이 일정에 동의하기'}</button></>}>
      <Badge text={v.badge} />
      <div className="mb-3 rounded-[12px] bg-white p-3 text-[14px]">
        <p className="font-bold">변경되는 수업 {rows.length}회</p>
        {from && to && <p>기존 수업 {v.date(from)} ~ {v.date(to)}</p>}
        {adm > 0 && <p className="text-[#b3261e]">{adm}회는 운영진이 시간을 정해요</p>}
      </div>
      <div className="rounded-[12px] bg-white px-3">
        {rows.map((r) => (
          <div key={r.key} className={rowBox}>
            <p className="text-[12.5px] text-[#6b6880] line-through"><Rich text={v.when(r.orig)} /></p>
            <p className="text-[14.5px] font-bold">{r.newAt ? <Rich text={v.when(r.newAt)} /> : '운영진이 시간을 정해요'}</p>
          </div>
        ))}
      </div>
      {err && <p className="mt-2 text-[13.5px] text-[#b3261e]">{err}</p>}
    </Frame>
  );
}

export const ttlConflictText = (code: string | null, en: boolean) => (code && CONFLICT[code] ? CONFLICT[code][en ? 0 : 1] : '');
