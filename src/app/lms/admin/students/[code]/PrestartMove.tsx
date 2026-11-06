'use client';

// 첫 수업 시작 전 개별 수업 날짜 변경 — 변경권 차감 없음 (2026-11-06 대표 요청, 정책 원본 H26(62))
// - 학생 상세 '다가오는 수업' 의 [시작 전 날짜 변경] → 이 창
// - 바꾼 수업을 먼저, 나머지는 [다른 수업 바꾸기]를 눌러 펼침 (바꾼 수업이 없으면 처음부터 펼침)
// - 저장 뒤: 한 줄 결과 + [학생 안내 복사] [강사 안내 복사]
// - 검사·저장은 DB(admin_prestart_move): 수강 기간 안 · 같은 날 수업 없음 · 강사 휴무·다른 수업(휴식 10분)·현지 06:00~22:30·연 시간·재등록 대기

import { useEffect, useState } from 'react';
import { formatInZone, instantToKstDate, kstToInstant, type KstDate } from '@/lms/rules/dates';
import { dayLabel, localTime } from '@/lms/admin/schedule';
import { prestartMoveNotices } from '@/lms/admin/confirm';
import type { Upcoming } from '@/lms/admin/students';
import { CopyButton, Sheet } from './parts';

const TIMES = Array.from({ length: 48 }, (_, i) => `${String(Math.floor(i / 2)).padStart(2, '0')}:${i % 2 ? '30' : '00'}`);
const kstOf = (d: Date) => ({ date: instantToKstDate(d), time: formatInZone(d, 'Asia/Seoul').time });
const label = (d: Date) => `${dayLabel(kstOf(d).date)} ${kstOf(d).time}`;
const local = (at: Date, tz: string) => (tz && tz !== 'Asia/Seoul' ? localTime(at, tz) : null);
const copyCls = 'min-h-[44px] flex-1 rounded-[10px] border border-[#cfc4ff] bg-white px-3 text-[14px] font-semibold text-[#5b3fe0]';

type Saved = { student: string; tutor: string; line: string };

