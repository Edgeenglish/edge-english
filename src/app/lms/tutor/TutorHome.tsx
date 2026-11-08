'use client';

// 강사 화면 (영어, 휴대폰 우선, 2026-11-04 개편): 왼쪽(PC)·아래(휴대폰) 고정 메뉴 Home · Schedule · Class Record · Students · Availability
// Home = 오늘 수업·할 일, Schedule = 월간·주간 일정 + 날짜별 막기·열기 (H26(49)+(50)), Class Record = 주별 기록 작성·조회,
// Students = 담당 학생 → 프로필, Availability = 매주 가능 시간 (예전 My hours)
// 화면 검사는 편의일 뿐, 본인 수업인지·시작했는지·정산 잠김은 DB 함수가 다시 확인 (migration 2000)

import { createContext, useCallback, useContext, useEffect, useRef, useState, type ReactNode } from 'react';
import { googleCalendarUrl, icsUrl } from '@/lms/calendar/add';
import { ampmEn, formatInZone } from '@/lms/rules/dates';
import { tutorPaidFor } from '@/lms/rules/status';
import { cityTime } from '@/lms/tutor/hours-view';
import TutorHours, { type HoursActions } from './TutorHours';
import TutorSchedule, { type ScheduleActions } from './TutorSchedule';
import { useSavedToggle, useSavedValue } from './useSaved';
import StudentProfile, { type ProfileActions } from './StudentProfile';
import FirstLessonFollowup, { type FollowupSave } from './FirstLessonFollowup';
import type { FollowupTodo } from '@/lms/tutor/followup';
import { LangCtx, useT, type Lang } from '@/lms/tutor/lang';
import { Rich } from '@/app/lms/Rich';
import { enBoth, stripBold } from '@/lms/admin/time-text';
import {
  canRecord, KOREA_TIME, tzHeader, tzTimeLabel, daysOf, dayLabel, kindTag, kstText, makeupOrigin, localDate, minutesOf, phaseOf, recordReady, RESULT_TEXT, resultOf, savedStatus, lateText, lateToSave, LATE_PRESETS, type Late,
  statusText, rangeFull, rangeFullNoDay, weekOf, whenFull, whenText, type TutorCanceled, type TutorCover, type TutorLesson, type TutorMakeup, type TutorResult, type TutorScreen, busyText } from '@/lms/tutor/screen';

export type TutorActions = {
  load: (kstFrom: string, kstTo: string) => Promise<TutorScreen>;
  record: (lessonId: string, result: TutorResult, topics: string, remarks: string, late: Late) => Promise<void>;
  answer: (requestId: string, yes: string[], note: string) => Promise<void>;
  /** 보강 확정 (H26(82)): 학생 시간 하나를 골라 바로 확정. 없으면 [Confirm] 버튼이 잠김 */
  confirm?: (requestId: string, slotId: string) => Promise<void>;
  /** 대체 수업 요청 답: items = 답하는 수업 전체, yes = 가능한 수업 */
  answerCover: (items: string[], yes: string[]) => Promise<void>;
  /** 매주 가능 시간 [Availability] (migration 3100) */
  hours: HoursActions;
  /** Schedule 날짜별 막기·열기 (migration 4403) */
  schedule: ScheduleActions;
  /** 학생 프로필 (4300): 학생 이름을 누르면 열림. 없으면 이름만 글자 */
  profile?: ProfileActions;
  /** Students 메뉴: 담당 학생 목록 (tutor_my_students — 정규 담당·확정 대체만, DB 가 정함) */
  students?: () => Promise<TutorStudentRow[]>;
  /** 첫 수업 후 To-do (4600): Home 목록 + 저장. 없으면 그 To-do 칸이 안 보임 */
  followups?: () => Promise<FollowupTodo[]>;
  followupSave?: FollowupSave;
  /** 취소된 수업 To-do: 학생이 취소한 앞으로의 수업 (tutor_canceled_classes). 없으면 그 칸이 안 보임 */
  canceled?: () => Promise<TutorCanceled[]>;
};

/** 학생 이름 → 프로필 창 (이 화면 어디서든 같은 창) */
const ProfileCtx = createContext<((studentId: string) => void) | null>(null);
function StudentName({ id, name, className }: { id?: string; name: ReactNode; className?: string }) {
  const open = useContext(ProfileCtx);
  if (!id || !open) return <span className={className}>{name}</span>;
  return (
    <button type="button" onClick={(e) => { e.stopPropagation(); open(id); }} title="Student profile"
      className={`${className ?? ''} cursor-pointer text-left underline decoration-[#c9c0ff] decoration-2 underline-offset-2 hover:text-[#5b3fe0]`}>
      {name}
    </button>
  );
}

const card = 'rounded-[14px] border border-[#e6e3ef] bg-white p-4';
const btnMain = 'min-h-[44px] rounded-[10px] bg-[#5b3fe0] px-4 text-[15px] font-semibold text-white disabled:opacity-40';
const btnDone = 'min-h-[44px] rounded-[10px] bg-[#e9e7f0] px-4 text-[15px] font-semibold text-[#6b6880]';
const btnSub = 'min-h-[44px] rounded-[10px] border border-[#e6e3ef] bg-white px-4 text-[15px] font-semibold text-[#1d1b2b] disabled:opacity-40';
const input = 'w-full rounded-[10px] border border-[#d9d5e6] bg-white px-3 py-2.5 text-[16px] text-[#1d1b2b]';
const label = 'mb-1 block text-[13px] font-semibold text-[#55526a]';

type Tab = 'home' | 'schedule' | 'record' | 'students' | 'hours';
// 메뉴 이름은 대표가 정한 영문 그대로 (2026-11-04, H26(50): My hours → Availability. 저장 키 'hours' 는 그대로)
const TABS: { key: Tab; label: string; icon: string }[] = [
  { key: 'home', label: 'Home', icon: 'M3 11l9-7 9 7v9a1 1 0 0 1-1 1h-5v-6H9v6H4a1 1 0 0 1-1-1z' },
  { key: 'schedule', label: 'Schedule', icon: 'M8 2v3M16 2v3M3 9h18M5 5h14a2 2 0 0 1 2 2v12a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V7a2 2 0 0 1 2-2z' },
  { key: 'record', label: 'Class Record', icon: 'M9 12l2 2 4-4M5 3h14a2 2 0 0 1 2 2v14a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2z' },
  { key: 'students', label: 'Students', icon: 'M16 11a4 4 0 1 0-8 0 4 4 0 0 0 8 0zM4 21v-1a6 6 0 0 1 6-6h4a6 6 0 0 1 6 6v1' },
  { key: 'hours', label: 'Availability', icon: 'M12 7v5l3 2M21 12a9 9 0 1 1-18 0 9 9 0 0 1 18 0z' },
];
// 운영자 보기 한국어 라벨 (강사 본인은 늘 영어)
const TAB_KO: Record<Tab, string> = { home: '홈', schedule: '일정', record: 'Class Record', students: '학생', hours: '가능 시간' };
function Icon({ d }: { d: string }) {
  return (
    <svg aria-hidden viewBox="0 0 24 24" className="h-[20px] w-[20px] shrink-0" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round">
      <path d={d} />
    </svg>
  );
}

/** Students 메뉴 한 줄 (tutor_my_students, 4300) */
export type TutorStudentRow = { id: string; name: string; level: string | null; classType: string | null; timezone: string | null; noteUrl: string | null };

export default function TutorHome({ initial, nowIso, actions, adminBar, onLogout, lang = 'en' }: {
  initial: TutorScreen;
  nowIso: string;
  actions: TutorActions;
  adminBar?: ReactNode;
  onLogout?: () => void;
  /** 운영자 보기에서만 'ko' (강사 본인은 늘 영어, H26(73)) */
  lang?: Lang;
}) {
  return (
    <LangCtx.Provider value={lang}>
      <TutorHomeInner initial={initial} nowIso={nowIso} actions={actions} adminBar={adminBar} onLogout={onLogout} />
    </LangCtx.Provider>
  );
}

