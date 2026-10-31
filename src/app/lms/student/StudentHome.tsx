'use client';

// 학생 마이페이지 A-1 (카드 쌓기형) — 휴대폰: 카드 순서대로 + 아래 탭 / PC: 왼쪽 메뉴 + 가운데 카드 + 오른쪽 현황·결제
// 판정은 src/lms/student/home.ts (6시간 규칙은 rules/change.ts), 저장은 DB 함수(migration 2800, StudentActions).
// ③ 학생 LMS (2026-10-28 대표): 휴무 안내에 한 번에 답(A안) · 보강 날짜는 달력에서 고르기 · 직접 취소
// 미리보기(?demo=1)는 같은 화면에 브라우저 안에서만 흉내 내는 동작(fakeStore)을 넣음 — 저장·발송 없음

import { googleCalendarUrl, icsUrl, type CalendarEvent } from '@/lms/calendar/add';
import { useEffect, useMemo, useState } from 'react';
import books from '@/data/books.json';
import { homepageProfile } from '@/lms/admin/homepage-tutor';
import { MAKEUP_SLOTS_MAX } from '@/lms/admin/lesson-change';
import { diffDays, formatInZone, hoursBetween, type KstDate } from '@/lms/rules/dates';
import type { PreviewExtras } from '@/lms/student/fake-data';
import type { LeaveRow, MakeupOption, MakeupRight, Reminders, StudentActions, StudentView } from '@/lms/student/live';
import {
  cancelPreview,
  lessonsLeft,
  nextLesson,
  PAYMENT_METHOD_LABEL,
  pointsHistory,
  regularLessonsLeft,
  renewalPrompt,
  REQUEST_STATUS_LABEL,
  studentTodos,
  type PaymentSummary,
  type RenewalState,
  type RequestStatus,
  type StudentLesson,
  type StudentRequest,
} from '@/lms/student/home';

type Tab = 'home' | 'schedule' | 'requests' | 'materials' | 'me';
type Right = Pick<MakeupRight, 'lessonId' | 'itemId'>;
type Overlay =
  | null
  | { kind: 'request'; id: string }
  | { kind: 'payments' }
  | { kind: 'points' }
  | { kind: 'consent' }
  | { kind: 'cancel'; lessonId: string | null }
  | { kind: 'leave' }
  | { kind: 'profile'; name: string }
  | { kind: 'makeup'; right: Right | null; canceled?: boolean }
  | { kind: 'credits' };

const TABS: { key: Tab; label: string; icon: string }[] = [
  { key: 'home', label: '홈', icon: 'M3 11l9-7 9 7v9a1 1 0 0 1-1 1h-5v-6H9v6H4a1 1 0 0 1-1-1z' },
  { key: 'schedule', label: '일정', icon: 'M5 4h14a2 2 0 0 1 2 2v13a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V6a2 2 0 0 1 2-2zM8 2v4M16 2v4M3 10h18' },
  { key: 'requests', label: '신청 내역', icon: 'M8 6h13M8 12h13M8 18h13M3 6h.01M3 12h.01M3 18h.01' },
  { key: 'materials', label: '학습자료', icon: 'M4 19V5a2 2 0 0 1 2-2h13v16H6a2 2 0 0 0-2 2z' },
  { key: 'me', label: '내 정보', icon: 'M12 12a4 4 0 1 0 0-8 4 4 0 0 0 0 8zM4 21c1.5-4 4.5-6 8-6s6.5 2 8 6' },
];

const STATUS_STYLE: Record<RequestStatus, string> = {
  tutor_reviewing: 'bg-[#fff1d6] text-[#8a5300]',
  admin_reviewing: 'bg-[#fff1d6] text-[#8a5300]',
  confirmed: 'bg-[#e3f5ea] text-[#13623a]',
  completed: 'bg-[#e3f5ea] text-[#13623a]',
};

const card = 'rounded-[16px] border border-[#e6e3ef] bg-white';

function kst(d: Date) {
  const f = formatInZone(d, 'Asia/Seoul');
  return { md: `${Number(f.date.slice(5, 7))}/${Number(f.date.slice(8, 10))}`, wd: '일월화수목금토'[new Date(`${f.date}T00:00:00Z`).getUTCDay()], time: f.time, date: f.date };
}
const fmtDate = (d: KstDate) => `${Number(d.slice(5, 7))}/${Number(d.slice(8, 10))}`;
const won = (n: number) => `${n.toLocaleString('ko-KR')}원`;

function Icon({ d, className = 'h-5 w-5' }: { d: string; className?: string }) {
  return (
    <svg aria-hidden viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth={2} strokeLinecap="round" strokeLinejoin="round" className={className}>
      {/* globals.css 의 '* { color }' 때문에 path 가 부모 색을 잃지 않도록 */}
      <path d={d} style={{ color: 'inherit' }} />
    </svg>
  );
}


const sameRight = (a: Right, b: Right) => (a.lessonId !== null && a.lessonId === b.lessonId) || (a.itemId !== null && a.itemId === b.itemId);
const whenText = (d: Date) => {
  const k = kst(d);
  return `${k.md} (${k.wd}) ${k.time}`;
};

