'use client';

// 신규 수강생 등록 (2026-10-18 대표 최종 시안 — C안 신청서 불러오기 + A안 상세 입력·스케줄)
// - PC: 왼쪽 수강생 정보·희망 조건·결제, 오른쪽 강사·주간 캘린더(1·2단계) → 수업 정보·결제(3) → 최종 확인(4)
// - 휴대폰: 1/4 ~ 4/4 단계. 모든 입력은 이 화면 상태 하나에 있어서 이전 단계로 가도 그대로
// - 저장은 한 번에 (DB 함수 admin_register_student). 같은 요청 번호라 여러 번 눌러도 1번만 생김
// - 실제로 저장에 성공했을 때만 '등록 완료'. 미리보기(가상 데이터)는 저장하지 않음

import Link from 'next/link';
import ApplicationPicker from './ApplicationPicker';
import { useEffect, useMemo, useState } from 'react';
import DateInput from '../../DateInput';
import { checkLessonList, firstLessonDateOnOrAfter, issueText, type CellState, type PlanIssue } from '@/lms/rules/booking';
import { ampmKo, instantToKstDate, kstToInstant, weekdayOf, type KstDate } from '@/lms/rules/dates';
import { buildLessons, lessonPayload, needsLessonList, type LessonDate } from '@/lms/rules/lessons';
import { courseName } from '@/lms/rules/period';
import type { RegularSlot } from '@/lms/rules/schedule';
import { CONFIRMED } from '@/lms/rules/policy';
import {
  checkDraft,
  checkPayment,
  draftFromForm,
  EMPTY_DRAFT,
  EMPTY_PAYMENT,
  firstDateBase,
  firstDateWarnings,
  newRequestId,
  payLabels,
  planSummary,
  savePayload,
  slotProblem,
  wishText,
  type Draft,
  type FormResponse,
  type Payment,
  type RegTutor,
} from '@/lms/admin/registration';
import { mdw } from '@/lms/admin/students';
import { dayLabel, diffFromKst, weekOf } from '@/lms/admin/schedule';
import { eunNeun, findCity, findCountry, manyZones, searchCities, searchCountries, searchZones, suggestTimezone, zoneName } from '@/lms/admin/places';
import { AdminHeader } from '../../ui';
import { proposalMessage, type PlanView } from '@/lms/admin/confirm';
import type { PlanActions } from '@/lms/admin/confirm-live';
import PlanCard, { TimeRows, type PlanHandlers } from '../../PlanCard';
import { FinalLessons, ScheduleStepMobile, ScheduleStepPc } from './ScheduleStep';
import { Badge, Card, EMPTY_FILTER, Field, inputCls, Legend, nowLocal, ProfileSheet, SearchPick, slotLocal, slotText, TutorPicker, WeekCalendar, wishWindows, type TutorFilter } from './parts';

export type SaveResult =
  | {
      kind: 'saved';
      studentCode: string;
      lessons: number;
      status: string;
      repeated: boolean;
      planId: string | null;
      planState: 'proposed' | 'confirmed' | null;
      tutorNoticeId: string | null;
      studentNoticeId: string | null;
    }
  | { kind: 'preview' }
  | { kind: 'error'; message: string; conflicts?: { date: string; time: string; reason: string }[] };

type Props = {
  nowIso: string;
  demo: boolean;
  applications: FormResponse[];
  applicationsNote?: string;
  tutors: RegTutor[];
  save: (requestId: string, payload: ReturnType<typeof savePayload>) => Promise<SaveResult>;
  sameEmail: (email: string) => Promise<{ code: string; name_ko: string }[]>;
  /** 실제 데이터: 일정안 제안 보냄·확정·안내 보냄 기록 (DB 함수). 미리보기는 없음 → 화면 안에서만 */
  planActions?: PlanActions;
};

const STEPS = ['수강생 정보\n(신청서 불러오기)', '강사 매칭', '수업 일정', '최종 확인'];
const HINT: Record<PlanIssue['reason'], string> = {
  tutor_makeup: '그날 보강을 옮기거나 첫 수업일을 다음 주로',
  tutor_regular: '다른 시간을 고르세요 (매주 겹치면 이 시간은 불가)',
  tutor_time_off: '휴무 날짜 — 첫 수업일 조정 또는 강사와 확인',
  tutor_hold: '다른 수강생이 종료일 오후 11:59까지 재등록할 수 있는 시간 — 다른 시간을 고르거나 마감 뒤에',
  break: '앞뒤 수업과 10분 휴식 필요 — 30분 당기거나 늦추기',
  student: '수강생의 다른 수업과 겹침',
  outside_availability: '강사 가능 시간 밖 — 강사와 확인 (서머타임 변경일 확인)',
};
const won = (n: number | null) => (n === null ? '-' : `${n.toLocaleString('ko-KR')}원`);
const product = (d: Draft) => (d.durationMin && d.weeklyCount && d.weeks ? `${d.durationMin}분 · 주${d.weeklyCount}회 · ${courseName(d.weeks)}` : '상품 미정');
// 수강 기간: 3개월(12주) · 84일 (POL-PER-01 '1개월 = 4주 기준', 계산은 28일 단위 그대로)
const termText = (weeks: number) => `${courseName(weeks)} · ${weeks * 7}일`;