function TutorHomeInner({ initial, nowIso, actions, adminBar, onLogout }: {
  initial: TutorScreen;
  nowIso: string;
  actions: TutorActions;
  adminBar?: ReactNode;
  onLogout?: () => void;
}) {
  const t = useT();
  const [screen, setScreen] = useState(initial);
  const [now, setNow] = useState(() => new Date(nowIso));
  // 마지막에 연 메뉴를 다음에도 그대로 (이 기기)
  const [tab, setTab] = useSavedValue<Tab>('lms_tutor_menu', 'home', TABS.map((t) => t.key));
  const [offset, setOffset] = useState(0);
  const [loading, setLoading] = useState(false);
  const [err, setErr] = useState('');
  // 이번에 기록·답한 것은 목록에서 빠지지 않고 '✓'로 남음 (2026-10-28 대표: 처리한 것은 사라지지 않게)
  const [recordedHere, setRecordedHere] = useState<TutorLesson[]>([]);
  const [answeredHere, setAnsweredHere] = useState<TutorMakeup[]>([]);
  const tz = screen.tutor.timezone;
  // KST·Paid 칸: 강사가 끌 수 있음, 이 기기에 기억 (대표 10/29). 한국 시간대 강사는 KST 칸 없음
  const [kstPref, setKst] = useSavedToggle('lms_tutor_kst');
  const [paidCol, setPaidCol] = useSavedToggle('lms_tutor_paid');
  const kstOn = tz === 'Asia/Seoul' ? null : kstPref;
  const kst = kstOn === true;
  const week = weekOf(now, tz, offset);
  // 학생별로 보기 (대표 10/29): 학생을 고르면 그 학생의 모든 수업을 날짜순으로 (주 단위 대신)
  const [student, setStudent] = useState('');
  const [allLessons, setAllLessons] = useState<TutorLesson[] | null>(null);
  const studentNames = [...new Set([...(allLessons ?? []), ...screen.lessons].map((l) => l.student))].sort();
  async function loadAll(): Promise<void> {
    if (!allLessons) await refreshAll();
  }
  async function refreshAll(): Promise<void> {
    setLoading(true);
    setErr('');
    try {
      setAllLessons((await actions.load('2000-01-01', '2100-12-31')).lessons);
    } catch (e) {
      setErr(e instanceof Error ? e.message : 'Could not load. Please try again.');
    } finally {
      setLoading(false);
    }
  }

  useEffect(() => setScreen(initial), [initial]);

  async function reload(off = offset) {
    setLoading(true);
    setErr('');
    try {
      const n = new Date();
      const w = weekOf(n, tz, off);
      setScreen(await actions.load(w.kstFrom, w.kstTo));
      setNow(n);
      // 첫 수업 기록(Held) 저장 뒤 홈 To-do 에 '첫 수업 후 확인'이 바로 보이게 같이 다시 읽음 (Work QA 11/7: 새로고침해야 보이던 오류)
      void refreshFollowups();
    } catch (e) {
      setErr(e instanceof Error ? e.message : 'Could not load. Please try again.');
    } finally {
      setLoading(false);
    }
  }
  async function goWeek(off: number) {
    setOffset(off);
    await reload(off);
  }
  // Schedule 수업 창 [Class Record ›] → 그 수업이 있는 주로 가서 그 줄을 펼침 (H26(49) ③)
  const [focus, setFocus] = useState<string | null>(null);
  async function openInRecord(l: TutorLesson) {
    const n = new Date();
    const off = Math.round((Date.parse(weekOf(l.startsAt, tz, 0).from) - Date.parse(weekOf(n, tz, 0).from)) / (7 * 86400000));
    setStudent('');
    setFocus(l.id);
    setTab('record');
    await goWeek(off);
  }
  const loadLessons = useCallback(async (kstFrom: string, kstTo: string) => (await actions.load(kstFrom, kstTo)).lessons, [actions]);

  const byId = new Map(screen.lessons.map((l) => [l.id, l]));
  const toRecord = [
    ...screen.toRecord.map((id) => byId.get(id)).filter((l): l is TutorLesson => !!l),
    ...recordedHere.filter((l) => !screen.toRecord.includes(l.id)).map((l) => byId.get(l.id) ?? l),
  ].sort((a, b) => +a.startsAt - +b.startsAt);
  // 할 일 게시판 (학생 화면과 같은 모양, 대표 10/29): 아직 안 한 것만 세고, 누르면 그 칸으로
  const [panel, setPanel] = useState<'cover' | 'makeup' | 'followup' | null>(null);
  // 학생 프로필 창 (4300): 열어도 보던 메뉴·주·고른 학생은 그대로, 닫으면 돌아옴
  const [profileOf, setProfileOf] = useState<string | null>(null);
  const openProfile = actions.profile ? setProfileOf : null;
  // 첫 수업 후 To-do (4600): 학생별 First Lesson Follow-up 창. 목록은 DB 가 저장값으로 판정
  const [followupOf, setFollowupOf] = useState<string | null>(null);
  const [followups, setFollowups] = useState<FollowupTodo[]>([]);
  const refreshFollowups = useCallback(async () => {
    if (!actions.followups) return;
    try { setFollowups(await actions.followups()); } catch { /* 옛 DB 또는 일시 오류: To-do 칸만 비움 */ }
  }, [actions]);
  useEffect(() => { void refreshFollowups(); }, [refreshFollowups]);
  // 취소된 수업 (학생이 취소한 앞으로의 수업): 화면을 다시 읽을 때마다 새로 읽음. 그 수업 시간이 지나면 저절로 빠짐
  const [canceled, setCanceled] = useState<TutorCanceled[]>([]);
  const [showAllCanceled, setShowAllCanceled] = useState(false);
  useEffect(() => {
    if (!actions.canceled) return;
    let live = true;
    actions.canceled().then((r) => { if (live) setCanceled(r.filter((c) => c.startsAt > now).sort((a, b) => +a.startsAt - +b.startsAt)); }).catch(() => { /* 옛 DB 또는 일시 오류: 이 칸만 비움 */ });
    return () => { live = false; };
  }, [actions, screen, now]);
  const followupOfStudent = (id?: string) => (id ? followups.find((f) => f.studentId === id) : undefined);
  const todoCount = [screen.toRecord.length, screen.covers.length, screen.makeups.length, followups.length].filter((n) => n > 0).length;
  const makeups = [...screen.makeups, ...answeredHere.filter((m) => !screen.makeups.some((x) => x.id === m.id))];
  const days = student
    ? daysOf((allLessons ?? screen.lessons).filter((l) => l.student === student), tz, { from: '1900-01-01', to: '2999-12-31' })
    : daysOf(screen.lessons, tz, week);
  // Students 메뉴: 처음 열 때 한 번 읽음 (담당 학생만 — DB 가 정함, 4300)
  const [students, setStudents] = useState<TutorStudentRow[] | null>(null);
  const [studentsErr, setStudentsErr] = useState('');
  useEffect(() => {
    if (tab !== 'students' || students || !actions.students) return;
    actions.students().then(setStudents).catch((e) => setStudentsErr(e instanceof Error ? e.message : 'Could not load.'));
  }, [tab, students, actions]);

  const today = localDate(now, tz);
  const todayLessons = screen.lessons.filter((l) => localDate(l.startsAt, tz) === today).sort((a, b) => +a.startsAt - +b.startsAt);
  const nextLesson = screen.lessons.filter((l) => l.state === 'scheduled' && l.startsAt > now && localDate(l.startsAt, tz) !== today).sort((a, b) => +a.startsAt - +b.startsAt)[0];

  const logo = (
    <span className="inline-flex items-center gap-1.5">
      <img src="/images/brand/edge-english-logo.svg" alt="Edge English" className="h-[22px] w-auto" />
      <span className="rounded-[6px] bg-[#27230e] px-[7px] py-[3px] text-[12px] font-extrabold text-[#ffd401]">Tutor</span>
    </span>
  );
  // 운영자 보기: 로고를 누르면 운영자 화면으로 (11/3 대표, 학생 화면과 같게)
  const brand = adminBar ? <a href="/lms/admin" aria-label="운영자 화면으로" className="inline-flex">{logo}</a> : logo;
  // Availability 에 저장 안 한 변경이 있으면 메뉴를 바꾸기 전에 확인 (QA UX: '1 change not saved' 상태에서 Home 누르면 사라짐)
  const hoursDirty = useRef(false);
  const goTab = (key: Tab) => {
    if (tab === 'hours' && key !== 'hours' && hoursDirty.current && !window.confirm('You have unsaved changes in Availability. Leave without saving?')) return;
    setTab(key);
  };
  const tr = t;
  const tabBtn = (t: (typeof TABS)[number], mobile: boolean) => (
    <button key={t.key} type="button" onClick={() => goTab(t.key)} aria-current={tab === t.key ? 'page' : undefined}
      className={mobile
        ? `flex min-h-[48px] flex-col items-center justify-center gap-0.5 text-[11px] ${tab === t.key ? 'font-bold text-[#5b3df0]' : 'text-[#55526a]'}`
        : `flex min-h-[46px] items-center gap-2.5 rounded-[12px] px-3 text-left text-[15px] ${tab === t.key ? 'bg-[#efeaff] font-bold text-[#3a22b0]' : 'text-[#1d1b2b] hover:bg-[#f3f1f8]'}`}>
      <Icon d={t.icon} />
      {TAB_KO[t.key] ? tr(t.label, TAB_KO[t.key]) : t.label}
      {!mobile && t.key === 'record' && screen.toRecord.length > 0 && <span className="ml-auto rounded-full bg-[#f0a33a] px-2 py-0.5 text-[12px] font-bold text-white">{screen.toRecord.length}</span>}
      {mobile && t.key === 'record' && screen.toRecord.length > 0 && <span className="sr-only">{screen.toRecord.length} to record</span>}
    </button>
  );
  const weekNav = (
    <div className="mb-2">
      <div className="flex items-center gap-2">
        <button type="button" aria-label="Previous week" disabled={loading} onClick={() => goWeek(offset - 1)} className={`${btnSub} shrink-0 px-3`}>‹</button>
        <p aria-live="polite" className="min-w-0 flex-1 text-center text-[14.5px] font-semibold text-[#1d1b2b]">{dayLabel(week.from)} – {dayLabel(week.to)}</p>
        <button type="button" aria-label="Next week" disabled={loading} onClick={() => goWeek(offset + 1)} className={`${btnSub} shrink-0 px-3`}>›</button>
      </div>
      {offset !== 0 && (
        <div className="text-center">
          <button type="button" disabled={loading} onClick={() => goWeek(0)} className="min-h-[36px] px-2 text-[13.5px] font-semibold text-[#5b3fe0] underline">Back to this week</button>
        </div>
      )}
    </div>
  );
  const table = (
    <>
      {days.length === 0 && <p className={`${card} text-[15px] text-[#6b6880]`}>No classes</p>}
      {days.length > 0 && (
        <div className="overflow-hidden rounded-[12px] border border-[#e6e3ef] bg-white">
          <div className="grid grid-cols-[76px_minmax(0,1fr)_auto] gap-2 border-b-2 border-[#5b3fe0] bg-[#efebff] px-3 py-2 text-[13px] font-bold leading-tight text-[#2b1c7a] lg:hidden">
            <span>{tzTimeLabel(tz)}</span><span>Student · Class Status</span><span className="sr-only">Details</span>
          </div>
          <div className={`hidden ${cols(kst, paidCol)} border-b-2 border-[#5b3fe0] bg-[#efebff] px-1 text-[13px] font-bold leading-tight text-[#2b1c7a] lg:grid [&>*]:break-words [&>*]:flex [&>*]:min-w-0 [&>*]:items-center [&>*]:border-l [&>*]:border-[#e6e3ef] [&>*]:px-2 [&>*:first-child]:border-l-0 [&>*]:py-2`}>
            <span>{tzTimeLabel(tz)}</span>{kst && <span>{KOREA_TIME}</span>}<span>Student</span><span>Class Count</span><span>Min</span><span>Class Type</span><span>Class Status</span>{paidCol && <span>Paid</span>}<span>Covered Topics</span>
          </div>
          {days.map((d) => (
            <div key={d.date}>
              <h3 className="border-b border-[#e6e3ef] bg-[#f7f6fb] px-3 py-1.5 text-[13px] font-bold text-[#1d1b2b]">{dayLabel(d.date)}{d.date === today ? ' · Today' : ''}</h3>
              {d.lessons.map((l) => (
                <ListRow key={l.id} focus={focus === l.id} lesson={l} tz={tz} now={now} kst={kst} paidCol={paidCol} meetUrl={screen.tutor.meetUrl} actions={actions} admin={!!adminBar}
                  onSaved={async () => { await reload(); if (student) await refreshAll(); }} />
              ))}
            </div>
          ))}
        </div>
      )}
    </>
  );
  const viewControls = (
    <>
      <div className="mb-2 flex flex-wrap items-center justify-end gap-2">
        {kstOn !== null && (
          <label className="flex min-h-[44px] items-center gap-1.5 text-[14px] font-semibold text-[#55526a]">
            <input type="checkbox" checked={kstOn} onChange={(e) => setKst(e.target.checked)} className="h-[18px] w-[18px] accent-[#5b3fe0]" />
            {KOREA_TIME}
          </label>
        )}
        <label className="flex min-h-[44px] items-center gap-1.5 text-[14px] font-semibold text-[#55526a]">
          <input type="checkbox" checked={paidCol} onChange={(e) => setPaidCol(e.target.checked)} className="h-[18px] w-[18px] accent-[#5b3fe0]" />
          Paid
        </label>
      </div>
      <select
        aria-label="Student"
        value={student}
        onFocus={() => void loadAll()}
        onChange={async (e) => {
          const v = e.target.value;
          if (v) await loadAll();
          setStudent(v);
        }}
        className="mb-2 min-h-[44px] w-full rounded-[10px] border border-[#e6e3ef] bg-white px-3 text-[15px] text-[#1d1b2b]"
      >
        <option value="">All students · by week</option>
        {studentNames.map((n) => (
          <option key={n} value={n}>{n} · all classes</option>
        ))}
      </select>
      {!student && weekNav}
    </>
  );

  return (
    <ProfileCtx.Provider value={openProfile}>
    <div className="mx-auto min-h-dvh max-w-[1280px] font-sans text-[#1d1b2b] lg:flex lg:gap-6 lg:px-6 lg:py-6">
      {/* PC: 왼쪽 고정 메뉴 (학생 LMS 와 같은 자리·모양) */}
      <nav aria-label="Menu" className="hidden w-[220px] shrink-0 flex-col gap-1 lg:flex">
        <div className="px-3 pb-4 pt-1">{brand}</div>
        {TABS.map((t) => tabBtn(t, false))}
        <div className="px-3 pt-5 text-[13px] text-[#55526a]">
          <b className="block text-[14px] text-[#1d1b2b]">{screen.tutor.name}</b>
        </div>
        {onLogout && <button type="button" onClick={onLogout} className="mx-3 mt-1 min-h-[36px] text-left text-[13px] text-[#55526a] underline">{t('Sign out', '로그아웃')}</button>}
      </nav>

      <div className="min-w-0 flex-1 px-4 pb-24 lg:px-0 lg:pb-0">
        {adminBar && <div className="pt-3 lg:pt-0">{adminBar}</div>}
        <header className="flex items-center justify-between pb-3 pt-[14px] lg:hidden">
          {brand}
          {onLogout && <button type="button" onClick={onLogout} className="min-h-[36px] text-[13px] text-[#55526a] underline">Sign out</button>}
        </header>
        {profileOf && actions.profile && <StudentProfile studentId={profileOf} actions={actions.profile} now={now} onClose={() => setProfileOf(null)}
          backLabel={tab === 'students' ? t('Back to students', '학생 목록으로') : tab === 'record' ? t('Back to Class Record', 'Class Record 로') : tab === 'schedule' ? t('Back to schedule', '일정으로') : t('Back', '뒤로')}
          followupPending={followupOfStudent(profileOf)?.pending ?? null}
          onFollowup={actions.followupSave ? () => { const id = profileOf; setProfileOf(null); setFollowupOf(id); } : undefined} />}
        {followupOf && actions.profile && actions.followupSave && (
          <FirstLessonFollowup studentId={followupOf} actions={actions.profile} save={actions.followupSave} now={now} onClose={() => setFollowupOf(null)} onChanged={() => void refreshFollowups()}
            backLabel={tab === 'students' ? t('Back to students', '학생 목록으로') : t('Back', '뒤로')} />
        )}
        {err && <p className="mb-3 rounded-[10px] bg-[#fdecea] px-3 py-2 text-[14px] text-[#b3261e]">{err}</p>}

        {tab === 'home' && (
          <div className="grid gap-4 lg:max-w-[720px]">
            <header>
              <h1 className="text-[22px] font-bold text-[#1d1b2b]">{t('Hi', '안녕하세요')}, {screen.tutor.name}</h1>
              <p className="text-[14px] text-[#6b6880]"><Rich text={enBoth(now, tz)} /></p>
              {screen.tutor.meetUrl && (
                <a href={screen.tutor.meetUrl} target="_blank" rel="noreferrer" className={`${btnMain} mt-3 inline-flex items-center`}>Classroom (Google Meet)</a>
              )}
            </header>

            {/* 할 일 게시판은 0건이어도 늘 보임 (대표 11/8) */}
            <section aria-label="To do" className="overflow-hidden rounded-[18px] border-2 border-[#f0a33a] bg-white">
              <h2 className="flex items-center gap-2 bg-[#fff4d6] px-4 py-2.5 text-[16px] font-bold text-[#5c3b00]">
                {t('To do', '할 일')} <span className="rounded-full bg-[#f0a33a] px-2 py-0.5 text-[13px] text-white">{todoCount}</span>
              </h2>
              <div className="divide-y divide-[#f3e6c4]">
                {todoCount === 0 && <p className="px-4 py-3.5 text-[15px] text-[#1f7a4d]">✓ {t('Nothing to do right now', '지금 할 일이 없어요')}</p>}
                {screen.toRecord.length > 0 && <TodoBar n={screen.toRecord.length} text={t('Classes to record', '기록할 수업')} onClick={() => setTab('record')} />}
                  {screen.covers.length > 0 && <TodoBar n={screen.covers.length} text={t('Cover requests', '대체 수업 요청')} onClick={() => setPanel('cover')} />}
                  {screen.makeups.length > 0 && <TodoBar n={screen.makeups.length} text={t('Make-up requests', '보강 요청')} onClick={() => setPanel('makeup')} />}
                {followups.length > 0 && <TodoBar n={followups.length} text={t('First lesson follow-up (level · goals · class style · class notes)', '첫 수업 후 확인 (레벨 · 목표 · 수업 방식 · 수업 노트)')} onClick={() => setPanel('followup')} />}
              </div>
            </section>

            {/* 알림 게시판: 할 일 바로 아래, 같은 모양. 0건이어도 늘 보임 (대표 11/8) */}
            <section aria-label="Updates" className="overflow-hidden rounded-[18px] border-2 border-[#c9c2f2] bg-white">
              <h2 className="flex items-center gap-2 bg-[#efecfd] px-4 py-2.5 text-[16px] font-bold text-[#3b2a9a]">
                {t('Updates', '일정 변경')} <span className="rounded-full bg-[#5b3fe0] px-2 py-0.5 text-[13px] text-white">{canceled.length > 0 ? 1 : 0}</span>
              </h2>
              {canceled.length === 0 && <p className="px-4 py-3.5 text-[15px] text-[#1f7a4d]">✓ {t('No updates', '변경 사항이 없어요')}</p>}
              {canceled.length > 0 && (
                <div className="px-4 py-3">
                  <p className="mb-1 text-[15px] font-semibold text-[#1d1b2b]">{t('Canceled classes', '취소된 수업')}</p>
                  <ul className="divide-y divide-[#f0eef5]">
                    {(showAllCanceled ? canceled : canceled.slice(0, 3)).map((c) => (
                      <li key={c.id} className="py-2">
                        <StudentName id={c.studentId} name={c.student} className="inline text-[15px] font-semibold" />
                        {c.classStatus === 'Student canceled late' && <span className="ml-1.5 text-[12.5px] font-semibold text-[#b3261e]">{t('late', '늦은 취소')}</span>}
                        <span className="block text-[14px] text-[#55526a]"><Rich text={whenFull(c.startsAt, tz)} /></span>
                      </li>
                    ))}
                  </ul>
                  {canceled.length > 3 && (
                    <button type="button" onClick={() => setShowAllCanceled((v) => !v)} className="mt-1 min-h-[36px] text-[13.5px] font-semibold text-[#5b3fe0] underline">
                      {showAllCanceled ? t('Show less', '접기') : `+ ${canceled.length - 3} ${t('more', '건 더보기')}`}
                    </button>
                  )}
                </div>
              )}
            </section>

            <section aria-label="Today" className={card}>
              <h2 className="mb-2 text-[16px] font-bold text-[#1d1b2b]">{t('Today’s classes', '오늘 수업')} <span className="text-[#6b6880]">{todayLessons.length || ''}</span></h2>
              {todayLessons.length === 0 && <p className="text-[14.5px] text-[#6b6880]">{t('No classes today.', '오늘은 수업이 없어요.')}</p>}
              <div className="divide-y divide-[#f0eef5]">
                {todayLessons.map((l) => <TodayRow key={l.id} lesson={l} tz={tz} now={now} onRecord={() => setTab('record')} />)}
              </div>
              {nextLesson && <p className="mt-2 text-[13.5px] text-[#6b6880]">{t('Next class', '다음 수업')}: <Rich text={whenFull(nextLesson.startsAt, tz)} /> · {nextLesson.student}</p>}
              <button type="button" onClick={() => setTab('schedule')} className="mt-2 min-h-[36px] text-[13.5px] font-semibold text-[#5b3fe0] underline">{t('All classes', '전체 수업')} ›</button>
            </section>
          </div>
        )}


        {tab === 'record' && (
          <section aria-label="Class Record">
            <h1 className="mb-1 text-[20px] font-bold text-[#1d1b2b]">Class Record</h1>
            <p className="mb-3 text-[13.5px] text-[#6b6880]">Your classes by week · {tzHeader(tz)}. Record each class after it ends; tap a past class to edit.</p>
            {toRecord.length > 0 && (
              <section aria-label="Classes to record" className="mb-5 grid gap-3 lg:max-w-[760px]">
                <h2 className="text-[16px] font-bold text-[#b3261e]">
                  Classes to record {screen.toRecord.length > 0 && <span className="rounded-full bg-[#f0a33a] px-2 py-0.5 text-[13px] text-white">{screen.toRecord.length}</span>}
                </h2>
                {toRecord.map((l) => (
                  <div key={l.id} className={`${card} border-[#f0a33a]`}>
                    <LessonHead lesson={l} tz={tz} now={now} />
                    <RecordForm key={`${l.id}-${l.state}`} lesson={l} now={now} actions={actions} startEditing={screen.toRecord.includes(l.id)} admin={!!adminBar}
                      onSaved={async (saved) => {
                        setRecordedHere((x) => [...x.filter((y) => y.id !== saved.id), saved]);
                        await reload();
                      }} />
                  </div>
                ))}
              </section>
            )}
            {viewControls}
            {table}
          </section>
        )}

        {tab === 'students' && (
          <section aria-label="Students">
            <h1 className="mb-1 text-[20px] font-bold text-[#1d1b2b]">{t('Students', '학생')}</h1>
            <p className="mb-3 text-[13.5px] text-[#6b6880]">{t('Your students. Tap a name to see their profile, preferences and recent topics.', '담당 학생입니다. 이름을 누르면 프로필·선호·최근 수업 내용을 볼 수 있어요.')}</p>
            {!actions.students && <p className={`${card} text-[14.5px] text-[#6b6880]`}>{t('Student list is not available here.', '여기서는 학생 목록을 볼 수 없어요.')}</p>}
            {studentsErr && <p className="mb-3 rounded-[10px] bg-[#fdecea] px-3 py-2 text-[14px] text-[#b3261e]">{studentsErr}</p>}
            {actions.students && !students && !studentsErr && <p className="text-[15px] text-[#6b6880]">Loading…</p>}
            {students && students.length === 0 && <p className={`${card} text-[14.5px] text-[#6b6880]`}>{t('No students assigned to you yet.', '아직 담당 학생이 없어요.')}</p>}
            {students && students.length > 0 && (
              <ul className="overflow-hidden rounded-[12px] border border-[#e6e3ef] bg-white">
                {[...students].sort((a, b) => a.name.localeCompare(b.name)).map((st) => (
                  <li key={st.id} className="border-b border-[#e6e3ef] last:border-b-0">
                    <button type="button" disabled={!openProfile} onClick={() => openProfile?.(st.id)}
                      className="flex min-h-[56px] w-full items-center gap-3 px-4 py-2 text-left hover:bg-[#f7f6fb]">
                      <span className="min-w-0 flex-1">
                        <span className="block text-[15.5px] font-semibold text-[#1d1b2b]">{st.name}</span>
                        <span className="block text-[13px] text-[#6b6880]">
                          {[st.level, st.classType, st.timezone ? tzTimeLabel(st.timezone) : null].filter(Boolean).join(' · ') || t('Profile', '프로필')}
                        </span>
                        {followupOfStudent(st.id) && (
                          <span className="mt-0.5 inline-block rounded-full bg-[#fff4d6] px-2 py-0.5 text-[12px] font-bold text-[#8a5300]">
                            {t('First lesson follow-up', '첫 수업 후 확인')} · {followupOfStudent(st.id)!.pending} {t('left', '남음')}
                          </span>
                        )}
                      </span>
                      <span className="text-[13px] font-semibold text-[#5b3fe0]">{t('Profile', '프로필')} ›</span>
                    </button>
                  </li>
                ))}
              </ul>
            )}
          </section>
        )}

        {tab === 'schedule' && (
          <TutorSchedule actions={actions.schedule} tz={tz} now={now} openProfile={openProfile} onRecord={openInRecord}
            loadLessons={loadLessons} onSaved={() => reload()} />
        )}

        {tab === 'hours' && <TutorHours actions={actions.hours} onClose={() => setTab('home')} onSchedule={() => goTab('schedule')} inline onDirty={(d) => { hoursDirty.current = d; }} onSaved={() => reload()} />}

        {panel === 'cover' && (
          <Sheet onClose={() => setPanel(null)}>
            <h2 className="mb-2 pr-10 text-[17px] font-bold text-[#1d1b2b]">Cover requests</h2>
            <div className="grid gap-3">
              {groupCovers(screen.covers).map((g) => (
                <CoverCard key={g.map((c) => c.id).join()} covers={g} tz={tz} actions={actions} onSent={() => reload()} />
              ))}
              {screen.covers.length === 0 && <p className="text-[15px] text-[#1f7a4d]">✓ Sent</p>}
            </div>
          </Sheet>
        )}

        {panel === 'followup' && (
          <Sheet onClose={() => setPanel(null)}>
            <h2 className="mb-1 pr-10 text-[17px] font-bold text-[#1d1b2b]">{t('First lesson follow-up', '첫 수업 후 확인')}</h2>
            <p className="mb-3 text-[13px] text-[#6b6880]">{t('English level · Wants to improve · Class style · Class notes (Google Docs)', '영어 레벨 · 개선 목표 · 수업 방식 · 수업 노트 (Google Docs)')}</p>
            <div className="grid gap-2">
              {followups.length === 0 && <p className="text-[15px] text-[#1f7a4d]">✓ {t('All done', '모두 완료')}</p>}
              {followups.map((f) => (
                <button key={f.studentId} type="button" onClick={() => { setPanel(null); setFollowupOf(f.studentId); }} className={`${card} flex items-center gap-3 text-left`}>
                  <span className="min-w-0 flex-1">
                    <b className="block text-[15.5px] text-[#1d1b2b]">{f.student}</b>
                    <span className="block text-[13px] text-[#6b6880]">
                      {f.firstLessonAt ? `${t('First lesson', '첫 수업')} ${whenText(f.firstLessonAt, tz)}` : ''} · {f.pending} {t('of 4 left', '/ 4 남음')}
                      {!f.done.level ? ` · ${t('Level', '레벨')}` : ''}{!f.done.improve ? ` · ${t('Wants to improve', '개선 목표')}` : ''}{!f.done.style ? ` · ${t('Class style', '수업 방식')}` : ''}{!f.done.docs ? ` · ${t('Class notes', '수업 노트')}` : ''}
                    </span>
                  </span>
                  <span className="whitespace-nowrap rounded-[10px] bg-[#5b3fe0] px-3 py-1.5 text-[13px] font-bold text-white">{t('Open', '열기')} ›</span>
                </button>
              ))}
            </div>
          </Sheet>
        )}

        {panel === 'makeup' && (
          <Sheet onClose={() => setPanel(null)}>
            <h2 className="mb-2 pr-10 text-[17px] font-bold text-[#1d1b2b]">Make-up requests</h2>
            <div className="grid gap-3">
              {makeups.map((m) => (
                <MakeupCard key={m.id} m={m} tz={tz} actions={actions} closed={!screen.makeups.some((x) => x.id === m.id)}
                  onSent={async () => {
                    setAnsweredHere((x) => [...x.filter((y) => y.id !== m.id), m]);
                    await reload();
                  }} />
              ))}
            </div>
          </Sheet>
        )}
      </div>

      {/* 휴대폰: 아래 고정 메뉴 */}
      <nav aria-label="Menu" className="fixed inset-x-0 bottom-0 z-30 grid grid-cols-5 border-t border-[#e6e3ef] bg-white pb-3 pt-1.5 lg:hidden">
        {TABS.map((t) => tabBtn(t, true))}
      </nav>
    </div>
    </ProfileCtx.Provider>
  );
}