export default function StudentHome(props: {
  nowIso: string;
  initial: StudentView;
  actions: StudentActions;
  /** 미리보기에만: 교재·결제 내역·동의 할 일 (실제 데이터 연결 전 항목) */
  extras?: PreviewExtras;
  preview: boolean;
  adminBar?: React.ReactNode;
  onLogout?: () => void;
}) {
  const { actions, extras, preview } = props;
  const now = useMemo(() => new Date(props.nowIso), [props.nowIso]);
  const [s, setView] = useState<StudentView>(props.initial);
  const [renewal, setRenewal] = useState<RenewalState>(props.initial.renewalPaid ? 'payment_confirmed' : 'not_requested');
  const [consents, setConsents] = useState(extras?.pendingConsents ?? []);
  const [tab, setTab] = useState<Tab>('home');
  const [overlay, setOverlay] = useState<Overlay>(null);
  const [toast, setToast] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [reminders, setReminders] = useState<Reminders | null>(null);

  const lessons = s.lessons;
  // 강사 휴무로 못 들은 수업도 학생 화면에서는 '보강' (2026-10-28 대표). DB 구분(lms_is_leave_postponed)은 그대로
  const openRights = s.makeupRights.filter((m) => !m.requested);
  const makeupsOwed = s.makeupRights.length;
  const leaveAsk = s.leave.filter((x) => x.choice === 'substitute' && x.stage === 'tutor_ok');
  const todos = studentTodos({ pendingConsents: consents });
  const next = nextLesson(lessons, now);
  const left = lessonsLeft(lessons, now, makeupsOwed);
  const prompt = renewalPrompt(lessons, renewal, now, makeupsOwed);
  const endDate = s.finalEndDate;
  const dLeft = endDate ? diffDays(formatInZone(now, 'Asia/Seoul').date, endDate) : 0;
  const points = pointsHistory(s.points);
  const textbook = extras?.textbook ?? null;
  const book = textbook && books.find((b) => b.title.replace(/\s/g, '') === textbook.title.replace(/\s/g, ''));
  const holidays = useMemo(() => new Set(s.holidays), [s.holidays]);

  useEffect(() => {
    if (!toast) return;
    const t = setTimeout(() => setToast(null), 4000);
    return () => clearTimeout(t);
  }, [toast]);

  useEffect(() => {
    actions.reminders().then(setReminders, () => setReminders(null));
  }, [actions]);

  async function saveReminder(change: { regular?: boolean; makeup?: boolean }) {
    setBusy(true);
    try {
      setReminders(await actions.reminders(change));
      say('저장했어요.');
    } catch (e) {
      setToast(e instanceof Error ? e.message : '저장하지 못했어요.');
    } finally {
      setBusy(false);
    }
  }

  function say(msg: string) {
    setToast(`${msg}${preview ? ' (미리보기: 실제로 저장되지 않아요)' : ''}`);
  }

  /** 저장 → 화면 다시 읽기. 실패하면 DB 오류 문구 그대로 */
  async function run(work: () => Promise<unknown>, done: string): Promise<StudentView | null> {
    setBusy(true);
    try {
      await work();
      const v = await actions.reload();
      setView(v);
      say(done);
      return v;
    } catch (e) {
      setToast(e instanceof Error ? e.message : '저장하지 못했어요.');
      return null;
    } finally {
      setBusy(false);
    }
  }

  async function confirmCancel(lesson: StudentLesson) {
    let allowed = false;
    const v = await run(async () => {
      allowed = (await actions.cancel(lesson.id)).makeup_allowed;
    }, '수업을 취소했어요.');
    if (!v) return;
    const right = v.makeupRights.find((m) => m.lessonId === lesson.id && !m.requested);
    setOverlay(allowed && right ? { kind: 'makeup', right, canceled: true } : null);
  }

  async function answerLeave(answer: 'ok' | 'makeup') {
    const ids = leaveAsk.map((x) => x.id);
    const v = await run(() => actions.answerLeave(ids, answer), answer === 'ok' ? '확정했어요.' : '기존 강사님과 수업하기로 정했어요.');
    if (!v || answer === 'ok') return;
    const right = v.makeupRights.find((m) => !m.requested && leaveAsk.some((x) => (x.lessonId && x.lessonId === m.lessonId) || (x.itemId && x.itemId === m.itemId)));
    if (right) setOverlay({ kind: 'makeup', right });
  }

  const nextFull = next && s.lessons.find((l) => l.id === next.id);
  const nextCard = next && <NextLesson lesson={next} now={now} textbook={textbook} meetUrl={nextFull?.leaveOpen ? null : nextFull?.meetUrl ?? null} substitute={nextFull?.substitute ?? false} leaveOpen={!!nextFull?.leaveOpen} />;

  const renewalCard = prompt && (
    <section aria-label="재등록 안내" className="grid gap-2.5 rounded-[18px] border border-[#f0d27a] bg-[#fff4d6] p-4 lg:flex lg:items-center lg:gap-4">
      <div className="lg:flex-1">
        <h2 className="text-[15px] font-bold text-[#5c3b00]">수업이 {prompt.left}회 남았어요</h2>
        {prompt.mode === 'request' ? (
          <p className="mt-1 text-[13px] leading-relaxed text-[#5c3b00]">
            종료일 {fmtDate(endDate)} 23:59까지 재등록 결제하면 남은 수업을 다음 등록으로 옮길 수 있고, 지금 고정 시간도 유지돼요.
          </p>
        ) : (
          <p className="mt-1 text-[13px] leading-relaxed text-[#5c3b00]">
            <b>재등록 신청 완료 · 결제 확인 중</b>이에요. 결제는 운영자가 직접 확인하고, 확인되면 이 안내가 사라져요. 마감은 {fmtDate(endDate)} 23:59예요.
          </p>
        )}
      </div>
      {/* 재등록 신청 저장은 아직 DB에 없음 → 미리보기에서만 버튼 */}
      {preview && prompt.mode === 'request' && (
        <button
          type="button"
          onClick={() => {
            setRenewal('requested');
            say('재등록을 신청했어요.');
          }}
          className="min-h-[46px] rounded-[12px] bg-[#1b1442] px-5 text-[15px] font-bold text-white"
        >
          재등록 신청
        </button>
      )}
      {prompt.mode === 'awaiting_payment' && <span className="justify-self-start rounded-full bg-white px-3 py-1.5 text-[13px] font-semibold text-[#8a5300]">결제 확인 대기</span>}
    </section>
  );

  const statusTiles = (
    <section aria-label="수강 현황" className="grid grid-cols-3 gap-2">
      <Tile label="남은 수업" value={`${left.total}`} unit="회" sub={left.other ? `정규 ${left.regular} · 보강 ${left.other}` : `${s.totalLessons}회 중`} />
      <Tile label="변경권" value={`${s.creditsLeft}`} unit="개" sub={`이번 기간 ${s.creditsPerPeriod}개 중 ›`} onClick={() => setOverlay({ kind: 'credits' })} />
      <Tile
        label="수강 종료"
        value={!endDate ? '-' : dLeft > 0 ? `D-${dLeft}` : dLeft === 0 ? 'D-day' : '종료'}
        sub={endDate ? `${fmtDate(endDate)} (${kst(new Date(`${endDate}T12:00:00+09:00`)).wd})` : ''}
      />
    </section>
  );

  const quick = (
    <section aria-label="빠른 신청" className="grid grid-cols-2 gap-2">
      <button type="button" onClick={() => setOverlay({ kind: 'cancel', lessonId: null })} className={`${card} grid content-start gap-1.5 p-4 text-left`}>
        <Icon d={TABS[1].icon} className="h-[22px] w-[22px] text-[#5b3df0]" />
        <span className="text-[15px] font-bold">수업 변경·취소</span>
        <span className="text-[12px] leading-[1.55] text-[#55526a]">
          6시간 전: 변경권 1개 사용 · 보강 가능
          <br />
          6시간 이내: 수업 1회 차감 · 보강 불가 · 변경권 유지
        </span>
      </button>
      <button
        type="button"
        disabled={openRights.length === 0}
        onClick={() => setOverlay({ kind: 'makeup', right: openRights.length === 1 ? openRights[0] : null })}
        className={`${card} grid content-start gap-1.5 p-4 text-left disabled:opacity-50`}
      >
        <Icon d="M12 3a9 9 0 1 0 0 18 9 9 0 0 0 0-18zM12 7v5l3 2" className="h-[22px] w-[22px] text-[#5b3df0]" />
        <span className="text-[15px] font-bold">보강 신청</span>
        <span className="text-[12px] leading-[1.55] text-[#55526a]">보강할 수업 {openRights.length}회</span>
      </button>
    </section>
  );

  const requestList = s.requests.length > 0 && (
    <section aria-label="신청 진행 상태" className={`${card} grid gap-1 p-4`}>
      <div className="flex items-center justify-between">
        <h2 className="text-[15px] font-bold">신청 진행 상태</h2>
        <button type="button" onClick={() => setTab('requests')} className="min-h-[36px] text-[13px] text-[#4b2fd6] underline">
          전체 ›
        </button>
      </div>
      {s.requests.slice(0, 3).map((r) => (
        <RequestRow key={r.id} r={r} onOpen={() => setOverlay({ kind: 'request', id: r.id })} />
      ))}
    </section>
  );

  const payBox = (
    <section aria-label="수강과 결제" className={`${card} px-4 pb-1.5 pt-4`}>
      <h2 className="mb-2 text-[15px] font-bold">수강·결제·적립금</h2>
      <LinkRow label="수강권" value={s.product} onClick={extras && (() => setOverlay({ kind: 'payments' }))} />
      <LinkRow label="결제" value={s.confirmedOn ? `확인 완료 (${fmtDate(s.confirmedOn)})` : '확인 중'} valueClass="text-[#13623a]" onClick={extras && (() => setOverlay({ kind: 'payments' }))} />
      <LinkRow label="적립금 내역" value={won(points.balance)} valueClass="font-bold" onClick={() => setOverlay({ kind: 'points' })} />
    </section>
  );

  // 할 일: 학생이 직접 해야 하는 것만 (휴무 안내 답 · 날짜 안 잡은 보강 POL-OP-22 · 수업 안내 동의)
  const todoItems = (
    <>
      {leaveAsk.length > 0 && <TodoBar n={leaveAsk.length} text="담당 강사님 휴무 안내" onClick={() => setOverlay({ kind: 'leave' })} />}
      {openRights.length > 0 && <TodoBar n={openRights.length} text="보강 날짜 고르기" onClick={() => setOverlay({ kind: 'makeup', right: openRights.length === 1 ? openRights[0] : null })} />}
      {todos.length > 0 && <TodoBar n={todos.length} text={todos.length === 1 ? todos[0].label : `${todos.length}가지 확인이 필요해요`} onClick={() => setOverlay({ kind: 'consent' })} />}
    </>
  );
  const todoCount = (leaveAsk.length > 0 ? 1 : 0) + (openRights.length > 0 ? 1 : 0) + (todos.length > 0 ? 1 : 0);
  const todoBars = todoCount > 0 && (
    <section aria-label="할 일" className="overflow-hidden rounded-[18px] border-2 border-[#f0a33a] bg-white">
      <h2 className="flex items-center gap-2 bg-[#fff4d6] px-4 py-2.5 text-[16px] font-bold text-[#5c3b00]">
        할 일 <span className="rounded-full bg-[#f0a33a] px-2 py-0.5 text-[13px] text-white">{todoCount}</span>
      </h2>
      <div className="divide-y divide-[#f3e6c4]">{todoItems}</div>
    </section>
  );

  const upcoming = lessons.filter((l) => l.state === 'scheduled' && l.startsAt.getTime() > now.getTime()).sort((a, b) => a.startsAt.getTime() - b.startsAt.getTime());
  const canceledAhead = lessons.filter((l) => l.state === 'canceled' && l.startsAt.getTime() > now.getTime()).sort((a, b) => a.startsAt.getTime() - b.startsAt.getTime());
  const leaveVisible = s.leave.length > 0;
  // 휴무 처리 확정 전 수업(일정 조율 중)은 입장 링크 없음 — 휴무 강사 링크로 들어가지 않게
  const meetOf = (id: string) => { const x = s.lessons.find((l) => l.id === id); return x && !x.leaveOpen ? x.meetUrl : null; };
  // 강사마다 수업 링크가 다름 → 앞으로 수업하는 강사별로 (대체강사 포함)
  const meetLinks = [...new Map(upcoming.map((l) => [l.tutorName, meetOf(l.id)] as const).filter(([, u]) => u)).entries()];

  return (
    <div className="mx-auto min-h-dvh max-w-[1280px] font-sans text-[#1d1b2b] lg:flex lg:gap-6 lg:px-6 lg:py-6">
      <nav aria-label="메뉴" className="hidden w-[220px] shrink-0 flex-col gap-1 lg:flex">
        {props.adminBar ? (
          <a href="/lms/admin" className="px-3 pb-4 pt-1 text-[20px] font-bold text-[#09246b]">
            Edge<span className="text-[#5b3df0]">English</span>
          </a>
        ) : (
          <div className="px-3 pb-4 pt-1 text-[20px] font-bold text-[#09246b]">
            Edge<span className="text-[#5b3df0]">English</span>
          </div>
        )}
        {TABS.map((t) => (
          <button
            key={t.key}
            type="button"
            onClick={() => setTab(t.key)}
            aria-current={tab === t.key ? 'page' : undefined}
            className={`flex min-h-[46px] items-center gap-2.5 rounded-[12px] px-3 text-left text-[15px] ${tab === t.key ? 'bg-[#efeaff] font-bold text-[#3a22b0]' : ''}`}
          >
            <Icon d={t.icon} />
            {t.label}
          </button>
        ))}
        <span className="px-3 pt-5 text-[13px] text-[#55526a]">{s.name} 님</span>
        {props.onLogout && (
          <button type="button" onClick={props.onLogout} className="mx-3 mt-1 min-h-[36px] text-left text-[13px] text-[#55526a] underline">
            로그아웃
          </button>
        )}
      </nav>

      <div className="min-w-0 flex-1 pb-24 lg:pb-0">
        {props.adminBar && <div className="px-4 pt-3 lg:px-0 lg:pt-0">{props.adminBar}</div>}
        <header className="flex items-center justify-between px-5 pb-3 pt-[18px] lg:hidden">
          {props.adminBar ? (
            <a href="/lms/admin" className="text-[17px] font-bold text-[#09246b]">
              Edge<span className="text-[#5b3df0]">English</span>
            </a>
          ) : (
            <span className="text-[17px] font-bold text-[#09246b]">
              Edge<span className="text-[#5b3df0]">English</span>
            </span>
          )}
          <span className="text-[13px] text-[#55526a]">{s.name} 님</span>
        </header>

        {preview && (
          <div className="mx-4 mb-3 grid gap-2 rounded-[12px] bg-[#fff8d6] px-3 py-2.5 text-[12.5px] text-[#5c4a00] lg:mx-0">
            <p>가상 데이터 미리보기예요. 눌러도 실제로 저장·발송되지 않아요.</p>
            <div className="flex flex-wrap gap-1.5">
              <PreviewChip on={consents.length > 0} onClick={() => setConsents(consents.length ? [] : (extras?.pendingConsents ?? []))}>
                할 일 {consents.length ? '있음' : '없음'}
              </PreviewChip>
              {(['not_requested', 'requested', 'payment_confirmed'] as const).map((r) => (
                <PreviewChip key={r} on={renewal === r} onClick={() => setRenewal(r)}>
                  재등록 {r === 'not_requested' ? '미신청' : r === 'requested' ? '신청함' : '결제 확인'}
                </PreviewChip>
              ))}
            </div>
          </div>
        )}

        {tab === 'home' && (
          <div className="grid gap-3.5 px-4 lg:grid-cols-[minmax(0,1fr)_340px] lg:items-start lg:gap-5 lg:px-0">
            <div className="grid min-w-0 gap-3.5">
              {todoBars}
              {nextCard}
              {renewalCard}
              <div className="lg:hidden">{statusTiles}</div>
              {quick}
              {leaveVisible && leaveAsk.length === 0 && (
                <button type="button" onClick={() => setOverlay({ kind: 'leave' })} className={`${card} flex min-h-[52px] items-center justify-between px-4 text-left text-[14px]`}>
                  <span className="font-semibold">담당 강사님 휴무 안내</span>
                  <span className="text-[#8b88a0]">›</span>
                </button>
              )}
              {requestList}
              <div className="lg:hidden">{payBox}</div>
            </div>
            <aside className="hidden gap-4 lg:grid">
              {statusTiles}
              {payBox}
            </aside>
          </div>
        )}

        {tab === 'schedule' && (
          <TabPage title="일정">
            <p className="text-[13px] text-[#55526a]">한국 시간 기준이에요.</p>
            {upcoming.map((l) => (
              <div key={l.id} className={`${card} flex items-center justify-between gap-3 p-4`}>
                <div className="min-w-0">
                  <p className="text-[15px] font-semibold">{whenText(l.startsAt)}</p>
                  <p className="text-[12.5px] text-[#6b6880]">
                    {l.minutes}분{s.lessons.find((x) => x.id === l.id)?.leaveOpen ? '' : ` · ${l.tutorName}`} · {l.kind === 'regular' ? '정규' : l.kind === 'makeup' ? '보강' : '보상'}
                  </p>
                  {s.lessons.find((x) => x.id === l.id)?.substitute && (
                    <p className="mt-1 text-[13px] font-bold text-[#b3261e]">⚠️ 대체강사 수업</p>
                  )}
                  {s.lessons.find((x) => x.id === l.id)?.leaveOpen && (
                    <p className="mt-1 text-[13px] font-bold text-[#b3261e]">⚠️ 강사님 휴무로 일정 조율 중</p>
                  )}
                  {meetOf(l.id) && (
                    <a href={meetOf(l.id)!} target="_blank" rel="noreferrer" className="mt-1 inline-block text-[13px] font-semibold text-[#4b2fd6] underline">
                      수업 링크 (Google Meet)
                    </a>
                  )}
                  {l.kind === 'makeup' && <AddToCalendar ev={{ title: '엣지영어 보강 수업', start: l.startsAt, end: new Date(l.startsAt.getTime() + l.minutes * 60000), details: meetOf(l.id) }} google="구글 캘린더에 추가" file="애플·삼성 캘린더에 추가" />}
                </div>
                <button type="button" onClick={() => setOverlay({ kind: 'cancel', lessonId: l.id })} className="min-h-[44px] rounded-[12px] border border-[#d9d5e8] px-3 text-[14px] font-semibold">
                  변경·취소
                </button>
              </div>
            ))}
            {/* 앞으로의 취소 수업은 '지난 수업'과 따로 (대표 10/30) */}
            {canceledAhead.length > 0 && <h2 className="pt-2 text-[14px] font-bold text-[#55526a]">취소된 수업</h2>}
            {canceledAhead.map((l) => (
              <div key={l.id} className="flex justify-between border-b border-[#eeecf4] px-1 py-2.5 text-[14px]">
                <span>{whenText(l.startsAt)}</span>
                <span className="text-[#6b6880]">취소</span>
              </div>
            ))}
            <h2 className="pt-2 text-[14px] font-bold text-[#55526a]">지난 수업</h2>
            {lessons
              .filter((l) => l.startsAt.getTime() <= now.getTime())
              .sort((a, b) => b.startsAt.getTime() - a.startsAt.getTime())
              .map((l) => (
                <div key={l.id} className="flex justify-between border-b border-[#eeecf4] px-1 py-2.5 text-[14px]">
                  <span>{whenText(l.startsAt)}</span>
                  <span className="text-[#6b6880]">{l.state === 'done' ? '진행' : l.state === 'canceled' ? '취소' : l.startsAt.getTime() + l.minutes * 60_000 > now.getTime() ? '진행 중' : '기록 전'}</span>
                </div>
              ))}
          </TabPage>
        )}

        {tab === 'requests' && (
          <TabPage title="신청 내역">
            {s.requests.length > 0 && (
              <section className={`${card} grid gap-1 p-4`}>
                {s.requests.map((r) => (
                  <RequestRow key={r.id} r={r} onOpen={() => setOverlay({ kind: 'request', id: r.id })} />
                ))}
              </section>
            )}
            <section className={`${card} px-4`}>
              <button
                type="button"
                disabled={openRights.length === 0}
                onClick={() => setOverlay({ kind: 'makeup', right: openRights.length === 1 ? openRights[0] : null })}
                className="flex min-h-[52px] w-full items-center justify-between text-left text-[15px] disabled:opacity-50"
              >
                보강 신청 <span className="text-[#8b88a0]">›</span>
              </button>
            </section>
          </TabPage>
        )}

        {tab === 'materials' && (
          <TabPage title="학습자료">
            {textbook && (
              <section className={`${card} grid gap-3 p-4`}>
                <p className="text-[13px] font-bold text-[#5b3df0]">지금 수업 교재</p>
                <p className="text-[17px] font-bold">{textbook.title}</p>
                <p className="text-[13px] text-[#55526a]">
                  {book ? `${book.category} · ${book.level.join('·')}` : ''} · 지난 수업 Unit {textbook.lastUnit}
                </p>
                <div className="grid grid-cols-2 gap-2">
                  {book?.pdf && (
                    <a href={book.pdf} target="_blank" rel="noreferrer" className="flex min-h-[46px] items-center justify-center rounded-[12px] bg-[#5b3df0] text-[14px] font-bold text-white">
                      미리보기 열기
                    </a>
                  )}
                  {book?.buyLink && (
                    <a href={book.buyLink} target="_blank" rel="noreferrer" className="flex min-h-[46px] items-center justify-center rounded-[12px] border border-[#d9d5e8] text-[14px] font-semibold">
                      교재 구매
                    </a>
                  )}
                </div>
              </section>
            )}
            <a href="/books" className={`${card} flex min-h-[52px] items-center justify-between px-4 text-[15px] font-semibold`}>
              전체 교재 둘러보기 (홈페이지 교재 소개) <span className="text-[#8b88a0]">›</span>
            </a>
          </TabPage>
        )}

        {tab === 'me' && (
          <TabPage title="내 정보">
            {meetLinks.length > 0 && (
              <section className={`${card} grid gap-1 px-4 py-3`}>
                <h2 className="text-[15px] font-bold">수업 링크</h2>
                {meetLinks.map(([name, url]) => (
                  <a key={name} href={url!} target="_blank" rel="noreferrer" className="flex min-h-[48px] items-center justify-between border-t border-[#eeecf4] text-[14px] first-of-type:border-0">
                    <span>{name} 강사님</span>
                    <span className="font-semibold text-[#4b2fd6]">Google Meet ›</span>
                  </a>
                ))}
              </section>
            )}
            {reminders && (
              <section className={`${card} grid px-4 pb-1.5 pt-3`}>
                <h2 className="text-[15px] font-bold">수업 알림 메일</h2>
                <p className="text-[13px] text-[#55526a]">수업 24시간 전 · 2시간 전</p>
                {!reminders.hasEmail && <p className="mt-1 text-[13px] font-semibold text-[#c0392b]">등록된 이메일이 없어 메일을 받을 수 없어요.</p>}
                <Switch label="정규 수업" on={reminders.regular} disabled={busy} onChange={(v) => saveReminder({ regular: v })} />
                <Switch label="보강 수업" on={reminders.makeup} disabled={busy} onChange={(v) => saveReminder({ makeup: v })} />
              </section>
            )}
            <section className={`${card} px-4 pb-1.5 pt-2`}>
              {extras && <LinkRow label="결제 내역" value="" onClick={() => setOverlay({ kind: 'payments' })} />}
              <LinkRow label="적립금 내역" value={won(points.balance)} onClick={() => setOverlay({ kind: 'points' })} />
            </section>
            {props.onLogout && (
              <button type="button" onClick={props.onLogout} className="min-h-[44px] text-left text-[14px] text-[#55526a] underline">
                로그아웃
              </button>
            )}
          </TabPage>
        )}
      </div>

      <nav aria-label="아래 메뉴" className="fixed inset-x-0 bottom-0 z-10 grid grid-cols-5 border-t border-[#e6e3ef] bg-white pb-3 pt-1.5 lg:hidden">
        {TABS.map((t) => (
          <button
            key={t.key}
            type="button"
            onClick={() => setTab(t.key)}
            aria-current={tab === t.key ? 'page' : undefined}
            className={`flex min-h-[48px] flex-col items-center justify-center gap-0.5 text-[11px] ${tab === t.key ? 'font-bold text-[#5b3df0]' : 'text-[#55526a]'}`}
          >
            <Icon d={t.icon} />
            {t.label}
          </button>
        ))}
      </nav>

      {overlay && (
        <Sheet onClose={() => setOverlay(null)} wide={overlay.kind === 'makeup'}>
          {overlay.kind === 'request' && s.requests.find((r) => r.id === overlay.id) && <RequestDetail r={s.requests.find((r) => r.id === overlay.id)!} />}
          {overlay.kind === 'payments' && extras && <Payments payments={extras.payments} />}
          {overlay.kind === 'points' && <Points history={points} />}
          {overlay.kind === 'credits' && <Credits s={s} />}
          {overlay.kind === 'consent' && (
            <div className="grid gap-3">
              <h2 className="text-[18px] font-bold">새 수업 안내 확인</h2>
              <p className="text-[14px] leading-relaxed text-[#55526a]">수업 안내 확인·동의 화면은 시안(previews/consent-drafts) 확정 후 이 자리에 연결해요.</p>
              <button
                type="button"
                onClick={() => {
                  setConsents([]);
                  setOverlay(null);
                  say('동의했어요.');
                }}
                className="min-h-[50px] rounded-[14px] bg-[#5b3df0] text-[16px] font-bold text-white"
              >
                (미리보기) 동의 완료로 표시
              </button>
            </div>
          )}
          {overlay.kind === 'cancel' && (
            <CancelSheet
              key={overlay.lessonId ?? 'pick'}
              lessons={upcoming}
              lessonId={overlay.lessonId}
              onPick={(id) => setOverlay({ kind: 'cancel', lessonId: id })}
              now={now}
              creditsLeft={s.creditsLeft}
              finalEndDate={s.finalEndDate}
              makeupUntil={s.finalEndDate}
              holidays={holidays}
              regularLeft={regularLessonsLeft(lessons, now)}
              totalLeft={left.total}
              busy={busy}
              onConfirm={confirmCancel}
              onClose={() => setOverlay(null)}
            />
          )}
          {overlay.kind === 'leave' && (
            <LeaveSheet
              rows={s.leave}
              rights={s.makeupRights}
              busy={busy}
              onProfile={(name) => setOverlay({ kind: 'profile', name })}
              onAnswer={answerLeave}
              onMakeup={(right) => setOverlay({ kind: 'makeup', right })}
            />
          )}
          {overlay.kind === 'profile' && <Profile name={overlay.name} onBack={() => setOverlay({ kind: 'leave' })} />}
          {overlay.kind === 'makeup' &&
            (overlay.right ? (
              <MakeupPicker
                key={`${overlay.right.lessonId}${overlay.right.itemId}`}
                right={s.makeupRights.find((m) => sameRight(m, overlay.right!)) ?? null}
                canceled={overlay.canceled ?? false}
                endDate={endDate}
                load={actions.makeupOptions}
                busy={busy}
                onSubmit={async (right, slots) => {
                  const v = await run(() => actions.requestMakeup(right, slots), '요청했어요. 강사님이 확인하면 확정돼요.');
                  if (v) setOverlay(null);
                }}
              />
            ) : (
              <div className="grid gap-3">
                <h2 className="text-[18px] font-bold">보강할 수업</h2>
                {openRights.map((m) => (
                  <button key={`${m.lessonId}${m.itemId}`} type="button" onClick={() => setOverlay({ kind: 'makeup', right: m })} className={`${card} flex min-h-[56px] items-center justify-between px-4 text-left`}>
                    <span className="text-[15px] font-semibold">{whenText(m.originalAt)} 수업</span>
                    <span className="text-[#8b88a0]">›</span>
                  </button>
                ))}
              </div>
            ))}
        </Sheet>
      )}

      {toast && (
        <div role="status" className="fixed inset-x-4 top-4 z-30 mx-auto max-w-md lg:bottom-6 lg:top-auto rounded-[12px] bg-[#1d1b2b] px-4 py-3 shadow-lg">
          <p className="text-[13.5px] text-white">{toast}</p>
          <button type="button" onClick={() => setToast(null)} className="mt-1 text-[12.5px] font-semibold text-[#c9bcff] underline">
            닫기
          </button>
        </div>
      )}
    </div>
  );
}

