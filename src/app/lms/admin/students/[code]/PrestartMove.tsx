'use client';

// 첫 수업 시작 전 개별 수업 날짜 변경 — 변경권 차감 없음 (2026-11-06 대표 요청, 정책 원본 H26(62))
// - 학생 상세 '다가오는 수업' 의 [시작 전 날짜 변경] → 이 창. 수업마다 [변경] → 날짜·시간 → [저장]
// - 검사·저장은 DB(admin_prestart_move): 수강 기간 안 · 같은 날 수업 없음 · 강사 휴무·다른 수업(휴식 10분)·현지 06:00~22:30·연 시간·재등록 대기
// - 저장 뒤 학생 카톡·강사 WhatsApp 안내 문구 복사

import { useState } from 'react';
import { formatInZone, instantToKstDate, kstToInstant, type KstDate } from '@/lms/rules/dates';
import { dayLabel, localTime } from '@/lms/admin/schedule';
import { prestartMoveNotices } from '@/lms/admin/confirm';
import type { Upcoming } from '@/lms/admin/students';
import { CopyButton, Sheet } from './parts';

const TIMES = Array.from({ length: 48 }, (_, i) => `${String(Math.floor(i / 2)).padStart(2, '0')}:${i % 2 ? '30' : '00'}`);
const kstOf = (d: Date) => ({ date: instantToKstDate(d), time: formatInZone(d, 'Asia/Seoul').time });
const local = (at: Date, tz: string) => (tz && tz !== 'Asia/Seoul' ? localTime(at, tz) : null);

type Saved = { student: string; tutor: string; line: string };

export default function PrestartMove(p: {
  lessons: Upcoming[];
  period: { start: KstDate; end: KstDate };
  student: { nameEn: string; timezone: string; city: string | null };
  move: (lessonId: string, startsAt: string) => Promise<unknown>;
  onSaved: () => Promise<void>;
  onClose: () => void;
}) {
  const [open, setOpen] = useState<string | null>(null);
  const [date, setDate] = useState<KstDate>('');
  const [time, setTime] = useState('');
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<{ id: string; msg: string } | null>(null);
  const [saved, setSaved] = useState<Saved | null>(null);

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
      setSaved({ ...n, line: `${dayLabel(kstOf(l.startsAt).date)} ${kstOf(l.startsAt).time} → ${dayLabel(date)} ${time} (한국 시간)` });
      setOpen(null);
      await p.onSaved();
    } catch (e) {
      setErr({ id: l.id, msg: e instanceof Error ? e.message : '저장하지 못했어요.' });
    } finally {
      setBusy(false);
    }
  }

  return (
    <Sheet title="시작 전 날짜 변경" onClose={p.onClose}>
      <p className="mb-3 text-[13px] text-[#6b6880]">변경권 차감 없음 · 수강 기간 {dayLabel(p.period.start)} ~ {dayLabel(p.period.end)}</p>
      {saved && (
        <div className="mb-3 rounded-[14px] border border-[#cfe8d8] bg-white p-3">
          <p className="text-[14px] font-bold text-[#13623a]">저장했어요 · {saved.line}</p>
          {[
            ['학생 카카오톡', saved.student],
            ['강사 WhatsApp', saved.tutor],
          ].map(([who, text]) => (
            <div key={who} className="mt-2 rounded-[10px] bg-[#f6f5fa] p-2.5">
              <div className="mb-1 flex items-center justify-between gap-2">
                <b className="text-[13px] text-[#1d1b2b]">{who}</b>
                <CopyButton text={text} />
              </div>
              <p className="whitespace-pre-line text-[13px] text-[#1d1b2b]">{text}</p>
            </div>
          ))}
        </div>
      )}
      <section className="rounded-[14px] border border-[#e6e3ef] bg-white px-3 py-1">
        {p.lessons.map((l) => {
          const k = kstOf(l.startsAt);
          const loc = local(l.startsAt, l.tutorTz);
          const newLoc = date && time ? local(kstToInstant(date, time), l.tutorTz) : null;
          return (
            <div key={l.id} className="border-b border-[#f0eef6] py-2.5 last:border-0">
              <div className="flex items-center gap-2">
                <div className="min-w-0 flex-1 text-[14px] text-[#1d1b2b]">
                  <span className="mr-2 inline-block w-9">{l.seq ? `${l.seq}회` : ''}</span>
                  <span className="tabular-nums">{dayLabel(k.date)} {k.time}</span>
                  <span className="ml-1 text-[12.5px] text-[#6b6880]">(한국){loc ? ` · 강사 현지 ${loc}` : ''}</span>
                </div>
                {open !== l.id && (
                  <button type="button" onClick={() => edit(l)} className="min-h-[38px] shrink-0 rounded-[10px] border border-[#e6e3ef] px-3 text-[13px] font-semibold text-[#1d1b2b]">
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
        })}
      </section>
    </Sheet>
  );
}