/** Home 의 오늘 수업 한 줄 */
function TodayRow({ lesson: l, tz, now, onRecord }: { lesson: TutorLesson; tz: string; now: Date; onRecord: () => void }) {
  const phase = phaseOf(l, now);
  const tag = kindTag(l);
  const st = statusText(l, now);
  return (
    <div className={`flex items-center gap-3 py-2 ${phase === 'canceled' ? 'text-[#8a879c]' : ''}`}>
      {/* 시각마다 그 옆에 어느 시간대인지 바로 적음 (현지 + 한국) */}
      <span className="min-w-0 flex-1">
        <span className="block text-[14.5px] tabular-nums"><Rich text={rangeFullNoDay(l, tz)} /></span>
        <StudentName id={l.studentId} name={l.student} className={`mt-0.5 block truncate text-[15px] font-semibold ${phase === 'canceled' ? 'line-through' : ''}`} />
        <span className="block text-[12.5px] text-[#6b6880]">{minutesOf(l)} min{tag ? ` · ${tag}` : ''}{l.count ? ` · Class ${l.count.n}/${l.count.total}` : ''}</span>
      </span>
      {phase === 'to_record'
        ? <button type="button" onClick={onRecord} className="min-h-[36px] rounded-[10px] bg-[#5b3fe0] px-3 text-[13px] font-bold text-white">Record</button>
        : <span className={`text-[13px] font-semibold ${phase === 'recorded' ? 'text-[#1f7a4d]' : 'text-[#6b6880]'}`}>{phase === 'recorded' ? `✓ ${st}${lateText(l.late)}` : st}</span>}
    </div>
  );
}