function TodoBar({ n, text, onClick }: { n: number; text: string; onClick: () => void }) {
  return (
    <button type="button" onClick={onClick} className="flex min-h-[54px] w-full items-center gap-3 px-4 py-3 text-left">
      <span className="flex-1 text-[15px] font-semibold leading-snug">{text}</span>
      {n > 1 && <span className="text-[13px] text-[#8a5300]">{n}건</span>}
      <span className="whitespace-nowrap rounded-[10px] bg-[#5b3df0] px-3 py-1.5 text-[13px] font-bold text-white">확인 ›</span>
    </button>
  );
}

// 강사 휴무 안내 (A안 한 번에 답, 2026-10-28 대표). 학생은 강사를 고르지 않음 — 운영진이 정한 대체강사만 보여 줌
function LeaveSheet(props: {
  rows: LeaveRow[];
  rights: MakeupRight[];
  busy: boolean;
  onProfile: (name: string) => void;
  onAnswer: (a: 'ok' | 'makeup') => void;
  onMakeup: (r: Right) => void;
}) {
  const subs = props.rows.filter((x) => x.choice === 'substitute');
  const waits = props.rows.filter((x) => x.choice === 'wait');
  const ask = subs.filter((x) => x.stage === 'tutor_ok');
  const off = props.rows[0];
  const offText = off && `${fmtDate(formatInZone(off.offFrom, 'Asia/Seoul').date)} ~ ${fmtDate(formatInZone(new Date(off.offTo.getTime() - 1), 'Asia/Seoul').date)}`;
  return (
    <div className="grid gap-3.5">
      <div>
        <h2 className="text-[18px] font-bold">담당 강사님 휴무 안내</h2>
        {offText && <p className="mt-0.5 text-[13px] text-[#55526a]">휴무 {offText}</p>}
      </div>
      <p className="rounded-[14px] bg-[#efeaff] px-4 py-3 text-[15px] font-semibold leading-relaxed text-[#2b1c7a]">
        <span className="mr-1.5 rounded-full bg-[#5b3df0] px-2 py-0.5 text-[12px] text-white">추천</span>
        {subs.length && waits.length
          ? `휴무 기간 수업 ${props.rows.length}회 중 ${subs.length}회는 대체강사님과, ${waits.length}회는 기존 강사님과 진행해요.`
          : subs.length
            ? `휴무 기간 수업 ${subs.length}회는 대체강사님과 진행해요.`
            : `휴무 기간 수업 ${waits.length}회는 기존 강사님과 보강해요.`}
      </p>
      {subs.some((x) => x.stage === 'confirmed') && (
        <p className="rounded-[14px] bg-[#ffd66b] px-4 py-3 text-[15px] font-bold leading-snug text-[#1b1442]">⚠️ 대체강사 수업은 아래 링크에서 진행됩니다.</p>
      )}
      {subs.length > 0 && (
        <section className={`${card} grid gap-1 p-4`}>
          <h3 className="text-[15px] font-bold">대체강사와 수업하기</h3>
          {subs.map((x) => (
            <div key={x.id} className="flex items-center justify-between gap-2 border-b border-[#eeecf4] py-2.5 last:border-0">
              <span>
                <span className="block text-[15px] font-semibold">{whenText(x.startsAt)}</span>
                <span className="block text-[13px] text-[#55526a]">{x.subTutor} 강사님</span>
              </span>
              {x.stage === 'confirmed' ? (
                <span className="grid justify-items-end gap-1">
                  <span className="rounded-full bg-[#e3f5ea] px-2.5 py-1 text-[12px] font-semibold text-[#13623a]">확정 ✓</span>
                  {x.subMeetUrl && (
                    <a href={x.subMeetUrl} target="_blank" rel="noreferrer" className="text-[13px] font-bold text-[#4b2fd6] underline">
                      {x.subTutor} 강사님 수업 링크
                    </a>
                  )}
                </span>
              ) : (
                <button type="button" onClick={() => props.onProfile(x.subTutor ?? '')} className="min-h-[40px] rounded-[10px] border border-[#d9d5e8] px-3 text-[13px] font-semibold">
                  프로필 보기
                </button>
              )}
            </div>
          ))}
        </section>
      )}
      {waits.length > 0 && (
        <section className={`${card} grid gap-1 p-4`}>
          <h3 className="text-[15px] font-bold">기존 강사님과 보강</h3>
          {waits.map((x) => {
            const r = props.rights.find((m) => (x.lessonId && m.lessonId === x.lessonId) || (x.itemId && m.itemId === x.itemId));
            return (
              <div key={x.id} className="flex items-center justify-between gap-2 border-b border-[#eeecf4] py-2.5 last:border-0">
                <span className="text-[15px] font-semibold">{whenText(x.startsAt)}</span>
                {!r ? (
                  <span className="rounded-full bg-[#e3f5ea] px-2.5 py-1 text-[12px] font-semibold text-[#13623a]">보강 확정 ✓</span>
                ) : r.requested ? (
                  <span className="rounded-full bg-[#fff1d6] px-2.5 py-1 text-[12px] font-semibold text-[#8a5300]">신청함 · 강사 확인 중</span>
                ) : (
                  <button type="button" onClick={() => props.onMakeup(r)} className="min-h-[40px] rounded-[10px] bg-[#5b3df0] px-3 text-[13px] font-bold text-white">
                    보강 날짜 고르기
                  </button>
                )}
              </div>
            );
          })}
        </section>
      )}
      {ask.length > 0 && (
        <div className="grid gap-2">
          <button type="button" disabled={props.busy} onClick={() => props.onAnswer('ok')} className="min-h-[52px] rounded-[14px] bg-[#5b3df0] text-[16px] font-bold text-white disabled:opacity-50">
            좋아요, 이대로 할게요
          </button>
          <button type="button" disabled={props.busy} onClick={() => props.onAnswer('makeup')} className="min-h-[50px] rounded-[14px] border border-[#5b3df0] text-[15px] font-bold text-[#4b2fd6] disabled:opacity-50">
            전부 기존 강사님과 수업할게요
          </button>
        </div>
      )}
    </div>
  );
}

