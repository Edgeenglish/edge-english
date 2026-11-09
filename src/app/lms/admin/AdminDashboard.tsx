'use client';

// 운영진 대시보드 5차 (대표 2026-11-09, 시안 https://claude.ai/artifact/VEzLG1nzfnfNzT73ac4wYY + H26(114))
//  PC: 숫자 칸 4개 → (펼친 명단) → 왼쪽 운영진 할 일 / 오른쪽 오늘 수업 · 빠른 메뉴 · 공지
//  휴대폰: 숫자 칸 → 운영진 할 일 → 오늘 수업 → 빠른 메뉴 → 공지
//  운영진 할 일 = 운영진이 직접 풀 일만. 마지막 필수 처리가 끝나면 다시 읽을 때 저절로 빠짐 ([카드 닫기] 없음). 성공 안내 없음, 실패만 짧게
// 미리보기(?demo=1)에서는 버튼을 눌러도 화면 안에서만 바뀌고 저장·발송하지 않는다.

import { useEffect, useMemo, useState } from 'react';
import Link from 'next/link';
import { buildBoard, CATEGORY_LABEL, categoryCounts, filterBoard, isUrgent, searchBoard, type BoardFilter, type BoardItem, type Category, type TaskSource } from '@/lms/admin/board';
import { fakeTasks } from '@/lms/admin/fake-data';
import type { PlanView } from '@/lms/admin/confirm';
import type { PlanActions } from '@/lms/admin/confirm-live';
import type { DashboardStats } from '@/lms/admin/live';
import { ENDING_STATE_TEXT, mdw, type LessonItem } from '@/lms/admin/dashboard';
import { instantToKstDate } from '@/lms/rules/dates';
import PlanCard, { type PlanHandlers } from './PlanCard';
import HistoryPanel from './HistoryPanel';
import type { HistoryRow } from '@/lms/admin/task-history';
import RenewalNotice from './RenewalNotice';
import OriginFix from './OriginFix';
import EndReasonFix from './EndReasonFix';
import NoticeBox, { type NoticeApi } from './NoticeBox';
import { LessonRows } from './LessonRows';
import type { EndReason } from '@/lms/admin/import';
import { AdminHeader, BottomNav, Icon } from './ui';

/** 기존 수강생 입력 뒤 처리 (DB 함수, migration 1500) */
export type ImportActions = {
  markChecked: (enrollmentId: string) => Promise<void>;
  setOrigin: (itemId: string, date: string | null) => Promise<void>;
  setEndReason: (enrollmentId: string, reason: EndReason, note: string) => Promise<void>;
};

const WD = ['일', '월', '화', '수', '목', '금', '토'];
const box = 'min-w-0 rounded-[14px] border border-[#e6e3ef] bg-white px-4 py-3';
const chip = (on: boolean) => `inline-flex min-h-[36px] items-center gap-1.5 whitespace-nowrap rounded-[10px] border px-3 text-[13px] font-semibold disabled:opacity-45 ${on ? 'border-[#1d1b2b] bg-[#1d1b2b] text-white' : 'border-[#e6e3ef] bg-white text-[#1d1b2b]'}`;
const btn = 'inline-flex min-h-[40px] items-center rounded-[10px] border px-3 text-[13.5px] font-semibold';
const PRI = `${btn} border-[#7d5ffb] bg-[#7d5ffb] text-white disabled:border-[#e6e3ef] disabled:bg-white disabled:text-[#b9b6c8]`;
const SEC = `${btn} border-[#e6e3ef] bg-white text-[#1d1b2b] disabled:text-[#b9b6c8]`;
const DONE = `${btn} border-[#c9c6d6] bg-[#d9d6e3] font-bold text-[#4a4760]`;
/** 실제 데이터에서 서버 저장이 있는 버튼 (나머지는 그 업무 화면으로 이동) */
const LIVE_KEYS = new Set(['import_checked', 'notify_tutor', 'no_extension']);

