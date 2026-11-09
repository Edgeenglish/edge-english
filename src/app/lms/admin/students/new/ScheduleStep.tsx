'use client';

// 신규 등록 3단계 · 수업 일정 (2026-11-06 대표 시안 그대로, 정책 원본 H26(61))
// - PC: 왼쪽 '수업 일정 설정'(1 정규 수업 · 2 첫 수업일 · 3 특정 수업 날짜 변경) | 오른쪽 '수업 일정 미리보기'
// - 휴대폰: 따로 구성 — 설정 카드를 세로로, 미리보기는 접어 두고 눌러서 펼침
// - 특정 수업 날짜 변경: 회차 목록 창에서 날짜·시각을 바꿈 (변경권 차감 없음). 검사는 기존 규칙 그대로(checkLessonList)

import { useState } from 'react';
import { ampmKo, kstToInstant, type KstDate } from '@/lms/rules/dates';
import type { PlanIssue } from '@/lms/rules/booking';
import type { LessonDate, LessonPlan, PlanLesson } from '@/lms/rules/lessons';
import type { RegularSlot } from '@/lms/rules/schedule';
import type { RegTutor } from '@/lms/admin/registration';
import { dayLabel, localTime, WEEKDAY_KO } from '@/lms/admin/schedule';
import { slotLocal } from './parts';
import DateInput from '../../DateInput';

const ORDER = [1, 2, 3, 4, 5, 6, 0];
const TIMES = Array.from({ length: 48 }, (_, i) => `${String(Math.floor(i / 2)).padStart(2, '0')}:${i % 2 ? '30' : '00'}`);
const md = (d: KstDate) => `${Number(d.slice(5, 7))}/${Number(d.slice(8, 10))}`;

export type ScheduleProps = {
  tutor: RegTutor | null;
  weeklyCount: number | null;
  weeks: number | null;
  slots: RegularSlot[];
  onToggleDay: (weekday: number) => void;
  onDayTime: (weekday: number, time: string) => void;
  firstDate: KstDate | null;
  onFirstDate: (d: KstDate) => void;
  plan: LessonPlan | null;
  issues: PlanIssue[];
  slotErr: string | null;
  warnings: string[];
  onEdit: (key: KstDate, to: LessonDate | null) => void;
  onPrev: () => void;
  onNext: () => void;
};

/** 강사 현지 시각 (한국과 같은 시간대면 없음) */
function localOf(tutor: RegTutor | null, date: KstDate, time: string) {
  if (!tutor || !tutor.timezone || tutor.timezone === 'Asia/Seoul' || !time) return null;
  return localTime(kstToInstant(date, time), tutor.timezone);
}

function Num({ n }: { n: number }) {
  return <span className="inline-flex h-7 w-7 shrink-0 items-center justify-center rounded-full bg-[#5b3fe0] text-[14px] font-bold text-white">{n}</span>;
}

function CalIcon() {
  return (
    <svg aria-hidden viewBox="0 0 24 24" className="h-5 w-5 shrink-0 text-[#1d1b2b]" fill="none" stroke="currentColor" strokeWidth="1.8">
      <rect x="3" y="5" width="18" height="16" rx="2" />
      <path d="M8 3v4M16 3v4M3 10h18" />
    </svg>
  );
}

function PenIcon() {
  return (
    <svg aria-hidden viewBox="0 0 24 24" className="h-[18px] w-[18px]" fill="none" stroke="currentColor" strokeWidth="2">
      <path d="M4 20h4L19 9l-4-4L4 16v4zM14 6l4 4" />
    </svg>
  );
}

function DayChips({ slots, onToggleDay, small }: Pick<ScheduleProps, 'slots' | 'onToggleDay'> & { small?: boolean }) {
  return (
    <div className="flex flex-wrap gap-1.5">
      {ORDER.map((wd) => {
        const on = slots.some((s) => s.weekday === wd);
        return (
          <button
            key={wd}
            type="button"
            aria-pressed={on}
            onClick={() => onToggleDay(wd)}
            className={`${small ? 'h-9 w-9 text-[14px]' : 'h-11 w-11 text-[16px]'} rounded-full border font-semibold ${on ? 'border-[#5b3fe0] bg-[#5b3fe0] text-white' : 'border-[#e6e3ef] bg-white text-[#1d1b2b]'}`}
          >
            {WEEKDAY_KO[wd]}
          </button>
        );
      })}
    </div>
  );
}