export default function NewStudent({ nowIso, demo, applications, applicationsNote, tutors, save, sameEmail, planActions }: Props) {
  const now = useMemo(() => new Date(nowIso), [nowIso]);
  const today = instantToKstDate(now);
  const [step, setStep] = useState(1);
  const [appRef, setAppRef] = useState<string | null>(null);
  const [draft, setDraft] = useState<Draft>(EMPTY_DRAFT);
  const [editing, setEditing] = useState(true);
  /** 등록 방법 (QA C-01): Google Form 신청서 / 신청서 없이 직접 — 고른 방법에 필요한 칸만 보임 */
  const [source, setSource] = useState<'form' | 'manual'>('form');
  const [showRaw, setShowRaw] = useState(false);
  const [tutorId, setTutorId] = useState<string | null>(null);
  const [filter, setFilter] = useState<TutorFilter>(EMPTY_FILTER);
  const [weekStart, setWeekStart] = useState<KstDate>(today);
  const [slots, setSlots] = useState<RegularSlot[]>([]);
  const [firstPick, setFirstPick] = useState<KstDate | ''>('');
  const [pay, setPay] = useState<Payment>(EMPTY_PAYMENT);
  const [requestId, setRequestId] = useState(newRequestId);
  const [saving, setSaving] = useState(false);
  const [result, setResult] = useState<SaveResult | null>(null);
  const [planView, setPlanView] = useState<PlanView | null>(null);
  // 저장하면서 제안 문구를 복사했는지 (복사 ≠ 보냄, B-02 — 보낸 시각은 [강사에게 보냈어요]로만 기록)
  const [copiedProposal, setCopiedProposal] = useState(false);
  const [toast, setToast] = useState('');
  const [profile, setProfile] = useState<RegTutor | null>(null);
  const [dupes, setDupes] = useState<{ code: string; name_ko: string }[]>([]);
  const [tried, setTried] = useState(false);
  const [tzWhy, setTzWhy] = useState(''); // 시간대를 국가·도시로 자동 추천했으면 그 이유, 직접 골랐으면 ''

  const app = applications.find((a) => a.ref === appRef) ?? null;
  const tutor = tutors.find((t) => t.id === tutorId) ?? null;
  const week = useMemo(() => weekOf(weekStart), [weekStart]);
  const wish = useMemo(() => wishWindows(draft.wishes, draft.timezone), [draft.wishes, draft.timezone]);
  const duration = draft.durationMin ?? 50;
  const problems = checkDraft(draft);
  const prob = (f: keyof Draft) => (tried ? problems.find((p) => p.field === f)?.text : undefined);
  const locked = !editing;
  const set = <K extends keyof Draft>(k: K, v: Draft[K]) => setDraft((d) => ({ ...d, [k]: v }));
  // 국가·도시가 바뀌면 시간대 다시 추천. 추천이 없으면 자동으로 넣었던 시간대만 비우고, 직접 고른 시간대는 그대로
  function setPlace(country: string, city: string) {
    const s = suggestTimezone(country, city);
    setDraft((d) => ({ ...d, country, city, timezone: s.timezone || (tzWhy ? '' : d.timezone) }));
    setTzWhy(s.timezone ? s.why : '');
  }
  function setCountry(country: string) {
    const c = findCity(draft.city);
    setPlace(country, c && c.country !== country ? '' : draft.city); // 다른 나라 도시였으면 비움
  }

  useEffect(() => {
    if (!toast) return;
    const t = setTimeout(() => setToast(''), 2600);
    return () => clearTimeout(t);
  }, [toast]);

  // 같은 이메일 수강생 확인 (알려 주기만 — 자동 연결·병합 안 함, POL-AC-04)
  useEffect(() => {
    const email = draft.email.trim();
    if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) return setDupes([]);
    const t = setTimeout(() => sameEmail(email).then(setDupes).catch(() => setDupes([])), 400);
    return () => clearTimeout(t);
  }, [draft.email, sameEmail]);

  function loadApp(ref: string) {
    const a = applications.find((x) => x.ref === ref);
    if (!a) return;
    setAppRef(ref);
    const d = draftFromForm(a);
    setDraft(d);
    setTzWhy(suggestTimezone(d.country, d.city).why);
    setEditing(false);
    setPay({ ...EMPTY_PAYMENT, payerName: a.payerName, method: a.paymentMethod ?? null });
    setSlots([]);
    setFirstPick('');
    if (a.startWish && /^\d{4}-\d{2}-\d{2}$/.test(a.startWish)) setWeekStart(a.startWish < today ? today : a.startWish);
  }
  function manual() {
    setSource('manual');
    setAppRef(null);
    setDraft(EMPTY_DRAFT);
    setTzWhy('');
    setEditing(true);
    setSlots([]);
    setFirstPick('');
  }

  // 정규 시간 고르기: 같은 요일은 바꾸기, 주 횟수를 넘으면 안내
  function toggle(date: KstDate, time: string, state: CellState) {
    const wd = weekdayOf(date);
    const same = slots.find((s) => s.weekday === wd);
    if (same && same.time === time) return setSlots(slots.filter((s) => s !== same));
    if (same) return setSlots(slots.map((s) => (s === same ? { weekday: wd, time } : s)).sort(bySlot));
    if (draft.weeklyCount && slots.length >= draft.weeklyCount) return setToast(`주 ${draft.weeklyCount}회예요. 먼저 고른 시간을 하나 빼 주세요.`);
    if (state === 'makeup') setToast('그날만 보강이 있어요. 등록기간 전체 검사에서 그 날짜를 따로 알려 드려요.');
    if (state === 'off') setToast('그날 강사 휴무예요. 등록기간 전체 검사에서 그 날짜를 따로 알려 드려요.');
    setSlots([...slots, { weekday: wd, time }].sort(bySlot));
  }

  // 3단계 직접 입력: 요일 누르기 = 넣기/빼기 (시간은 이미 고른 다른 요일의 시간을 그대로), 요일별 시간 고르기
  function toggleDay(wd: number) {
    const same = slots.find((s) => s.weekday === wd);
    if (same) return setSlots(slots.filter((s) => s !== same));
    if (draft.weeklyCount && slots.length >= draft.weeklyCount) return setToast(`주 ${draft.weeklyCount}회예요. 먼저 고른 요일을 하나 빼 주세요.`);
    setSlots([...slots, { weekday: wd, time: slots.find((s) => s.time)?.time ?? '' }].sort(bySlot));
  }
  function setDayTime(wd: number, time: string) {
    setSlots(slots.map((s) => (s.weekday === wd ? { ...s, time } : s)));
  }

  // 첫 수업일 후보는 등록 당일부터 (2026-11-06 대표 결정, H26(58)). 오늘 정규 시각이 이미 지났으면 내일부터
  const suggested = useMemo(() => {
    const base = draft.startWish && draft.startWish > today ? draft.startWish : firstDateBase(today, now, slots);
    return firstLessonDateOnOrAfter(base, slots.map((s) => s.weekday));
  }, [draft.startWish, today, now, slots]);
  // 첫 수업일은 어느 날이든 (2026-11-06 대표, H26(60)·(61)). 정규 요일이 아니면 그날이 1회로 들어감 (src/lms/rules/lessons.ts)
  const firstDate = firstPick || suggested;
  const slotErr = tutor ? slotProblem(slots, draft.weeklyCount) ?? (slots.some((s) => !s.time) ? '수업 시간을 골라 주세요' : null) : null;

  // 특정 수업 날짜 변경: 기본 목록(정규 시간·첫 수업일·기간)이 바뀌면 지난 변경은 버림
  const editBasis = JSON.stringify([slots, firstDate, draft.weeks, draft.weeklyCount]);
  const [editState, setEditState] = useState<{ basis: string; map: Record<KstDate, LessonDate> }>({ basis: '', map: {} });
  const edits = useMemo(() => (editState.basis === editBasis ? editState.map : {}), [editState, editBasis]);
  function setEdit(key: KstDate, to: LessonDate | null) {
    const map = { ...edits };
    if (to) map[key] = to;
    else delete map[key];
    setEditState({ basis: editBasis, map });
  }

  const lessonPlan = useMemo(
    () => (tutor && !slotErr && firstDate && draft.weeks && draft.weeklyCount ? buildLessons({ firstDate, weeks: draft.weeks, weeklyCount: draft.weeklyCount, slots, edits }) : null),
    [tutor, slotErr, firstDate, draft.weeks, draft.weeklyCount, slots, edits],
  );
  // 충돌 검사: 기존 규칙 그대로 (다른 수업·보강·휴무·휴식 10분·강사 가능 시간) — 회차마다
  const issues = useMemo(
    () => (lessonPlan && tutor && draft.durationMin ? checkLessonList({ lessons: lessonPayload(lessonPlan), durationMin: draft.durationMin, tutorBusy: tutor.busy, availability: tutor.availability }) : []),
    [lessonPlan, tutor, draft.durationMin],
  );
  const plan = lessonPlan && lessonPlan.lessons.length ? { issues, lessons: lessonPlan.lessons } : null;
  // 첫 수업이 오늘인데 그 시각이 이미 지났으면 안내만 (막지 않음, H26(60))
  const firstLesson = lessonPlan?.lessons[0];
  const todayPassed = !!firstLesson && firstLesson.date === today && kstToInstant(firstLesson.date, firstLesson.time) <= now;
  const summary = planSummary(draft, lessonPlan?.startDate ?? firstDate ?? (draft.startWish || null));
  const payErr = checkPayment(pay);
  const paid = pay.status === 'confirmed';
  const blockers = [
    ...problems.map((p) => p.text),
    ...(paid && tutor && slotErr ? [slotErr] : []),
    ...(paid && plan && plan.issues.length ? [`일정 충돌 ${plan.issues.length}건을 먼저 해결해 주세요`] : []),
    ...payErr,
    ...(!summary ? ['첫 수업일(또는 희망 시작일)을 정해 주세요'] : []),
    ...(paid && tutor && lessonPlan ? lessonPlan.problems : []),
  ];

  function go(n: number) {
    if (n > 1 && problems.length) {
      setTried(true);
      setStep(1);
      return setToast('수강생 정보에서 빨간 칸을 먼저 채워 주세요.');
    }
    setStep(n);
    window.scrollTo({ top: 0 });
  }

  // 저장하면서 강사·시간을 정했으면 일정안이 생김 (H22). 화면에 보일 일정안 모양
  const draftPlan: PlanView | null =
    paid && tutor && summary && slots.length && !slotErr && draft.durationMin
      ? {
          planId: '',
          state: 'proposed',
          studentNameEn: draft.nameEn.trim(),
          studentPlace: [draft.country, draft.city].filter(Boolean).join(' '),
          studentTz: draft.timezone || 'Asia/Seoul',
          tutorName: tutor.name,
          tutorPlace: tutor.country,
          tutorTz: tutor.timezone,
          slots,
          startDate: summary.startDate,
          endDate: summary.endDate,
          lessons: summary.lessons,
          lessonList: lessonPlan && needsLessonList(lessonPlan) ? lessonPayload(lessonPlan) : null,
          durationMin: draft.durationMin,
          proposalSentAt: null,
          confirmedAt: null,
          tutorNotice: null,
          studentNotice: null,
        }
      : null;

  async function submit(tutorAccepted = false, copyProposal = false) {
    if (saving || blockers.length || !summary) return;
    // 강사 제안 문구는 누른 순간 복사 (휴대폰은 저장을 기다린 뒤에는 복사가 막힘). 저장이 실패하면 보내지 말라고 안내
    let copied = false;
    if (copyProposal && draftPlan) {
      try {
        await navigator.clipboard.writeText(proposalMessage(draftPlan));
        copied = true;
      } catch {
        copied = false;
      }
    }
    setSaving(true);
    try {
      const r = await save(requestId, savePayload(draft, slots, tutor?.id ?? null, summary.startDate, pay, tutorAccepted, draftPlan?.lessonList ?? null));
      setResult(r);
      if (!draftPlan) return;
      const now = new Date();
      if (r.kind === 'preview' || r.kind === 'saved') setCopiedProposal(copied);
      if (r.kind === 'preview') {
        setPlanView(
          tutorAccepted
            ? { ...draftPlan, planId: 'preview', state: 'confirmed', confirmedAt: now, tutorNotice: { id: 'pv-t', status: 'pending', sentAt: null }, studentNotice: { id: 'pv-s', status: 'pending', sentAt: null } }
            : { ...draftPlan, planId: 'preview', proposalSentAt: null },
        );
      } else if (r.kind === 'saved' && r.planId) {
        if (r.planState === 'confirmed') {
          setPlanView({
            ...draftPlan,
            planId: r.planId,
            state: 'confirmed',
            confirmedAt: now,
            tutorNotice: r.tutorNoticeId ? { id: r.tutorNoticeId, status: 'pending', sentAt: null } : null,
            studentNotice: r.studentNoticeId ? { id: r.studentNoticeId, status: 'pending', sentAt: null } : null,
          });
        } else {
          // 복사만으로는 보낸 것으로 기록하지 않음 (B-02). 실제로 보낸 뒤 [강사에게 보냈어요]
          setPlanView({ ...draftPlan, planId: r.planId, proposalSentAt: null });
        }
      } else if (r.kind === 'error' && copied) {
        setToast('제안 문구는 복사됐지만 저장되지 않았어요 — 강사에게 보내지 마세요.');
      }
    } finally {
      setSaving(false);
    }
  }

  // 저장 뒤 일정안 카드 처리 (실제: DB 함수 / 미리보기: 화면 안에서만)
  const planHandlers: PlanHandlers = {
    confirm: async () => {
      if (!planView) return;
      if (planActions && !demo) {
        const r = await planActions.confirm(planView.planId);
        setPlanView({ ...planView, state: 'confirmed', confirmedAt: new Date(), tutorNotice: { id: r.tutor_notice_id, status: 'pending', sentAt: null }, studentNotice: { id: r.student_notice_id, status: 'pending', sentAt: null } });
      } else setPlanView({ ...planView, state: 'confirmed', confirmedAt: new Date(), tutorNotice: { id: 'pv-t', status: 'pending', sentAt: null }, studentNotice: { id: 'pv-s', status: 'pending', sentAt: null } });
    },
    decline: async () => {
      if (!planView) return;
      if (planActions && !demo) await planActions.decline(planView.planId);
      setPlanView(null);
      setToast('이 안을 닫았어요. 처리할 일에 신규 매칭으로 남아요.');
    },
    proposalSent: async () => {
      if (!planView) return;
      const at = planActions && !demo ? new Date(await planActions.proposalSent(planView.planId)) : new Date();
      setPlanView({ ...planView, proposalSentAt: planView.proposalSentAt ?? (isNaN(at.getTime()) ? new Date() : at) });
    },
    noticeSent: async (who) => {
      if (!planView) return;
      const n = who === 'tutor' ? planView.tutorNotice : planView.studentNotice;
      if (!n) return;
      if (planActions && !demo) await planActions.noticeSent(n.id);
      const sent = { ...n, status: 'sent' as const, sentAt: n.sentAt ?? new Date() };
      setPlanView(who === 'tutor' ? { ...planView, tutorNotice: sent } : { ...planView, studentNotice: sent });
    },
  };

  function startNew() {
    setResult(null);
    setPlanView(null);
    setRequestId(newRequestId());
    manual();
    setTutorId(null);
    setPay(EMPTY_PAYMENT);
    setStep(1);
  }

  // ---------- 화면 조각 ----------
  const studentCard = (
    <Card
      title="1. 수강생 정보"
      badge={app ? <Badge tone="green">신청서 연동 완료</Badge> : source === 'manual' ? <Badge tone="gray">직접 입력</Badge> : <Badge tone="gray">신청서 고르기 전</Badge>}
    >
      <div className="mb-3 grid grid-cols-2 gap-1.5" role="group" aria-label="등록 방법">
        {([['form', '구글폼 신청서로 등록'], ['manual', '신청서 없이 직접 등록']] as const).map(([k, label]) => (
          <button key={k} type="button" aria-pressed={source === k}
            onClick={() => { if (k === source) return; if (k === 'manual') manual(); else setSource('form'); }}
            className={`min-h-[44px] rounded-[10px] border px-2 text-[14px] font-semibold ${source === k ? 'border-[#7d5ffb] bg-[#efebff] text-[#5b3fe0]' : 'border-[#e6e3ef] bg-white text-[#1d1b2b]'}`}>
            {label}
          </button>
        ))}
      </div>
      {source === 'form' && (
        <>
          <ApplicationPicker applications={applications} selected={appRef} onSelect={loadApp} />
          {app && (
            <div className="mb-3 flex gap-2">
              <button type="button" onClick={() => setShowRaw(true)} className="min-h-[44px] shrink-0 whitespace-nowrap rounded-[10px] border border-[#e6e3ef] px-3 text-[13.5px] font-semibold text-[#1d1b2b]">
                원본 보기
              </button>
            </div>
          )}
          {applicationsNote && <p className="-mt-1 mb-3 text-[12.5px] text-[#6b6880]">{applicationsNote}</p>}
        </>
      )}
      <div className="grid grid-cols-2 gap-3">
        <Field label="이름(한글)" problem={prob('nameKo')}>
          <input readOnly={locked} value={draft.nameKo} onChange={(e) => set('nameKo', e.target.value)} className={inputCls(locked, !!prob('nameKo'))} />
        </Field>
        <Field label="영문 이름" problem={prob('nameEn')}>
          <input readOnly={locked} value={draft.nameEn} onChange={(e) => set('nameEn', e.target.value)} className={inputCls(locked, !!prob('nameEn'))} />
        </Field>
        <Field full label="이메일 (로그인용)" problem={prob('email')}>
          <input readOnly={locked} type="email" value={draft.email} onChange={(e) => set('email', e.target.value)} className={inputCls(locked, !!prob('email'))} />
        </Field>
        <Field full label="휴대폰 (해외: 카카오톡 ID)">
          <input readOnly={locked} value={draft.phone} onChange={(e) => set('phone', e.target.value)} className={inputCls(locked)} />
        </Field>
        <Field label="거주 국가">
          <SearchPick
            locked={locked}
            value={draft.country}
            placeholder="예: 호주, Australia"
            search={(q) => [{ label: q.trim() ? undefined : '자주 쓰는 나라', items: searchCountries(q).map((c) => ({ key: c.ko, main: c.ko, sub: c.en, pick: () => setCountry(c.ko) })) }]}
            onFree={setCountry}
          />
          {draft.country && !findCountry(draft.country) && <span className="mt-1 block text-[12px] text-[#9a5b00]">목록에 없는 나라 (친 그대로 저장) — 시간대는 직접 골라 주세요</span>}
        </Field>
        <Field label="도시">
          <SearchPick
            locked={locked}
            value={draft.city}
            placeholder="예: 멜버른, Melbourne"
            search={(q) => [{ label: findCountry(draft.country) ? `${draft.country}의 도시` : undefined, items: searchCities(q, draft.country).map((c) => ({ key: `${c.country}-${c.ko}`, main: c.ko, sub: `${c.country} · ${c.en}`, pick: () => setPlace(c.country, c.ko) })) }]}
            onFree={(t) => setPlace(draft.country, t)}
          />
          {draft.city && !findCity(draft.city) && <span className="mt-1 block text-[12px] text-[#9a5b00]">목록에 없는 도시 (친 그대로 저장)</span>}
        </Field>
        <Field wide label="사는 곳 시간대 · 현재 시각" problem={prob('timezone')}>
          <SearchPick
            value={draft.timezone ? zoneName(draft.timezone) : ''}
            bad={!!prob('timezone')}
            placeholder="예: 멜버른, 시드니, Sydney"
            search={(q) => {
              const pick = (z: string) => () => {
                set('timezone', z);
                setTzWhy('');
              };
              const r = searchZones(q);
              const sub = (z: string) => `${z} · 지금 ${nowLocal(z, now)} · ${diffFromKst(now, z)}`;
              return [
                { items: r.rows.map((x) => ({ key: x.timezone, main: zoneName(x.timezone), sub: sub(x.timezone), pick: pick(x.timezone) })) },
                { label: '그 밖의 시간대 (영어 이름)', items: r.more.map((z) => ({ key: z, main: z, sub: sub(z), pick: pick(z) })) },
              ];
            }}
          />
          {draft.timezone ? (
            <span className={`mt-1 block text-[12.5px] ${tzWhy ? 'text-[#1e7a46]' : 'text-[#6b6880]'}`}>
              {draft.timezone} · 지금 {nowLocal(draft.timezone, now)} · {diffFromKst(now, draft.timezone)}
              {tzWhy && ` · ${tzWhy}`}
            </span>
          ) : manyZones(draft.country) ? (
            <span className="mt-1 block text-[12.5px] text-[#9a5b00]">{eunNeun(draft.country)} 시간대가 여럿이라 도시를 고르면 자동으로 들어가요</span>
          ) : (
            <span className="mt-1 block text-[12.5px] text-[#6b6880]">한국어(멜버른·시드니)나 영어(Melbourne)로 검색</span>
          )}
        </Field>
      </div>
      {dupes.length > 0 && (
        <p className="mt-3 rounded-[10px] bg-[#fff6e6] px-3 py-2 text-[13px] text-[#7a4a00]">
          같은 이메일의 기존 수강생이 있어요: {dupes.map((x) => `${x.code} ${x.name_ko}`).join(', ')}. 자동으로 연결하지 않아요 — 재등록이면 그 수강생 화면에서 처리하세요.
        </p>
      )}
      <div className="mt-3 grid grid-cols-2 gap-2">
        {source === 'manual' ? <span /> : <button type="button" onClick={() => setEditing((v) => !v)} className={`min-h-[44px] rounded-[10px] border text-[14px] font-semibold ${editing ? 'border-[#7d5ffb] bg-[#efebff] text-[#5b3fe0]' : 'border-[#cfc4ff] text-[#5b3fe0]'}`}>
          {editing ? '수정 끝내기' : '✎ 신청서 내용 수정'}
        </button>}
        <Field label="" wide={false}>
          <textarea value={draft.memo} onChange={(e) => set('memo', e.target.value)} placeholder="추가 메모 (운영자만 봄)" rows={1} className="min-h-[44px] w-full rounded-[10px] border border-[#e6e3ef] px-3 py-2.5 text-[14px] text-[#1d1b2b]" />
        </Field>
      </div>
    </Card>
  );

  const pick = (k: 'durationMin' | 'weeklyCount' | 'weeks', opts: readonly number[], unit: (n: number) => string) => (
    <select disabled={locked} value={draft[k] ?? ''} onChange={(e) => set(k, (e.target.value ? Number(e.target.value) : null) as never)} className={`${inputCls(locked, !!prob(k))} min-h-[38px] text-[14px]`}>
      <option value="">확인 필요</option>
      {opts.map((n) => (
        <option key={n} value={n}>
          {unit(n)}
        </option>
      ))}
    </select>
  );
  const row = (label: string, v: React.ReactNode) => (
    <div className="grid grid-cols-[96px_1fr] items-center gap-2 border-b border-[#f0eef6] py-2 last:border-0">
      <span className="text-[13.5px] text-[#6b6880]">{label}</span>
      <span className="text-[14px] text-[#1d1b2b]">{v}</span>
    </div>
  );
  const wishCard = (
    <Card title="수업 희망 조건" badge={app ? <span className="text-[13px] text-[#6b6880]">(신청서 내용)</span> : null} action={<button type="button" onClick={() => setEditing((v) => !v)} className="rounded-[8px] bg-[#efebff] px-3 py-1.5 text-[13px] font-semibold text-[#5b3fe0]">{editing ? '완료' : '수정'}</button>}>
      {row('수업 형태', '1:1 화상')}
      {row(
        '희망 요일·시간',
        draft.wishes.length ? (
          <>
            {wishText(draft.wishes)} <span className="text-[12px] text-[#6b6880]">({draft.timezone || '시간대 미정'} 기준)</span>
          </>
        ) : draft.desiredTime ? (
          <>
            {draft.desiredTime} <Badge tone="amber">예전 형식 · 자유 서술</Badge>
          </>
        ) : (
          <span className="text-[#6b6880]">없음 — 캘린더에서 바로 고르세요</span>
        ),
      )}
      {row('수업 길이', pick('durationMin', CONFIRMED.durations, (n) => `${n}분`))}
      {row('주 횟수', pick('weeklyCount', CONFIRMED.weeklyCounts, (n) => `주 ${n}회`))}
      {row('수강 기간', pick('weeks', CONFIRMED.courseWeeks, (n) => `${n / 4}개월 (${n}주 · ${n * 7}일)`))}
      {row('시작 희망일', <DateInput readOnly={locked} value={draft.startWish} onChange={(v) => set('startWish', v)} aria-label="시작 희망일" className={`${inputCls(locked)} min-h-[38px] text-[14px]`} />)}
      {row('학습 목표', <input readOnly={locked} value={draft.goal} onChange={(e) => set('goal', e.target.value)} className={`${inputCls(locked)} min-h-[38px] text-[14px]`} />)}
    </Card>
  );

  const payBox = (
    <Card title={<span className="flex items-center gap-2">{paid ? '✅' : '⏳'} 입금 확인</span>} badge={paid ? <Badge tone="green">확인 완료</Badge> : <Badge tone="amber">확인 전</Badge>}>
      {paid ? (
        <>
          {row('결제 금액', won(pay.amount))}
          {row(payLabels(pay.method).date, pay.paidOn ? mdw(pay.paidOn) : '-')}
          {row('방법', pay.method === 'card_link' ? '아임웹 카드' : '계좌이체')}
        </>
      ) : (
        <p className="text-[13.5px] leading-relaxed text-[#6b6880]">결제·입금 확인 전에는 수강생 정보와 수강권(결제 대기)만 저장하고 강사·정규 일정은 확정하지 않아요. 확인은 4단계에서 기록해요.</p>
      )}
    </Card>
  );

  const calendarCard = (
    <Card title="3. 강사 스케줄 확인 및 수업 시간 선택">
      <div className="mb-3">
        <Legend />
      </div>
      {tutor ? (
        <>
          <WeekCalendar tutor={tutor} week={week} today={today} slots={slots} onToggle={toggle} wish={wish} studentTz={draft.timezone} durationMin={duration} onWeek={setWeekStart} />
          <div className="mt-3 flex flex-wrap items-center gap-2 rounded-[12px] bg-[#f6f5fb] px-3 py-2.5">
            <b className="text-[14px] text-[#1d1b2b]">선택한 시간</b>
            {slots.length ? slots.map((s) => <Badge key={s.weekday} tone="purple">{slotText(s)}</Badge>) : <span className="text-[13.5px] text-[#6b6880]">캘린더 칸을 눌러 고르세요</span>}
            <span className="text-[13.5px] text-[#6b6880]">· {product(draft)}</span>
            {slotErr && slots.length > 0 && <span className="text-[13px] text-[#b3261e]">{slotErr}</span>}
          </div>
          {plan && <PlanResult issues={plan.issues} count={plan.lessons.length} />}
        </>
      ) : (
        <p className="py-8 text-center text-[14px] text-[#6b6880]">위에서 강사를 고르면 그 강사의 주간 일정이 보여요.</p>
      )}
    </Card>
  );

  const tutorInfo = tutor && (
    <Card title="선택한 강사 정보" action={<button type="button" onClick={() => setProfile(tutor)} className="min-h-[38px] rounded-[10px] border border-[#cfc4ff] px-3 text-[13px] font-semibold text-[#5b3fe0]">홈페이지 소개 보기</button>}>
      <div className="flex items-center gap-3">
        <span className="flex h-12 w-12 items-center justify-center rounded-full bg-[#efebff] text-[18px] font-bold text-[#5b3fe0]">{tutor.name.slice(0, 1)}</span>
        <div className="text-[14px] text-[#1d1b2b]">
          <b>{tutor.name}</b> · {tutor.country}
          <p className="text-[13px] text-[#6b6880]">
            {tutor.timezone} · 지금 {nowLocal(tutor.timezone, now)} · {diffFromKst(now, tutor.timezone)}
          </p>
        </div>
      </div>
      {slots.length > 0 && firstDate && (
        <p className="mt-2 text-[13px] text-[#6b6880]">
          강사 현지: {slots.filter((s) => s.time).map((s) => `${slotText(s)} → ${slotLocal(s, firstDate, tutor.timezone)}`).join(' · ')}
        </p>
      )}
    </Card>
  );

  const tutorCard = (
    <Card title="2. 강사 선택">
      <TutorPicker tutors={tutors} selectedId={tutorId} onSelect={(id) => (id !== tutorId ? (setTutorId(id), setSlots([])) : null)} week={week} durationMin={duration} wish={wish} filter={filter} setFilter={setFilter} onProfile={setProfile} />
    </Card>
  );

  // 3단계 수업 일정 (2026-11-06 대표 시안 그대로 — PC·휴대폰 따로 구성)
  const scheduleProps = {
    tutor,
    weeklyCount: draft.weeklyCount,
    weeks: draft.weeks,
    slots,
    onToggleDay: toggleDay,
    onDayTime: setDayTime,
    firstDate,
    onFirstDate: (d: KstDate) => setFirstPick(d),
    plan: lessonPlan,
    issues,
    slotErr,
    warnings: [...(todayPassed ? ['오늘 첫 수업 시각이 이미 지났어요 — 그래도 저장할 수 있어요 (지난 시각으로 기록돼요)'] : []), ...(firstDate ? firstDateWarnings(firstDate, today, draft.startWish) : [])],
    onEdit: setEdit,
    onPrev: () => go(2),
    onNext: () => go(4),
  };
  const step3 = (
    <>
      <div className="hidden lg:block">
        <ScheduleStepPc {...scheduleProps} />
      </div>
      <div className="lg:hidden">
        <ScheduleStepMobile {...scheduleProps} />
      </div>
    </>
  );

  const payCard = (
    <Card title="결제·입금 확인">
      <div className="grid grid-cols-2 gap-2">
        {(['confirmed', 'unconfirmed'] as const).map((s) => (
          <button key={s} type="button" aria-pressed={pay.status === s} onClick={() => setPay({ ...pay, status: s })} className={`min-h-[46px] rounded-[10px] border text-[14px] font-semibold ${pay.status === s ? 'border-[#7d5ffb] bg-[#efebff] text-[#5b3fe0]' : 'border-[#e6e3ef] text-[#1d1b2b]'}`}>
            {s === 'confirmed' ? '입금·결제 확인함' : '아직 확인 전'}
          </button>
        ))}
      </div>
      {paid ? (
        <div className="mt-3 grid grid-cols-2 gap-3">
          <Field label="방법">
            <select value={pay.method ?? ''} onChange={(e) => setPay({ ...pay, method: (e.target.value || null) as Payment['method'] })} className={inputCls(false)}>
              <option value="">골라 주세요</option>
              <option value="bank_transfer">계좌이체</option>
              <option value="card_link">아임웹 카드</option>
            </select>
          </Field>
          <Field label="받은 금액 (원)">
            <input inputMode="numeric" value={pay.amount ?? ''} onChange={(e) => setPay({ ...pay, amount: e.target.value ? Number(e.target.value.replace(/\D/g, '')) : null })} className={inputCls(false)} />
            {pay.amount ? <span className="mt-1 block text-[12px] text-[#6b6880]">{won(pay.amount)}</span> : null}
          </Field>
          <Field label={`${payLabels(pay.method).date} (한국 날짜)`}>
            <DateInput value={pay.paidOn} onChange={(v) => setPay({ ...pay, paidOn: v })} aria-label={payLabels(pay.method).date} className={inputCls(false)} />
          </Field>
          <Field label={payLabels(pay.method).payer}>
            <input value={pay.payerName} onChange={(e) => setPay({ ...pay, payerName: e.target.value })} className={inputCls(false)} />
          </Field>
          <Field label="아임웹 주문번호 · 거래 식별값 (있으면)" wide>
            <input value={pay.externalRef} onChange={(e) => setPay({ ...pay, externalRef: e.target.value })} className={inputCls(false)} />
          </Field>
          {payErr.map((e) => (
            <p key={e} className="col-span-2 text-[13px] text-[#b3261e]">
              {e}
            </p>
          ))}
        </div>
      ) : (
        <p className="mt-3 text-[13.5px] leading-relaxed text-[#6b6880]">확인 전이면 수강생·수강권(결제 대기)만 저장해요. 고른 강사·시간은 저장되지 않고, 결제 확인 후 매칭 때 다시 정해요 (POL-OP-13).</p>
      )}
    </Card>
  );

  const step4 = (
    <div className="space-y-4">
    {payCard}
    <Card title="최종 확인">
      {row('수강생', `${draft.nameKo} (${draft.nameEn}) · ${draft.email}`)}
      {row('연락처', draft.phone || '-')}
      {row('사는 곳', `${[draft.country, draft.city].filter(Boolean).join(' ')} · ${draft.timezone} (지금 ${draft.timezone ? nowLocal(draft.timezone, now) : '-'})`)}
      {row('수강 상품', product(draft))}
      {row('결제', paid ? `확인함 · ${pay.method === 'card_link' ? '아임웹 카드' : '계좌이체'} ${won(pay.amount)}` : '확인 전 → 결제 대기로 저장')}
      {row('강사', paid && tutor ? `${tutor.name} (${tutor.country})` : paid ? '미배정 → 신규 매칭 업무로 남음' : '저장 안 함 (결제 확인 후)')}
      {row('정규 시간', draftPlan ? <TimeRows view={draftPlan} /> : '-')}
      {row('첫 수업일', summary ? dayLabel(summary.startDate) + (paid && tutor ? '' : ' (예정)') : '-')}
      {row('수강 기간', summary ? `${dayLabel(summary.startDate)} – ${dayLabel(summary.endDate)}${draft.weeks ? ` · ${termText(draft.weeks)}` : ''}` : '-')}
      {row('만들어질 수업', paid && tutor && summary ? `정규 ${summary.lessons}회` : '없음 (강사 배정 때 생성)')}
      {paid && tutor && lessonPlan && lessonPlan.lessons.length > 0 && <FinalLessons plan={lessonPlan} tutor={tutor} />}
      {dupes.length > 0 && <p className="mt-2 text-[13px] text-[#9a5b00]">같은 이메일 기존 수강생: {dupes.map((x) => x.code).join(', ')} — 새 수강생으로 따로 만들어요 (연결 안 함).</p>}
      {blockers.length > 0 && (
        <ul className="mt-3 space-y-1 rounded-[10px] bg-[#fdecec] px-3 py-2 text-[13px] text-[#b3261e]">
          {blockers.map((b) => (
            <li key={b}>• {b}</li>
          ))}
        </ul>
      )}
      {result && <ResultBox result={result} onNew={startNew} demo={demo} />}
      {planView && (
        <div className="mt-3 rounded-[12px] border border-[#e6e3ef] bg-white p-3">
          <b className="mb-2 block text-[14.5px] text-[#1d1b2b]">{planView.state === 'proposed' ? '강사 답 대기' : '확정 · 양쪽에 안내를 보내 주세요'}</b>
          <PlanCard view={planView} handlers={planHandlers} showTimes={false} proposalCopied={copiedProposal} />
        </div>
      )}
      {!(result?.kind === 'saved') && !(result?.kind === 'preview' && planView) &&
        (draftPlan ? (
          <div className="mt-4 grid gap-2">
            <p className="text-[15px] font-bold text-[#1d1b2b]">강사에게 물어봤나요?</p>
            <details className="rounded-[10px] border border-[#e6e3ef] bg-white px-3 text-[13px]">
                  <summary className="flex min-h-[44px] cursor-pointer list-none items-center font-semibold text-[#4b33c4]">
                    강사 제안 문구 보기<span className="flex-1" /><span aria-hidden className="text-[#6b6880]">⌄</span>
                  </summary>
                  <p className="whitespace-pre-line rounded-[10px] bg-[#f6f5fa] p-2.5 pb-3 text-[#1d1b2b]">{proposalMessage(draftPlan)}</p>
                  <div className="h-2" />
                </details>
            <button type="button" disabled={saving || blockers.length > 0} onClick={() => submit(false, true)} className="min-h-[52px] rounded-[12px] bg-[#7d5ffb] text-[16px] font-bold text-white disabled:bg-[#cfc4ff]">
              {saving ? '저장 중…' : '아직 → 제안 문구 복사'}
            </button>
            <button type="button" disabled={saving || blockers.length > 0} onClick={() => submit(true)} className="min-h-[52px] rounded-[12px] border-[1.5px] border-[#7d5ffb] bg-white text-[16px] font-bold text-[#4b33c4] disabled:opacity-50">
              가능하대요 → 확정
            </button>
            {demo && <p className="text-[12.5px] text-[#6b6880]">미리보기 — 실제로 저장되지 않아요</p>}
          </div>
        ) : (
          <button type="button" disabled={saving || blockers.length > 0} onClick={() => submit()} className="mt-4 min-h-[52px] w-full rounded-[12px] bg-[#7d5ffb] text-[16px] font-bold text-white disabled:bg-[#cfc4ff]">
            {saving ? '저장 중…' : demo ? '저장 (미리보기 — 실제로 저장 안 됨)' : paid ? '등록 저장 (강사 미배정)' : '등록 저장 (결제 대기)'}
          </button>
        ))}
    </Card>
    </div>
  );

  const nextLabel = ['다음: 강사 매칭 →', '다음: 수업 일정 →', '다음: 최종 확인 ›', ''][step - 1];
  const right = step <= 2 ? (
    <div className="space-y-4">
      {tutorCard}
      {calendarCard}
      {tutorInfo}
    </div>
  ) : step === 3 ? (
    step3
  ) : (
    step4
  );

  return (
    <div className="min-h-screen bg-[#f6f5fb] pb-28 lg:pb-10">
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
      {/* 휴대폰 위쪽: ‹ 뒤로(이전 단계, 1단계면 목록) · 단계 (2026-11-06 대표 시안) */}
      <header className="sticky top-0 z-10 border-b border-[#e6e3ef] bg-white lg:hidden">
        <div className="flex items-center gap-1 px-2 py-2">
          {step > 1 ? (
            <button type="button" onClick={() => go(step - 1)} aria-label="이전 단계" className="flex h-10 w-10 items-center justify-center text-[24px] text-[#1d1b2b]">
              ‹
            </button>
          ) : (
            <Link href={demo ? '/lms/admin?demo=1' : '/lms/admin'} aria-label="목록으로" className="flex h-10 w-10 items-center justify-center text-[24px] text-[#1d1b2b]">
              ‹
            </Link>
          )}
          <b className="text-[17px] text-[#1d1b2b]">신규 수강생 등록</b>
        </div>
        <MobileStepper step={step} />
      </header>
      {demo && <p className="mx-4 mt-3 rounded-[12px] bg-[#fff8d6] px-4 py-2.5 text-[13.5px] text-[#5c4a00] lg:mx-7">가상 데이터 미리보기예요. 신청서·강사·일정은 모두 가상이고, 저장을 눌러도 실제로 저장되지 않아요.</p>}

      <p className="mx-4 mt-3 text-[13.5px] text-[#6b6880] lg:mx-7">
        이미 수업 중인 수강생인가요?{' '}
        <Link href={demo ? '/lms/admin/students/import?demo=1' : '/lms/admin/students/import'} className="font-semibold text-[#5b3fe0] underline underline-offset-2">
          기존 수강생 간단 입력 →
        </Link>
      </p>

      <Stepper step={step} onStep={go} />

      <main className={`mx-auto max-w-[1400px] px-4 lg:px-7 ${step === 3 ? '' : 'lg:grid lg:grid-cols-[minmax(360px,420px)_1fr] lg:items-start lg:gap-5'}`}>
        {/* 왼쪽(PC) / 1단계(휴대폰) */}
        <div className={`space-y-4 ${step === 1 ? '' : step === 3 ? 'hidden' : 'hidden lg:block'}`}>
          {studentCard}
          {wishCard}
          <div className="hidden lg:block">{payBox}</div>
        </div>
        {/* 오른쪽(PC) / 2~4단계(휴대폰) */}
        <div className={`mt-3 lg:mt-0 ${step === 1 ? 'hidden lg:block' : ''}`}>
          {right}
          {step < 3 && (
            <div className="mt-4 hidden justify-end gap-2 lg:flex">
              {step > 2 && (
                <button type="button" onClick={() => go(step - 1)} className="min-h-[48px] rounded-[12px] border border-[#e6e3ef] bg-white px-5 text-[15px] text-[#1d1b2b]">
                  이전
                </button>
              )}
              <button type="button" onClick={() => go(step <= 2 ? 3 : 4)} className="min-h-[48px] rounded-[12px] bg-[#7d5ffb] px-6 text-[15px] font-bold text-white">
                {step <= 2 ? '다음: 수업 일정 →' : '다음: 최종 확인 →'}
              </button>
            </div>
          )}
          {step === 4 && (
            <button type="button" onClick={() => go(3)} className="mt-3 hidden min-h-[44px] rounded-[10px] border border-[#e6e3ef] bg-white px-4 text-[14px] text-[#1d1b2b] lg:inline-block">
              ← 이전
            </button>
          )}
        </div>
      </main>

      {/* 휴대폰 아래 버튼 */}
      <div className="fixed inset-x-0 bottom-0 z-10 flex gap-2 border-t border-[#e6e3ef] bg-white px-4 py-3 lg:hidden">
        {step > 1 && (
          <button type="button" onClick={() => go(step - 1)} className="min-h-[50px] rounded-[12px] border border-[#e6e3ef] px-5 text-[15px] text-[#1d1b2b]">
            이전
          </button>
        )}
        {step < 4 && (
          <button type="button" onClick={() => go(step + 1)} className="min-h-[50px] flex-1 rounded-[12px] bg-[#7d5ffb] text-[15px] font-bold text-white">
            {nextLabel}
          </button>
        )}
      </div>

      {showRaw && app && (
        <div role="dialog" aria-modal="true" aria-label="신청서 원본" className="fixed inset-0 z-30 flex items-end justify-center bg-black/40 lg:items-center" onClick={() => setShowRaw(false)}>
          <div className="max-h-[85vh] w-full max-w-[520px] overflow-y-auto rounded-t-[18px] bg-white p-5 lg:rounded-[18px]" onClick={(e) => e.stopPropagation()}>
            <div className="flex items-center">
              <b className="text-[17px] text-[#1d1b2b]">신청서 원본 · {app.ref}</b>
              <span className="flex-1" />
              <button type="button" onClick={() => setShowRaw(false)} aria-label="닫기" className="h-10 w-10 text-[20px] text-[#6b6880]">
                ×
              </button>
            </div>
            <p className="mb-2 text-[12.5px] text-[#6b6880]">수강생이 제출한 그대로예요. 여기서는 고치지 않고, 등록 화면에서 고친 내용만 LMS에 저장돼요.</p>
            {app.raw.map(([k, v]) => (
              <div key={k} className="grid grid-cols-[120px_1fr] gap-2 border-b border-[#f0eef6] py-2 text-[14px]">
                <span className="text-[#6b6880]">{k}</span>
                <span className="whitespace-pre-line text-[#1d1b2b]">{v || '-'}</span>
              </div>
            ))}
          </div>
        </div>
      )}
      {profile && <ProfileSheet tutor={profile} onClose={() => setProfile(null)} />}
      {toast && (
        <div role="status" className="fixed inset-x-4 bottom-24 z-40 mx-auto max-w-[420px] rounded-[12px] bg-[#1d1b2b] px-4 py-3 text-center text-[14px] text-white lg:bottom-8">
          {toast}
        </div>
      )}
    </div>
  );
}

