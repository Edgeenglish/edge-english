'use client';

// 강사 휴무·대체강사 (2순위 ①, migration 1800, 2026-10-27 대표 시안 승인 Q1 A · Q2 A, 화면 흐름 안 1 확정)
// 위: 휴무 목록 · [+ 휴무 넣기] · 할 일 요약. PC: 왼쪽 학생 목록(지금 단계) · 오른쪽 고른 학생. 휴대폰: 학생 카드가 위아래로
// 학생 카드 = 단계 흐름(1 안내 › 2 학생 답 › 3 강사 확인 / 보강 날짜 › 4 확정) + 지금 할 일부터 단계 순서로. 끝난 단계를 누르면 되돌리기, 끝난 수업·보낸 글은 접어 둠
// 대체강사: 강사 가능(가능한 날짜만 골라 저장) → 학생 안내 → 학생 OK 뒤 확정 (A41). 안 되는 날짜는 다른 강사·기존 강사 보강으로
// 기존 강사 보강: 보강 가능한 날짜(지금 수강기간 안 → 종료일 뒤 평소 요일·시간)를 학생에게 보내고 2개까지 골라 신청 → 확정은 수업 변경·보강 화면 (A20)

import Link from 'next/link';
import { useCallback, useEffect, useMemo, useState } from 'react';
import { instantToKstDate, type KstDate } from '@/lms/rules/dates';
import { dateLabel, kstLabel, MAKEUP_SLOTS_MAX } from '@/lms/admin/lesson-change';
import {
  groupByStudent, groupRenewals, itemStatus, leaveMessages, LV_EVENT_TEXT, LV_STEP_TEXT, makeupDatesText, renewalLeaveText, renewalTutorText, studentWork,
  type LvItem, type LvRenewal, type LvRenewalGroup, type LvMakeupOption, type LvMessage, type LvNotice, type LvStep, type LvStudentGroup, type LvStudentWork, type LvSubOption, type LvTimeOff,
} from '@/lms/admin/tutor-leave';
import type { LeaveCreateResult, LvTutor } from '@/lms/admin/tutor-leave-live';
import { AdminHeader } from '../ui';
import { Card, inputCls } from '../students/new/parts';

export type LeaveActions = {
  leaves: (now: Date) => Promise<LvTimeOff[]>;
  items: (timeOffId: string) => Promise<{ items: LvItem[]; notices: LvNotice[] }>;
  create: (tutorId: string, from: KstDate, to: KstDate, reason: string, dryRun: boolean) => Promise<LeaveCreateResult>;
  choose: (itemIds: string[], choice: 'substitute' | 'wait', subTutorId: string | null) => Promise<void>;
  subOk: (itemIds: string[]) => Promise<void>;
  studentOk: (itemIds: string[]) => Promise<void>;
  subOptions: (itemIds: string[]) => Promise<LvSubOption[]>;
  markSent: (noticeIds: string[]) => Promise<void>;
  makeupOptions: (itemIds: string[]) => Promise<LvMakeupOption[]>;
  requestMakeup: (source: { lessonId?: string; itemId?: string }, slots: Date[]) => Promise<void>;
  back: (itemIds: string[], to: 'undecided' | 'asked' | 'tutor_ok') => Promise<void>;
  renewals: (timeOffId: string) => Promise<LvRenewal[]>;
};

const btnMain = 'min-h-[44px] rounded-[10px] bg-[#7d5fff] px-4 text-[14.5px] font-bold text-white disabled:bg-[#cfc4ff]';
const btnSub = 'min-h-[44px] rounded-[10px] border border-[#e6e3ef] bg-white px-3.5 text-[14px] text-[#1d1b2b] disabled:text-[#b9b6c8]';
/** 누른 버튼: 회색으로 꽉 차게 (눌린 티) */
const btnDone = 'min-h-[44px] rounded-[10px] border border-[#c9c6d6] bg-[#d9d6e3] px-3.5 text-[14px] font-bold text-[#4a4760]';
const Err = ({ children }: { children: React.ReactNode }) => (children ? <p className="mt-1.5 text-[13px] text-[#b3261e]">{children}</p> : null);
const TONE = { todo: 'bg-[#fff8d6] text-[#5c4a00]', wait: 'bg-[#e9f4ff] text-[#1b5a8a]', done: 'bg-[#e3f6ea] text-[#1e7a46]' } as const;
const STEP_ORDER: LvStep[] = ['notify', 'answer', 'tutor', 'makeup', 'confirm'];
/** 단계 화면 제목 (4 = 3단계가 기존 강사 보강뿐일 때) */
const STEP_TITLE = ['학생에게 안내', '학생 답 입력', '강사 확인', '확정', '보강 날짜'];

async function copyText(text: string): Promise<boolean> {
  try {
    await navigator.clipboard.writeText(text);
    return true;
  } catch {
    return false;
  }
}

/** 처리 버튼 공통: 실행 → 다시 읽기, 오류는 그 자리에 */
function useRun(done: () => Promise<void>) {
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState('');
  const run = async (f: () => Promise<unknown>, after?: () => void) => {
    setBusy(true);
    setErr('');
    try {
      await f();
      after?.();
      await done();
    } catch (e) {
      setErr(e instanceof Error ? e.message : '처리하지 못했어요.');
    } finally {
      setBusy(false);
    }
  };
  return { busy, err, setErr, run };
}

