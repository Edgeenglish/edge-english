'use client';

// 신규 학생 등록 화면 조각: 입력 칸, 카드, 강사 고르기, 주간 캘린더 (2026-10-18 대표 최종 시안)

import { useMemo, useRef, useState } from 'react';
import { cellState, clashes, startsWithinAvailability, withinAvailability, type AvailabilityWindow, type CellState } from '@/lms/rules/booking';
import { addDays, formatInZone, instantToKstDate, kstToInstant, weekdayOf, type KstDate } from '@/lms/rules/dates';
import type { RegularSlot } from '@/lms/rules/schedule';
import { homepageProfile, type HomepageProfile } from '@/lms/admin/homepage-tutor';
import type { RegTutor, WishWindow } from '@/lms/admin/registration';
import { dayLabel, diffFromKst, localTime, upcomingOffsetChange, WEEKDAY_KO } from '@/lms/admin/schedule';
import { Icon } from '../../ui';

export const C = {
  ink: 'text-[#1d1b2b]',
  sub: 'text-[#6b6880]',
  line: 'border-[#e6e3ef]',
  primary: 'bg-[#7d5ffb] text-white',
};

export function Card({ title, badge, action, children, className = '' }: { title?: React.ReactNode; badge?: React.ReactNode; action?: React.ReactNode; children: React.ReactNode; className?: string }) {
  return (
    <section className={`rounded-[16px] border border-[#e6e3ef] bg-white p-4 lg:p-5 ${className}`}>
      {(title || badge || action) && (
        <div className="mb-3 flex items-center gap-2">
          {title && <h2 className="text-[16px] font-bold text-[#1d1b2b] lg:text-[17px]">{title}</h2>}
          {badge}
          <span className="flex-1" />
          {action}
        </div>
      )}
      {children}
    </section>
  );
}

export function Badge({ tone, children }: { tone: 'green' | 'purple' | 'amber' | 'red' | 'gray'; children: React.ReactNode }) {
  const t = {
    green: 'bg-[#e3f6ea] text-[#1e7a46]',
    purple: 'bg-[#efebff] text-[#5b3fe0]',
    amber: 'bg-[#fff1dc] text-[#9a5b00]',
    red: 'bg-[#fdecec] text-[#b3261e]',
    gray: 'bg-[#f1f0f5] text-[#6b6880]',
  }[tone];
  return <span className={`inline-flex items-center rounded-full px-2.5 py-1 text-[12px] font-semibold ${t}`}>{children}</span>;
}

export function Field({ label, children, wide = false, full = false, problem }: { label: string; children: React.ReactNode; wide?: boolean; full?: boolean; problem?: string }) {
  // wide: 늘 두 칸, full: 휴대폰에서만 두 칸(좁은 화면에서 이메일 등이 잘리지 않게)
  return (
    <label className={`block ${wide ? 'col-span-2' : full ? 'col-span-2 lg:col-span-1' : ''}`}>
      <span className="mb-1 block text-[13px] text-[#6b6880]">{label}</span>
      {children}
      {problem && <span className="mt-1 block text-[12px] text-[#b3261e]">{problem}</span>}
    </label>
  );
}

export const inputCls = (locked: boolean, bad = false) =>
  `min-h-[44px] w-full rounded-[10px] border px-3 text-[15px] text-[#1d1b2b] outline-none focus:border-[#7d5ffb] ${
    bad ? 'border-[#e8a39e]' : 'border-[#e6e3ef]'
  } ${locked ? 'bg-[#faf9fd]' : 'bg-white'}`;