const bySlot = (a: RegularSlot, b: RegularSlot) => ((a.weekday + 6) % 7) - ((b.weekday + 6) % 7);

/** 휴대폰 단계 줄: 끝난 단계는 ✓, 지금 단계만 이름 */
function MobileStepper({ step }: { step: number }) {
  return (
    <ol className="flex items-center gap-1.5 px-4 pb-2.5" aria-label={`${step}/4 단계`}>
      {STEPS.map((label, i) => {
        const n = i + 1;
        const now = n === step;
        return (
          <li key={n} className="flex items-center gap-1.5">
            {i > 0 && <span aria-hidden className="text-[13px] text-[#cfc4ff]">{now ? '⟶' : '›'}</span>}
            <span className={`flex h-6 w-6 items-center justify-center rounded-full text-[12.5px] font-bold ${now ? 'bg-[#5b3fe0] text-white' : n < step ? 'bg-[#e6e3ef] text-[#6b6880]' : 'border border-[#cfc4ff] text-[#6b6880]'}`}>{n}</span>
            {n < step && <span aria-hidden className="text-[12px] text-[#6b6880]">✓</span>}
            {now && <span className="text-[14px] font-bold text-[#5b3fe0]">{label.split('\n')[0]}</span>}
          </li>
        );
      })}
    </ol>
  );
}

