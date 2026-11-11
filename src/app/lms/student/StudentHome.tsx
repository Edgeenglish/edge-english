'use client';

// 수강생 마이페이지 A-1 (카드 쌓기형) — 휴대폰: 카드 순서대로 + 아래 탭 / PC: 왼쪽 메뉴 + 가운데 카드 + 오른쪽 현황·결제
// 판정은 src/lms/student/home.ts (6시간 규칙은 rules/change.ts), 저장은 DB 함수(migration 2800, StudentActions).
// ③ 수강생 LMS (2026-10-28 대표): 휴무 안내에 한 번에 답(A안) · 보강 날짜는 달력에서 고르기 · 직접 취소
// 미리보기(?demo=1)는 같은 화면에 브라우저 안에서만 흉내 내는 동작(fakeStore)을 넣음 — 저장·발송 없음

import { googleCalendarUrl, icsUrl, type CalendarEvent } from '@/lms/calendar/add';
import { createContext, useContext, useEffect, useMemo, useRef, useState } from 'react';
import books from '@/data/books.json';
import { homepageProfile } from '@/lms/admin/homepage-tutor';
import { koZoneCity, ZONE_ROWS, zoneName } from '@/lms/admin/places';
import { MAKEUP_SLOTS_MAX } from '@/lms/admin/lesson-change';
import { CONFIRMED } from '@/lms/rules/policy';
import { diffDays, formatInZone, hoursBetween, instantToKstDate, type KstDate } from '@/lms/rules/dates';
import { MEET_MISSING_KO, meetRoomUrl } from '@/lms/rules/meet';
import type { PreviewExtras } from '@/lms/student/fake-data';
import HomeNotices from '@/app/lms/HomeNotices';
import type { LeaveRow, MakeupOption, MakeupRight, MyInfo, RegularSlot, Reminders, StudentActions, StudentView, TimezoneState } from '@/lms/student/live';
import {
  cancelManySummary,
  cancelPreview,
  creditPeriodFor,
  creditsForDate,
  lessonsLeft,
  nextLesson,
  PAYMENT_METHOD_LABEL,
  pointsHistory,
  regularLessonsLeft,
  planCancelMany,
  renewalPrompt,
  REQUEST_STATUS_LABEL,
  studentTodos,
  type CancelResult,
  type CreditPeriod,
  type PaymentSummary,
  type RenewalState,
  type RequestStatus,
  type StudentLesson,
  type StudentRequest,
} from '@/lms/student/home';

type Tab = 'home' | 'schedule' | 'requests' | 'materials' | 'me';
type Right = Pick<MakeupRight, 'lessonId' | 'itemId' | 'compId'>;
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
  rescheduling: 'bg-[#fdecea] text-[#7a1d12]',
  confirmed: 'bg-[#e3f5ea] text-[#13623a]',
  canceled: 'bg-[#eeecf4] text-[#55526a]',
  completed: 'bg-[#e3f5ea] text-[#13623a]',
  expired: 'bg-[#eeecf4] text-[#55526a]',
  withdrawn: 'bg-[#eeecf4] text-[#55526a]',
};

const card = 'rounded-[16px] border border-[#e6e3ef] bg-white';

// 수강생 화면 시각은 수강생이 사는 곳 시간대로 (11/3 대표: 해외 수강생은 본인 나라 시간으로 캘린더). 국내 수강생은 한국 시간 그대로.
// 화면 하나에 수강생 한 명이라 렌더할 때 정해 둠. 판정(6시간 규칙·수강 종료일 23:59 KST)은 그대로
let VIEW_TZ = 'Asia/Seoul';
/** 운영자 보기에서 해외 수강생을 한국 시간으로 보는 중 (주황 띠·배지) */
let ADMIN_KST = false;
/** 기준 이름: '시드니 시간' / '한국 시간' (도시 이름 한국어, 11/8 대표) */
const zoneCity = () => `${koZoneCity(VIEW_TZ)} 시간`;
const zoneText = zoneCity;
/** '20:00' → '오후 8:00', '00:30' → '오전 12:30' */
const ampm = (hhmm: string) => {
  const h = Number(hhmm.slice(0, 2));
  return `${h < 12 ? '오전' : '오후'} ${h % 12 === 0 ? 12 : h % 12}:${hhmm.slice(3, 5)}`;
};
/** '오후 8:30–9:20' (오전·오후가 바뀌면 '오전 11:30–오후 12:20') */
const ampmRange = (a: string, b: string) => {
  const x = ampm(a), y = ampm(b);
  return x.slice(0, 2) === y.slice(0, 2) ? `${x}–${y.slice(3)}` : `${x}–${y}`;
};
/** 이름은 예전 그대로(kst) — 보여 주는 시간대는 VIEW_TZ. time = '오후 8:00' */
function kst(d: Date) {
  const f = formatInZone(d, VIEW_TZ);
  return { md: `${Number(f.date.slice(5, 7))}/${Number(f.date.slice(8, 10))}`, wd: wdOf(f.date), time: ampm(f.time), date: f.date };
}
/** 'YYYY-MM-DD' 의 요일 (그 날짜 글자 그대로 — 시간대 바꿈 없음) */
const wdOf = (date: string) => '일월화수목금토'[new Date(`${date.slice(0, 10)}T00:00:00Z`).getUTCDay()];
const fmtDate = (d: KstDate) => `${Number(d.slice(5, 7))}/${Number(d.slice(8, 10))}`;

/*
 * 시각 표기 원칙 (2026-11-03 대표: '어디 기준 시간인지 빠지면 절대 안 됨', H26(93) 11/7: 수강생은 거주지 시간만,
 * 11/8 대표 확정: 표기 통일): 수강생 화면의 모든 날짜·요일·시각·신청 기한 = 수강생 거주지 시간 '11/2(월) 오후 8:00'.
 * 기준 시간대는 줄마다 붙이지 않고 화면·팝업 맨 위 띠 '모든 날짜·시간은 시드니 시간 기준' (ZoneBar, 11/8 대표 시안).
 * 운영자 보기에서만 '수강생 시간 | 한국 시간 (KST)' 전환 (이 브라우저에 기억). 한국 시간이면 주황 띠 '한국 시간 (KST)으로 보는 중'.
 */
const overseas = () => VIEW_TZ !== 'Asia/Seoul';
/*
 * 시간대 기준은 화면·팝업 맨 위 띠(ZoneBar) 한 곳에만 (11/8 대표 시안: 날짜마다 시간대 글을 반복하지 않음).
 * 아래 시각 글에는 시간대 이름을 붙이지 않는다. 예외: 수강생 시간대가 아닌 날짜(시트 이관 보강의 '한국 날짜')만 따로 적음
 */
/**
 * 시간 기준 배지 (11/8 대표 시안: 큰 띠 대신 작은 배지 하나, 화면·팝업 같은 모양).
 * 수강생 시간 = 보라 '모든 날짜·시간은 시드니 시간 기준', 운영자가 한국 시간으로 보는 중 = 주황 '한국 시간(KST) 기준으로 보는 중'.
 * 색만이 아니라 글자로 구별. globals.css 의 '* { color }' 때문에 글자에 색 직접 지정
 */
function ZoneBar({ change }: { change?: { value: string; options: string[]; disabled: boolean; onChange: (tz: string) => void } }) {
  const tone = ADMIN_KST ? 'bg-[#fff1d6] text-[#8a5300]' : 'bg-[#efeaff] text-[#3a22b0]';
  const text = ADMIN_KST ? '한국 시간(KST) 기준으로 보는 중' : `모든 날짜·시간은 ${zoneText()} 기준`;
  // 화면 맨 위 배지만: 누르면 바로 시간대 목록 (H26(122) A안 — 배지 위에 투명한 고르기 칸을 겹침)
  if (change && !ADMIN_KST)
    return (
      <label className={`relative inline-flex w-fit items-center gap-1.5 rounded-full px-3 py-1.5 text-[13.5px] font-bold leading-snug ${tone}`}>
        <Icon d="M12 22a10 10 0 1 0 0-20 10 10 0 0 0 0 20zM12 6v6l4 2" className="h-4 w-4 shrink-0" />
        <span className="text-[#3a22b0]">{text} · <span className="text-[#3a22b0] underline">변경</span></span>
        <select aria-label="시간대 변경" value={change.value} disabled={change.disabled}
          onChange={(e) => e.target.value !== change.value && change.onChange(e.target.value)}
          className="absolute inset-0 h-full w-full cursor-pointer opacity-0">
          {change.options.map((z) => <option key={z} value={z}>{tzLabel(z)}</option>)}
        </select>
      </label>
    );
  return (
    <p role="note" className={`inline-flex w-fit items-center gap-1.5 rounded-full px-3 py-1.5 text-[13.5px] font-bold leading-snug ${tone}`}>
      <Icon d="M12 22a10 10 0 1 0 0-20 10 10 0 0 0 0 20zM12 6v6l4 2" className="h-4 w-4 shrink-0" />
      <span className={ADMIN_KST ? 'text-[#8a5300]' : 'text-[#3a22b0]'}>{text}</span>
    </p>
  );
}
/** 운영자 보기 전용 시간대 전환: 수강생 시간 | 한국 시간(KST). 고른 쪽은 굵은 테두리·굵은 글자 (색만으로 구별하지 않음). 오른쪽에 기준 배지 */
const KstCtx = createContext<{ admin: boolean; studentTz: string; on: boolean; set: (v: boolean) => void }>({ admin: false, studentTz: 'Asia/Seoul', on: false, set: () => {} });
function KstToggle() {
  const c = useContext(KstCtx);
  if (!c.admin) return null;
  const city = koZoneCity(c.studentTz);
  const btn = (on: boolean) =>
    `min-h-[36px] rounded-full px-3.5 text-[13px] ${on ? 'border-2 border-white bg-white font-extrabold text-[#1d1b2b]' : 'border-2 border-transparent font-semibold text-white'}`;
  // 운영자만 보는 칸이라 운영자 검은 칸 안에 (11/11 대표: 학생 화면 부분은 모든 학생이 같게)
  return (
    <div className="-mt-3 mb-3 flex flex-wrap items-center gap-x-3 gap-y-2 rounded-b-[12px] bg-[#1d1b2b] px-3 pb-2">
      <span className="text-[13px] font-semibold text-white">시간 기준</span>
      {c.studentTz === 'Asia/Seoul' ? (
        <span className="inline-flex min-h-[36px] items-center rounded-full border-2 border-white bg-white px-3.5 text-[13px] font-extrabold text-[#1d1b2b]">한국 시간 (KST)</span>
      ) : <div role="group" aria-label="시간 기준 (운영자 보기)" className="flex w-fit rounded-full border border-white/30 bg-white/10">
        <button type="button" aria-pressed={!c.on} className={btn(!c.on)} onClick={() => c.set(false)}>수강생 시간 ({city})</button>
        <button type="button" aria-pressed={c.on} className={btn(c.on)} onClick={() => c.set(true)}>한국 시간 (KST)</button>
      </div>}
    </div>
  );
}
/**
 * 수강 종료(재등록 마감) 시각: 기준은 한국 종료일 23:59 (POL-RN-01). 보이는 시간대로 바꿔
 * 국내 '11/30(월) 오후 11:59', 시드니 '12/1(화) 오전 1:59' (11/3 대표·ChatGPT: 종료 시각도 현지로 정확히)
 */
const endText = (d: KstDate) => whenText(new Date(`${d}T23:59:00+09:00`));
/** 수강 종료일을 보이는 시간대 날짜만으로 '12/1(화)' (취소 창 보강 마감, 대표 11/8: 시각은 빼고 날짜만) */
const endDay = (d: KstDate) => {
  const k = kst(new Date(`${d}T23:59:00+09:00`));
  return `${k.md}(${k.wd})`;
};
const won = (n: number) => `${n.toLocaleString('ko-KR')}원`;

function Icon({ d, className = 'h-5 w-5' }: { d: string; className?: string }) {
  return (
    <svg aria-hidden viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth={2} strokeLinecap="round" strokeLinejoin="round" className={className}>
      {/* globals.css 의 '* { color }' 때문에 path 가 부모 색을 잃지 않도록 */}
      <path d={d} style={{ color: 'inherit' }} />
    </svg>
  );
}


// 같은 노쇼 수업이라도 원래 수업 보강과 무료 보상수업은 다른 권리 (4100)
const sameRight = (a: Right, b: Right) =>
  a.compId || b.compId ? !!a.compId && a.compId === b.compId : (a.lessonId !== null && a.lessonId === b.lessonId) || (a.itemId !== null && a.itemId === b.itemId);