// 할 일은 화면에 펼쳐 두지 않고 누르면 창으로 (대표 10/29: 할 일이 많아도 Class Record 표가 아래로 밀리지 않게)
// 보내지 않은 답·저장 안 한 기록 보호 (대표 10/30): 창을 닫거나 페이지를 떠날 때 확인 (My hours와 같은 'Discard changes?')
const DirtyCtx = createContext<((id: string, dirty: boolean) => void) | null>(null);

function useDirty(id: string, dirty: boolean) {
  const mark = useContext(DirtyCtx);
  useEffect(() => {
    mark?.(id, dirty);
    if (!dirty) return;
    const warn = (e: BeforeUnloadEvent) => e.preventDefault();
    window.addEventListener('beforeunload', warn);
    return () => {
      mark?.(id, false);
      window.removeEventListener('beforeunload', warn);
    };
  }, [mark, id, dirty]);
}

/** 창 안에서 고치는 중인 칸 목록 (닫기 전 확인용) */
function useDirtyList() {
  const dirty = useRef(new Set<string>());
  const [mark] = useState(() => (id: string, on: boolean) => {
    if (on) dirty.current.add(id);
    else dirty.current.delete(id);
  });
  return [dirty, mark] as const;
}

function Sheet({ onClose, children }: { onClose: () => void; children: ReactNode }) {
  const [dirty, mark] = useDirtyList();
  const close = () => {
    if (dirty.current.size > 0 && !window.confirm('Discard changes?')) return;
    onClose();
  };
  return (
    <div className="fixed inset-0 z-40 flex items-end justify-center bg-black/40 lg:items-center" onClick={close}>
      <div role="dialog" aria-modal="true" onClick={(e) => e.stopPropagation()}
        className="relative max-h-[90vh] w-full max-w-[640px] overflow-y-auto rounded-t-[20px] bg-[#f6f5fa] p-4 pb-8 lg:rounded-[20px]">
        <button type="button" aria-label="Close" onClick={close}
          className="absolute right-3 top-3 flex h-[40px] w-[40px] items-center justify-center rounded-full bg-white text-[18px] text-[#1d1b2b]">✕</button>
        <DirtyCtx.Provider value={mark}>{children}</DirtyCtx.Provider>
      </div>
    </div>
  );
}

