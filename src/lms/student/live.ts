// 수강생 화면 실제 데이터 (migration 2800). 읽기·쓰기 모두 DB 함수 — 본인 확인·검사·이력은 DB
import { asClassType } from '../class-type';
// 수강생 본인은 student_ 함수, 운영자(TOTP 완료)가 ?student= 로 열면 운영진 화면과 같은 admin_ 함수(이력에 운영자로 남음)

import type { SupabaseClient } from '@supabase/supabase-js';
import type { KstDate } from '../rules/dates';
import type { CreditPeriod, PaymentSummary, PointsEvent, StudentLesson, StudentRequest } from './home';
import { processingEvents, type ProcessingEvent } from './processing-history';

const NOT_APPLIED = '수강생 화면이 이 DB에 아직 없어요 (migration 2800).';

function check<T>(r: { data: T | null; error: { code?: string; message: string } | null }): T {
  if (r.error) {
    if (r.error.code === 'PGRST202' || r.error.code === '42883' || r.error.code === '42703') throw new Error(NOT_APPLIED);
    throw new Error(r.error.message);
  }
  return r.data as T;
}

/** 보강할 수업 (취소한 수업 또는 시트에서 넘어온 날짜 미정 보강) */
/** timeKnown=false: 시트에서 옮긴 보강이라 원래 수업 날짜만 앎 (화면은 날짜만, 3700) */
/** compId: 강사 노쇼 무료 보상수업 (4100, 원래 수업 보강과 따로). useUntil = 사용 기한(수강 종료일, 기한 안 재등록이면 이월) */
const TUTOR_FAULT = ['Tutor no-show', 'Tutor canceled in advance', 'Tutor canceled late'];
export type MakeupRight = {
  lessonId: string | null; itemId: string | null; compId?: string | null; useUntil?: KstDate | null;
  originalAt: Date; timeKnown?: boolean; tutorLeave: boolean; requested: boolean; tutor?: string | null; tutorNoShow?: boolean;
  /** 강사 사전·늦은 취소·노쇼 — 수강생 화면 이름 '강사 사정으로 취소된 수업' (수강생에게 '노쇼'라고 쓰지 않음, 11/8 대표) */
  tutorFault?: boolean;
  /** 강사 사전·늦은 취소 (노쇼 아님) — 사유 '강사가 취소' (11/12 대표) */
  tutorCanceled?: boolean;
  /** 지난 수강 기간에서 이월된 권리 (원래 수업이 지금 수강권이 아닌 앞 수강권 것) — 카드 '이월된 수업' (11/12 대표) */
  carryIn?: boolean;
};
/** 보강 권리를 가리키는 값 (원래 수업 · 시트 보강 · 보상수업 중 하나) */
export type RightRef = { lessonId: string | null; itemId: string | null; compId?: string | null };
/** 강사 휴무 안내 한 줄. stage tutor_ok = 수강생 답 기다림, confirmed = 대체 수업 확정, choice wait = 기존 강사님과 보강 */
export type LeaveRow = {
  id: string;
  startsAt: Date;
  choice: 'substitute' | 'wait';
  stage: 'tutor_ok' | 'confirmed' | null;
  subTutor: string | null;
  /** 대체강사 수업 링크 (평소 강사 링크와 다름) */
  subMeetUrl: string | null;
  lessonId: string | null;
  itemId: string | null;
  offFrom: Date;
  offTo: Date;
};