function TimeSelect({ value, onChange, label, small }: { value: string; onChange: (t: string) => void; label: string; small?: boolean }) {
  const opts = value && !TIMES.includes(value) ? [value, ...TIMES] : TIMES;
  return (
    <select
      aria-label={label}
      value={value}
      onChange={(e) => onChange(e.target.value)}
      className={`${small ? 'min-h-[40px] w-[128px] text-[14px]' : 'min-h-[46px] w-[140px] text-[16px]'} rounded-[10px] border border-[#e6e3ef] bg-white px-3 text-[#1d1b2b]`}
    >
      <option value="">시간 선택</option>
      {opts.map((t) => (
        <option key={t} value={t}>
          {ampmKo(t)}
        </option>
      ))}
    </select>
  );
}

/** 정규 시간의 강사 현지 시각 한 줄 (모든 시각에 시간대 이름) */
function zoneLine(tutor: RegTutor | null, slots: RegularSlot[], firstDate: KstDate | null) {
  const set = slots.filter((s) => s.time);
  if (!set.length) return null;
  const kst = '한국 시간(KST)';
  if (!tutor || tutor.timezone === 'Asia/Seoul' || !firstDate) return kst;
  return `${kst} · ${tutor.name} 현지 ${set.map((s) => `${WEEKDAY_KO[s.weekday]} ${slotLocal(s, firstDate, tutor.timezone)}`).join(' / ')}`;
}

function FirstDateInput({ firstDate, onFirstDate, small }: Pick<ScheduleProps, 'firstDate' | 'onFirstDate'> & { small?: boolean }) {
  return (
    <label className={`flex items-center gap-3 rounded-[10px] border border-[#e6e3ef] bg-white px-3 ${small ? 'min-h-[44px]' : 'min-h-[50px] w-[300px]'}`}>
      <CalIcon />
      <DateInput
        aria-label="첫 수업일"
        value={firstDate ?? ''}
        onChange={(v) => v && onFirstDate(v)}
        className={`min-w-0 flex-1 bg-transparent text-[#1d1b2b] outline-none ${small ? 'text-[14.5px]' : 'text-[17px]'}`}
      />
      {firstDate && <span className={`shrink-0 text-[#1d1b2b] ${small ? 'text-[14px]' : 'text-[16px]'}`}>({WEEKDAY_KO[new Date(`${firstDate}T00:00:00Z`).getUTCDay()]})</span>}
    </label>
  );
}

/** '✓ 총 8회 수업이 생성됩니다. (11/6 ~ 12/3 · 28일)' 또는 문제·충돌 */
function PlanStatus({ plan, issues, weeks, small }: { plan: LessonPlan | null; issues: PlanIssue[]; weeks: number | null; small?: boolean }) {
  if (!plan || !plan.startDate || !plan.endDate || !weeks) return null;
  const bad = plan.problems.length + new Set(issues.map((i) => i.kstDate)).size;
  if (bad > 0)
    return (
      <p className={`${small ? 'text-[13px]' : 'text-[15px]'} font-semibold text-[#b3261e]`}>
        ✕ 문제 {bad}건 — 아래 미리보기에서 확인
      </p>
    );
  return (
    <div className={small ? 'text-[13px]' : 'text-[15.5px]'}>
      <p className="font-semibold text-[#1e7a46]">✓ 총 {plan.lessons.length}회 수업이 생성됩니다.</p>
      <p className="text-[#6b6880]">
        ({md(plan.startDate)} ~ {md(plan.endDate)} · {weeks * 7}일)
      </p>
    </div>
  );
}

