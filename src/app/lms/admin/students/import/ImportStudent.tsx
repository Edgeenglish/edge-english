'use client';

// 기존 학생 입력 (D-52, 정책 원본 H23(3) → 확대판 H26, 2026-10-24 대표 결정 6가지)
// - 지금 수업 중인 학생: 이름·강사·요일·시각·수업 길이·지금 수강 종료일 → 시작일(기본 오늘)~종료일 정규 수업
// - 미완료 보강: 예약됨/미예약 + 원래 수업 날짜(모르면 '날짜 확인 필요'). 원래 날짜가 시작일 이후면 그날 정규는 안 만듦
// - 지금 28일 기간·그 기간 남은 변경권, 시트 숫자(총 수업 수·진행·차감된 수)와 남은 수업 대조 — 달라도 저장
// - 저장 뒤 [시트와 같음 · 대조 완료] → 확인 시각·담당자 기록. 안 누르면 대시보드 처리할 일에 남음
// - LMS 전환일은 비워 둠 (시트로 계속 관리, 학생 상세에서 나중에). 결제·지난 수업 기록은 옮기지 않음. 학생에게 아무것도 보내지 않음
// - 휴대폰·PC 한 화면: 위에서 아래로 채우고 맨 아래 [저장]. 경고·충돌은 그 입력칸 바로 아래, DB가 다시 확인

import Link from 'next/link';
import { useMemo, useState } from 'react';
import { addDays, instantToKstDate, weekdayOf } from '@/lms/rules/dates';
import {
  DURATIONS, emptyImport, IMPORT_REASON_TEXT, importCount, importIssues, importLessons, importPayload, importPeriods, importProblems, importWarnings,
  newMakeup, regularRows, type ImportDraft, type ImportExtra, type ImportIssue, type ImportMakeup, type ImportWeeks,
} from '@/lms/admin/import';
import type { ImportConflict, ImportResult } from '@/lms/admin/import-live';
import { creditsPerPeriod } from '@/lms/rules/policy';
import { newRequestId, type RegTutor } from '@/lms/admin/registration';
import { dayLabel, diffFromKst, WEEKDAY_KO } from '@/lms/admin/schedule';
import { searchZones, zoneName } from '@/lms/admin/places';
import { AdminHeader } from '../../ui';
import { Card, Field, inputCls, nowLocal, SearchPick } from '../new/parts';

type Props = {
  nowIso: string;
  demo: boolean;
  tutors: RegTutor[];
  save: (requestId: string, payload: ReturnType<typeof importPayload>) => Promise<ImportResult>;
  /** 저장 뒤 강사 일정 다시 읽기 (방금 넣은 학생 수업이 다음 입력의 충돌 검사에 들어가게) */
  reload?: () => Promise<void>;
  /** 시트와 대조 완료 기록 (미리보기에는 없음) */
  markChecked?: (enrollmentId: string) => Promise<void>;
};

const WEEK_ORDER = [1, 2, 3, 4, 5, 6, 0];
const CONFLICT_TEXT: Record<string, string> = IMPORT_REASON_TEXT;
const KIND_TEXT: Record<string, string> = { regular: '정규', makeup: '보강', migrated_makeup: '보강', extra: '추가', migrated_extra: '추가' };
const WEEKS: ImportWeeks[] = [4, 12, 24];
const WEEKS_TEXT: Record<ImportWeeks, string> = { 4: '1개월(4주)', 12: '3개월(12주)', 24: '6개월(24주)' };
function openPicker(e: React.MouseEvent) {
  const el = e.target as HTMLInputElement;
  if (el.tagName !== 'INPUT' || (el.type !== 'date' && el.type !== 'time') || el.disabled) return;
  try {
    el.showPicker?.();
  } catch {
    /* 지원하지 않는 브라우저는 기본 동작 그대로 */
  }
}
const numOrNull = (v: string) => (/^\d+$/.test(v.trim()) ? Number(v.trim()) : null);
const Note = ({ tone, children }: { tone: 'warn' | 'info' | 'bad' | 'ok'; children: React.ReactNode }) => (
  <p
    className={`mt-1.5 rounded-[10px] px-3 py-2 text-[13px] ${
      { warn: 'bg-[#fff8d6] text-[#5c4a00]', info: 'bg-[#e9f4ff] text-[#1b5a8a]', bad: 'bg-[#fdecec] text-[#b3261e]', ok: 'bg-[#e3f6ea] text-[#1e7a46]' }[tone]
    }`}
  >
    {children}
  </p>
);

function Chips<T extends string | number>({ value, options, label, onPick }: { value: T | null; options: readonly T[]; label: (v: T) => string; onPick: (v: T) => void }) {
  return (
    <div className="flex flex-wrap gap-1.5">
      {options.map((o) => (
        <button
          key={String(o)}
          type="button"
          onClick={() => onPick(o)}
          aria-pressed={value === o}
          className={`min-h-[40px] min-w-[52px] rounded-[10px] border px-3 text-[14px] ${value === o ? 'border-[#7d5fff] bg-[#efebff] font-bold text-[#5b3fe0]' : 'border-[#e6e3ef] bg-white text-[#1d1b2b]'}`}
        >
          {label(o)}
        </button>
      ))}
    </div>
  );
}

