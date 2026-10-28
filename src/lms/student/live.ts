// 학생 화면 실제 데이터 (migration 2800). 읽기·쓰기 모두 DB 함수 — 본인 확인·검사·이력은 DB
// 학생 본인은 student_ 함수, 운영자(TOTP 완료)가 ?student= 로 열면 운영진 화면과 같은 admin_ 함수(이력에 운영자로 남음)

import type { SupabaseClient } from '@supabase/supabase-js';
import type { KstDate } from '../rules/dates';
import type { PointsEvent, StudentLesson, StudentRequest } from './home';

const NOT_APPLIED = '학생 화면이 이 DB에 아직 없어요 (migration 2800).';

function check<T>(r: { data: T | null; error: { code?: string; message: string } | null }): T {
  if (r.error) {
    if (r.error.code === 'PGRST202' || r.error.code === '42883' || r.error.code === '42703') throw new Error(NOT_APPLIED);
    throw new Error(r.error.message);
  }
  return r.data as T;
}

/** 보강할 수업 (취소한 수업 또는 시트에서 넘어온 날짜 미정 보강) */
export type MakeupRight = { lessonId: string | null; itemId: string | null; originalAt: Date; tutorLeave: boolean; requested: boolean };
/** 강사 휴무 안내 한 줄. stage tutor_ok = 학생 답 기다림, confirmed = 대체 수업 확정, choice wait = 기존 강사님과 보강 */
export type LeaveRow = {
  id: string;
  startsAt: Date;
  choice: 'substitute' | 'wait';
  stage: 'tutor_ok' | 'confirmed' | null;
  subTutor: string | null;
  lessonId: string | null;
  itemId: string | null;
  offFrom: Date;
  offTo: Date;
};

export type StudentView = {
  studentId: string;
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
  /** leavePostponed = 휴무로 미뤄진 수업 (강사 장기휴무로 못 들은 수업, 학생 화면에서 '보강'이라 부르지 않음) */
  lessons: (StudentLesson & { meetUrl: string | null; leavePostponed: boolean })[];
  makeupRights: MakeupRight[];
  requests: StudentRequest[];
  leave: LeaveRow[];
  holidays: KstDate[];
  points: PointsEvent[];
};

type Raw = {
  student: { id: string; code: string; name_ko: string };
  enrollment: null | {
    weeks: number | null; legacy_label: string | null; weekly_count: number; duration_min: number; final_end_date: KstDate;
    lessons_total: number; credits_left: number; credits_granted: number; confirmed_on: KstDate | null; renewal_paid: boolean;
    next_regular_from: KstDate | null;
  };
  lessons: { id: string; kind: string; starts_at: string; ends_at: string; state: string; tutor: string; meet_url: string | null; leave_postponed: boolean }[];
  makeup_rights: { lesson_id: string | null; item_id: string | null; original_at: string; tutor_leave: boolean }[];
  makeup_requests: { id: string; status: string; lesson_id: string | null; item_id: string | null; requested_at: string; candidates: string[]; tutor_leave: boolean }[];
  leave: { id: string; starts_at: string; choice: 'substitute' | 'wait'; stage: 'tutor_ok' | 'confirmed' | null; sub_tutor: string | null; lesson_id: string | null; item_id: string | null; off_from: string; off_to: string }[];
  holidays: KstDate[];
  points: { id: string; on: KstDate; kind: string; amount: number; note: string | null }[];
};

const md = (d: Date) => new Intl.DateTimeFormat('ko-KR', { timeZone: 'Asia/Seoul', month: 'numeric', day: 'numeric' }).format(d).replace(/\.\s?/g, '/').replace(/\/$/, '');

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
  const at = (lessonId: string | null, itemId: string | null) => r.makeup_rights.find((m) => (lessonId && m.lesson_id === lessonId) || (itemId && m.item_id === itemId));
  return {
    studentId: r.student.id,
    name: r.student.name_ko,
    product: e ? `${e.duration_min}분 · 주 ${e.weekly_count}회 · ${e.weeks ? `${e.weeks}주` : e.legacy_label}` : '-',
    finalEndDate: e?.final_end_date ?? ('' as KstDate),
    nextRegularFrom: e?.next_regular_from ?? null,
    totalLessons: e?.lessons_total ?? 0,
    creditsLeft: e?.credits_left ?? 0,
    creditsPerPeriod: e?.credits_granted ?? 0,
    renewalPaid: e?.renewal_paid ?? false,
    confirmedOn: e?.confirmed_on ?? null,
    lessons: r.lessons.map((l) => ({
      id: l.id,
      kind: lessonKind(l.kind),
      startsAt: new Date(l.starts_at),
      minutes: Math.round((new Date(l.ends_at).getTime() - new Date(l.starts_at).getTime()) / 60_000),
      tutorName: l.tutor,
      state: lessonState(l.state),
      meetUrl: l.meet_url,
      leavePostponed: l.leave_postponed,
    })),
    makeupRights: r.makeup_rights.map((m) => ({
      lessonId: m.lesson_id,
      itemId: m.item_id,
      originalAt: new Date(m.original_at),
      tutorLeave: m.tutor_leave,
      requested: open.some((q) => (m.lesson_id && q.lesson_id === m.lesson_id) || (m.item_id && q.item_id === m.item_id)),
    })),
    requests: r.makeup_requests.map((q) => {
      const src = at(q.lesson_id, q.item_id);
      return {
        id: q.id,
        kind: 'makeup',
        title: `${q.tutor_leave ? '휴무로 미뤄진 수업' : '보강 신청'}${src ? ` · ${md(new Date(src.original_at))} 수업분` : ''}`,
        status: q.status === 'confirmed' ? 'confirmed' : 'tutor_reviewing',
        candidates: q.candidates.map((c) => new Date(c)),
        createdAt: new Date(q.requested_at),
        note: '',
      };
    }),
    leave: r.leave.map((x) => ({
      id: x.id, startsAt: new Date(x.starts_at), choice: x.choice, stage: x.stage, subTutor: x.sub_tutor,
      lessonId: x.lesson_id, itemId: x.item_id, offFrom: new Date(x.off_from), offTo: new Date(x.off_to),
    })),
    holidays: r.holidays,
    points: r.points.map((p) => ({ id: p.id, on: p.on, kind: p.amount > 0 ? 'grant' : 'use', amount: Math.abs(p.amount), reason: p.note || POINT_REASON[p.kind] || '적립금' })),
  };
}