// 대체강사 프로필: 홈페이지 강사 소개(src/data/tutors.json)에 이미 공개된 내용만 (2026-10-28 대표: 홈페이지 보고 가져오기)
function Profile({ name, onBack }: { name: string; onBack: () => void }) {
  const p = homepageProfile(name);
  const video = p?.videoUrl.replace('/embed/', '/watch?v=');
  return (
    <div className="grid gap-3.5">
      <button type="button" onClick={onBack} className="flex min-h-[44px] items-center gap-1 justify-self-start rounded-[12px] border border-[#5b3df0] px-4 text-[15px] font-bold text-[#4b2fd6]">
        ← 휴무 안내로 돌아가기
      </button>
      <h2 className="text-[18px] font-bold">{p?.name ?? name} 강사님</h2>
      {p ? (
        <section className={`${card} grid gap-3 p-4 text-[14px] leading-relaxed`}>
          {p.career && (
            <div>
              <p className="text-[12.5px] font-bold text-[#5b3df0]">이력</p>
              <p className="whitespace-pre-line">{p.career}</p>
            </div>
          )}
          {p.intro && (
            <div>
              <p className="text-[12.5px] font-bold text-[#5b3df0]">소개</p>
              <p className="whitespace-pre-line">{p.intro}</p>
            </div>
          )}
          {video && (
            <a href={video} target="_blank" rel="noreferrer" className="flex min-h-[46px] items-center justify-center gap-2 rounded-[12px] bg-[#efeaff] text-[14px] font-bold text-[#4b2fd6]">
              ▶ 자기소개 영상 보기
            </a>
          )}
        </section>
      ) : (
        <p className="text-[14px] text-[#55526a]">프로필을 찾지 못했어요.</p>
      )}
    </div>
  );
}

