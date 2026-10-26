'use client';

// 수업 변경·보강 (1순위, migration 1700) — 카톡·WhatsApp 요청을 운영진이 대신 처리
// 카드: 1 학생 · 2 수업(실제 예정 수업 목록에서 고름) · 3 변경(요청한 사람·요청 받은 시각 → DB 미리 보기 → [변경])
//       · 4 안내(학생·강사 각각 [복사] → 보낸 뒤 [보냈어요]) · 5 보강(신청 → 강사 확인 → [확정]) · 6 변경 기록([되돌리기])
// 판정(6시간·변경권·공휴일·보강 기한)과 중복 방지는 DB 함수 하나 — 화면 미리 보기와 저장 결과가 같음

import { useCallback, useEffect, useMemo, useState } from 'react';
import { formatInZone, instantToKstDate, kstToInstant } from '@/lms/rules/dates';
import { newRequestId } from '@/lms/admin/registration';
import { sentLabel } from '@/lms/admin/confirm';
import {
  changeableLessons, dateLabel, tutorLocalLabel, decisionLines, EVENT_TEXT, kstLabel, lessonTag, makeupRights, STATUS_SHORT, studentNotice, tutorNotice,
  type ChangeDecision, type ChLesson, type ChNotice, type ChStudent, type MakeupRight, type NoticeContext,
} from '@/lms/admin/lesson-change';
import type { StudentLessonData } from '@/lms/admin/lesson-change-live';
import { AdminHeader } from '../ui';
import TimeInput from '../TimeInput';
import { Card, inputCls } from '../students/new/parts';

export type ChangeActions = {
  load: (studentId: string) => Promise<StudentLessonData>;
  change: (requestId: string, lessonId: string, who: 'student' | 'tutor', requestedAt: Date, dryRun: boolean) => Promise<ChangeDecision>;
  revert: (changeId: string, note: string) => Promise<void>;
  requestMakeup: (source: { lessonId?: string; itemId?: string }, slots: Date[]) => Promise<void>;
  confirmMakeup: (requestId: string, at: Date) => Promise<void>;
  withdrawMakeup: (requestId: string) => Promise<void>;
  voidMakeup: (lessonId: string, note: string) => Promise<void>;
  markSent: (noticeId: string) => Promise<void>;
};

const btnMain = 'min-h-[44px] rounded-[10px] bg-[#7d5fff] px-4 text-[14.5px] font-bold text-white disabled:bg-[#cfc4ff]';
const btnSub = 'min-h-[44px] rounded-[10px] border border-[#e6e3ef] bg-white px-3.5 text-[14px] text-[#1d1b2b] disabled:text-[#b9b6c8]';
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