/** 학생 희망 칸 → 판정용 창 (학생 시간대 기준이라 서머타임 자동) */
// 칸 안에서 바로 검색해서 고르기 (사는 곳 A안). 목록에 없으면 onFree 로 친 그대로 저장 (없으면 목록에서만)
export type PickItem = { key: string; main: string; sub?: string; pick: () => void };
export function SearchPick({ value, placeholder, locked = false, bad = false, search, onFree }: { value: string; placeholder: string; locked?: boolean; bad?: boolean; search: (q: string) => { label?: string; items: PickItem[] }[]; onFree?: (text: string) => void }) {
  const [open, setOpen] = useState(false);
  const [q, setQ] = useState('');
  const typed = useRef(''); // 칸을 떠날 때 친 글자 (고른 뒤에는 비움 → 친 글자로 덮어쓰지 않음)
  const input = useRef<HTMLInputElement>(null);
  const groups = open ? search(q) : [];
  const first = groups.flatMap((g) => g.items)[0];
  const text = q.trim();
  const type = (v: string) => {
    typed.current = v;
    setQ(v);
  };
  const close = (free: boolean) => {
    if (free && typed.current.trim() && onFree) onFree(typed.current.trim());
    typed.current = '';
    setOpen(false);
    setQ('');
  };
  const choose = (it: PickItem) => {
    it.pick();
    typed.current = '';
    input.current?.blur();
    close(false);
  };
  return (
    <div className="relative">
      <input
        ref={input}
        readOnly={locked}
        value={open ? q : value}
        placeholder={placeholder}
        autoComplete="off"
        onFocus={(e) => {
          if (locked) return;
          setOpen(true);
          type('');
          // 휴대폰: 키보드가 올라와도 목록이 보이게 칸을 위로
          const el = e.currentTarget;
          setTimeout(() => el.scrollIntoView({ block: 'start', behavior: 'smooth' }), 250);
        }}
        onChange={(e) => type(e.target.value)}
        onBlur={() => setTimeout(() => close(true), 150)} // 휴대폰에서 목록을 누르는 사이 칸이 먼저 닫히지 않게
        onKeyDown={(e) => {
          if (e.key === 'Enter' && !e.nativeEvent.isComposing) {
            e.preventDefault();
            if (first) choose(first);
            else input.current?.blur();
          }
          if (e.key === 'Escape') {
            typed.current = '';
            input.current?.blur();
          }
        }}
        className={`${inputCls(locked, bad)} scroll-mt-24`}
      />
      {open && (
        <div className="absolute left-0 right-0 top-[calc(100%+4px)] z-20 max-h-[260px] overflow-y-auto rounded-[12px] border border-[#e6e3ef] bg-white p-1 shadow-[0_8px_24px_rgba(0,0,0,.12)]">
          {groups.map((g, i) => (
            <div key={i}>
              {g.label && g.items.length > 0 && <p className="px-2.5 pb-0.5 pt-1.5 text-[12px] text-[#6b6880]">{g.label}</p>}
              {g.items.map((it) => (
                <button key={it.key} type="button" onMouseDown={(e) => e.preventDefault()} onClick={() => choose(it)} className="block min-h-[44px] w-full rounded-[8px] px-2.5 py-2 text-left text-[14.5px] text-[#1d1b2b] hover:bg-[#efebff]">
                  {it.main}
                  {it.sub && <span className="block text-[12.5px] text-[#6b6880]">{it.sub}</span>}
                </button>
              ))}
            </div>
          ))}
          {text && onFree && (
            <button type="button" onMouseDown={(e) => e.preventDefault()} onClick={() => input.current?.blur()} className="block min-h-[44px] w-full rounded-[8px] px-2.5 py-2 text-left text-[14.5px] font-semibold text-[#5b3fe0] hover:bg-[#efebff]">
              ‘{text}’ 그대로 쓰기
            </button>
          )}
          {!first && !(text && onFree) && <p className="px-2.5 py-2 text-[13px] text-[#6b6880]">찾는 곳이 없어요. 가까운 큰 도시 이름이나 영어로 쳐 보세요.</p>}
        </div>
      )}
    </div>
  );
}

export function wishWindows(w: readonly WishWindow[], timezone: string): AvailabilityWindow[] {
  return w.map((x) => ({ weekday: x.weekday, startLocal: x.from, endLocal: x.to, timezone: timezone || 'Asia/Seoul', effectiveFrom: '2000-01-01', effectiveTo: null }));
}