// 보강 날짜 고르기 (2026-10-28 대표: 목록 대신 달력 — PC·휴대폰 같은 모양, 스크롤 줄이기)
// 달력에서 날짜 → 그날 가능한 시각 → 고른 날짜 최대 2개 → 신청. 날짜는 DB '보강 가능한 날짜'(강사 일정·휴무·종료일)만
function MakeupPicker(props: {
  right: MakeupRight | null;
  /** 방금 수업을 취소하고 넘어왔으면 맨 위에 결과 표시 */
  canceled: boolean;
  endDate: KstDate;
  load: (r: Right) => Promise<MakeupOption[]>;
  busy: boolean;
  onSubmit: (r: Right, slots: Date[]) => void;
}) {
  const [opts, setOpts] = useState<MakeupOption[] | null>(null);
  const [err, setErr] = useState<string | null>(null);
  const [day, setDay] = useState<string | null>(null);
  const [month, setMonth] = useState<string | null>(null);
  const [picked, setPicked] = useState<Date[]>([]);
  const { right, load } = props;

  useEffect(() => {
    if (!right) return;
    load(right)
      .then((o) => {
        setOpts(o);
        if (o[0]) setMonth(kst(o[0].startsAt).date.slice(0, 7));
      })
      .catch((e) => setErr(e instanceof Error ? e.message : '불러오지 못했어요.'));
  }, [right, load]);

  if (!right) return <p className="text-[14px]">이미 신청했거나 신청할 수 없는 수업이에요.</p>;
  const byDay = new Map<string, Date[]>();
  for (const o of opts ?? []) {
    const d = kst(o.startsAt).date;
    byDay.set(d, [...(byDay.get(d) ?? []), o.startsAt]);
  }
  const months = [...new Set([...byDay.keys()].map((d) => d.slice(0, 7)))].sort();
  const mi = month ? months.indexOf(month) : -1;
  const isPicked = (t: Date) => picked.some((p) => p.getTime() === t.getTime());
  const toggle = (t: Date) => setPicked(isPicked(t) ? picked.filter((p) => p.getTime() !== t.getTime()) : picked.length < MAKEUP_SLOTS_MAX ? [...picked, t].sort((a, b) => a.getTime() - b.getTime()) : picked);

  const calendar = month && (
    <section className={`${card} grid gap-2 p-3`}>
      <div className="flex items-center justify-between">
        <button type="button" aria-label="이전 달" disabled={mi <= 0} onClick={() => setMonth(months[mi - 1])} className="h-10 w-10 rounded-[10px] text-[18px] disabled:opacity-30">
          ‹
        </button>
        <span className="text-[15px] font-bold">
          {month.slice(0, 4)}년 {Number(month.slice(5))}월
        </span>
        <button type="button" aria-label="다음 달" disabled={mi < 0 || mi >= months.length - 1} onClick={() => setMonth(months[mi + 1])} className="h-10 w-10 rounded-[10px] text-[18px] disabled:opacity-30">
          ›
        </button>
      </div>
      <div className="grid grid-cols-7 gap-1 text-center text-[12px] text-[#6b6880]">
        {'일월화수목금토'.split('').map((w) => (
          <span key={w}>{w}</span>
        ))}
        {monthCells(month).map((d, i) =>
          !d ? (
            <span key={i} />
          ) : (
            <button
              key={d}
              type="button"
              disabled={!byDay.has(d)}
              onClick={() => setDay(d)}
              aria-pressed={day === d}
              className={`relative flex h-10 items-center justify-center rounded-full text-[14px] ${
                day === d ? 'bg-[#5b3df0] font-bold text-white' : byDay.has(d) ? 'bg-[#efeaff] font-semibold text-[#3a22b0]' : 'text-[#c4c1d2]'
              }`}
            >
              {Number(d.slice(8))}
              {(byDay.get(d) ?? []).some(isPicked) && day !== d && <span aria-hidden className="absolute bottom-1 h-1 w-1 rounded-full bg-[#5b3df0]" />}
            </button>
          ),
        )}
      </div>
      {props.endDate && !right.tutorLeave && <p className="text-[12px] text-[#6b6880]">수강 종료일 {fmtDate(props.endDate)}</p>}
    </section>
  );

  return (
    <div className="grid gap-3.5">
      {props.canceled && <p className="rounded-[12px] bg-[#e3f5ea] px-3.5 py-2.5 text-[15px] font-bold text-[#13623a]">✓ {whenText(right.originalAt)} 수업을 취소했어요</p>}
      <h2 className="text-[18px] font-bold">보강 날짜 고르기 · {whenText(right.originalAt)} 수업</h2>
      <p className="text-[14px] leading-relaxed text-[#55526a]">원하시는 일정을 최대 2개 고르실 수 있어요(선택). 2개를 고르시면 강사님이 확인 후 가능한 일정으로 확정해드립니다.</p>
      {err && <p className="text-[14px] text-[#b3261e]">{err}</p>}
      {!opts && !err && <p className="text-[14px] text-[#55526a]">불러오는 중…</p>}
      {opts && opts.length === 0 && <p className="text-[14px]">가능한 날짜가 없어요. 카카오톡으로 문의해 주세요.</p>}
      {opts && opts.length > 0 && (
        <div className="grid gap-3.5 lg:grid-cols-2 lg:items-start">
          {calendar}
          <div className="grid gap-3">
            <section className={`${card} grid gap-2 p-3`}>
              <p className="text-[14px] font-bold">{day ? `${fmtDate(day as KstDate)} (${kst(new Date(`${day}T12:00:00+09:00`)).wd})` : '날짜를 골라 주세요'}</p>
              {day && (
                <div className="grid grid-cols-3 gap-2">
                  {(byDay.get(day) ?? []).map((t) => (
                    <button
                      key={t.getTime()}
                      type="button"
                      aria-pressed={isPicked(t)}
                      disabled={!isPicked(t) && picked.length >= MAKEUP_SLOTS_MAX}
                      onClick={() => toggle(t)}
                      className={`min-h-[44px] rounded-[10px] border text-[14px] font-semibold disabled:opacity-40 ${isPicked(t) ? 'border-[#5b3df0] bg-[#5b3df0] text-white' : 'border-[#d9d5e8]'}`}
                    >
                      {kst(t).time}
                      {isPicked(t) ? ' ✓' : ''}
                    </button>
                  ))}
                </div>
              )}
            </section>
            <section className={`${card} sticky bottom-0 z-10 grid gap-2 p-3 shadow-[0_-6px_16px_rgba(27,20,66,0.12)]`}>
              <p className="text-[14px] font-bold">
                고른 날짜 {picked.length}/{MAKEUP_SLOTS_MAX}
              </p>
              {picked.map((t) => (
                <div key={t.getTime()} className="flex items-center justify-between rounded-[10px] border border-[#e6e3ef] px-3 py-2 text-[14px]">
                  <span className="font-semibold">{whenText(t)}</span>
                  <button type="button" aria-label="빼기" onClick={() => toggle(t)} className="h-8 w-8 text-[16px] text-[#55526a]">
                    ×
                  </button>
                </div>
              ))}
              <button
                type="button"
                disabled={picked.length === 0 || props.busy}
                onClick={() => props.onSubmit(right, picked)}
                className="min-h-[50px] rounded-[14px] bg-[#5b3df0] text-[16px] font-bold text-white disabled:opacity-40"
              >
                강사님께 확정 요청하기
              </button>
            </section>
          </div>
        </div>
      )}
    </div>
  );
}