export type StudentView = {
  studentId: string;
  /** 수강생이 사는 곳 시간대 — 수강생 화면 시각은 이 시간대로 (11/3 대표: 해외 수강생은 본인 나라 시간으로) */
  timezone?: string;
  name: string;
  product: string;
  /** 수강 종료일 (강사 휴무면 마지막 휴무 보강일까지 연장된 날, A20) — 재등록 결제 마감도 이 날 23:59 */
  finalEndDate: KstDate;
  /** 재등록하면 다음 정규 수업을 시작할 수 있는 첫날. null = 휴무로 미뤄진 수업 날짜가 아직 안 잡힘 */
  nextRegularFrom: KstDate | null;
  totalLessons: number;
  creditsLeft: number;
  creditsPerPeriod: number;
  renewalPaid: boolean;
  confirmedOn: KstDate | null;
  /** 결제 완료 여부 (결제 확인 기록, 또는 시트에서 옮긴 수강 중 수강권) */
  paid: boolean;
  /** 수강권 상태 (pending_payment · confirmed · active · completed · canceled). 결제 전·수업 생성 전에는 '남은 0회' 재등록 안내를 띄우지 않음 (QA-05) */
  enrollmentStatus: string | null;
  /** 강사가 정한 교재 이름 (QA C-04). 없거나 수업 방식에 교재가 없으면 null */
  textbook?: string | null;
  /** leavePostponed = 강사 장기휴무로 못 들은 수업의 보강 (DB 구분용, 수강생 화면 표시는 '보강'으로 같음) */
  lessons: (StudentLesson & { meetUrl: string | null; leavePostponed: boolean; substitute: boolean; /** 휴무 처리 확정 전 (3300): 일정 조율 중 */ leaveOpen?: boolean; /** 강사 노쇼 (4000) */ tutorNoShow?: boolean })[];
  makeupRights: MakeupRight[];
  requests: StudentRequest[];
  processingHistory?: ProcessingEvent[];
  processingHistoryError?: boolean;
  leave: LeaveRow[];
  /** 휴무 처리 중인데 수업 줄이 아직 없는 수업 → 일정에 '일정 조율 중' (3700) */
  leavePending?: { id: string; startsAt: Date; endsAt: Date }[];
  holidays: KstDate[];
  points: PointsEvent[];
  /** 지금 변경권 기간과 쓴·돌려받은 기록 */
  creditPeriod: { start: KstDate; end: KstDate } | null;
  /** 수강권의 모든 변경권 기간(지급·잔여) — 미래 수업 취소 미리 보기는 그 수업 날짜의 기간으로 (R-12, 4520). 옛 DB 면 빈 배열 */
  creditPeriods: CreditPeriod[];
  creditUses: { at: Date; reason: 'student_change' | 'admin_restore' | 'admin_adjust'; delta: number; lessonAt: Date | null; note?: string | null }[];
};

type Raw = {
  student: { id: string; code: string; name_ko: string; timezone?: string | null };
  enrollment: null | {
    status?: string;
    weeks: number | null; legacy_label: string | null; weekly_count: number; duration_min: number; final_end_date: KstDate;
    lessons_total: number; credits_left: number; credits_granted: number; confirmed_on: KstDate | null; renewal_paid: boolean;
    next_regular_from: KstDate | null;
  };
  lessons: { id: string; kind: string; starts_at: string; ends_at: string; state: string; tutor: string; meet_url: string | null; leave_postponed: boolean; substitute: boolean; leave_open?: boolean; class_status?: string | null; type?: string; lesson_final_end_date?: KstDate | null }[];
  makeup_rights: { lesson_id: string | null; item_id: string | null; comp_id?: string | null; use_until?: KstDate | null; tutor?: string | null; original_at: string; time_known?: boolean; tutor_leave: boolean; carry_in?: boolean }[];
  leave_pending?: { id: string; starts_at: string; ends_at: string }[];
  makeup_requests: {
    confirmed_lesson_id?: string | null;
    id: string; status: string; lesson_id: string | null; item_id: string | null; comp_id?: string | null; requested_at: string; candidates: string[]; tutor_leave: boolean;
    /** 4100: 원래 수업 시각·강사, 보강 강사, 확정된 날짜 */
    /** 강사가 답한 시각 (있으면 운영진 최종 확정 대기) */
    tutor_answered_at?: string | null;
    /** 4500: 강사가 모든 후보에 불가 답 / 확정된 보강 수업 상태(canceled 면 취소됨) */
    tutor_declined_all?: boolean;
    confirmed_state?: string | null;
    original_at?: string | null; original_time_known?: boolean; original_tutor?: string | null; tutor?: string | null; confirmed_at?: string | null;
  }[];
  leave: { id: string; starts_at: string; choice: 'substitute' | 'wait'; stage: 'tutor_ok' | 'confirmed' | null; sub_tutor: string | null; sub_meet_url: string | null; lesson_id: string | null; item_id: string | null; off_from: string; off_to: string }[];
  holidays: KstDate[];
  credit_period: { start: KstDate; end: KstDate } | null;
  credit_periods?: { idx: number; start: KstDate; end: KstDate; granted: number; left: number }[];
  credit_uses: { at: string; reason: 'student_change' | 'admin_restore' | 'admin_adjust'; delta: number; lesson_at: string | null; note?: string | null }[];
  points: { id: string; on: KstDate; kind: string; amount: number; note: string | null }[];
};