function TodoBar({ n, text, onClick }: { n: number; text: string; onClick: () => void }) {
  const t = useT();
  return (
    <button type="button" onClick={onClick}
      className="flex min-h-[54px] w-full items-center gap-3 px-4 py-3 text-left">
      <span className="flex-1 text-[15px] font-semibold leading-snug text-[#1d1b2b]">{text}</span>
      <span className="text-[13px] text-[#8a5300]">{n}</span>
      <span className="whitespace-nowrap rounded-[10px] bg-[#5b3fe0] px-3 py-1.5 text-[13px] font-bold text-white">{t('Open', '열기')} ›</span>
    </button>
  );
}

function LessonHead({ lesson: l, tz, now }: { lesson: TutorLesson; tz: string; now: Date }) {
  const tag = kindTag(l);
  return (
    <div>
      <div className="flex flex-wrap items-baseline gap-x-2">
        <StudentName id={l.studentId} name={l.student} className="text-[16px] font-bold text-[#1d1b2b]" />
        {tag && <span className="rounded-[6px] bg-[#efebff] px-1.5 text-[12.5px] font-semibold text-[#5b3fe0]">{tag}</span>}
        {l.count && <span className="text-[13px] text-[#6b6880]">Class {l.count.n}/{l.count.total}</span>}
      </div>
      <p className="text-[14.5px] text-[#1d1b2b]">
        <Rich text={rangeFull(l, tz)} /> · {minutesOf(l)} min
      </p>
      {l.makeupOf && <p className="text-[13px] text-[#6b6880]">Make-up for <Rich text={whenFull(l.makeupOf, tz)} /></p>}
      {l.compensationOf && <p className="text-[13px] text-[#6b6880]">Compensation for <Rich text={whenFull(l.compensationOf, tz)} /> (tutor no-show)</p>}
      {phaseOf(l, now) === 'canceled' && <p className="text-[13px] font-semibold text-[#b3261e]">{statusText(l, now)}</p>}
    </div>
  );
}