export default function TutorLeave({ tutors, actions, nowIso, initialOff }: { tutors: LvTutor[]; actions: LeaveActions; nowIso: string; initialOff?: string }) {
  const now = useMemo(() => new Date(nowIso), [nowIso]);
  const [leaves, setLeaves] = useState<LvTimeOff[]>([]);
  const [offId, setOffId] = useState<string | null>(initialOff ?? null);
  const [data, setData] = useState<{ items: LvItem[]; notices: LvNotice[]; renewals: LvRenewal[] } | null>(null);
  const [sel, setSel] = useState<string | null>(null);
  const [err, setErr] = useState('');

  const reloadLeaves = useCallback(async () => {
    try {
      setLeaves(await actions.leaves(now));
    } catch (e) {
      setErr(e instanceof Error ? e.message : '불러오지 못했어요.');
    }
  }, [actions, now]);
  const reload = useCallback(async () => {
    if (!offId) return setData(null);
    try {
      setErr('');
      const [d, renewals] = await Promise.all([actions.items(offId), actions.renewals(offId)]);
      setData({ ...d, renewals });
    } catch (e) {
      setErr(e instanceof Error ? e.message : '불러오지 못했어요.');
    }
  }, [actions, offId]);
  useEffect(() => {
    reloadLeaves();
  }, [reloadLeaves]);
  useEffect(() => {
    setData(null);
    setSel(null);
    reload();
  }, [reload]);

  const groups = data ? groupByStudent(data.items) : [];
  const messages = data ? leaveMessages(data.items, data.notices) : [];
  const works = new Map(groups.map((g) => [g.studentId, studentWork(g, messages, now)]));
  const renewals = data ? groupRenewals(data.renewals) : [];
  const off = leaves.find((l) => l.id === offId) ?? null;
  const selected = groups.find((g) => g.studentId === sel) ?? groups.find((g) => works.get(g.studentId)!.steps.length > 0) ?? groups[0];
  const selKey = sel && (groups.some((g) => g.studentId === sel) || sel.startsWith('r:')) ? sel : selected?.studentId ?? (renewals[0] ? `r:${renewals[0].studentId}` : null);
  const todo = STEP_ORDER.map((s) => [s, groups.filter((g) => works.get(g.studentId)!.steps[0] === s).length] as const).filter(([, n]) => n > 0);

  return (
    <div className="pb-24">
      <AdminHeader active="schedule" demo={false} />
      <main className="mx-auto grid max-w-[720px] gap-3 px-4 py-4 lg:max-w-[1120px]">
        <h1 className="text-[20px] font-extrabold text-[#1d1b2b]">강사 휴무</h1>

        <div className="flex flex-wrap items-center gap-1.5">
          {leaves.map((l) => (
            <button key={l.id} type="button" aria-pressed={l.id === offId} onClick={() => setOffId(l.id === offId ? null : l.id)}
              className={`min-h-[40px] rounded-full border px-3.5 text-[14px] ${l.id === offId ? 'border-[#7d5fff] bg-[#efebff] font-bold text-[#5b3fe0]' : 'border-[#e6e3ef] bg-white text-[#1d1b2b]'}`}>
              {l.tutorName} · {dateLabel(l.from)} ~ {dateLabel(l.to)}
            </button>
          ))}
        </div>
        <NewLeave tutors={tutors} actions={actions} today={instantToKstDate(now)} saved={async (id) => { await reloadLeaves(); setOffId(id); }} />
        <Err>{err}</Err>

        {offId && data && (
          <>
            <p className="rounded-[12px] bg-[#f6f5fb] px-3 py-2.5 text-[14px] text-[#1d1b2b]">
              {data.items.length === 0
                ? '이 휴무에 걸리는 수업이 없어요.'
                : `학생 ${groups.length}명 · 수업 ${data.items.length}회 · ${todo.length ? `할 일: ${todo.map(([s, n]) => `${LV_STEP_TEXT[s].replace(/^\d /, '')} ${n}명`).join(' · ')}` : '모두 처리됨'}`}
              {renewals.length > 0 && ` · 재등록 대기 ${renewals.length}명(재등록하면 ${renewals.reduce((n, r) => n + r.dates.length, 0)}회)`}
            </p>

            {(groups.length > 0 || renewals.length > 0) && (
              <div className="grid gap-3 lg:grid-cols-[260px_1fr] lg:items-start">
                <ul className="hidden gap-1.5 lg:grid">
                  {groups.map((g) => {
                    const w = works.get(g.studentId)!;
                    const on = g.studentId === selKey;
                    return (
                      <li key={g.studentId}>
                        <button type="button" aria-pressed={on} onClick={() => setSel(g.studentId)}
                          className={`grid w-full gap-0.5 rounded-[12px] border px-3 py-2.5 text-left ${on ? 'border-[#7d5fff] bg-[#efebff]' : 'border-[#e6e3ef] bg-white'}`}>
                          <b className="text-[15px] text-[#1d1b2b]">{g.studentName}</b>
                          <span className="text-[12.5px] text-[#6b6880]">{dateLabel(instantToKstDate(g.items[0].startsAt))}{g.items.length > 1 ? ` ~ ${dateLabel(instantToKstDate(g.items[g.items.length - 1].startsAt))}` : ''} · {g.items.length}회</span>
                          <span className="text-[13px] font-semibold text-[#5b3fe0]">{LV_STEP_TEXT[w.steps[0] ?? 'done']}</span>
                        </button>
                      </li>
                    );
                  })}
                  {renewals.length > 0 && <li className="mt-2 text-[13px] font-bold text-[#6b6880]">재등록 대기</li>}
                  {renewals.map((r) => {
                    const on = `r:${r.studentId}` === selKey;
                    return (
                      <li key={r.studentId}>
                        <button type="button" aria-pressed={on} onClick={() => setSel(`r:${r.studentId}`)}
                          className={`grid w-full gap-0.5 rounded-[12px] border px-3 py-2.5 text-left ${on ? 'border-[#7d5fff] bg-[#efebff]' : 'border-[#e6e3ef] bg-white'}`}>
                          <b className="text-[15px] text-[#1d1b2b]">{r.studentName}</b>
                          <span className="text-[12.5px] text-[#6b6880]">{dateLabel(r.endDate)} 종료 · 재등록하면 {r.dates.length}회</span>
                        </button>
                      </li>
                    );
                  })}
                </ul>
                <div className="grid min-w-0 gap-3">
                  {groups.map((g) => (
                    <div key={g.studentId} className={g.studentId === selKey ? '' : 'lg:hidden'}>
                      <StudentPanel g={g} w={works.get(g.studentId)!} sent={messages.filter((m) => m.status === 'sent' && m.studentId === g.studentId)}
                        now={now} actions={actions} done={reload} />
                    </div>
                  ))}
                  {renewals.length > 0 && <h2 className="text-[15px] font-bold text-[#6b6880] lg:hidden">재등록 대기</h2>}
                  {renewals.map((r) => (
                    <div key={r.studentId} className={`r:${r.studentId}` === selKey ? '' : 'lg:hidden'}>
                      {off && <RenewalPanel r={r} from={off.from} to={off.to} />}
                    </div>
                  ))}
                </div>
              </div>
            )}
          </>
        )}
      </main>
    </div>
  );
}