/** 날짜 'M/D' — 수강생 시간대 날짜 (시각 모르는 시트 수업은 한국 날짜) */
const md = (d: Date, tz = 'Asia/Seoul') => new Intl.DateTimeFormat('ko-KR', { timeZone: tz, month: 'numeric', day: 'numeric' }).format(d).replace(/\.\s?/g, '/').replace(/\/$/, '');

/** 확정된 보강 수업 시각 (옛 DB: confirmed_at 이 없으면 수업 목록에서) */
function lessonStart(r: Raw, q: { status: string } & { confirmed_lesson_id?: string | null }): Date | null {
  const l = q.confirmed_lesson_id ? r.lessons.find((x) => x.id === q.confirmed_lesson_id) : undefined;
  return l ? new Date(l.starts_at) : null;
}

/**
 * 수강권 이름: '50분 · 주 2회 · 4주'. 시트에서 옮긴 수강권은 운영 메모('기존 수강생 이관 · 4주 (결제는 시트)')가 이름 칸에 있어
 * 수강생에게는 주 수만 보여 줌 (11/2 점검 ⑥: 내부 문구 노출)
 */
export function productLabel(e: { duration_min: number; weekly_count: number; weeks: number | null; legacy_label: string | null }): string {
  const weeks = e.weeks ?? Number(/(\d+)\s*주/.exec(e.legacy_label ?? '')?.[1] ?? 0);
  return [`${e.duration_min}분`, `주 ${e.weekly_count}회`, weeks ? `${weeks}주` : ''].filter(Boolean).join(' · ');
}

/** 결제 상태: 결제 확인된 수강권(확정·수강 중·끝남)은 결제 완료. 시트에서 옮긴 수강권은 LMS 결제 기록이 없어도 수강 중이면 결제 완료 */
export function paidStatus(e: { status?: string; confirmed_on: KstDate | null }): boolean {
  return !!e.confirmed_on || (e.status !== undefined && ['confirmed', 'active', 'completed'].includes(e.status));
}

const POINT_REASON: Record<string, string> = {
  grant_tutor_late_cancel: '강사 사정 취소 보상 (시작 6시간 이내)',
  grant_admin: '적립금 지급',
  hold: '재등록 결제에 사용',
  release: '결제 취소로 돌아옴',
  refund_restore: '환불로 돌아옴',
  admin_adjust: '적립금 조정',
};

