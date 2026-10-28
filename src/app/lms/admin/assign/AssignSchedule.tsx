'use client';

// 이미 저장된 학생에게 강사·시간 고르기 (결제만 저장한 학생, 강사가 '안 된대요' 한 뒤 다른 안)
// 2026-10-22 대표: "너무 복잡하지 않게" → 한 화면: 학생 요약 → 강사 → 주간 칸 → 첫 수업일 → [아직 → 제안 문구 복사] / [가능하대요 → 확정]
// 등록 화면의 강사 고르기·캘린더를 그대로 씀. 저장은 DB 함수 admin_propose_schedule (같은 요청 번호면 1번만)

import Link from 'next/link';
import { useMemo, useState } from 'react';
import { checkRegularPlan, firstLessonDateOnOrAfter, issueText, type CellState } from '@/lms/rules/booking';
import { addDays, instantToKstDate, weekdayOf, type KstDate } from '@/lms/rules/dates';
import { courseName } from '@/lms/rules/period';
import type { CourseWeeks } from '@/lms/rules/policy';
import type { RegularSlot } from '@/lms/rules/schedule';
import { proposalMessage, type PlanView } from '@/lms/admin/confirm';
import type { PlanActions } from '@/lms/admin/confirm-live';
import type { RegTutor } from '@/lms/admin/registration';
import { dayLabel, weekOf } from '@/lms/admin/schedule';
import PlanCard, { TimeRows, type PlanHandlers } from '../PlanCard';
import { Card, EMPTY_FILTER, Legend, ProfileSheet, TutorPicker, WeekCalendar, type TutorFilter } from '../students/new/parts';

export type AssignInfo = {
  enrollmentId: string;
  studentCode: string;
  studentName: string;
  nameEn: string;
  place: string; // '미국 뉴욕'
  timezone: string;
  weeks: CourseWeeks;
  weeklyCount: number;
  durationMin: number;
  startWish: KstDate; // 지금 수강등록의 시작일 (희망 시작일)
};

export type ProposeResult = {
  planId: string;
  state: 'proposed' | 'confirmed';
  tutorNoticeId: string | null;
  studentNoticeId: string | null;
};

type Props = {
  nowIso: string;
  demo: boolean;
  info: AssignInfo;
  tutors: RegTutor[];
  /** 저장 (미리보기는 null → 화면 안에서만) */
  propose:
    | ((
        planId: string,
        p: {
          tutor_id: string;
          slots: RegularSlot[];
          start_date: KstDate;
          tutor_answer: 'accepted' | null;
        }
      ) => Promise<ProposeResult>)
    | null;
  planActions?: PlanActions;
};

const bySlot = (a: RegularSlot, b: RegularSlot) => ((a.weekday + 6) % 7) - ((b.weekday + 6) % 7);

