'use client';

// 강사 휴무·대체강사 (2순위 ①, migration 1800, 2026-10-27 대표 시안 승인 Q1 A · Q2 A, 화면 흐름 안 1 확정)
// 위: 휴무 목록 · [+ 강사 휴무 등록] · 할 일 요약. PC: 왼쪽 학생 목록(지금 단계) · 오른쪽 고른 학생. 휴대폰: 학생 카드가 위아래로
// 학생 카드 = 단계 흐름(1 대체 강사에게 묻기 › 2 학생에게 휴무 안내 · 대체 강사 제안 › 3 학생 답 입력 › 4 확정 안내 보내기, 2026-10-28 대표 새 순서
//   정책 원본 H26(27), migration 2500) + 고른 단계 화면 하나. 앞 단계로는 단계 화면의 [← 뒤로]
// 대체강사: 운영진이 먼저 강사 가능 확인(가능한 날짜만 골라 저장) → 학생에게 휴무 안내와 함께 제안 → 학생 [좋아요] 뒤 확정 (A41). 안 되는 날짜는 다른 강사·보강으로
// 기존 강사 보강: 보강 가능한 날짜(지금 수강기간 안 → 종료일 뒤 평소 요일·시간)를 학생에게 보내고 2개까지 골라 신청 → 확정은 수업 변경·보강 화면 (A20)

import Link from 'next/link';
import { createContext, Fragment, useCallback, useContext, useEffect, useMemo, useState } from 'react';
import { instantToKstDate, type KstDate } from '@/lms/rules/dates';
import { dateLabel, enAt, kstLabel, MAKEUP_SLOTS_MAX } from '@/lms/admin/lesson-change';
import {
  groupByStudent, groupRenewals, itemStatus, leaveMessages, pendingNoticeKeys, studentPhase, tutorBundles, LV_EVENT_TEXT, LV_STEP_TEXT, makeupDatesText, renewalLeaveText, renewalTutorText, studentWork,
  type LvItem, type LvProposal, type LvTutorBundle, type LvRenewal, type LvRenewalGroup, type LvMakeupOption, type LvMessage, type LvNotice, type LvStep, type LvStudentGroup, type LvStudentWork, type LvSubOption, type LvTimeOff,
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
  /** 휴무 안내 '보냄'을 안 보냄으로 (모든 날짜가 학생 답 전일 때만) */
  unsend: (noticeIds: string[]) => Promise<void>;
  renewals: (timeOffId: string) => Promise<LvRenewal[]>;
};

const btnMain = 'min-h-[44px] rounded-[10px] bg-[#7d5ffb] px-4 text-[14.5px] font-bold text-white disabled:bg-[#cfc4ff]';
const btnSub = 'min-h-[44px] rounded-[10px] border border-[#e6e3ef] bg-white px-3.5 text-[14px] text-[#1d1b2b] disabled:text-[#b9b6c8]';
/** 누른 버튼: 회색으로 꽉 차게 (눌린 티) */
const btnDone = 'min-h-[44px] rounded-[10px] border border-[#c9c6d6] bg-[#d9d6e3] px-3.5 text-[14px] font-bold text-[#4a4760]';
const Err = ({ children }: { children: React.ReactNode }) => (children ? <p className="mt-1.5 text-[13px] text-[#b3261e]">{children}</p> : null);
/** 진행 상태 글자 (대표 10/29: '진행 중'·'완료'가 눈에 확 띄게) */
const STATUS_BADGE = { doing: 'border-2 border-[#f0a33a] bg-[#fff4d6] text-[#5c3b00]', fresh: 'border-2 border-[#b9b4cc] bg-white text-[#55526a]', done: 'border-2 border-[#1e7a46] bg-[#e3f6ea] text-[#1e7a46]' } as const;

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
  /** 성공하면 true — 화면을 옮길 때는 done(다시 읽기) 뒤에 옮겨야 done 이 보던 단계로 되돌리지 않음 */
  const run = async (f: () => Promise<unknown>, after?: () => void): Promise<boolean> => {
    setBusy(true);
    setErr('');
    try {
      await f();
      after?.();
      await done();
      return true;
    } catch (e) {
      setErr(e instanceof Error ? e.message : '처리하지 못했어요.');
      return false;
    } finally {
      setBusy(false);
    }
  };
  return { busy, err, setErr, run };
}