/** 'YYYY-MM' 달력 칸 (일요일 시작, 앞쪽 빈칸 null) */
function monthCells(month: string): (string | null)[] {
  const first = new Date(`${month}-01T00:00:00Z`);
  const days = new Date(Date.UTC(first.getUTCFullYear(), first.getUTCMonth() + 1, 0)).getUTCDate();
  return [...Array<null>(first.getUTCDay()).fill(null), ...Array.from({ length: days }, (_, i) => `${month}-${String(i + 1).padStart(2, '0')}`)];
}

/** 보강을 캘린더에 더하기 (2026-10-29 대표, 학생·강사 화면 같은 버튼) */
export function AddToCalendar({ ev, google, file }: { ev: CalendarEvent; google: string; file: string }) {
  const cls = 'inline-flex min-h-[36px] items-center rounded-[10px] border border-[#d9d5e8] bg-white px-2.5 text-[13px] font-semibold text-[#1b1442]';
  return (
    <span className="mt-1.5 flex flex-wrap gap-1.5">
      <a href={googleCalendarUrl(ev)} target="_blank" rel="noreferrer" className={cls}>{google}</a>
      <a href={icsUrl(ev)} className={cls}>{file}</a>
    </span>
  );
}

function NextLesson({ lesson, now, textbook, meetUrl, substitute, leaveOpen }: { lesson: StudentLesson; now: Date; textbook: { title: string; lastUnit: number } | null; meetUrl: string | null; substitute: boolean; leaveOpen?: boolean }) {
  const k = kst(lesson.startsAt);
  const days = diffDays(formatInZone(now, 'Asia/Seoul').date, k.date);
  const started = now.getTime() >= lesson.startsAt.getTime();
  const hours = hoursBetween(now, lesson.startsAt);
  const badge = started ? '진행 중' : hours < 24 ? `${Math.max(1, Math.round(hours))}시간 후` : days === 1 ? '내일' : `${days}일 후`;
  return (
    <section aria-label="다음 수업" className="grid gap-3.5 rounded-[20px] bg-[#1b1442] p-5 text-white lg:rounded-[22px] lg:p-6">
      <div className="flex items-center justify-between">
        <span className="text-[13px] font-semibold text-[#c9c0ff]">다음 수업</span>
        <span className="rounded-full bg-[#ffd66b] px-2.5 py-1 text-[12px] font-semibold text-[#1b1442]">{badge}</span>
      </div>
      {/* 대체강사 수업은 수업 링크가 다름 — 늘 쓰던 링크로 들어가는 일이 잦음 (대표 10/29) */}
      {/* 휴무 처리 확정 전: 휴무 강사와 정상 수업처럼 보이지 않게 (대표 10/30) */}
      {leaveOpen && (
        <p className="rounded-[12px] bg-[#ffd66b] px-3.5 py-2.5 text-[15px] font-bold leading-snug text-[#1b1442]">⚠️ 강사님 휴무로 일정 조율 중</p>
      )}
      {substitute && (
        <p className="rounded-[12px] bg-[#ffd66b] px-3.5 py-2.5 text-[15px] font-bold leading-snug text-[#1b1442]">
          ⚠️ 대체강사 {lesson.tutorName} 강사님 수업이에요. 아래 &lsquo;수업 입장&rsquo; 링크에서 진행됩니다.
        </p>
      )}
      <div>
        <p className="text-[26px] font-bold tracking-tight text-white lg:text-[30px]">
          {Number(k.md.split('/')[0])}월 {Number(k.md.split('/')[1])}일 ({k.wd}) {k.time}
        </p>
        <p className="mt-1 text-[14px] text-[#d8d3f5]">
          {lesson.minutes}분{leaveOpen ? '' : ` · ${lesson.tutorName}`} · 한국 시간{lesson.kind === 'makeup' ? ' · 보강' : ''}
        </p>
      </div>
      <div className="grid gap-2.5 lg:grid-cols-2">
        {textbook && (
        <a href="/books" className="flex min-h-[44px] items-center justify-between gap-2.5 rounded-[12px] bg-[#2c2263] px-3.5 py-3 text-[14px] lg:order-2">
          <span className="flex items-center gap-2.5">
            <Icon d={TABS[3].icon} className="h-[18px] w-[18px] text-[#c9c0ff]" />
            <span className="text-white">
              교재 <b className="text-white">{textbook.title}</b> · Unit {textbook.lastUnit}
            </span>
          </span>
          <span className="whitespace-nowrap text-[13px] text-[#c9c0ff]">보기 ›</span>
        </a>
        )}
        {meetUrl ? (
          <a href={meetUrl} target="_blank" rel="noreferrer" className="flex min-h-[50px] items-center justify-center gap-2 rounded-[14px] bg-white text-[16px] font-bold text-[#1b1442] lg:order-1">
            <Icon d="M4 6h10a2 2 0 0 1 2 2v8a2 2 0 0 1-2 2H4a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2zM16 10l6-3v10l-6-3z" />
            수업 입장 (Google Meet)
          </a>
        ) : null}
      </div>

    </section>
  );
}

function Tile({ label, value, unit, sub, onClick }: { label: string; value: string; unit?: string; sub: string; onClick?: () => void }) {
  const body = (
    <>
      <p className="text-[12px] text-[#55526a]">{label}</p>
      <p className="mt-1 text-[22px] font-bold">
        {value}
        {unit && <span className="text-[13px] font-medium">{unit}</span>}
      </p>
      <p className="text-[11px] text-[#6b6880]">{sub}</p>
    </>
  );
  return onClick ? (
    <button type="button" onClick={onClick} className={`${card} p-3 text-left lg:p-4`}>
      {body}
    </button>
  ) : (
    <div className={`${card} p-3 lg:p-4`}>{body}</div>
  );
}