/** PC 표 칸 (KST 칸은 강사가 끌 수 있음) */
// 시간대 열은 긴 도시 이름('Ho Chi Minh Time')도 두 줄 안에 들어가게 108px + 줄바꿈 (11/3 대표: 열 제목이 Student와 겹침)
const cols = (kst: boolean, paid: boolean) => kst
  ? (paid ? 'lg:grid-cols-[108px_108px_minmax(120px,1.1fr)_96px_48px_104px_minmax(120px,1fr)_56px_minmax(180px,1.8fr)]'
    : 'lg:grid-cols-[108px_108px_minmax(120px,1.1fr)_96px_48px_104px_minmax(120px,1fr)_minmax(180px,1.8fr)]')
  : (paid ? 'lg:grid-cols-[108px_minmax(120px,1.1fr)_96px_48px_104px_minmax(120px,1fr)_56px_minmax(180px,1.8fr)]'
    : 'lg:grid-cols-[108px_minmax(120px,1.1fr)_96px_48px_104px_minmax(120px,1fr)_minmax(180px,1.8fr)]');


/** 일정 한 줄 (Class Record 시트처럼). 누르면 그 아래에 기록칸·링크가 펼쳐짐. 휴대폰은 칸을 줄여 한 줄 */
function ListRow({ lesson: l, tz, now, kst, paidCol, meetUrl, actions, onSaved, admin, focus = false }: {
  focus?: boolean;
  lesson: TutorLesson; tz: string; now: Date; kst: boolean; paidCol: boolean; meetUrl: string | null; actions: TutorActions; onSaved: () => Promise<void>; admin: boolean;
}) {
  const [open, setOpen] = useState(false);
  const [dirty, mark] = useDirtyList();
  const rowRef = useRef<HTMLDivElement>(null);
  const phase = phaseOf(l, now);
  const status = statusText(l, now);
  const k = kst ? kstText(l.startsAt, tz) : null;
  const time = ampmEn(formatInZone(l.startsAt, tz).time);
  const count = l.count ? `${l.count.n}/${l.count.total}` : '—';
  // 펼쳐도 보일 것이 없는 줄은 못 누름 (대표 10/31: 대체수업을 펼쳐도 빈 칸)
  const isMakeup = l.kind === 'makeup' || l.kind === 'migrated_makeup';
  const recordable = canRecord(l, now);
  const canOpen = (phase !== 'canceled' || recordable) && !!(l.noteUrl || recordable || l.remarks || l.makeupOf || l.locked || (phase === 'upcoming' && isMakeup) || l.studentId);
  const toggle = () => {
    if (open && dirty.current.size > 0 && !window.confirm('Discard changes?')) return;
    setOpen(!open);
  };
  // Schedule 에서 [Class Record ›] 로 온 수업: 펼치고 그 줄로 스크롤
  useEffect(() => {
    if (!focus) return;
    if (canOpen) setOpen(true);
    rowRef.current?.scrollIntoView({ block: 'center' });
  }, [focus]); // eslint-disable-line react-hooks/exhaustive-deps
  const stColor = phase === 'to_record' ? 'text-[#b3261e]' : phase === 'recorded' ? 'text-[#1f7a4d]' : 'text-[#6b6880]';
  const stText = phase === 'recorded' ? `✓ ${status}${lateText(l.late)}` : status;
  // 페이 대상 Y/N (상태 규칙 tutorPaid + 보상수업은 무급, R-19: 공통 규칙 tutorPaidFor). 기록 전은 빈칸, 정산 끝난 수업은 'Y ✓'
  const paidRule = tutorPaidFor(l.kind, l.classStatus);
  const paid = paidRule === null ? '' : paidRule ? (l.locked ? 'Y ✓' : 'Y') : 'N';
  const name = <span className={phase === 'canceled' ? 'line-through' : ''}>{l.student}</span>;
  const remarksChip = l.remarks ? <span className="ml-1 inline-block rounded-[6px] border border-[#e6e3ef] px-1 text-[11.5px] font-semibold text-[#6b6880]">Remarks</span> : null;
  const openProfile = useContext(ProfileCtx);
  const links = (
    <>
      {l.studentId && openProfile && <button type="button" onClick={() => openProfile(l.studentId!)} className={`${btnSub} inline-flex items-center text-[14px]`}>Student profile</button>}
      {l.noteUrl && <a href={l.noteUrl} target="_blank" rel="noreferrer" className={`${btnSub} inline-flex items-center text-[14px]`}>Class notes</a>}
      {phase === 'upcoming' && (l.kind === 'makeup' || l.kind === 'migrated_makeup') && (() => {
        const ev = { title: `Edge English make-up · ${l.student}`, start: l.startsAt, end: l.endsAt, details: meetUrl };
        return (
          <>
            <a href={googleCalendarUrl(ev)} target="_blank" rel="noreferrer" className={`${btnSub} inline-flex items-center text-[14px]`}>Google Calendar</a>
            <a href={icsUrl(ev)} className={`${btnSub} inline-flex items-center text-[14px]`}>Apple / Samsung Calendar</a>
          </>
        );
      })()}
    </>
  );
  return (
    <div ref={rowRef} className={`border-b border-[#e6e3ef] last:border-b-0 ${focus ? 'ring-2 ring-inset ring-[#5b3fe0]' : ''} ${phase === 'canceled' ? 'text-[#8a879c]' : 'text-[#1d1b2b]'}`}>
      {/* 줄 전체(이름 빼고)를 누르면 펼침. 이름은 프로필로 (QA-06: 버튼 안에 버튼 없이 — 바깥은 div, 펼치기 전용 버튼(›)은 키보드용) */}
      <div onClick={canOpen ? toggle : undefined}
        className={`w-full px-3 py-2 text-left lg:px-1 ${canOpen ? 'cursor-pointer' : ''} ${open ? 'bg-[#f3f1f8]' : canOpen ? 'hover:bg-[#f7f6fb]' : ''}`}>
        {/* 휴대폰: 출결 상태는 이름 아래 줄 (QA-02: 긴 상태가 이름 폭을 빼앗지 않게) */}
        <div className="grid grid-cols-[76px_minmax(0,1fr)_28px] items-start gap-2 lg:hidden">
          <span className="text-[14px] font-bold tabular-nums">
            {time}{k && <span className="block text-[11.5px] font-medium text-[#6b6880]"><Rich text={k} /></span>}
          </span>
          <span className="min-w-0">
            <StudentName id={l.studentId} name={name} className="block max-w-full truncate text-[14.5px] font-semibold" />
            <span className="block text-[12.5px] text-[#6b6880]">
              {l.count ? `Class ${count} · ` : ''}{minutesOf(l)} min{kindTag(l) ? ` · ${kindTag(l)}` : ''}{paidCol && paid ? ` · Paid ${paid}` : ''}
            </span>
            <span className={`block text-[13px] font-semibold ${stColor}`}>{stText}{remarksChip}</span>
            {l.topics && <span className="block truncate text-[12.5px]">{l.topics}</span>}
          </span>
          {canOpen ? <button type="button" aria-expanded={open} aria-label={open ? 'Hide details' : 'Show details'} onClick={(e) => { e.stopPropagation(); toggle(); }}
            className="flex h-[28px] w-[28px] items-center justify-center rounded-full text-[16px] text-[#6b6880]">{open ? '▴' : '▾'}</button> : <span />}
        </div>
        <div className={`-my-2 hidden text-[14px] tabular-nums lg:grid ${cols(kst, paidCol)} [&>*]:flex [&>*]:min-w-0 [&>*]:items-center [&>*]:border-l [&>*]:border-[#e6e3ef] [&>*]:px-2 [&>*:first-child]:border-l-0 [&>*]:py-2`}>
          <span className="font-semibold">{time}</span>
          {kst && <span className="text-[#6b6880]">{k ? stripBold(k).replace(/ KST$/, '') : ''}</span>}
          <span className="font-semibold"><StudentName id={l.studentId} name={name} className="truncate" /></span>
          <span>{count}</span>
          <span>{minutesOf(l)}</span>
          <span>{kindTag(l) ?? 'Regular'}</span>
          <span className={`font-semibold ${stColor}`}>{stText}</span>
          {paidCol && <span>{paid}</span>}
          <span className="flex-wrap text-[13px]">
            <span className="min-w-0 flex-1">{l.topics}{remarksChip}</span>
            {canOpen && <button type="button" aria-expanded={open} aria-label={open ? 'Hide details' : 'Show details'} onClick={(e) => { e.stopPropagation(); toggle(); }}
              className="ml-1 flex h-[26px] w-[26px] shrink-0 items-center justify-center rounded-full text-[15px] text-[#6b6880] hover:bg-[#e6e3ef]">{open ? '▴' : '▾'}</button>}
          </span>
        </div>
      </div>
      {open && (
        <div className="border-t border-[#e6e3ef] bg-[#f7f6fb] px-3 pb-3 lg:pl-[92px]">
          {l.makeupOf && <p className="pt-2 text-[13px] text-[#6b6880]">Make-up for {whenFull(l.makeupOf, tz)}</p>}
          {l.compensationOf && <p className="pt-2 text-[13px] text-[#6b6880]">Compensation for {whenFull(l.compensationOf, tz)} (tutor no-show)</p>}
          {recordable ? (
            <div className="lg:max-w-[560px]">
              <DirtyCtx.Provider value={mark}>
                <RecordForm key={`${l.id}-${l.state}`} lesson={l} now={now} actions={actions} startEditing extra={links} admin={admin}
                  onSaved={async () => { setOpen(false); await onSaved(); }} />
              </DirtyCtx.Provider>
            </div>
          ) : (
            <div className="grid gap-2 pt-2">
              {l.remarks && <p className="text-[14px]"><b className="text-[13px] text-[#55526a]">Remarks</b> {l.remarks}</p>}
              <div className="flex flex-wrap items-center gap-1.5">
                {links}
                {l.locked && <span className="text-[13px] text-[#6b6880]">In payroll</span>}
              </div>
            </div>
          )}
        </div>
      )}
    </div>
  );
}

