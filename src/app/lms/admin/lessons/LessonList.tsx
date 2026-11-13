'use client';

// 기간별 수업 목록 (대시보드 5차): PC 표(날짜 줄 + 시각·학생·강사·종류·상태) / 휴대폰 날짜별 목록. 시각은 한국 시간
import Link from 'next/link';
import { useEffect, useMemo, useState } from 'react';
import { loadLessonRange } from '@/lms/admin/live';
import { mdw, RANGE_LABEL, rangeDates, type LessonItem, type LessonRange } from '@/lms/admin/dashboard';
import { instantToKstDate, type KstDate } from '@/lms/rules/dates';
import { AdminHeader, BottomNav } from '../ui';
import { useAdminSb } from '../useAdmin';
import DateInput from '../DateInput';
import { LessonRows, lessonStateClass, STRIKE } from '../LessonRows';

export default function LessonList() {
  const { sb, error } = useAdminSb();
  const today = useMemo(() => instantToKstDate(new Date()), []);
  const [range, setRange] = useState<LessonRange>('today');
  const [pick, setPick] = useState<{ from: KstDate | ''; to: KstDate | '' }>({ from: today, to: today });
  const dates = rangeDates(range, today, pick);
  const [rows, setRows] = useState<LessonItem[] | null>(null);
  const [err, setErr] = useState<string | null>(null);

  useEffect(() => {
    if (!sb || !dates) return;
    let stop = false;
    setRows(null);
    loadLessonRange(sb, dates.from, dates.to)
      .then((r) => { if (!stop) { setRows(r); setErr(null); } })
      .catch((e) => { if (!stop) setErr(e instanceof Error ? e.message : '수업을 읽지 못했어요.'); });
    return () => { stop = true; };
  }, [sb, dates?.from, dates?.to]); // eslint-disable-line react-hooks/exhaustive-deps

  const days = rows ? [...new Set(rows.map((r) => r.date))] : [];
  const studentHref = (code: string) => `/lms/admin/students/${encodeURIComponent(code)}`;

  return (
    <div className="mx-auto min-h-dvh max-w-[1280px] pb-24 lg:pb-8">
      <AdminHeader active="home" demo={false} />
      <div className="grid gap-3 px-4 pt-3 lg:px-7 lg:pt-5">
        <Link href="/lms/admin" className="min-h-[32px] w-fit text-[13.5px] font-semibold text-[#5b3fe0]">← 홈</Link>
        <section aria-label="수업 목록" className="min-w-0 rounded-[14px] border border-[#e6e3ef] bg-white px-4 py-3">
          <div className="mb-2 flex flex-wrap items-center gap-2">
            <h1 className="text-[15px] font-bold text-[#1d1b2b]">수업 목록</h1>
            <span className="text-[12px] text-[#6b6880]">한국 시간</span>
            {dates && <span className="ml-auto text-[13px] font-semibold text-[#6b6880]">{mdw(dates.from)}{dates.from === dates.to ? '' : ` ~ ${mdw(dates.to)}`}</span>}
          </div>
          <div role="group" aria-label="기간" className="flex flex-wrap gap-1.5">
            {(Object.keys(RANGE_LABEL) as LessonRange[]).map((k) => (
              <button key={k} type="button" aria-pressed={range === k} onClick={() => setRange(k)}
                className={`min-h-[36px] rounded-[10px] border px-3 text-[13px] font-semibold ${range === k ? 'border-[#1d1b2b] bg-[#1d1b2b] text-white' : 'border-[#e6e3ef] bg-white text-[#1d1b2b]'}`}>
                {RANGE_LABEL[k]}
              </button>
            ))}
          </div>
          {range === 'pick' && (
            <div className="mt-2 flex flex-wrap items-end gap-2">
              <label className="grid gap-1 text-[12.5px] font-semibold text-[#6b6880]">시작일
                <DateInput value={pick.from} onChange={(v) => setPick({ ...pick, from: v })} className="min-h-[40px] rounded-[10px] border border-[#e6e3ef] px-2 text-[15px] font-normal text-[#1d1b2b]" />
              </label>
              <label className="grid gap-1 text-[12.5px] font-semibold text-[#6b6880]">종료일
                <DateInput value={pick.to} onChange={(v) => setPick({ ...pick, to: v })} className="min-h-[40px] rounded-[10px] border border-[#e6e3ef] px-2 text-[15px] font-normal text-[#1d1b2b]" />
              </label>
            </div>
          )}
          <div className="mt-3">
            {(error || err) && <p className="text-[13px] text-[#c62b2b]">{error ?? err}</p>}
            {!dates && <p className="text-[13px] font-semibold text-[#c62b2b]">{pick.from && pick.to ? '종료일이 시작일보다 빨라요.' : '시작일과 종료일을 넣어 주세요.'}</p>}
            {dates && !rows && !err && !error && <p className="py-4 text-center text-[13px] text-[#6b6880]">불러오는 중…</p>}
            {rows && rows.length === 0 && <p className="py-4 text-center text-[13px] text-[#6b6880]">이 기간에 수업이 없어요.</p>}
            {rows && rows.length > 0 && (
              <>
                {/* PC 표 */}
                <div className="hidden max-h-[560px] overflow-auto rounded-[10px] border border-[#e6e3ef] lg:block">
                  <table className="w-full border-collapse text-[13.5px]">
                    <thead>
                      <tr className="sticky top-0 bg-white text-left text-[12px] text-[#6b6880]">
                        <th className="w-[120px] border-b border-[#e6e3ef] px-2 py-1.5 font-semibold">시각 (한국 시간)</th>
                        <th className="border-b border-[#e6e3ef] px-2 py-1.5 font-semibold">학생</th>
                        <th className="border-b border-[#e6e3ef] px-2 py-1.5 font-semibold">강사</th>
                        <th className="border-b border-[#e6e3ef] px-2 py-1.5 font-semibold">종류</th>
                        <th className="border-b border-[#e6e3ef] px-2 py-1.5 font-semibold">상태</th>
                      </tr>
                    </thead>
                    <tbody>
                      {days.map((d) => {
                        const r = rows.filter((x) => x.date === d);
                        return [
                          <tr key={d}><td colSpan={5} className="bg-[#f6f5fa] px-2 py-1.5 text-[12.5px] font-extrabold text-[#6b6880]">{mdw(d)} · {r.length}건</td></tr>,
                          ...r.map((l) => (
                            <tr key={l.id} className="border-b border-[#e6e3ef]">
                              <td className={`px-2 py-1.5 align-top tabular-nums text-[#6b6880] ${l.struck ? STRIKE : ''}`}>{l.time}</td>
                              <td className="px-2 py-1.5 align-top">
                                {l.studentCode ? <Link href={studentHref(l.studentCode)} className={`hover:underline ${l.struck ? STRIKE : ''}`}>{l.studentName}</Link> : <span className={l.struck ? STRIKE : ''}>{l.studentName}</span>}
                                {l.note && <span className="block text-[12px] text-[#6b6880]">{l.note}</span>}
                              </td>
                              <td className="px-2 py-1.5 align-top">{l.tutorName}</td>
                              <td className="px-2 py-1.5 align-top">{l.kind}</td>
                              <td className={`px-2 py-1.5 align-top ${lessonStateClass(l)}`}>{l.state}</td>
                            </tr>
                          )),
                        ];
                      })}
                    </tbody>
                  </table>
                </div>
                {/* 휴대폰 날짜별 */}
                <div className="lg:hidden">
                  {days.map((d) => {
                    const r = rows.filter((x) => x.date === d);
                    return (
                      <div key={d}>
                        <div className="sticky top-0 flex justify-between bg-[#f6f5fa] px-1 py-1.5 text-[12.5px] font-extrabold text-[#6b6880]"><span>{mdw(d)}</span><span>{r.length}건</span></div>
                        <div className="px-1"><LessonRows rows={r} studentHref={studentHref} /></div>
                      </div>
                    );
                  })}
                </div>
              </>
            )}
          </div>
        </section>
      </div>
      <BottomNav active="home" demo={false} />
    </div>
  );
}