export function parseStudentView(r: Raw): StudentView {
  const e = r.enrollment;
  const lessonKind = (k: string): StudentLesson['kind'] => (k === 'regular' ? 'regular' : k === 'compensation' ? 'compensation' : 'makeup');
  const lessonState = (s: string): StudentLesson['state'] => (s === 'scheduled' ? 'scheduled' : s === 'done' ? 'done' : 'canceled');
  const open = r.makeup_requests.filter((q) => q.status === 'requested' || q.status === 'countered');
  const at = (lessonId: string | null, itemId: string | null) => r.makeup_rights.find((m) => !m.comp_id && ((lessonId && m.lesson_id === lessonId) || (itemId && m.item_id === itemId)));
  return {
    studentId: r.student.id,
    timezone: r.student.timezone || 'Asia/Seoul',
    name: r.student.name_ko,
    product: e ? productLabel(e) : '-',
    finalEndDate: e?.final_end_date ?? ('' as KstDate),
    nextRegularFrom: e?.next_regular_from ?? null,
    totalLessons: e?.lessons_total ?? 0,
    creditsLeft: e?.credits_left ?? 0,
    creditsPerPeriod: e?.credits_granted ?? 0,
    renewalPaid: e?.renewal_paid ?? false,
    confirmedOn: e?.confirmed_on ?? null,
    paid: e ? paidStatus(e) : false,
    enrollmentStatus: e?.status ?? null,
    lessons: r.lessons.map((l) => ({
      id: l.id,
      kind: lessonKind(l.kind),
      type: asClassType(l.type, l.kind, l.substitute),
      finalEndDate: l.lesson_final_end_date ?? undefined,
      startsAt: new Date(l.starts_at),
      minutes: Math.round((new Date(l.ends_at).getTime() - new Date(l.starts_at).getTime()) / 60_000),
      tutorName: l.tutor,
      state: lessonState(l.state),
      meetUrl: l.meet_url,
      leavePostponed: l.leave_postponed,
      substitute: l.substitute,
      leaveOpen: !!l.leave_open,
      tutorNoShow: l.class_status === 'Tutor no-show',
    })),
    makeupRights: r.makeup_rights.map((m) => ({
      lessonId: m.lesson_id,
      itemId: m.item_id,
      compId: m.comp_id ?? null,
      useUntil: m.use_until ?? null,
      originalAt: new Date(m.original_at),
      timeKnown: m.time_known !== false,
      tutorLeave: m.tutor_leave,
      tutor: m.tutor ?? r.lessons.find((l) => l.id === m.lesson_id)?.tutor ?? null,
      tutorNoShow: !!m.comp_id || r.lessons.find((l) => l.id === m.lesson_id)?.class_status === 'Tutor no-show',
      tutorFault: TUTOR_FAULT.includes(r.lessons.find((l) => l.id === m.lesson_id)?.class_status ?? ''),
      tutorCanceled: ['Tutor canceled in advance', 'Tutor canceled late'].includes(r.lessons.find((l) => l.id === m.lesson_id)?.class_status ?? ''),
      carryIn: !!m.carry_in,
      // 원래 수업 보강과 보상수업은 신청이 따로 (4100)
      requested: open.some((q) => (m.comp_id ? q.comp_id === m.comp_id : !q.comp_id && ((m.lesson_id && q.lesson_id === m.lesson_id) || (m.item_id && q.item_id === m.item_id)))),
    })),
    requests: r.makeup_requests.map((q) => {
      // 확정 뒤에는 보강 권리 목록에서 빠지므로 원래 수업 정보는 신청 줄에서 바로 읽음 (4100), 옛 DB는 권리 목록에서
      const src = at(q.lesson_id, q.item_id);
      const originalIso = q.original_at ?? src?.original_at ?? null;
      const comp = !!q.comp_id;
      return {
        id: q.id,
        kind: 'makeup',
        compensation: comp,
        title: `${comp ? '무료 보상수업' : '보강'}${originalIso ? ` · ${md(new Date(originalIso), (q.original_time_known ?? src?.time_known !== false) ? r.student.timezone || 'Asia/Seoul' : 'Asia/Seoul')} 수업분` : ''}`,
        status: q.status === 'confirmed'
          ? (q.confirmed_state === 'canceled' ? 'canceled' : 'confirmed')
          : q.status === 'expired' ? 'expired'
          : q.status === 'withdrawn' ? 'withdrawn'
          : q.tutor_answered_at ? (q.tutor_declined_all ? 'rescheduling' : 'admin_reviewing') : 'tutor_reviewing',
        tutorDeclinedAll: !!q.tutor_declined_all,
        lessonId: q.lesson_id,
        itemId: q.item_id,
        compId: q.comp_id ?? null,
        candidates: q.candidates.map((c) => new Date(c)),
        createdAt: new Date(q.requested_at),
        note: '',
        originalAt: originalIso ? new Date(originalIso) : null,
        originalTimeKnown: q.original_time_known ?? src?.time_known !== false,
        originalTutor: q.original_tutor ?? (q.lesson_id ? r.lessons.find((l) => l.id === q.lesson_id)?.tutor ?? null : null),
        tutor: q.tutor ?? null,
        confirmedAt: q.confirmed_at ? new Date(q.confirmed_at) : q.status === 'confirmed' ? lessonStart(r, q) : null,
      };
    }),
    leave: r.leave.map((x) => ({
      id: x.id, startsAt: new Date(x.starts_at), choice: x.choice, stage: x.stage, subTutor: x.sub_tutor, subMeetUrl: x.sub_meet_url,
      lessonId: x.lesson_id, itemId: x.item_id, offFrom: new Date(x.off_from), offTo: new Date(x.off_to),
    })),
    leavePending: (r.leave_pending ?? []).map((x) => ({ id: x.id, startsAt: new Date(x.starts_at), endsAt: new Date(x.ends_at) })),
    holidays: r.holidays,
    creditPeriod: r.credit_period,
    creditPeriods: (r.credit_periods ?? []).map((p) => ({ start: p.start, end: p.end, granted: p.granted, left: p.left })),
    creditUses: (r.credit_uses ?? []).map((c) => ({ at: new Date(c.at), reason: c.reason, delta: c.delta, lessonAt: c.lesson_at ? new Date(c.lesson_at) : null, note: c.note ?? null })),
    points: r.points.map((p) => ({ id: p.id, on: p.on, kind: p.amount > 0 ? 'grant' : 'use', amount: Math.abs(p.amount), reason: p.note || POINT_REASON[p.kind] || '적립금' })),
  };
}

