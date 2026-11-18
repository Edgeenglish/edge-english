'use client';
/*
 * 운영자 홈 할 일 '정규 시간 변경 신청' (H26(208), 보충 7: 1·2순위 = 일정 전체): 1·2순위 중 골라 [확정] / [반려].
 * [확정] 순간 DB 가 [정규 일정 수정]과 같은 충돌 검사를 다시 돌림 — 막히면 저장 안 하고 사유·다음 가능한 주를 그 자리에 보여 줌.
 * 시각은 모두 한국 시간.
 */
import { useState } from 'react';

type Problem = { date: string; time: string; why: string; other?: string | null };
export type DecideResult = { ok: boolean; why?: 'passed' | 'problems'; week?: string; shifted_to?: string | null; problems?: Problem[] };

const WHY: Record<string, string> = {
  tutor_hours_range: '강사 현지 오전 6:00~오후 10:30 밖',
  tutor_unavailable: '강사 가능 시간 아님',
  tutor_time_off: '강사 휴무',
  tutor_busy: '강사 다른 수업과 겹침',
  tutor_hold: '재등록 대기 자리와 겹침',
  after_end: '수강 종료일 뒤',
};
const md = (d: string) => `${Number(d.slice(5, 7))}/${Number(d.slice(8, 10))}`;
const wd = (d: string) => '일월화수목금토'[new Date(`${d.slice(0, 10)}T00:00:00Z`).getUTCDay()];
const hm = (t: string) => { const h = Number(t.slice(0, 2)); return `${h < 12 ? '오전' : '오후'} ${h % 12 === 0 ? 12 : h % 12}:${t.slice(3, 5)}`; };
const weekText = (w: string) => `${md(w)}(월) 주부터`;

const btn = 'min-h-[40px] rounded-[10px] border px-3 text-[14px] font-semibold disabled:opacity-40';
const PRI = `${btn} border-[#5b3df0] bg-[#5b3df0] text-white`;
const SEC = `${btn} border-[#5b3df0] bg-white text-[#5b3df0]`;
const GRAY = `${btn} border-[#e6e3ef] bg-[#ecebf1] text-[#55526a]`;

export default function RegularChangeDecide({ view, busy, decide }: {
  view: { items: { c: ({ text: string; week: string } | null)[] }[] };
  busy: boolean;
  /** 저장·다시 읽기는 부모가. 확정이 막혔을 때만 결과를 돌려받아 그 자리에 보여 줌 */
  decide: (action: 'confirm' | 'reject', choice: number[] | null, week: string | null) => Promise<DecideResult | null>;
}) {
  const single = view.items.length === 1;
  const [choice, setChoice] = useState<number[]>(view.items.map(() => 1));
  const [res, setRes] = useState<{ choice: number[]; r: DecideResult } | null>(null);
  const go = async (c: number[], week: string | null = null) => {
    const r = await decide('confirm', c, week);
    setRes(r && !r.ok ? { choice: c, r } : null);
  };
  const blocked = res && (
    <div className="grid gap-1.5">
      {res.r.why === 'passed' && <p className="text-[13.5px] font-bold text-[#b3261e]">{res.r.week ? `${md(res.r.week)}(월) 주` : '그 주'} 첫 수업이 이미 지났어요</p>}
      {res.r.why === 'problems' && (res.r.problems ?? []).map((p, i) => (
        <p key={i} className="text-[13.5px] font-bold text-[#b3261e]">확정할 수 없어요: {md(p.date)}({wd(p.date)}) {hm(p.time)} 한국 시간 — {WHY[p.why] ?? p.why}{p.other ? ` (${p.other})` : ''}</p>
      ))}
      {res.r.shifted_to
        ? <button type="button" disabled={busy} className={`${PRI} justify-self-start`} onClick={() => go(res.choice, res.r.shifted_to!)}>
            {single ? `${res.choice[0]}순위로 ` : ''}{weekText(res.r.shifted_to)} 확정
          </button>
        : <p className="text-[13.5px] text-[#55526a]">수강 종료일 안에 가능한 주가 없어요</p>}
    </div>
  );
  return (
    <div className="grid gap-2">
      {view.items.map((it, i) => (
        <div key={i} className="grid gap-1">
          {it.c.map((c, k) => c && (
            single ? (
              <p key={k} className="flex justify-between gap-2 rounded-[10px] bg-[#efebff] px-3 py-2 text-[14px]">
                <span>{k + 1}순위 · {c.text}</span><b className="shrink-0 text-[#5b3df0]">{weekText(c.week)}</b>
              </p>
            ) : (
              <button key={k} type="button" aria-pressed={choice[i] === k + 1} onClick={() => setChoice((x) => x.map((v, j) => (j === i ? k + 1 : v)))}
                className={`flex justify-between gap-2 rounded-[10px] border px-3 py-2 text-left text-[14px] ${choice[i] === k + 1 ? 'border-[#5b3df0] bg-[#efebff]' : 'border-[#e6e3ef] bg-white'}`}>
                <span>{k + 1}순위 · {c.text}</span><b className="shrink-0 text-[#5b3df0]">{weekText(c.week)}</b>
              </button>
            )
          ))}
        </div>
      ))}
      <div className="flex flex-wrap gap-1.5">
        {single
          ? view.items[0].c.map((c, k) => c && (
              <button key={k} type="button" disabled={busy} className={k === 0 ? PRI : SEC} onClick={() => go([k + 1])}>{k + 1}순위로 확정</button>
            ))
          : <button type="button" disabled={busy} className={PRI} onClick={() => go(choice)}>확정</button>}
        <button type="button" disabled={busy} className={GRAY}
          onClick={() => { if (window.confirm('이 신청을 반려할까요?')) void decide('reject', null, null); }}>반려</button>
      </div>
      {blocked}
    </div>
  );
}