/** 회차 한 줄의 표시 (첫 수업·변경) */
function Tags({ l }: { l: PlanLesson }) {
  return (
    <>
      {l.n === 1 && <span className="rounded-full bg-[#efebff] px-2 py-0.5 text-[12.5px] font-semibold text-[#5b3fe0]">첫 수업</span>}
      {l.original && <span className="rounded-full bg-[#fff1dc] px-2 py-0.5 text-[12.5px] font-semibold text-[#9a5b00]">변경</span>}
      {l.original && <span className="text-[12.5px] text-[#6b6880]">(원래 {dayLabel(l.original.date)}{l.original.time !== l.time ? ` ${ampmKo(l.original.time)}` : ''})</span>}
    </>
  );
}

/** 미리보기 목록: 1~5회 · 바꾼 회차 · 마지막 회차, 사이는 ⋯ (all 이면 전부) */
function PreviewRows({ plan, issues, tutor, all }: { plan: LessonPlan; issues: PlanIssue[]; tutor: RegTutor | null; all?: boolean }) {
  const last = plan.lessons.length;
  const shown = plan.lessons.filter((l) => all || l.n <= 5 || l.n === last || l.original || issues.some((i) => i.kstDate === l.date));
  const showLocal = !!tutor && tutor.timezone !== 'Asia/Seoul';
  const rows: React.ReactNode[] = [];
  shown.forEach((l, i) => {
    if (i > 0 && l.n - shown[i - 1].n > 1)
      rows.push(
        <li key={`gap-${l.n}`} className="px-3 py-1 text-[15px] tracking-widest text-[#9a97a8]">
          ⋯
        </li>,
      );
    const bad = issues.filter((x) => x.kstDate === l.date);
    rows.push(
      <li key={l.key} className={`border-b border-[#f0eef6] px-3 py-2.5 last:border-b-0 ${l.original ? 'bg-[#fff8e8]' : ''} ${bad.length ? 'bg-[#fdecec]' : ''}`}>
        <div className="flex flex-wrap items-center gap-x-3 gap-y-1 text-[15px] text-[#1d1b2b]">
          <span className="w-9 shrink-0">{l.n}회</span>
          <span className="tabular-nums">{dayLabel(l.date)}</span>
          <span className="tabular-nums">{ampmKo(l.time)}</span>
          {showLocal && <span className="text-[13px] tabular-nums text-[#6b6880]">현지 {localOf(tutor, l.date, l.time)}</span>}
          <Tags l={l} />
        </div>
        {bad.map((x, k) => (
          <p key={k} className="mt-1 pl-12 text-[12.5px] text-[#b3261e]">
            {x.detail}
          </p>
        ))}
      </li>,
    );
  });
  return (
    <>
      <p className="px-3 pb-1 text-[12.5px] text-[#6b6880]">
        한국 시간(KST){showLocal ? ` · 현지 = ${tutor!.name} 현지 시각` : ''}
      </p>
      <ul>{rows}</ul>
    </>
  );
}

function PeriodBox({ plan, slots, weeks }: { plan: LessonPlan; slots: RegularSlot[]; weeks: number | null }) {
  if (!plan.startDate || !plan.endDate) return null;
  return (
    <div className="mt-3 space-y-2 rounded-[12px] bg-[#f6f5fb] px-4 py-3 text-[14.5px]">
      <p className="flex flex-wrap gap-x-4">
        <span className="text-[#6b6880]">수강 기간</span>
        <span className="text-[#1d1b2b]">
          {dayLabel(plan.startDate)} ~ {dayLabel(plan.endDate)}
          {weeks ? ` · ${weeks * 7}일` : ''}
        </span>
      </p>
      <p className="flex flex-wrap gap-x-4">
        <span className="text-[#6b6880]">정규 일정</span>
        <span className="text-[#1d1b2b]">{slots.map((s) => `${WEEKDAY_KO[s.weekday]} ${ampmKo(s.time)}`).join(' / ')} (KST)</span>
      </p>
    </div>
  );
}

/** 특정 수업 날짜 변경 창 (PC 가운데 · 휴대폰 아래에서 올라옴)
 *  바꾼 수업을 먼저, 나머지 회차는 [다른 회차 바꾸기]를 눌러야 펼침 (바꾼 수업이 없으면 처음부터 펼침) */