type SuggestionRow = { id: string; stage: string; suggested: { id: string; starts_at: string; ok: boolean }[] };
/** 강사가 시간을 제안한 신청: DB 상태(makeup_stage) 'student' = 고르기, 그 밖('admin') = 운영진 조율 */
export function withSuggestions(v: StudentView, rows: SuggestionRow[]): StudentView {
  const by = new Map(rows.map((r) => [r.id, r]));
  return {
    ...v,
    requests: v.requests.map((q) => {
      const r = by.get(q.id);
      if (!r) return q;
      return { ...q, status: r.stage === 'student' ? 'choosing' : r.stage === 'admin' ? 'rescheduling' : q.status, suggested: r.suggested.map((x) => ({ id: x.id, startsAt: new Date(x.starts_at), ok: !!x.ok })) };
    }),
  };
}

/** studentId: 운영자가 고른 수강생 (수강생 본인은 비움) */
export async function loadStudentView(sb: SupabaseClient, studentId: string | null): Promise<StudentView> {
  const [screen, book, sug, history] = await Promise.all([
    sb.rpc('student_screen', { p_student: studentId }), loadTextbook(sb, studentId), sb.rpc('student_makeup_suggestions', { p_student: studentId }),
    sb.rpc('student_processing_history', { p_student: studentId })]);
  const v = parseStudentView(check(screen));
  // 강사가 제안한 시간 (H26(134), 20261111160000). 함수 없는 옛 DB 면 예전 그대로
  return { ...(sug.error ? v : withSuggestions(v, (sug.data as SuggestionRow[]) ?? [])), textbook: book,
    processingHistory: history.error ? [] : processingEvents((history.data as ProcessingEvent[]) ?? []),
    processingHistoryError: !!history.error };
}
/** 강사가 정한 교재 (QA C-04, migration 20261107040000). 함수가 없는 옛 DB 면 null — 학습자료에 교재만 안 보임 */
async function loadTextbook(sb: SupabaseClient, studentId: string | null): Promise<string | null> {
  const r = await sb.rpc('student_textbook', { p_student: studentId });
  if (r.error) return null;
  return (r.data as { textbook: string | null } | null)?.textbook ?? null;
}