// 변경권: 지금 기간과 언제 썼는지 (대표 10/29)
function Credits({ s }: { s: StudentView }) {
  const text = (c: StudentView['creditUses'][number]) =>
    c.reason === 'student_change'
      ? `${c.lessonAt ? `${whenText(c.lessonAt)} 수업 취소` : '수업 취소'}`
      : c.reason === 'admin_restore'
        ? `${c.lessonAt ? `${whenText(c.lessonAt)} 수업 ` : ''}취소 되돌림`
        : 'LMS 시작 전 사용';
  return (
    <div className="grid gap-3.5">
      <h2 className="text-[18px] font-bold">변경권</h2>
      <section className="flex items-center justify-between rounded-[18px] bg-[#1b1442] p-4 text-white">
        <div>
          <p className="text-[13px] text-[#c9c0ff]">남은 변경권</p>
          <p className="mt-0.5 text-[26px] font-bold text-white">
            {s.creditsLeft}개 <span className="text-[14px] font-medium text-[#d8d3f5]">/ {s.creditsPerPeriod}개</span>
          </p>
        </div>
        {s.creditPeriod && (
          <p className="text-right text-[12.5px] text-[#d8d3f5]">
            이번 기간
            <br />
            {fmtDate(s.creditPeriod.start)} ~ {fmtDate(s.creditPeriod.end)}
          </p>
        )}
      </section>
      <section className={`${card} px-4`}>
        {s.creditUses.length === 0 && <p className="py-4 text-[14px] text-[#6b6880]">이번 기간에 쓴 변경권이 없어요.</p>}
        {s.creditUses.map((c, i) => (
          <div key={i} className="flex items-center justify-between gap-3 border-b border-[#eeecf4] py-3 text-[14px] last:border-0">
            <span>{text(c)}</span>
            <b className={c.delta > 0 ? 'text-[#13623a]' : ''}>{c.delta > 0 ? '+1' : '−1'}</b>
          </div>
        ))}
      </section>
    </div>
  );
}

function RequestRow({ r, onOpen }: { r: StudentRequest; onOpen: () => void }) {
  return (
    <button type="button" onClick={onOpen} className="flex min-h-[56px] w-full items-center justify-between gap-2 border-b border-[#eeecf4] py-2 text-left last:border-0">
      <span>
        <span className="block text-[14px] font-semibold">{r.title}</span>
        <span className="block text-[12px] text-[#6b6880]">{r.kind === 'makeup' ? `고른 날짜 ${r.candidates.length}개` : r.note}</span>
      </span>
      <span className="flex items-center gap-1.5">
        <span className={`whitespace-nowrap rounded-full px-2.5 py-1 text-[12px] font-semibold ${STATUS_STYLE[r.status]}`}>{REQUEST_STATUS_LABEL[r.status]}</span>
        <span className="text-[#8b88a0]">›</span>
      </span>
    </button>
  );
}

// 누를 곳이 없으면 버튼 모양(›) 없이 글만 (R8)
function LinkRow({ label, value, valueClass = 'font-semibold', onClick }: { label: string; value: string; valueClass?: string; onClick?: () => void }) {
  if (!onClick) return (
    <div className="flex min-h-[52px] w-full items-center justify-between border-t border-[#eeecf4] text-[14px] first:border-0">
      <span className="text-[#55526a]">{label}</span>
      <span className={valueClass}>{value}</span>
    </div>
  );
  return (
    <button type="button" onClick={onClick} className="flex min-h-[52px] w-full items-center justify-between border-t border-[#eeecf4] text-left text-[14px] first:border-0">
      <span className="text-[#55526a]">{label}</span>
      <span className={valueClass}>
        {value} <span className="font-normal text-[#8b88a0]">›</span>
      </span>
    </button>
  );
}

function Switch({ label, on, disabled, onChange }: { label: string; on: boolean; disabled: boolean; onChange: (v: boolean) => void }) {
  return (
    <button
      type="button"
      role="switch"
      aria-checked={on}
      disabled={disabled}
      onClick={() => onChange(!on)}
      className="flex min-h-[48px] items-center justify-between border-t border-[#eeecf4] text-left text-[15px] first-of-type:border-0"
    >
      <span>{label}</span>
      <span className={`relative h-7 w-[46px] flex-none rounded-full transition-colors ${on ? 'bg-[#5b3df0]' : 'bg-[#dcd8e8]'}`}>
        <span className={`absolute top-[3px] h-[22px] w-[22px] rounded-full bg-white transition-all ${on ? 'right-[3px]' : 'left-[3px]'}`} />
      </span>
    </button>
  );
}

function PreviewChip({ on, onClick, children }: { on: boolean; onClick: () => void; children: React.ReactNode }) {
  return (
    <button type="button" onClick={onClick} className={`min-h-[32px] rounded-full border px-2.5 text-[12px] font-semibold ${on ? 'border-[#5c4a00] bg-[#5c4a00] text-white' : 'border-[#e0cf8a] bg-white'}`}>
      {children}
    </button>
  );
}

function TabPage({ title, children }: { title: string; children: React.ReactNode }) {
  return (
    <div className="grid gap-3 px-4 lg:max-w-[720px] lg:px-0">
      <h1 className="text-[22px] font-bold">{title}</h1>
      {children}
    </div>
  );
}

function Sheet({ onClose, children, wide }: { onClose: () => void; children: React.ReactNode; wide?: boolean }) {
  return (
    <div className="fixed inset-0 z-20 flex items-end justify-center bg-black/40 lg:items-center" onClick={onClose}>
      <div role="dialog" aria-modal className={`max-h-[90dvh] w-full ${wide ? 'max-w-[520px] lg:max-w-[860px]' : 'max-w-[520px]'} overflow-y-auto rounded-t-[22px] bg-[#f6f5fa] p-5 lg:rounded-[22px]`} onClick={(e) => e.stopPropagation()}>
        <div className="flex justify-end">
          <button type="button" aria-label="닫기" onClick={onClose} className="-mr-2 -mt-2 flex h-11 w-11 items-center justify-center rounded-full text-[22px] leading-none text-[#55526a] hover:bg-[#ebe8f5]">
            ✕
          </button>
        </div>
        {children}
      </div>
    </div>
  );
}

function RequestDetail({ r }: { r: StudentRequest }) {
  const steps = ['신청', r.status === 'admin_reviewing' ? '운영자 확인' : '강사 확인', '확정'];
  const at = r.status === 'tutor_reviewing' || r.status === 'admin_reviewing' ? 1 : 2;
  const c = kst(r.createdAt);
  return (
    <div className="grid gap-3.5">
      <h2 className="text-[18px] font-bold">{r.title}</h2>
      <section className={`${card} grid gap-3.5 p-4`}>
        <div className="flex items-center justify-between">
          <span className="text-[13px] text-[#55526a]">지금 상태</span>
          <span className={`rounded-full px-3 py-1 text-[13px] font-semibold ${STATUS_STYLE[r.status]}`}>{REQUEST_STATUS_LABEL[r.status]}</span>
        </div>
        <ol className="flex gap-1.5">
          {steps.map((t, i) => (
            <li key={t} className="flex-1 text-center">
              <div className={`h-1.5 rounded ${i < at ? 'bg-[#5b3df0]' : i === at && at < 2 ? 'bg-[#f0a33a]' : i <= at ? 'bg-[#5b3df0]' : 'bg-[#e6e3ef]'}`} />
              <span className={`mt-1.5 block text-[12px] ${i <= at ? 'font-semibold' : 'text-[#8b88a0]'}`}>{t}</span>
            </li>
          ))}
        </ol>
      </section>
      {r.candidates.length > 0 && (
        <section className={`${card} grid gap-2.5 p-4`}>
          <h3 className="text-[15px] font-bold">내가 고른 날짜</h3>
          {r.candidates.map((d, i) => {
            const k = kst(d);
            return (
              <div key={i} className="flex items-center gap-3 rounded-[12px] border border-[#e6e3ef] px-3.5 py-3">
                <span className="text-[12px] font-bold text-[#5b3df0]">{i + 1}</span>
                <span className="text-[16px] font-bold">
                  {k.md} ({k.wd}) {k.time}
                </span>
              </div>
            );
          })}
          <p className="text-[12px] text-[#55526a]">한국 시간</p>
        </section>
      )}
      <section className={`${card} grid gap-2 p-4 text-[14px]`}>
        <div className="flex justify-between">
          <span className="text-[#55526a]">내용</span>
          <span>{r.note}</span>
        </div>
        <div className="flex justify-between">
          <span className="text-[#55526a]">신청한 날</span>
          <span>
            {c.md} ({c.wd}) {c.time}
          </span>
        </div>
      </section>
    </div>
  );
}

