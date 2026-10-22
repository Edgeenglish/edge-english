'use client';

// 기존 학생 간단 입력 (D-52, 정책 원본 H23(3), 2026-10-22 대표 승인)
// - 지금 수업 중인 학생: 이름·강사·요일·시각·수업 길이·지금 수강 종료일 → 시작일(기본 오늘)~종료일 정규 수업
// - 확정된 미래 보강(선택): 날짜·시각·길이·강사 → 그날 하나만 (같은 요일·시각을 매주 막지 않음)
// - 지난 수업·변경권·보강 권리·결제는 옮기지 않음 (종료 때까지 시트). 학생에게 아무것도 보내지 않음
// - 휴대폰·PC 한 화면: 위에서 아래로 채우고 맨 아래 [저장]. 충돌은 저장 전에 날짜별로 보여 주고, DB가 다시 확인

import Link from 'next/link';
import { useMemo, useState } from 'react';
import { addDays, instantToKstDate } from '@/lms/rules/dates';
import { DURATIONS, emptyImport, IMPORT_REASON_TEXT, importIssues, importLessons, importPayload, importProblems, type ImportDraft, type ImportMakeup } from '@/lms/admin/import';
import type { ImportConflict, ImportResult } from '@/lms/admin/import-live';
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
};

const WEEK_ORDER = [1, 2, 3, 4, 5, 6, 0];
const CONFLICT_TEXT: Record<string, string> = IMPORT_REASON_TEXT;

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