/** studentId: 운영자가 고른 학생 (학생 본인은 비움) */
export async function loadStudentView(sb: SupabaseClient, studentId: string | null): Promise<StudentView> {
  return parseStudentView(check(await sb.rpc('student_screen', { p_student: studentId })));
}

export type MakeupOption = { startsAt: Date; afterEnd: boolean };
export async function loadMakeupOptions(sb: SupabaseClient, studentId: string | null, right: { lessonId: string | null; itemId: string | null }): Promise<MakeupOption[]> {
  const rows = check(await sb.rpc('student_makeup_options', { p_student: studentId, p_lesson: right.lessonId, p_item: right.itemId })) as { section: string; starts_at: string }[];
  return rows.map((x) => ({ startsAt: new Date(x.starts_at), afterEnd: x.section === 'after_end' }));
}

/** 학생 화면 동작. admin = 운영자 보기(대신 입력)면 운영진 함수 */
export function studentActions(sb: SupabaseClient, adminStudentId: string | null) {
  const admin = adminStudentId !== null;
  return {
    reload: () => loadStudentView(sb, adminStudentId),
    makeupOptions: (right: { lessonId: string | null; itemId: string | null }) => loadMakeupOptions(sb, adminStudentId, right),
    /** 수업 취소 (판정 시각 = 지금). 결과는 DB 판정 */
    cancel: async (lessonId: string): Promise<{ status: string; uses_credit: boolean; makeup_allowed: boolean }> => {
      const id = crypto.randomUUID();
      return admin
        ? check(await sb.rpc('admin_change_lesson', { p_request_id: id, p_lesson: lessonId, p_who: 'student', p_requested_at: new Date().toISOString(), p_dry_run: false }))
        : check(await sb.rpc('student_change_lesson', { p_request_id: id, p_lesson: lessonId, p_dry_run: false }));
    },
    requestMakeup: async (right: { lessonId: string | null; itemId: string | null }, slots: Date[]): Promise<void> => {
      const p_slots = slots.map((s) => ({ starts_at: s.toISOString() }));
      check(
        admin
          ? await sb.rpc('admin_makeup_request', { p_lesson: right.lessonId, p_item: right.itemId, p_slots, p_requested_at: new Date().toISOString() })
          : await sb.rpc('student_makeup_request', { p_lesson: right.lessonId, p_item: right.itemId, p_slots }),
      );
    },
    /** 휴무 안내 답 (A안 한 번에): ok = 대체강사와 평소 시간, makeup = 기존 강사님과 보강 */
    answerLeave: async (items: string[], answer: 'ok' | 'makeup'): Promise<void> => {
      if (!admin) return void check(await sb.rpc('student_leave_answer', { p_items: items, p_answer: answer }));
      check(answer === 'ok' ? await sb.rpc('admin_leave_student_ok', { p_items: items }) : await sb.rpc('admin_leave_choose', { p_items: items, p_choice: 'wait', p_sub_tutor: null }));
    },
  };
}
export type StudentActions = ReturnType<typeof studentActions>;

export type StudentAccount = { id: string; code: string; name: string; hasLogin: boolean };
export async function loadStudentAccounts(sb: SupabaseClient): Promise<StudentAccount[]> {
  const rows = check(await sb.rpc('admin_student_accounts')) as { id: string; code: string; name_ko: string; has_login: boolean }[];
  return rows.map((r) => ({ id: r.id, code: r.code, name: r.name_ko, hasLogin: r.has_login }));
}
export async function createStudentLogin(sb: SupabaseClient, studentId: string, email: string): Promise<{ created: boolean }> {
  const rows = check(await sb.rpc('admin_student_login', { p_student: studentId, p_email: email })) as { created: boolean }[];
  return { created: rows[0]?.created ?? false };
}