export type MakeupOption = { startsAt: Date; afterEnd: boolean };
/** '내 정보' 학습 정보(강사 작성)·홈 누적 학습 시간 (migration 20261111010000). 값이 없으면 null */
/** 학생 홈 공지 (migration 20261111150000): 게시 중인 공지 + 이 학생이 열어 봤는지 */
export type StudentNotice = { id: string; title: string; body: string; startsOn: KstDate; read: boolean };
export type MyInfo = { level: string | null; goal: string | null; style: string | null; noteUrl: string | null; learnedMin: number };
export type RegularSlot = { weekday: number; timeKst: string; minutes: number; tutor: string };
/** 보상수업이면 p_comp 를 붙임 (4100). 원래 수업 보강은 예전과 같은 인자 → 4100 전 DB에서도 그대로 */
const compArg = (right: RightRef) => (right.compId ? { p_comp: right.compId } : {});
export async function loadMakeupOptions(sb: SupabaseClient, studentId: string | null, right: RightRef): Promise<MakeupOption[]> {
  const rows = check(await sb.rpc('student_makeup_options', { p_student: studentId, p_lesson: right.lessonId, p_item: right.itemId, ...compArg(right) })) as { section: string; starts_at: string }[];
  return rows.map((x) => ({ startsAt: new Date(x.starts_at), afterEnd: x.section === 'after_end' }));
}

/** 수업 알림 메일 켬/끔 (정규 = 정규 수업, 보강 = 그 밖의 수업). hasEmail = 받을 이메일이 있는지 */
export type Reminders = { regular: boolean; makeup: boolean; hasEmail: boolean };

/** 시간대 (하나뿐: 화면·메일·카톡 모두). kept = 학생이 [그대로]를 누른 기기 시간대 */
export type TimezoneState = { timezone: string; kept: string | null };