function Stepper({ step, onStep }: { step: number; onStep: (n: number) => void }) {
  return (
    <ol className="mx-auto hidden max-w-[900px] grid-cols-4 px-7 py-5 lg:grid">
      {STEPS.map((label, i) => {
        const n = i + 1;
        const on = n === step || (step <= 2 && n <= 2);
        const done = n < step;
        return (
          <li key={label} className="relative flex flex-col items-center text-center">
            {i > 0 && <span className={`absolute right-1/2 top-[15px] h-[2px] w-full ${n <= step ? 'bg-[#7d5ffb]' : 'bg-[#e1dcf5]'}`} />}
            <button type="button" onClick={() => onStep(n)} className={`relative z-[1] flex h-8 w-8 items-center justify-center rounded-full text-[14px] font-bold ${on || done ? 'bg-[#7d5ffb] text-white' : 'bg-[#e4ddff] text-white'}`}>
              {n}
            </button>
            <span className={`mt-1.5 whitespace-pre-line text-[13px] ${on ? 'font-bold text-[#1d1b2b]' : 'text-[#6b6880]'}`}>
              {label}
              {done && step > 2 && <span className="ml-1 text-[#5b3fe0]">✓</span>}
            </span>
          </li>
        );
      })}
    </ol>
  );
}