const STEP = 30;
const times = Array.from({ length: 48 }, (_, i) => `${String(Math.floor(i / 2)).padStart(2, '0')}:${i % 2 ? '30' : '00'}`);

/** 강사가 이 칸에서 수업을 시작할 수 있는지 (가능 시간 안 + 다른 수업·휴식 10분·휴무와 안 부딪힘) — 그 날짜 하나만 */
export function canStartAt(t: RegTutor, date: KstDate, time: string, durationMin: number): boolean {
  const s = kstToInstant(date, time);
  const e = new Date(s.getTime() + durationMin * 60000);
  return startsWithinAvailability(s, t.availability) && clashes(s, e, t.busy).length === 0;
}

/** 이번 주에 학생 희망 시간과 맞는 시작 칸 수 (희망 시간이 없으면 가능한 시작 칸 수) */
export function matchCount(t: RegTutor, week: KstDate[], durationMin: number, wish: AvailabilityWindow[]): number {
  let n = 0;
  for (const d of week)
    for (const time of times) {
      const s = kstToInstant(d, time);
      if (wish.length && !withinAvailability(s, new Date(s.getTime() + durationMin * 60000), wish)) continue;
      if (canStartAt(t, d, time, durationMin)) n++;
    }
  return n;
}

const BANDS = [
  { key: 'morning', label: '오전 (6–12시)', from: 6, to: 12 },
  { key: 'afternoon', label: '오후 (12–18시)', from: 12, to: 18 },
  { key: 'evening', label: '저녁 (18–22시)', from: 18, to: 22 },
  { key: 'night', label: '밤 (22–24시)', from: 22, to: 24 },
] as const;

export type TutorFilter = { q: string; country: string; weekday: string; band: string };
export const EMPTY_FILTER: TutorFilter = { q: '', country: '', weekday: '', band: '' };

function passesFilter(t: RegTutor, f: TutorFilter, week: KstDate[], durationMin: number): boolean {
  if (f.q && !t.name.toLowerCase().includes(f.q.trim().toLowerCase())) return false;
  if (f.country && t.country !== f.country) return false;
  if (!f.weekday && !f.band) return true;
  const band = BANDS.find((b) => b.key === f.band);
  return week.some(
    (d) =>
      (!f.weekday || weekdayOf(d) === Number(f.weekday)) &&
      times.some((time) => {
        const h = Number(time.slice(0, 2));
        return (!band || (h >= band.from && h < band.to)) && canStartAt(t, d, time, durationMin);
      }),
  );
}

const flag = (country: string) =>
  /호주|australia/i.test(country) ? '🇦🇺' : /캐나다|canada/i.test(country) ? '🇨🇦' : /미국|usa|united states/i.test(country) ? '🇺🇸' : /영국|uk|united kingdom/i.test(country) ? '🇬🇧' : /한국|korea/i.test(country) ? '🇰🇷' : '';

