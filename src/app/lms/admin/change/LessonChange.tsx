'use client';

// 수업 변경·보강 (1순위, migration 1700) — 카톡·WhatsApp 요청을 운영진이 대신 처리
// 카드: 1 학생 · 2 수업(실제 예정 수업 목록에서 고름) · 3 변경(요청한 사람·요청 받은 시각 → DB 미리 보기 → [변경])
//       · 4 안내(학생·강사 각각 [복사] → 보낸 뒤 [보냄], 누른 버튼은 회색으로 남음) · 5 보강(신청 → 강사 확인 → [확정]) · 6 변경 기록([되돌리기])
// 판정(6시간·변경권·공휴일·보강 기한)과 중복 방지는 DB 함수 하나 — 화면 미리 보기와 저장 결과가 같음

import { createContext, useCallback, useContext, useEffect, useMemo, useRef, useState } from 'react';
import DateInput from '../DateInput';
import { useSavingGuard } from '../useSavingGuard';
import { markOrphans, reconcileStored, setPendingHref } from '@/lms/admin/pending-saves';
import { formatInZone, instantToKstDate, kstToInstant, type KstDate } from '@/lms/rules/dates';
import { newRequestId } from '@/lms/admin/registration';
import { sentLabel } from '@/lms/admin/confirm';
import {
  changeableLessons, dateLabel, makeupLink, tutorLocalLabel, decisionLines, emailStatusText, EVENT_TEXT, kstLabel, lessonTag, makeupRights, MAKEUP_SLOTS_MAX, STATUS_SHORT, studentNotice, tutorNotice,
  type ChangeDecision, type ChLesson, type ChNotice, type ChStudent, type MakeupRight, type NoticeContext,
} from '@/lms/admin/lesson-change';
import type { AdminCredits, StudentLessonData } from '@/lms/admin/lesson-change-live';
import { AdminHeader } from '../ui';
import TimeInput from '../TimeInput';
import { Card, inputCls } from '../students/new/parts';

export type ChangeActions = {
  load: (studentId: string) => Promise<StudentLessonData>;
  change: (requestId: string, lessonId: string, who: 'student' | 'tutor', requestedAt: Date, dryRun: boolean) => Promise<ChangeDecision>;
  revert: (changeId: string, note: string) => Promise<void>;
  requestMakeup: (source: { lessonId?: string; itemId?: string; compId?: string }, slots: Date[]) => Promise<{ repeated: boolean }>;
  confirmMakeup: (requestId: string, at: Date) => Promise<void>;
  /** 이미 진행한 보강 기록 (지난 시각만, 사유 필수). 없는 화면(가상 데이터)은 버튼 안 보임 */
  recordPastMakeup?: (source: { lessonId?: string; itemId?: string }, at: Date, note: string) => Promise<void>;
  withdrawMakeup: (requestId: string) => Promise<void>;
  voidMakeup: (lessonId: string, note: string) => Promise<void>;
  markSent: (noticeId: string) => Promise<void>;
  /** 자동 메일 다시 보내기 (20261108010000). 없는 화면(가상 데이터)은 버튼 안 보임 */
  resendEmail?: (noticeId: string) => Promise<{ status: string; error: string | null; repeated: boolean }>;
  /** 변경권 (4500): 읽기·수동 조정(±1, 사유 필수). 4500 전 DB 면 loadCredits 가 null */
  loadCredits?: (studentId: string) => Promise<AdminCredits | null>;
  adjustCredit?: (studentId: string, delta: 1 | -1, reason: string) => Promise<{ before: number; after: number }>;
};

const btnMain = 'min-h-[44px] rounded-[10px] bg-[#7d5ffb] px-4 text-[14.5px] font-bold text-white disabled:bg-[#cfc4ff]';
const btnSub = 'min-h-[44px] rounded-[10px] border border-[#e6e3ef] bg-white px-3.5 text-[14px] text-[#1d1b2b] disabled:text-[#b9b6c8]';
/** 누른 버튼: 회색으로 꽉 차게 (눌린 티, 2026-10-27 대표) */
const btnDone = 'min-h-[44px] rounded-[10px] border border-[#c9c6d6] bg-[#d9d6e3] px-3.5 text-[14px] font-bold text-[#4a4760]';
const Err = ({ children }: { children: React.ReactNode }) => (children ? <p className="mt-1.5 text-[13px] text-[#b3261e]">{children}</p> : null);

async function copyText(text: string): Promise<boolean> {
  try {
    await navigator.clipboard.writeText(text);
    return true;
  } catch {
    return false;
  }
}
const kstParts = (at: Date) => ({ date: instantToKstDate(at), time: formatInZone(at, 'Asia/Seoul').time });
/** 존재하지 않는 날짜(2/30 등)는 null — 입력란 오류로만 보이고 화면이 멈추지 않게 (QA-16) */
function safeInstant(date: string, time: string): Date | null {
  try {
    return kstToInstant(date, time);
  } catch {
    return null;
  }
}

/** 저장 중인 카드 수 (R-20): 하나라도 저장 중이면 화면을 떠나기 전에 확인 */
const SavingCtx = createContext<(d: 1 | -1) => void>(() => {});
/** useState(false) 대신 — 바뀔 때 저장 중 수를 위에 알림 */
function useBusyState(): [boolean, (b: boolean) => void] {
  const report = useContext(SavingCtx);
  const [busy, set] = useState(false);
  const ref = useRef(false);
  const setBusy = useCallback((b: boolean) => { if (b !== ref.current) { ref.current = b; report(b ? 1 : -1); } set(b); }, [report]);
  useEffect(() => () => { if (ref.current) { ref.current = false; report(-1); } }, [report]);
  return [busy, setBusy];
}