function RecordForm({ lesson: l, now, actions, startEditing, onSaved, extra }: {
  lesson: TutorLesson; now: Date; actions: TutorActions; startEditing: boolean; onSaved: (saved: TutorLesson) => Promise<void>; extra?: ReactNode; admin?: boolean;
}) {
  const [editing, setEditing] = useState(startEditing);
  const [result, setResult] = useState<TutorResult | null>(resultOf(l.classStatus));
  const [topics, setTopics] = useState(l.topics ?? '');
  const [remarks, setRemarks] = useState(l.remarks ?? '');
  // 지각은 결과와 따로 (4400): 평소엔 Held 만 누르면 끝, 지각일 때만 분 칸이 열림
  const [late, setLate] = useState<Late>(l.late);
  // Remarks 칸은 이슈 있을 때만 꺼내 씀 (대표 10/29). 강사 지각은 이유가 필요해서 바로 보임
  const [remarksOpen, setRemarksOpen] = useState(!!l.remarks);
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState('');
  const ready = recordReady(result, topics, remarks, late) && canRecord(l, now);
  const sameLate = (a: Late, b: Late) => a.student === b.student && a.studentMin === b.studentMin && a.tutor === b.tutor && a.tutorMin === b.tutorMin;
  useDirty(`record-${l.id}`, editing && (result !== resultOf(l.classStatus) || topics !== (l.topics ?? '') || remarks !== (l.remarks ?? '') || !sameLate(late, l.late)));

  if (!editing) {
    return (
      <div className="mt-2 flex items-center justify-between gap-2 rounded-[10px] bg-[#f3f1f8] px-3 py-2">
        <span className="text-[14px] font-semibold text-[#1f7a4d]">✓ {statusText(l, now)}{lateText(l.late)}{l.topics ? ` · ${l.topics}` : ''}</span>
        {canRecord(l, now) && <button type="button" onClick={() => setEditing(true)} className={`${btnSub} min-h-[36px] text-[13.5px]`}>Edit</button>}
      </div>
    );
  }

  async function save() {
    if (!result) return;
    if (result === 'tutor_no_show' && l.classStatus !== 'Tutor no-show'
      && !window.confirm('Record a tutor no-show? The student gets a make-up class and a free compensation class, and this class is not paid.')) return;
    setBusy(true);
    setErr('');
    try {
      const noShow = result === 'student_no_show' || result === 'tutor_no_show';
      const t = noShow ? '' : topics.trim();
      const lt = lateToSave(result, late);
      await actions.record(l.id, result, t, remarks, lt);
      setEditing(false);
      await onSaved({ ...l, state: 'done', classStatus: savedStatus(l, result, lt.tutor), topics: t || null, remarks: remarks.trim() || null, studentLate: lt.student, late: lt });
    } catch (e) {
      setErr(e instanceof Error ? e.message : 'Could not save. Please try again.');
    } finally {
      setBusy(false);
    }
  }

  // 강사 본인도 운영진도 Tutor no-show 선택 가능 (2026-11-04 대표, 4401)
  const results = ['held', 'student_no_show', 'tutor_no_show'] as const;
  return (
    <div className="mt-3 grid gap-3">
      <div>
        <p className={label}>How did the class go?</p>
        <div role="radiogroup" aria-label="How did the class go?" className="grid grid-cols-1 gap-1.5 sm:grid-cols-3">
          {results.map((r) => (
            <button key={r} type="button" role="radio" aria-checked={result === r} onClick={() => setResult(r)}
              className={`min-h-[48px] rounded-[10px] border px-2 text-[14px] font-semibold ${
                result === r ? 'border-[#5b3fe0] bg-[#5b3fe0] text-white' : 'border-[#d9d5e6] bg-white text-[#1d1b2b]'}`}>
              {RESULT_TEXT[r]}
            </button>
          ))}
        </div>
      </div>
      {result === 'held' && (
        <div>
          <p className={label}>Anyone late? <span className="font-normal">(skip if not)</span></p>
          <div className="grid gap-2">
            <LateRow id={`${l.id}-s`} who="Student late" on={late.student} min={late.studentMin}
              onToggle={(on) => setLate({ ...late, student: on, studentMin: on ? late.studentMin : null })} onMin={(m) => setLate({ ...late, studentMin: m })} />
            <LateRow id={`${l.id}-t`} who="Tutor late" hint="(I was late)" on={late.tutor} min={late.tutorMin}
              onToggle={(on) => setLate({ ...late, tutor: on, tutorMin: on ? late.tutorMin : null })} onMin={(m) => setLate({ ...late, tutorMin: m })} />
          </div>
        </div>
      )}
      {result !== 'student_no_show' && result !== 'tutor_no_show' && (
        <div>
          <label className={label} htmlFor={`topics-${l.id}`}>Covered topics</label>
          <textarea id={`topics-${l.id}`} rows={2} value={topics} onChange={(e) => setTopics(e.target.value)} className={input} />
        </div>
      )}
      {(remarksOpen || (result === 'held' && late.tutor)) ? <div>
        <label className={label} htmlFor={`remarks-${l.id}`}>{result === 'held' && late.tutor ? 'Briefly explain why you were late (required)' : 'Remarks'}</label>
        <textarea id={`remarks-${l.id}`} rows={result === 'held' && late.tutor ? 2 : 1} value={remarks} onChange={(e) => setRemarks(e.target.value)} className={input} />
      </div> : (
        <button type="button" onClick={() => setRemarksOpen(true)} className={`${btnSub} justify-self-start text-[14px]`}>+ Remarks</button>
      )}
      {err && <p className="text-[14px] text-[#b3261e]">{err}</p>}
      <div className="flex flex-wrap gap-2">
        <button type="button" disabled={!ready || busy} onClick={save} className={`${btnMain} flex-1`}>{busy ? 'Saving…' : 'Save'}</button>
        {l.state === 'done' && !extra && <button type="button" disabled={busy} onClick={() => setEditing(false)} className={btnSub}>Cancel</button>}
        {extra}
      </div>
    </div>
  );
}

/** 지각 한 줄 (4400): 켜면 5 / 10 / 15 min · Custom(분 직접 입력) */
function LateRow({ id, who, hint, on, min, onToggle, onMin }: {
  id: string; who: string; hint?: string; on: boolean; min: number | null; onToggle: (on: boolean) => void; onMin: (m: number | null) => void;
}) {
  const preset = (LATE_PRESETS as readonly number[]).includes(min ?? -1);
  const [custom, setCustom] = useState(on && min != null && !preset);
  const chip = (active: boolean) => `min-h-[40px] rounded-[10px] border px-3 text-[14px] font-semibold ${
    active ? 'border-[#5b3fe0] bg-[#5b3fe0] text-white' : 'border-[#d9d5e6] bg-white text-[#1d1b2b]'}`;
  return (
    <div className="rounded-[10px] border border-[#e6e3ef] bg-white px-3 py-2">
      <label className="flex min-h-[40px] items-center gap-2 text-[15px] font-semibold text-[#1d1b2b]">
        <input type="checkbox" checked={on} onChange={(e) => { onToggle(e.target.checked); if (!e.target.checked) setCustom(false); }} className="h-[20px] w-[20px] accent-[#5b3fe0]" />
        {who}{hint && <span className="text-[13px] font-normal text-[#6b6880]">{hint}</span>}
      </label>
      {on && (
        <div className="mt-1 flex flex-wrap items-center gap-1.5" role="radiogroup" aria-label={`${who} — how many minutes?`}>
          {LATE_PRESETS.map((m) => (
            <button key={m} type="button" role="radio" aria-checked={!custom && min === m} onClick={() => { setCustom(false); onMin(m); }} className={chip(!custom && min === m)}>{m} min</button>
          ))}
          <button type="button" role="radio" aria-checked={custom} onClick={() => { setCustom(true); if (preset) onMin(null); }} className={chip(custom)}>Custom</button>
          {custom && (
            <label className="flex items-center gap-1 text-[14px] text-[#1d1b2b]">
              <input id={`late-${id}`} type="number" inputMode="numeric" min={1} max={300} aria-label={`${who} minutes`} value={min ?? ''}
                onChange={(e) => onMin(e.target.value ? Math.max(0, Math.floor(Number(e.target.value))) : null)}
                className="w-[72px] rounded-[10px] border border-[#d9d5e6] px-2 py-1.5 text-[16px]" />
              min
            </label>
          )}
        </div>
      )}
    </div>
  );
}