export function TutorPicker({
  tutors,
  selectedId,
  onSelect,
  week,
  durationMin,
  wish,
  filter,
  setFilter,
  onProfile,
}: {
  tutors: RegTutor[];
  selectedId: string | null;
  onSelect: (id: string) => void;
  week: KstDate[];
  durationMin: number;
  wish: AvailabilityWindow[];
  filter: TutorFilter;
  setFilter: (f: TutorFilter) => void;
  onProfile: (t: RegTutor) => void;
}) {
  const countries = [...new Set(tutors.map((t) => t.country))].sort();
  const rows = useMemo(
    () =>
      tutors
        .filter((t) => passesFilter(t, filter, week, durationMin))
        .map((t) => ({ t, n: matchCount(t, week, durationMin, wish) }))
        .sort((a, b) => b.n - a.n || a.t.name.localeCompare(b.t.name)),
    [tutors, filter, week, durationMin, wish],
  );
  const sel = 'min-h-[42px] rounded-[10px] border border-[#e6e3ef] bg-white px-2.5 text-[14px] text-[#1d1b2b]';
  return (
    <div>
      <div className="grid grid-cols-2 gap-2 lg:flex lg:flex-wrap">
        <label className="col-span-2 flex min-h-[42px] items-center gap-2 rounded-[10px] border border-[#e6e3ef] bg-white px-3 lg:min-w-[220px] lg:flex-1">
          <Icon name="search" className="h-[18px] w-[18px] text-[#9a97ad]" />
          <input value={filter.q} onChange={(e) => setFilter({ ...filter, q: e.target.value })} placeholder="강사 이름 검색" className="w-full bg-transparent text-[14px] text-[#1d1b2b] outline-none" />
        </label>
        <select aria-label="국적" value={filter.country} onChange={(e) => setFilter({ ...filter, country: e.target.value })} className={sel}>
          <option value="">국적 전체</option>
          {countries.map((c) => (
            <option key={c} value={c}>
              {c}
            </option>
          ))}
        </select>
        <select aria-label="가능 요일" value={filter.weekday} onChange={(e) => setFilter({ ...filter, weekday: e.target.value })} className={sel}>
          <option value="">가능 요일</option>
          {[1, 2, 3, 4, 5, 6, 0].map((d) => (
            <option key={d} value={d}>
              {WEEKDAY_KO[d]}요일
            </option>
          ))}
        </select>
        <select aria-label="가능 시간" value={filter.band} onChange={(e) => setFilter({ ...filter, band: e.target.value })} className={sel}>
          <option value="">가능 시간 (한국)</option>
          {BANDS.map((b) => (
            <option key={b.key} value={b.key}>
              {b.label}
            </option>
          ))}
        </select>
        <button type="button" onClick={() => setFilter(EMPTY_FILTER)} className={`${sel} font-semibold`}>
          필터 초기화
        </button>
      </div>
      <p className="mt-2 text-[12.5px] text-[#6b6880]">{wish.length ? '학생 희망 시간에 이번 주 바로 시작할 수 있는 칸이 많은 강사부터 보여요.' : '희망 시간이 칸으로 들어오지 않아 이번 주 가능한 칸이 많은 순서예요.'}</p>
      <div className="-mx-4 mt-3 flex snap-x scroll-px-4 gap-2.5 overflow-x-auto px-4 pb-1 lg:mx-0 lg:grid lg:grid-cols-3 lg:overflow-visible lg:px-0 xl:grid-cols-4">
        {rows.length === 0 && <p className="py-6 text-[14px] text-[#6b6880]">조건에 맞는 강사가 없어요.</p>}
        {rows.map(({ t, n }) => {
          const on = t.id === selectedId;
          return (
            <div key={t.id} className={`relative w-[72%] min-w-[220px] shrink-0 snap-start rounded-[14px] border bg-white p-3 lg:w-auto lg:min-w-0 ${on ? 'border-[#7d5ffb] shadow-[0_0_0_2px_#e4ddff]' : 'border-[#e6e3ef]'}`}>
              <button type="button" aria-pressed={on} onClick={() => onSelect(t.id)} className="flex w-full items-center gap-3 text-left">
                <span className={`flex h-5 w-5 shrink-0 items-center justify-center rounded-full border-2 ${on ? 'border-[#7d5ffb] bg-[#7d5ffb]' : 'border-[#cfcbe0]'}`}>
                  {on && <span className="h-2 w-2 rounded-full bg-white" />}
                </span>
                <span className="flex h-11 w-11 shrink-0 items-center justify-center rounded-full bg-[#efebff] text-[17px] font-bold text-[#5b3fe0]">{t.name.slice(0, 1)}</span>
                <span className="min-w-0">
                  <b className="block text-[15px] text-[#1d1b2b]">{t.name}</b>
                  <span className="block text-[12.5px] text-[#6b6880]">
                    {flag(t.country)} {t.country}
                  </span>
                </span>
              </button>
              <div className="mt-2 flex items-center gap-2">
                <Badge tone={n > 0 ? 'purple' : 'gray'}>{wish.length ? `희망 시간 가능 ${n}칸` : `이번 주 가능 ${n}칸`}</Badge>
                <span className="flex-1" />
                <button type="button" onClick={() => onProfile(t)} className="text-[12.5px] font-semibold text-[#5b3fe0]">
                  소개
                </button>
              </div>
            </div>
          );
        })}
      </div>
    </div>
  );
}

