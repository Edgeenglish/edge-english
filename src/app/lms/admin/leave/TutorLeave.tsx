'use client';

// 강사 휴무·대체강사 (2순위 ①, migration 1800, 2026-10-27 대표 시안 승인 Q1 A · Q2 A)
// 카드: 1 휴무 넣기(강사·기간 → 걸리는 수업 미리 보기 → [저장]) · 2 휴무 고르기 · 3 학생별 처리(대체강사 / 기다림, 일부 날짜만 다르게)
//       · 4 안내(학생·강사마다 한 메시지 [복사] → 보낸 뒤 [보냈어요]). 휴무를 넣으면 학생에게 두 가지 선택 안내(① 대체강사 · 추천 / ② 기존 강사 보강)
// 대체강사: 강사 가능 → 학생 안내 → 학생 OK 뒤 확정 (A41)
// 기존 강사 보강: 후보(지금 수강기간 안 → 종료일 뒤 평소 요일·시간)에서 골라 신청 → 확정은 수업 변경·보강 화면 (종료일 뒤면 자동 연장, A20)

import Link from 'next/link';
import { useCallback, useEffect, useMemo, useState } from 'react';
import { instantToKstDate, type KstDate } from '@/lms/rules/dates';
import { dateLabel, kstLabel } from '@/lms/admin/lesson-change';
import {
  groupByStudent, groupChoice, itemStatus, leaveMessages, leaveSummary, LV_EVENT_TEXT,
  type LvItem, type LvMakeupOption, type LvMessage, type LvNotice, type LvStudentGroup, type LvSubOption, type LvTimeOff,
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
};

const btnMain = 'min-h-[44px] rounded-[10px] bg-[#7d5fff] px-4 text-[14.5px] font-bold text-white disabled:bg-[#cfc4ff]';
const btnSub = 'min-h-[44px] rounded-[10px] border border-[#e6e3ef] bg-white px-3.5 text-[14px] text-[#1d1b2b] disabled:text-[#b9b6c8]';
const Err = ({ children }: { children: React.ReactNode }) => (children ? <p className="mt-1.5 text-[13px] text-[#b3261e]">{children}</p> : null);
const TONE = { todo: 'bg-[#fff8d6] text-[#5c4a00]', wait: 'bg-[#e9f4ff] text-[#1b5a8a]', done: 'bg-[#e3f6ea] text-[#1e7a46]' } as const;

async function copyText(text: string): Promise<boolean> {
  try {
    await navigator.clipboard.writeText(text);
    return true;
  } catch {
    return false;
  }
}