/** 신청 제목 '보강 · 11/2 수업분': 원래 수업 날짜를 지금 보이는 시간대로 다시 씀 (운영자 한국 시간 전환에도 맞게). 시각 모르는 시트 수업은 한국 날짜 */
function reqTitle(r: StudentRequest) {
  if (!r.originalAt || r.kind !== 'makeup') return r.title;
  const day = r.originalTimeKnown === false
    ? `${fmtDate(formatInZone(r.originalAt, 'Asia/Seoul').date as KstDate)}${overseas() ? '(한국 날짜)' : ''}`
    : kst(r.originalAt).md;
  return `${r.compensation ? '무료 보상수업' : '보강'} · ${day} 수업분`;
}
function whenText(d: Date) {
  const k = kst(d);
  return `${k.md}(${k.wd}) ${k.time}`;
}
/** 보강 권리의 원래 수업: 시트에서 옮긴 보강은 날짜만 (00:00 으로 보이지 않게, 3700) */
const rightText = (m: { originalAt: Date; timeKnown?: boolean }) => {
  if (m.timeKnown !== false) return whenText(m.originalAt);
  return kstDateOnly(m.originalAt);
};
/** 시트에서 옮긴 수업(시각 모름): 한국 날짜만 — 해외 수강생 날짜로 바꾸면 하루 어긋날 수 있음 */
function kstDateOnly(d: Date) {
  const k = formatInZone(d, 'Asia/Seoul').date;
  return `${fmtDate(k as KstDate)}(${wdOf(k)})${overseas() ? ' 한국 날짜' : ''}`;
}
/*
 * 보강 권리 카드 (2026-11-07 대표: 수강생에게는 어떤 수업인지·사유 한 줄·신청 기한·날짜 선택만. 노쇼·보상 처리 같은 내부 사유는 안 보임)
 * 제목: 원래 수업 날짜 (수강생 시간대). withTime = 같은 날 수업이 둘일 때만 시각까지
 */
const rightTitle = (m: MakeupRight, withTime = false) => {
  if (m.compId) return '무료 보상수업 1회';
  if (m.timeKnown === false) return `${kstDateOnly(m.originalAt)} 수업`;
  const k = kst(m.originalAt);
  return `${k.md}(${k.wd})${withTime ? ` ${k.time}` : ''} 수업`;
};
/** 제목 아래 사유 한 줄 — 무료 보상수업은 원래 수업과 헷갈리지 않게 '추가' 수업으로만 */
const rightReason = (m: MakeupRight) =>
  m.compId ? '추가 비용 없이 신청할 수 있어요' : m.tutorLeave ? '강사 휴무로 취소된 수업' : m.tutorFault || m.tutorNoShow ? '강사 사정으로 취소된 수업' : '취소된 수업';
/**
 * 신청 기한 = 수강 종료일 하나 (H26(93): 정규·수강생 취소 보강·강사 귀책 보강·무료 보상수업 모두 같은 종료일. 보상수업 사용 기한도 이 날을 따라감).
 * 예외: 시행 전 시트에서 넘어온 강사 휴무 보강(이관 보강권)은 예전처럼 보강 날짜에 따라 종료일이 늘어나 기한을 적지 않음.
 * 보이는 시간대로 바꾼 시각까지 '기한: 11/21(토) 오전 1:59까지' (종료 기준은 한국 23:59)
 */
const rightUntil = (m: MakeupRight, endDate: KstDate | null) => {
  const d = m.compId ? m.useUntil : m.tutorLeave && m.itemId ? null : endDate;
  if (!d) return null;
  return `기한: ${endText(d)}까지`;
};
/** 같은 날 수업이 둘 이상이면 제목에 시각까지 */
const needsTime = (m: MakeupRight, all: MakeupRight[]) =>
  !m.compId && all.some((o) => o !== m && !o.compId && kst(o.originalAt).date === kst(m.originalAt).date);
/**
 * 수업까지 남은 때 (홈 '다음 수업'·수업 변경 창 같은 글, 11/2 점검 ④): 24시간 안이면 'n시간 후', 아니면 한국 날짜 차이로 '내일'·'n일 후'.
 * 판정(6시간 규칙 등) 계산은 그대로 — 화면 글만 하나로
 */
function untilText(now: Date, at: Date): string {
  const hours = hoursBetween(now, at);
  if (hours < 24) return `${Math.max(1, Math.floor(hours))}시간 후`;
  const days = diffDays(formatInZone(now, VIEW_TZ).date, kst(at).date);
  return days === 1 ? '내일' : `${days}일 후`;
}