const CELL: Record<CellState, { cls: string; text: string }> = {
  available: { cls: 'bg-[#efebff] text-[#5b3fe0]', text: '가능' },
  makeup: { cls: 'bg-[#fff1dc] text-[#9a5b00]', text: '보강' },
  regular: { cls: 'bg-[#7d5ffb] text-white', text: '정규 수업' },
  off: { cls: 'bg-[#e9e8ee] text-[#6b6880]', text: '휴무' },
  unavailable: { cls: 'bg-[#f6f5f9] text-[#b5b2c4]', text: '-' },
};

export function Legend() {
  const item = (cls: string, label: string) => (
    <span className="inline-flex items-center gap-1.5 text-[12.5px] text-[#6b6880]">
      <span className={`h-3.5 w-3.5 rounded-[4px] ${cls}`} />
      {label}
    </span>
  );
  return (
    <div className="flex flex-wrap gap-x-3 gap-y-1">
      {item('bg-[#efebff]', '가능')}
      {item('bg-[#f7f5ff] border border-[#e4ddff]', '시작 불가 (길이·휴식 부족)')}
      {item('bg-[#fff1dc]', '보강 있음 (그날만)')}
      {item('bg-[#7d5ffb]', '정규 수업 있음')}
      {item('bg-[#e9e8ee]', '휴무')}
      {item('bg-[#f6f5f9] border border-[#e6e3ef]', '불가')}
      {item('border-2 border-dashed border-[#f0a23a] bg-white', '학생 희망')}
    </div>
  );
}