export default function PrestartMove(p: {
  lessons: Upcoming[];
  period: { start: KstDate; end: KstDate };
  student: { nameEn: string; timezone: string; city: string | null };
  move: (lessonId: string, startsAt: string) => Promise<unknown>;
  /** 이미 옮긴 수업: 수업 id → 처음 날짜(ISO) */
  loadMoved: () => Promise<Record<string, string>>;
  onSaved: () => Promise<void>;
  onClose: () => void;
}) {
  const [moved, setMoved] = useState<Record<string, string> | null>(null);
  const [showOthers, setShowOthers] = useState<boolean | null>(null);
  const [open, setOpen] = useState<string | null>(null);
  const [date, setDate] = useState<KstDate>('');
  const [time, setTime] = useState('');
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<{ id: string; msg: string } | null>(null);
  const [saved, setSaved] = useState<Saved | null>(null);

  useEffect(() => {
    let live = true;
    p.loadMoved().then((m) => live && setMoved(m)).catch(() => live && setMoved({}));
    return () => {
      live = false;
    };
  }, []); // eslint-disable-line react-hooks/exhaustive-deps

  const changed = p.lessons.filter((l) => moved?.[l.id]);
  const others = p.lessons.filter((l) => !moved?.[l.id]);
  const othersOpen = showOthers ?? changed.length === 0;

  function edit(l: Upcoming) {
    const k = kstOf(l.startsAt);
    setOpen(l.id);
    setDate(k.date);
    setTime(k.time);
    setErr(null);
  }

  async function save(l: Upcoming) {
    if (busy || !date || !time) return;
    setBusy(true);
    setErr(null);
    const to = kstToInstant(date, time);
    try {
      await p.move(l.id, to.toISOString());
      const n = prestartMoveNotices({ studentNameEn: p.student.nameEn, studentTz: p.student.timezone, studentCity: p.student.city, tutorTz: l.tutorTz, from: l.startsAt, to });
      setSaved({ ...n, line: `${label(l.startsAt)} → ${dayLabel(date)} ${time}` });
      setMoved((m) => ({ ...(m ?? {}), [l.id]: m?.[l.id] ?? l.startsAt.toISOString() }));
      setOpen(null);
      await p.onSaved();
    } catch (e) {
      setErr({ id: l.id, msg: e instanceof Error ? e.message : '저장하지 못했어요.' });
    } finally {
      setBusy(false);
    }
  }

  const row = (l: Upcoming) => {
    const k = kstOf(l.startsAt);
    const loc = local(l.startsAt, l.tutorTz);
    const first = moved?.[l.id];
    const newLoc = date && time ? local(kstToInstant(date, time), l.tutorTz) : null;
    return (
      <div key={l.id} className="border-b border-[#f0eef6] py-2.5 last:border-0">
        <div className="flex items-center gap-2">
          <div className="min-w-0 flex-1 text-[14px] text-[#1d1b2b]">
            <span className="mr-2 inline-block w-9">{l.seq ? `${l.seq}회` : ''}</span>
            {first && <s className="mr-1 text-[13px] text-[#9a97a8]">{label(new Date(first))}</s>}
            {first && <span className="mr-1 text-[#9a97a8]">→</span>}
            <span className={`tabular-nums ${first ? 'font-bold' : ''}`}>{dayLabel(k.date)} {k.time}</span>
            {loc && <span className="ml-1.5 text-[12.5px] text-[#6b6880]">현지 {loc}</span>}
          </div>
          {open !== l.id && (
            <button type="button" onClick={() => edit(l)} className="min-h-[38px] shrink-0 rounded-[10px] border border-[#e6e3ef] bg-white px-3 text-[13px] font-semibold text-[#1d1b2b]">
              변경
            </button>
          )}
        </div>
        {open === l.id && (
          <div className="mt-2 flex flex-wrap items-center gap-2 rounded-[10px] bg-[#f6f5fb] p-2.5">
            <input type="date" aria-label={`${l.seq ?? ''}회 새 날짜`} value={date} min={p.period.start} max={p.period.end} onChange={(e) => setDate(e.target.value)} className="min-h-[42px] rounded-[10px] border border-[#e6e3ef] bg-white px-3 text-[14.5px] text-[#1d1b2b]" />
            <select aria-label={`${l.seq ?? ''}회 새 시간`} value={time} onChange={(e) => setTime(e.target.value)} className="min-h-[42px] w-[110px] rounded-[10px] border border-[#e6e3ef] bg-white px-3 text-[14.5px] text-[#1d1b2b]">
              {(TIMES.includes(time) ? TIMES : [time, ...TIMES]).map((t) => (
                <option key={t} value={t}>
                  {t}
                </option>
              ))}
            </select>
            <span className="text-[12.5px] text-[#6b6880]">한국{newLoc ? ` · 강사 현지 ${newLoc}` : ''}</span>
            <span className="flex-1" />
            <button type="button" onClick={() => setOpen(null)} className="min-h-[40px] rounded-[10px] border border-[#e6e3ef] bg-white px-3 text-[13.5px] text-[#1d1b2b]">
              취소
            </button>
            <button
              type="button"
              disabled={busy || !date || !time || (date === k.date && time === k.time)}
              onClick={() => save(l)}
              className="min-h-[40px] rounded-[10px] bg-[#7d5ffb] px-4 text-[13.5px] font-bold text-white disabled:bg-[#cfc4ff]"
            >
              {busy ? '저장 중…' : '저장'}
            </button>
          </div>
        )}
        {err?.id === l.id && <p className="mt-1.5 text-[13px] text-[#b3261e]">{err.msg}</p>}
      </div>
    );
  };

  return (
    <Sheet title="시작 전 날짜 변경" onClose={p.onClose}>
      <p className="mb-3 text-[13px] text-[#6b6880]">변경권 차감 없음 · 한국 시간 · 수강 기간 {dayLabel(p.period.start)} ~ {dayLabel(p.period.end)}</p>
      {saved && (
        <div className="mb-3 rounded-[14px] border border-[#cfe8d8] bg-white p-3">
          <p className="text-[14px] font-bold text-[#13623a]">✓ 저장했어요 · {saved.line}</p>
          <div className="mt-2 flex gap-2">
            <CopyButton text={saved.student} className={copyCls}>
              학생 안내 복사
            </CopyButton>
            <CopyButton text={saved.tutor} className={copyCls}>
              강사 안내 복사
            </CopyButton>
          </div>
          <details className="mt-2 text-[13px]">
            <summary className="cursor-pointer py-1 font-semibold text-[#5b3fe0]">안내 문구 보기</summary>
            <p className="mt-1 text-[12.5px] font-semibold text-[#6b6880]">학생 카카오톡</p>
            <p className="whitespace-pre-line rounded-[10px] bg-[#f6f5fa] p-2.5 text-[#1d1b2b]">{saved.student}</p>
            <p className="mt-2 text-[12.5px] font-semibold text-[#6b6880]">강사 WhatsApp</p>
            <p className="whitespace-pre-line rounded-[10px] bg-[#f6f5fa] p-2.5 text-[#1d1b2b]">{saved.tutor}</p>
          </details>
        </div>
      )}
      {moved === null ? (
        <p className="py-6 text-center text-[13.5px] text-[#6b6880]">불러오는 중…</p>
      ) : (
        <>
          {changed.length > 0 && (
            <>
              <p className="pb-1 text-[13px] font-bold text-[#1d1b2b]">바꾼 수업 {changed.length}</p>
              <section className="mb-2 rounded-[14px] border border-[#f3e2bf] bg-[#fff8e8] px-3 py-1">{changed.map(row)}</section>
            </>
          )}
          <button type="button" aria-expanded={othersOpen} onClick={() => setShowOthers(!othersOpen)} className="flex min-h-[44px] w-full items-center gap-2 text-left text-[14px] font-semibold text-[#4b33c4]">
            {changed.length > 0 ? '다른 수업 바꾸기' : '수업 고르기'} <span className="text-[13px] font-normal text-[#6b6880]">({others.length})</span>
            <span className="flex-1" />
            <span aria-hidden className={`text-[16px] transition-transform ${othersOpen ? 'rotate-180' : ''}`}>⌄</span>
          </button>
          {othersOpen && <section className="rounded-[14px] border border-[#e6e3ef] bg-white px-3 py-1">{others.map(row)}</section>}
        </>
      )}
    </Sheet>
  );
}