export default function AssignSchedule({ nowIso, demo, info, tutors, propose, planActions }: Props) {
  const now = useMemo(() => new Date(nowIso), [nowIso]);
  const today = instantToKstDate(now);
  const [tutorId, setTutorId] = useState<string | null>(null);
  const [filter, setFilter] = useState<TutorFilter>(EMPTY_FILTER);
  const [weekStart, setWeekStart] = useState<KstDate>(info.startWish > today ? info.startWish : today);
  const [slots, setSlots] = useState<RegularSlot[]>([]);
  const [firstPick, setFirstPick] = useState<KstDate | ''>('');
  const [profile, setProfile] = useState<RegTutor | null>(null);
  const [requestId] = useState(() => crypto.randomUUID());
  const [saving, setSaving] = useState(false);
  const [err, setErr] = useState('');
  const [msg, setMsg] = useState('');
  const [view, setView] = useState<PlanView | null>(null);

  const tutor = tutors.find((t) => t.id === tutorId) ?? null;
  const week = useMemo(() => weekOf(weekStart), [weekStart]);
  const product = `${info.durationMin}분 · 주${info.weeklyCount}회 · ${courseName(info.weeks)}`;
  const enough = slots.length === info.weeklyCount;

  function toggle(date: KstDate, time: string, state: CellState) {
    const wd = weekdayOf(date);
    const same = slots.find((s) => s.weekday === wd);
    if (same && same.time === time) return setSlots(slots.filter((s) => s !== same));
    if (same) return setSlots(slots.map((s) => (s === same ? { weekday: wd, time } : s)).sort(bySlot));
    if (slots.length >= info.weeklyCount) return setMsg(`주 ${info.weeklyCount}회예요. 먼저 고른 시간을 하나 빼 주세요.`);
    if (state === 'makeup' || state === 'off') setMsg('그날만 보강·휴무가 있어요. 아래 기간 전체 검사에서 그 날짜를 알려 드려요.');
    else setMsg('');
    setSlots([...slots, { weekday: wd, time }].sort(bySlot));
  }

  // 첫 수업일: 희망 시작일(또는 내일)부터 첫 정규 요일. 후보 4개 중 충돌 적은 날을 고를 수 있게
  const suggested = useMemo(() => {
    const base = info.startWish > today ? info.startWish : addDays(today, 1);
    return firstLessonDateOnOrAfter(
      base,
      slots.map((s) => s.weekday)
    );
  }, [info.startWish, today, slots]);
  const firstDate = firstPick && slots.some((s) => s.weekday === weekdayOf(firstPick)) ? firstPick : suggested;
  const check = (start: KstDate) =>
    tutor
      ? checkRegularPlan({
          startDate: start,
          weeks: info.weeks,
          slots,
          durationMin: info.durationMin,
          tutorBusy: tutor.busy,
          availability: tutor.availability,
        })
      : null;
  const plan = useMemo(() => (enough && firstDate ? check(firstDate) : null), [enough, firstDate, tutor, slots]); // eslint-disable-line react-hooks/exhaustive-deps
  const candidates = useMemo(() => {
    if (!enough || !suggested || !tutor) return [];
    const out: { date: KstDate; issues: number }[] = [];
    for (let d = suggested; out.length < 4; d = addDays(d, 1)) if (slots.some((s) => s.weekday === weekdayOf(d))) out.push({ date: d, issues: check(d)?.issues.length ?? 0 });
    return out;
  }, [enough, suggested, tutor, slots]); // eslint-disable-line react-hooks/exhaustive-deps

  const draft: PlanView | null =
    tutor && enough && firstDate && plan
      ? {
          planId: '',
          state: 'proposed',
          studentNameEn: info.nameEn,
          studentPlace: info.place,
          studentTz: info.timezone || 'Asia/Seoul',
          tutorName: tutor.name,
          tutorPlace: tutor.country,
          tutorTz: tutor.timezone,
          slots,
          startDate: firstDate,
          endDate: addDays(firstDate, (info.weeks / 4) * 28 - 1),
          lessons: info.weeklyCount * info.weeks,
          durationMin: info.durationMin,
          proposalSentAt: null,
          confirmedAt: null,
          tutorNotice: null,
          studentNotice: null,
        }
      : null;
  const ready = !!draft && plan!.issues.length === 0;

  async function save(accepted: boolean) {
    if (!draft || !ready || saving) return;
    setErr('');
    // 제안 문구는 누른 순간 복사 (휴대폰은 저장을 기다린 뒤엔 복사가 막힘)
    let copied = false;
    if (!accepted) {
      try {
        await navigator.clipboard.writeText(proposalMessage(draft));
        copied = true;
      } catch {
        copied = false;
      }
    }
    setSaving(true);
    try {
      const nowD = new Date();
      if (!propose) {
        setView(
          accepted
            ? {
                ...draft,
                planId: 'preview',
                state: 'confirmed',
                confirmedAt: nowD,
                tutorNotice: { id: 'pv-t', status: 'pending', sentAt: null },
                studentNotice: { id: 'pv-s', status: 'pending', sentAt: null },
              }
            : { ...draft, planId: 'preview', proposalSentAt: copied ? nowD : null }
        );
        return;
      }
      const r = await propose(requestId, {
        tutor_id: tutor!.id,
        slots,
        start_date: draft.startDate,
        tutor_answer: accepted ? 'accepted' : null,
      });
      if (r.state === 'confirmed') {
        setView({
          ...draft,
          planId: r.planId,
          state: 'confirmed',
          confirmedAt: nowD,
          tutorNotice: r.tutorNoticeId ? { id: r.tutorNoticeId, status: 'pending', sentAt: null } : null,
          studentNotice: r.studentNoticeId ? { id: r.studentNoticeId, status: 'pending', sentAt: null } : null,
        });
      } else {
        const at = copied && planActions ? new Date(await planActions.proposalSent(r.planId).catch(() => '')) : null;
        setView({
          ...draft,
          planId: r.planId,
          proposalSentAt: at && !isNaN(at.getTime()) ? at : null,
        });
      }
    } catch (e) {
      setErr(`${e instanceof Error ? e.message : '저장하지 못했어요.'}${copied ? ' 제안 문구는 복사됐지만 저장되지 않았어요 — 강사에게 보내지 마세요.' : ''}`);
    } finally {
      setSaving(false);
    }
  }

  const live = !!planActions && !demo;
  const handlers: PlanHandlers = {
    confirm: async () => {
      if (!view) return;
      const r = live ? await planActions!.confirm(view.planId) : { tutor_notice_id: 'pv-t', student_notice_id: 'pv-s' };
      setView({
        ...view,
        state: 'confirmed',
        confirmedAt: new Date(),
        tutorNotice: { id: r.tutor_notice_id, status: 'pending', sentAt: null },
        studentNotice: { id: r.student_notice_id, status: 'pending', sentAt: null },
      });
    },
    decline: async () => {
      if (!view) return;
      if (live) await planActions!.decline(view.planId);
      setView(null);
      setSlots([]);
      setTutorId(null);
      setMsg('이 안을 닫았어요. 다른 강사·시간을 골라 주세요.');
    },
    proposalCopied: async () => {
      if (!view) return;
      if (live) await planActions!.proposalSent(view.planId);
      setView({ ...view, proposalSentAt: view.proposalSentAt ?? new Date() });
    },
    noticeSent: async (who) => {
      if (!view) return;
      const n = who === 'tutor' ? view.tutorNotice : view.studentNotice;
      if (!n) return;
      if (live) await planActions!.noticeSent(n.id);
      const sent = { ...n, status: 'sent' as const, sentAt: n.sentAt ?? new Date() };
      setView(who === 'tutor' ? { ...view, tutorNotice: sent } : { ...view, studentNotice: sent });
    },
  };

  const home = demo ? '/lms/admin?demo=1' : '/lms/admin';
  return (
    <div className="min-h-screen bg-[#f6f5fb] pb-10">
      <header className="sticky top-0 z-10 flex items-center gap-2 border-b border-[#e6e3ef] bg-white px-4 py-3">
        <b className="text-[17px] text-[#1d1b2b]">강사·시간 고르기</b>
        <span className="flex-1" />
        <Link href={home} aria-label="닫기" className="flex h-10 w-10 items-center justify-center text-[22px] text-[#1d1b2b]">
          ×
        </Link>
      </header>
      {demo && <p className="mx-4 mt-3 rounded-[12px] bg-[#fff8d6] px-4 py-2.5 text-[13.5px] text-[#5c4a00]">가상 데이터 미리보기 — 저장·발송 안 됨</p>}

      <main className="mx-auto max-w-[1100px] space-y-4 px-4 pt-4">
        <Card>
          <b className="block text-[16px] text-[#1d1b2b]">
            {info.studentName}
            {info.place && <span className="font-normal text-[#6b6880]"> · {info.place}</span>}
          </b>
          <span className="text-[14px] text-[#3d3a52]">
            {info.studentCode} · {product} · 희망 시작 {dayLabel(info.startWish)}
          </span>
        </Card>

        {view ? (
          <Card title={view.state === 'proposed' ? '강사 답 대기' : '확정 · 양쪽에 안내를 보내 주세요'}>
            <PlanCard view={view} handlers={handlers} />
            {view.state === 'confirmed' && view.tutorNotice?.status === 'sent' && view.studentNotice?.status === 'sent' && (
              <Link href={home} className="mt-3 flex min-h-[48px] items-center justify-center rounded-[12px] bg-[#e3f6ea] text-[15px] font-bold text-[#1e7a46]">
                ✓ 끝 — 처리할 일로
              </Link>
            )}
          </Card>
        ) : (
          <>
            <Card title="1. 강사">
              <TutorPicker
                tutors={tutors}
                selectedId={tutorId}
                onSelect={(id) => (id !== tutorId ? (setTutorId(id), setSlots([]), setFirstPick('')) : null)}
                week={week}
                durationMin={info.durationMin}
                wish={[]}
                filter={filter}
                setFilter={setFilter}
                onProfile={setProfile}
              />
            </Card>
            {tutor && (
              <Card title={`2. 시간 ${slots.length}/${info.weeklyCount}`}>
                <div className="mb-3">
                  <Legend />
                </div>
                <WeekCalendar tutor={tutor} week={week} today={today} slots={slots} onToggle={toggle} wish={[]} studentTz={info.timezone} durationMin={info.durationMin} onWeek={setWeekStart} />
                {msg && <p className="mt-2 text-[13px] text-[#9a5b00]">{msg}</p>}
              </Card>
            )}
            {tutor && enough && firstDate && (
              <Card title="3. 첫 수업일">
                <div className="flex flex-wrap gap-1.5">
                  {candidates.map((c) => (
                    <button
                      key={c.date}
                      type="button"
                      onClick={() => setFirstPick(c.date)}
                      className={`min-h-[40px] rounded-full border px-3 text-[13.5px] ${c.date === firstDate ? 'border-[#7d5ffb] bg-[#efebff] font-semibold text-[#5b3fe0]' : 'border-[#e6e3ef] bg-white text-[#1d1b2b]'}`}
                    >
                      {dayLabel(c.date)} {c.issues === 0 ? '✓' : `충돌 ${c.issues}`}
                    </button>
                  ))}
                </div>
                {plan && plan.issues.length > 0 && (
                  <ul className="mt-3 space-y-1 rounded-[10px] bg-[#fdecec] px-3 py-2 text-[13px] text-[#b3261e]">
                    {plan.issues.slice(0, 5).map((i, k) => (
                      <li key={k}>
                        • {dayLabel(i.kstDate)} {i.kstTime} · {issueText(i.reason)}
                      </li>
                    ))}
                    {plan.issues.length > 5 && <li>외 {plan.issues.length - 5}건 — 다른 시간이나 첫 수업일을 골라 주세요</li>}
                  </ul>
                )}
              </Card>
            )}
            {draft && (
              <Card title="확인">
                <TimeRows view={draft} />
                <p className="mt-2 text-[13px] text-[#6b6880]">
                  첫 수업 {dayLabel(draft.startDate)} · {draft.lessons}회 · {dayLabel(draft.startDate)}–{dayLabel(draft.endDate)}
                </p>
                <p className="mt-4 text-[15px] font-bold text-[#1d1b2b]">강사에게 물어봤나요?</p>
                <div className="mt-2 grid gap-2">
                  <button
                    type="button"
                    disabled={!ready || saving}
                    onClick={() => save(false)}
                    className="min-h-[52px] rounded-[12px] bg-[#7d5ffb] text-[16px] font-bold text-white disabled:bg-[#cfc4ff]"
                  >
                    {saving ? '저장 중…' : '아직 → 제안 문구 복사'}
                  </button>
                  <button
                    type="button"
                    disabled={!ready || saving}
                    onClick={() => save(true)}
                    className="min-h-[52px] rounded-[12px] border-[1.5px] border-[#7d5ffb] bg-white text-[16px] font-bold text-[#4b33c4] disabled:opacity-50"
                  >
                    가능하대요 → 확정
                  </button>
                </div>
              </Card>
            )}
          </>
        )}
        {err && <p className="rounded-[10px] bg-[#fdecec] px-3 py-2.5 text-[13.5px] text-[#b3261e]">{err}</p>}
      </main>
      {profile && <ProfileSheet tutor={profile} onClose={() => setProfile(null)} />}
    </div>
  );
}
