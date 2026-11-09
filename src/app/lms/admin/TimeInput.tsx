'use client';

// 시각 입력칸: [오전|오후] + 시 + 분 (대표 2026-11-08 — 24시간 숫자 입력은 오전·오후를 헷갈려 사고가 남)
// 값은 예전과 같은 'HH:MM'(24시간) 또는 ''(아직 다 안 고름). 오전·오후·시·분을 모두 골라야 값이 생김
// 분은 5분 단위. 기존 값이 5분 단위가 아니면 그 분도 목록에 넣어 그대로 보이게

import { useEffect, useState } from 'react';

type Props = { value: string; onChange: (v: string) => void; id?: string; disabled?: boolean; className?: string; 'aria-label'?: string };
type Parts = { ap: 'am' | 'pm' | ''; h: string; m: string };

const HOURS = ['12', '1', '2', '3', '4', '5', '6', '7', '8', '9', '10', '11'];
const MINUTES = Array.from({ length: 12 }, (_, i) => String(i * 5).padStart(2, '0'));

function split(v: string): Parts {
  if (!/^\d\d:\d\d$/.test(v)) return { ap: '', h: '', m: '' };
  const h = Number(v.slice(0, 2));
  return { ap: h < 12 ? 'am' : 'pm', h: String(h % 12 === 0 ? 12 : h % 12), m: v.slice(3, 5) };
}
function join(p: Parts): string {
  if (!p.ap || !p.h || !p.m) return '';
  const h = (Number(p.h) % 12) + (p.ap === 'pm' ? 12 : 0);
  return `${String(h).padStart(2, '0')}:${p.m}`;
}

export default function TimeInput({ value, onChange, id, disabled, className, 'aria-label': label }: Props) {
  const [p, setP] = useState<Parts>(() => split(value));
  useEffect(() => {
    // 밖에서 값이 바뀌면 따라감. 고르는 중(아직 '')이면 고른 칸은 그대로 둠
    if (join(p) !== value && (value !== '' || join(p) !== '')) setP(split(value));
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [value]);
  const set = (q: Partial<Parts>) => {
    const n = { ...p, ...q };
    setP(n);
    onChange(join(n));
  };
  const minutes = p.m && !MINUTES.includes(p.m) ? [...MINUTES, p.m].sort() : MINUTES;
  // 넘겨받은 칸 모양(테두리·글자)은 쓰되 너비는 이 묶음이 정함 (예전 한 칸짜리 너비 지정이 셋에 똑같이 걸리지 않게)
  const sel = `${(className ?? '').replace(/(^|\s)(w-\S+|flex-1|min-w-0|text-center)(?=\s|$)/g, ' ')} w-full min-w-0 !px-1.5`;
  const ap = (k: 'am' | 'pm') =>
    `min-h-[44px] flex-1 px-2 text-[14.5px] font-semibold ${p.ap === k ? 'bg-[#7d5ffb] text-white' : 'bg-white text-[#1d1b2b]'} disabled:opacity-60`;
  return (
    <div id={id} role="group" aria-label={label} className={`grid min-w-0 grid-cols-[auto_1fr_1fr] gap-1 ${/(^|\s)flex-1(\s|$)/.test(className ?? '') ? 'flex-1' : ''}`}>
      <div className="flex overflow-hidden rounded-[10px] border border-[#e6e3ef]">
        <button type="button" disabled={disabled} aria-pressed={p.ap === 'am'} className={ap('am')} onClick={() => set({ ap: 'am' })}>오전</button>
        <button type="button" disabled={disabled} aria-pressed={p.ap === 'pm'} className={ap('pm')} onClick={() => set({ ap: 'pm' })}>오후</button>
      </div>
      <select aria-label={`${label ?? '시각'} 시`} disabled={disabled} value={p.h} onChange={(e) => set({ h: e.target.value })} className={sel}>
        <option value="">시</option>
        {HOURS.map((h) => <option key={h} value={h}>{h}시</option>)}
      </select>
      <select aria-label={`${label ?? '시각'} 분`} disabled={disabled} value={p.m} onChange={(e) => set({ m: e.target.value })} className={sel}>
        <option value="">분</option>
        {minutes.map((m) => <option key={m} value={m}>{m}분</option>)}
      </select>
    </div>
  );
}