function Payments({ payments }: { payments: PaymentSummary[] }) {
  // 금액·카드 정보는 보여 주지 않음 (POL-PAY-11). 카드 영수증은 아임웹 주문조회로
  return (
    <div className="grid gap-3.5">
      <h2 className="text-[18px] font-bold">결제 내역</h2>
      {payments.map((p) => (
        <section key={p.id} className={`${card} grid gap-2.5 p-4 text-[14px]`}>
          <div className="flex items-center justify-between">
            <h3 className="text-[15px] font-bold">{p.current ? '지금 수강권' : '지난 수강권'}</h3>
            <span className={`rounded-full px-2.5 py-1 text-[12px] font-semibold ${p.confirmedOn ? 'bg-[#e3f5ea] text-[#13623a]' : 'bg-[#fff1d6] text-[#8a5300]'}`}>
              {p.confirmedOn ? '결제 확인 완료' : '결제 확인 중'}
            </span>
          </div>
          <Row k="수강권" v={p.product} />
          <Row k="수강 기간" v={`${fmtDate(p.periodStart)} ~ ${fmtDate(p.periodEnd)}`} />
          <Row k="결제 방법" v={PAYMENT_METHOD_LABEL[p.method]} />
          <Row k="확인한 날" v={p.confirmedOn ? `${fmtDate(p.confirmedOn)} · 운영자 확인` : '-'} />
          {p.method === 'card_imweb' && (
            <span aria-disabled title="아임웹 주문조회 주소 확인 후 연결" className="mt-1 flex min-h-[46px] items-center justify-center rounded-[12px] border border-[#d9d5e8] text-[14px] font-semibold text-[#55526a]">
              카드 영수증 · 주문 보기 (아임웹) ↗
            </span>
          )}
        </section>
      ))}
      <p className="text-[12px] leading-relaxed text-[#55526a]">결제 금액·카드 정보는 이 화면에 따로 표시하지 않아요 (아임웹 주문조회에서 확인). 결제는 운영자가 직접 확인해요.</p>
    </div>
  );
}

function Points({ history }: { history: ReturnType<typeof pointsHistory> }) {
  return (
    <div className="grid gap-3.5">
      <h2 className="text-[18px] font-bold">적립금 내역</h2>
      <section className="flex items-center justify-between rounded-[18px] bg-[#1b1442] p-4 text-white">
        <div>
          <p className="text-[13px] text-[#c9c0ff]">사용할 수 있는 적립금</p>
          <p className="mt-0.5 text-[26px] font-bold text-white">{won(history.balance)}</p>
        </div>
        <p className="text-right text-[12px] leading-relaxed text-[#d8d3f5]">
          유효기간 없음
          <br />
          재등록 결제 때 사용
        </p>
      </section>
      <section className={`${card} px-4`}>
        {history.rows.map((r) => (
          <div key={r.id} className="grid grid-cols-[1fr_auto] gap-x-3 border-b border-[#eeecf4] py-3 last:border-0">
            <span className="text-[14px]">{r.reason}</span>
            <b className={`text-right text-[14px] ${r.signed > 0 ? 'text-[#13623a]' : ''}`}>
              {r.signed > 0 ? '+' : '−'}
              {won(Math.abs(r.signed))}
            </b>
            <span className="text-[12px] text-[#6b6880]">{fmtDate(r.on)}</span>
            <span className="text-right text-[12px] text-[#6b6880]">잔액 {won(r.balanceAfter)}</span>
          </div>
        ))}
      </section>
      <p className="text-[12px] leading-relaxed text-[#55526a]">사용 신청은 재등록할 때 해요. 결제가 취소·환불되면 사용한 적립금은 다시 돌아와요.</p>
    </div>
  );
}

function Row({ k, v }: { k: string; v: string }) {
  return (
    <div className="flex justify-between gap-3">
      <span className="text-[#55526a]">{k}</span>
      <span className="text-right">{v}</span>
    </div>
  );
}

// 6시간 이내 취소 확인 문구 (대표 원문, docs/lms-기획서-원문.md 3-3)
const LATE_CANCEL_TEXT = '수업 시작까지 6시간이 남지 않았어요. 지금 취소하면 보강 없이 수업 1회가 소진돼요. (변경권은 차감되지 않아요) 그래도 미리 알려주시면 강사님이 기다리지 않아도 돼요. 취소할까요?';

function CancelSheet(props: {
  lessons: StudentLesson[];
  lessonId: string | null;
  onPick: (id: string) => void;
  now: Date;
  creditsLeft: number;
  finalEndDate: KstDate;
  /** 보강 기한 = 수강 종료일 */
  makeupUntil: KstDate;
  holidays: ReadonlySet<KstDate>;
  regularLeft: number;
  totalLeft: number;
  busy: boolean;
  onConfirm: (l: StudentLesson) => void;
  onClose: () => void;
}) {
  const [checked, setChecked] = useState(false);
  const lesson = props.lessons.find((l) => l.id === props.lessonId);

  if (!lesson) {
    return (
      <div className="grid gap-3">
        <h2 className="text-[18px] font-bold">어느 수업을 바꿀까요?</h2>
        {props.lessons.map((l) => {
          const k = kst(l.startsAt);
          const h = hoursBetween(props.now, l.startsAt);
          return (
            <button key={l.id} type="button" onClick={() => props.onPick(l.id)} className={`${card} flex min-h-[56px] items-center justify-between px-4 text-left`}>
              <span className="text-[15px] font-semibold">
                {k.md} ({k.wd}) {k.time}
              </span>
              <span className="text-[12.5px] text-[#6b6880]">{h < 6 ? '6시간 이내' : h < 24 ? `${Math.floor(h)}시간 후` : `${Math.floor(h / 24)}일 후`} ›</span>
            </button>
          );
        })}
      </div>
    );
  }

  const d = cancelPreview({ lesson, now: props.now, finalEndDate: props.finalEndDate, creditsLeft: props.creditsLeft, holidays: props.holidays }, null);
  const k = kst(lesson.startsAt);
  const title = `${k.md} (${k.wd}) ${k.time} 수업을 취소할까요?`;

  if (!d.ok) {
    const msg =
      d.reason === 'policy_pending' ? '보상 수업 취소 규칙이 아직 정해지지 않았어요. 카카오톡으로 문의해 주세요.' : d.reason === 'already_started' ? '이미 시작한 수업은 취소할 수 없어요.' : '수강기간이 지난 수업이에요.';
    return (
      <div className="grid gap-3">
        <h2 className="text-[18px] font-bold">{title}</h2>
        <p className="text-[14px]">{msg}</p>
      </div>
    );
  }

  const hours = hoursBetween(props.now, lesson.startsAt);
  const needsCheck = d.consumesLesson; // 수업이 차감되면 한 번 더 확인
  const late = d.timing === 'late';
  const rows: [string, string][] = [
    ['수업 횟수', d.consumesLesson ? `1회 차감 (남은 ${props.totalLeft}회 → ${props.totalLeft - 1}회)` : '차감 안 됨'],
    ['보강', d.makeupAllowed ? `수강기간(~${fmtDate(props.makeupUntil)}) 안에 보강 가능` : '불가'],
    ['변경권', d.usesCredit ? `1개 사용 (${props.creditsLeft}개 → ${props.creditsLeft - 1}개)` : `사용 안 함 (${props.creditsLeft}개 그대로)`],
  ];

  return (
    <div className="grid gap-3.5">
      <h2 className="text-[19px] font-bold">{d.timing === 'late' ? `수업 시작 ${hours < 1 ? '1시간 이내' : `${Math.floor(hours)}시간 전`}이에요` : title}</h2>
      <section className={`grid gap-2 rounded-[14px] p-3.5 text-[14px] leading-normal ${needsCheck ? 'border border-[#f3c2bb] bg-[#fff1ef] text-[#7a1d12]' : 'bg-[#f1eefc]'}`}>
        <p className={`font-bold ${needsCheck ? 'text-[#7a1d12]' : ''}`}>지금 취소하면</p>
        {rows.map(([a, b]) => (
          <div key={a} className="flex justify-between gap-3">
            <span className={needsCheck ? 'text-[#7a1d12]' : ''}>{a}</span>
            <b className={`text-right ${needsCheck ? 'text-[#7a1d12]' : ''}`}>{b}</b>
          </div>
        ))}
      </section>
      {late ? (
        <p className="text-[15px] leading-relaxed">{LATE_CANCEL_TEXT}</p>
      ) : (
        <p className="text-[12.5px] leading-relaxed text-[#55526a]">{d.studentMessage}</p>
      )}
      {needsCheck && !late && (
        <label className="flex min-h-[44px] items-start gap-2.5 text-[14px] leading-normal">
          <input type="checkbox" checked={checked} onChange={(e) => setChecked(e.target.checked)} className="mt-0.5 h-5 w-5 accent-[#b3261e]" />
          수업 1회가 차감되고 보강이 없다는 것을 확인했어요
        </label>
      )}
      <button
        type="button"
        disabled={(needsCheck && !late && !checked) || props.busy}
        onClick={() => props.onConfirm(lesson)}
        className={`min-h-[52px] rounded-[14px] text-[16px] font-bold text-white disabled:opacity-40 ${needsCheck ? 'bg-[#b3261e]' : 'bg-[#5b3df0]'}`}
      >
        {late ? '취소할게요' : needsCheck ? '1회 차감하고 취소' : '취소하고 보강 시간 고르기'}
      </button>
      <button type="button" onClick={props.onClose} className="min-h-[44px] text-[14px] text-[#55526a]">
        {late ? '돌아가기' : '취소 안 함'}
      </button>
    </div>
  );
}