function PlanResult({ issues, count }: { issues: PlanIssue[]; count: number }) {
  if (issues.length === 0)
    return <p className="mt-3 rounded-[10px] bg-[#e3f6ea] px-3 py-2 text-[13.5px] text-[#1e7a46]">✓ 등록기간 전체 {count}회 모두 충돌 없음 (다른 수업·보강·휴무·휴식 10분·강사 가능 시간 확인)</p>;
  const byDate = new Map<string, PlanIssue[]>();
  for (const i of issues) byDate.set(i.kstDate, [...(byDate.get(i.kstDate) ?? []), i]);
  return (
    <div className="mt-3 rounded-[10px] bg-[#fdecec] px-3 py-2.5">
      <p className="text-[13.5px] font-bold text-[#b3261e]">
        등록기간 {count}회 중 {byDate.size}개 날짜에 충돌 — 해결 전에는 저장할 수 없어요
      </p>
      <ul className="mt-1.5 space-y-1.5">
        {[...byDate].map(([d, list]) => (
          <li key={d} className="text-[13px] text-[#1d1b2b]">
            <b>
              {dayLabel(d)} {list[0].kstTime}
            </b>{' '}
            · {list.map((x) => x.detail).join(' / ')}
            <span className="block text-[12.5px] text-[#6b6880]">해결: {HINT[list[0].reason]}</span>
          </li>
        ))}
      </ul>
    </div>
  );
}