export default function ImportStudent({ nowIso, demo, tutors, save }: Props) {
  const now = useMemo(() => new Date(nowIso), [nowIso]);
  const today = instantToKstDate(now);
  const [d, setD] = useState<ImportDraft>(() => emptyImport(today));
  const [requestId, setRequestId] = useState(newRequestId);
  const [saving, setSaving] = useState(false);
  const [result, setResult] = useState<ImportResult | null>(null);
  const [tried, setTried] = useState(false);

  const set = <K extends keyof ImportDraft>(k: K, v: ImportDraft[K]) => {
    setD((x) => ({ ...x, [k]: v }));
    setResult(null);
  };
  const setSlot = (i: number, patch: Partial<ImportDraft['slots'][number]>) => set('slots', d.slots.map((s, j) => (j === i ? { ...s, ...patch } : s)));
  const setMakeup = (i: number, patch: Partial<ImportMakeup>) => set('makeups', d.makeups.map((m, j) => (j === i ? { ...m, ...patch } : m)));
  const tutorName = (id: string) => tutors.find((t) => t.id === id)?.name ?? '';

  const problems = importProblems(d);
  const lessons = useMemo(() => importLessons(d), [d]);
  const issues = useMemo(() => importIssues(lessons, tutors), [lessons, tutors]);
  const regular = lessons.filter((l) => l.kind === 'regular');
  const makeups = lessons.filter((l) => l.kind === 'makeup');
  const blockers = [...problems, ...(regular.length === 0 && d.endDate && problems.length === 0 ? ['시작일~종료일 사이에 정규 수업이 없어요. 요일·날짜를 확인해 주세요.'] : [])];
  const saved = result?.kind === 'saved';

  async function submit() {
    setTried(true);
    if (blockers.length > 0 || issues.length > 0 || saving) return;
    setSaving(true);
    try {
      setResult(await save(requestId, importPayload(d)));
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
    window.scrollTo({ top: 0 });
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
          • {dayLabel(c.date)} {c.time} {c.kind === 'regular' ? '정규' : '보강'} · {CONFLICT_TEXT[c.reason] ?? c.reason}
          {c.other && c.other !== '이번 입력' ? ` (${c.other})` : ''}
        </li>
      ))}
    </ul>
  );

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
        <b className="text-[17px] text-[#1d1b2b]">기존 학생 간단 입력</b>
        <span className="flex-1" />
        <Link href={demo ? '/lms/admin?demo=1' : '/lms/admin'} aria-label="닫기" className="flex h-10 w-10 items-center justify-center text-[22px] text-[#1d1b2b]">
          ×
        </Link>
      </header>

      <main className="mx-auto grid max-w-[760px] gap-4 px-4 pt-4 lg:px-7">
        <div className="hidden lg:block">
          <h1 className="text-[22px] font-bold text-[#1d1b2b]">기존 학생 간단 입력</h1>
        </div>
        {demo && <p className="rounded-[12px] bg-[#fff8d6] px-4 py-2.5 text-[13.5px] text-[#5c4a00]">가상 데이터 미리보기예요. 저장을 눌러도 실제로 저장되지 않아요.</p>}
        <p className="rounded-[12px] bg-white px-4 py-3 text-[13.5px] leading-relaxed text-[#6b6880]">
          지금 수업 중인 학생의 <b className="text-[#1d1b2b]">고정 시간표</b>만 넣어요. 시작일부터 지금 수강 종료일까지 수업이 만들어지고, 학생·강사에게는 아무것도 보내지 않아요.
          지난 수업·변경권·결제는 시트에 그대로 두고, 재등록 때 정식 등록해요. 처음 시작하는 학생은{' '}
          <Link href={demo ? '/lms/admin/students/new?demo=1' : '/lms/admin/students/new'} className="font-semibold text-[#5b3fe0] underline underline-offset-2">
            신규 등록
          </Link>
          으로.
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
                  <div key={i} className="flex items-center gap-2">
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
          </div>
        </Card>

        <Card title="3. 확정된 보강 (선택)">
          <p className="mb-2 text-[13px] text-[#6b6880]">앞으로 잡혀 있는 보강만 넣어요. 그날 하나만 들어가고, 같은 요일·시각을 매주 막지 않아요.</p>
          <div className="grid gap-3">
            {d.makeups.map((m, i) => (
              <div key={i} className="grid gap-2 rounded-[12px] border border-[#e6e3ef] p-3">
                <div className="flex items-center">
                  <b className="text-[14px] text-[#1d1b2b]">보강 {i + 1}{m.date ? ` · ${dayLabel(m.date)}` : ''}</b>
                  <span className="flex-1" />
                  {!saved && (
                    <button type="button" onClick={() => set('makeups', d.makeups.filter((_, j) => j !== i))} className="min-h-[36px] rounded-[8px] px-2 text-[13px] text-[#b3261e]">
                      빼기
                    </button>
                  )}
                </div>
                <div className="grid grid-cols-2 gap-2">
                  <Field label="날짜">
                    <input id={`imp-mk-date-${i}`} type="date" value={m.date} min={d.fromDate} disabled={saved} onChange={(e) => setMakeup(i, { date: e.target.value })} className={inputCls(saved, tried && !m.date)} />
                  </Field>
                  <Field label="한국 시각">
                    <input id={`imp-mk-time-${i}`} type="time" step={300} value={m.time} disabled={saved} onChange={(e) => setMakeup(i, { time: e.target.value })} className={inputCls(saved, tried && !m.time)} />
                  </Field>
                </div>
                <Chips value={m.durationMin} options={DURATIONS} label={(v) => `${v}분`} onPick={(v) => !saved && setMakeup(i, { durationMin: v })} />
                <Field label="보강 강사">{tutorSelect(m.tutorId, (v) => setMakeup(i, { tutorId: v }), `imp-mk-tutor-${i}`)}</Field>
              </div>
            ))}
            {!saved && (
              <button
                type="button"
                onClick={() => set('makeups', [...d.makeups, { date: '', time: '', durationMin: d.durationMin ?? 50, tutorId: d.tutorId }])}
                className="min-h-[44px] rounded-[10px] border border-dashed border-[#cfc4ff] bg-white text-[14px] text-[#5b3fe0]"
              >
                + 보강 추가
              </button>
            )}
          </div>
        </Card>

        <Card title="4. 확인 · 저장">
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
            <dt className="text-[#6b6880]">만들어질 수업</dt>
            <dd className="text-[#1d1b2b]">
              {regular.length > 0 ? `정규 ${regular.length}회 (${dayLabel(regular[0].date)} – ${dayLabel(regular[regular.length - 1].date)})` : '정규 0회'}
              {makeups.length > 0 && ` + 보강 ${makeups.length}회`}
            </dd>
          </dl>
          {regular.length > 0 && regular[0].date !== d.fromDate && (
            <p className="mt-2 text-[12.5px] text-[#6b6880]">시작일은 수업 요일이 아니라 첫 수업이 {dayLabel(regular[0].date)}이에요.</p>
          )}

          {tried && blockers.length > 0 && (
            <ul className="mt-3 grid gap-1 rounded-[10px] bg-[#fdecec] px-3 py-2 text-[13px] text-[#b3261e]">
              {blockers.map((b) => (
                <li key={b}>• {b}</li>
              ))}
            </ul>
          )}
          {issues.length > 0 && (
            <div className="mt-3 rounded-[10px] bg-[#fdecec] px-3 py-2.5 text-[13.5px] text-[#b3261e]">
              <b>일정 충돌 {issues.length}건 — 이대로는 저장할 수 없어요.</b>
              {issueList(issues.map((x) => ({ date: x.lesson.date, time: x.lesson.time, kind: x.lesson.kind, reason: x.reason, other: x.other })))}
              <p className="mt-1.5 text-[12.5px] text-[#6b6880]">시트의 실제 시간표와 다르면 시트를 먼저 확인해 주세요. 상대 학생 시간표가 틀렸다면 그 학생부터 고쳐요.</p>
            </div>
          )}

          {result?.kind === 'error' && (
            <div className="mt-3 rounded-[10px] bg-[#fdecec] px-3 py-2.5 text-[13.5px] text-[#b3261e]">
              저장하지 못했어요 — 아무것도 저장되지 않았어요. {result.message}
              {result.conflicts && issueList(result.conflicts.map((c: ImportConflict) => ({ ...c, kind: c.kind === 'regular' ? 'regular' : 'makeup' })))}
            </div>
          )}
          {result?.kind === 'preview' && (
            <p className="mt-3 rounded-[10px] bg-[#fff8d6] px-3 py-2.5 text-[13.5px] text-[#5c4a00]">미리보기라 저장하지 않았어요. 실제 화면에서는 한 번에 저장되고, 성공했을 때만 &lsquo;입력 완료&rsquo;가 보여요.</p>
          )}
          {result?.kind === 'saved' ? (
            <div className="mt-3 rounded-[12px] bg-[#e3f6ea] px-4 py-3 text-[14px] text-[#1e7a46]">
              <b className="text-[16px]">✓ 입력 완료 · {result.studentCode}</b>
              <p className="mt-1">
                정규 {result.lessons}회{result.makeups > 0 ? ` + 보강 ${result.makeups}회` : ''} 만들었어요. 학생·강사에게는 아무것도 보내지 않았어요.
                {result.repeated && ' (이미 저장된 요청이라 새로 만들지 않았어요)'}
              </p>
              <button type="button" onClick={startNew} className="mt-2 min-h-[44px] w-full rounded-[10px] bg-white text-[14.5px] font-bold text-[#1d1b2b]">
                다음 학생 입력
              </button>
            </div>
          ) : (
            <button
              type="button"
              disabled={saving || (tried && (blockers.length > 0 || issues.length > 0))}
              onClick={submit}
              className="mt-4 min-h-[52px] w-full rounded-[12px] bg-[#7d5fff] text-[16px] font-bold text-white disabled:bg-[#cfc4ff]"
            >
              {saving ? '저장 중…' : '저장'}
            </button>
          )}
        </Card>
      </main>
    </div>
  );
}