export function ChangeSheet({ plan, issues, tutor, onEdit, onClose }: { plan: LessonPlan; issues: PlanIssue[]; tutor: RegTutor | null; onEdit: ScheduleProps['onEdit']; onClose: () => void }) {
  const [open, setOpen] = useState<KstDate | null>(null);
  const [date, setDate] = useState<KstDate>('');
  const [time, setTime] = useState('');
  // 날짜 칸에 치는 중(미완성)이면 적용을 막고 안내 (QA A-02)
  const [partial, setPartial] = useState(false);
  const changed = plan.lessons.filter((l) => l.original);
  const others = plan.lessons.filter((l) => !l.original);
  const [showOthers, setShowOthers] = useState(changed.length === 0);
  const edit = (l: PlanLesson) => {
    setOpen(l.key);
    setDate(l.date);
    setTime(l.time);
  };
  const row = (l: PlanLesson) => {
    const bad = issues.filter((x) => x.kstDate === l.date);
    const loc = localOf(tutor, l.date, l.time);
    return (
      <li key={l.key} className="border-b border-[#f0eef6] py-2.5 last:border-b-0">
        <div className="flex items-center gap-2">
          <div className="min-w-0 flex-1 text-[14.5px] text-[#1d1b2b]">
            <span className="mr-2 inline-block w-9">{l.n}회</span>
            {l.original && <s className="mr-1 text-[13px] text-[#9a97a8]">{dayLabel(l.original.date)}{l.original.time !== l.time ? ` ${ampmKo(l.original.time)}` : ''}</s>}
            {l.original && <span className="mr-1 text-[#9a97a8]">→</span>}
            <span className={`tabular-nums ${l.original ? 'font-bold' : ''}`}>
              {dayLabel(l.date)} {ampmKo(l.time)}
            </span>
            {loc && <span className="ml-1.5 whitespace-nowrap text-[12.5px] text-[#6b6880]">현지 {loc}</span>}
            {l.n === 1 && <span className="ml-1.5 rounded-full bg-[#efebff] px-2 py-0.5 text-[12px] font-semibold text-[#5b3fe0]">첫 수업</span>}
          </div>
          {l.original ? (
            <button type="button" onClick={() => onEdit(l.key, null)} className="min-h-[38px] shrink-0 rounded-[10px] border border-[#cfc4ff] px-3 text-[13px] font-semibold text-[#5b3fe0]">
              원래대로
            </button>
          ) : (
            open !== l.key && (
              <button type="button" onClick={() => edit(l)} className="min-h-[38px] shrink-0 rounded-[10px] border border-[#e6e3ef] px-3 text-[13px] font-semibold text-[#1d1b2b]">
                변경
              </button>
            )
          )}
        </div>
        {bad.map((x, k) => (
          <p key={k} className="mt-1 pl-11 text-[12.5px] text-[#b3261e]">
            {x.detail}
          </p>
        ))}
        {open === l.key && !l.original && (
          <div className="mt-2 flex flex-wrap items-center gap-2 rounded-[10px] bg-[#f6f5fb] p-2.5">
            <DateInput aria-label={`${l.n}회 새 날짜`} value={date} onChange={setDate} onPartial={setPartial} className="min-h-[42px] rounded-[10px] border border-[#e6e3ef] bg-white px-3 text-[14.5px] text-[#1d1b2b]" />
            <TimeSelect value={time} onChange={setTime} label={`${l.n}회 새 시간`} small />
            <span className="text-[12.5px] text-[#6b6880]">KST{date && time && localOf(tutor, date, time) ? ` · 현지 ${localOf(tutor, date, time)}` : ''}</span>
            <span className="flex-1" />
            <button type="button" onClick={() => setOpen(null)} className="min-h-[40px] rounded-[10px] border border-[#e6e3ef] bg-white px-3 text-[13.5px] text-[#1d1b2b]">
              취소
            </button>
            <button
              type="button"
              disabled={partial || !date || !time || (date === l.date && time === l.time)}
              onClick={() => {
                onEdit(l.key, { date, time });
                setOpen(null);
              }}
              className="min-h-[40px] rounded-[10px] bg-[#7d5ffb] px-4 text-[13.5px] font-bold text-white disabled:bg-[#cfc4ff]"
            >
              {/* 실제로 적용될 날짜를 버튼에 그대로 (QA A-02: 입력값과 저장값이 다른 일이 없게) */}
              {!partial && date && time ? `적용 · ${dayLabel(date)} ${ampmKo(time)}` : '적용'}
            </button>
            {partial && <p className="w-full text-[12.5px] text-[#b3261e]">날짜를 다시 선택해 주세요 (연·월·일을 모두 채워야 적용돼요)</p>}
          </div>
        )}
      </li>
    );
  };
  return (
    <div role="dialog" aria-modal="true" aria-label="특정 수업 날짜 변경" className="fixed inset-0 z-30 flex items-end justify-center bg-black/40 lg:items-center" onClick={onClose}>
      <div className="flex max-h-[88vh] w-full max-w-[560px] flex-col rounded-t-[18px] bg-white lg:rounded-[18px]" onClick={(e) => e.stopPropagation()}>
        <div className="flex items-center border-b border-[#f0eef6] px-5 py-4">
          <div>
            <b className="block text-[17px] text-[#1d1b2b]">특정 수업 날짜 변경</b>
            <span className="text-[13px] text-[#6b6880]">변경권 차감 없음 · 한국 시간(KST)</span>
          </div>
          <span className="flex-1" />
          <button type="button" onClick={onClose} aria-label="닫기" className="h-10 w-10 text-[20px] text-[#6b6880]">
            ×
          </button>
        </div>
        <div className="overflow-y-auto px-5 py-3">
          {plan.problems.map((p) => (
            <p key={p} className="mb-2 rounded-[10px] bg-[#fdecec] px-3 py-2 text-[13px] text-[#b3261e]">
              {p}
            </p>
          ))}
          {changed.length > 0 && (
            <>
              <p className="pb-1 text-[13px] font-bold text-[#1d1b2b]">바꾼 수업 {changed.length}</p>
              <ul className="mb-2 rounded-[12px] bg-[#fff8e8] px-3">{changed.map(row)}</ul>
            </>
          )}
          <button
            type="button"
            aria-expanded={showOthers}
            onClick={() => setShowOthers((v) => !v)}
            className="flex min-h-[44px] w-full items-center gap-2 text-left text-[14px] font-semibold text-[#4b33c4]"
          >
            {changed.length > 0 ? '다른 회차 바꾸기' : '회차 고르기'} <span className="text-[13px] font-normal text-[#6b6880]">({others.length})</span>
            <span className="flex-1" />
            <span aria-hidden className={`text-[16px] transition-transform ${showOthers ? 'rotate-180' : ''}`}>⌄</span>
          </button>
          {showOthers && <ul>{others.map(row)}</ul>}
        </div>
        <div className="border-t border-[#f0eef6] px-5 py-3">
          <button type="button" onClick={onClose} className="min-h-[48px] w-full rounded-[12px] bg-[#7d5ffb] text-[15px] font-bold text-white">
            완료
          </button>
        </div>
      </div>
    </div>
  );
}