export default function StudentHome(props: {
  nowIso: string;
  initial: StudentView;
  actions: StudentActions;
  /** 미리보기에만: 교재·결제 내역·동의 할 일 (실제 데이터 연결 전 항목) */
  extras?: PreviewExtras;
  preview: boolean;
  adminBar?: React.ReactNode;
  onLogout?: () => void;
  /** 톡 바로가기 ?makeup=수업(시트 보강·보상권)id → 그 '보강 날짜 고르기'를 바로 엶 (11/8 대표 시안) */
  openMakeup?: string;
}) {
  const { actions, extras, preview } = props;
  const now = useMemo(() => new Date(props.nowIso), [props.nowIso]);
  const [s, setView] = useState<StudentView>(props.initial);
  const studentTz = s.timezone || props.initial.timezone || 'Asia/Seoul';
  // 운영자 보기에서만 한국 시간으로 바꿔 볼 수 있음 (H26(93)). 수강생 본인 화면은 항상 수강생 시간
  const isAdminView = !!props.adminBar;
  const [adminKst, setAdminKstState] = useState(false);
  useEffect(() => {
    if (!isAdminView) return;
    try { if (localStorage.getItem('lms_admin_student_view_kst') === '1') setAdminKstState(true); } catch { /* 저장 안 되는 브라우저 */ }
  }, [isAdminView]);
  const setAdminKst = (v: boolean) => {
    setAdminKstState(v);
    try { localStorage.setItem('lms_admin_student_view_kst', v ? '1' : '0'); } catch { /* 저장 안 되는 브라우저 */ }
  };
  VIEW_TZ = isAdminView && adminKst ? 'Asia/Seoul' : studentTz;
  ADMIN_KST = isAdminView && adminKst && studentTz !== 'Asia/Seoul';
  const [renewal, setRenewal] = useState<RenewalState>(props.initial.renewalPaid ? 'payment_confirmed' : 'not_requested');
  const [consents, setConsents] = useState(extras?.pendingConsents ?? []);
  const [tab, setTab] = useState<Tab>('home');
  const [overlay, setOverlay] = useState<Overlay>(null);
  // 창이 열리면 history 에 한 칸 → 휴대폰 뒤로가기(제스처 포함)는 창만 닫고 수강생 화면에 머묾 (Work QA 11/7: 수업 변경 창에서 뒤로가기 → 화면 이탈)
  const overlayOpen = overlay !== null;
  const mounted = useRef(true);
  useEffect(() => { mounted.current = true; return () => { mounted.current = false; }; }, []);   // 화면을 떠날 때(다른 페이지)는 아래에서 history 를 건드리지 않게
  useEffect(() => {
    if (!overlayOpen) return;
    if (!window.history.state?.studentSheet) window.history.pushState({ ...(window.history.state ?? {}), studentSheet: true }, '');
    const onPop = () => setOverlay(null);
    window.addEventListener('popstate', onPop);
    return () => {
      window.removeEventListener('popstate', onPop);
      // ✕·바깥 누름 등 화면에서 닫았으면 넣어 둔 칸을 빼서, 다음 뒤로가기가 한 번에 이전 화면으로 가게
      if (mounted.current && window.history.state?.studentSheet) window.history.back();
    };
  }, [overlayOpen]);
  const [toast, setToast] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [reminders, setReminders] = useState<Reminders | null>(null);
  /** 저장은 됐는데 화면을 다시 읽지 못함 (R-02) → 위에 안내 + [다시 읽기] */
  const [stale, setStale] = useState<string | null>(null);
  /** 여러 수업 취소가 중간에 멈춤 → 남은 수업만 다시 고른 상태로 창 유지 (R-02) */
  const [retry, setRetry] = useState<{ ids: string[]; notice: string } | null>(null);

  const lessons = s.lessons;
  // 강사 휴무로 못 들은 수업도 수강생 화면에서는 '보강' (2026-10-28 대표). DB 구분(lms_is_leave_postponed)은 그대로
  const openRights = s.makeupRights.filter((m) => !m.requested);
  // 휴무 처리 중인 시트 휴가 수업(수업 줄 없음)도 남은 수업 — 보강 신청 목록에서만 빠짐 (3700, 대시보드와 같은 수)
  const makeupsOwed = s.makeupRights.length + (s.leavePending?.length ?? 0);
  const leaveAsk = s.leave.filter((x) => x.choice === 'substitute' && x.stage === 'tutor_ok');
  const todos = studentTodos({ pendingConsents: consents });
  const next = nextLesson(lessons, now);
  const left = lessonsLeft(lessons, now, makeupsOwed);
  // 결제 확인 전·강사 배정 전(수업이 아직 없음)에는 '수업이 0회 남았어요' 재등록 안내를 띄우지 않음 (QA-05)
  const notStarted = !s.paid || (s.enrollmentStatus != null && s.enrollmentStatus !== 'active' && lessons.length === 0);
  const prompt = notStarted ? null : renewalPrompt(lessons, renewal, now, makeupsOwed, studentTz);
  const endDate = s.finalEndDate;
  // 바로가기 링크: 고를 수 있으면 날짜 고르기를 바로 열고, 아니면 수강생 홈 맨 위 한 줄로 이유 (신청 중·확정·기한 지남·열 수 없음)
  const [linkNote, setLinkNote] = useState<string | null>(null);
  useEffect(() => {
    const id = props.openMakeup;
    if (!id) return;
    try {
      // 새로고침·뒤로가기로 다시 열리지 않게 주소에서 뺌 (운영자 보기 ?student= 는 그대로)
      const u = new URL(window.location.href);
      u.searchParams.delete('makeup');
      window.history.replaceState(window.history.state, '', u.pathname + u.search);
    } catch { /* 주소를 못 바꿔도 화면은 그대로 */ }
    const hit = (x: { lessonId?: string | null; itemId?: string | null; compId?: string | null }) => x.lessonId === id || x.itemId === id || x.compId === id;
    const right = s.makeupRights.find((m) => !m.requested && hit(m));
    if (right) return setOverlay({ kind: 'makeup', right });
    const req = s.requests.filter((q) => q.kind === 'makeup' && q.status !== 'canceled' && hit(q)).sort((a, b) => b.createdAt.getTime() - a.createdAt.getTime())[0];
    if (req && (req.status === 'confirmed' || req.status === 'completed'))
      setLinkNote(`이 수업의 보강이 확정됐어요${req.confirmedAt ? `: ${whenText(req.confirmedAt)}` : '.'}`);
    else if (req) setLinkNote('이 수업은 보강을 이미 신청했어요. 강사님 확인을 기다리는 중이에요. 신청 내역에서 확인할 수 있어요.');
    else if (s.lessons.some((l) => l.id === id))
      setLinkNote(endDate && now.getTime() > new Date(`${endDate}T23:59:59+09:00`).getTime()
        ? `이 수업은 보강 신청 기한(${endText(endDate)})이 지났어요. 카카오톡으로 문의해 주세요.`
        : '이 수업은 지금 보강을 신청할 수 없어요. 카카오톡으로 문의해 주세요.');
    else setLinkNote('열 수 없는 링크예요. 카카오톡으로 문의해 주세요.');
  }, []); // eslint-disable-line react-hooks/exhaustive-deps
  const dLeft = endDate ? diffDays(formatInZone(now, 'Asia/Seoul').date, endDate) : 0;
  const points = pointsHistory(s.points);
  // 가상 화면은 extras(지난 Unit 포함), 실제 화면은 강사가 정한 교재 이름만 (QA C-04)
  const textbook: { title: string; lastUnit?: number | null } | null = extras?.textbook ?? (s.textbook ? { title: s.textbook, lastUnit: null } : null);
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

  // 시간대 자동 확인 (H26(119)): 기기 시간대가 프로필과 다르고, 그 기기 시간대에 [그대로]를 누른 적이 없으면 맨 위에서 물음. 운영자 보기에서는 안 물음
  const [tzState, setTzState] = useState<TimezoneState | null>(null);
  const [deviceTz, setDeviceTz] = useState<string | null>(null);
  useEffect(() => {
    actions.timezone().then(setTzState, () => setTzState(null));
    try {
      const d = Intl.DateTimeFormat().resolvedOptions().timeZone;
      // 'UTC'·'Etc/…' 는 기기 설정이 없는 경우라 묻지 않음
      if (d && d.includes('/') && !d.startsWith('Etc/')) setDeviceTz(d);
    } catch { /* 시간대를 못 읽는 브라우저 */ }
  }, [actions]);
  const askTz = !isAdminView && tzState && deviceTz && deviceTz !== studentTz && deviceTz !== tzState.kept ? deviceTz : null;

  async function saveTimezone(change: { set?: string; keep?: string }) {
    setBusy(true);
    try {
      setTzState(await actions.timezone(change));
      if (change.set) {
        setView(await actions.reload());
        say('저장했어요.');
      }
    } catch (e) {
      setToast(e instanceof Error ? e.message : '저장하지 못했어요.');
    } finally {
      setBusy(false);
    }
  }

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

  // 수업 시간 (H26(95) ②): 매주 정규 요일·시각 — 수강생 거주지 시간으로 (운영자 보기에서 KST 전환 시 한국 시간)
  const [slots, setSlots] = useState<RegularSlot[]>([]);
  useEffect(() => {
    let alive = true;
    actions.regularSlots().then((x) => { if (alive) setSlots(x); }, () => {});
    return () => { alive = false; };
  }, [actions, s]);
  const slotText = regularSlotText(slots, now);

  // 나의 학습 정보(강사 작성)·누적 학습 시간 (11/11 대표 시안, migration 20261111010000)
  const [info, setInfo] = useState<MyInfo | null>(null);
  useEffect(() => {
    let alive = true;
    actions.myInfo().then((x) => { if (alive) setInfo(x); }, () => {});
    return () => { alive = false; };
  }, [actions, s]);

  // [맞는 시간이 없어요] 보일 보강권 (H26(92) ⑤): 수업 번호 → 누른 시각. 화면을 다시 읽을 때마다 같이
  const [noTime, setNoTime] = useState<Map<string, string | null>>(new Map());
  useEffect(() => {
    let alive = true;
    actions.noTimeRights().then((m) => { if (alive) setNoTime(m); }, () => {});
    return () => { alive = false; };
  }, [actions, s]);

  async function confirmCancel(lesson: StudentLesson) {
    let allowed = false;
    const v = await run(async () => {
      allowed = (await actions.cancel(lesson.id)).makeup_allowed;
    }, '수업을 취소했어요.');
    if (!v) return;
    const right = v.makeupRights.find((m) => m.lessonId === lesson.id && !m.requested);
    setOverlay(allowed && right ? { kind: 'makeup', right, canceled: true } : null);
  }
  /**
   * 여러 수업 한 번에 취소 (추가 요청 2): 시간순으로 하나씩 DB 판정 — 미리 보기(기간별 변경권 차례 차감)와 같은 순서.
   * 하나가 실패하면 거기서 멈추되(R-02) 그때까지 저장된 결과를 반드시 다시 읽고, 성공·실패를 나눠 알리고, 남은 수업만 다시 고른 상태로 창을 둔다.
   * 완료 문구는 예상치가 아니라 저장 결과로 (R-01)
   */
  async function confirmCancelMany(ls: StudentLesson[]) {
    const sorted = [...ls].sort((a, b) => +a.startsAt - +b.startsAt);
    const done: { lesson: StudentLesson; r: CancelResult }[] = [];
    let failed: { lesson: StudentLesson; message: string } | null = null;
    setBusy(true);
    setRetry(null);
    try {
      for (const l of sorted) {
        try {
          done.push({ lesson: l, r: await actions.cancel(l.id) });
        } catch (e) {
          failed = { lesson: l, message: e instanceof Error ? e.message : '오류' };
          break;
        }
      }
      // 저장된 것이 있으면(또는 실패했어도) 서버 상태를 다시 읽음 — 재조회가 실패하면 성공으로 보이지 않게 안내 + [다시 읽기]
      let v: StudentView | null = null;
      try {
        v = await actions.reload();
        setView(v);
        setStale(null);
      } catch {
        setStale(`${done.length}회 취소는 저장됐지만 화면을 다시 읽지 못했어요. [다시 읽기]를 눌러 확인해 주세요.`);
      }
      const remaining = v
        ? [...new Map(done.map((d) => { const p = creditPeriodFor(v!.creditPeriods, instantToKstDate(d.lesson.startsAt)); return [p?.start ?? '', { start: p?.start ?? null, left: p ? p.left : v!.creditsLeft }] as const; })).values()]
        : [];
      const summary = done.length > 0 ? cancelManySummary(done.map((d) => d.r), remaining) : '';
      if (!failed) {
        say(summary);
        setOverlay(null);
        return;
      }
      const rest = sorted.slice(sorted.findIndex((l) => l.id === failed!.lesson.id));
      const restLeft = v ? rest.filter((l) => v!.lessons.some((x) => x.id === l.id && x.state === 'scheduled')) : rest;
      const notice = `${done.length > 0 ? `${done.length}회는 취소했어요. ` : ''}${whenText(failed.lesson.startsAt)} 수업은 취소하지 못했어요: ${failed.message}${restLeft.length > 0 ? ` 아래 ${restLeft.length}회는 처리되지 않았어요. 다시 취소하려면 선택을 확인하고 버튼을 눌러 주세요.` : ''}`;
      // 남은 수업이 그새 다른 경로로 처리돼 다시 할 것이 없으면, 성공 요약 뒤에 그 사실만 덧붙임
      setToast(done.length > 0 ? (restLeft.length > 0 ? summary : `${summary} · ${whenText(failed.lesson.startsAt)} 수업은 ${failed.message}`) : notice);
      if (restLeft.length > 0) {
        setRetry({ ids: restLeft.map((l) => l.id), notice });
        setOverlay({ kind: 'cancel', lessonId: null });
      } else {
        setOverlay(null);
      }
    } finally {
      setBusy(false);
    }
  }

  async function answerLeave(answer: 'ok' | 'makeup') {
    const ids = leaveAsk.map((x) => x.id);
    const v = await run(() => actions.answerLeave(ids, answer), answer === 'ok' ? '확정했어요.' : '기존 강사님과 수업하기로 정했어요.');
    if (!v || answer === 'ok') return;
    const right = v.makeupRights.find((m) => !m.requested && leaveAsk.some((x) => (x.lessonId && x.lessonId === m.lessonId) || (x.itemId && x.itemId === m.itemId)));
    if (right) setOverlay({ kind: 'makeup', right });
  }

  const nextFull = next && s.lessons.find((l) => l.id === next.id);
  // 다음 수업 칸은 수업이 없어도 늘 같은 자리에 (11/11 대표: 학생마다 화면 모양이 달라 보이지 않게)
  const nextCard = <NextLesson lesson={next} now={now} meetUrl={nextFull?.leaveOpen ? null : meetRoomUrl(nextFull?.meetUrl)} substitute={nextFull?.substitute ?? false} leaveOpen={!!nextFull?.leaveOpen} />;

  const renewalCard = prompt && (
    <section aria-label="재등록 안내" className="grid gap-2.5 rounded-[18px] border border-[#f0d27a] bg-[#fff4d6] p-4 lg:flex lg:items-center lg:gap-4">
      <div className="lg:flex-1">
        <h2 className="text-[15px] font-bold text-[#5c3b00]">수업이 {prompt.left}회 남았어요</h2>
        {prompt.mode === 'request' ? (
          <p className="mt-1 text-[13px] leading-relaxed text-[#5c3b00]">
            종료일 {endText(endDate)}까지 재등록 결제하면 남은 수업을 다음 등록으로 옮길 수 있고, 지금 고정 시간도 유지돼요.
          </p>
        ) : (
          <p className="mt-1 text-[13px] leading-relaxed text-[#5c3b00]">
            <b>재등록 신청 완료 · 결제 확인 중</b>이에요. 결제는 운영자가 직접 확인하고, 확인되면 이 안내가 사라져요. 마감은 {endText(endDate)}예요.
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
      <Tile label="남은 수업" value={notStarted ? '—' : `${left.total}`} unit={notStarted ? '' : '회'} sub={notStarted ? (s.paid ? '수업 일정 준비 중' : '결제 확인 후 시작') : left.other ? `정규 ${left.regular} · 보강 ${left.other}` : `${s.totalLessons}회 중`} />
      <Tile label="변경권" value={`${s.creditsLeft}`} unit="개" sub={`이번 기간 ${s.creditsPerPeriod}개 중 ›`} onClick={() => setOverlay({ kind: 'credits' })} />
      <Tile
        label="수강 종료"
        value={!endDate ? '-' : dLeft > 0 ? `D-${dLeft}` : dLeft === 0 ? 'D-day' : '종료'}
        sub={endDate ? `${endText(endDate)}까지` : ''}
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
        <span className="text-[12px] leading-[1.55] text-[#55526a]">
          보강할 수업 {openRights.filter((m) => !m.compId).length}회
          {openRights.some((m) => m.compId) && (
            <>
              <br />
              무료 보상수업 {openRights.filter((m) => m.compId).length}회
            </>
          )}
        </span>
      </button>
    </section>
  );

  // 신청 진행 상태도 신청이 없어도 늘 보임 (11/11 대표: 학생마다 같은 화면)
  const requestList = (
    <section aria-label="신청 진행 상태" className={`${card} grid gap-1 p-4`}>
      <div className="flex items-center justify-between">
        <h2 className="text-[15px] font-bold">신청 진행 상태</h2>
        <button type="button" onClick={() => setTab('requests')} className="min-h-[36px] text-[13px] text-[#4b2fd6] underline">
          전체 ›
        </button>
      </div>
      {s.requests.length === 0 && <p className="py-2 text-[14px] text-[#6b6880]">아직 신청한 내용이 없어요.</p>}
      {s.requests.slice(0, 3).map((r) => (
        <RequestRow key={r.id} r={r} onOpen={() => setOverlay({ kind: 'request', id: r.id })} />
      ))}
    </section>
  );

  const payBox = (
    <section aria-label="수강과 결제" className={`${card} px-4 pb-1.5 pt-4`}>
      <h2 className="mb-2 text-[15px] font-bold">수강·결제·적립금</h2>
      <LinkRow label="수강권" value={s.product} onClick={extras && (() => setOverlay({ kind: 'payments' }))} />
      <div className="flex min-h-[60px] w-full items-center justify-between gap-3 border-t border-[#eeecf4] py-2 text-[14px]">
        <span className="shrink-0 text-[#55526a]">수업 시간</span>
        <span className="grid min-w-0 gap-0.5 text-right">
          {slotText ? slotText.map((g) => (
            <span key={g.when + g.tutor} className="grid">
              <span className="font-semibold">{g.when}</span>
              <span className="text-[13px] text-[#55526a]">{g.tutor}</span>
            </span>
          )) : <span className="text-[#6b6880]">등록된 정규 시간이 없어요</span>}
        </span>
      </div>
      <LinkRow label="결제" value={s.paid ? `결제 완료${s.confirmedOn ? ` (${fmtDate(s.confirmedOn)})` : ''}` : '결제 확인 중'} valueClass={s.paid ? 'text-[#13623a]' : 'text-[#8a5300]'} onClick={extras && (() => setOverlay({ kind: 'payments' }))} />
      <LinkRow label="적립금 내역" value={won(points.balance)} valueClass="font-bold" onClick={() => setOverlay({ kind: 'points' })} />
    </section>
  );

  // 할 일: 수강생이 직접 해야 하는 것만 (휴무 안내 답 · 날짜 안 잡은 보강 POL-OP-22 · 수업 안내 동의)
  const todoItems = (
    <>
      {leaveAsk.length > 0 && <TodoBar n={leaveAsk.length} text="담당 강사님 휴무 안내" onClick={() => setOverlay({ kind: 'leave' })} />}
      {openRights.length > 0 && <TodoBar n={openRights.length} text="보강 날짜 고르기" onClick={() => setOverlay({ kind: 'makeup', right: openRights.length === 1 ? openRights[0] : null })} />}
      {todos.length > 0 && <TodoBar n={todos.length} text={todos.length === 1 ? todos[0].label : `${todos.length}가지 확인이 필요해요`} onClick={() => setOverlay({ kind: 'consent' })} />}
    </>
  );
  const todoCount = (leaveAsk.length > 0 ? 1 : 0) + (openRights.length > 0 ? 1 : 0) + (todos.length > 0 ? 1 : 0);
  // 할 일 칸은 0개여도 늘 보임 (11/11 대표)
  const todoBars = (
    <section aria-label="할 일" className="overflow-hidden rounded-[18px] border-2 border-[#f0a33a] bg-white">
      <h2 className="flex items-center gap-2 bg-[#fff4d6] px-4 py-2.5 text-[16px] font-bold text-[#5c3b00]">
        할 일
      </h2>
      {todoCount > 0 ? <div className="divide-y divide-[#f3e6c4]">{todoItems}</div> : <p className="px-4 py-3.5 text-[14px] text-[#6b6880]">할 일이 없어요</p>}
    </section>
  );

  const upcoming = lessons.filter((l) => l.state === 'scheduled' && l.startsAt.getTime() > now.getTime()).sort((a, b) => a.startsAt.getTime() - b.startsAt.getTime());
  const canceledAhead = lessons.filter((l) => l.state === 'canceled' && l.startsAt.getTime() > now.getTime()).sort((a, b) => a.startsAt.getTime() - b.startsAt.getTime());
  const leaveVisible = s.leave.length > 0;
  // 휴무 처리 확정 전 수업(일정 조율 중)은 입장 링크 없음 — 휴무 강사 링크로 들어가지 않게
  // 수업 링크는 회의실 주소(meet.google.com/xxx-xxxx-xxx)일 때만 (R-05) — 홈페이지 주소는 링크로 내보내지 않음
  const meetOf = (id: string) => { const x = s.lessons.find((l) => l.id === id); return x && !x.leaveOpen ? meetRoomUrl(x.meetUrl) : null; };
  // 강사마다 수업 링크가 다름 → 앞으로 수업하는 강사별로 (대체강사 포함)
  const meetLinks = [...new Map(upcoming.map((l) => [l.tutorName, meetOf(l.id)] as const).filter(([, u]) => u)).entries()];
  // 내 정보 '담당 강사' = 정규 수업 강사 (없으면 다음 수업 강사)
  const myTutors = [...new Set(slots.map((x) => x.tutor))].join(' · ') || upcoming[0]?.tutorName || '';
  const enrollText = s.enrollmentStatus === 'active' || s.enrollmentStatus === 'confirmed' ? '수강 중' : s.enrollmentStatus === 'completed' ? '수강 종료' : s.enrollmentStatus === 'pending_payment' ? '결제 확인 중' : null;

  const logo = (
    <span className="inline-flex items-center gap-1.5">
      <img src="/images/brand/edge-english-logo.svg" alt="엣지영어" className="h-[22px] w-auto" />
      <span className="rounded-[6px] bg-[#27230e] px-[6px] py-[2px] text-[11px] font-extrabold text-[#ffd401]">수강생용</span>
    </span>
  );
  const brand = props.adminBar ? <a href="/lms/admin" aria-label="운영자 화면으로" className="inline-flex">{logo}</a> : <button type="button" aria-label="새로고침" onClick={() => window.location.reload()} className="inline-flex">{logo}</button>;
  return (
    <KstCtx.Provider value={{ admin: isAdminView, studentTz, on: adminKst, set: setAdminKst }}>
    <div className="mx-auto min-h-dvh max-w-[1280px] font-sans text-[#1d1b2b] lg:flex lg:gap-6 lg:px-6 lg:py-6">
      <nav aria-label="메뉴" className="hidden w-[220px] shrink-0 flex-col gap-1 lg:flex">
        <div className="px-3 pb-4 pt-1">{brand}</div>
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
        {props.adminBar && <div className="grid px-4 pt-3 lg:px-0 lg:pt-0">{props.adminBar}<KstToggle /></div>}
        <header className="flex items-center justify-between px-5 pb-3 pt-[18px] lg:hidden">
          {brand}
          <span className="text-[13px] text-[#55526a]">{s.name} 님</span>
        </header>
        <div className="grid gap-2 px-4 pb-3 lg:px-0 lg:pb-4 lg:pt-1">
          {askTz && (
            <section aria-label="시간대 확인" className="grid gap-2.5 rounded-[14px] border border-[#d9d0ff] bg-[#f3f0ff] px-3.5 py-3">
              <p className="text-[15px] font-semibold leading-relaxed text-[#1d1b2b]">
                지금 계신 곳이 {withRo(koZoneCity(askTz))} 보여요. {koZoneCity(askTz)} 시간으로 볼까요?
              </p>
              <div className="flex flex-wrap gap-2">
                <button type="button" disabled={busy} onClick={() => saveTimezone({ set: askTz })}
                  className="min-h-[44px] rounded-[10px] bg-[#5b3df0] px-4 text-[14px] font-semibold text-white disabled:opacity-50">
                  {koZoneCity(askTz)} 시간으로 보기
                </button>
                <button type="button" disabled={busy} onClick={() => saveTimezone({ keep: askTz })}
                  className="min-h-[44px] rounded-[10px] border border-[#d9d5e8] bg-white px-4 text-[14px] font-semibold text-[#1d1b2b] disabled:opacity-50">
                  {koZoneCity(studentTz)} 시간 그대로
                </button>
              </div>
            </section>
          )}
          {/* 시간대 띠는 모든 학생·운영자 보기에서 같은 자리·같은 모양 (11/11 대표: 학생마다 화면이 달라 보이지 않게) */}
          <ZoneBar change={tzState ? { value: studentTz, options: tzOptions(studentTz, deviceTz), disabled: busy, onChange: (z) => saveTimezone({ set: z }) } : undefined} />
          {tab === 'home' && <LearnedBand minutes={info?.learnedMin ?? 0} />}
          {linkNote && (
            <p role="status" className="flex items-start justify-between gap-2 rounded-[12px] border border-[#d9d0ff] bg-[#f3f0ff] px-3.5 py-2.5 text-[14px] font-semibold leading-relaxed text-[#3a22b0]">
              <span>{linkNote}</span>
              <button type="button" aria-label="안내 닫기" onClick={() => setLinkNote(null)} className="-my-1 h-8 w-8 shrink-0 text-[16px] text-[#55526a]">✕</button>
            </p>
          )}
        </div>

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

        {/* 운영진 공지 (대시보드에서 게시, 게시 중일 때만) — 운영 화면과 같은 자리 */}
        {!preview && tab === 'home' && <HomeNotices who="student" title="공지" className="mx-4 mb-3 lg:mx-0 lg:mb-4" />}

        {/* 홈: 운영 화면 배치 유지 (11/11 대표) + 시안 변경점(누적 학습 시간 띠·할 일/다음 수업 칸 항상·다음 수업 교재 링크 없음) */}
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
            {[...upcoming.map((l) => ({ at: l.startsAt, l, p: null })), ...(s.leavePending ?? []).map((p) => ({ at: p.startsAt, l: null, p }))]
              .sort((a, b) => a.at.getTime() - b.at.getTime())
              .map(({ l, p }) => p ? (
              // 휴무 처리 중인데 수업 줄이 아직 없는 수업 (3700, 대표 11/2: 휴무 안내에는 보이는데 일정에 없음)
              <div key={p.id} className={`${card} p-4`}>
                <p className="text-[15px] font-semibold">{whenText(p.startsAt)}</p>
                <p className="text-[12.5px] text-[#6b6880]">{Math.round((p.endsAt.getTime() - p.startsAt.getTime()) / 60000)}분</p>
                <p className="mt-1 text-[13px] font-bold text-[#b3261e]">⚠️ 강사님 휴무로 일정 조율 중</p>
              </div>
            ) : l && (
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
                  <span className="text-[#6b6880]">{l.state === 'done' ? (s.lessons.find((x) => x.id === l.id)?.tutorNoShow ? '강사 사정으로 취소' : '진행') : l.state === 'canceled' ? '취소' : l.startsAt.getTime() + l.minutes * 60_000 > now.getTime() ? '진행 중' : '기록 전'}</span>
                </div>
              ))}
          </TabPage>
        )}

        {tab === 'requests' && (
          <TabPage title="신청 내역">
            {/* 빈 상태 (QA C-04): 오류인지 비어 있는지 알 수 있게 — 상태만, 사용법 안내는 넣지 않음 */}
            {s.requests.length === 0 && openRights.length === 0 && (
              <p className={`${card} px-4 py-5 text-center text-[14px] text-[#6b6880]`}>아직 신청한 내용이 없어요.</p>
            )}
            {s.requests.length > 0 && (
              <section className={`${card} grid gap-1 p-4`}>
                {s.requests.map((r) => (
                  <RequestRow key={r.id} r={r} onOpen={() => setOverlay({ kind: 'request', id: r.id })} />
                ))}
              </section>
            )}
            {openRights.length > 0 && (
              <section className={`${card} grid gap-1 p-4`}>
                {openRights.map((m) => (
                  <button key={`${m.lessonId}${m.itemId}${m.compId}`} type="button" onClick={() => setOverlay({ kind: 'makeup', right: m })}
                    className="flex min-h-[56px] w-full items-center justify-between gap-2 border-b border-[#eeecf4] py-2 text-left last:border-0">
                    <span>
                      <span className="block text-[14px] font-semibold">{rightTitle(m, needsTime(m, openRights))}</span>
                      <span className="block text-[12px] text-[#6b6880]">{rightReason(m)}{rightUntil(m, endDate) ? ` · ${rightUntil(m, endDate)}` : ''}</span>
                    </span>
                    <span className="flex items-center gap-1.5">
                      <span className="whitespace-nowrap rounded-full bg-[#fff1d6] px-2.5 py-1 text-[12px] font-semibold text-[#8a5300]">날짜 선택 필요</span>
                      <span className="text-[#8b88a0]">›</span>
                    </span>
                  </button>
                ))}
              </section>
            )}
          </TabPage>
        )}

        {tab === 'materials' && (
          <TabPage title="학습자료">
            {!textbook && <p className={`${card} px-4 py-5 text-center text-[14px] text-[#6b6880]`}>아직 정해진 교재가 없어요.</p>}
            {textbook && (
              <section className={`${card} grid gap-3 p-4`}>
                <p className="text-[13px] font-bold text-[#5b3df0]">지금 수업 교재</p>
                <p className="text-[17px] font-bold">{textbook.title}</p>
                <p className="text-[13px] text-[#55526a]">
                  {[book ? `${book.category} · ${book.level.join('·')}` : '', textbook.lastUnit ? `지난 수업 Unit ${textbook.lastUnit}` : ''].filter(Boolean).join(' · ')}
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

        {/* 내 정보 (11/11 대표 시안 + H26(95) 누락 금지: 알림 메일 켬/끔 · 담당 강사·수업 링크 · 적립금 내역) */}
        {tab === 'me' && (
          <div className="grid gap-3 px-4 lg:px-0">
            <div>
              <h1 className="text-[22px] font-bold">내 정보</h1>
              <p className="mt-0.5 text-[13px] text-[#6b6880]">수강 정보와 강사님이 작성한 학습 정보</p>
            </div>
            <div className="grid gap-3 lg:grid-cols-2 lg:items-start">
              <div className="grid content-start gap-3">
                <section className={`${card} px-4 pb-1.5 pt-4`}>
                  <div className="flex items-center gap-2.5 pb-2">
                    <span className="grid h-10 w-10 shrink-0 place-items-center rounded-full bg-[#efecfd] text-[16px] font-extrabold text-[#5034b8]">{s.name.slice(0, 1)}</span>
                    <span className="min-w-0">
                      <span className="block text-[17px] font-extrabold">{s.name}님</span>
                      {myTutors && <span className="block text-[13px] text-[#69667c]">담당 강사 · {myTutors}</span>}
                    </span>
                    {enrollText && <span className="ml-auto shrink-0 rounded-full bg-[#e5f5ed] px-2.5 py-1 text-[12px] font-bold text-[#176c45]">{enrollText}</span>}
                  </div>
                  {tzState && (
                    <div className="flex min-h-[52px] items-center justify-between gap-3 border-t border-[#eeecf4] text-[14px]">
                      <span className="text-[#55526a]">시간대</span>
                      <label className="relative inline-flex items-center gap-2 font-semibold">
                        {tzLabel(studentTz)}
                        <span className="rounded-[8px] border border-[#d7d1ef] bg-white px-2 py-1 text-[12px] font-extrabold text-[#4b30b5]">변경 ›</span>
                        <select aria-label="시간대 변경" value={studentTz} disabled={busy}
                          onChange={(e) => e.target.value !== studentTz && saveTimezone({ set: e.target.value })}
                          className="absolute inset-0 h-full w-full cursor-pointer opacity-0">
                          {tzOptions(studentTz, deviceTz).map((z) => <option key={z} value={z}>{tzLabel(z)}</option>)}
                        </select>
                      </label>
                    </div>
                  )}
                  {meetLinks.map(([name, url]) => (
                    <a key={name} href={url!} target="_blank" rel="noreferrer" className="flex min-h-[52px] items-center justify-between gap-3 border-t border-[#eeecf4] text-[14px]">
                      <span className="text-[#55526a]">수업 링크{meetLinks.length > 1 ? ` · ${name} 강사님` : ''}</span>
                      <span className="font-semibold text-[#4b2fd6]">Google Meet ›</span>
                    </a>
                  ))}
                </section>
                {info && (info.level || info.goal || info.style || info.noteUrl) && (
                  <section className={`${card} grid p-4`}>
                    <h2 className="mb-1 text-[15px] font-bold">나의 학습 정보 <span className="text-[12px] font-normal text-[#69667c]">· 강사님 작성</span></h2>
                    {info.level && <InfoBlock label="영어 레벨"><span className="text-[17px] font-extrabold">{info.level}</span></InfoBlock>}
                    {info.goal && <InfoBlock label="학습 목표">{info.goal}</InfoBlock>}
                    {info.style && <InfoBlock label="수업 방식 · 교재">{info.style}</InfoBlock>}
                    {info.noteUrl && (
                      <InfoBlock label="수업 노트">
                        매 수업 내용이 이 노트에 계속 쌓여요.
                        <a href={info.noteUrl} target="_blank" rel="noreferrer" className="mt-2.5 flex min-h-[46px] items-center justify-center rounded-[10px] bg-[#5b3df0] text-[14px] font-extrabold text-white">
                          수업 노트 열기 ↗
                        </a>
                      </InfoBlock>
                    )}
                  </section>
                )}
              </div>
              <div className="grid content-start gap-3">
                {reminders && (
                  <section className={`${card} grid px-4 pb-3 pt-4`}>
                    <h2 className="mb-1 text-[15px] font-bold">이메일 알림 설정</h2>
                    {!reminders.hasEmail && <p className="text-[13px] font-semibold text-[#c0392b]">등록된 이메일이 없어 메일을 받을 수 없어요.</p>}
                    <Switch label="정규 수업" sub="일반 수업 리마인더" on={reminders.regular} disabled={busy} onChange={(v) => saveReminder({ regular: v })} />
                    <Switch label="보강 수업" sub="보강 수업 리마인더" on={reminders.makeup} disabled={busy} onChange={(v) => saveReminder({ makeup: v })} />
                    <p className="mt-1.5 rounded-[9px] bg-[#f7f6fa] px-3 py-2.5 text-[12.5px] text-[#69667c]">수업 취소·확정·시간 변경 등 필수 일정 안내는 알림 설정과 관계없이 발송됩니다.</p>
                  </section>
                )}
                <section className={`${card} px-4 pb-1.5 pt-4`}>
                  <h2 className="mb-1 text-[15px] font-bold">내 수강권</h2>
                  <LinkRow label="현재 코스" value={s.product} />
                  {slotText && (
                    <div className="flex min-h-[52px] w-full items-center justify-between gap-3 border-t border-[#eeecf4] py-2 text-[14px]">
                      <span className="shrink-0 text-[#55526a]">수업 시간</span>
                      <span className="grid min-w-0 gap-0.5 text-right">
                        {slotText.map((g) => (
                          <span key={g.when + g.tutor} className="grid">
                            <span className="font-semibold">{g.when}</span>
                            <span className="text-[13px] text-[#55526a]">{g.tutor}</span>
                          </span>
                        ))}
                      </span>
                    </div>
                  )}
                  <LinkRow label="남은 정규 수업" value={notStarted ? (s.paid ? '수업 일정 준비 중' : '결제 확인 후 시작') : `${left.regular}회`} />
                  {!notStarted && left.other > 0 && <LinkRow label="남은 보강 수업" value={`${left.other}회`} />}
                  <LinkRow label="변경권" value={`${s.creditsLeft}개`} onClick={() => setOverlay({ kind: 'credits' })} />
                  {endDate && <LinkRow label="종료일" value={endDay(endDate)} />}
                  <LinkRow label="결제" value={s.paid ? `결제 완료${s.confirmedOn ? ` (${fmtDate(s.confirmedOn)})` : ''}` : '결제 확인 중'} valueClass={s.paid ? 'font-semibold text-[#13623a]' : 'font-semibold text-[#8a5300]'} onClick={extras && (() => setOverlay({ kind: 'payments' }))} />
                </section>
                <section className={`${card} px-4 pb-1.5 pt-4`}>
                  <h2 className="mb-1 text-[15px] font-bold">적립금 · 보강권</h2>
                  <LinkRow label="적립금 내역" value={won(points.balance)} valueClass="font-bold" onClick={() => setOverlay({ kind: 'points' })} />
                  <LinkRow label="보강권 확인" value={`${openRights.length}개`} onClick={() => setTab('requests')} />
                </section>
              </div>
            </div>
            {props.onLogout && (
              <button type="button" onClick={props.onLogout} className="min-h-[44px] text-left text-[14px] text-[#55526a] underline">
                로그아웃
              </button>
            )}
          </div>
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
          {overlay.kind === 'request' && s.requests.find((r) => r.id === overlay.id) && <RequestDetail r={s.requests.find((r) => r.id === overlay.id)!} busy={busy} onWithdraw={async (id) => { await run(() => actions.withdrawMakeup(id), '신청을 취소했어요.'); }} />}
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
              creditPeriods={s.creditPeriods}
              initialMany={retry?.ids}
              notice={retry?.notice ?? null}
              finalEndDate={s.finalEndDate}
              makeupUntil={s.finalEndDate}
              holidays={holidays}
              regularLeft={regularLessonsLeft(lessons, now)}
              totalLeft={left.total}
              busy={busy}
              onConfirm={confirmCancel}
              onConfirmMany={confirmCancelMany}
              onClose={() => { setRetry(null); setOverlay(null); }}
            />
          )}
          {overlay.kind === 'leave' && (
            <LeaveSheet
              rows={s.leave}
              rights={s.makeupRights}
              requests={s.requests}
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
                key={`${overlay.right.lessonId}${overlay.right.itemId}${overlay.right.compId}`}
                right={s.makeupRights.find((m) => sameRight(m, overlay.right!)) ?? null}
                canceled={overlay.canceled ?? false}
                endDate={endDate}
                load={actions.makeupOptions}
                busy={busy}
                tz={VIEW_TZ}
                noTime={overlay.right.lessonId && noTime.has(overlay.right.lessonId) ? { requestedAt: noTime.get(overlay.right.lessonId) ?? null } : null}
                onNoTime={async (lessonId) => { await run(() => actions.noTimeRequest(lessonId), '요청했어요.'); }}
                onLater={() => setOverlay(null)}
                onSubmit={async (right, slots) => {
                  const v = await run(() => actions.requestMakeup(right, slots), '요청했어요. 강사님 확인 후 최종 확정돼요.');
                  if (v) setOverlay(null);
                }}
              />
            ) : (
              <div className="grid gap-3">
                <div>
                  <h2 className="text-[18px] font-bold">보강할 수업</h2>
                  <p className="mt-0.5 text-[13.5px] text-[#55526a]">보강할 수업을 고르고 날짜를 신청해 주세요.</p>
                </div>
                {openRights.map((m) => (
                  <RightCard key={`${m.lessonId}${m.itemId}${m.compId}`} right={m} withTime={needsTime(m, openRights)} endDate={endDate} onPick={() => setOverlay({ kind: 'makeup', right: m })} />
                ))}
              </div>
            ))}
        </Sheet>
      )}

      {stale && (
        <div role="alert" className="fixed inset-x-4 top-4 z-30 mx-auto max-w-md rounded-[12px] border border-[#f3c2bb] bg-[#fff1ef] px-4 py-3 shadow-lg lg:bottom-24 lg:top-auto">
          <p className="text-[13.5px] text-[#7a1d12]">{stale}</p>
          <button type="button" disabled={busy} onClick={async () => { setBusy(true); try { setView(await actions.reload()); setStale(null); say('다시 읽었어요.'); } catch { setToast('아직 읽지 못했어요. 잠시 뒤 다시 눌러 주세요.'); } finally { setBusy(false); } }}
            className="mt-1.5 min-h-[40px] rounded-[10px] bg-[#b3261e] px-3 text-[13.5px] font-bold text-white disabled:opacity-40">다시 읽기</button>
        </div>
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
    </KstCtx.Provider>
  );
}

/** 보강할 수업 카드: 날짜 · 사유 한 줄 · 신청 기한 · [보강 날짜 선택] (2026-11-07 대표 시안) */
function RightCard({ right, withTime, endDate, onPick }: { right: MakeupRight; withTime: boolean; endDate: KstDate | null; onPick: () => void }) {
  const until = rightUntil(right, endDate);
  const comp = !!right.compId;
  return (
    <div className={`${card} grid gap-1 px-4 pb-3 pt-3.5 ${comp ? 'border-[#d9d0ff] bg-[#f8f6ff]' : ''}`}>
      <div className="flex items-start justify-between gap-2">
        <p className="text-[16px] font-bold">{rightTitle(right, withTime)}</p>
        {comp && <Icon d="M20 12v10H4V12M2 7h20v5H2zM12 22V7M12 7H7.5a2.5 2.5 0 0 1 0-5C11 2 12 7 12 7zM12 7h4.5a2.5 2.5 0 0 0 0-5C13 2 12 7 12 7z" className="mt-0.5 h-5 w-5 shrink-0 text-[#5b3df0]" />}
      </div>
      <p className="text-[13.5px] text-[#55526a]">{rightReason(right)}</p>
      {until && <p className="text-[13.5px] text-[#55526a]">{until}</p>}
      <button type="button" onClick={onPick} className="mt-1.5 min-h-[44px] rounded-[12px] bg-[#1d1b2b] text-[14.5px] font-bold text-white">
        {comp ? '보상수업 날짜 선택' : '보강 날짜 선택'}
      </button>
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

// 강사 휴무 안내 (A안 한 번에 답, 2026-10-28 대표). 수강생은 강사를 고르지 않음 — 운영진이 정한 대체강사만 보여 줌
function LeaveSheet(props: {
  rows: LeaveRow[];
  rights: MakeupRight[];
  /** 보강 신청 내역 — 신청한 보강의 상태를 신청 내역과 같게 (R-17) */
  requests?: StudentRequest[];
  busy: boolean;
  onProfile: (name: string) => void;
  onAnswer: (a: 'ok' | 'makeup') => void;
  onMakeup: (r: Right) => void;
}) {
  const subs = props.rows.filter((x) => x.choice === 'substitute');
  const waits = props.rows.filter((x) => x.choice === 'wait');
  const ask = subs.filter((x) => x.stage === 'tutor_ok');
  const fixed = subs.filter((x) => x.stage === 'confirmed');
  const off = props.rows[0];
  const offText = off && `${fmtDate(formatInZone(off.offFrom, VIEW_TZ).date)} ~ ${fmtDate(formatInZone(new Date(off.offTo.getTime() - 1), VIEW_TZ).date)}`;
  return (
    <div className="grid gap-3.5">
      <div>
        <h2 className="text-[18px] font-bold">담당 강사님 휴무 안내</h2>
        {offText && <p className="mt-0.5 text-[13px] text-[#55526a]">휴무 {offText}</p>}
      </div>
      {/* 확정·답변 필요·기존 강사 보강을 따로 (대표 11/2: 확정 2회·미정 1회인데 '3회 대체수업'으로 보임) */}
      <p className="rounded-[14px] bg-[#efeaff] px-4 py-3 text-[15px] font-semibold leading-relaxed text-[#2b1c7a]">
        {[fixed.length && `대체강사 확정 ${fixed.length}회`, ask.length && `답변 필요 ${ask.length}회`, waits.length && `기존 강사님과 보강 ${waits.length}회`].filter(Boolean).join(' · ')}
      </p>
      {fixed.length > 0 && (() => {
        // R-23: 회의실 링크가 있는 수업만 '아래 링크', 없으면 카톡으로 보냄
        const withLink = fixed.filter((x) => meetRoomUrl(x.subMeetUrl)).length;
        const text = withLink === fixed.length ? '⚠️ 대체강사 수업은 아래 링크에서 진행됩니다.'
          : withLink === 0 ? `⚠️ 대체강사 수업 링크는 수업 전에 카카오톡으로 보내 드려요.`
          : '⚠️ 대체강사 수업은 아래 링크에서 진행됩니다. 링크가 없는 수업은 수업 전에 카카오톡으로 보내 드려요.';
        return <p className="rounded-[14px] bg-[#ffd66b] px-4 py-3 text-[15px] font-bold leading-snug text-[#1b1442]">{text}</p>;
      })()}
      {[{ title: '대체강사 수업 · 확정', list: fixed }, { title: '대체강사 수업 · 답변 필요', list: ask }].filter((x) => x.list.length > 0).map(({ title, list }) => (
        <section key={title} className={`${card} grid gap-1 p-4`}>
          <h3 className="text-[15px] font-bold">{title}</h3>
          {list.map((x) => (
            <div key={x.id} className="flex items-center justify-between gap-2 border-b border-[#eeecf4] py-2.5 last:border-0">
              <span>
                <span className="block text-[15px] font-semibold">{whenText(x.startsAt)}</span>
                <span className="block text-[13px] text-[#55526a]">{x.subTutor} 강사님</span>
              </span>
              {x.stage === 'confirmed' ? (
                <span className="grid justify-items-end gap-1">
                  <span className="rounded-full bg-[#e3f5ea] px-2.5 py-1 text-[12px] font-semibold text-[#13623a]">확정 ✓</span>
                  {meetRoomUrl(x.subMeetUrl) ? (
                    <a href={meetRoomUrl(x.subMeetUrl)!} target="_blank" rel="noreferrer" className="text-[13px] font-bold text-[#4b2fd6] underline">
                      {x.subTutor} 강사님 수업 링크
                    </a>
                  ) : (
                    <span className="text-right text-[12px] text-[#55526a]">{MEET_MISSING_KO}</span>
                  )}
                </span>
              ) : (
                <button type="button" onClick={() => props.onProfile(x.subTutor ?? '')} className="min-h-[40px] rounded-[10px] border border-[#d9d5e8] px-3 text-[13px] font-semibold">
                  프로필 보기
                </button>
              )}
            </div>
          ))}
          {list === ask && (
            <div className="mt-2 grid gap-2">
              <button type="button" disabled={props.busy} onClick={() => props.onAnswer('ok')} className="min-h-[52px] rounded-[14px] bg-[#5b3df0] text-[16px] font-bold text-white disabled:opacity-50">
                {ask.length > 1 ? `좋아요, ${ask.length}회 모두 이대로 할게요` : '좋아요, 이대로 할게요'}
              </button>
              <button type="button" disabled={props.busy} onClick={() => props.onAnswer('makeup')} className="min-h-[50px] rounded-[14px] border border-[#5b3df0] text-[15px] font-bold text-[#4b2fd6] disabled:opacity-50">
                {ask.length > 1 ? `${ask.length}회 모두 기존 강사님과 보강할게요` : '기존 강사님과 보강할게요'}
              </button>
            </div>
          )}
        </section>
      ))}
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
                ) : r.requested ? (() => {
                  // 신청 내역의 같은 신청과 같은 상태로 (R-17: 전부 불가 → '다른 일정 조율 중', 강사 답 뒤 → '최종 확정 대기')
                  const q = (props.requests ?? []).find((x) => x.kind === 'makeup' && !x.compId && ((r.lessonId && x.lessonId === r.lessonId) || (r.itemId && x.itemId === r.itemId)) && (x.status === 'tutor_reviewing' || x.status === 'admin_reviewing' || x.status === 'rescheduling'));
                  const st: RequestStatus = q?.status ?? 'tutor_reviewing';
                  return <span className={`rounded-full px-2.5 py-1 text-[12px] font-semibold ${STATUS_STYLE[st]}`}>신청함 · {REQUEST_STATUS_LABEL[st]}</span>;
                })() : (
                  <button type="button" onClick={() => props.onMakeup(r)} className="min-h-[40px] rounded-[10px] bg-[#5b3df0] px-3 text-[13px] font-bold text-white">
                    보강 날짜 고르기
                  </button>
                )}
              </div>
            );
          })}
        </section>
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
  /** 나중에 고르기 = 창 닫기 */
  onLater: () => void;
  /** 지금 보여 주는 시간대 (운영자 보기 전환 때 달력 날짜를 다시 맞춤) */
  tz: string;
  /** 종료 5일 이내 강사 취소 보강만 (아니면 null → 링크 없음). requestedAt = 이미 누름 */
  noTime?: { requestedAt: string | null } | null;
  onNoTime?: (lessonId: string) => void;
}) {
  const [opts, setOpts] = useState<MakeupOption[] | null>(null);
  const [err, setErr] = useState<string | null>(null);
  const [day, setDay] = useState<string | null>(null);
  const [month, setMonth] = useState<string | null>(null);
  const [picked, setPicked] = useState<Date[]>([]);
  // 고른 날짜의 실제 시각 (운영자 보기에서 시간대를 바꾸면 날짜·달을 이 시각 기준으로 다시 맞춤 — QA 11/8)
  const [anchor, setAnchor] = useState<Date | null>(null);
  const { right, load } = props;
  useEffect(() => {
    const a = picked[picked.length - 1] ?? anchor;
    if (!a) return;
    const d = kst(a).date;
    setDay((cur) => (cur ? d : cur));
    setMonth(d.slice(0, 7));
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [props.tz]);

  useEffect(() => {
    if (!right) return;
    load(right)
      .then((o) => {
        const available = right.timeKnown === false ? o : o.filter((slot) => slot.startsAt.getTime() !== right.originalAt.getTime());
        setOpts(available);
        if (available[0]) setMonth(kst(available[0].startsAt).date.slice(0, 7));
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
              onClick={() => { setDay(d); setAnchor(byDay.get(d)?.[0] ?? null); }}
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
    </section>
  );

  return (
    <div className="grid gap-3.5">
      {props.canceled && <p className="rounded-[12px] bg-[#e3f5ea] px-3.5 py-2.5 text-[15px] font-bold text-[#13623a]">✓ {rightText(right)} 수업을 취소했어요</p>}
      <h2 className="text-[18px] font-bold">{right.compId ? '보상수업 날짜 고르기' : '보강 날짜 고르기'}</h2>
      <div className={`${card} grid gap-0.5 px-4 py-3`}>
        {right.compId ? (
          <>
            <p className="text-[15px] font-bold">{rightTitle(right, true)}</p>
            <p className="text-[13.5px] text-[#55526a]">{rightReason(right)}</p>
          </>
        ) : (
          <>
            <p className="text-[13px] text-[#55526a]">{rightReason(right)}</p>
            <p className="text-[16px] font-bold">{rightText(right)}</p>
          </>
        )}
        {rightUntil(right, props.endDate) && <p className="text-[13.5px] text-[#55526a]">{rightUntil(right, props.endDate)}</p>}
      </div>
      <p className="text-[14px] leading-relaxed text-[#55526a]">이 수업을 대신할 날짜를 최대 {MAKEUP_SLOTS_MAX}개 골라 주세요. 강사님이 확인하면 확정돼요.</p>
      <p className="text-[14px] font-semibold">{right.tutor ? `${right.tutor} 강사님의 가능한 시간입니다.` : '담당 강사님의 가능한 시간입니다.'}</p>
      {err && <p className="text-[14px] text-[#b3261e]">{err}</p>}
      {!opts && !err && <p className="text-[14px] text-[#55526a]">불러오는 중…</p>}
      {opts && opts.length === 0 && <p className="text-[14px]">가능한 날짜가 없어요. 카카오톡으로 문의해 주세요.</p>}
      {opts && opts.length > 0 && (
        <div className="grid gap-3.5 lg:grid-cols-2 lg:items-start">
          {calendar}
          <div className="grid gap-3">
            <section className={`${card} grid gap-2 p-3`}>
              <p className="text-[14px] font-bold">{day ? `${fmtDate(day as KstDate)}(${wdOf(day)})` : '날짜를 골라 주세요'}</p>
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
              <p className="text-[13px] leading-relaxed text-[#55526a]">최대 {MAKEUP_SLOTS_MAX}개 옵션을 고를 수 있어요.</p>
              {picked.map((t) => (
                <div key={t.getTime()} className="flex items-center justify-between rounded-[10px] border border-[#e6e3ef] px-3 py-2 text-[14px]">
                  <span className="font-semibold">{whenText(t)}</span>
                  <button type="button" aria-label="빼기" onClick={() => toggle(t)} className="h-8 w-8 text-[16px] text-[#55526a]">
                    ×
                  </button>
                </div>
              ))}
              {/* 시작까지 6시간 미만 시간을 고르면 경고만, 신청은 그대로 (대표 11/9) */}
              {picked.some((t) => t.getTime() - Date.now() < CONFIRMED.changeNoticeHours * 3600_000) && (
                <p className="text-[13.5px] leading-relaxed text-[#b3261e]">수업 시작까지 6시간 미만 남았습니다. 강사가 요청을 제때 확인하지 못할 수 있으며, 강사가 확정해야 수업이 진행됩니다.</p>
              )}
              <button
                type="button"
                disabled={picked.length === 0 || props.busy}
                onClick={() => props.onSubmit(right, picked)}
                className="min-h-[50px] rounded-[14px] bg-[#5b3df0] text-[16px] font-bold text-white disabled:opacity-40"
              >
                {right.compId ? '보상수업 신청하기' : '보강 신청하기'}
              </button>
              <LaterButton onLater={props.onLater} />
            </section>
          </div>
        </div>
      )}
      {!(opts && opts.length > 0) && <LaterButton onLater={props.onLater} />}
      {props.noTime && right.lessonId && (
        props.noTime.requestedAt ? (
          <button type="button" disabled className="mx-auto min-h-[40px] rounded-[10px] bg-[#ecebf1] px-4 text-[13.5px] font-semibold text-[#6b6880]">요청함 ✓</button>
        ) : (
          <button type="button" disabled={props.busy} onClick={() => props.onNoTime?.(right.lessonId!)} className="mx-auto min-h-[40px] px-3 text-[13.5px] text-[#55526a] underline">
            맞는 시간이 없어요
          </button>
        )
      )}
    </div>
  );
}

/** 대표 11/3: 취소하면 바로 보강 고르기로 넘어옴 → 지금 안 고르고 창 닫기. 보강 권리는 홈 '할 일'에 그대로 남음 */
function LaterButton({ onLater }: { onLater: () => void }) {
  return (
    <>
      <button type="button" onClick={onLater} className="min-h-[46px] rounded-[14px] border border-[#d9d5e8] bg-white text-[15px] font-semibold text-[#1d1b2b]">
        나중에 고르기
      </button>
      <p className="text-center text-[12px] text-[#6b6880]">나중에 홈 → 보강 날짜 고르기</p>
    </>
  );
}

/** 'YYYY-MM' 달력 칸 (일요일 시작, 앞쪽 빈칸 null) */
function monthCells(month: string): (string | null)[] {
  const first = new Date(`${month}-01T00:00:00Z`);
  const days = new Date(Date.UTC(first.getUTCFullYear(), first.getUTCMonth() + 1, 0)).getUTCDate();
  return [...Array<null>(first.getUTCDay()).fill(null), ...Array.from({ length: days }, (_, i) => `${month}-${String(i + 1).padStart(2, '0')}`)];
}

/** 보강을 캘린더에 더하기 (2026-10-29 대표, 수강생·강사 화면 같은 버튼) */
export function AddToCalendar({ ev, google, file }: { ev: CalendarEvent; google: string; file: string }) {
  const cls = 'inline-flex min-h-[36px] items-center rounded-[10px] border border-[#d9d5e8] bg-white px-2.5 text-[13px] font-semibold text-[#1b1442]';
  return (
    <span className="mt-1.5 flex flex-wrap gap-1.5">
      <a href={googleCalendarUrl(ev)} target="_blank" rel="noreferrer" className={cls}>{google}</a>
      <a href={icsUrl(ev)} className={cls}>{file}</a>
    </span>
  );
}

function NextLesson({ lesson, now, meetUrl, substitute, leaveOpen }: { lesson: StudentLesson | null; now: Date; meetUrl: string | null; substitute: boolean; leaveOpen?: boolean }) {
  const shell = 'grid min-h-[206px] content-start gap-3.5 rounded-[20px] bg-[#1b1442] p-5 text-white lg:min-h-[222px] lg:rounded-[22px] lg:p-6';
  if (!lesson) return (
    <section aria-label="다음 수업" className={shell}>
      <div className="flex min-h-[28px] items-center">
        <span className="text-[13px] font-semibold text-[#c9c0ff]">다음 수업</span>
      </div>
      <p className="text-[26px] font-bold tracking-tight text-white lg:text-[30px]">예정된 수업이 없어요</p>
    </section>
  );
  const k = kst(lesson.startsAt);
  const started = now.getTime() >= lesson.startsAt.getTime();
  const badge = started ? '진행 중' : untilText(now, lesson.startsAt);
  // 11/11 대표 시안: 교재 링크 없음 · '40분 · Maria 강사님 · 정규 수업' 같은 글씨 크기·두께 · '수업 입장' 버튼만
  const kindText = lesson.kind === 'regular' ? '정규 수업' : lesson.kind === 'makeup' ? '보강 수업' : '보상수업';
  return (
    <section aria-label="다음 수업" className={shell}>
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
          {Number(k.md.split('/')[0])}월 {Number(k.md.split('/')[1])}일({k.wd}) {k.time}
        </p>
        <p className="mt-1 text-[14px] font-normal text-[#d8d3f5]">
          {lesson.minutes}분{leaveOpen ? '' : ` · ${lesson.tutorName} 강사님`} · {kindText}
        </p>
      </div>
      {meetUrl && (
        <a href={meetUrl} target="_blank" rel="noreferrer" className="flex min-h-[50px] items-center justify-center gap-2 rounded-[14px] bg-white text-[16px] font-bold text-[#1b1442]">
          <Icon d="M4 6h10a2 2 0 0 1 2 2v8a2 2 0 0 1-2 2H4a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2zM16 10l6-3v10l-6-3z" />
          수업 입장
        </a>
      )}
    </section>
  );
}

// 변경권: 지금 기간과 언제 썼는지 (대표 10/29)
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
        : c.note
          ? `운영진 조정 · ${c.note}`
          : c.delta > 0 ? '운영진이 돌려드림' : 'LMS 시작 전 사용';
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
        <span className="block text-[14px] font-semibold">{reqTitle(r)}</span>
        <span className="block text-[12px] text-[#6b6880]">
          {r.kind !== 'makeup' ? r.note
            : r.status === 'confirmed' && r.confirmedAt ? `${whenText(r.confirmedAt)} 확정`
            : r.status === 'canceled' && r.confirmedAt ? `${whenText(r.confirmedAt)} 보강 수업 취소됨`
            : r.status === 'rescheduling' ? '강사님이 신청한 시간에는 어렵다고 답했어요'
            : `고른 날짜 ${r.candidates.length}개`}
        </span>
      </span>
      <span className="flex items-center gap-1.5">
        <span className={`whitespace-nowrap rounded-full px-2.5 py-1 text-[12px] font-semibold ${STATUS_STYLE[r.status]}`}>{REQUEST_STATUS_LABEL[r.status]}</span>
        <span className="text-[#8b88a0]">›</span>
      </span>
    </button>
  );
}

// 누를 곳이 없으면 버튼 모양(›) 없이 글만 (R8)
/**
 * '매주 월·목 오후 10:30–11:20' + 강사 이름 줄 — 정규 일정(KST 요일·시각)을 다음 실제 날짜로 바꿔 보여 주는 시간대(VIEW_TZ)의 요일·시각으로.
 * 같은 시각·강사끼리 요일을 묶고, 다르면 줄을 나눔
 */
function regularSlotText(slots: RegularSlot[], now: Date): { when: string; tutor: string }[] | null {
  if (slots.length === 0) return null;
  const today = formatInZone(now, 'Asia/Seoul').date;
  const groups = new Map<string, { days: number[]; text: string; tutor: string }>();
  for (const x of slots) {
    const base = new Date(`${today}T12:00:00+09:00`);
    const add = (x.weekday - base.getUTCDay() + 7) % 7;
    const d = new Date(base.getTime() + add * 86_400_000);
    const ymd = formatInZone(d, 'Asia/Seoul').date;
    const start = new Date(`${ymd}T${x.timeKst}:00+09:00`);
    const end = new Date(start.getTime() + x.minutes * 60_000);
    const a = formatInZone(start, VIEW_TZ);
    const text = ampmRange(a.time, formatInZone(end, VIEW_TZ).time);
    const key = `${text}|${x.tutor}`;
    const day = new Date(`${a.date}T00:00:00Z`).getUTCDay();
    const g = groups.get(key) ?? { days: [], text, tutor: x.tutor };
    g.days.push(day);
    groups.set(key, g);
  }
  const order = (d: number) => (d + 6) % 7;   // 월요일부터
  return [...groups.values()].map((g) => ({
    when: `매주 ${[...new Set(g.days)].sort((p, q) => order(p) - order(q)).map((d) => '일월화수목금토'[d]).join('·')} ${g.text}`,
    tutor: g.tutor,
  }));
}

/** '시드니로' / '런던으로' (받침 있으면 '으로', ㄹ 받침은 '로') */
function withRo(w: string) {
  const c = w.charCodeAt(w.length - 1) - 0xac00;
  if (c < 0 || c > 11171) return `${w}로`;
  const jong = c % 28;
  return `${w}${jong === 0 || jong === 8 ? '로' : '으로'}`;
}
/** '내 정보' 시간대 목록: 지금 시간대 · 기기 시간대 · 수강생이 많은 곳 시간대 (중복 없이) */
const tzOptions = (cur: string, device: string | null) => [...new Set([cur, ...(device ? [device] : []), ...ZONE_ROWS.map((r) => r.timezone)])];
/** 'Australia/Sydney' → '시드니·캔버라 (호주)', 목록에 없으면 '리스본 (Europe/Lisbon)' */
const tzLabel = (tz: string) => {
  const n = zoneName(tz);
  return n === tz ? `${koZoneCity(tz)} (${tz})` : n;
};

/** 홈 '나의 누적 학습 시간' (11/11 대표: 시간대 띠처럼 가볍게, 숫자는 작게) */
function LearnedBand({ minutes }: { minutes: number }) {
  const h = Math.floor(minutes / 60), m = minutes % 60;
  const text = h && m ? `${h}시간 ${m}분` : h ? `${h}시간` : `${m}분`;
  // 11/11 대표: 한 줄로, 시간은 문장 바로 뒤에 (오른쪽 끝으로 떨어뜨리지 않음)
  return (
    <p aria-label="나의 학습 누적 시간" className="w-fit rounded-[14px] bg-[#f4f1ff] px-3.5 py-2 text-[13px] leading-snug text-[#5c4b95]">
      <b className="font-extrabold text-[#1d1b2b]">나의 학습 누적 시간</b> <b className="whitespace-nowrap text-[14px] font-extrabold text-[#4d34bc]">{text}</b> 영어 공부에는 비법이 없고 꾸준히 접할수록 늘어요. 벌써 이만큼이나 쌓였어요🔥
    </p>
  );
}

function InfoBlock({ label, children }: { label: string; children: React.ReactNode }) {
  return (
    <div className="grid border-t border-[#eeecf4] py-2.5 first-of-type:border-0">
      <span className="mb-0.5 text-[12px] font-bold text-[#69667c]">{label}</span>
      <span className="text-[14px]">{children}</span>
    </div>
  );
}

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

function Switch({ label, sub, on, disabled, onChange }: { label: string; sub?: string; on: boolean; disabled: boolean; onChange: (v: boolean) => void }) {
  return (
    <button
      type="button"
      role="switch"
      aria-checked={on}
      disabled={disabled}
      onClick={() => onChange(!on)}
      className="flex min-h-[56px] items-center justify-between border-t border-[#eeecf4] py-2 text-left text-[15px] first-of-type:border-0"
    >
      <span className="grid">
        <span className="text-[14px] font-bold">{label}</span>
        {sub && <span className="text-[12.5px] text-[#69667c]">{sub}</span>}
      </span>
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
    <div className="fixed inset-0 z-20 flex flex-col bg-black/40" onClick={onClose}>
      <div className="flex min-h-0 flex-1 items-end justify-center lg:items-center">
      <div role="dialog" aria-modal className={`max-h-[min(90dvh,100%)] w-full ${wide ? 'max-w-[520px] lg:max-w-[860px]' : 'max-w-[520px]'} overflow-y-auto rounded-t-[22px] bg-[#f6f5fa] p-5 lg:rounded-[22px]`} onClick={(e) => e.stopPropagation()}>
        <div className="mb-3 flex items-center gap-2">
          <div className="min-w-0 flex-1">
            <ZoneBar />
          </div>
          <button type="button" aria-label="닫기" onClick={onClose} className="-mr-2 flex h-11 w-11 shrink-0 items-center justify-center rounded-full text-[22px] leading-none text-[#55526a] hover:bg-[#ebe8f5]">
            ✕
          </button>
        </div>
        {children}
      </div>
      </div>
    </div>
  );
}

function RequestDetail({ r, busy, onWithdraw }: { r: StudentRequest; busy?: boolean; onWithdraw?: (id: string) => void }) {
  const [asking, setAsking] = useState(false);
  // 강사 확정 전에만 신청 취소 (대표 11/9)
  const open = r.kind === 'makeup' && (r.status === 'tutor_reviewing' || r.status === 'admin_reviewing' || r.status === 'rescheduling');
  // 신청 → 강사 확인 → 최종 확정(운영진). 지금 단계는 주황, 끝난 단계는 보라 (11/3 점검 ②: 누가 확인 중인지)
  const steps = r.status === 'rescheduling' ? ['신청', '강사 확인', '일정 조율'] : ['신청', '강사 확인', '최종 확정'];
  const at = r.status === 'tutor_reviewing' ? 1 : r.status === 'admin_reviewing' || r.status === 'rescheduling' ? 2 : 3;
  return (
    <div className="grid gap-3.5">
      <h2 className="text-[18px] font-bold">{reqTitle(r)}</h2>
      <section className={`${card} grid gap-3.5 p-4`}>
        <div className="flex items-center justify-between">
          <span className="text-[13px] text-[#55526a]">지금 상태</span>
          <span className={`rounded-full px-3 py-1 text-[13px] font-semibold ${STATUS_STYLE[r.status]}`}>{REQUEST_STATUS_LABEL[r.status]}</span>
        </div>
        {/* 상황별 안내 (추가 요청 6): 지금 무엇을 기다리는지, 다음에 누가 연락하는지 */}
        {r.status === 'tutor_reviewing' && <p className="text-[13.5px] leading-relaxed text-[#55526a]">강사님이 확인하고 확정하면 일정에 바로 들어가요.</p>}
        {r.status === 'admin_reviewing' && <p className="text-[13.5px] leading-relaxed text-[#55526a]">강사님 확인이 끝났어요. 운영진이 최종 확정하면 일정에 바로 들어가요.</p>}
        {r.status === 'rescheduling' && <p className="text-[13.5px] leading-relaxed text-[#7a1d12]">강사님이 고른 날짜에는 어렵다고 했어요. 운영진이 다른 일정을 조율해서 카카오톡으로 알려 드릴게요. 따로 하실 일은 없어요.</p>}
        {r.status === 'canceled' && <p className="text-[13.5px] leading-relaxed text-[#55526a]">확정됐던 보강 수업이 취소됐어요. 취소 때 안내된 규칙(변경권·보강 가능 여부)에 따라 처리됐어요.</p>}
        {r.status !== 'expired' && r.status !== 'withdrawn' && <ol className="flex gap-1.5">
          {steps.map((t, i) => (
            <li key={t} className="flex-1 text-center">
              <div className={`h-1.5 rounded ${i < at ? 'bg-[#5b3df0]' : i === at ? 'bg-[#f0a33a]' : 'bg-[#e6e3ef]'}`} />
              <span className={`mt-1.5 block text-[12px] ${i <= at ? 'font-semibold' : 'text-[#8b88a0]'}`}>{t}</span>
            </li>
          ))}
        </ol>}
      </section>
      {r.candidates.length > 0 && (
        <section className={`${card} grid gap-2.5 p-4`}>
          <h3 className="text-[15px] font-bold">내가 고른 날짜</h3>
          {r.candidates.map((d, i) => (
            <div key={i} className="flex items-center gap-3 rounded-[12px] border border-[#e6e3ef] px-3.5 py-3">
              <span className="text-[12px] font-bold text-[#5b3df0]">{i + 1}</span>
              <span className="text-[16px] font-bold">{whenText(d)}</span>
            </div>
          ))}
        </section>
      )}
      <section className={`${card} grid gap-2 p-4 text-[14px]`}>
        {r.originalAt && (
          <div className="flex justify-between gap-3">
            <span className="shrink-0 text-[#55526a]">원래 수업</span>
            <span className="text-right">
              {r.originalTimeKnown === false ? kstDateOnly(r.originalAt) : whenText(r.originalAt)}
              {r.compensation ? ' · 강사 사정으로 취소' : ''}
            </span>
          </div>
        )}
        {(r.tutor || r.originalTutor) && (
          <div className="flex justify-between gap-3">
            <span className="shrink-0 text-[#55526a]">담당 강사</span>
            <span className="text-right">{r.tutor ?? r.originalTutor}</span>
          </div>
        )}
        {r.status === 'confirmed' && r.confirmedAt && (
          <div className="flex justify-between gap-3">
            <span className="shrink-0 text-[#55526a]">확정 날짜</span>
            <b className="text-right">{whenText(r.confirmedAt)}</b>
          </div>
        )}
        {r.note && (
          <div className="flex justify-between gap-3">
            <span className="shrink-0 text-[#55526a]">내용</span>
            <span className="text-right">{r.note}</span>
          </div>
        )}
        <div className="flex justify-between">
          <span className="text-[#55526a]">신청한 날</span>
          <span className="text-right">{whenText(r.createdAt)}</span>
        </div>
      </section>
      {open && onWithdraw && (
        asking ? (
          <section className={`${card} grid gap-2 p-4`}>
            <p className="text-[15px] font-bold">신청을 취소할까요?</p>
            <button type="button" disabled={busy} onClick={() => onWithdraw(r.id)} className="min-h-[48px] rounded-[14px] bg-[#5b3df0] text-[15px] font-bold text-white disabled:opacity-50">신청 취소하기</button>
            <button type="button" disabled={busy} onClick={() => setAsking(false)} className="min-h-[44px] rounded-[14px] border border-[#d9d5e8] text-[14px] font-semibold text-[#55526a]">돌아가기</button>
          </section>
        ) : (
          <button type="button" onClick={() => setAsking(true)} className="mx-auto min-h-[40px] px-3 text-[13.5px] text-[#55526a] underline">신청 취소</button>
        )
      )}
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

/** 수업 하나를 취소하면 어떻게 되는지 한 줄 (목록 줄 아래 · 여러 수업 요약 공통) */
const outcomeText = (d: { ok: boolean; consumesLesson?: boolean; timing?: string; usesCredit?: boolean }) =>
  !d.ok ? '취소 불가' : d.consumesLesson ? (d.timing === 'late' ? '6시간 이내 · 1회 차감 · 보강 없음' : '변경권 없음 · 1회 차감 · 보강 없음')
    : d.usesCredit ? '변경권 1개 · 보강 가능' : '변경권 그대로 · 보강 가능';

function CancelSheet(props: {
  lessons: StudentLesson[];
  lessonId: string | null;
  onPick: (id: string) => void;
  now: Date;
  /** 지금 기간 변경권 (기간 목록이 없는 옛 DB 용) */
  creditsLeft: number;
  /** 모든 기간의 변경권 — 수업 날짜가 속한 기간으로 판정 (R-12) */
  creditPeriods?: CreditPeriod[];
  /** 중간에 멈춘 뒤 다시 고른 상태로 열 때 (R-02): 남은 수업 id + 안내 */
  initialMany?: string[];
  notice?: string | null;
  finalEndDate: KstDate;
  /** 보강 기한 = 수강 종료일 */
  makeupUntil: KstDate;
  holidays: ReadonlySet<KstDate>;
  regularLeft: number;
  totalLeft: number;
  busy: boolean;
  onConfirm: (l: StudentLesson) => void;
  /** 여러 수업 한 번에 (추가 요청 2) */
  onConfirmMany?: (ls: StudentLesson[]) => void;
  onClose: () => void;
}) {
  const [checked, setChecked] = useState(false);
  const [many, setMany] = useState<Set<string>>(() => new Set(props.initialMany ?? []));
  // 한 번 누르면 그 수업 하나만 취소, 여러 수업은 '여러 수업 한 번에 취소'를 눌러야 체크 칸이 나옴 (대표 11/8)
  const [multi, setMulti] = useState(() => (props.initialMany?.length ?? 0) > 0);
  const [manyChecked, setManyChecked] = useState(false);
  const lesson = props.lessons.find((l) => l.id === props.lessonId);
  const periods = props.creditPeriods ?? [];
  /** 그 수업 날짜가 속한 기간의 변경권 (R-12) */
  const creditsOf = (l: StudentLesson) => creditsForDate(periods, instantToKstDate(l.startsAt), props.creditsLeft);

  if (!lesson) {
    // 여러 수업 고르기: 시간순으로, 각 수업이 속한 기간의 변경권을 차례로 차감해 미리 계산 (DB 도 같은 순서·같은 기간 규칙, R-12)
    const picked = props.lessons.filter((l) => many.has(l.id));
    const plan = planCancelMany(picked, { now: props.now, finalEndDate: props.finalEndDate, creditsLeft: props.creditsLeft, creditPeriods: periods, holidays: props.holidays });
    const { uses, consumes, makeups } = plan;
    const bad = plan.items.filter((x) => !x.decision.ok);
    const toggleMany = (id: string) => setMany((prev) => { const n = new Set(prev); if (n.has(id)) n.delete(id); else n.add(id); return n; });
    return (
      <div className="grid gap-3">
        <h2 className="text-[18px] font-bold">{multi ? '취소할 수업을 모두 골라 주세요' : '취소할 수업을 골라 주세요'}</h2>
        {props.lessons.map((l) => {
          const on = many.has(l.id);
          const alone = planCancelMany([l], { now: props.now, finalEndDate: props.finalEndDate, creditsLeft: props.creditsLeft, creditPeriods: periods, holidays: props.holidays }).items[0]?.decision;
          const showCheck = multi && !!props.onConfirmMany && l.kind !== 'compensation';
          return (
            <div key={l.id} className={`${card} flex min-h-[56px] items-center gap-2 pl-3 pr-4 ${on ? 'border-[#5b3df0] bg-[#f6f3ff]' : ''}`}>
              {showCheck && (
                <input type="checkbox" aria-label={`${whenText(l.startsAt)} 함께 취소`} checked={on} onChange={() => toggleMany(l.id)} className="h-5 w-5 shrink-0 accent-[#5b3df0]" />
              )}
              <button type="button" onClick={() => (showCheck ? toggleMany(l.id) : props.onPick(l.id))} className="flex min-h-[56px] min-w-0 flex-1 items-center justify-between gap-2 py-1.5 text-left">
                <span className="min-w-0">
                  <span className="block text-[15px] font-semibold">{whenText(l.startsAt)}</span>
                  {/* 누르면 어떻게 되는지 미리 (설명 문장 대신) */}
                  {alone && <span className={`block text-[12.5px] ${alone.ok && alone.consumesLesson ? 'font-bold text-[#b3261e]' : 'text-[#55526a]'}`}>{outcomeText(alone)}</span>}
                </span>
                {!showCheck && <span className="shrink-0 text-[#6b6880]">›</span>}
              </button>
            </div>
          );
        })}
        {props.onConfirmMany && props.lessons.some((l) => l.kind !== 'compensation') && (
          <button type="button" onClick={() => { setMulti(!multi); if (multi) { setMany(new Set()); setManyChecked(false); } }}
            className="min-h-[44px] text-center text-[14px] font-bold text-[#3a22b0]">
            {multi ? '한 개씩 취소 ›' : '여러 수업 한 번에 취소 ›'}
          </button>
        )}
        {props.notice && <p className="rounded-[12px] border border-[#f3c2bb] bg-[#fff1ef] px-3.5 py-2.5 text-[13.5px] leading-relaxed text-[#7a1d12]">{props.notice}</p>}
        {picked.length > 0 && props.onConfirmMany && (
          <section className={`${card} sticky bottom-0 z-10 grid gap-2 p-3.5 shadow-[0_-6px_16px_rgba(27,20,66,0.12)]`}>
            <p className="text-[15px] font-bold">선택한 수업 {picked.length}회 · 변경권 {uses}개 사용</p>
            {/* 기간별 잔여 (R-12): 수업이 속한 기간마다 차감 전 → 후 */}
            <p className="text-[12.5px] text-[#55526a]">
              {plan.periods.map((p) => `${p.start && p.end ? `${fmtDate(p.start)}~${fmtDate(p.end)} 기간 ` : ''}변경권 ${p.before}개 → ${p.after}개`).join(' · ')}
            </p>
            <ul className="grid gap-1 text-[13px] text-[#1d1b2b]">
              {plan.items.map(({ lesson: l, decision: d }) => (
                <li key={l.id} className="flex justify-between gap-2">
                  <span>{whenText(l.startsAt)}</span>
                  <b className={d.ok && d.consumesLesson ? 'text-[#b3261e]' : ''}>{outcomeText(d)}</b>
                </li>
              ))}
            </ul>
            {/* R-04: 보강 권리가 생기는 수업이 있을 때만 보강 신청 안내 */}
            <p className="text-[12.5px] text-[#55526a]">취소 뒤 남은 수업 {props.totalLeft}회 → {props.totalLeft - consumes}회{makeups ? ` (보강 ${makeups}회 포함). 보강 날짜는 취소 뒤 ‘보강 신청’에서 골라 주세요.` : '.'}</p>
            {consumes > 0 && (
              <label className="flex min-h-[44px] items-start gap-2.5 text-[14px] leading-normal">
                <input type="checkbox" checked={manyChecked} onChange={(e) => setManyChecked(e.target.checked)} className="mt-0.5 h-5 w-5 accent-[#b3261e]" />
                {consumes}회는 보강 없이 수업이 차감된다는 것을 확인했어요
              </label>
            )}
            <button type="button" disabled={props.busy || bad.length > 0 || (consumes > 0 && !manyChecked)} onClick={() => props.onConfirmMany!(picked)}
              className={`min-h-[52px] rounded-[14px] text-[16px] font-bold text-white disabled:opacity-40 ${consumes > 0 ? 'bg-[#b3261e]' : 'bg-[#5b3df0]'}`}>
              {picked.length}회 취소하기
            </button>
            {bad.length > 0 && <p className="text-[12.5px] text-[#b3261e]">취소할 수 없는 수업이 있어요. 체크를 풀어 주세요.</p>}
          </section>
        )}
      </div>
    );
  }

  const creditsNow = creditsOf(lesson);   // 그 수업 날짜가 속한 기간의 변경권 (R-12)
  const d = cancelPreview({ lesson, now: props.now, finalEndDate: props.finalEndDate, creditsLeft: creditsNow, holidays: props.holidays }, null);
  const title = `${whenText(lesson.startsAt)} 수업을 취소할까요?`;

  if (!d.ok) {
    const msg =
      d.reason === 'policy_pending' ? '보상수업 변경·취소는 카카오톡으로 문의해 주세요.' : d.reason === 'already_started' ? '이미 시작한 수업은 취소할 수 없어요.' : '수강기간이 지난 수업이에요.';
    return (
      <div className="grid gap-3">
        <h2 className="text-[18px] font-bold">{title}</h2>
        <p className="text-[14px]">{msg}</p>
      </div>
    );
  }

  const needsCheck = d.consumesLesson; // 수업이 차감되면 한 번 더 확인
  const late = d.timing === 'late';
  // 정보 줄이기 (대표 11/8): 평소와 다른 것만 보여 줌 — 수업이 차감될 때만 '수업 횟수', 변경권을 쓸 때만 '변경권'
  const rows: [string, string][] = [
    ...(d.consumesLesson ? [['수업 횟수', '1회 차감'] as [string, string]] : []),
    ...(d.usesCredit ? [['변경권', `1개 사용 (${creditsNow}개 → ${creditsNow - 1}개)`] as [string, string]] : []),
    ['보강', d.makeupAllowed ? `~${endDay(props.makeupUntil)}까지 가능` : '불가'],
    ...(d.consumesLesson ? [['변경권', late ? '그대로 (차감 안 됨)' : '없음'] as [string, string]] : []),
  ];

  return (
    <div className="grid gap-3.5">
      <h2 className="text-[19px] font-bold">{late ? '수업 시작까지 6시간 이내예요. 그래도 취소할까요?' : title}</h2>
      <section className={`grid gap-2 rounded-[14px] p-3.5 text-[14px] leading-normal ${needsCheck ? 'border border-[#f3c2bb] bg-[#fff1ef] text-[#7a1d12]' : 'bg-[#f1eefc]'}`}>
        {rows.map(([a, b]) => (
          <div key={a} className="flex justify-between gap-3">
            <span className={`shrink-0 ${needsCheck ? 'text-[#7a1d12]' : ''}`}>{a}</span>
            <b className={`text-right ${needsCheck ? 'text-[#7a1d12]' : ''}`}>{b}</b>
          </div>
        ))}
      </section>
      {late && <p className="text-[14px] leading-relaxed">그래도 미리 알려주시면 강사님이 기다리지 않아도 돼요.</p>}
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