export default function TutorLeave({ tutors, actions, nowIso, initialOff }: { tutors: LvTutor[]; actions: LeaveActions; nowIso: string; initialOff?: string }) {
  const now = useMemo(() => new Date(nowIso), [nowIso]);
  const [leaves, setLeaves] = useState<LvTimeOff[]>([]);
  const [offId, setOffId] = useState<string | null>(initialOff ?? null);
  const [data, setData] = useState<{ items: LvItem[]; notices: LvNotice[] } | null>(null);
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
      setData(await actions.items(offId));
    } catch (e) {
      setErr(e instanceof Error ? e.message : '불러오지 못했어요.');
    }
  }, [actions, offId]);
  useEffect(() => {
    reloadLeaves();
  }, [reloadLeaves]);
  useEffect(() => {
    setData(null);
    reload();
  }, [reload]);

  const off = leaves.find((l) => l.id === offId) ?? null;
  const groups = data ? groupByStudent(data.items) : [];
  const sum = data ? leaveSummary(data.items, data.notices) : null;
  const messages = data && off ? leaveMessages(data.items, data.notices, off.tutorName) : [];
  const pendingMsgs = messages.filter((m) => m.status === 'pending');

  return (
    <div className="pb-24">
      <AdminHeader active="schedule" demo={false} />
      <main className="mx-auto grid max-w-[720px] gap-3 px-4 py-4">
        <h1 className="text-[20px] font-extrabold text-[#1d1b2b]">강사 휴무</h1>

        <NewLeave tutors={tutors} actions={actions} today={instantToKstDate(now)} saved={async (id) => { await reloadLeaves(); setOffId(id); }} />

        {leaves.length > 0 && (
          <Card title="휴무 목록">
            <ul className="grid gap-1.5">
              {leaves.map((l) => (
                <li key={l.id}>
                  <button type="button" aria-pressed={l.id === offId} onClick={() => setOffId(l.id === offId ? null : l.id)}
                    className={`flex min-h-[48px] w-full items-center gap-2 rounded-[12px] border px-3 py-2 text-left ${l.id === offId ? 'border-[#7d5fff] bg-[#efebff]' : 'border-[#e6e3ef] bg-white'}`}>
                    <b className="text-[15.5px] text-[#1d1b2b]">{l.tutorName}</b>
                    <span className="flex-1 text-right text-[13.5px] text-[#6b6880]">{dateLabel(l.from)} ~ {dateLabel(l.to)}{l.reason ? ` · ${l.reason}` : ''}</span>
                  </button>
                </li>
              ))}
            </ul>
          </Card>
        )}
        <Err>{err}</Err>

        {off && data && sum && (
          <>
            <p className="rounded-[12px] bg-[#f6f5fb] px-3 py-2.5 text-[14px] text-[#1d1b2b]">
              {data.items.length === 0
                ? '이 휴무에 걸리는 수업이 없어요.'
                : [
                    `수업 ${data.items.length}회 · 학생 ${groups.length}명`,
                    sum.undecidedStudents > 0 && `학생 선택 미확인 ${sum.undecidedStudents}명`,
                    sum.tutorReply > 0 && `대체강사 답 대기 ${sum.tutorReply}회`,
                    sum.studentReply > 0 && `학생 OK 대기 ${sum.studentReply}회`,
                    sum.makeupOpen > 0 && `보강 날짜 미정 ${sum.makeupOpen}회`,
                    sum.pendingNotices > 0 && `안내 안 보냄 ${pendingMsgs.length}건`,
                  ].filter(Boolean).join(' · ')}
            </p>

            {pendingMsgs.length > 0 && (
              <Card title="안내">
                <ul className="grid gap-2">
                  {pendingMsgs.map((m) => <MessageRow key={m.key} m={m} markSent={async () => { await actions.markSent(m.noticeIds); await reload(); }} />)}
                </ul>
              </Card>
            )}

            {groups.map((g) => <StudentCard key={g.studentId} g={g} now={now} actions={actions} done={reload} />)}

            {messages.some((m) => m.status === 'sent') && (
              <Card title="보낸 안내">
                <ul className="grid gap-2">
                  {messages.filter((m) => m.status === 'sent').map((m) => <MessageRow key={m.key} m={m} markSent={async () => {}} />)}
                </ul>
              </Card>
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

function StudentCard({ g, now, actions, done }: { g: LvStudentGroup; now: Date; actions: LeaveActions; done: () => Promise<void> }) {
  // 지난 수업·확정된 대체 수업은 고를 대상에서 빼고, 나머지를 기본으로 한 번에 (Q1 A)
  const changeable = g.items.filter((i) => i.startsAt > now && !(i.choice === 'wait' && (i.makeupAt || i.makeupRequested)));
  const [some, setSome] = useState(false);
  const [picked, setPicked] = useState<Set<string>>(() => new Set(changeable.map((i) => i.id)));
  const [options, setOptions] = useState<LvSubOption[] | null>(null);
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState('');
  const target = some ? changeable.filter((i) => picked.has(i.id)) : changeable;
  const ids = target.map((i) => i.id);
  const asked = g.items.filter((i) => i.choice === 'substitute' && i.subStage === 'asked');
  const tutorOk = g.items.filter((i) => i.choice === 'substitute' && i.subStage === 'tutor_ok');
  const choice = groupChoice(g.items);
  const needMakeup = g.items.filter((i) => i.choice === 'wait' && !i.makeupAt && !i.makeupRequested);

  async function run(f: () => Promise<void>) {
    setBusy(true);
    setErr('');
    try {
      await f();
      setOptions(null);
      setPicked(new Set());
      await done();
    } catch (e) {
      setErr(e instanceof Error ? e.message : '처리하지 못했어요.');
    } finally {
      setBusy(false);
    }
  }

  return (
    <Card title={<>{g.studentName} <span className="text-[13px] font-normal text-[#6b6880]">{g.studentCode}</span></>}
      badge={choice === 'mixed' ? <span className="rounded-[6px] bg-[#efebff] px-2 py-0.5 text-[12px] font-bold text-[#5b3fe0]">날짜마다 다름</span> : null}>
      <ul className="grid gap-1.5">
        {g.items.map((i) => {
          const s = itemStatus(i);
          const can = changeable.some((c) => c.id === i.id);
          return (
            <li key={i.id} className="flex min-h-[44px] items-center gap-2 rounded-[10px] border border-[#e6e3ef] px-3 py-1.5">
              {some && can && (
                <input type="checkbox" aria-label={`${kstLabel(i.startsAt)} 고르기`} checked={picked.has(i.id)} className="h-5 w-5"
                  onChange={(e) => { const n = new Set(picked); if (e.target.checked) n.add(i.id); else n.delete(i.id); setPicked(n); }} />
              )}
              <span className="text-[14.5px] text-[#1d1b2b]">{kstLabel(i.startsAt)}{i.isLesson ? '' : ' · 시트 보강'}</span>
              <span className={`ml-auto rounded-[6px] px-2 py-0.5 text-[12px] font-bold ${TONE[s.tone]}`}>{s.text}</span>
            </li>
          );
        })}
      </ul>

      {changeable.length > 0 && (
        <div className="mt-3 grid gap-2">
          {changeable.length > 1 && (
            <button type="button" className="min-h-[40px] text-left text-[13.5px] font-semibold text-[#5b3fe0]" onClick={() => setSome(!some)}>
              {some ? '모든 날짜 한 번에 ›' : '일부 날짜만 다르게 처리 ›'}
            </button>
          )}
          <div className="grid grid-cols-2 gap-1.5">
            <button type="button" disabled={busy || ids.length === 0} className={btnSub} onClick={async () => {
              setErr('');
              try { setOptions(await actions.subOptions(ids)); } catch (e) { setErr(e instanceof Error ? e.message : '강사 목록을 읽지 못했어요.'); }
            }}>
              대체강사
            </button>
            <button type="button" disabled={busy || ids.length === 0} className={btnSub} onClick={() => run(() => actions.choose(ids, 'wait', null))}>
              기존 강사 보강
            </button>
          </div>
          {options && (
            <ul className="grid gap-1.5">
              {options.length === 0 && <li className="text-[13.5px] text-[#6b6880]">고를 수 있는 강사가 없어요.</li>}
              {options.map((o) => (
                <li key={o.tutorId}>
                  <button type="button" disabled={busy || o.free < ids.length} onClick={() => run(() => actions.choose(ids, 'substitute', o.tutorId))}
                    className="flex min-h-[48px] w-full items-center gap-2 rounded-[12px] border border-[#e6e3ef] bg-white px-3 py-2 text-left disabled:bg-[#faf9fd] disabled:text-[#b9b6c8]">
                    <b className="text-[15px]">{o.name}</b>
                    <span className="flex-1 text-right text-[13px] text-[#6b6880]">
                      {o.free === ids.length ? `${ids.length}회 모두 가능` : `${o.free}회 가능 · ${o.busyDates.join('·')} 겹침`}
                    </span>
                  </button>
                </li>
              ))}
            </ul>
          )}
        </div>
      )}

      {(asked.length > 0 || tutorOk.length > 0) && (
        <div className="mt-3 grid gap-1.5">
          {asked.length > 0 && (
            <button type="button" disabled={busy} className={btnMain} onClick={() => run(() => actions.subOk(asked.map((i) => i.id)))}>
              {asked[0].subTutorName} 가능 ({asked.length}회)
            </button>
          )}
          {tutorOk.length > 0 && (
            <button type="button" disabled={busy} className={btnMain} onClick={() => run(() => actions.studentOk(tutorOk.map((i) => i.id)))}>
              학생 OK → 확정 ({tutorOk.length}회)
            </button>
          )}
        </div>
      )}
      {needMakeup.length > 0 && <MakeupPick items={needMakeup} actions={actions} done={done} />}
      {g.items.some((i) => i.makeupRequested) && (
        <Link href={`/lms/admin/change?student=${encodeURIComponent(g.studentCode)}`} className="mt-3 flex min-h-[44px] items-center justify-center rounded-[10px] border border-[#7d5fff] text-[14px] font-semibold text-[#5b3fe0]">
          보강 확정
        </Link>
      )}
      <Err>{err}</Err>
    </Card>
  );
}

// 기존 강사 보강 후보: 지금 수강기간 안 먼저, 종료일 뒤 평소 요일·시간 (확정하면 그날까지 자동 연장)
function MakeupPick({ items, actions, done }: { items: LvItem[]; actions: LeaveActions; done: () => Promise<void> }) {
  const [itemId, setItemId] = useState(items[0].id);
  const [opts, setOpts] = useState<LvMakeupOption[] | null>(null);
  const [picked, setPicked] = useState<Set<number>>(new Set());
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState('');
  const item = items.find((i) => i.id === itemId) ?? items[0];
  const section = (s: LvMakeupOption['section'], title: string) => {
    const list = (opts ?? []).filter((o) => o.section === s);
    if (list.length === 0) return null;
    return (
      <div className="grid gap-1">
        <b className="text-[13px] text-[#6b6880]">{title}</b>
        <ul className="grid max-h-[260px] gap-1 overflow-y-auto">
          {list.map((o) => (
            <li key={+o.startsAt}>
              <label className="flex min-h-[44px] items-center gap-2 rounded-[10px] border border-[#e6e3ef] px-3 text-[14.5px] text-[#1d1b2b]">
                <input type="checkbox" className="h-5 w-5" checked={picked.has(+o.startsAt)}
                  onChange={(e) => { const n = new Set(picked); if (e.target.checked) n.add(+o.startsAt); else n.delete(+o.startsAt); setPicked(n); }} />
                {kstLabel(o.startsAt)}
              </label>
            </li>
          ))}
        </ul>
      </div>
    );
  };
  return (
    <div className="mt-3 grid gap-2 rounded-[12px] border border-[#e6e3ef] p-3">
      <b className="text-[14.5px] text-[#1d1b2b]">보강 후보</b>
      {items.length > 1 && (
        <select aria-label="보강할 수업" value={itemId} onChange={(e) => { setItemId(e.target.value); setPicked(new Set()); }} className={inputCls(false)}>
          {items.map((i) => <option key={i.id} value={i.id}>{kstLabel(i.startsAt)} 수업분</option>)}
        </select>
      )}
      {opts === null ? (
        <button type="button" className={btnSub} disabled={busy} onClick={async () => {
          setErr('');
          try { setOpts(await actions.makeupOptions(items.map((i) => i.id))); } catch (e) { setErr(e instanceof Error ? e.message : '후보를 읽지 못했어요.'); }
        }}>
          후보 보기
        </button>
      ) : (
        <>
          {section('in_period', '수강기간 안')}
          {section('after_end', '종료일 뒤 평소 요일·시간')}
          {opts.length === 0 && <p className="text-[13.5px] text-[#6b6880]">후보 없음</p>}
          <button type="button" className={btnMain} disabled={busy || picked.size === 0} onClick={async () => {
            setBusy(true);
            setErr('');
            try {
              await actions.requestMakeup(item.lessonId ? { lessonId: item.lessonId } : { itemId: item.migratedItemId! }, [...picked].sort((a, b) => a - b).map((t) => new Date(t)));
              setPicked(new Set());
              setOpts(null);
              await done();
            } catch (e) {
              setErr(e instanceof Error ? e.message : '신청하지 못했어요.');
            } finally {
              setBusy(false);
            }
          }}>
            보강 신청 ({picked.size})
          </button>
        </>
      )}
      <Err>{err}</Err>
    </div>
  );
}

function MessageRow({ m, markSent }: { m: LvMessage; markSent: () => Promise<void> }) {
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState('');
  const [copied, setCopied] = useState(false);
  const [manual, setManual] = useState(false);
  const sent = m.status === 'sent';
  return (
    <li className="rounded-[12px] border border-[#e6e3ef] px-3 py-2.5">
      <div className="flex items-center gap-2">
        <div className="min-w-0 flex-1">
          <b className="block text-[14.5px] text-[#1d1b2b]">{m.recipient === 'student' ? '학생' : '강사'} {m.to} · {LV_EVENT_TEXT[m.event]}</b>
          <span className="text-[12.5px] text-[#6b6880]">{sent ? '보냄' : copied ? '복사함' : '안 보냄'}</span>
        </div>
        <button type="button" className={btnSub} onClick={async () => { if (await copyText(m.text)) setCopied(true); else setManual(true); }}>
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
      <pre className="mt-2 whitespace-pre-wrap rounded-[10px] bg-[#f6f5fb] px-3 py-2 font-sans text-[13.5px] text-[#1d1b2b]">{m.text}</pre>
      {manual && <textarea readOnly value={m.text} rows={5} onFocus={(e) => e.currentTarget.select()} aria-label="복사할 글" className="mt-2 w-full rounded-[10px] border border-[#e6e3ef] p-2 text-[13.5px]" />}
      <Err>{err}</Err>
    </li>
  );
}