/** 수강생 화면 동작. admin = 운영자 보기(대신 입력)면 운영진 함수 */
export function studentActions(sb: SupabaseClient, adminStudentId: string | null) {
  const admin = adminStudentId !== null;
  return {
    reload: () => loadStudentView(sb, adminStudentId),
    /** 알림 설정 읽기(인자 없음)·바꾸기 — 수강생·운영자 같은 함수 */
    reminders: async (change?: { regular?: boolean; makeup?: boolean }): Promise<Reminders> => {
      const r = check(await sb.rpc('student_reminders', { p_student: adminStudentId, p_regular: change?.regular ?? null, p_makeup: change?.makeup ?? null })) as {
        regular: boolean;
        makeup: boolean;
        has_email: boolean;
      };
      return { regular: r.regular, makeup: r.makeup, hasEmail: r.has_email };
    },
    /** 시간대 읽기(인자 없음) · 바꾸기(set) · [그대로] 기억(keep = 그때 기기 시간대) (H26(119), migration 20261109150000). 함수 없는 옛 DB 면 null */
    timezone: async (change?: { set?: string; keep?: string }): Promise<TimezoneState | null> => {
      const r = await sb.rpc('student_timezone', { p_student: adminStudentId, p_set: change?.set ?? null, p_keep: change?.keep ?? null });
      if (r.error) {
        if (change) throw new Error(r.error.message);
        return null;
      }
      const d = r.data as { timezone: string; kept: string | null };
      return { timezone: d.timezone, kept: d.kept };
    },
    makeupOptions: (right: RightRef) => loadMakeupOptions(sb, adminStudentId, right),
    /**
     * [맞는 시간이 없어요] (H26(92) ⑤, migration 20261108020000): 종료 5일 이내에 강사가 알린 사전·늦은 취소의 보강권만.
     * 값 = 수업 번호 → 이미 누른 시각(null = 아직 안 누름). 함수가 없는 옛 DB 면 빈 목록 (링크 안 보임)
     */
    /** 정규 수업 시간 (H26(95) ②, migration 20261108040000): 요일(KST 0=일)·시각(KST)·길이·강사. 함수 없는 옛 DB 면 빈 목록 */
    notices: async (): Promise<StudentNotice[]> => {
      const r = await sb.rpc('student_notices', { p_student: adminStudentId });
      if (r.error) return [];
      return ((r.data ?? []) as { id: string; title: string; body: string; starts_on: KstDate; read: boolean }[]).map((x) => ({ id: x.id, title: x.title, body: x.body, startsOn: x.starts_on, read: x.read }));
    },
    /** 학생이 공지를 열면 확인함 (운영자 보기는 DB 에서 기록 안 함) */
    noticeRead: async (id: string): Promise<void> => {
      await sb.rpc('student_notice_read', { p_student: adminStudentId, p_announcement: id });
    },
    /** 현재·지난 수강권 / 결제 내역 — 실제 등록·결제 기록만 (금액·카드 정보 없음, POL-PAY-11) */
    history: async (): Promise<PaymentSummary[]> => {
      const r = await sb.rpc('student_enrollment_history', { p_student: adminStudentId });
      if (r.error) return [];
      return ((r.data ?? []) as { id: string; current: boolean; status: string; duration_min: number; weekly_count: number; weeks: number | null; legacy_label: string | null; start_date: KstDate; final_end_date: KstDate; method: string | null; confirmed_on: KstDate | null }[]).map((e) => ({
        id: e.id, product: productLabel(e), periodStart: e.start_date, periodEnd: e.final_end_date,
        method: e.method === 'bank_transfer' ? 'bank_transfer' : e.method === 'card_link' ? 'card_imweb' : null,
        confirmedOn: e.confirmed_on, current: e.current, paid: paidStatus({ status: e.status, confirmed_on: e.confirmed_on }),
      }));
    },
    /** 함수 없는 옛 DB 면 null (화면에서 해당 칸 숨김) */
    myInfo: async (): Promise<MyInfo | null> => {
      const r = await sb.rpc('student_my_info', { p_student: adminStudentId });
      if (r.error || !r.data) return null;
      const d = r.data as { level: string | null; goal: string | null; style: string | null; note_url: string | null; learned_min: number };
      return { level: d.level, goal: d.goal, style: d.style, noteUrl: d.note_url, learnedMin: d.learned_min ?? 0 };
    },
    regularSlots: async (): Promise<RegularSlot[]> => {
      const r = await sb.rpc('student_regular_slots', { p_student: adminStudentId });
      if (r.error) return [];
      return ((r.data ?? []) as { weekday: number; time: string; minutes: number; tutor: string }[]).map((x) => ({ weekday: x.weekday, timeKst: x.time, minutes: x.minutes, tutor: x.tutor }));
    },
    noTimeRights: async (): Promise<Map<string, string | null>> => {
      const r = await sb.rpc('student_no_time_rights', { p_student: adminStudentId });
      if (r.error) return new Map();
      return new Map(((r.data ?? []) as { lesson_id: string; requested_at: string | null }[]).map((x) => [x.lesson_id, x.requested_at]));
    },
    noTimeRequest: async (lessonId: string): Promise<void> => {
      check(await sb.rpc('student_no_time_request', { p_student: adminStudentId, p_lesson: lessonId }));
    },
    /** 수업 취소 (판정 시각 = 지금 = 서버 시각. A-01: 브라우저 시각을 보내면 시계가 빠른 기기에서 '요청 받은 시각이 지금보다 늦습니다' 로 거절됨). 결과는 DB 판정 */
    cancel: async (lessonId: string): Promise<{ status: string; uses_credit: boolean; makeup_allowed: boolean }> => {
      const id = crypto.randomUUID();
      return admin
        ? check(await sb.rpc('admin_change_lesson', { p_request_id: id, p_lesson: lessonId, p_who: 'student', p_requested_at: null, p_dry_run: false }))
        : check(await sb.rpc('student_change_lesson', { p_request_id: id, p_lesson: lessonId, p_dry_run: false }));
    },
    requestMakeup: async (right: RightRef, slots: Date[]): Promise<void> => {
      const p_slots = slots.map((s) => ({ starts_at: s.toISOString() }));
      check(
        admin
          ? await sb.rpc('admin_makeup_request', { p_lesson: right.lessonId, p_item: right.itemId, p_slots, p_requested_at: null, ...compArg(right) })
          : await sb.rpc('student_makeup_request', { p_lesson: right.lessonId, p_item: right.itemId, p_slots, ...compArg(right) }),
      );
    },
    /** 강사 확정 전 보강 신청 취소 (대표 11/9). 운영자 보기도 같은 함수 */
    withdrawMakeup: async (requestId: string): Promise<void> => {
      check(await sb.rpc('student_makeup_withdraw', { p_student: adminStudentId, p_request: requestId }));
    },
    /** 강사가 제안한 시간 하나로 바로 확정 (H26(134)). 누르는 순간 DB 가 다시 검사. 운영자 보기도 같은 함수 */
    pickSuggestion: async (requestId: string, candidateId: string): Promise<void> => {
      check(await sb.rpc('student_makeup_pick', { p_student: adminStudentId, p_request: requestId, p_candidate: candidateId }));
    },
    /** [제안한 시간이 모두 안 돼요] → 운영진 조율 */
    declineSuggestion: async (requestId: string): Promise<void> => {
      check(await sb.rpc('student_makeup_decline_suggestion', { p_student: adminStudentId, p_request: requestId }));
    },
        /** 휴무 안내 답 (A안 한 번에): ok = 대체강사와 수업, makeup = 기존 강사님과 보강 */
    answerLeave: async (items: string[], answer: 'ok' | 'makeup'): Promise<void> => {
      if (!admin) return void check(await sb.rpc('student_leave_answer', { p_items: items, p_answer: answer }));
      check(answer === 'ok' ? await sb.rpc('admin_leave_student_ok', { p_items: items }) : await sb.rpc('admin_leave_choose', { p_items: items, p_choice: 'wait', p_sub_tutor: null }));
    },
  };
}
export type StudentActions = ReturnType<typeof studentActions>;