export default function LessonChange({ students, actions, nowIso, initialCode }: { students: ChStudent[]; actions: ChangeActions; nowIso: string; initialCode?: string }) {
  const [student, setStudent] = useState<ChStudent | null>(() => students.find((s) => s.code === initialCode) ?? null);
  const [q, setQ] = useState('');
  const [data, setData] = useState<StudentLessonData | null>(null);
  const [loadErr, setLoadErr] = useState('');
  const [lessonId, setLessonId] = useState<string | null>(null);
  const now = useMemo(() => new Date(nowIso), [nowIso]);

  const reload = useCallback(async () => {
    if (!student) return;
    try {
      setLoadErr('');
      setData(await actions.load(student.id));
    } catch (e) {
      setLoadErr(e instanceof Error ? e.message : '불러오지 못했어요.');
    }
  }, [student, actions]);
  useEffect(() => {
    setData(null);
    setLessonId(null);
    reload();
  }, [reload]);

  const found = useMemo(() => {
    const t = q.trim().toLowerCase();
    if (!t) return [];
    return students.filter((s) => s.nameKo.includes(t) || s.nameEn.toLowerCase().includes(t) || s.code.toLowerCase().includes(t)).slice(0, 8);
  }, [q, students]);

  const lessons = data?.lessons ?? [];
  const byId = useMemo(() => new Map(lessons.map((l) => [l.id, l])), [lessons]);
  const choices = changeableLessons(lessons, now);
  const lesson = lessonId ? byId.get(lessonId) ?? null : null;
  const rights = data ? makeupRights(lessons, data.migrated, data.makeupRequests) : [];
  const lastTutor = [...lessons].reverse().find((l) => !l.voided) ?? null;

  function ctxFor(n: ChNotice): NoticeContext | null {
    if (!student || !data?.enrollment) return null;
    const base = { student, durationMin: data.enrollment.durationMin };
    if (n.changeRequestId) {
      const c = data.changes.find((x) => x.id === n.changeRequestId);
      const l = c ? byId.get(c.lessonId) : undefined;
      if (!c || !l) return null;
      const voided = n.event === 'revert' ? lessons.filter((x) => x.makeupOf === l.id && x.voided).pop() : undefined;
      return { ...base, lesson: l, decision: c.decision, makeupAt: voided?.startsAt, tutorName: l.tutorName, tutorTz: l.tutorTz };
    }
    const r = data.makeupRequests.find((x) => x.id === n.makeupRequestId);
    if (!r) return null;
    const src = r.sourceLessonId ? byId.get(r.sourceLessonId) : undefined;
    const item = r.migratedItemId ? data.migrated.find((m) => m.id === r.migratedItemId) : undefined;
    const made = r.confirmedLessonId ? byId.get(r.confirmedLessonId) : undefined;
    const t = made ?? src ?? lastTutor;
    return {
      ...base, lesson: src, originalDate: item?.originalDate ?? null, candidates: r.candidates, makeupAt: made?.startsAt,
      tutorName: t?.tutorName ?? '', tutorTz: t?.tutorTz ?? 'Asia/Seoul',
    };
  }

  const notices = (data?.notices ?? []).filter((n) => n.status !== 'not_needed');
  const shownNotices = [...notices.filter((n) => n.status === 'pending'), ...notices.filter((n) => n.status === 'sent').reverse().slice(0, 4)];

  return (
    <div className="pb-24">
      <AdminHeader active="students" demo={false} />
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
                        onClick={() => setLessonId(l.id === lessonId ? null : l.id)}
                        className={`flex min-h-[48px] w-full items-center gap-2 rounded-[12px] border px-3 py-2 text-left ${l.id === lessonId ? 'border-[#7d5fff] bg-[#efebff]' : 'border-[#e6e3ef] bg-white'}`}
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
                done={async () => { setLessonId(null); await reload(); }} />
            )}

            {shownNotices.length > 0 && (
              <Card title="안내">
                <ul className="grid gap-2">
                  {shownNotices.map((n) => {
                    const c = ctxFor(n);
                    const text = c ? (n.recipient === 'student' ? studentNotice(n.event, c) : tutorNotice(n.event, c)) : '';
                    return <NoticeRow key={n.id} n={n} text={text} markSent={async () => { await actions.markSent(n.id); await reload(); }} />;
                  })}
                </ul>
              </Card>
            )}

            {rights.length > 0 && (
              <Card title="보강">
                <ul className="grid gap-2.5">
                  {rights.map((r) => (
                    <MakeupRow key={r.key} right={r} finalEnd={data.enrollment?.finalEndDate ?? null} tutorTz={(r.kind === 'lesson' ? r.source : lastTutor)?.tutorTz ?? 'Asia/Seoul'} actions={actions} done={reload} />
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
  );
}

function ChangeCard({ lesson, now, actions, isMakeup, done }: { lesson: ChLesson; now: Date; actions: ChangeActions; isMakeup: boolean; done: () => Promise<void> }) {
  const [who, setWho] = useState<'student' | 'tutor'>('student');
  const init = kstParts(now);
  const [date, setDate] = useState(init.date);
  const [time, setTime] = useState(init.time);
  const [preview, setPreview] = useState<ChangeDecision | null>(null);
  const [err, setErr] = useState('');
  const [busy, setBusy] = useState(false);
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
    <Card title={`변경 · ${kstLabel(lesson.startsAt)}`}>
      <div className="grid gap-3">
        <div className="grid grid-cols-2 gap-1.5" role="group" aria-label="요청한 사람">
          {(['student', 'tutor'] as const).map((w) => (
            <button key={w} type="button" aria-pressed={who === w} onClick={() => setWho(w)}
              className={`min-h-[44px] rounded-[10px] border text-[14.5px] font-semibold ${who === w ? 'border-[#7d5fff] bg-[#efebff] text-[#5b3fe0]' : 'border-[#e6e3ef] bg-white text-[#1d1b2b]'}`}>
              {w === 'student' ? '학생 요청' : '강사 요청'}
            </button>
          ))}
        </div>
        <label className="grid gap-1 text-[13px] text-[#6b6880]">
          요청 받은 시각 (한국)
          <div className="grid grid-cols-[1.4fr_1fr] gap-1.5">
            <input type="date" aria-label="요청 받은 날짜" value={date} max={init.date} onChange={(e) => setDate(e.target.value)} className={inputCls(false)} />
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
        <button type="button" className={btnMain} disabled={!preview || busy} onClick={() => run(async () => { await actions.change(requestId, lesson.id, who, requestedAt!, false); })}>
          변경
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

function NoticeRow({ n, text, markSent }: { n: ChNotice; text: string; markSent: () => Promise<void> }) {
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState('');
  const [copied, setCopied] = useState(false);
  const [manual, setManual] = useState(false);
  const sent = n.status === 'sent';
  return (
    <li className="rounded-[12px] border border-[#e6e3ef] px-3 py-2.5">
      <div className="flex items-center gap-2">
        <div className="min-w-0 flex-1">
          <b className="block text-[14.5px] text-[#1d1b2b]">{n.recipient === 'student' ? '학생' : '강사'} · {EVENT_TEXT[n.event]}</b>
          <span className="text-[12.5px] text-[#6b6880]">{sent && n.sentAt ? `보냄 ${sentLabel(n.sentAt)}` : copied ? '복사함' : '안 보냄'}</span>
        </div>
        <button type="button" disabled={!text} className={btnSub} onClick={async () => { if (await copyText(text)) setCopied(true); else setManual(true); }}>
          복사
        </button>
        {!sent && (
          <button type="button" disabled={busy} className={btnMain} onClick={async () => {
            setBusy(true);
            setErr('');
            try { await markSent(); } catch (e) { setErr(e instanceof Error ? e.message : '기록하지 못했어요.'); } finally { setBusy(false); }
          }}>
            보냈어요
          </button>
        )}
      </div>
      <pre className="mt-2 whitespace-pre-wrap rounded-[10px] bg-[#f6f5fb] px-3 py-2 font-sans text-[13.5px] text-[#1d1b2b]">{text}</pre>
      {manual && <textarea readOnly value={text} rows={5} onFocus={(e) => e.currentTarget.select()} aria-label="복사할 글" className="mt-2 w-full rounded-[10px] border border-[#e6e3ef] p-2 text-[13.5px]" />}
      <Err>{err}</Err>
    </li>
  );
}

function MakeupRow({ right, finalEnd, tutorTz, actions, done }: { right: MakeupRight; finalEnd: string | null; tutorTz: string; actions: ChangeActions; done: () => Promise<void> }) {
  const src = right.kind === 'lesson' ? right.source : null;
  const defTime = src ? kstParts(src.startsAt).time : '';
  const [slots, setSlots] = useState<{ date: string; time: string }[]>([{ date: '', time: defTime }]);
  const [other, setOther] = useState({ date: '', time: defTime });
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState('');
  const open = right.open;
  const title = src
    ? `${kstLabel(src.startsAt)} · ${src.classStatus ? STATUS_SHORT[src.classStatus] ?? src.classStatus : ''}`
    : `시트 보강 · 원래 ${right.kind === 'migrated' && right.item.originalDate ? dateLabel(right.item.originalDate) : '날짜 확인 필요'}`;
  const until = right.kind === 'migrated' && right.item.tutorLeave ? '강사 휴가 · 종료일 제한 없음' : finalEnd ? `${dateLabel(finalEnd)}까지` : '';
  const toAt = (s: { date: string; time: string }) => (s.date && /^\d\d:\d\d$/.test(s.time) ? kstToInstant(s.date, s.time) : null);
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
      {open ? (
        <div className="mt-2 grid gap-1.5">
          {open.candidates.map((t) => (
            <div key={+t} className="flex items-center gap-2">
              <span className="flex-1 text-[15px] text-[#1d1b2b]">
                {kstLabel(t)}
                <span className="block"><Local at={t} /></span>
              </span>
              <button type="button" disabled={busy} className={btnMain} onClick={() => run(() => actions.confirmMakeup(open.id, t))}>확정</button>
            </div>
          ))}
          <div className="grid grid-cols-[1.4fr_1fr_auto] gap-1.5">
            <input type="date" aria-label="다른 보강 날짜" value={other.date} onChange={(e) => setOther({ ...other, date: e.target.value })} className={inputCls(false)} />
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
              <input type="date" aria-label={`보강 희망 날짜 ${i + 1}`} value={s.date} max={right.kind === 'migrated' && right.item.tutorLeave ? undefined : finalEnd ?? undefined}
                onChange={(e) => setSlots(slots.map((x, j) => (j === i ? { ...x, date: e.target.value } : x)))} className={inputCls(false)} />
              <TimeInput aria-label={`보강 희망 시각 ${i + 1}`} value={s.time}
                onChange={(v) => setSlots(slots.map((x, j) => (j === i ? { ...x, time: v } : x)))} className={inputCls(false)} />
            </div>
            <Local at={toAt(s)} />
            </div>
          ))}
          <div className="grid grid-cols-2 gap-1.5">
            <button type="button" className={btnSub} onClick={() => setSlots([...slots, { date: '', time: defTime }])}>+ 시간</button>
            <button type="button" disabled={busy || slots.every((s) => !toAt(s))} className={btnMain}
              onClick={() => run(() => actions.requestMakeup(right.kind === 'lesson' ? { lessonId: right.source.id } : { itemId: right.item.id }, slots.map(toAt).filter((t): t is Date => !!t)))}>
              신청
            </button>
          </div>
        </div>
      )}
      <Err>{err}</Err>
    </li>
  );
}

function HistoryRow({ change, lesson, actions, done }: { change: StudentLessonData['changes'][number]; lesson: ChLesson; actions: ChangeActions; done: () => Promise<void> }) {
  const [asking, setAsking] = useState(false);
  const [note, setNote] = useState('');
  const [busy, setBusy] = useState(false);
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