const changedCount = (plan: LessonPlan | null) => plan?.lessons.filter((l) => l.original).length ?? 0;

/** PC: 설정 | 미리보기 */
export function ScheduleStepPc(p: ScheduleProps) {
  const [sheet, setSheet] = useState(false);
  const zl = zoneLine(p.tutor, p.slots, p.firstDate);
  const ready = !!p.plan && p.plan.lessons.length > 0;
  return (
    <div>
      <div className="grid grid-cols-[minmax(0,1.15fr)_minmax(0,1fr)] items-start gap-5">
        <section className="rounded-[16px] border border-[#e6e3ef] bg-white p-6">
          <h2 className="text-[22px] font-bold text-[#1d1b2b]">수업 일정 설정</h2>
          <p className="mt-1 text-[15px] text-[#6b6880]">기본 요일·시간을 정하고, 필요하면 특정 수업만 날짜를 조정하세요.</p>

          <div className="mt-5 rounded-[14px] border border-[#ebe8f3] p-5">
            <h3 className="flex items-center gap-2.5 text-[18px] font-bold text-[#1d1b2b]">
              <Num n={1} />
              정규 수업 {p.weeklyCount ? <span className="font-normal text-[#6b6880]">(주 {p.weeklyCount}회)</span> : null}
            </h3>
            <div className="mt-4 grid grid-cols-[88px_1fr] items-center gap-y-4">
              <span className="text-[15px] text-[#1d1b2b]">수업 요일</span>
              <DayChips slots={p.slots} onToggleDay={p.onToggleDay} />
              <span className="text-[15px] text-[#1d1b2b]">수업 시간</span>
              <div className="flex flex-wrap items-center gap-x-5 gap-y-2">
                {p.slots.length === 0 && <span className="text-[14px] text-[#9a97a8]">요일을 먼저 고르세요</span>}
                {p.slots.map((s) => (
                  <span key={s.weekday} className="flex items-center gap-2.5">
                    <span className="text-[15px] text-[#1d1b2b]">{WEEKDAY_KO[s.weekday]}요일</span>
                    <TimeSelect value={s.time} onChange={(t) => p.onDayTime(s.weekday, t)} label={`${WEEKDAY_KO[s.weekday]}요일 수업 시간`} />
                  </span>
                ))}
              </div>
            </div>
            {zl && <p className="mt-3 pl-[88px] text-[13px] text-[#6b6880]">{zl}</p>}
            {p.slotErr && p.slots.length > 0 && <p className="mt-2 pl-[88px] text-[13.5px] text-[#b3261e]">{p.slotErr}</p>}
          </div>

          <div className="mt-3 rounded-[14px] border border-[#ebe8f3] p-5">
            <h3 className="flex items-center gap-2.5 text-[18px] font-bold text-[#1d1b2b]">
              <Num n={2} />첫 수업일
            </h3>
            <div className="mt-4 flex flex-wrap items-center gap-x-6 gap-y-2">
              <FirstDateInput firstDate={p.firstDate} onFirstDate={p.onFirstDate} />
              <PlanStatus plan={p.plan} issues={p.issues} weeks={p.weeks} />
            </div>
            {p.warnings.map((w) => (
              <p key={w} className="mt-2 text-[13.5px] text-[#9a5b00]">
                {w}
              </p>
            ))}
          </div>

          <div className="mt-3 flex items-center gap-4 rounded-[14px] border border-[#ebe8f3] p-5">
            <div className="min-w-0 flex-1">
              <h3 className="flex items-center gap-2.5 text-[18px] font-bold text-[#1d1b2b]">
                <Num n={3} />
                특정 수업 날짜 변경 <span className="font-normal text-[#6b6880]">(선택)</span>
                {changedCount(p.plan) > 0 && <span className="rounded-full bg-[#fff1dc] px-2 py-0.5 text-[13px] font-semibold text-[#9a5b00]">{changedCount(p.plan)}건 변경</span>}
              </h3>
              <p className="mt-2 text-[15px] leading-relaxed text-[#6b6880]">
                특정 주만 다른 날짜로 진행할 경우에만 변경하세요.
                <br />
                (변경권 차감 없음)
              </p>
            </div>
            <button
              type="button"
              disabled={!ready}
              onClick={() => setSheet(true)}
              className="flex min-h-[50px] shrink-0 items-center gap-2 rounded-[12px] border-[1.5px] border-[#7d5ffb] bg-white px-5 text-[16px] font-bold text-[#4b33c4] disabled:opacity-40"
            >
              <PenIcon />
              특정 수업 날짜 변경
            </button>
          </div>
        </section>

        <section className="rounded-[16px] border border-[#e6e3ef] bg-white p-6">
          <div className="mb-3 flex items-center">
            <h2 className="text-[22px] font-bold text-[#1d1b2b]">수업 일정 미리보기</h2>
            <span className="flex-1" />
            {ready && <span className="rounded-full bg-[#efebff] px-3 py-1 text-[15px] font-bold text-[#5b3fe0]">총 {p.plan!.lessons.length}회</span>}
          </div>
          {ready ? (
            <>
              <PreviewRows plan={p.plan!} issues={p.issues} tutor={p.tutor} />
              <PeriodBox plan={p.plan!} slots={p.slots} weeks={p.weeks} />
            </>
          ) : (
            <p className="py-10 text-center text-[14.5px] text-[#6b6880]">{p.tutor ? '정규 요일·시간을 고르면 수업 일정이 보여요' : '2단계에서 강사를 먼저 고르세요'}</p>
          )}
        </section>
      </div>

      <div className="mt-6 flex items-center border-t border-[#ebe8f3] pt-6">
        <button type="button" onClick={p.onPrev} className="min-h-[54px] rounded-[12px] border-[1.5px] border-[#7d5ffb] bg-white px-10 text-[17px] font-bold text-[#4b33c4]">
          ‹ 이전
        </button>
        <span className="flex-1" />
        <button type="button" onClick={p.onNext} className="min-h-[56px] rounded-[12px] bg-[#5b3fe0] px-14 text-[18px] font-bold text-white">
          다음: 최종 확인 ›
        </button>
      </div>
      {sheet && p.plan && <ChangeSheet plan={p.plan} issues={p.issues} tutor={p.tutor} onEdit={p.onEdit} onClose={() => setSheet(false)} />}
    </div>
  );
}