export default function TutorLeave({ tutors, actions, nowIso, initialOff, startNew }: { tutors: LvTutor[]; actions: LeaveActions; nowIso: string; initialOff?: string; startNew?: boolean }) {
  const now = useMemo(() => new Date(nowIso), [nowIso]);
  const [leaves, setLeaves] = useState<LvTimeOff[]>([]);
  const [offId, setOffId] = useState<string | null>(initialOff ?? null);
  // 맨 위 버튼 둘: 등록된 휴무 / 새 휴무 입력 (대표 10/29). ?new=1 이면 입력부터
  const [tab, setTab] = useState<'list' | 'new'>(startNew && !initialOff ? 'new' : 'list');
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
  const off = leaves.find((l) => l.id === offId) ?? null;
  const works = new Map(groups.map((g) => [g.studentId, studentWork(g, messages, now, off ?? undefined)]));
  const renewals = data ? groupRenewals(data.renewals) : [];
  const bundles = data ? tutorBundles(data.items, data.notices, now) : [];
  const phases = { todo: [] as LvStudentGroup[], wait: [] as LvStudentGroup[], done: [] as LvStudentGroup[] };
  for (const g of groups) phases[studentPhase(works.get(g.studentId)!)].push(g);
  // 처음 고른 곳: 처리할 학생 → 보내기 전 강사 문의 → 답 기다리는 학생 → 첫 학생
  const first = phases.todo[0]?.studentId ?? (bundles.find((b) => b.status === 'pending') && `t:${bundles.find((b) => b.status === 'pending')!.subTutorId}`)
    ?? phases.wait[0]?.studentId ?? groups[0]?.studentId ?? (renewals[0] ? `r:${renewals[0].studentId}` : null);
  const valid = (k: string) => groups.some((g) => g.studentId === k) || k.startsWith('r:') || bundles.some((b) => `t:${b.subTutorId}` === k);
  const selKey = sel && valid(sel) ? sel : first;
  // 처리해도 보던 학생에 머묾: 처음 자동으로 고른 것도 고정 (다음 학생으로 저절로 넘어가지 않음)
  useEffect(() => { if (selKey && selKey !== sel && (!sel || !valid(sel))) setSel(selKey); });

  const pending = useMemo(() => pendingNoticeKeys(data?.notices ?? []), [data]);

  return (
    <PENDING.Provider value={pending}>
    <div className="pb-24">
      <AdminHeader active="schedule" demo={false} />
      <main className="mx-auto grid max-w-[720px] gap-3 px-4 py-4 lg:max-w-[1120px]">
        <h1 className="text-[20px] font-extrabold text-[#1d1b2b]">강사 휴무</h1>

        <div role="tablist" className="grid grid-cols-2 gap-1.5">
          {(['list', 'new'] as const).map((t) => (
            <button key={t} type="button" role="tab" aria-selected={tab === t} onClick={() => setTab(t)}
              className={`min-h-[44px] rounded-[10px] border text-[15px] font-bold ${tab === t ? 'border-[#7d5ffb] bg-[#7d5ffb] text-white' : 'border-[#7d5ffb] bg-white text-[#5b3fe0]'}`}>
              {t === 'list' ? `등록된 휴무${leaves.length ? ` ${leaves.length}` : ''}` : '+ 새 휴무 입력'}
            </button>
          ))}
        </div>
        {tab === 'new' && (
          <NewLeave tutors={tutors} actions={actions} today={instantToKstDate(now)} onClose={() => setTab('list')}
            saved={async (id) => { await reloadLeaves(); setOffId(id); setTab('list'); }} />
        )}
        {tab === 'list' && leaves.length === 0 && <p className="text-[14px] text-[#6b6880]">등록된 휴무가 없어요.</p>}
        {tab === 'list' && <div className="flex flex-wrap items-center gap-1.5">
          {leaves.map((l) => (
            <button key={l.id} type="button" aria-pressed={l.id === offId} onClick={() => setOffId(l.id === offId ? null : l.id)}
              className={`min-h-[40px] rounded-full border px-3.5 text-[14px] ${l.id === offId ? 'border-[#7d5ffb] bg-[#efebff] font-bold text-[#5b3fe0]' : 'border-[#e6e3ef] bg-white text-[#1d1b2b]'}`}>
              {l.tutorName} · {dateLabel(l.from)} ~ {dateLabel(l.to)}
            </button>
          ))}
        </div>}
        <Err>{err}</Err>

        {tab === 'list' && offId && data && (
          <>
            <p className="rounded-[12px] bg-[#f6f5fb] px-3 py-2.5 text-[14px] text-[#1d1b2b]">
              {data.items.length === 0
                ? '이 휴무에 걸리는 수업이 없어요.'
                : `학생 ${groups.length}명 · 수업 ${data.items.length}회 · ${phases.todo.length + bundles.filter((b) => b.status === 'pending').length ? `처리할 것 ${phases.todo.length}명${bundles.some((b) => b.status === 'pending') ? ` · 강사 문의 ${bundles.filter((b) => b.status === 'pending').length}명` : ''}` : '처리할 것 없음'}${phases.wait.length ? ` · 답 기다리는 것 ${phases.wait.length}명` : ''}`}
              {renewals.length > 0 && ` · 재등록 대기 ${renewals.length}명(재등록하면 ${renewals.reduce((n, r) => n + r.dates.length, 0)}회)`}
            </p>

            {(groups.length > 0 || renewals.length > 0) && (
              <div className="grid gap-3 lg:grid-cols-[280px_1fr] lg:items-start">
                {/* 왼쪽(휴대폰은 위) 목록: 처리할 것 / 강사에게 묻기 / 답 기다리는 것 / 끝남 / 재등록 대기 (R15·R17) */}
                <ul className="grid gap-1.5">
                  {([['todo', '처리할 것'], ['wait', '답 기다리는 것'], ['done', '끝남']] as const).map(([ph, label]) => (
                    <Fragment key={ph}>
                      {ph === 'wait' && bundles.length > 0 && (
                        <li className="grid gap-1.5">
                          <h3 className="mt-1 text-[13px] font-bold text-[#55526a]">강사에게 묻기 {bundles.length}명</h3>
                          {bundles.map((b) => (
                            <ListButton key={b.subTutorId} on={selKey === `t:${b.subTutorId}`} onClick={() => setSel(`t:${b.subTutorId}`)}
                              name={b.subTutorName} sub={`학생 ${new Set(b.items.map((i) => i.studentId)).size}명 ${b.items.length}회 · ${b.status === 'pending' ? '문의 보내기 전' : '답변 기다리는 중'}`} />
                          ))}
                        </li>
                      )}
                      {phases[ph].length > 0 && (
                        <li className="grid gap-1.5">
                          <h3 className="mt-1 text-[13px] font-bold text-[#55526a]">{label} {phases[ph].length}명</h3>
                          {phases[ph].map((g) => (
                            <ListButton key={g.studentId} on={g.studentId === selKey} onClick={() => setSel(g.studentId)} name={g.studentName} done={ph === 'done'}
                              sub={nextText(g, works.get(g.studentId)!)} />
                          ))}
                        </li>
                      )}
                    </Fragment>
                  ))}
                  {renewals.length > 0 && <li className="mt-2 text-[13px] font-bold text-[#6b6880]">재등록 대기</li>}
                  {renewals.map((r) => (
                    <li key={r.studentId}>
                      <ListButton on={`r:${r.studentId}` === selKey} onClick={() => setSel(`r:${r.studentId}`)} name={r.studentName} sub={`${dateLabel(r.endDate)} 종료 · 재등록하면 ${r.dates.length}회`} />
                    </li>
                  ))}
                </ul>
                <div className="grid min-w-0 gap-3">
                  {groups.map((g) => (
                    <div key={g.studentId} className={g.studentId === selKey ? '' : 'hidden'}>
                      <StudentPanel g={g} w={works.get(g.studentId)!} msgs={messages.filter((m) => m.studentId === g.studentId)} leaveTutor={off?.tutorName ?? '기존'}
                        now={now} actions={actions} done={reload} openTutor={(id) => setSel(`t:${id}`)} />
                    </div>
                  ))}
                  {bundles.map((b) => (
                    <div key={b.subTutorId} className={`t:${b.subTutorId}` === selKey ? '' : 'hidden'}>
                      <TutorBundlePanel b={b} actions={actions} done={reload} />
                    </div>
                  ))}
                  {renewals.map((r) => (
                    <div key={r.studentId} className={`r:${r.studentId}` === selKey ? '' : 'hidden'}>
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
    </PENDING.Provider>
  );
}

function ListButton({ on, onClick, name, sub, done }: { on: boolean; onClick: () => void; name: string; sub: string; done?: boolean }) {
  return (
    <button type="button" aria-pressed={on} onClick={onClick}
      className={`grid w-full gap-0.5 rounded-[12px] border px-3 py-2.5 text-left ${on ? 'border-[#7d5ffb] bg-[#efebff]' : 'border-[#e6e3ef] bg-white'}`}>
      <b className={`text-[15px] ${done ? 'text-[#6b6880]' : 'text-[#1d1b2b]'}`}>{name}</b>
      <span className="text-[12.5px] text-[#55526a]">{sub}</span>
    </button>
  );
}

/** 목록 한 줄 글: 지금 할 일(첫 수업 날짜와 함께), 없으면 기다리는 것 */
function nextText(g: LvStudentGroup, w: LvStudentWork): string {
  const md = (i: LvItem) => dateLabel(instantToKstDate(i.startsAt));
  if (w.pick.length) return `${md(w.pick[0])} 대체 강사 고르기`;
  if (w.proposal?.status === 'pending') return LV_STEP_TEXT.propose;
  if (w.confirm.confirmedMsgs.length) return LV_STEP_TEXT.confirm;
  if (w.confirm.makeup.length) return `${md(w.confirm.makeup[0])} 보강 날짜 잡기`;
  if (w.tutor.length) return w.tutor.map((t) => (t.ask ? `${t.subTutorName} 강사님에게 문의 보내기 전` : `${t.subTutorName} 강사님 답`)).join(' · ');
  if (w.answer.length) return `학생 답 · 첫 수업 ${md(w.answer[0])}`;
  if (w.confirm.makeupRequested.length) return '보강 · 강사님 확인 기다림';
  return `${g.items.length}회 · ✓ 완료`;
}

function NewLeave({ tutors, actions, today, saved, onClose }: {
  tutors: LvTutor[]; actions: LeaveActions; today: KstDate; saved: (id: string) => Promise<void>; onClose: () => void;
}) {
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

  return (
    <Card title="새 휴무 입력">
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
            휴무 시작일
            <input type="date" value={from} min={today} onChange={(e) => { setFrom(e.target.value); if (!to || to < e.target.value) setTo(e.target.value); }} className={inputCls(false)} />
          </label>
          <label className="grid gap-1 text-[13px] text-[#6b6880]">
            휴무 종료일
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
          <button type="button" className={btnSub} onClick={onClose}>닫기</button>
          <button type="button" className={btnMain} disabled={!preview || busy} onClick={async () => {
            setBusy(true);
            setErr('');
            try {
              const r = await actions.create(tutorId, from, to, reason, false);
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

// 더 할 일이 없는 묶음: 사라지지 않고 접힘 (눌러서 펼치면 보낸 글·날짜가 그대로)
const Fold = ({ title, children }: { title: string; children: React.ReactNode }) => (
  <details className="rounded-[12px] border border-[#e6e3ef] px-3 py-2">
    <summary className="min-h-[36px] cursor-pointer py-1.5 text-[14px] font-bold text-[#1e7a46]">{title}</summary>
    <div className="mt-2 grid gap-2">{children}</div>
  </details>
);

// 휴무에 걸린 수업 순서: '첫 번째 수업 · 11/2(월) 12:00'
const ORD = ['첫', '두', '세', '네', '다섯', '여섯', '일곱', '여덟', '아홉', '열'];
const ordText = (n: number) => (n < ORD.length ? `${ORD[n]} 번째 수업` : `${n + 1}번째 수업`);
/** 안 보낸 안내 (상태 글 '보내기 전' 구분, R2·R4) */
const PENDING = createContext<ReadonlySet<string>>(new Set());

// 학생 한 명 (2026-10-30 대표 시안 승인, R11·R15): 수업마다 한 줄 = 지금 상태 + 그 수업에서 지금 누를 버튼. 끝난 수업은 '✓ 끝난 수업 n회'로 접힘(사라지지 않음).
// 줄 아래에는 지금 할 일이 있는 묶음만: 대체 강사 고르기(목록 하나, R12·R13) · 휴무 안내 글 · 확정 안내 · 보강 날짜. 대체강사 문의는 강사별 묶음(R17)
// 버튼·처리 함수는 이전과 같음 (새 단계·승인 없음). 처리 무르기는 줄의 [다시 고르기] + 확인창 (R1)
function StudentPanel({ g, w, msgs, leaveTutor, now, actions, done, openTutor }: {
  g: LvStudentGroup; w: LvStudentWork; msgs: LvMessage[]; leaveTutor: string; now: Date; actions: LeaveActions; done: () => Promise<void>; openTutor: (tutorId: string) => void;
}) {
  const r = useRun(done);
  const pending = useContext(PENDING);
  const [copied, setCopied] = useState<Set<string>>(new Set());
  /** 학생이 대체수업 대신 기존 강사 보강을 고른 수업 → 그 대체강사에게 보낼 취소 글 (이 화면에서만) */
  const [dropped, setDropped] = useState<LvItem[]>([]);
  // 대체 강사를 고를 날짜: 처음엔 고르기 전 날짜 모두. 목록은 하나 (R12)
  const pickKey = w.pick.map((i) => i.id).join(',');
  const [checked, setChecked] = useState<Set<string>>(() => new Set(w.pick.map((i) => i.id)));
  useEffect(() => { setChecked(new Set(pickKey ? pickKey.split(',') : [])); }, [pickKey]);

  const msg = (m: LvMessage) => (
    <MessageRow key={m.key} m={m} copied={overlaps(m, copied)}
      onCopied={() => setCopied(new Set([...copied, ...m.noticeIds]))}
      onSend={async () => { await actions.markSent(m.noticeIds); await done(); }} />
  );
  const pickSet = new Set(w.pick.map((i) => i.id));
  const answerSet = new Set(w.answer.map((i) => i.id));
  const finished = (i: LvItem) => i.startsAt <= now || itemStatus(i, pending).tone === 'done';
  const openItems = g.items.filter((i) => !finished(i));
  const closedItems = g.items.filter(finished);
  const ok = (its: LvItem[]) => r.run(() => actions.studentOk(its.map((i) => i.id)));
  const wait = (its: LvItem[]) => r.run(() => actions.choose(its.map((i) => i.id), 'wait', null), () => setDropped([...dropped, ...its.filter((i) => i.choice === 'substitute')]));
  const redo = async (i: LvItem) => {
    if (window.confirm(`${kstLabel(i.startsAt)} 수업을 처음부터 다시 고를까요?`)) await r.run(() => actions.back([i.id], 'undecided'));
  };
  const sm = 'min-h-[38px] text-[13.5px]';

  // 줄마다 지금 누를 것 하나(학생 답은 두 가지 답 중 하나)
  const rowAction = (i: LvItem): React.ReactNode => {
    if (pickSet.has(i.id)) return <button type="button" disabled={r.busy} className={`${btnSub} ${sm}`} onClick={() => wait([i])}>대체 강사 없음 → 보강</button>;
    if (answerSet.has(i.id)) return (
      <>
        <button type="button" disabled={r.busy} className={`${btnMain} ${sm}`} onClick={() => ok([i])}>대체수업 수락</button>
        <button type="button" disabled={r.busy} className={`${btnSub} ${sm}`} onClick={() => wait([i])}>기존 강사 보강 요청</button>
      </>
    );
    if (i.choice === 'substitute' && i.subStage === 'asked' && i.subTutorId) {
      return <button type="button" className={`${btnSub} ${sm}`} onClick={() => openTutor(i.subTutorId!)}>{i.subTutorName} 강사님에게 묻기 ›</button>;
    }
    if (i.choice !== 'undecided' && !i.lessonGone && i.startsAt > now) return <button type="button" disabled={r.busy} className={`${btnSub} ${sm}`} onClick={() => redo(i)}>다시 고르기</button>;
    return null;
  };
  const row = (i: LvItem, n: number) => {
    const s = itemStatus(i, pending);
    const box = pickSet.has(i.id) && w.pick.length > 1;
    return (
      <li key={i.id} className={`grid gap-1.5 rounded-[12px] px-3 py-2 ${s.tone === 'done' || i.startsAt <= now ? 'border border-[#e6e3ef]' : 'border-2 border-[#f0a33a]'}`}>
        <div className="flex flex-wrap items-center gap-x-2 gap-y-1">
          <label className="flex items-center gap-2 text-[14.5px] font-bold text-[#1d1b2b]">
            {box && <input type="checkbox" className="h-5 w-5" aria-label={`${kstLabel(i.startsAt)} 대체 강사 고를 날짜`} checked={checked.has(i.id)}
              onChange={(e) => { const c = new Set(checked); if (e.target.checked) c.add(i.id); else c.delete(i.id); setChecked(c); }} />}
            {ordText(n)} · {kstLabel(i.startsAt)}
          </label>
          <span className={`rounded-[6px] px-2 py-0.5 text-[12.5px] font-extrabold ${s.tone === 'done' ? STATUS_BADGE.done : STATUS_BADGE.doing}`}>{s.text}</span>
        </div>
        {rowAction(i) && <div className="flex flex-wrap gap-1.5">{rowAction(i)}</div>}
      </li>
    );
  };
  const order = new Map(g.items.map((i, n) => [i.id, n]));

  const p = w.proposal;
  const subTutors = [...new Map(g.items.filter((i) => i.choice === 'substitute' && i.subTutorId).map((i) => [i.subTutorId!, i.subTutorName ?? ''])).entries()];
  const confirmedSubs = g.items.filter((i) => i.choice === 'substitute' && i.subStage === 'confirmed' && !i.lessonGone);
  const picked = w.pick.filter((i) => checked.has(i.id));

  return (
    <Card title={<>{g.studentName} <span className="text-[13px] font-normal text-[#6b6880]">{g.studentCode}</span></>}>
      <div className="grid gap-2">
        {closedItems.length > 0 && (
          <Fold title={`✓ 끝난 수업 ${closedItems.length}회`}>
            <ul className="grid gap-1.5">{closedItems.map((i) => row(i, order.get(i.id)!))}</ul>
          </Fold>
        )}
        {openItems.length > 0 && <ul className="grid gap-1.5">{openItems.map((i) => row(i, order.get(i.id)!))}</ul>}

        {w.pick.length > 0 && (
          <Block title={w.pick.length > 1 ? `대체 강사 고르기 · 체크한 ${picked.length}회` : '대체 강사 고르기'}>
            {picked.length > 0 && <PickTutors key={picked.map((i) => i.id).join()} items={picked} actions={actions} done={done} />}
          </Block>
        )}
        {p?.status === 'pending' && (
          <Block title={LV_STEP_TEXT.propose}>
            <ProposalRow key={p.noticeIds.join()} p={p} to={g.studentName} onSend={async () => { await actions.markSent(p.noticeIds); await done(); }} />
          </Block>
        )}
        {w.answer.length > 1 && (
          <Block title={LV_STEP_TEXT.answer}>
            <div className="grid grid-cols-2 gap-1.5">
              <button type="button" disabled={r.busy} className={btnMain} onClick={() => ok(w.answer)}>모두 대체수업 수락</button>
              <button type="button" disabled={r.busy} className={btnSub} onClick={() => wait(w.answer)}>모두 기존 강사 보강 요청</button>
            </div>
          </Block>
        )}
        {subTutors.map(([tid, name]) => {
          const its = dropped.filter((i) => i.subTutorId === tid);
          return its.length ? <CopyBox key={`cancel-${tid}`} title={`${name} 강사님에게 취소 알리기`} text={subCancelText(its)} /> : null;
        })}
        {subTutors.map(([tid, name]) => {
          const ids = new Set(confirmedSubs.filter((i) => i.subTutorId === tid).map((i) => i.id));
          if (ids.size === 0) return null;
          const mine = msgs.filter((m) => m.event === 'sub_confirmed' && m.itemIds.some((id) => ids.has(id)));
          const body = <>{mine.map((m) => msg(m))}</>;
          // 제목 횟수 = 본문(안내 글)에 든 수업 수 (취소된 수업은 둘 다에서 빠짐)
          const n = new Set(mine.flatMap((m) => m.itemIds).filter((id) => ids.has(id))).size || ids.size;
          return mine.some((m) => m.status === 'pending')
            ? <Block key={`c-${tid}`} title={`${LV_STEP_TEXT.confirm} · ${name} 강사님 ${n}회`}>{body}</Block>
            : <Fold key={`c-${tid}`} title={`✓ ${name} 강사님 ${n}회 확정 안내 보냄`}>{body}</Fold>;
        })}
        {w.confirm.makeup.length > 0 && <Block title={`${leaveTutor} 강사님 복귀 뒤 보강 날짜 잡기`}><MakeupPick g={g} items={w.confirm.makeup} actions={actions} done={done} /></Block>}
        {w.confirm.makeupRequested.length > 0 && (
          <Block title={`${leaveTutor} 강사님 확인 후 보강 확정`}>
            <Link href={`/lms/admin/change?student=${encodeURIComponent(g.studentCode)}`} className="flex min-h-[44px] items-center justify-center rounded-[10px] border border-[#7d5ffb] text-[14px] font-semibold text-[#5b3fe0]">
              보강 확정
            </Link>
          </Block>
        )}
        {p?.status === 'sent' && <Fold title="✓ 휴무 안내 보냄"><ProposalRow p={p} to={g.studentName} onSend={async () => {}} /></Fold>}
        <Err>{r.err}</Err>
      </div>
    </Card>
  );
}

// 대체강사 한 명에게 묻기 (R17): 여러 학생 수업을 한 메시지로, [보냄]도 한 번. 답은 수업마다 체크 (처음엔 체크 없음, R3)
function TutorBundlePanel({ b, actions, done }: { b: LvTutorBundle; actions: LeaveActions; done: () => Promise<void> }) {
  const [copied, setCopied] = useState(false);
  const m: LvMessage = { key: `ask-${b.subTutorId}`, event: 'sub_ask', recipient: 'tutor', to: b.subTutorName, studentId: '', recipientId: b.subTutorId,
    itemIds: b.items.map((i) => i.id), noticeIds: b.noticeIds, status: b.status, text: b.text };
  const students = new Set(b.items.map((i) => i.studentId)).size;
  return (
    <Card title={<>{b.subTutorName} 강사님에게 묻기 <span className="text-[13px] font-normal text-[#6b6880]">학생 {students}명 {b.items.length}회</span></>}>
      <div className="grid gap-3">
        <MessageRow m={m} copied={copied} onCopied={() => setCopied(true)}
          onSend={async () => { if (b.noticeIds.length) await actions.markSent(b.noticeIds); await done(); }} />
        <TutorCheck key={b.items.map((i) => i.id).join()} t={{ subTutorId: b.subTutorId, subTutorName: b.subTutorName, items: b.items, ask: null }} actions={actions} done={done} />
      </div>
    </Card>
  );
}

/** 3단계에서 학생이 기존 강사와 보강을 골랐을 때 대체강사에게 보내는 글 (휴무 강사 이름은 안 씀) */
function subCancelText(items: LvItem[]): string {
  const tz = items[0].subTutorTz ?? 'Asia/Seoul';
  return [
    `Cancelled - ${items[0].studentNameEn} (${items[0].durationMin} min)`,
    'The student will wait for their regular tutor, so these classes are no longer needed:',
    ...items.map((x, n) => `${n + 1}) ${enAt(x.startsAt, tz)}`),
    'Thank you for making time!',
  ].join('\n');
}

// 2단계 글 한 건: 휴무 안내 + 대체 강사 제안. [복사] → 회색 '복사함 ✓', [보냄] → 회색 '보냄 ✓'
function ProposalRow({ p, to, onSend }: { p: LvProposal; to: string; onSend: () => Promise<void> }) {
  const [copied, setCopied] = useState(false);
  const [manual, setManual] = useState(false);
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState('');
  return (
    <div className="rounded-[12px] border border-[#e6e3ef] px-3 py-2.5">
      <div className="flex items-center gap-2">
        <b className="min-w-0 flex-1 text-[14.5px] text-[#1d1b2b]">학생 {to}</b>
        <button type="button" className={copied ? btnDone : btnSub} onClick={async () => { if (await copyText(p.text)) setCopied(true); else setManual(true); }}>
          {copied ? '복사함 ✓' : '복사'}
        </button>
        {p.status === 'sent' ? (
          <button type="button" disabled className={btnDone}>보냄 ✓</button>
        ) : (
          <button type="button" disabled={busy} className={btnMain} onClick={async () => {
            setBusy(true); setErr('');
            try { await onSend(); } catch (e) { setErr(e instanceof Error ? e.message : '기록하지 못했어요.'); } finally { setBusy(false); }
          }}>보냄</button>
        )}
      </div>
      <pre className="mt-2 whitespace-pre-wrap rounded-[10px] bg-[#f6f5fb] px-3 py-2 font-sans text-[13.5px] text-[#1d1b2b]">{p.text}</pre>
      {manual && <textarea readOnly value={p.text} rows={6} onFocus={(e) => e.currentTarget.select()} aria-label="복사할 글" className="mt-2 w-full rounded-[10px] border border-[#e6e3ef] p-2 text-[13.5px]" />}
      <Err>{err}</Err>
    </div>
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

/** 날짜·상태 글 목록 (보강 날짜 잡기에서 한 수업일 때) */
function ItemList({ items }: { items: LvItem[] }) {
  const pending = useContext(PENDING);
  return (
    <ul className="grid gap-1.5">
      {items.map((i) => (
        <li key={i.id} className="flex min-h-[44px] flex-wrap items-center gap-2 rounded-[10px] border border-[#e6e3ef] px-3 py-1.5">
          <span className="text-[14.5px] text-[#1d1b2b]">{kstLabel(i.startsAt)}</span>
          <span className="ml-auto text-[12.5px] text-[#55526a]">{itemStatus(i, pending).text}</span>
        </li>
      ))}
    </ul>
  );
}

// 남은 수업 전체 기준 강사별 맡을 수 있는 횟수 (많은 순). 누르면 그 강사가 되는 날짜를 모두 그 강사로 → 남은 날짜는 아래 줄마다 (2026-10-28 대표)
function PickTutors({ items, actions, done }: { items: LvItem[]; actions: LeaveActions; done: () => Promise<void> }) {
  const [options, setOptions] = useState<LvSubOption[] | null>(null);
  const r = useRun(done);
  const { setErr } = r;
  const ids = items.map((i) => i.id).join(',');
  useEffect(() => {
    let live = true;
    actions.subOptions(ids.split(',')).then(
      (o) => live && setOptions(o),
      (e) => live && setErr(e instanceof Error ? e.message : '강사 목록을 읽지 못했어요.'),
    );
    return () => { live = false; };
  }, [actions, ids, setErr]);
  return (
    <div className="grid gap-1.5">
      {options === null ? <p className="text-[13.5px] text-[#6b6880]">불러오는 중…</p>
        : <SubOptions options={options} items={items} busy={r.busy} pick={(id, sel) => r.run(() => actions.choose(sel, 'substitute', id))} />}
      <Err>{r.err}</Err>
    </div>
  );
}

// 대체강사 목록 하나 (R12·R13): 날짜마다 '평소 가능시간과 일치' / '평소 시간표 밖 · 문의 필요'(골라도 됨, 2700) / '불가'(다른 수업·휴무·불가 답).
// 고르면 불가가 아닌 날짜만 그 강사로, 불가 날짜는 그대로 남음
function SubOptions({ options, items, busy, pick }: { options: LvSubOption[]; items: LvItem[]; busy: boolean; pick: (tutorId: string, itemIds: string[]) => void }) {
  const md = (i: LvItem) => instantToKstDate(i.startsAt).slice(5).split('-').map(Number).join('/');
  const all = items.length;
  return (
    <ul className="grid gap-1.5">
      {options.length === 0 && <li className="text-[13.5px] text-[#6b6880]">고를 수 있는 강사가 없어요.</li>}
      {options.map((o) => {
        const can = items.filter((i) => !o.busyDates.includes(md(i)));
        return (
          <li key={o.tutorId}>
            <button type="button" disabled={busy || can.length === 0} onClick={() => pick(o.tutorId, can.map((i) => i.id))}
              className="flex min-h-[48px] w-full flex-wrap items-center gap-x-2 rounded-[12px] border border-[#e6e3ef] bg-white px-3 py-2 text-left disabled:bg-[#faf9fd] disabled:text-[#b9b6c8]">
              <b className="text-[15px]">{o.name}</b>
              <span className="flex flex-1 flex-col items-end text-right text-[13px]">
                {o.free > 0 && <span className="text-[#1e7a46]">{o.free === all ? '모두' : `${o.free}회`} 평소 가능시간과 일치</span>}
                {o.offHours.length > 0 && <span className="text-[#5c3b00]">{o.offHours.join('·')} 평소 시간표 밖 · 문의 필요</span>}
                {o.busyDates.length > 0 && <span className="text-[#b3261e]">{o.busyDates.join('·')} 불가</span>}
              </span>
            </button>
          </li>
        );
      })}
    </ul>
  );
}

// 대체강사 답: 가능하다고 한 날짜만 체크해 저장. 체크 안 한 날짜는 다른 강사 또는 기존 강사 보강으로
function TutorCheck({ t, actions, done }: { t: LvStudentWork['tutor'][number]; actions: LeaveActions; done: () => Promise<void> }) {
  // 처음엔 아무것도 체크 안 함: 강사가 실제로 가능하다고 답한 날짜만 체크 (R3)
  const [ok, setOk] = useState<Set<string>>(() => new Set());
  const [options, setOptions] = useState<LvSubOption[] | null>(null);
  const r = useRun(done);
  const yes = t.items.filter((i) => ok.has(i.id)).map((i) => i.id);
  const no = t.items.filter((i) => !ok.has(i.id)).map((i) => i.id);

  // 고른 강사를 무름 → 확인창에 걸리는 수업 (R1)
  const reset = () => {
    if (window.confirm(`${t.subTutorName} 강사님 대신 다시 고를까요?\n${t.items.map((i) => `- ${kstLabel(i.startsAt)}`).join('\n')}`)) r.run(() => actions.back(t.items.map((i) => i.id), 'undecided'));
  };
  return (
    <div className="grid gap-2">
      <span className="text-[13px] text-[#6b6880]">{t.subTutorName} 강사님이 가능하다고 답한 날짜 선택</span>
      <ul className="grid gap-1.5">
        {t.items.map((i) => (
          <li key={i.id}>
            <label className="flex min-h-[44px] items-center gap-2 rounded-[10px] border border-[#e6e3ef] px-3 text-[14.5px] text-[#1d1b2b]">
              <input type="checkbox" className="h-5 w-5" checked={ok.has(i.id)}
                onChange={(e) => { const n = new Set(ok); if (e.target.checked) n.add(i.id); else n.delete(i.id); setOk(n); setOptions(null); }} />
              {kstLabel(i.startsAt)} · {i.studentName}
            </label>
          </li>
        ))}
      </ul>
      <button type="button" disabled={r.busy || yes.length === 0} className={btnMain} onClick={() => r.run(() => actions.subOk(yes))}>
        강사 가능 여부 확인 완료
      </button>
      {no.length > 0 && (
        <>
          {/* 체크 안 한 날짜 = 아직 모름 (거절로 표시하지 않음) */}
          <span className="text-[13px] text-[#6b6880]">체크 안 한 날짜 {no.length}회</span>
          <div className="grid grid-cols-2 gap-1.5">
            <button type="button" disabled={r.busy} className={btnSub} onClick={async () => {
              r.setErr('');
              try { setOptions((await actions.subOptions(no)).filter((o) => o.tutorId !== t.subTutorId)); } catch (e) { r.setErr(e instanceof Error ? e.message : '강사 목록을 읽지 못했어요.'); }
            }}>
              다른 대체강사 선택
            </button>
            <button type="button" disabled={r.busy} className={btnSub} onClick={() => r.run(() => actions.choose(no, 'wait', null))}>
              대체 강사 없음 → 보강
            </button>
          </div>
          {options && <SubOptions options={options} items={t.items.filter((i) => no.includes(i.id))} busy={r.busy} pick={(id, sel) => r.run(() => actions.choose(sel, 'substitute', id))} />}
        </>
      )}
      {/* 이 강사 대신 처음부터 다시 고르기 (대표 10/29) */}
      <button type="button" disabled={r.busy} className={btnSub} onClick={reset}>
        강사 다시 고르기
      </button>
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
          {items.map((i) => <option key={i.id} value={i.id}>{kstLabel(i.startsAt)}</option>)}
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
            학생이 선택한 날짜로 보강 신청 ({picked.size})
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