export function WeekCalendar({
  tutor,
  week,
  today,
  slots,
  onToggle,
  wish,
  studentTz,
  durationMin,
  onWeek,
}: {
  tutor: RegTutor;
  week: KstDate[];
  today: KstDate;
  slots: RegularSlot[];
  onToggle: (date: KstDate, time: string, state: CellState) => void;
  wish: AvailabilityWindow[];
  studentTz: string;
  durationMin: number;
  onWeek: (monday: KstDate) => void;
}) {
  const [showLocal, setShowLocal] = useState(false);
  const grid = useMemo(() => week.map((d) => times.map((t) => cellState(d, t, STEP, tutor.busy, tutor.availability))), [week, tutor]);
  // 보여 줄 시간 범위: 이번 주에 가능·수업·휴무가 있는 칸 + 고른 시간 (없으면 18–22시)
  const used = times.map((t, i) => grid.some((col) => col[i].state !== 'unavailable') || slots.some((s) => s.time === t));
  let first = used.indexOf(true);
  let last = used.lastIndexOf(true);
  if (first < 0) [first, last] = [36, 43];
  const rowIdx = Array.from({ length: last - first + 1 }, (_, i) => first + i);
  const dst = [tutor.timezone, studentTz]
    .filter((z, i, a) => z && z !== 'Asia/Seoul' && a.indexOf(z) === i)
    .map((z) => ({ z, c: upcomingOffsetChange(kstToInstant(week[0], '00:00'), z, 21) }))
    .filter((x) => x.c);
  return (
    <div>
      <div className="flex flex-wrap items-center gap-2">
        <button type="button" aria-label="이전 주" onClick={() => onWeek(addDays(week[0], -7))} className="flex h-10 w-10 items-center justify-center rounded-[10px] border border-[#e6e3ef] bg-white text-[#1d1b2b]">
          <Icon name="chevron" className="h-4 w-4 rotate-180" />
        </button>
        <b className="min-w-[150px] text-center text-[15px] text-[#1d1b2b]">
          {dayLabel(week[0])} – {dayLabel(week[6])}
        </b>
        <button type="button" aria-label="다음 주" onClick={() => onWeek(addDays(week[0], 7))} className="flex h-10 w-10 items-center justify-center rounded-[10px] border border-[#e6e3ef] bg-white text-[#1d1b2b]">
          <Icon name="chevron" className="h-4 w-4" />
        </button>
        <button type="button" onClick={() => onWeek(today)} className="min-h-[40px] rounded-[10px] border border-[#e6e3ef] bg-white px-3 text-[14px] text-[#1d1b2b]">
          오늘
        </button>
        <span className="flex-1" />
        <label className="flex min-h-[40px] items-center gap-2 text-[13px] text-[#1d1b2b]">
          <input type="checkbox" checked={showLocal} onChange={(e) => setShowLocal(e.target.checked)} className="h-4 w-4 accent-[#7d5ffb]" />
          {tutor.name} 현지 시각 함께
        </label>
      </div>
      <p className="mt-1 text-[12.5px] text-[#6b6880]">
        한국 시간(KST) 기준 · {tutor.name}({tutor.country}) {diffFromKst(kstToInstant(week[3], '12:00'), tutor.timezone)} · 칸은 30분 단위 표시이고, 실제 가능 여부는 수업 길이 + 휴식 10분으로 따로 판정해요.
      </p>
      {dst.map(({ z, c }) => (
        <p key={z} className="mt-2 rounded-[10px] bg-[#fff6e6] px-3 py-2 text-[13px] text-[#7a4a00]">
          {z === tutor.timezone ? `${tutor.name}(${tutor.country})` : `학생(${z})`} {dayLabel(c!.on)} {c!.label} ({c!.from} → {c!.to}). 그날부터 한국 시각 칸이 자동으로 1시간 옮겨져요.
        </p>
      ))}
      <div className="-mx-4 mt-3 overflow-x-auto px-4 lg:mx-0 lg:px-0">
        <table className="w-full min-w-[560px] border-separate border-spacing-[3px] text-center">
          <thead>
            <tr>
              <th className="sticky left-0 z-[1] w-[52px] bg-white" />
              {week.map((d) => (
                <th key={d} className={`py-1.5 text-[12.5px] font-semibold ${d === today ? 'text-[#5b3fe0]' : 'text-[#1d1b2b]'}`}>
                  {dayLabel(d)}
                </th>
              ))}
            </tr>
          </thead>
          <tbody>
            {rowIdx.map((i) => (
              <tr key={times[i]}>
                <td className="sticky left-0 z-[1] bg-white pr-1 text-right text-[12px] text-[#6b6880]">{times[i]}</td>
                {week.map((d, j) => {
                  const c = grid[j][i];
                  const picked = slots.some((s) => s.weekday === weekdayOf(d) && s.time === times[i]);
                  const s = kstToInstant(d, times[i]);
                  const wished = wish.length > 0 && withinAvailability(s, new Date(s.getTime() + durationMin * 60000), wish);
                  const past = d < today;
                  // 30분 칸은 비어 있어도 고른 수업 길이 + 휴식 10분이 안 되면 여기서 시작할 수 없음 (표시와 판정을 따로)
                  const tight = c.state === 'available' && !canStartAt(tutor, d, times[i], durationMin);
                  const look = picked ? 'bg-[#5b3fe0] text-white' : tight ? 'bg-[#f7f5ff] text-[#b3a8e8]' : CELL[c.state].cls;
                  return (
                    <td key={d} className="p-0">
                      <button
                        type="button"
                        disabled={past || c.state === 'regular' || c.state === 'unavailable' || (tight && !picked)}
                        onClick={() => onToggle(d, times[i], c.state)}
                        title={tight ? `${durationMin}분 수업 + 휴식 10분이 안 돼요 (다음 수업 또는 가능 시간 끝)` : c.busy?.label}
                        className={`flex h-[38px] w-full flex-col items-center justify-center rounded-[7px] text-[12px] font-semibold leading-tight ${look} ${wished && !picked ? 'outline-dashed outline-2 -outline-offset-2 outline-[#f0a23a]' : ''} ${past ? 'opacity-50' : ''}`}
                      >
                        <span className="text-inherit">{picked ? '✓ 선택' : tight ? '시작 불가' : c.state === 'makeup' ? '보강 1건' : CELL[c.state].text}</span>
                        {showLocal && c.state !== 'unavailable' && <span className="text-[10.5px] font-normal opacity-80">{formatInZone(s, tutor.timezone).time}</span>}
                      </button>
                    </td>
                  );
                })}
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </div>
  );
}

export function slotText(s: RegularSlot) {
  return `${WEEKDAY_KO[s.weekday]} ${s.time}`;
}

/** 고른 정규 시간을 강사·학생 현지 시각으로 (첫 수업 날짜 기준 — 서머타임이면 날짜마다 달라질 수 있음) */
export function slotLocal(s: RegularSlot, first: KstDate, tz: string) {
  let d = first;
  while (weekdayOf(d) !== s.weekday) d = addDays(d, 1);
  return localTime(kstToInstant(d, s.time), tz);
}

export function ProfileSheet({ tutor, onClose }: { tutor: RegTutor; onClose: () => void }) {
  const p: HomepageProfile | null = homepageProfile(tutor.name);
  return (
    <div role="dialog" aria-modal="true" aria-label={`${tutor.name} 소개`} className="fixed inset-0 z-30 flex items-end justify-center bg-black/40 lg:items-center" onClick={onClose}>
      <div className="max-h-[85vh] w-full max-w-[520px] overflow-y-auto rounded-t-[18px] bg-white p-5 lg:rounded-[18px]" onClick={(e) => e.stopPropagation()}>
        <div className="flex items-center gap-2">
          <b className="text-[17px] text-[#1d1b2b]">{tutor.name}</b>
          <span className="text-[13px] text-[#6b6880]">
            {tutor.country} · {tutor.timezone} · 지금 {formatInZone(new Date(), tutor.timezone).time}
          </span>
          <span className="flex-1" />
          <button type="button" onClick={onClose} aria-label="닫기" className="h-10 w-10 text-[20px] text-[#6b6880]">
            ×
          </button>
        </div>
        {p ? (
          <div className="mt-3 space-y-3 text-[14px] leading-relaxed text-[#1d1b2b]">
            {/* 홈페이지에 이미 공개된 사진·소개만 */}
            <img src={p.img} alt="" className="h-40 w-full rounded-[12px] object-cover" />
            <p className="whitespace-pre-line font-semibold">{p.desc}</p>
            <div className="flex flex-wrap gap-1.5">
              {p.tags.map((t) => (
                <Badge key={t} tone="purple">
                  {t}
                </Badge>
              ))}
            </div>
            {p.career && <p className="text-[#6b6880]">경력: {p.career}</p>}
            <p className="whitespace-pre-line">{p.intro}</p>
            <a href="/tutors" target="_blank" rel="noreferrer" className="inline-block font-semibold text-[#5b3fe0]">
              홈페이지 강사 소개 열기 ›
            </a>
          </div>
        ) : (
          <p className="mt-3 text-[14px] text-[#6b6880]">홈페이지 강사 소개에 같은 이름이 없어요. (홈페이지 이름의 영문 부분과 LMS 강사 이름이 같으면 여기서 보여요.)</p>
        )}
      </div>
    </div>
  );
}

export const nowLocal = (tz: string, now: Date) => `${instantToKstDate(now) === formatInZone(now, tz).date ? '' : `${formatInZone(now, tz).date.slice(5).replace('-', '/')} `}${formatInZone(now, tz).time}`;