export default function AdminDashboard({
  nowIso, today, preview, tasks: liveTasks, stats, onLogout, planActions, importActions, renewalSent, renewalNotify, enrollmentClose, onReload,
  history, notices, noExtension,
}: {
  nowIso: string;
  today: LessonItem[];
  preview: boolean;
  /** 실제 데이터 (없으면 가상 데이터 미리보기) */
  tasks?: TaskSource[];
  stats?: DashboardStats | null;
  onLogout?: () => void;
  planActions?: PlanActions;
  importActions?: ImportActions;
  /** 재등록 안내 [보냄] 기록 (migration 1900) — 보내면 할 일에서 빠지고 '종료 예정' 명단에 '안내 보냄' */
  renewalSent?: (enrollmentId: string) => Promise<void>;
  /** 재등록 [강사에게 통보] → 통보 기록 + 업무 완료 (20261109070000) */
  renewalNotify?: (taskId: string) => Promise<void>;
  /** 재등록 안 함 · 수강 종료 (3800) */
  enrollmentClose?: (enrollmentId: string) => Promise<void>;
  onReload?: () => Promise<void>;
  /** 처리 내역 보기·다시 열기 (3900) */
  history?: { load: () => Promise<HistoryRow[]>; reopen: (r: HistoryRow) => Promise<void> };
  notices?: NoticeApi;
  /** 예외 연장 검토 [검토 종료] 결정 기록 */
  noExtension?: (task: TaskSource) => Promise<void>;
}) {
  const now = useMemo(() => new Date(nowIso), [nowIso]);
  const todayKst = instantToKstDate(now);
  const [tasks, setTasks] = useState<TaskSource[]>(() => liveTasks ?? fakeTasks(now));
  useEffect(() => {
    if (liveTasks) setTasks(liveTasks);
  }, [liveTasks]);
  const [err, setErr] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [historyOpen, setHistoryOpen] = useState(false);
  const [roster, setRoster] = useState<'reg' | 'end' | null>(null);
  const [open, setOpen] = useState<string | null>(null);
  const items = useMemo(() => buildBoard(tasks, now), [tasks, now]);
  const [filter, setFilter] = useState<BoardFilter>('all');
  const byCat = categoryCounts(items);
  const [query, setQuery] = useState('');
  // 긴급 먼저 (buildBoard 가 이미 급한 순서)
  const shown = searchBoard(filterBoard(items, filter), query);
  const dateLabel = `${Number(todayKst.slice(5, 7))}월 ${Number(todayKst.slice(8, 10))}일 (${WD[new Date(`${todayKst}T00:00:00Z`).getUTCDay()]})`;
  const q = (href: string) => (preview ? `${href}${href.includes('?') ? '&' : '?'}demo=1` : href);

  useEffect(() => {
    if (!err) return;
    const id = setTimeout(() => setErr(null), 6000);
    return () => clearTimeout(id);
  }, [err]);

  // 저장 → 다시 읽기. 끝난 업무는 다시 읽은 목록에 없어 저절로 빠짐. 실패만 짧게
  async function run(f: () => Promise<unknown>) {
    if (busy) return;
    setBusy(true);
    setErr(null);
    try {
      await f();
      await onReload?.();
    } catch (e) {
      setErr(e instanceof Error ? e.message : '저장하지 못했어요.');
    } finally {
      setBusy(false);
    }
  }
  const drop = (item: BoardItem) => setTasks((prev) => prev.filter((t) => !(t.id === item.id && t.kind === item.kind)));

  function planHandlers(item: BoardItem, p: PlanView): PlanHandlers {
    if (!preview && planActions)
      return {
        confirm: () => run(() => planActions.confirm(p.planId)),
        decline: () => run(() => planActions.decline(p.planId)),
        proposalSent: () => run(() => planActions.proposalSent(p.planId)),
        noticeSent: (who) => {
          const n = who === 'tutor' ? p.tutorNotice : p.studentNotice;
          return n ? run(() => planActions.noticeSent(n.id)) : Promise.resolve();
        },
      };
    const patch = (f: (x: PlanView) => PlanView | null) =>
      setTasks((prev) => prev.flatMap((t) => {
        if (t.id !== item.id || t.kind !== 'new_student_matching' || !t.plan) return [t];
        const next = f(t.plan);
        return next ? [{ ...t, plan: next }] : [];
      }));
    const at = () => new Date();
    return {
      confirm: async () => patch((x) => ({ ...x, state: 'confirmed', confirmedAt: at(), tutorNotice: { id: 'pv-t', status: 'pending', sentAt: null }, studentNotice: { id: 'pv-s', status: 'pending', sentAt: null } })),
      decline: async () => patch(() => null),
      proposalSent: async () => patch((x) => ({ ...x, proposalSentAt: x.proposalSentAt ?? at() })),
      noticeSent: async (who) => patch((x) => {
        const sent = (n: PlanView['tutorNotice']) => (n && n.status !== 'sent' ? { ...n, status: 'sent' as const, sentAt: at() } : n);
        const next = who === 'tutor' ? { ...x, tutorNotice: sent(x.tutorNotice) } : { ...x, studentNotice: sent(x.studentNotice) };
        return next.tutorNotice?.status === 'sent' && next.studentNotice?.status === 'sent' ? null : next;
      }),
    };
  }

  function act(item: BoardItem, key: string) {
    const task = tasks.find((t) => t.id === item.id && t.kind === item.kind);
    if (preview) {
      if (key !== 'assign_tutor') drop(item);
      return;
    }
    if (key === 'import_checked' && importActions) return run(() => importActions.markChecked(item.id));
    if (key === 'notify_tutor' && item.kind === 'renewal_tutor_notice' && renewalNotify) return run(() => renewalNotify(item.id));
    if (key === 'no_extension' && task && noExtension) return run(() => noExtension(task));
  }

  async function markRenewalSent(item: BoardItem) {
    if (preview || !renewalSent) return drop(item);
    await renewalSent(item.id);
    await onReload?.();
  }

  function closeEnrollmentItem(item: BoardItem) {
    if (!window.confirm(`${item.title.split(' · ')[0]} 님 수강을 종료할까요?`)) return;
    if (preview || !enrollmentClose) return drop(item);
    void run(() => enrollmentClose(item.id));
  }

  async function fixOrigin(item: BoardItem, itemId: string, date: string | null) {
    if (preview || !importActions) {
      setTasks((prev) => prev.flatMap((t) => {
        if (t.id !== item.id || t.kind !== 'import_check') return [t];
        const next = { ...t, unknownOrigins: t.unknownOrigins.filter((o) => o.id !== itemId) };
        return next.counts || next.unknownOrigins.length > 0 || next.endReason ? [next] : [];
      }));
      return;
    }
    await importActions.setOrigin(itemId, date);
    await onReload?.();
  }

  async function fixEndReason(item: BoardItem, reason: EndReason, note: string) {
    if (preview || !importActions) {
      setTasks((prev) => prev.flatMap((t) => (t.id !== item.id || t.kind !== 'import_check' ? [t] : t.counts || t.unknownOrigins.length ? [{ ...t, endReason: null }] : [])));
      return;
    }
    await importActions.setEndReason(item.id, reason, note);
    await onReload?.();
  }

  const reg = stats?.registrations ?? [];
  const ends = stats?.endings ?? [];
  const needNotice = ends.filter((e) => e.state === 'need').length;
  const studentHref = (code: string) => q(`/lms/admin/students/${encodeURIComponent(code)}`);

  const tile = 'grid min-w-0 gap-px rounded-[14px] border border-[#e6e3ef] bg-white px-3.5 py-2.5 text-left';
  const tiles = (
    <section aria-label="운영 현황" className="grid grid-cols-2 gap-2 lg:grid-cols-4 lg:gap-2.5">
      <div className={tile}>
        <span className="text-[12.5px] text-[#6b6880]">수강 중 학생</span>
        <b className="text-[19px] tabular-nums text-[#1d1b2b] lg:text-[21px]">{stats ? `${stats.activeStudents}명` : '—'}</b>
      </div>
      <button type="button" aria-expanded={roster === 'reg'} onClick={() => setRoster(roster === 'reg' ? null : 'reg')} className={`${tile} hover:bg-[#f4f2fa]`}>
        <span className="flex justify-between text-[12.5px] text-[#6b6880]">이번 달 등록 <span aria-hidden className="font-bold">{roster === 'reg' ? '⌃' : '›'}</span></span>
        <b className="text-[19px] tabular-nums text-[#1d1b2b] lg:text-[21px]">{stats ? `${reg.length}건` : '—'}</b>
        <small className="text-[11.5px] text-[#6b6880]">신규 {reg.filter((r) => r.fresh).length} · 재등록 {reg.filter((r) => !r.fresh).length}</small>
      </button>
      <button type="button" aria-expanded={roster === 'end'} onClick={() => setRoster(roster === 'end' ? null : 'end')} className={`${tile} hover:bg-[#f4f2fa]`}>
        <span className="flex justify-between text-[12.5px] text-[#6b6880]">이번 달 종료 예정 <span aria-hidden className="font-bold">{roster === 'end' ? '⌃' : '›'}</span></span>
        <b className="text-[19px] tabular-nums text-[#1d1b2b] lg:text-[21px]">{stats ? `${ends.length}명` : '—'}</b>
        <small className="text-[11.5px] text-[#6b6880]">재등록 안내 필요 {needNotice}</small>
      </button>
      <div className={tile}>
        <span className="text-[12.5px] text-[#6b6880]">미결제</span>
        <b className="text-[19px] tabular-nums text-[#1d1b2b] lg:text-[21px]">{stats ? `${stats.unpaid}건` : '—'}</b>
      </div>
    </section>
  );

  const rosterBox = roster && (
    <section aria-label={roster === 'reg' ? '이번 달 등록' : '이번 달 종료 예정'} className={box}>
      <div className="mb-1 flex items-center gap-2">
        <h2 className="text-[15px] font-bold text-[#1d1b2b]">{Number(todayKst.slice(5, 7))}월 {roster === 'reg' ? '등록' : '수강 종료 예정'}</h2>
        <span className="text-[13px] font-semibold text-[#6b6880]">{roster === 'reg' ? '결제 확인일 기준' : `${ends.length}명`}</span>
        <button type="button" onClick={() => setRoster(null)} className={`${SEC} ml-auto min-h-[32px] px-2.5 text-[12.5px]`}>접기</button>
      </div>
      {(roster === 'reg' ? reg.length : ends.length) === 0 && <p className="py-4 text-center text-[13px] text-[#6b6880]">없어요.</p>}
      <ul className="lg:columns-2 lg:gap-8">
        {roster === 'reg'
          ? reg.map((r) => (
              <li key={r.enrollmentId} className="break-inside-avoid border-b border-[#e6e3ef] last:border-0">
                <Link href={studentHref(r.studentCode)} className="grid grid-cols-[minmax(0,1fr)_auto] items-center gap-x-2.5 py-2 hover:bg-[#f4f2fa]">
                  <span className="font-semibold text-[#1d1b2b]">{r.studentName}<span className="ml-1 text-[12px] font-normal text-[#6b6880]">{r.studentCode}</span></span>
                  <span className="row-span-2 text-[12.5px] text-[#6b6880]">{r.fresh ? '신규' : '재등록'} ›</span>
                  <span className="text-[12.5px] tabular-nums text-[#6b6880]">{r.plan}{r.paidOn ? ` · 결제 ${mdw(r.paidOn)}` : ''} · 결제 확인 {mdw(r.confirmedOn)}</span>
                </Link>
              </li>
            ))
          : ends.map((e) => (
              <li key={e.enrollmentId} className="break-inside-avoid border-b border-[#e6e3ef] last:border-0">
                <Link href={studentHref(e.studentCode)} className="grid grid-cols-[minmax(0,1fr)_auto] items-center gap-x-2.5 py-2 hover:bg-[#f4f2fa]">
                  <span className="font-semibold text-[#1d1b2b]">{e.studentName}<span className="ml-1 text-[12px] font-normal text-[#6b6880]">{e.studentCode}</span></span>
                  <span className={`row-span-2 text-right text-[12.5px] font-semibold ${e.state === 'need' ? 'text-[#c62b2b]' : e.state === 'renewed' ? 'text-[#13804b]' : 'font-normal text-[#6b6880]'}`}>{ENDING_STATE_TEXT(e)} ›</span>
                  <span className="text-[12.5px] tabular-nums text-[#6b6880]">
                    수강 종료 {mdw(e.endDate)} · 남은 {e.lessonsLeft}회{e.undated ? ` (날짜 미정 보강 ${e.undated} 포함)` : ''}
                    <br />
                    {e.renewedStart ? `새 수강권 ${mdw(e.renewedStart)} 시작` : `결제 마감 ${mdw(e.endDate)} 오후 11:59 한국 시간`}
                  </span>
                </Link>
              </li>
            ))}
      </ul>
    </section>
  );

  function detail(item: BoardItem) {
    const task = tasks.find((t) => t.id === item.id && t.kind === item.kind);
    const actions = item.actions.filter((a) => preview || a.href || a.done || a.disabled || LIVE_KEYS.has(a.key));
    // 서버 저장이 없는 버튼(장기 연기·노쇼·자동 처리 오류)은 실제 데이터에서 그 업무 화면으로
    const fallback = !preview && item.actions.some((a) => !a.href && !a.done && !a.disabled && !LIVE_KEYS.has(a.key));
    return (
      <div className="grid gap-2 px-0.5 pb-3">
        {item.detail && <p className="text-[12.5px] text-[#6b6880]">{item.detail}</p>}
        {item.due && <p className={`text-[13px] ${item.severity === 'open' ? 'text-[#6b6880]' : 'font-bold text-[#c62b2b]'}`}>{item.due}</p>}
        {item.steps.length > 0 && (
          <ul className="flex flex-wrap gap-x-3 gap-y-1">
            {item.steps.map((s) => (
              <li key={s.key} className={`text-[13px] ${s.done ? 'text-[#13804b]' : 'text-[#6b6880]'}`}>
                <span aria-hidden className={s.done ? 'text-[#13804b]' : 'text-[#b9b6c8]'}>{s.done ? '✓' : '○'}</span> {s.label}
                <span className="sr-only">{s.done ? ' (완료)' : ' (남음)'}</span>
              </li>
            ))}
          </ul>
        )}
        {item.plan && <PlanCard view={item.plan} handlers={planHandlers(item, item.plan)} />}
        {item.unknownOrigins && item.unknownOrigins.length > 0 && <OriginFix items={item.unknownOrigins} onSave={(id, date) => fixOrigin(item, id, date)} />}
        {item.renewal && <RenewalNotice text={item.renewal.text} sentAt={item.renewal.sentAt} onSent={() => markRenewalSent(item)} />}
        {item.endReason && <EndReasonFix weeks={item.endReason.weeks} onSave={(r, n) => fixEndReason(item, r, n)} />}
        <div className="flex flex-wrap gap-1.5">
          {actions.map((a) =>
            a.done ? (
              <button key={a.key} type="button" disabled className={DONE}>{a.label} ✓</button>
            ) : a.href && !a.disabled ? (
              <Link key={a.key} href={q(a.href)} className={a.primary ? PRI : SEC}>{a.label}</Link>
            ) : (
              <button key={a.key} type="button" disabled={a.disabled || busy} onClick={() => act(item, a.key)} className={a.danger ? `${btn} border-[#c62b2b] bg-[#c62b2b] text-white` : a.primary ? PRI : SEC}>
                {a.label}
              </button>
            ),
          )}
          {item.kind === 'extension_review' && (
            <button type="button" disabled={busy} onClick={() => act(item, 'no_extension')} className={SEC}>검토 종료</button>
          )}
          {fallback && <Link href={item.studentCode ? studentHref(item.studentCode) : '/lms/admin/change'} className={PRI}>열기</Link>}
          {/* 재등록 넣기 → 학생 상세 재등록 창이 바로 열림 (시안 5차 승인 11/9) */}
          {item.kind === 'ending_soon' && item.studentCode && <Link href={q(`/lms/admin/students/${encodeURIComponent(item.studentCode)}?renew=1`)} className={PRI}>재등록 넣기</Link>}
          {item.kind === 'ending_soon' && item.studentCode && <Link href={studentHref(item.studentCode)} className={SEC}>학생 상세</Link>}
          {/* 수강기간이 끝난 뒤에만: 재등록 안 하는 수강생 정리 */}
          {item.kind === 'ending_soon' && item.severity === 'overdue' && (
            <button type="button" disabled={busy} onClick={() => closeEnrollmentItem(item)} className={SEC}>수강 종료</button>
          )}
          {task?.kind === 'lesson_change' && item.studentCode && !item.actions.some((a) => a.href?.includes(item.studentCode!)) && (
            <Link href={studentHref(item.studentCode)} className={SEC}>학생 상세</Link>
          )}
        </div>
      </div>
    );
  }

  const tasksBox = (
    <section aria-label="운영진 할 일" className={box}>
      <div className="mb-2 flex items-center gap-2">
        <h2 className="text-[15px] font-bold text-[#1d1b2b]">운영진 할 일</h2>
        <span className="text-[13px] font-semibold text-[#6b6880]">{items.length}건</span>
      </div>
      <div role="group" aria-label="칸" className="flex flex-wrap gap-1.5">
        <button type="button" aria-pressed={filter === 'all'} onClick={() => { setFilter('all'); setOpen(null); }} className={chip(filter === 'all')}>
          전체 <em className={`not-italic tabular-nums ${filter === 'all' ? 'text-[#c9c6d6]' : 'text-[#6b6880]'}`}>{items.length}</em>
        </button>
        {(Object.keys(CATEGORY_LABEL) as Category[]).map((c) => (
          <button key={c} type="button" aria-pressed={filter === c} disabled={byCat[c].n === 0} onClick={() => { setFilter(c); setOpen(null); }} className={chip(filter === c)}>
            {CATEGORY_LABEL[c]} <em className={`not-italic tabular-nums ${filter === c ? 'text-[#c9c6d6]' : 'text-[#6b6880]'}`}>{byCat[c].n}</em>
          </button>
        ))}
      </div>
      <div className="mt-2 flex flex-wrap items-center gap-1.5">
        <label className="flex min-h-[38px] min-w-[180px] flex-1 items-center gap-2 rounded-[10px] border border-[#e6e3ef] bg-white px-2.5">
          <Icon name="search" className="h-4 w-4 text-[#6b6880]" />
          <span className="sr-only">할 일 찾기</span>
          <input type="search" value={query} onChange={(e) => setQuery(e.target.value)} placeholder="학생·강사 이름, 학생 번호" className="min-w-0 flex-1 bg-transparent text-[14px] text-[#1d1b2b] outline-none" />
        </label>
        {history && (
          <button type="button" aria-pressed={historyOpen} onClick={() => setHistoryOpen(!historyOpen)} className={`min-h-[34px] rounded-full border px-3 text-[12.5px] font-semibold ${historyOpen ? 'border-[#1d1b2b] bg-[#1d1b2b] text-white' : 'border-[#e6e3ef] bg-white text-[#1d1b2b]'}`}>
            처리 내역
          </button>
        )}
      </div>
      {historyOpen && history && (
        <div className="mt-2">
          <HistoryPanel load={history.load} reopen={history.reopen} onClose={() => setHistoryOpen(false)} onReopened={async () => { await onReload?.(); }} />
        </div>
      )}
      <ul className="mt-2">
        {shown.length === 0 && <li className="py-5 text-center text-[13px] text-[#6b6880]">{items.length ? '찾는 일이 없어요.' : '처리할 일이 없어요.'}</li>}
        {shown.map((item) => {
          const key = `${item.kind}:${item.id}`;
          const on = open === key;
          return (
            <li key={key} className="border-t border-[#e6e3ef]">
              <button type="button" aria-expanded={on} onClick={() => setOpen(on ? null : key)} className="grid w-full grid-cols-[minmax(0,1fr)_auto] items-center gap-x-2.5 gap-y-0.5 px-0.5 py-2.5 text-left hover:bg-[#f4f2fa]">
                <span className="text-[12px] text-[#6b6880]">
                  {item.tag}
                  {isUrgent(item) && <span className="ml-1.5 rounded-[6px] border border-[#c62b2b] px-1.5 text-[11px] font-bold text-[#c62b2b]">긴급</span>}
                </span>
                <span aria-hidden className="row-span-3 font-bold text-[#6b6880]">{on ? '⌃' : '›'}</span>
                <span className="text-[14.5px] font-bold text-[#1d1b2b]">{item.title}</span>
                <span className="truncate text-[12.5px] text-[#6b6880]">{item.brief}</span>
              </button>
              {on && detail(item)}
            </li>
          );
        })}
      </ul>
    </section>
  );

  const todayBox = (
    <section aria-label="오늘 수업" className={box}>
      <div className="mb-1 flex items-center gap-2">
        <Link href={q('/lms/admin/lessons')} className="inline-flex min-h-[32px] items-center gap-1 text-[15px] font-extrabold text-[#1d1b2b]">
          오늘 수업 <span aria-hidden className="text-[#6b6880]">›</span>
        </Link>
        <span className="text-[12px] text-[#6b6880]">한국 시간</span>
      </div>
      {today.length === 0 ? <p className="py-3 text-[13px] text-[#6b6880]">오늘 수업이 없어요.</p> : <LessonRows rows={today} studentHref={studentHref} />}
    </section>
  );

  const QUICK: [string, string][] = [
    ['수강생 관리', '/lms/admin/students'], ['강사 관리', '/lms/admin/tutors'], ['신규 수강생 등록', '/lms/admin/students/new'],
    ['수업 변경·취소', '/lms/admin/change'], ['강사 휴무', '/lms/admin/leave'],
  ];
  const quick = (
    <section aria-label="빠른 메뉴" className={box}>
      <h2 className="mb-2 text-[15px] font-bold text-[#1d1b2b]">빠른 메뉴</h2>
      <div className="grid grid-cols-2 gap-2">
        {QUICK.map(([label, href]) => (
          <Link key={href} href={q(href)} className="flex min-h-[44px] items-center rounded-[10px] border border-[#7d5ffb] px-3 text-[13.5px] font-semibold text-[#5b3fe0] last:odd:col-span-2">
            {label}
          </Link>
        ))}
      </div>
    </section>
  );

  return (
    <div className="mx-auto min-h-dvh max-w-[1280px] pb-24 lg:pb-8">
      <AdminHeader
        active="home"
        demo={preview}
        rightInline
        right={
          <>
            <span className="hidden text-[13px] text-[#6b6880] lg:inline">{dateLabel}</span>
            {onLogout && (
              <button type="button" onClick={onLogout} className="min-h-[36px] px-1 text-[12.5px] font-semibold text-[#1d1b2b] lg:px-2 lg:text-[13px]">로그아웃</button>
            )}
            {/* PC 최상단 오른쪽 버튼은 이것 하나 (대표 11/9). 휴대폰은 빠른 메뉴에 */}
            <Link href={q('/lms/admin/students/new')} className="hidden min-h-[40px] items-center rounded-[10px] bg-[#7d5ffb] px-3 text-[13px] font-semibold text-white lg:flex">
              + 신규 수강생 등록
            </Link>
          </>
        }
      />

      {preview && (
        <p className="mx-4 mt-3 rounded-[10px] bg-[#fff8d6] px-3 py-2 text-[13px] text-[#5c4a00] lg:mx-7">가상 데이터 미리보기예요. 눌러도 저장·발송되지 않아요.</p>
      )}

      <div className="grid gap-3 px-4 pt-3 lg:gap-4 lg:px-7 lg:pt-5">
        {tiles}
        {rosterBox}
        <div className="grid gap-3 lg:grid-cols-[minmax(0,1fr)_370px] lg:items-start lg:gap-4">
          <div className="grid min-w-0 gap-3">{tasksBox}</div>
          <div className="grid min-w-0 gap-3">
            {todayBox}
            {quick}
            <NoticeBox api={notices} today={todayKst} />
          </div>
        </div>
      </div>

      {err && (
        <div role="alert" className="fixed inset-x-4 bottom-20 z-20 mx-auto flex max-w-md items-center gap-3 rounded-[12px] bg-[#1d1b2b] px-4 py-2.5 shadow-lg lg:bottom-6">
          <p className="flex-1 text-[13.5px] text-white">{err}</p>
          <button type="button" aria-label="닫기" onClick={() => setErr(null)} className="text-[15px] text-[#c9bcff]">✕</button>
        </div>
      )}

      <BottomNav active="home" demo={preview} />
    </div>
  );
}