function NewLeave({ tutors, actions, today, saved }: { tutors: LvTutor[]; actions: LeaveActions; today: KstDate; saved: (id: string) => Promise<void> }) {
  const [open, setOpen] = useState(false);
  const [tutorId, setTutorId] = useState('');
  const [from, setFrom] = useState('');
  const [to, setTo] = useState('');
  const [reason, setReason] = useState('');
  const [preview, setPreview] = useState<LeaveCreateResult | null>(null);
  const [err, setErr] = useState('');
  const [busy, setBusy] = useState(false);
  const ready = !!tutorId && !!from && !!to && to >= from;

  useEffect(() => {
    setPreview(null);
    setErr('');
    if (!ready) return;
    let live = true;
    actions.create(tutorId, from, to, reason, true).then(
      (r) => live && setPreview(r),
      (e) => live && setErr(e instanceof Error ? e.message : '확인하지 못했어요.'),
    );
    return () => {
      live = false;
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [tutorId, from, to]);

  if (!open) {
    return (
      <button type="button" className={btnMain} onClick={() => setOpen(true)}>
        + 휴무 넣기
      </button>
    );
  }
  return (
    <Card title="휴무 넣기">
      <div className="grid gap-2.5">
        <label className="grid gap-1 text-[13px] text-[#6b6880]">
          강사
          <select value={tutorId} onChange={(e) => setTutorId(e.target.value)} className={inputCls(false)}>
            <option value="">고르기</option>
            {tutors.map((t) => <option key={t.id} value={t.id}>{t.name}</option>)}
          </select>
        </label>
        <div className="grid grid-cols-2 gap-1.5">
          <label className="grid gap-1 text-[13px] text-[#6b6880]">
            시작일
            <input type="date" value={from} min={today} onChange={(e) => { setFrom(e.target.value); if (!to || to < e.target.value) setTo(e.target.value); }} className={inputCls(false)} />
          </label>
          <label className="grid gap-1 text-[13px] text-[#6b6880]">
            끝일
            <input type="date" value={to} min={from || today} onChange={(e) => setTo(e.target.value)} className={inputCls(false)} />
          </label>
        </div>
        <label className="grid gap-1 text-[13px] text-[#6b6880]">
          사유 (선택)
          <input value={reason} onChange={(e) => setReason(e.target.value)} placeholder="예: 개인 휴가" className={inputCls(false)} />
        </label>
        {preview && (
          <p className="rounded-[12px] bg-[#fff8d6] px-3 py-2.5 text-[14px] text-[#5c4a00]">
            걸리는 수업 <b>{preview.items}회 · 학생 {preview.students}명</b>
            {preview.items > preview.lessons ? ` (시트 휴가 보강 ${preview.items - preview.lessons}회 포함)` : ''}
            {preview.existing ? ` · 이미 목록 ${preview.existing}회` : ''}
          </p>
        )}
        <Err>{err}</Err>
        <div className="grid grid-cols-2 gap-1.5">
          <button type="button" className={btnSub} onClick={() => setOpen(false)}>닫기</button>
          <button type="button" className={btnMain} disabled={!preview || busy} onClick={async () => {
            setBusy(true);
            setErr('');
            try {
              const r = await actions.create(tutorId, from, to, reason, false);
              setOpen(false);
              await saved(r.time_off_id!);
            } catch (e) {
              setErr(e instanceof Error ? e.message : '저장하지 못했어요.');
            } finally {
              setBusy(false);
            }
          }}>
            저장
          </button>
        </div>
      </div>
    </Card>
  );
}

const Block = ({ title, children }: { title: string; children: React.ReactNode }) => (
  <div className="grid gap-2 border-t border-[#e6e3ef] pt-3 first:border-t-0 first:pt-0">
    <b className="text-[14.5px] text-[#1d1b2b]">{title}</b>
    {children}
  </div>
);

const overlaps = (m: LvMessage, ids: Set<string>) => m.noticeIds.some((id) => ids.has(id));

// 학생 한 명: 단계 흐름(1 안내 › 2 학생 답 › 3 강사 확인 › 4 확정). 고른 단계(처음엔 지금 단계)의 화면만 보임:
// 그 단계에서 할 일 + 그 단계에서 보낸 글(회색 '보냄 ✓') + 앞 단계로 되돌리기.
// 할 일도 되돌릴 것도 없는 단계는 못 누름. 보냄을 누르면 그 단계에 머물러 회색 버튼을 보여 주고, 아래 [다음 단계 ›]로 넘어감
function StudentPanel({ g, w, sent, now, actions, done }: { g: LvStudentGroup; w: LvStudentWork; sent: LvMessage[]; now: Date; actions: LeaveActions; done: () => Promise<void> }) {
  const [view, setView] = useState<number | null>(null);
  // 처리(고르기·저장·확정)를 하면 지금 단계로 넘어가 다음 할 일이 바로 보이게
  const next = async () => { setView(null); await done(); };
  const r = useRun(next);
  const [copied, setCopied] = useState<Set<string>>(new Set());
  const stage = (s: LvStep) => (s === 'notify' ? 0 : s === 'answer' ? 1 : s === 'confirm' ? 3 : 2);
  const cur = w.steps.length ? stage(w.steps[0]) : 4;
  const third = w.tutor.length && w.makeup.length ? '3 강사 확인·보강 날짜' : w.makeup.length ? LV_STEP_TEXT.makeup : LV_STEP_TEXT.tutor;
  const chips = [LV_STEP_TEXT.notify, LV_STEP_TEXT.answer, third, LV_STEP_TEXT.confirm];
  const changeable = g.items.filter((i) => i.startsAt > now && !(i.choice === 'wait' && (i.makeupAt || i.makeupRequested)));

  const msg = (m: LvMessage, n: number) => (
    <MessageRow key={m.key} m={m} copied={overlaps(m, copied)}
      onCopied={() => setCopied(new Set([...copied, ...m.noticeIds]))}
      onSend={async () => { await actions.markSent(m.noticeIds); setView(n); await done(); }} />
  );
  const sentOf = (n: number) => sent.filter((m) => (n === 0 ? m.event === 'leave_options' : n === 2 ? m.event === 'sub_ask' : n === 3 && (m.event === 'sub_student' || m.event === 'sub_confirmed')));

  // 되돌리기 대상 (지난 수업 제외)
  const future = g.items.filter((i) => i.startsAt > now);
  const backOf = (n: number) => {
    if (n === 1) return { items: future.filter((i) => i.choice === 'substitute' || (i.choice === 'wait' && !i.makeupAt && !i.makeupRequested)), to: 'undecided' as const, label: '학생 답 전으로' };
    if (n === 2) return { items: future.filter((i) => i.choice === 'substitute' && (i.subStage === 'tutor_ok' || i.subStage === 'confirmed')), to: 'asked' as const, label: '강사 답 전으로' };
    if (n === 3) return { items: future.filter((i) => i.choice === 'substitute' && i.subStage === 'confirmed'), to: 'tutor_ok' as const, label: '확정 전으로' };
    return null;
  };

  // 단계마다 할 일
  const c = w.confirm;
  const todo = (n: number): React.ReactNode[] => {
    if (n === 0) return w.notify.map((m) => msg(m, 0));
    if (n === 1) return w.answer.length ? [
      <div key="answer" className="grid gap-2">
        <ItemList items={w.answer} />
        <ChooseBox items={w.answer} actions={actions} done={next} />
      </div>,
    ] : [];
    if (n === 2) return [
      ...w.tutor.map((t) => (
        <Block key={`t-${t.subTutorId}`} title={`대체강사 ${t.subTutorName} 확인`}>
          {t.ask && msg(t.ask, 2)}
          <TutorCheck key={t.items.map((i) => i.id).join()} t={t} actions={actions} done={next} />
        </Block>
      )),
      ...(w.makeup.length ? [<Block key="makeup" title="보강 날짜"><MakeupPick g={g} items={w.makeup} actions={actions} done={next} /></Block>] : []),
    ];
    const out: React.ReactNode[] = [];
    if (c.studentMsg) out.push(msg(c.studentMsg, 3));
    if (c.tutorOk.length) out.push(
      <button key="ok" type="button" disabled={r.busy} className={btnMain} onClick={() => r.run(() => actions.studentOk(c.tutorOk.map((i) => i.id)))}>
        학생 OK → 확정 ({c.tutorOk.length}회)
      </button>,
    );
    out.push(...c.confirmedMsgs.map((m) => msg(m, 3)));
    if (c.makeupRequested.length) out.push(
      <div key="mk" className="grid gap-2">
        <ItemList items={c.makeupRequested} />
        <Link href={`/lms/admin/change?student=${encodeURIComponent(g.studentCode)}`} className="flex min-h-[44px] items-center justify-center rounded-[10px] border border-[#7d5fff] text-[14px] font-semibold text-[#5b3fe0]">
          보강 확정
        </Link>
      </div>,
    );
    return out;
  };
  const canOpen = (n: number) => todo(n).length > 0 || sentOf(n).length > 0 || (backOf(n)?.items.length ?? 0) > 0;
  const sel = view !== null && canOpen(view) ? view : cur;
  const nextStep = todo(sel).length === 0 ? [0, 1, 2, 3].find((n) => n > sel && todo(n).length > 0) : undefined;
  const back = sel < 4 ? backOf(sel) : null;

  return (
    <Card title={<>{g.studentName} <span className="text-[13px] font-normal text-[#6b6880]">{g.studentCode}</span></>}>
      <div className="mb-3 flex flex-wrap items-center gap-1">
        {chips.map((label, n) => {
          const on = sel === n;
          const open = canOpen(n);
          return (
            <span key={label} className="flex items-center gap-1">
              {n > 0 && <span aria-hidden className="text-[15px] font-bold text-[#b9b6c8]">›</span>}
              <button type="button" aria-pressed={on} disabled={!open} onClick={() => setView(n)}
                className={`min-h-[34px] rounded-full px-3 text-[13px] ${on ? 'bg-[#7d5fff] font-bold text-white' : open ? 'border border-[#7d5fff] bg-white text-[#5b3fe0]' : 'bg-[#f3f2f7] text-[#b9b6c8]'}`}>
                {n < cur ? '✓ ' : ''}{label}
              </button>
            </span>
          );
        })}
        {cur === 4 && <span className="ml-1 rounded-full bg-[#e3f6ea] px-3 py-1 text-[13px] font-bold text-[#1e7a46]">완료</span>}
      </div>

      <div className="grid gap-3">
        {sel < 4 && (
          <section aria-label={`${sel + 1}단계`} className="grid gap-2 rounded-[14px] border-2 border-[#7d5fff] p-3">
            <h3 className="-mx-3 -mt-3 mb-1 rounded-t-[12px] bg-[#7d5fff] px-3 py-2 text-[15.5px] font-extrabold text-white">
              {sel + 1}단계 · {STEP_TITLE[sel === 2 && w.makeup.length && !w.tutor.length ? 4 : sel]}
            </h3>
            {todo(sel)}
            {sentOf(sel).map((m) => msg(m, sel))}
            {back && back.items.length > 0 && (
              <div className="grid gap-2 border-t border-[#e6e3ef] pt-3">
                <ItemList items={back.items} />
                <button type="button" disabled={r.busy} className={btnSub} onClick={() => r.run(() => actions.back(back.items.map((i) => i.id), back.to), () => setView(null))}>
                  {back.label} ({back.items.length}회)
                </button>
              </div>
            )}
            {nextStep !== undefined && (
              <button type="button" className={btnMain} onClick={() => setView(nextStep)}>{chips[nextStep]} ›</button>
            )}
            <Err>{r.err}</Err>
          </section>
        )}

        <details className="border-t border-[#e6e3ef] pt-3">
          <summary className="min-h-[36px] cursor-pointer text-[13.5px] font-semibold text-[#5b3fe0]">전체 수업 {g.items.length}회</summary>
          <div className="mt-2 grid gap-2">
            <ItemList items={g.items} />
            {changeable.length > 0 && (
              <details>
                <summary className="min-h-[36px] cursor-pointer text-[13.5px] font-semibold text-[#5b3fe0]">처리 방법 바꾸기</summary>
                <div className="mt-2"><ChooseBox items={changeable} actions={actions} done={next} /></div>
              </details>
            )}
          </div>
        </details>
      </div>
    </Card>
  );
}

// 재등록 대기 학생: 재등록하면 휴무에 걸리는 날짜 + 재등록 안내에 덧붙일 글 + 대체강사에게 같이 물어볼 글 (복사만)
function RenewalPanel({ r, from, to }: { r: LvRenewalGroup; from: KstDate; to: KstDate }) {
  return (
    <Card title={<>{r.studentName} <span className="text-[13px] font-normal text-[#6b6880]">{r.studentCode} · {dateLabel(r.endDate)} 종료 · 재등록 대기</span></>}>
      <div className="grid gap-3">
        <div className="grid gap-1.5">
          <b className="text-[14px] text-[#1d1b2b]">재등록하면 휴무에 걸리는 날짜</b>
          <ul className="grid gap-1.5">
            {r.dates.map((d) => (
              <li key={+d.startsAt} className="flex min-h-[44px] items-center rounded-[10px] border border-[#e6e3ef] px-3 text-[14.5px] text-[#1d1b2b]">
                {kstLabel(d.startsAt)} · {d.durationMin}분
              </li>
            ))}
          </ul>
        </div>
        <CopyBox title="재등록 안내에 덧붙일 글" text={renewalLeaveText(from, to)} />
        <CopyBox title="대체강사에게 물어볼 때 덧붙일 글" text={renewalTutorText(r)} />
      </div>
    </Card>
  );
}

function CopyBox({ title, text }: { title: string; text: string }) {
  const [copied, setCopied] = useState(false);
  const [manual, setManual] = useState(false);
  return (
    <div className="rounded-[12px] border border-[#e6e3ef] px-3 py-2.5">
      <div className="flex items-center gap-2">
        <b className="min-w-0 flex-1 text-[14px] text-[#1d1b2b]">{title}</b>
        <button type="button" className={copied ? btnDone : btnSub} onClick={async () => { if (await copyText(text)) setCopied(true); else setManual(true); }}>
          {copied ? '복사함 ✓' : '복사'}
        </button>
      </div>
      <pre className="mt-2 whitespace-pre-wrap rounded-[10px] bg-[#f6f5fb] px-3 py-2 font-sans text-[13.5px] text-[#1d1b2b]">{text}</pre>
      {manual && <textarea readOnly value={text} rows={5} onFocus={(e) => e.currentTarget.select()} aria-label="복사할 글" className="mt-2 w-full rounded-[10px] border border-[#e6e3ef] p-2 text-[13.5px]" />}
    </div>
  );
}

function ItemList({ items }: { items: LvItem[] }) {
  return (
    <ul className="grid gap-1.5">
      {items.map((i) => {
        const s = itemStatus(i);
        return (
          <li key={i.id} className="flex min-h-[44px] items-center gap-2 rounded-[10px] border border-[#e6e3ef] px-3 py-1.5">
            <span className="text-[14.5px] text-[#1d1b2b]">{kstLabel(i.startsAt)}{i.isLesson ? '' : ' · 시트 보강'}</span>
            <span className={`ml-auto rounded-[6px] px-2 py-0.5 text-[12px] font-bold ${TONE[s.tone]}`}>{s.text}</span>
          </li>
        );
      })}
    </ul>
  );
}

// 대체강사 / 기존 강사 보강 고르기 (모든 날짜 한 번에, 필요하면 일부 날짜만)
function ChooseBox({ items, actions, done }: { items: LvItem[]; actions: LeaveActions; done: () => Promise<void> }) {
  const [some, setSome] = useState(false);
  const [picked, setPicked] = useState<Set<string>>(() => new Set(items.map((i) => i.id)));
  const [options, setOptions] = useState<LvSubOption[] | null>(null);
  const r = useRun(done);
  const ids = (some ? items.filter((i) => picked.has(i.id)) : items).map((i) => i.id);
  const reset = () => { setOptions(null); setSome(false); };

  return (
    <div className="grid gap-2">
      {some && (
        <ul className="grid gap-1.5">
          {items.map((i) => (
            <li key={i.id}>
              <label className="flex min-h-[44px] items-center gap-2 rounded-[10px] border border-[#e6e3ef] px-3 text-[14.5px] text-[#1d1b2b]">
                <input type="checkbox" className="h-5 w-5" checked={picked.has(i.id)}
                  onChange={(e) => { const n = new Set(picked); if (e.target.checked) n.add(i.id); else n.delete(i.id); setPicked(n); setOptions(null); }} />
                {kstLabel(i.startsAt)}{i.isLesson ? '' : ' · 시트 보강'}
              </label>
            </li>
          ))}
        </ul>
      )}
      <div className="grid grid-cols-2 gap-1.5">
        <button type="button" disabled={r.busy || ids.length === 0} className={btnSub} onClick={async () => {
          r.setErr('');
          try { setOptions(await actions.subOptions(ids)); } catch (e) { r.setErr(e instanceof Error ? e.message : '강사 목록을 읽지 못했어요.'); }
        }}>
          대체강사
        </button>
        <button type="button" disabled={r.busy || ids.length === 0} className={btnSub} onClick={() => r.run(() => actions.choose(ids, 'wait', null), reset)}>
          기존 강사 보강
        </button>
      </div>
      {items.length > 1 && (
        <button type="button" className="min-h-[36px] text-left text-[13.5px] font-semibold text-[#5b3fe0]" onClick={() => { setSome(!some); setOptions(null); }}>
          {some ? '모든 날짜 한 번에 ›' : '일부 날짜만 다르게 ›'}
        </button>
      )}
      {options && <SubOptions options={options} items={items.filter((i) => ids.includes(i.id))} busy={r.busy} pick={(id, sel) => r.run(() => actions.choose(sel, 'substitute', id), reset)} />}
      <Err>{r.err}</Err>
    </div>
  );
}

// 대체강사 목록: 일부만 가능한 강사도 고를 수 있음 → 가능한 날짜만 그 강사에게, 겹치는 날짜는 그대로 남음
function SubOptions({ options, items, busy, pick }: { options: LvSubOption[]; items: LvItem[]; busy: boolean; pick: (tutorId: string, itemIds: string[]) => void }) {
  const md = (i: LvItem) => instantToKstDate(i.startsAt).slice(5).split('-').map(Number).join('/');
  return (
    <ul className="grid gap-1.5">
      {options.length === 0 && <li className="text-[13.5px] text-[#6b6880]">고를 수 있는 강사가 없어요.</li>}
      {options.map((o) => (
        <li key={o.tutorId}>
          <button type="button" disabled={busy || o.free === 0} onClick={() => pick(o.tutorId, items.filter((i) => !o.busyDates.includes(md(i))).map((i) => i.id))}
            className="flex min-h-[48px] w-full items-center gap-2 rounded-[12px] border border-[#e6e3ef] bg-white px-3 py-2 text-left disabled:bg-[#faf9fd] disabled:text-[#b9b6c8]">
            <b className="text-[15px]">{o.name}</b>
            <span className="flex-1 text-right text-[13px] text-[#6b6880]">
              {o.free === items.length ? `${items.length}회 모두 가능` : `${o.free}회 가능 · ${o.busyDates.join('·')} 겹침`}
            </span>
          </button>
        </li>
      ))}
    </ul>
  );
}

// 대체강사 답: 가능하다고 한 날짜만 체크해 저장. 체크 안 한 날짜는 다른 강사 또는 기존 강사 보강으로
function TutorCheck({ t, actions, done }: { t: LvStudentWork['tutor'][number]; actions: LeaveActions; done: () => Promise<void> }) {
  const [ok, setOk] = useState<Set<string>>(() => new Set(t.items.map((i) => i.id)));
  const [options, setOptions] = useState<LvSubOption[] | null>(null);
  const r = useRun(done);
  const yes = t.items.filter((i) => ok.has(i.id)).map((i) => i.id);
  const no = t.items.filter((i) => !ok.has(i.id)).map((i) => i.id);

  return (
    <div className="grid gap-2">
      <span className="text-[13px] text-[#6b6880]">{t.subTutorName}가 가능하다고 한 날짜</span>
      <ul className="grid gap-1.5">
        {t.items.map((i) => (
          <li key={i.id}>
            <label className="flex min-h-[44px] items-center gap-2 rounded-[10px] border border-[#e6e3ef] px-3 text-[14.5px] text-[#1d1b2b]">
              <input type="checkbox" className="h-5 w-5" checked={ok.has(i.id)}
                onChange={(e) => { const n = new Set(ok); if (e.target.checked) n.add(i.id); else n.delete(i.id); setOk(n); setOptions(null); }} />
              {kstLabel(i.startsAt)}{i.isLesson ? '' : ' · 시트 보강'}
            </label>
          </li>
        ))}
      </ul>
      <button type="button" disabled={r.busy || yes.length === 0} className={btnMain} onClick={() => r.run(() => actions.subOk(yes))}>
        저장 ({yes.length}회)
      </button>
      {no.length > 0 && (
        <>
          <span className="text-[13px] text-[#6b6880]">안 되는 날짜 {no.length}회</span>
          <div className="grid grid-cols-2 gap-1.5">
            <button type="button" disabled={r.busy} className={btnSub} onClick={async () => {
              r.setErr('');
              try { setOptions((await actions.subOptions(no)).filter((o) => o.tutorId !== t.subTutorId)); } catch (e) { r.setErr(e instanceof Error ? e.message : '강사 목록을 읽지 못했어요.'); }
            }}>
              다른 대체강사
            </button>
            <button type="button" disabled={r.busy} className={btnSub} onClick={() => r.run(() => actions.choose(no, 'wait', null))}>
              기존 강사 보강
            </button>
          </div>
          {options && <SubOptions options={options} items={t.items.filter((i) => no.includes(i.id))} busy={r.busy} pick={(id, sel) => r.run(() => actions.choose(sel, 'substitute', id))} />}
        </>
      )}
      <Err>{r.err}</Err>
    </div>
  );
}

// 기존 강사 보강: 보강 가능한 날짜(지금 수강기간 안 먼저, 종료일 뒤 평소 요일·시간) → 학생에게 보내기 → 학생이 고른 날짜 2개까지 신청
function MakeupPick({ g, items, actions, done }: { g: LvStudentGroup; items: LvItem[]; actions: LeaveActions; done: () => Promise<void> }) {
  const [itemId, setItemId] = useState(items[0].id);
  const [opts, setOpts] = useState<LvMakeupOption[] | null>(null);
  const [picked, setPicked] = useState<Set<number>>(new Set());
  const [copied, setCopied] = useState(false);
  const [manual, setManual] = useState(false);
  const r = useRun(done);
  const item = items.find((i) => i.id === itemId) ?? items[0];
  const { setErr } = r;

  useEffect(() => {
    let live = true;
    setOpts(null);
    setPicked(new Set());
    setCopied(false);
    setManual(false);
    actions.makeupOptions([item.id]).then(
      (o) => live && setOpts(o),
      (e) => live && setErr(e instanceof Error ? e.message : '보강 가능한 날짜를 읽지 못했어요.'),
    );
    return () => { live = false; };
  }, [actions, item.id, setErr]);

  const text = opts ? makeupDatesText(g.studentName, item.studentTz, opts.map((o) => o.startsAt)) : '';
  const section = (s: LvMakeupOption['section'], title: string) => {
    const list = (opts ?? []).filter((o) => o.section === s);
    if (list.length === 0) return null;
    return (
      <div className="grid gap-1">
        <span className="text-[13px] text-[#6b6880]">{title}</span>
        <ul className="grid max-h-[260px] gap-1 overflow-y-auto">
          {list.map((o) => {
            const on = picked.has(+o.startsAt);
            return (
              <li key={+o.startsAt}>
                <label className="flex min-h-[44px] items-center gap-2 rounded-[10px] border border-[#e6e3ef] px-3 text-[14.5px] text-[#1d1b2b]">
                  <input type="checkbox" className="h-5 w-5" checked={on} disabled={!on && picked.size >= MAKEUP_SLOTS_MAX}
                    onChange={(e) => { const n = new Set(picked); if (e.target.checked) n.add(+o.startsAt); else n.delete(+o.startsAt); setPicked(n); }} />
                  {kstLabel(o.startsAt)}
                </label>
              </li>
            );
          })}
        </ul>
      </div>
    );
  };

  return (
    <div className="grid gap-2">
      {items.length > 1 ? (
        <select aria-label="보강할 수업" value={itemId} onChange={(e) => setItemId(e.target.value)} className={inputCls(false)}>
          {items.map((i) => <option key={i.id} value={i.id}>{kstLabel(i.startsAt)}{i.isLesson ? '' : ' · 시트 보강'} 수업분</option>)}
        </select>
      ) : (
        <ItemList items={items} />
      )}
      {opts === null ? (
        <p className="text-[13.5px] text-[#6b6880]">불러오는 중…</p>
      ) : opts.length === 0 ? (
        <p className="text-[13.5px] text-[#6b6880]">보강 가능한 날짜 없음</p>
      ) : (
        <>
          <div className="grid gap-1.5 rounded-[12px] border border-[#e6e3ef] px-3 py-2.5">
            <div className="flex items-center gap-2">
              <b className="flex-1 text-[14px] text-[#1d1b2b]">학생에게 보낼 글</b>
              <button type="button" className={copied ? btnDone : btnSub} onClick={async () => { if (await copyText(text)) setCopied(true); else setManual(true); }}>
                {copied ? '복사함 ✓' : '복사'}
              </button>
            </div>
            <pre className="whitespace-pre-wrap rounded-[10px] bg-[#f6f5fb] px-3 py-2 font-sans text-[13.5px] text-[#1d1b2b]">{text}</pre>
            {manual && <textarea readOnly value={text} rows={5} onFocus={(e) => e.currentTarget.select()} aria-label="복사할 글" className="w-full rounded-[10px] border border-[#e6e3ef] p-2 text-[13.5px]" />}
          </div>
          <b className="text-[14px] text-[#1d1b2b]">학생이 고른 날짜 ({picked.size}/{MAKEUP_SLOTS_MAX})</b>
          {section('in_period', '보강 가능한 날짜 · 수강기간 안')}
          {section('after_end', '보강 가능한 날짜 · 종료일 뒤')}
          <button type="button" className={btnMain} disabled={r.busy || picked.size === 0} onClick={() => r.run(
            () => actions.requestMakeup(item.lessonId ? { lessonId: item.lessonId } : { itemId: item.migratedItemId! }, [...picked].sort((a, b) => a - b).map((t) => new Date(t))),
            () => setPicked(new Set()),
          )}>
            보강 신청 ({picked.size})
          </button>
        </>
      )}
      <Err>{r.err}</Err>
    </div>
  );
}

// 안내 한 건: [복사] 누르면 회색 '복사함 ✓'(보냄을 눌러도 그대로), [보냄] 누르면 회색 '보냄 ✓'로 남고 더 못 누름 (다른 화면과 같게)
function MessageRow({ m, copied, onCopied, onSend }: { m: LvMessage; copied: boolean; onCopied: () => void; onSend: () => Promise<void> }) {
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState('');
  const [manual, setManual] = useState(false);
  const sent = m.status === 'sent';
  const act = async (f: () => Promise<void>) => {
    setBusy(true);
    setErr('');
    try { await f(); } catch (e) { setErr(e instanceof Error ? e.message : '기록하지 못했어요.'); } finally { setBusy(false); }
  };
  return (
    <div className="rounded-[12px] border border-[#e6e3ef] px-3 py-2.5">
      <div className="flex items-center gap-2">
        <b className="min-w-0 flex-1 text-[14.5px] text-[#1d1b2b]">{m.recipient === 'student' ? '학생' : '강사'} {m.to} · {LV_EVENT_TEXT[m.event]}</b>
        <button type="button" className={copied ? btnDone : btnSub} onClick={async () => { if (await copyText(m.text)) onCopied(); else setManual(true); }}>
          {copied ? '복사함 ✓' : '복사'}
        </button>
        {sent ? (
          <button type="button" disabled className={btnDone}>보냄 ✓</button>
        ) : (
          <button type="button" disabled={busy} className={btnMain} onClick={() => act(onSend)}>보냄</button>
        )}
      </div>
      <pre className="mt-2 whitespace-pre-wrap rounded-[10px] bg-[#f6f5fb] px-3 py-2 font-sans text-[13.5px] text-[#1d1b2b]">{m.text}</pre>
      {manual && <textarea readOnly value={m.text} rows={5} onFocus={(e) => e.currentTarget.select()} aria-label="복사할 글" className="mt-2 w-full rounded-[10px] border border-[#e6e3ef] p-2 text-[13.5px]" />}
      <Err>{err}</Err>
    </div>
  );
}