export default function LessonChange({ students, actions, nowIso, initialCode }: { students: ChStudent[]; actions: ChangeActions; nowIso: string; initialCode?: string }) {
  const [saving, setSaving] = useState(0);
  const reportSaving = useCallback((d: 1 | -1) => setSaving((n) => Math.max(0, n + d)), []);
  useSavingGuard(saving > 0, '아직 저장 중이에요. 지금 이동하면 처리 결과를 확인할 수 없어요. 그래도 이동할까요?');
  const [student, setStudent] = useState<ChStudent | null>(() => students.find((s) => s.code === initialCode) ?? null);
  const [q, setQ] = useState('');
  const [data, setData] = useState<StudentLessonData | null>(null);
  const [loadErr, setLoadErr] = useState('');
  const [lessonId, setLessonId] = useState<string | null>(null);
  const [credits, setCredits] = useState<AdminCredits | null>(null);
  /** 방금 저장한 수업 취소 결과 (QA B-03): 카드가 닫혀도 무엇이 저장됐는지 보이게 */
  const [canceled, setCanceled] = useState<string | null>(null);
  const now = useMemo(() => new Date(nowIso), [nowIso]);

  const reload = useCallback(async () => {
    if (!student) return;
    try {
      setLoadErr('');
      const d = await actions.load(student.id);
      setData(d);
      // 응답 없던·화면이 닫혔던 저장을 서버 자료로 판정 (R-20)
      const base = {
        changes: d.changes.map((c) => ({ id: c.id, status: c.status })),
        lessons: d.lessons.map((l) => ({ id: l.id, state: l.state, voided: l.voided })),
        requests: d.makeupRequests.map((r) => ({ id: r.id, status: r.status, sourceLessonId: r.sourceLessonId, migratedItemId: r.migratedItemId, compensationId: r.compensationId, requestedAt: null })),
        notices: d.notices.map((n) => ({ id: n.id, status: n.status })),
        studentId: student.id,
      };
      reconcileStored(base);
      if (actions.loadCredits) {
        const cr = await actions.loadCredits(student.id).catch(() => null);
        setCredits(cr);
        if (cr) reconcileStored({ ...base, creditUses: cr.uses.map((u) => ({ reason: u.reason, note: u.note, at: u.at, delta: u.delta })) });
      }
    } catch (e) {
      setLoadErr(e instanceof Error ? e.message : '불러오지 못했어요.');
    }
  }, [student, actions]);
  useEffect(() => {
    setData(null);
    setLessonId(null);
    setCanceled(null);
    markOrphans();
    if (student) setPendingHref(`/lms/admin/change?student=${encodeURIComponent(student.code)}`);
    reload();
  }, [reload, student]);

  const found = useMemo(() => {
    const t = q.trim().toLowerCase();
    if (!t) return [];
    return students.filter((s) => s.nameKo.includes(t) || s.nameEn.toLowerCase().includes(t) || s.code.toLowerCase().includes(t)).slice(0, 8);
  }, [q, students]);

  const lessons = data?.lessons ?? [];
  const byId = useMemo(() => new Map(lessons.map((l) => [l.id, l])), [lessons]);
  const choices = changeableLessons(lessons, now);
  const lesson = lessonId ? byId.get(lessonId) ?? null : null;
  const rights = data ? makeupRights(lessons, data.migrated, data.makeupRequests, data.compensations ?? []) : [];
  const lastTutor = [...lessons].reverse().find((l) => !l.voided) ?? null;

  function ctxFor(n: ChNotice): NoticeContext | null {
    if (!student || !data?.enrollment) return null;
    const base = { student, durationMin: data.enrollment.durationMin };
    if (n.changeRequestId) {
      const c = data.changes.find((x) => x.id === n.changeRequestId);
      const l = c ? byId.get(c.lessonId) : undefined;
      if (!c || !l) return null;
      const voided = n.event === 'revert' ? lessons.filter((x) => x.makeupOf === l.id && x.voided).pop() : undefined;
      // 취소 안내는 보내는 시점의 보강 상태에 맞게 (추가 요청 6): 신청 전 / 신청 중 / 강사 답 / 전부 불가 / 확정
      const req = [...data.makeupRequests].reverse().find((x) => !x.compensationId && x.sourceLessonId === l.id && ['requested', 'countered', 'confirmed'].includes(x.status));
      const made = req?.confirmedLessonId ? byId.get(req.confirmedLessonId) : undefined;
      const makeup: NoticeContext['makeup'] = !req ? { state: 'none' }
        : req.status === 'confirmed' ? (made && made.state !== 'canceled' ? { state: 'confirmed', at: made.startsAt } : { state: 'none' })
        : !req.tutorAnsweredAt ? { state: 'requested', candidates: req.candidates }
        : req.candidates.every((t) => req.tutorAnswers?.[+t] === 'no') ? { state: 'declined', candidates: req.candidates }
        : { state: 'tutor_answered', candidates: req.candidates };
      return { ...base, lesson: l, decision: c.decision, makeupAt: voided?.startsAt, tutorName: l.tutorName, tutorTz: l.tutorTz, makeup };
    }
    const r = data.makeupRequests.find((x) => x.id === n.makeupRequestId);
    if (!r) return null;
    const src = r.sourceLessonId ? byId.get(r.sourceLessonId) : undefined;
    const item = r.migratedItemId ? data.migrated.find((m) => m.id === r.migratedItemId) : undefined;
    const made = r.confirmedLessonId ? byId.get(r.confirmedLessonId) : undefined;
    const t = made ?? src ?? lastTutor;
    return {
      ...base, lesson: src, originalDate: item?.originalDate ?? null, candidates: r.candidates, makeupAt: made?.startsAt,
      tutorName: t?.tutorName ?? '', tutorTz: t?.tutorTz ?? 'Asia/Seoul', compensation: !!r.compensationId,
    };
  }

  // 복사 안내가 필요 없어진 줄(not_needed)도 자동 메일이 걸려 있으면 보여 줌 (강사가 직접 확정한 보강의 강사 메일 상태)
  const notices = (data?.notices ?? []).filter((n) => n.status !== 'not_needed' || n.email);
  const shownNotices = [
    ...notices.filter((n) => n.status === 'pending' || (n.email && n.email.status !== 'sent')),
    ...notices.filter((n) => n.status !== 'pending' && !(n.email && n.email.status !== 'sent')).reverse().slice(0, 4),
  ];

  return (
    <SavingCtx.Provider value={reportSaving}>
    <div className="pb-24">
      <AdminHeader active="students" demo={false} />
      {/* 저장 중 안내 (R-20): 이 동안 홈·메뉴로 이동하면 확인창 */}
      {saving > 0 && <p role="status" className="sticky top-[57px] z-10 bg-[#fff8d6] px-4 py-2 text-center text-[13.5px] font-semibold text-[#5c4a00]">저장 중이에요… 끝날 때까지 이 화면에 있어 주세요.</p>}
      <main className="mx-auto grid max-w-[720px] gap-3 px-4 py-4">
        <h1 className="text-[20px] font-extrabold text-[#1d1b2b]">수업 변경·보강</h1>

        <Card title="1. 학생">
          {student ? (
            <div className="flex items-center gap-2">
              <b className="flex-1 text-[16px] text-[#1d1b2b]">
                {student.nameKo} <span className="text-[13px] font-normal text-[#6b6880]">{student.code} · {student.nameEn}</span>
              </b>
              <button type="button" className={btnSub} onClick={() => setStudent(null)}>
                다른 학생
              </button>
            </div>
          ) : (
            <>
              <input aria-label="학생 검색" value={q} onChange={(e) => setQ(e.target.value)} placeholder="이름·영문 이름·학생 번호" className={inputCls(false)} />
              <ul className="mt-1.5 grid gap-1">
                {found.map((s) => (
                  <li key={s.id}>
                    <button type="button" onClick={() => { setStudent(s); setQ(''); }} className="min-h-[44px] w-full rounded-[10px] px-3 py-2 text-left text-[15px] text-[#1d1b2b] hover:bg-[#efebff]">
                      {s.nameKo} <span className="text-[13px] text-[#6b6880]">{s.code} · {s.nameEn}</span>
                    </button>
                  </li>
                ))}
                {q.trim() && found.length === 0 && <li className="px-3 py-2 text-[13.5px] text-[#6b6880]">없음</li>}
              </ul>
            </>
          )}
          <Err>{loadErr}</Err>
        </Card>

        {student && data && (
          <>
            {credits?.period && actions.adjustCredit && (
              <CreditsCard credits={credits} adjust={(d, r) => actions.adjustCredit!(student.id, d, r)} done={reload} />
            )}
            <Card title="2. 수업">
              {choices.length === 0 ? (
                <p className="text-[14px] text-[#6b6880]">예정 수업 없음</p>
              ) : (
                <ul className="grid max-h-[420px] gap-1.5 overflow-y-auto">
                  {choices.map((l) => (
                    <li key={l.id}>
                      <button
                        type="button"
                        aria-pressed={l.id === lessonId}
                        onClick={() => { setLessonId(l.id === lessonId ? null : l.id); setCanceled(null); }}
                        className={`flex min-h-[48px] w-full items-center gap-2 rounded-[12px] border px-3 py-2 text-left ${l.id === lessonId ? 'border-[#7d5ffb] bg-[#efebff]' : 'border-[#e6e3ef] bg-white'}`}
                      >
                        <b className="text-[16px] text-[#1d1b2b]">{kstLabel(l.startsAt)}</b>
                        <span className="flex-1 text-right text-[13px] text-[#6b6880]">{lessonTag(l)} · {l.tutorName}</span>
                      </button>
                    </li>
                  ))}
                </ul>
              )}
            </Card>

            {lesson && (
              <ChangeCard key={lesson.id} lesson={lesson} now={now} actions={actions} isMakeup={!!data.makeupRequests.find((r) => r.confirmedLessonId === lesson.id)}
                byTutor={!!data.makeupRequests.find((r) => r.confirmedLessonId === lesson.id && r.confirmedInTutorScreen)}
                done={async (msg) => { setLessonId(null); if (msg) setCanceled(msg); await reload(); }} />
            )}
            {canceled && <p role="status" className="rounded-[12px] bg-[#e8f5ee] px-3 py-2.5 text-[14.5px] font-bold text-[#1f7a4d]">✓ {canceled}</p>}

            {shownNotices.length > 0 && (
              <Card title="안내">
                <ul className="grid gap-2">
                  {shownNotices.map((n) => {
                    const c = ctxFor(n);
                    const text = c ? (n.recipient === 'student' ? studentNotice(n.event, c) : tutorNotice(n.event, c)) : '';
                    return <NoticeRow key={n.id} n={n} text={text} markSent={async () => { await actions.markSent(n.id); await reload(); }}
                      resendEmail={actions.resendEmail && n.email && n.email.status !== 'sent' ? async () => { const r = await actions.resendEmail!(n.id); await reload(); return r; } : undefined} />;
                  })}
                </ul>
              </Card>
            )}

            {rights.length > 0 && (
              <Card title="보강">
                <ul className="grid gap-2.5">
                  {rights.map((r) => (
                    <MakeupRow key={r.key} right={r} finalEnd={data.enrollment?.finalEndDate ?? null} tutorTz={(r.kind === 'migrated' ? lastTutor : r.source ?? lastTutor)?.tutorTz ?? 'Asia/Seoul'} actions={actions} done={reload} />
                  ))}
                </ul>
              </Card>
            )}

            {data.changes.length > 0 && (
              <Card title="변경 기록">
                <ul className="grid gap-2">
                  {data.changes.slice(0, 10).map((c) => {
                    const l = byId.get(c.lessonId);
                    return l ? <HistoryRow key={c.id} change={c} lesson={l} actions={actions} done={reload} /> : null;
                  })}
                </ul>
              </Card>
            )}
          </>
        )}
      </main>
    </div>
    </SavingCtx.Provider>
  );
}