/** 같은 학생 대체 수업은 한 카드로 */
function groupCovers(covers: TutorCover[]): TutorCover[][] {
  const m = new Map<string, TutorCover[]>();
  for (const c of covers) m.set(c.student, [...(m.get(c.student) ?? []), c]);
  return [...m.values()];
}

// 대체 수업 요청: 가능한 수업만 체크해 보내기 (체크 안 한 수업 = 불가). 확정은 운영진이 학생 답을 받은 뒤
function CoverCard({ covers, tz, actions, onSent }: { covers: TutorCover[]; tz: string; actions: TutorActions; onSent: () => Promise<void> }) {
  const [yes, setYes] = useState<Set<string>>(() => new Set());
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState('');
  const [sent, setSent] = useState(false);
  useDirty(`cover-${covers[0].id}`, !sent && yes.size > 0);
  async function send() {
    setBusy(true);
    setErr('');
    try {
      await actions.answerCover(covers.map((c) => c.id), [...yes]);
      setSent(true);
      await onSent();
    } catch (e) {
      setErr(e instanceof Error ? e.message : 'Could not send. Please try again.');
    } finally {
      setBusy(false);
    }
  }
  return (
    <div className={card}>
      <div className="flex flex-wrap items-baseline gap-x-2">
        <StudentName id={covers[0].studentId} name={covers[0].student} className="text-[16px] font-bold text-[#1d1b2b]" />
        <span className="text-[13px] text-[#6b6880]">{minutesOf(covers[0])} min · not confirmed yet</span>
      </div>
      <p className="mb-1.5 mt-3 text-[13px] font-semibold text-[#55526a]">Available?</p>
      <div className="grid gap-1.5">
        {covers.map((c) => {
          const on = yes.has(c.id);
          return (
            <button key={c.id} type="button" role="checkbox" aria-checked={on} disabled={busy}
              onClick={() => { const n = new Set(yes); if (on) n.delete(c.id); else n.add(c.id); setYes(n); }}
              className={`flex min-h-[52px] items-center gap-3 rounded-[10px] border px-3 py-2 text-left ${on ? 'border-[#5b3fe0] bg-[#efebff]' : 'border-[#d9d5e6] bg-white'}`}>
              <span aria-hidden className={`flex h-6 w-6 shrink-0 items-center justify-center rounded-[6px] border text-[14px] font-bold ${
                on ? 'border-[#5b3fe0] bg-[#5b3fe0] text-white' : 'border-[#b9b4cc] text-transparent'}`}>✓</span>
              <span className="flex-1">
                <b className="block text-[15px] text-[#1d1b2b]"><Rich text={rangeFull(c, tz)} /></b>
                {c.busy && <span className="block text-[12.5px] font-semibold text-[#b3261e]">{busyText(c.why, cityTime(tz))}</span>}
              </span>
            </button>
          );
        })}
      </div>
      {err && <p className="mt-2 text-[14px] text-[#b3261e]">{err}</p>}
      <button type="button" disabled={busy} onClick={send} className={`${btnMain} mt-3 w-full`}>
        {busy ? 'Sending…' : yes.size === 0 ? 'None of these work' : `Send answer · ${yes.size} available`}
      </button>
    </div>
  );
}

function MakeupCard({ m, tz, actions, closed, onSent }: { m: TutorMakeup; tz: string; actions: TutorActions; closed: boolean; onSent: () => Promise<void> }) {
  // 강사 자율 운영 1단계 (H26(82)): 학생 시간 하나를 골라 [Confirm make-up] → 바로 보강 수업. 모두 안 되면 메모로 운영진에게
  const declined = !!m.answeredAt && m.slots.every((s) => s.answer !== 'yes');
  const [pick, setPick] = useState<string | null>(() => m.slots.find((s) => s.answer === 'yes' && !s.busy && !s.past)?.id ?? null);
  const [none, setNone] = useState(declined);
  const [note, setNote] = useState(m.note ?? '');
  const [sent, setSent] = useState(declined);
  const [confirmed, setConfirmed] = useState<TutorMakeup['slots'][number] | null>(null);
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState('');
  const minutes = m.slots[0] ? minutesOf(m.slots[0]) : null;
  const [firstNote] = useState(note);
  useDirty(`makeup-${m.id}`, !closed && !confirmed && !sent && none && note !== firstNote);
  const picked = m.slots.find((s) => s.id === pick) ?? null;
  const at = (s: { startsAt: Date }) => `${whenText(s.startsAt, tz)} ${tzTimeLabel(tz)}`;

  async function run(f: () => Promise<void>) {
    setBusy(true);
    setErr('');
    try {
      await f();
      await onSent();
    } catch (e) {
      setErr(e instanceof Error ? e.message : 'Could not send. Please try again.');
    } finally {
      setBusy(false);
    }
  }

  return (
    <div className={card}>
      <div className="flex flex-wrap items-baseline gap-x-2">
        <StudentName id={m.studentId} name={m.student} className="text-[16px] font-bold text-[#1d1b2b]" />
        {m.compensation && <span className="rounded-[6px] bg-[#efebff] px-1.5 text-[12.5px] font-semibold text-[#5b3fe0]">Compensation</span>}
        {minutes && <span className="text-[13px] text-[#6b6880]">{minutes} min</span>}
      </div>
      <p className="text-[13.5px] text-[#55526a]">{m.compensation ? 'Tutor no-show class' : 'Original class'}: {makeupOrigin(m, tz)}</p>
      {confirmed ? (
        <p role="status" className="mt-2 rounded-[10px] bg-[#e6f6ec] px-3 py-2 text-[14.5px] font-bold text-[#1f7a4d]">
          ✓ Make-up confirmed · <Rich text={rangeFull(confirmed, tz)} />
        </p>
      ) : closed ? (
        <p className="mt-2 rounded-[10px] bg-[#f3f1f8] px-3 py-2 text-[14px] font-semibold text-[#1f7a4d]">{sent ? 'Sent ✓ · Edge English will arrange another time' : '✓ Closed by Edge English'}</p>
      ) : (
        <>
          <p className="mb-1.5 mt-3 text-[13px] font-semibold text-[#55526a]">Pick one time to confirm</p>
          <div className="grid gap-1.5" role="radiogroup" aria-label="Make-up time">
            {m.slots.map((s) => {
              const on = pick === s.id && !none;
              return (
                <button key={s.id} type="button" role="radio" aria-checked={on} disabled={s.past || s.busy || busy}
                  onClick={() => { setPick(s.id); setNone(false); }}
                  className={`flex min-h-[52px] items-center gap-3 rounded-[10px] border px-3 py-2 text-left disabled:opacity-40 ${
                    on ? 'border-[#5b3fe0] bg-[#efebff]' : 'border-[#d9d5e6] bg-white'}`}>
                  <span aria-hidden className={`flex h-6 w-6 shrink-0 items-center justify-center rounded-full border text-[11px] ${
                    on ? 'border-[#5b3fe0] bg-[#5b3fe0] text-white' : 'border-[#b9b4cc] text-transparent'}`}>●</span>
                  <span className="flex-1">
                    <b className="block text-[15px] text-[#1d1b2b]"><Rich text={rangeFull(s, tz)} /></b>
                    {s.busy && <span className="block text-[12.5px] font-semibold text-[#b3261e]">{busyText(s.why, cityTime(tz))}</span>}
                  </span>
                </button>
              );
            })}
          </div>
          {err && <p className="mt-2 text-[14px] text-[#b3261e]">{err}</p>}
          {!none ? (
            <div className="mt-3 grid gap-2">
              <button type="button" disabled={busy || !picked || !actions.confirm} className={`${btnMain} w-full`}
                onClick={() => run(async () => { await actions.confirm!(m.id, picked!.id); setConfirmed(picked); })}>
                {busy ? 'Confirming…' : picked ? `Confirm make-up · ${at(picked)}` : 'Confirm make-up'}
              </button>
              <button type="button" disabled={busy} className={`${btnSub} w-full`} onClick={() => { setNone(true); setPick(null); }}>None of these times work</button>
            </div>
          ) : (
            <>
              <label className={`${label} mt-3`} htmlFor={`note-${m.id}`}>Other times you are available</label>
              <textarea id={`note-${m.id}`} rows={2} value={note} onChange={(e) => { setNote(e.target.value); setSent(false); }} className={input} />
              <button type="button" disabled={busy || sent || !note.trim()} className={`${sent ? btnDone : btnMain} mt-2 w-full`}
                onClick={() => run(async () => { await actions.answer(m.id, [], note); setSent(true); })}>
                {sent ? 'Sent ✓ · Edge English will arrange another time' : busy ? 'Sending…' : 'Send to Edge English'}
              </button>
            </>
          )}
        </>
      )}
    </div>
  );
}