export type StudentAccount = { id: string; code: string; name: string; nameEn: string; tutors: string; hasLogin: boolean };
export async function loadStudentAccounts(sb: SupabaseClient): Promise<StudentAccount[]> {
  const rows = check(await sb.rpc('admin_student_accounts')) as { id: string; code: string; name_ko: string; name_en: string; tutors: string | null; has_login: boolean }[];
  return rows.map((r) => ({ id: r.id, code: r.code, name: r.name_ko, nameEn: r.name_en, tutors: r.tutors ?? '', hasLogin: r.has_login }));
}

/** 운영자 보기 수강생 검색: 한글·영문 이름, 수강생 번호, 강사 이름 (공백 무시) */
export function searchStudents(list: StudentAccount[], q: string): StudentAccount[] {
  const k = q.replace(/\s/g, '').toLowerCase();
  if (!k) return list;
  return list.filter((x) => [x.name, x.nameEn, x.code, x.tutors].some((v) => v.replace(/\s/g, '').toLowerCase().includes(k)));
}
export async function createStudentLogin(sb: SupabaseClient, studentId: string, email: string): Promise<{ created: boolean }> {
  const rows = check(await sb.rpc('admin_student_login', { p_student: studentId, p_email: email })) as { created: boolean }[];
  return { created: rows[0]?.created ?? false };
}