function ChangeCard({ lesson, now, actions, isMakeup, byTutor, done }: { lesson: ChLesson; now: Date; actions: ChangeActions; isMakeup: boolean; byTutor?: boolean; done: (msg?: string) => Promise<void> }) {
  const [who, setWho] = useState<'student' | 'tutor'>('student');
  const init = kstParts(now);
  const [date, setDate] = useState(init.date);
  const [time, setTime] = useState(init.time);
  const [preview, setPreview] = useState<ChangeDecision | null>(null);
  const [err, setErr] = useState('');
  const [busy, setBusy] = useBusyState();
  const [requestId] = useState(newRequestId);
  const [voiding, setVoiding] = useState(false);
  const requestedAt = date && /^\d\d:\d\d$/.test(time) ? kstToInstant(date, time) : null;

  useEffect(() => {
    setPreview(null);
    setErr('');
    if (!requestedAt) return;
    let live = true;
    actions.change(requestId, lesson.id, who, requestedAt, true).then(
      (d) => live && setPreview(d),
      (e) => live && setErr(e instanceof Error ? e.message : '판정하지 못했어요.'),
    );
    return () => {
      live = false;
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [lesson.id, who, date, time]);

  async function run(f: () => Promise<string | void>) {
    setBusy(true);
    setErr('');
    try {
      const msg = await f();
      await done(msg || undefined);
    } catch (e) {
      setErr(e instanceof Error ? e.message : '처리하지 못했어요.');
    } finally {
      setBusy(false);
    }
  }

  // 이 화면의 저장은 늘 '수업 취소' (날짜를 옮기는 것은 아래 '보강' 에서) — 버튼·제목이 실제 저장 내용을 말하게 (QA B-03)
  return (
    <Card title={`수업 취소 · ${kstLabel(lesson.startsAt)} 한국`}>
      <div className="grid gap-3">
        {byTutor && <p className="text-[13px] font-semibold text-[#1f7a4d]">강사가 확정한 보강</p>}
        <div className="grid grid-cols-2 gap-1.5" role="group" aria-label="요청한 사람">
          {(['student', 'tutor'] as const).map((w) => (
            <button key={w} type="button" aria-pressed={who === w} onClick={() => setWho(w)}
              className={`min-h-[44px] rounded-[10px] border text-[14.5px] font-semibold ${who === w ? 'border-[#7d5ffb] bg-[#efebff] text-[#5b3fe0]' : 'border-[#e6e3ef] bg-white text-[#1d1b2b]'}`}>
              {w === 'student' ? '학생 요청' : '강사 요청'}
            </button>
          ))}
        </div>
        <label className="grid gap-1 text-[13px] text-[#6b6880]">
          요청 받은 시각 (한국)
          <div className="grid grid-cols-[1.4fr_1fr] gap-1.5">
            <DateInput aria-label="요청 받은 날짜" value={date} max={init.date} onChange={setDate} className={inputCls(false)} />
            <TimeInput aria-label="요청 받은 시각" value={time} onChange={setTime} className={inputCls(false)} />
          </div>
        </label>
        {preview && (
          <ul className="grid gap-0.5 rounded-[12px] bg-[#f6f5fb] px-3 py-2.5 text-[14.5px] text-[#1d1b2b]">
            {decisionLines(preview).map((t, i) => (
              <li key={i} className={i === 0 ? 'font-bold' : ''}>{t}</li>
            ))}
          </ul>
        )}
        <Err>{err}</Err>
        <button type="button" className={btnMain} disabled={!preview || busy} onClick={() => run(async () => {
          const d = await actions.change(requestId, lesson.id, who, requestedAt!, false);
          return `${kstLabel(lesson.startsAt)} 한국 수업 취소 저장 · ${decisionLines(d).join(' · ')}`;
        })}>
          {busy ? '저장 중…' : '수업 취소 저장'}
        </button>
        {isMakeup && (
          voiding ? (
            <div className="grid grid-cols-2 gap-1.5">
              <button type="button" className={btnSub} onClick={() => setVoiding(false)}>취소</button>
              <button type="button" className={btnMain} disabled={busy} onClick={() => run(() => actions.voidMakeup(lesson.id, '운영진 정정'))}>보강 삭제</button>
            </div>
          ) : (
            <button type="button" className={btnSub} onClick={() => setVoiding(true)}>잘못 넣은 보강 삭제</button>
          )
        )}
      </div>
    </Card>
  );
}

function NoticeRow({ n, text, markSent, resendEmail }: { n: ChNotice; text: string; markSent: () => Promise<void>; resendEmail?: () => Promise<{ status: string; error: string | null; repeated: boolean }> }) {
  const [busy, setBusy] = useBusyState();
  const [err, setErr] = useState('');
  const [copied, setCopied] = useState(false);
  const [manual, setManual] = useState(false);
  const [mailMsg, setMailMsg] = useState('');
  const sent = n.status === 'sent';
  const e = n.email;
  // 자동 메일(보강 확정)은 카톡·WhatsApp 복사와 병행 (대표 2026-11-07): 메일 상태는 아래 한 줄, 실패·주소 없음만 [다시 보내기]
  const mailCls = !e ? '' : e.status === 'sent' ? 'text-[#1f7a4d]' : e.status === 'queued' ? 'text-[#6b6880]' : 'text-[#b3261e]';
  return (
    <li className="rounded-[12px] border border-[#e6e3ef] px-3 py-2.5">
      <div className="flex items-center gap-2">
        <div className="min-w-0 flex-1">
          <b className="block text-[14.5px] text-[#1d1b2b]">{n.recipient === 'student' ? '학생' : '강사'} · {EVENT_TEXT[n.event]}</b>
          {sent && n.sentAt && <span className="text-[12.5px] text-[#6b6880]">보냄 {sentLabel(n.sentAt)}</span>}
          {n.status === 'not_needed' && <span className="text-[12.5px] text-[#6b6880]">{n.recipient === 'tutor' ? '강사가 직접 확정 · WhatsApp 복사 불필요' : '복사 안내 불필요'}</span>}
        </div>
        {n.status !== 'not_needed' && (
          <button type="button" disabled={!text} className={copied ? btnDone : btnSub} onClick={async () => { if (await copyText(text)) setCopied(true); else setManual(true); }}>
            {copied ? '복사함 ✓' : '복사'}
          </button>
        )}
        {n.status === 'not_needed' ? null : sent ? (
          <button type="button" disabled className={btnDone}>보냄 ✓</button>
        ) : (
          <button type="button" disabled={busy} className={btnMain} onClick={async () => {
            setBusy(true);
            setErr('');
            try { await markSent(); } catch (e) { setErr(e instanceof Error ? e.message : '기록하지 못했어요.'); } finally { setBusy(false); }
          }}>
            보냄
          </button>
        )}
      </div>
      {e && (
        <div className="mt-1.5 flex flex-wrap items-center gap-2">
          <span className={`min-w-0 flex-1 text-[12.5px] ${mailCls}`} role="status">{e.status === 'sent' ? '✓ ' : ''}{emailStatusText(e, sentLabel)}{e.attempts > 1 ? ` · ${e.attempts}번째 시도` : ''}</span>
          {resendEmail && (e.status === 'failed' || e.status === 'no_address' || (e.status === 'queued' && e.error)) && (
            <button type="button" disabled={busy} className={`${btnSub} min-h-[36px]`} onClick={async () => {
              setBusy(true);
              setErr('');
              setMailMsg('');
              try {
                const r = await resendEmail();
                setMailMsg(r.repeated ? '이미 보낸 메일이에요.' : r.status === 'queued' && !r.error ? '다시 보냈어요. 결과는 잠시 뒤 새로고침하면 보여요.' : r.error ?? '');
              } catch (err) { setErr(err instanceof Error ? err.message : '다시 보내지 못했어요.'); } finally { setBusy(false); }
            }}>
              메일 다시 보내기
            </button>
          )}
          {mailMsg && <span className="text-[12.5px] text-[#1f7a4d]">{mailMsg}</span>}
        </div>
      )}
      <pre className="mt-2 whitespace-pre-wrap rounded-[10px] bg-[#f6f5fb] px-3 py-2 font-sans text-[13.5px] text-[#1d1b2b]">{text}</pre>
      {manual && <textarea readOnly value={text} rows={5} onFocus={(e) => e.currentTarget.select()} aria-label="복사할 글" className="mt-2 w-full rounded-[10px] border border-[#e6e3ef] p-2 text-[13.5px]" />}
      <Err>{err}</Err>
    </li>
  );
}

/** 변경권: 지금 기간 잔여·기록 + 운영진 수동 조정 (추가 요청 3, 4500). 자동 차감은 그대로, 조정은 사유 필수·한 번에 1개 */
function CreditsCard({ credits, adjust, done }: { credits: AdminCredits; adjust: (delta: 1 | -1, reason: string) => Promise<{ before: number; after: number }>; done: () => Promise<void> }) {
  const [mode, setMode] = useState<1 | -1 | null>(null);
  const [reason, setReason] = useState('');
  const [busy, setBusy] = useBusyState();
  const [err, setErr] = useState('');
  const [msg, setMsg] = useState('');
  const describeUse = (u: AdminCredits['uses'][number]) =>
    u.reason === 'student_change' ? `${u.lessonAt ? `${kstLabel(u.lessonAt)} 수업 ` : ''}취소 (자동 차감)`
    : u.reason === 'admin_restore' ? `${u.lessonAt ? `${kstLabel(u.lessonAt)} 수업 ` : ''}취소 되돌림`
    : `운영진 조정${u.note ? ` · ${u.note}` : ''}`;
  async function run() {
    if (!mode) return;
    setBusy(true);
    setErr('');
    try {
      const r = await adjust(mode, reason.trim());
      setMsg(`변경권 ${r.before}개 → ${r.after}개. 학생 화면에도 바로 반영돼요.`);
      setMode(null);
      setReason('');
      await done();
    } catch (e) {
      setErr(e instanceof Error ? e.message : '조정하지 못했어요.');
    } finally {
      setBusy(false);
    }
  }
  return (
    <Card title="변경권">
      <div className="flex items-center gap-2">
        <b className="flex-1 text-[16px] text-[#1d1b2b]">
          남은 {credits.left}개 <span className="text-[13px] font-normal text-[#6b6880]">/ 이번 기간 {credits.granted}개 ({credits.period ? `${dateLabel(credits.period.start as KstDate)}~${dateLabel(credits.period.end as KstDate)}` : ''})</span>
        </b>
        <button type="button" className={btnSub} disabled={busy || credits.left >= credits.granted} onClick={() => { setMode(1); setMsg(''); }}>+1 복구·추가</button>
        <button type="button" className={btnSub} disabled={busy || credits.left <= 0} onClick={() => { setMode(-1); setMsg(''); }}>−1 차감</button>
      </div>
      {mode && (
        <div className="mt-2 grid gap-1.5 rounded-[12px] bg-[#f6f5fb] p-3">
          <p className="text-[14px] text-[#1d1b2b]">변경권 {credits.left}개 → <b>{credits.left + mode}개</b> ({mode > 0 ? '1개 추가' : '1개 차감'}). 사유를 적어 주세요 — 조정자·시각과 함께 기록에 남아요.</p>
          <input aria-label="조정 사유" value={reason} onChange={(e) => setReason(e.target.value)} placeholder="예: 11/5 두 수업 변경에 1개만 차감하기로 사전 안내" className={inputCls(false)} />
          <div className="grid grid-cols-2 gap-1.5">
            <button type="button" className={btnSub} disabled={busy} onClick={() => setMode(null)}>취소</button>
            <button type="button" className={btnMain} disabled={busy || !reason.trim()} onClick={run}>{mode > 0 ? '+1 적용' : '−1 적용'}</button>
          </div>
        </div>
      )}
      {msg && <p className="mt-1.5 text-[13px] text-[#1f7a4d]">{msg}</p>}
      <Err>{err}</Err>
      {credits.uses.length > 0 && (
        <ul className="mt-2 grid gap-1 text-[13px] text-[#1d1b2b]">
          {credits.uses.map((u, i) => (
            <li key={i} className="flex justify-between gap-2 border-t border-[#eeecf4] pt-1">
              <span>{sentLabel(u.at)} · {describeUse(u)}</span>
              <b className={u.delta > 0 ? 'text-[#1f7a4d]' : ''}>{u.delta > 0 ? '+1' : '−1'}</b>
            </li>
          ))}
        </ul>
      )}
      <p className="mt-1.5 text-[12px] text-[#6b6880]">한도: 0개 ~ 이번 기간 지급 수량. 자동 차감 규칙(POL-CHG-01~05)은 그대로이고, 수동 조정은 예외 처리 기록용이에요.</p>
    </Card>
  );
}

function MakeupRow({ right, finalEnd, tutorTz, actions, done }: { right: MakeupRight; finalEnd: string | null; tutorTz: string; actions: ChangeActions; done: () => Promise<void> }) {
  const src = right.kind === 'migrated' ? null : right.source;
  const defTime = src ? kstParts(src.startsAt).time : '';
  const [slots, setSlots] = useState<{ date: string; time: string }[]>([{ date: '', time: defTime }]);
  const [other, setOther] = useState({ date: '', time: defTime });
  const [busy, setBusy] = useBusyState();
  const [err, setErr] = useState('');
  const [past, setPast] = useState<{ date: string; time: string; note: string } | null>(null);
  /** 방금 누른 [신청] 결과 (QA B-04): 새 신청 / 이미 열린 신청 */
  const [sent, setSent] = useState<'new' | 'repeated' | null>(null);
  const open = right.open;
  const comp = right.kind === 'compensation' ? right.comp : null;
  // 톡으로 보낼 '보강 날짜 고르기' 바로가기 (11/8 대표 B안): 학생이 누르면 이 수업 날짜 고르기가 바로 열림
  const link = makeupLink(right.kind === 'compensation' ? right.comp.id : right.kind === 'migrated' ? right.item.id : right.source.id);
  const [copied, setCopied] = useState<'ok' | 'fail' | null>(null);
  const title = comp
    ? `무료 보상수업 · ${src ? `${kstLabel(src.startsAt)} 강사 노쇼` : '강사 노쇼'}`
    : src
      ? `${kstLabel(src.startsAt)} · ${src.classStatus ? STATUS_SHORT[src.classStatus] ?? src.classStatus : ''}`
      : `보강 · 원래 ${right.kind === 'migrated' && right.item.originalDate ? dateLabel(right.item.originalDate) : '날짜 확인 필요'}`;
  // 강사 휴무 보강은 종료일 제한 없음 — 종료일 뒤로 확정되면 그 날까지 자동 연장 (A20, migration 1800)
  const leave = (right.kind === 'migrated' && right.item.tutorLeave) || src?.classStatus === 'Tutor long-term leave';
  // 보상수업 사용 기한 = 수강 종료일, 기한 안 재등록이면 다음 수강권 종료일 (4100)
  const lastDay = comp ? comp.useUntil : finalEnd;
  const until = comp ? `${dateLabel(comp.useUntil)}까지` : leave ? '강사 휴가 · 종료일 제한 없음 (뒤로 잡으면 그날까지 연장)' : finalEnd ? `${dateLabel(finalEnd)}까지` : '';
  // 날짜 입력 중(연도 '0002' 등)에는 변환하지 않음 — 완성된 날짜(2000~2099)·시각일 때만 (QA-16)
  const toAt = (s: { date: string; time: string }) => (/^20\d\d-\d\d-\d\d$/.test(s.date) && /^\d\d:\d\d$/.test(s.time) ? safeInstant(s.date, s.time) : null);
  // 한국 시각으로 넣고, 강사 현지 날짜·시각은 바로 아래 자동 표시 (2026-10-26 대표)
  const Local = ({ at }: { at: Date | null }) => {
    const t = at && tutorLocalLabel(at, tutorTz);
    return t ? <span className="text-[12.5px] text-[#6b6880]">강사 현지 {t}</span> : null;
  };

  async function run(f: () => Promise<void>) {
    setBusy(true);
    setErr('');
    try {
      await f();
      await done();
    } catch (e) {
      setErr(e instanceof Error ? e.message : '처리하지 못했어요.');
    } finally {
      setBusy(false);
    }
  }

  return (
    <li className="rounded-[12px] border border-[#e6e3ef] p-3">
      <b className="block text-[15px] text-[#1d1b2b]">{title}</b>
      <span className="text-[12.5px] text-[#6b6880]">{until}</span>
      {!open && (
        <div className="mt-2 grid gap-1">
          <button type="button" className={`${btnSub} w-fit`} onClick={async () => setCopied((await copyText(link)) ? 'ok' : 'fail')}>
            {copied === 'ok' ? '✓ 보강 링크 복사했어요' : '보강 링크 복사'}
          </button>
          {copied === 'fail' && <p className="select-all break-all rounded-[8px] bg-[#f6f5fa] px-2 py-1.5 text-[13px] text-[#1d1b2b]">{link}</p>}
        </div>
      )}
      {open ? (
        <div className="mt-2 grid gap-1.5">
          {sent && (
            <p role="status" className="rounded-[10px] bg-[#e8f5ee] px-3 py-2 text-[14px] font-bold text-[#1f7a4d]">
              {sent === 'new' ? '✓ 강사에게 확인 요청을 보냈어요. 답변 대기 중' : '이미 신청한 보강이 있어요. 아래 신청 그대로예요.'}
            </p>
          )}
          <p className="text-[13px] text-[#6b6880]">
            {open.tutorAnsweredAt ? `강사 답변 ${sentLabel(open.tutorAnsweredAt)} (한국)` : '강사 답변 대기 중'}
            {open.requestedAt ? ` · 신청 ${sentLabel(open.requestedAt)} (한국)` : ''}
            {open.via === 'student_app' ? ' · 학생이 LMS에서 신청' : open.via === 'admin_on_behalf' ? ' · 운영진 대신 신청' : ''}
          </p>
          {open.candidates.map((t) => (
            <div key={+t} className="flex items-center gap-2">
              <span className="flex-1 text-[15px] text-[#1d1b2b]">
                {kstLabel(t)} 한국
                {open.tutorAnswers?.[+t] && (
                  <b className={`ml-1.5 text-[13px] ${open.tutorAnswers[+t] === 'yes' ? 'text-[#1f7a4d]' : 'text-[#b3261e]'}`}>
                    {open.tutorAnswers[+t] === 'yes' ? '강사 가능' : '강사 불가'}
                  </b>
                )}
                <span className="block"><Local at={t} /></span>
              </span>
              {/* 강사가 불가라고 답한 시간은 확정 못 함 (QA-01 D, DB 도 거절) */}
              <button type="button" disabled={busy || open.tutorAnswers?.[+t] === 'no'} className={btnMain} title={open.tutorAnswers?.[+t] === 'no' ? '강사가 불가라고 답한 시간이에요' : undefined}
                onClick={() => run(() => actions.confirmMakeup(open.id, t))}>확정</button>
            </div>
          ))}
          {open.tutorAnsweredAt && open.candidates.length > 0 && open.candidates.every((t) => open.tutorAnswers?.[+t] === 'no') && (
            <p className="rounded-[10px] bg-[#fdecea] px-3 py-2 text-[13.5px] text-[#b3261e]">강사가 모든 날짜에 불가라고 답했어요. 강사 메모를 참고해 학생에게 다른 날짜를 받거나(카톡), 강사에게 다시 확인한 시간이 있으면 아래에 넣어 확정해 주세요. 그 시간은 강사가 Schedule에서 연 시간이어야 해요.</p>
          )}
          {open.tutorNote && <p className="rounded-[10px] bg-[#f3f1f8] px-3 py-2 text-[14px] text-[#1d1b2b]">강사 메모: {open.tutorNote}</p>}
          <div className="grid grid-cols-[1.4fr_1fr_auto] gap-1.5">
            <DateInput aria-label="다른 보강 날짜" value={other.date} onChange={(v) => setOther({ ...other, date: v })} className={inputCls(false)} />
            <TimeInput aria-label="다른 보강 시각" value={other.time} onChange={(v) => setOther({ ...other, time: v })} className={inputCls(false)} />
            <button type="button" disabled={busy || !toAt(other)} className={btnMain} onClick={() => run(() => actions.confirmMakeup(open.id, toAt(other)!))}>확정</button>
          </div>
          <Local at={toAt(other)} />
          <button type="button" disabled={busy} className={btnSub} onClick={() => run(() => actions.withdrawMakeup(open.id))}>신청 닫기</button>
        </div>
      ) : (
        <div className="mt-2 grid gap-1.5">
          {slots.map((s, i) => (
            <div key={i} className="grid gap-1">
            <div className="grid grid-cols-[1.4fr_1fr] gap-1.5">
              <DateInput aria-label={`보강 희망 날짜 ${i + 1}`} value={s.date} max={leave ? undefined : lastDay ?? undefined}
                onChange={(v) => setSlots(slots.map((x, j) => (j === i ? { ...x, date: v } : x)))} className={inputCls(false)} />
              <TimeInput aria-label={`보강 희망 시각 ${i + 1}`} value={s.time}
                onChange={(v) => setSlots(slots.map((x, j) => (j === i ? { ...x, time: v } : x)))} className={inputCls(false)} />
            </div>
            <Local at={toAt(s)} />
            </div>
          ))}
          <div className="grid grid-cols-2 gap-1.5">
            <button type="button" disabled={slots.length >= MAKEUP_SLOTS_MAX} className={btnSub} onClick={() => setSlots([...slots, { date: '', time: defTime }])}>+ 시간</button>
            <button type="button" disabled={busy || slots.every((s) => !toAt(s))} className={btnMain}
              onClick={() => run(async () => {
                setSent(null);
                const r = await actions.requestMakeup(right.kind === 'lesson' ? { lessonId: right.source.id } : right.kind === 'compensation' ? { compId: right.comp.id } : { itemId: right.item.id }, slots.map(toAt).filter((t): t is Date => !!t));
                setSent(r.repeated ? 'repeated' : 'new');
              })}>
              {busy ? '신청 중…' : '신청'}
            </button>
          </div>
        </div>
      )}
      {/* 이미 진행한 보강 기록 (2026-11-07): 강사가 먼저 진행한 보강(더블 수업 등)을 지난 시각으로 남김 → 강사 '기록할 수업'에 뜸 */}
      {!comp && actions.recordPastMakeup && (past ? (
        <div className="mt-2 grid gap-1.5 rounded-[12px] bg-[#f6f5fb] p-3">
          <b className="text-[14px] text-[#1d1b2b]">이미 진행한 보강 기록</b>
          <div className="grid grid-cols-[1.4fr_1fr] gap-1.5">
            <DateInput aria-label="진행한 보강 날짜" value={past.date} onChange={(v) => setPast({ ...past, date: v })} className={inputCls(false)} />
            <TimeInput aria-label="진행한 보강 시각" value={past.time} onChange={(v) => setPast({ ...past, time: v })} className={inputCls(false)} />
          </div>
          <span className="text-[12.5px] text-[#6b6880]">한국 시간{toAt(past) ? ` · 강사 현지 ${tutorLocalLabel(toAt(past)!, tutorTz)}` : ''}</span>
          <input aria-label="기록 사유" value={past.note} onChange={(e) => setPast({ ...past, note: e.target.value })} placeholder="사유 (예: 11/5 더블 수업으로 진행)" className={inputCls(false)} />
          <div className="grid grid-cols-2 gap-1.5">
            <button type="button" className={btnSub} disabled={busy} onClick={() => setPast(null)}>닫기</button>
            <button type="button" className={btnMain} disabled={busy || !toAt(past) || +toAt(past)! >= Date.now() || !past.note.trim()}
              onClick={() => run(async () => { await actions.recordPastMakeup!(right.kind === 'lesson' ? { lessonId: right.source.id } : { itemId: (right as { item: { id: string } }).item.id }, toAt(past)!, past.note.trim()); setPast(null); })}>
              {busy ? '저장 중…' : '기록'}
            </button>
          </div>
        </div>
      ) : (
        <button type="button" className={`${btnSub} mt-2 w-full`} onClick={() => setPast({ date: '', time: defTime, note: '' })}>이미 진행한 보강 기록</button>
      ))}
      <Err>{err}</Err>
    </li>
  );
}

function HistoryRow({ change, lesson, actions, done }: { change: StudentLessonData['changes'][number]; lesson: ChLesson; actions: ChangeActions; done: () => Promise<void> }) {
  const [asking, setAsking] = useState(false);
  const [note, setNote] = useState('');
  const [busy, setBusy] = useBusyState();
  const [err, setErr] = useState('');
  const reverted = change.status === 'reverted';
  return (
    <li className="rounded-[12px] border border-[#e6e3ef] px-3 py-2.5">
      <div className="flex items-center gap-2">
        <div className="min-w-0 flex-1">
          <b className={`block text-[14.5px] ${reverted ? 'text-[#6b6880] line-through' : 'text-[#1d1b2b]'}`}>
            {kstLabel(lesson.startsAt)} · {STATUS_SHORT[change.decision.status] ?? change.decision.status}
          </b>
          <span className="text-[12.5px] text-[#6b6880]">
            {reverted ? '되돌림 · ' : ''}요청 {change.requestedAt ? sentLabel(change.requestedAt) : '-'} · 처리 {sentLabel(change.decidedAt)}
          </span>
        </div>
        {!reverted && !asking && (
          <button type="button" className={btnSub} onClick={() => setAsking(true)}>되돌리기</button>
        )}
      </div>
      {asking && (
        <div className="mt-2 grid gap-1.5">
          <input aria-label="되돌리는 이유" value={note} onChange={(e) => setNote(e.target.value)} placeholder="이유" className={inputCls(false)} />
          <div className="grid grid-cols-2 gap-1.5">
            <button type="button" className={btnSub} onClick={() => setAsking(false)}>취소</button>
            <button type="button" disabled={busy} className={btnMain} onClick={async () => {
              setBusy(true);
              setErr('');
              try { await actions.revert(change.id, note); await done(); setAsking(false); } catch (e) { setErr(e instanceof Error ? e.message : '되돌리지 못했어요.'); } finally { setBusy(false); }
            }}>
              되돌리기
            </button>
          </div>
        </div>
      )}
      <Err>{err}</Err>
    </li>
  );
}
