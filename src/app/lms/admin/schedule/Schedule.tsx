'use client';

// 이번 주(월~일) 전체 수업 — PC: 7일 칸 / 휴대폰: 요일 고르기 + 그날 목록
// 강사를 고르면 그 강사의 현지 시각을 크게 보여 줌. 현지 시각은 IANA 시간대로 계산 → 서머타임 자동 반영

import Link from 'next/link';
import { useMemo, useState } from 'react';
import { addDays, formatInZone, instantToKstDate } from '@/lms/rules/dates';
import { fakeDirectory } from '@/lms/admin/fake-directory';
import { dayLabel, diffFromKst, localTime, upcomingOffsetChange, weekOf } from '@/lms/admin/schedule';
import { AdminHeader, BottomNav, Icon } from '../ui';

const STATE_STYLE = {
  done: 'bg-[#eeedf3] text-[#6b6880]',
  scheduled: 'bg-[#efebff] text-[#5b3fe0]',
  canceled: 'bg-[#fff1d6] text-[#a35b00]',
} as const;
const STATE_LABEL = { done: '완료', scheduled: '예정', canceled: '취소' } as const;

export default function Schedule({ nowIso }: { nowIso: string }) {
  const now = useMemo(() => new Date(nowIso), [nowIso]);
  const today = instantToKstDate(now);
  const [weekShift, setWeekShift] = useState(0);
  const [tutorId, setTutorId] = useState<string | 'all'>('all');
  const [day, setDay] = useState(today);
  const base = useMemo(() => fakeDirectory(now), [now]);
  const week = weekOf(addDays(today, weekShift * 7));
  const lessons = base.lessons.filter((l) => week.includes(instantToKstDate(l.startsAt)));
  const shown = lessons.filter((l) => tutorId === 'all' || l.tutorId === tutorId);
  const tutor = base.tutors.find((t) => t.id === tutorId) ?? null;
  const selDay = week.includes(day) ? day : week[0];
  const studentName = (code: string) => base.students.find((s) => s.code === code)?.name ?? code;
  const tutorOf = (id: string) => base.tutors.find((t) => t.id === id)!;
  const changes = base.tutors
    .filter((t) => tutorId === 'all' || t.id === tutorId)
    .map((t) => ({ t, c: upcomingOffsetChange(new Date(`${week[0]}T00:00:00+09:00`), t.timezone, 14) }))
    .filter((x) => x.c);

  const card = (l: (typeof lessons)[number]) => {
    const t = tutorOf(l.tutorId);
    const k = formatInZone(l.startsAt, 'Asia/Seoul');
    return (
      <Link
        key={l.id}
        href={`/lms/admin/students/${l.studentCode}?demo=1`}
        className={`grid gap-0.5 rounded-[10px] border px-2.5 py-2 ${l.state === 'canceled' ? 'border-dashed border-[#e0cf8a] bg-[#fffaf0]' : 'border-[#e6e3ef] bg-white'}`}
      >
        <span className="flex items-center justify-between gap-1">
          <b className={`text-[14px] tabular-nums ${tutor ? 'text-[#6b6880]' : 'text-[#1d1b2b]'}`}>{k.time}</b>
          <span className={`rounded-full px-1.5 py-0.5 text-[10.5px] font-bold ${STATE_STYLE[l.state]}`}>{l.kind === 'makeup' ? '보강' : STATE_LABEL[l.state]}</span>
        </span>
        {tutor && (
          <span className="text-[14px] font-bold tabular-nums text-[#1d1b2b]">
            현지 {localTime(l.startsAt, t.timezone)}
          </span>
        )}
        <span className="truncate text-[12.5px] text-[#1d1b2b]">{studentName(l.studentCode)}</span>
        <span className="truncate text-[11.5px] text-[#6b6880]">
          {t.name}
          {!tutor && ` · 현지 ${localTime(l.startsAt, t.timezone)}`} · {l.minutes}분
        </span>
      </Link>
    );
  };

  return (
    <div className="mx-auto min-h-dvh max-w-[1280px] pb-24 lg:pb-8">
      <AdminHeader active="schedule" demo right={<span className="text-[13px] text-[#6b6880]">한국 시간 기준</span>} />
      <p className="mx-4 mt-3 rounded-[10px] bg-[#fff8d6] px-3 py-2 text-[13px] text-[#5c4a00] lg:mx-7">가상 데이터 미리보기예요.</p>

      <div className="grid gap-3 px-4 pt-3 lg:px-7">
        <div className="flex flex-wrap items-center gap-2">
          <button type="button" onClick={() => setWeekShift((w) => w - 1)} aria-label="이전 주" className="flex h-9 w-9 items-center justify-center rounded-[10px] border border-[#e6e3ef] bg-white">
            <Icon name="chevron" className="h-4 w-4 rotate-180" />
          </button>
          <h1 className="text-[17px] font-bold text-[#1d1b2b]">
            {weekShift === 0 ? '이번 주' : weekShift === 1 ? '다음 주' : weekShift === -1 ? '지난주' : ''} {dayLabel(week[0])} – {dayLabel(week[6])}
          </h1>
          <button type="button" onClick={() => setWeekShift((w) => w + 1)} aria-label="다음 주" className="flex h-9 w-9 items-center justify-center rounded-[10px] border border-[#e6e3ef] bg-white">
            <Icon name="chevron" className="h-4 w-4" />
          </button>
          <span className="ml-auto text-[13px] text-[#6b6880]">수업 {shown.filter((l) => l.state !== 'canceled').length}개</span>
        </div>

        <div role="group" aria-label="강사" className="flex gap-1.5 overflow-x-auto pb-1">
          <button type="button" aria-pressed={tutorId === 'all'} onClick={() => setTutorId('all')} className={`shrink-0 rounded-full border px-3 py-1.5 text-[13px] font-semibold ${tutorId === 'all' ? 'border-[#1d1b2b] bg-[#1d1b2b] text-white' : 'border-[#e6e3ef] bg-white text-[#1d1b2b]'}`}>
            전체 강사
          </button>
          {base.tutors.map((t) => (
            <button
              key={t.id}
              type="button"
              aria-pressed={tutorId === t.id}
              onClick={() => setTutorId(t.id)}
              className={`shrink-0 rounded-full border px-3 py-1.5 text-left text-[13px] ${tutorId === t.id ? 'border-[#1d1b2b] bg-[#1d1b2b] text-white' : 'border-[#e6e3ef] bg-white text-[#1d1b2b]'}`}
            >
              <b className={tutorId === t.id ? 'text-white' : 'text-[#1d1b2b]'}>{t.name}</b> <span className={tutorId === t.id ? 'text-[#d8d3f5]' : 'text-[#6b6880]'}>· {t.country} · {diffFromKst(now, t.timezone)}</span>
            </button>
          ))}
        </div>

        {changes.map(({ t, c }) => (
          <p key={t.id} className="flex items-start gap-2 rounded-[10px] bg-[#fff1d6] px-3 py-2 text-[13px] leading-relaxed text-[#8a5300]">
            <Icon name="clock" className="mt-0.5 h-4 w-4 shrink-0" />
            <span>
              <b>{t.name}</b>({t.country}) {dayLabel(c!.on)} {c!.label} → 그날부터 {diffFromKst(new Date(`${c!.on}T12:00:00Z`), t.timezone)}. 시간표의 현지 시각은 자동으로 바뀌어요. 한국 시각 수업이 강사 현지에서 1시간 당겨지거나 늦어지니 강사 확인이 필요할 수 있어요.
            </span>
          </p>
        ))}

        {/* 휴대폰: 요일 고르기 */}
        <div role="tablist" aria-label="요일" className="grid grid-cols-7 gap-1 lg:hidden">
          {week.map((d) => (
            <button
              key={d}
              type="button"
              role="tab"
              aria-selected={selDay === d}
              onClick={() => setDay(d)}
              className={`rounded-[10px] py-1.5 text-center text-[12px] ${selDay === d ? 'bg-[#7d5fff] font-bold text-white' : d === today ? 'bg-[#efebff] text-[#5b3fe0]' : 'bg-white text-[#1d1b2b]'}`}
            >
              {dayLabel(d).split('(')[1].replace(')', '')}
              <span className="block text-[11px] opacity-80">{Number(d.slice(8))}</span>
            </button>
          ))}
        </div>
        <div className="grid gap-2 lg:hidden">
          {shown.filter((l) => instantToKstDate(l.startsAt) === selDay).map(card)}
          {shown.filter((l) => instantToKstDate(l.startsAt) === selDay).length === 0 && <p className="py-6 text-center text-[13px] text-[#6b6880]">이날 수업이 없어요.</p>}
        </div>

        {/* PC: 7일 칸 */}
        <div className="hidden grid-cols-7 gap-2 lg:grid">
          {week.map((d) => (
            <section key={d} aria-label={dayLabel(d)} className={`min-w-0 rounded-[14px] p-2 ${d === today ? 'bg-[#efebff]' : 'bg-[#f6f5fa]'}`}>
              <h2 className={`mb-2 px-1 text-[13px] font-bold ${d === today ? 'text-[#5b3fe0]' : 'text-[#1d1b2b]'}`}>
                {dayLabel(d)} {d === today && '· 오늘'}
              </h2>
              <div className="grid gap-1.5">
                {shown.filter((l) => instantToKstDate(l.startsAt) === d).map(card)}
                {shown.filter((l) => instantToKstDate(l.startsAt) === d).length === 0 && <p className="px-1 text-[12px] text-[#b9b6c8]">수업 없음</p>}
              </div>
            </section>
          ))}
        </div>
      </div>
      <BottomNav active="schedule" demo />
    </div>
  );
}