/** 휴대폰: 세로 카드 + 접힌 미리보기 */
export function ScheduleStepMobile(p: ScheduleProps) {
  const [sheet, setSheet] = useState(false);
  const [preview, setPreview] = useState(false);
  const zl = zoneLine(p.tutor, p.slots, p.firstDate);
  const ready = !!p.plan && p.plan.lessons.length > 0;
  const bad = p.plan ? p.plan.problems.length + new Set(p.issues.map((i) => i.kstDate)).size : 0;
  return (
    <div className="space-y-3">
      <div className="px-1">
        <h2 className="text-[18px] font-bold text-[#1d1b2b]">수업 일정 설정</h2>
        <p className="mt-0.5 text-[13.5px] leading-snug text-[#6b6880]">
          기본 요일·시간을 정하고, 필요하면
          <br />
          특정 수업만 날짜를 조정하세요.
        </p>
      </div>

      <section className="rounded-[14px] border border-[#e6e3ef] bg-white p-4">
        <h3 className="flex items-center gap-2 text-[16px] font-bold text-[#1d1b2b]">
          <Num n={1} />
          정규 수업 {p.weeklyCount ? <span className="text-[14px] font-normal text-[#6b6880]">(주 {p.weeklyCount}회)</span> : null}
        </h3>
        <p className="mt-3 text-[13.5px] text-[#1d1b2b]">수업 요일</p>
        <div className="mt-1.5">
          <DayChips slots={p.slots} onToggleDay={p.onToggleDay} small />
        </div>
        <div className="mt-3 grid grid-cols-[64px_1fr] gap-x-2 gap-y-2">
          <span className="pt-2.5 text-[13.5px] text-[#1d1b2b]">수업 시간</span>
          <div className="space-y-2">
            {p.slots.length === 0 && <p className="pt-2.5 text-[13px] text-[#9a97a8]">요일을 먼저 고르세요</p>}
            {p.slots.map((s) => (
              <div key={s.weekday} className="flex items-center gap-3">
                <span className="w-12 text-[13.5px] text-[#1d1b2b]">{WEEKDAY_KO[s.weekday]}요일</span>
                <TimeSelect value={s.time} onChange={(t) => p.onDayTime(s.weekday, t)} label={`${WEEKDAY_KO[s.weekday]}요일 수업 시간`} small />
              </div>
            ))}
          </div>
        </div>
        {zl && <p className="mt-2 text-[12.5px] text-[#6b6880]">{zl}</p>}
        {p.slotErr && p.slots.length > 0 && <p className="mt-1.5 text-[13px] text-[#b3261e]">{p.slotErr}</p>}
      </section>

      <section className="rounded-[14px] border border-[#e6e3ef] bg-white p-4">
        <h3 className="flex items-center gap-2 text-[16px] font-bold text-[#1d1b2b]">
          <Num n={2} />첫 수업일
        </h3>
        <div className="mt-3">
          <FirstDateInput firstDate={p.firstDate} onFirstDate={p.onFirstDate} small />
        </div>
        <div className="mt-2">
          <PlanStatus plan={p.plan} issues={p.issues} weeks={p.weeks} small />
        </div>
        {p.warnings.map((w) => (
          <p key={w} className="mt-1.5 text-[12.5px] text-[#9a5b00]">
            {w}
          </p>
        ))}
      </section>

      <section className="rounded-[14px] border border-[#e6e3ef] bg-white p-4">
        <h3 className="flex items-center gap-2 text-[16px] font-bold text-[#1d1b2b]">
          <Num n={3} />
          특정 수업 날짜 변경 <span className="text-[14px] font-normal text-[#6b6880]">(선택)</span>
        </h3>
        <p className="mt-2 text-[13.5px] leading-snug text-[#6b6880]">
          특정 주만 다른 날짜로 진행할 경우에만
          <br />
          변경하세요. (변경권 차감 없음)
        </p>
        <button
          type="button"
          disabled={!ready}
          onClick={() => setSheet(true)}
          className="mt-3 flex min-h-[46px] w-full items-center justify-center gap-2 rounded-[12px] border-[1.5px] border-[#7d5ffb] bg-white text-[15px] font-bold text-[#4b33c4] disabled:opacity-40"
        >
          <PenIcon />
          특정 수업 날짜 변경{changedCount(p.plan) > 0 ? ` · ${changedCount(p.plan)}건` : ''}
        </button>
      </section>

      <section className="rounded-[14px] border border-[#e6e3ef] bg-white">
        <button type="button" aria-expanded={preview} disabled={!ready} onClick={() => setPreview((v) => !v)} className="flex min-h-[52px] w-full items-center gap-2.5 px-4 text-left disabled:opacity-50">
          <CalIcon />
          <span className="text-[15px] font-semibold text-[#1d1b2b]">수업 일정 미리보기</span>
          {ready && <span className="text-[13.5px] text-[#6b6880]">(총 {p.plan!.lessons.length}회)</span>}
          {bad > 0 && <span className="text-[13px] font-semibold text-[#b3261e]">문제 {bad}건</span>}
          <span className="flex-1" />
          <span aria-hidden className={`text-[18px] text-[#1d1b2b] transition-transform ${preview ? 'rotate-180' : ''}`}>
            ⌄
          </span>
        </button>
        {preview && ready && (
          <div className="border-t border-[#f0eef6] px-1 pb-3 pt-2">
            <PreviewRows plan={p.plan!} issues={p.issues} tutor={p.tutor} all />
            <div className="px-3">
              <PeriodBox plan={p.plan!} slots={p.slots} weeks={p.weeks} />
            </div>
          </div>
        )}
      </section>
      {sheet && p.plan && <ChangeSheet plan={p.plan} issues={p.issues} tutor={p.tutor} onEdit={p.onEdit} onClose={() => setSheet(false)} />}
    </div>
  );
}

/** 4단계 최종 확인: 실제 등록될 수업 목록 (바꾼 날짜 강조) */
export function FinalLessons({ plan, tutor }: { plan: LessonPlan; tutor: RegTutor | null }) {
  return (
    <div className="mt-3 rounded-[12px] border border-[#e6e3ef]">
      <p className="flex items-center gap-2 px-3 pt-3 text-[15px] font-bold text-[#1d1b2b]">
        등록될 수업 {plan.lessons.length}회
        {changedCount(plan) > 0 && <span className="rounded-full bg-[#fff1dc] px-2 py-0.5 text-[12.5px] font-semibold text-[#9a5b00]">변경 {changedCount(plan)}건</span>}
      </p>
      <div className="pt-1">
        <PreviewRows plan={plan} issues={[]} tutor={tutor} all />
      </div>
    </div>
  );
}