function ResultBox({ result, onNew, demo }: { result: SaveResult; onNew: () => void; demo: boolean }) {
  if (result.kind === 'preview')
    return <p className="mt-3 rounded-[10px] bg-[#fff8d6] px-3 py-2.5 text-[13.5px] text-[#5c4a00]">미리보기라 저장하지 않았어요. 실제 화면에서는 이 내용이 한 번에 저장되고, 성공했을 때만 &lsquo;등록 완료&rsquo;가 보여요.</p>;
  if (result.kind === 'error')
    return (
      <div className="mt-3 rounded-[10px] bg-[#fdecec] px-3 py-2.5 text-[13.5px] text-[#b3261e]">
        저장하지 못했어요 — 아무것도 저장되지 않았어요. {result.message}
        {result.conflicts && (
          <ul className="mt-1 text-[13px] text-[#1d1b2b]">
            {result.conflicts.map((c, i) => (
              <li key={i}>
                • {dayLabel(c.date)} {ampmKo(c.time)} · {issueText(c.reason as PlanIssue['reason'])}
              </li>
            ))}
          </ul>
        )}
      </div>
    );
  return (
    <div className="mt-3 rounded-[12px] bg-[#e3f6ea] px-4 py-3 text-[14px] text-[#1e7a46]">
      <b className="text-[16px] text-[#1e7a46]">✓ 등록 완료 · {result.studentCode}</b>
      <p className="mt-1 text-[#1e7a46]">
        {result.status !== 'confirmed'
          ? '결제 대기로 저장 (강사·수업은 결제 확인 후)'
          : result.planState === 'confirmed'
            ? `결제 확인 · 정규 수업 ${result.lessons}회 생성`
            : result.planState === 'proposed'
              ? '결제 확인 · 강사 답을 받으면 확정해요'
              : '결제 확인 · 강사 미배정 (신규 매칭으로 남음)'}
        {result.repeated && ' · 이미 저장된 요청이라 새로 만들지 않았어요'}
      </p>
      <div className="mt-2 flex gap-2">
        <Link href={`/lms/admin/students/${result.studentCode}${demo ? '?demo=1' : ''}`} className="min-h-[40px] rounded-[10px] bg-white px-3 py-2 text-[13.5px] font-semibold text-[#1d1b2b]">
          수강생 보기
        </Link>
        <button type="button" onClick={onNew} className="min-h-[40px] rounded-[10px] bg-white px-3 text-[13.5px] font-semibold text-[#1d1b2b]">
          다른 수강생 등록
        </button>
      </div>
    </div>
  );
}