export default function ImportStudent({ nowIso, demo, tutors, save, reload, markChecked }: Props) {
  const now = useMemo(() => new Date(nowIso), [nowIso]);
  const today = instantToKstDate(now);
  const [d, setD] = useState<ImportDraft>(() => emptyImport(today));
  const [requestId, setRequestId] = useState(newRequestId);
  const [saving, setSaving] = useState(false);
  const [result, setResult] = useState<ImportResult | null>(null);
  const [tried, setTried] = useState(false);
  const [checked, setChecked] = useState<'no' | 'saving' | 'yes'>('no');
  const [checkError, setCheckError] = useState<string | null>(null);

  const set = <K extends keyof ImportDraft>(k: K, v: ImportDraft[K]) => {
    setD((x) => ({ ...x, [k]: v }));
    setResult(null);
  };
  const setSlot = (i: number, patch: Partial<ImportDraft['slots'][number]>) => set('slots', d.slots.map((s, j) => (j === i ? { ...s, ...patch } : s)));
  const setMakeup = (i: number, patch: Partial<ImportMakeup>) => set('makeups', d.makeups.map((m, j) => (j === i ? { ...m, ...patch } : m)));
  const setExtra = (i: number, patch: Partial<ImportExtra>) => set('extras', d.extras.map((x, j) => (j === i ? { ...x, ...patch } : x)));
  const tutorName = (id: string) => tutors.find((t) => t.id === id)?.name ?? '';

  const problems = importProblems(d);
  const lessons = useMemo(() => importLessons(d), [d]);
  const issues = useMemo(() => importIssues(lessons, tutors), [lessons, tutors]);
  const regular = lessons.filter((l) => l.kind === 'regular');
  const rows = useMemo(() => regularRows(d), [d]);
  const count = importCount(d);
  const periods = importPeriods(d);
  const warn = importWarnings(d);
  const granted = d.slots.length > 0 ? creditsPerPeriod(d.slots.length) : 0;
  const blockers = [...problems, ...(regular.length === 0 && d.endDate && problems.length === 0 ? ['시작일~종료일 사이에 정규 수업이 없어요. 요일·날짜를 확인해 주세요.'] : [])];
  const saved = result?.kind === 'saved';
  const diff = count.diff ?? 0;

  async function submit() {
    setTried(true);
    if (blockers.length > 0 || issues.length > 0 || saving) return;
    setSaving(true);
    try {
      const r = await save(requestId, importPayload(d));
      setResult(r);
      if (r.kind === 'saved') await reload?.();
    } catch (e) {
      setResult({ kind: 'error', message: e instanceof Error ? e.message : '저장하지 못했어요.' });
    } finally {
      setSaving(false);
    }
  }
  function startNew() {
    setD(emptyImport(today));
    setRequestId(newRequestId());
    setResult(null);
    setTried(false);
    setChecked('no');
    setCheckError(null);
    window.scrollTo({ top: 0 });
  }
  async function confirmChecked(enrollmentId: string) {
    setChecked('saving');
    setCheckError(null);
    try {
      await markChecked?.(enrollmentId);
      setChecked('yes');
    } catch (e) {
      setChecked('no');
      setCheckError(e instanceof Error ? e.message : '기록하지 못했어요.');
    }
  }

  const tutorSelect = (value: string, onChange: (v: string) => void, id: string) => (
    <select id={id} value={value} onChange={(e) => onChange(e.target.value)} className={inputCls(saved, tried && !value)}>
      <option value="">강사 고르기</option>
      {tutors.map((t) => (
        <option key={t.id} value={t.id}>
          {t.name} ({t.country})
        </option>
      ))}
    </select>
  );

  const issueList = (list: { date: string; time: string; kind: string; reason: string; other?: string | null }[]) => (
    <ul className="mt-1.5 grid gap-1 text-[13.5px] text-[#1d1b2b]">
      {list.map((c, i) => (
        <li key={i}>
          • {dayLabel(c.date)} {c.time} {KIND_TEXT[c.kind] ?? c.kind} · {CONFLICT_TEXT[c.reason] ?? c.reason}
          {c.other && c.other !== '이번 입력' ? ` (${c.other})` : ''}
        </li>
      ))}
    </ul>
  );

  // 충돌은 그 입력 줄 바로 아래에 (휴대폰에서 맨 아래까지 내려가지 않게). 같은 이유·상대는 날짜를 한 줄로 묶음
  const inline = (list: ImportIssue[]) => {
    if (list.length === 0) return null;
    const groups = new Map<string, string[]>();
    for (const x of list) {
      const k = `${CONFLICT_TEXT[x.reason] ?? x.reason}${x.other && x.other !== '이번 입력' ? ` (${x.other})` : ''}`;
      groups.set(k, [...(groups.get(k) ?? []), dayLabel(x.lesson.date)]);
    }
    return (
      <ul className="mt-1.5 grid gap-1 rounded-[10px] bg-[#fdecec] px-3 py-2 text-[13px] text-[#b3261e]">
        {[...groups].map(([k, days]) => (
          <li key={k}>
            ⚠ {k} · {days.join(', ')}
          </li>
        ))}
      </ul>
    );
  };

  return (
    <div className="min-h-dvh bg-[#f6f5fb] pb-16">
      <div className="hidden lg:block">
        <AdminHeader
          active="students"
          demo={demo}
          right={
            <Link href={demo ? '/lms/admin?demo=1' : '/lms/admin'} className="min-h-[40px] rounded-[10px] border border-[#e6e3ef] px-4 py-2 text-[14px] text-[#1d1b2b]">
              목록으로
            </Link>
          }
        />
      </div>
      <header className="sticky top-0 z-10 flex items-center gap-2 border-b border-[#e6e3ef] bg-white px-4 py-3 lg:hidden">
        <b className="text-[17px] text-[#1d1b2b]">기존 학생 입력</b>
        <span className="flex-1" />
        <Link href={demo ? '/lms/admin?demo=1' : '/lms/admin'} aria-label="닫기" className="flex h-10 w-10 items-center justify-center text-[22px] text-[#1d1b2b]">
          ×
        </Link>
      </header>

      {/* 날짜·시각 칸은 PC에서도 휴대폰처럼 칸 아무 곳이나 누르면 고르는 창이 열림 */}
      <main className="mx-auto grid max-w-[760px] gap-4 px-4 pt-4 lg:px-7" onClick={openPicker}>
        <div className="hidden lg:block">
          <h1 className="text-[22px] font-bold text-[#1d1b2b]">기존 학생 입력</h1>
        </div>
        {demo && <p className="rounded-[12px] bg-[#fff8d6] px-4 py-2.5 text-[13.5px] text-[#5c4a00]">가상 데이터 미리보기예요. 저장을 눌러도 실제로 저장되지 않아요.</p>}
        <p className="text-[13.5px] text-[#6b6880]">
          수업 중인 학생의 시간표·남은 수업·변경권·미완료 보강을 넣어요. 넣은 뒤에도 전환 전까지는 시트로 관리하고, 학생·강사에게는 보내지 않아요. 새 학생은{' '}
          <Link href={demo ? '/lms/admin/students/new?demo=1' : '/lms/admin/students/new'} className="font-semibold text-[#5b3fe0] underline underline-offset-2">
            신규 등록
          </Link>
        </p>

        <Card title="1. 학생">
          <div className="grid grid-cols-2 gap-3">
            <Field label="한글 이름" problem={tried && !d.nameKo.trim() ? '필요해요' : undefined}>
              <input id="imp-name-ko" value={d.nameKo} disabled={saved} onChange={(e) => set('nameKo', e.target.value)} className={inputCls(saved, tried && !d.nameKo.trim())} />
            </Field>
            <Field label="영문 이름" problem={tried && !d.nameEn.trim() ? '필요해요' : undefined}>
              <input id="imp-name-en" value={d.nameEn} disabled={saved} onChange={(e) => set('nameEn', e.target.value)} className={inputCls(saved, tried && !d.nameEn.trim())} />
            </Field>
            <Field label="이메일 (선택)" full>
              <input id="imp-email" type="email" inputMode="email" value={d.email} disabled={saved} onChange={(e) => set('email', e.target.value)} className={inputCls(saved)} />
            </Field>
            <Field label="휴대폰 (선택)" full>
              <input id="imp-phone" type="tel" inputMode="tel" value={d.phone} disabled={saved} onChange={(e) => set('phone', e.target.value)} className={inputCls(saved)} />
            </Field>
            <Field wide label="사는 곳 시간대">
              <SearchPick
                value={d.timezone ? zoneName(d.timezone) : ''}
                locked={saved}
                placeholder="예: 서울, 시드니, Sydney"
                search={(q) => {
                  const r = searchZones(q);
                  const sub = (z: string) => `${z} · 지금 ${nowLocal(z, now)} · ${diffFromKst(now, z)}`;
                  return [
                    { items: r.rows.map((x) => ({ key: x.timezone, main: zoneName(x.timezone), sub: sub(x.timezone), pick: () => set('timezone', x.timezone) })) },
                    { label: '그 밖의 시간대 (영어 이름)', items: r.more.map((z) => ({ key: z, main: z, sub: sub(z), pick: () => set('timezone', z) })) },
                  ];
                }}
              />
              {d.timezone && (
                <span className="mt-1 block text-[12.5px] text-[#6b6880]">
                  {d.timezone} · 지금 {nowLocal(d.timezone, now)} · {diffFromKst(now, d.timezone)}
                </span>
              )}
            </Field>
            <Field wide label="운영 메모 (선택, 강사에게 안 보임)">
              <input id="imp-memo" value={d.memo} disabled={saved} onChange={(e) => set('memo', e.target.value)} className={inputCls(saved)} />
            </Field>
          </div>
        </Card>

        <Card title="2. 정규 수업">
          <div className="grid gap-3">
            <Field label="담당 강사">{tutorSelect(d.tutorId, (v) => set('tutorId', v), 'imp-tutor')}</Field>
            <div>
              <span className="mb-1 block text-[13px] text-[#6b6880]">수업 길이</span>
              <Chips value={d.durationMin} options={DURATIONS} label={(v) => `${v}분`} onPick={(v) => !saved && set('durationMin', v)} />
            </div>
            <div>
              <span className="mb-1 block text-[13px] text-[#6b6880]">요일 · 한국 시각 (주 {d.slots.length}회)</span>
              <div className="grid gap-2">
                {d.slots.map((s, i) => (
                  <div key={i}>
                    <div className="flex items-center gap-2">
                    <select
                      id={`imp-slot-day-${i}`}
                      aria-label={`${i + 1}번째 요일`}
                      value={s.weekday}
                      disabled={saved}
                      onChange={(e) => setSlot(i, { weekday: Number(e.target.value) })}
                      className={`${inputCls(saved)} !w-[92px] shrink-0`}
                    >
                      {WEEK_ORDER.map((w) => (
                        <option key={w} value={w}>
                          {WEEKDAY_KO[w]}요일
                        </option>
                      ))}
                    </select>
                    <input
                      id={`imp-slot-time-${i}`}
                      aria-label={`${i + 1}번째 시각`}
                      type="time"
                      step={300}
                      value={s.time}
                      disabled={saved}
                      onChange={(e) => setSlot(i, { time: e.target.value })}
                      className={`${inputCls(saved, tried && !s.time)} min-w-0 flex-1`}
                    />
                    {d.slots.length > 1 && !saved && (
                      <button type="button" aria-label={`${i + 1}번째 요일 빼기`} onClick={() => set('slots', d.slots.filter((_, j) => j !== i))} className="h-11 w-11 shrink-0 rounded-[10px] border border-[#e6e3ef] bg-white text-[18px] text-[#6b6880]">
                        −
                      </button>
                    )}
                    </div>
                    {inline(issues.filter((x) => x.lesson.kind === 'regular' && weekdayOf(x.lesson.date) === s.weekday && x.lesson.time === s.time))}
                  </div>
                ))}
                {d.slots.length < 5 && !saved && (
                  <button
                    type="button"
                    onClick={() => set('slots', [...d.slots, { weekday: WEEK_ORDER.find((w) => !d.slots.some((s) => s.weekday === w)) ?? 1, time: d.slots[0]?.time ?? '' }])}
                    className="min-h-[44px] rounded-[10px] border border-dashed border-[#cfc4ff] bg-white text-[14px] text-[#5b3fe0]"
                  >
                    + 요일 추가
                  </button>
                )}
              </div>
            </div>
            <div className="grid grid-cols-2 gap-3">
              <Field label="시작일 (이날부터 수업 생성)">
                <input id="imp-from" type="date" value={d.fromDate} min={addDays(today, -7)} disabled={saved} onChange={(e) => set('fromDate', e.target.value || today)} className={inputCls(saved)} />
              </Field>
              <Field label="지금 수강 종료일" problem={tried && !d.endDate ? '필요해요' : undefined}>
                <input id="imp-end" type="date" value={d.endDate} min={d.fromDate} disabled={saved} onChange={(e) => set('endDate', e.target.value)} className={inputCls(saved, tried && !d.endDate)} />
              </Field>
            </div>
            {!saved && (
              <div className="flex flex-wrap items-center gap-1.5">
                <span className="text-[12.5px] text-[#6b6880]">종료일 빠르게:</span>
                {WEEKS.map((w) => (
                  <button
                    key={w}
                    type="button"
                    onClick={() => set('endDate', addDays(d.fromDate, w * 7 - 1))}
                    aria-pressed={d.endDate === addDays(d.fromDate, w * 7 - 1)}
                    className={`min-h-[36px] rounded-[10px] border px-3 text-[13px] ${d.endDate === addDays(d.fromDate, w * 7 - 1) ? 'border-[#7d5fff] bg-[#efebff] font-bold text-[#5b3fe0]' : 'border-[#e6e3ef] bg-white text-[#1d1b2b]'}`}
                  >
                    {w}주 뒤
                  </button>
                ))}
              </div>
            )}
            {warn.endDate && <Note tone="warn">{warn.endDate}</Note>}
          </div>
        </Card>

        <Card title="3. 미완료 보강">
          <p className="mb-2 text-[13px] text-[#6b6880]">아직 안 끝난 보강 전부 (예약됨 · 미예약). 지난 보강은 넣지 않아요.</p>
          <div className="grid gap-3">
            {d.makeups.map((m, i) => {
              const originIsRegular = !!m.originalDate && rows.some((r) => r.date === m.originalDate);
              return (
                <div key={i} className="grid gap-2 rounded-[12px] border border-[#e6e3ef] p-3">
                  <div className="flex items-center">
                    <b className="text-[14px] text-[#1d1b2b]">
                      보강 {i + 1}
                      {m.status === 'booked' && m.date ? ` · ${dayLabel(m.date)}` : ''}
                    </b>
                    <span className="flex-1" />
                    {!saved && (
                      <button type="button" onClick={() => set('makeups', d.makeups.filter((_, j) => j !== i))} className="min-h-[36px] rounded-[8px] px-2 text-[13px] text-[#b3261e]">
                        빼기
                      </button>
                    )}
                  </div>
                  <Chips<'booked' | 'open'> value={m.status} options={['booked', 'open']} label={(v) => (v === 'booked' ? '예약됨' : '미예약')} onPick={(v) => !saved && setMakeup(i, { status: v })} />
                  <div>
                    <span className="mb-1 block text-[13px] text-[#6b6880]">원래 수업 날짜 (어느 수업이 취소돼서 생긴 보강인지)</span>
                    <div className="flex items-center gap-2">
                      <input
                        id={`imp-mk-orig-${i}`}
                        aria-label={`보강 ${i + 1} 원래 수업 날짜`}
                        type="date"
                        value={m.originalDate}
                        disabled={saved || m.originUnknown}
                        onChange={(e) => setMakeup(i, { originalDate: e.target.value, originUnknown: false })}
                        className={`${inputCls(saved || m.originUnknown, tried && !m.originalDate && !m.originUnknown)} min-w-0 flex-1`}
                      />
                      <button
                        type="button"
                        aria-pressed={m.originUnknown}
                        disabled={saved}
                        onClick={() => setMakeup(i, { originUnknown: !m.originUnknown, originalDate: '' })}
                        className={`min-h-[44px] shrink-0 rounded-[10px] border px-3 text-[13px] ${m.originUnknown ? 'border-[#7d5fff] bg-[#efebff] font-bold text-[#5b3fe0]' : 'border-[#e6e3ef] bg-white text-[#1d1b2b]'}`}
                      >
                        날짜 확인 필요
                      </button>
                    </div>
                    {m.originUnknown && <Note tone="info">시트에서 원래 날짜를 알 수 없을 때만. 저장 뒤 대시보드에서 나중에 넣을 수 있어요.</Note>}
                    {originIsRegular && <Note tone="info">{dayLabel(m.originalDate as string)} 정규 수업은 만들지 않아요 (이미 취소된 원래 수업)</Note>}
                    {warn.origins[i] && <Note tone="warn">{warn.origins[i]}</Note>}
                  </div>
                  {m.status === 'booked' ? (
                    <>
                      <div className="grid grid-cols-2 gap-2">
                        <Field label="보강 날짜">
                          <input id={`imp-mk-date-${i}`} type="date" value={m.date} min={d.fromDate} disabled={saved} onChange={(e) => setMakeup(i, { date: e.target.value })} className={inputCls(saved, tried && !m.date)} />
                        </Field>
                        <Field label="한국 시각">
                          <input id={`imp-mk-time-${i}`} type="time" step={300} value={m.time} disabled={saved} onChange={(e) => setMakeup(i, { time: e.target.value })} className={inputCls(saved, tried && !m.time)} />
                        </Field>
                      </div>
                      <Chips value={m.durationMin} options={DURATIONS} label={(v) => `${v}분`} onPick={(v) => !saved && setMakeup(i, { durationMin: v })} />
                      <Field label="보강 강사">{tutorSelect(m.tutorId, (v) => setMakeup(i, { tutorId: v }), `imp-mk-tutor-${i}`)}</Field>
                      {inline(issues.filter((x) => x.lesson.kind === 'makeup' && x.lesson.date === m.date && x.lesson.time === m.time))}
                    </>
                  ) : (
                    <p className="text-[12.5px] text-[#6b6880]">날짜는 나중에 보강 잡을 때. 강사 시간은 막지 않아요.</p>
                  )}
                </div>
              );
            })}
            {!saved && (
              <div className="grid grid-cols-2 gap-2">
                <button type="button" onClick={() => set('makeups', [...d.makeups, newMakeup(d, 'booked')])} className="min-h-[44px] rounded-[10px] border border-dashed border-[#cfc4ff] bg-white text-[14px] text-[#5b3fe0]">
                  + 예약된 보강
                </button>
                <button type="button" onClick={() => set('makeups', [...d.makeups, newMakeup(d, 'open')])} className="min-h-[44px] rounded-[10px] border border-dashed border-[#cfc4ff] bg-white text-[14px] text-[#5b3fe0]">
                  + 미예약 보강
                </button>
              </div>
            )}
          </div>
        </Card>

        <Card title="4. 지금 수강기간 · 변경권">
          <div className="grid gap-3">
            <div>
              <span className="mb-1 block text-[13px] text-[#6b6880]">상품</span>
              <Chips<ImportWeeks> value={d.weeks} options={WEEKS} label={(w) => WEEKS_TEXT[w]} onPick={(w) => !saved && setD((x) => ({ ...x, weeks: w, periodIdx: x.periodIdx && x.periodIdx > w / 4 ? null : x.periodIdx }))} />
              {tried && !d.weeks && <span className="mt-1 block text-[12px] text-[#b3261e]">필요해요</span>}
            </div>
            {d.weeks && (
              <div>
                <span className="mb-1 block text-[13px] text-[#6b6880]">지금 몇 번째 기간</span>
                <Chips value={d.periodIdx} options={Array.from({ length: d.weeks / 4 }, (_, i) => i + 1)} label={(i) => `${i}기간`} onPick={(i) => !saved && set('periodIdx', i)} />
                {tried && !d.periodIdx && <span className="mt-1 block text-[12px] text-[#b3261e]">필요해요</span>}
              </div>
            )}
            <div className="grid grid-cols-2 gap-3">
              <Field label="이 기간 시작일" problem={tried && !d.periodStart ? '필요해요' : undefined}>
                <input id="imp-period-start" type="date" value={d.periodStart} disabled={saved} onChange={(e) => set('periodStart', e.target.value)} className={inputCls(saved, tried && !d.periodStart)} />
              </Field>
              <div>
                <span className="mb-1 block text-[13px] text-[#6b6880]">이 기간 끝 (28일)</span>
                <p className="flex min-h-[44px] items-center rounded-[10px] border border-[#e6e3ef] bg-[#f6f5fb] px-3 text-[15px] text-[#1d1b2b]">
                  {periods.find((p) => p.state === 'now') ? dayLabel(periods.find((p) => p.state === 'now')!.end) : '-'}
                </p>
              </div>
            </div>
            {warn.period && <Note tone="warn">{warn.period}</Note>}
            <div>
              <span className="mb-1 block text-[13px] text-[#6b6880]">이 기간 남은 변경권 (주 {d.slots.length}회 → 기간마다 {granted}개)</span>
              <Chips value={d.creditsLeft} options={Array.from({ length: granted + 1 }, (_, i) => i)} label={(i) => `${i}개`} onPick={(i) => !saved && set('creditsLeft', i)} />
              {tried && d.creditsLeft === null && <span className="mt-1 block text-[12px] text-[#b3261e]">필요해요</span>}
            </div>
            {periods.length > 0 && (
              <ul className="grid gap-1.5">
                {periods.map((p) => (
                  <li
                    key={p.index}
                    className={`grid grid-cols-[auto_1fr_auto] items-center gap-2 rounded-[10px] border px-3 py-2 text-[13.5px] ${
                      p.state === 'now' ? 'border-[#7d5fff] bg-[#efebff]' : p.state === 'past' ? 'border-[#e6e3ef] bg-[#f6f5fb] text-[#6b6880]' : 'border-[#e6e3ef]'
                    }`}
                  >
                    <b>{p.index}기간</b>
                    <span className="tabular-nums">
                      {dayLabel(p.start)} – {dayLabel(p.end)}
                    </span>
                    <span className="text-right tabular-nums">{p.state === 'past' ? '지난 기간 · 시트' : p.state === 'now' ? `남은 ${p.credits}/${granted}` : `${granted}개 새로 지급`}</span>
                  </li>
                ))}
              </ul>
            )}
          </div>
        </Card>

        <Card title="5. 남은 수업 대조">
          <div className="grid gap-3">
            <div className="grid grid-cols-2 gap-3">
              <Field label="시트 총 수업 수" problem={tried && d.sheetTotal === null ? '필요해요' : undefined}>
                <input id="imp-sheet-total" type="number" inputMode="numeric" min={0} value={d.sheetTotal ?? ''} disabled={saved} onChange={(e) => set('sheetTotal', numOrNull(e.target.value))} className={inputCls(saved, tried && d.sheetTotal === null)} />
              </Field>
              <Field label="이미 진행·차감된 수" problem={tried && d.sheetUsed === null ? '필요해요' : undefined}>
                <input id="imp-sheet-used" type="number" inputMode="numeric" min={0} value={d.sheetUsed ?? ''} disabled={saved} onChange={(e) => set('sheetUsed', numOrNull(e.target.value))} className={inputCls(saved, tried && d.sheetUsed === null)} />
              </Field>
            </div>
            <p className="-mt-1 text-[12.5px] text-[#6b6880]">회차 번호가 아니라 수업 상태(Class Status)가 진행·차감인 줄 수예요.</p>
            <p className="overflow-x-auto whitespace-nowrap rounded-[8px] bg-[#f6f5fb] px-3 py-2 text-[12.5px] tabular-nums text-[#1d1b2b]">
              정규 {count.regular}
              {count.origin + count.skipped > 0 && ` (자동 ${count.candidates}${count.origin ? ` − 취소된 원래 수업 ${count.origin}` : ''}${count.skipped ? ` − 뺀 수업 ${count.skipped}` : ''})`} + 보강 예약 {count.booked} + 미예약 {count.open}
              {count.extra > 0 && ` + 추가 ${count.extra}`} = <b>{count.lmsLeft}</b>
            </p>
            {count.sheetLeft !== null &&
              (diff === 0 ? (
                <Note tone="ok">
                  ✓ 시트 남은 {count.sheetLeft}회 = 만들 수업 {count.lmsLeft}회
                </Note>
              ) : diff > 0 ? (
                <Note tone="bad">
                  만들 수업이 시트보다 {diff}회 많아요. 아래 목록에서 뺄 정규 수업을 고르세요 (보통 이미 취소했거나 옮긴 수업). 그대로 저장해도 돼요.
                </Note>
              ) : (
                <Note tone="warn">
                  만들 수업이 시트보다 {-diff}회 적어요. 종료일·요일을 먼저 확인하고, 맞으면 아래 [+ 수업 날짜 추가]나 3번의 [+ 미예약 보강]으로 채우세요. 그대로 저장해도 돼요.
                </Note>
              ))}
            {d.extras.map((x, i) => (
              <div key={i} className="grid gap-2 rounded-[12px] border border-[#e6e3ef] p-3">
                <div className="flex items-center">
                  <b className="text-[14px] text-[#1d1b2b]">추가 수업 {i + 1}{x.date ? ` · ${dayLabel(x.date)}` : ''}</b>
                  <span className="flex-1" />
                  {!saved && (
                    <button type="button" onClick={() => set('extras', d.extras.filter((_, j) => j !== i))} className="min-h-[36px] rounded-[8px] px-2 text-[13px] text-[#b3261e]">
                      빼기
                    </button>
                  )}
                </div>
                <div className="grid grid-cols-2 gap-2">
                  <Field label="날짜">
                    <input id={`imp-ex-date-${i}`} type="date" value={x.date} min={d.fromDate} disabled={saved} onChange={(e) => setExtra(i, { date: e.target.value })} className={inputCls(saved, tried && !x.date)} />
                  </Field>
                  <Field label="한국 시각">
                    <input id={`imp-ex-time-${i}`} type="time" step={300} value={x.time} disabled={saved} onChange={(e) => setExtra(i, { time: e.target.value })} className={inputCls(saved, tried && !x.time)} />
                  </Field>
                </div>
                <Field label="근거 (예: 시트 18회차 · 이월 1회)" problem={tried && !x.reason.trim() ? '필요해요' : undefined}>
                  <input id={`imp-ex-reason-${i}`} value={x.reason} disabled={saved} onChange={(e) => setExtra(i, { reason: e.target.value })} className={inputCls(saved, tried && !x.reason.trim())} />
                </Field>
                <p className="text-[12.5px] text-[#6b6880]">실제로 받아야 하는 수업만. 그날 하나만 만들어요 ({tutorName(d.tutorId) || '담당 강사'} · {d.durationMin ?? '-'}분).</p>
                {inline(issues.filter((y) => y.lesson.kind === 'extra' && y.lesson.date === x.date && y.lesson.time === x.time))}
              </div>
            ))}
            {!saved && (
              <button
                type="button"
                onClick={() => set('extras', [...d.extras, { date: '', time: d.slots[0]?.time ?? '', reason: '' }])}
                className="min-h-[44px] rounded-[10px] border border-dashed border-[#cfc4ff] bg-white text-[14px] text-[#5b3fe0]"
              >
                + 수업 날짜 추가
              </button>
            )}
            {rows.length > 0 && (
              <details open={diff > 0 || d.skipDates.length > 0}>
                <summary className="flex min-h-[40px] cursor-pointer items-center text-[13px] font-semibold text-[#5b3fe0]">만들어질 정규 수업 {count.candidates}개 보기</summary>
                <ul className="mt-1 grid max-h-[320px] gap-1 overflow-y-auto">
                  {rows.map((r) => (
                    <li
                      key={r.date}
                      className={`flex min-h-[40px] items-center gap-2 rounded-[9px] border border-[#e6e3ef] px-3 text-[13.5px] ${r.state === 'keep' ? 'text-[#1d1b2b]' : 'bg-[#f6f5fb] text-[#6b6880] line-through'}`}
                    >
                      <span className="tabular-nums">
                        {dayLabel(r.date)} {r.time}
                      </span>
                      <span className="flex-1" />
                      {r.state === 'origin' ? (
                        <span className="text-[12px] no-underline">취소된 원래 수업</span>
                      ) : (
                        (diff > 0 || r.state === 'skip') &&
                        !saved && (
                          <label className="flex min-h-[36px] items-center gap-1.5 text-[12.5px] text-[#b3261e]">
                            <input
                              type="checkbox"
                              className="h-5 w-5"
                              checked={r.state === 'skip'}
                              onChange={(e) => set('skipDates', e.target.checked ? [...d.skipDates, r.date] : d.skipDates.filter((x) => x !== r.date))}
                            />
                            빼기
                          </label>
                        )
                      )}
                    </li>
                  ))}
                </ul>
              </details>
            )}
          </div>
        </Card>

        <Card title="6. 확인 · 저장">
          <dl className="grid grid-cols-[auto_1fr] gap-x-3 gap-y-1.5 text-[14px]">
            <dt className="text-[#6b6880]">학생</dt>
            <dd className="text-[#1d1b2b]">{d.nameKo || '-'} {d.nameEn && `(${d.nameEn})`}</dd>
            <dt className="text-[#6b6880]">강사</dt>
            <dd className="text-[#1d1b2b]">{tutorName(d.tutorId) || '-'}</dd>
            <dt className="text-[#6b6880]">정규</dt>
            <dd className="text-[#1d1b2b]">
              {d.slots.filter((s) => s.time).map((s) => `${WEEKDAY_KO[s.weekday]} ${s.time}`).join(' · ') || '-'}
              {d.durationMin ? ` · ${d.durationMin}분` : ''}
            </dd>
            <dt className="text-[#6b6880]">남은 수업</dt>
            <dd className="tabular-nums text-[#1d1b2b]">
              {count.lmsLeft}회
              {count.sheetLeft !== null && (diff === 0 ? ` (시트 ${count.sheetLeft}회 ✓)` : <b className="text-[#b3261e]"> (시트 {count.sheetLeft}회 · {diff > 0 ? '+' : ''}{diff})</b>)}
            </dd>
            <dt className="text-[#6b6880]">종료일</dt>
            <dd className="text-[#1d1b2b]">{d.endDate ? dayLabel(d.endDate) : '-'}</dd>
            <dt className="text-[#6b6880]">지금 기간</dt>
            <dd className="text-[#1d1b2b]">{d.weeks && d.periodIdx ? `${d.periodIdx}/${d.weeks / 4}기간 · 변경권 ${d.creditsLeft ?? '-'}/${granted} 남음` : '-'}</dd>
            <dt className="text-[#6b6880]">보강</dt>
            <dd className="text-[#1d1b2b]">
              예약 {count.booked} · 미예약 {count.open}
              {d.makeups.some((m) => m.originUnknown) && ` · 날짜 확인 필요 ${d.makeups.filter((m) => m.originUnknown).length}`}
            </dd>
            <dt className="text-[#6b6880]">LMS 전환</dt>
            <dd className="text-[#1d1b2b]">아직 시트로 관리 (전환일은 학생 상세에서 나중에)</dd>
          </dl>

          {tried && blockers.length > 0 && (
            <ul className="mt-3 grid gap-1 rounded-[10px] bg-[#fdecec] px-3 py-2 text-[13px] text-[#b3261e]">
              {blockers.map((b) => (
                <li key={b}>• {b}</li>
              ))}
            </ul>
          )}
          {issues.length > 0 && (
            <p className="mt-3 rounded-[10px] bg-[#fdecec] px-3 py-2.5 text-[13.5px] font-bold text-[#b3261e]">일정 충돌 {issues.length}건 · 위 빨간 표시를 고쳐 주세요</p>
          )}

          {result?.kind === 'error' && (
            <div className="mt-3 rounded-[10px] bg-[#fdecec] px-3 py-2.5 text-[13.5px] text-[#b3261e]">
              <b>저장 안 됨</b> · {result.message}
              {result.conflicts && issueList(result.conflicts.map((c: ImportConflict) => ({ ...c })))}
            </div>
          )}
          {result?.kind === 'preview' && (
            <p className="mt-3 rounded-[10px] bg-[#fff8d6] px-3 py-2.5 text-[13.5px] text-[#5c4a00]">미리보기라 저장하지 않았어요. 실제 화면에서는 한 번에 저장되고, 성공했을 때만 &lsquo;입력 완료&rsquo;와 시트 대조가 보여요.</p>
          )}
          {result?.kind === 'saved' ? (
            <div className="mt-3 grid gap-3">
              <div className="rounded-[12px] bg-[#e3f6ea] px-4 py-3 text-[14px] text-[#1e7a46]">
                <b className="text-[16px]">✓ 입력 완료 · {result.studentCode}</b>
                <p className="mt-1">
                  남은 수업 {result.lmsLeft}회 (정규 {result.lessons} · 보강 예약 {result.makeups} · 미예약 {result.openMakeups}
                  {result.extras > 0 ? ` · 추가 ${result.extras}` : ''}). 학생·강사에게는 아무것도 보내지 않았어요. 시트로 계속 관리해요.
                  {result.repeated && ' (이미 저장된 요청이라 새로 만들지 않았어요)'}
                </p>
              </div>
              <div className="rounded-[12px] border border-[#e6e3ef] px-4 py-3">
                <b className="text-[15px] text-[#1d1b2b]">시트와 1회 대조</b>
                <ul className="mt-2 grid gap-1 text-[13.5px] text-[#1d1b2b]">
                  <li>• 남은 수업 {result.lmsLeft}회 {result.lmsLeft === result.sheetLeft ? `= 시트 ${result.sheetLeft}회` : <b className="text-[#b3261e]">≠ 시트 {result.sheetLeft}회</b>}</li>
                  <li>• 다음 수업 {regular[0] ? `${dayLabel(regular[0].date)} ${regular[0].time}` : '-'} · 종료일 {d.endDate ? dayLabel(d.endDate) : '-'}</li>
                  <li>• {d.periodIdx}기간 변경권 {d.creditsLeft}/{granted}</li>
                  <li>• 보강 예약 {count.booked} · 미예약 {count.open}</li>
                </ul>
                {checked === 'yes' ? (
                  <Note tone="ok">✓ 대조 완료로 기록했어요 (오늘 · 내 계정). 이 학생은 다시 묻지 않아요.</Note>
                ) : demo ? (
                  <Note tone="warn">미리보기에서는 대조 완료를 기록하지 않아요.</Note>
                ) : (
                  <>
                    <button
                      type="button"
                      disabled={checked === 'saving'}
                      onClick={() => confirmChecked(result.enrollmentId)}
                      className="mt-2 min-h-[48px] w-full rounded-[10px] bg-[#7d5fff] text-[15px] font-bold text-white disabled:bg-[#cfc4ff]"
                    >
                      {checked === 'saving' ? '기록 중…' : '시트와 같음 · 대조 완료'}
                    </button>
                    <p className="mt-1.5 text-[12.5px] text-[#6b6880]">지금 확인하지 못하면 그냥 다음으로 넘어가세요. 대시보드 처리할 일에 &lsquo;시트 대조&rsquo;로 남아요.</p>
                  </>
                )}
                {checkError && <Note tone="bad">{checkError}</Note>}
              </div>
              <button type="button" onClick={startNew} className="min-h-[44px] w-full rounded-[10px] border border-[#e6e3ef] bg-white text-[14.5px] font-bold text-[#1d1b2b]">
                다음 학생 입력
              </button>
            </div>
          ) : (
            <>
              {count.sheetLeft !== null && diff !== 0 && (
                <p className="mt-3 text-[13px] text-[#b3261e]">차이 {Math.abs(diff)}회는 저장 뒤 대시보드 처리할 일(시트 대조)에 남아요.</p>
              )}
              <button
                type="button"
                disabled={saving || (tried && (blockers.length > 0 || issues.length > 0))}
                onClick={submit}
                className={`mt-3 min-h-[52px] w-full rounded-[12px] text-[16px] font-bold text-white disabled:bg-[#cfc4ff] ${count.sheetLeft !== null && diff !== 0 ? 'bg-[#b7791f]' : 'bg-[#7d5fff]'}`}
              >
                {saving ? '저장 중…' : count.sheetLeft !== null && diff !== 0 ? `차이 ${Math.abs(diff)}회 그대로 저장` : '저장'}
              </button>
            </>
          )}
        </Card>
      </main>
    </div>
  );
}
