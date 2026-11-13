// 운영자 대시보드 실제 데이터 (시험용 Supabase) — DB 행을 board.ts 의 TaskSource 로 바꾼다
// 읽기는 로그인한 운영자(aal2) 토큰으로 RLS 를 거친다. 쓰기(처리 버튼)는 서버 기능을 만든 뒤 연결 (POL-AC-07: 쓰기는 서버만)
// 표시 원칙 POL-OP-20: 열린 업무만 가져온다 (완료·취소된 업무는 목록에 오지 않음)

import type { SupabaseClient } from '@supabase/supabase-js';
import { addDays, endOfKstDay, formatInZone, instantToKstDate, type KstDate } from '../rules/dates';
import { courseName } from '../rules/period';
import { grantsMakeup, type ClassStatus } from '../rules/status';
import { RENEWAL_PROMPT } from '../student/home';
import type { TaskSource } from './board';
import { filterActionableTasks, filterClosedTasks } from './task-closure';
import type { PlanView } from './confirm';
import { loadPlans } from './confirm-live';
import type { FakeLesson } from './fake-data';
import { monthEnd, monthRegistrations, toLessonItems, type EndingItem, type LessonItem, type LessonListRow, type PaymentRow, type RegistrationItem } from './dashboard';
import type { MissingRecord } from '../tutor/live';

const WD = ['일', '월', '화', '수', '목', '금', '토'];
const short = (d: KstDate) => `${Number(d.slice(5, 7))}/${Number(d.slice(8, 10))}(${WD[new Date(`${d}T00:00:00Z`).getUTCDay()]})`;

type Enrollment = { weeks: number | null; legacy_label: string | null; weekly_count: number; duration_min: number; start_date: string; base_end_date: string; student: { name_ko: string; code: string } | null;
  /** 재등록: 새 수강권 일정안 상태 (확정 있으면 일정 확정됨) */
  plans?: { state: string }[] | null };

export type TaskRow = {
  id: string;
  enrollment_id?: string;
  kind: 'new_student_matching' | 'renewal_tutor_notice';
  due_at: string | null;
  created_at: string;
  tutor_assigned_at: string | null;
  student_notified_at: string | null;
  tutor_notified_at: string | null;
  tutor_acknowledged_at: string | null;
  schedule_checked_at: string | null;
  tutor_change_planned: boolean;
  tutor: { name: string } | null;
  enrollment: Enrollment | null;
};

export type LeaveRow = {
  id: string;
  leave_start: string;
  days: number;
  reason_kind: 'health' | 'family_emergency' | 'business_trip' | 'other_special';
  created_at: string;
  enrollment: { student: { name_ko: string; code: string } | null } | null;
};

export type NoShowRow = {
  id: string;
  reported_at: string;
  lesson: { starts_at: string; student: { name_ko: string } | null; tutor: { name: string } | null } | null;
};

export type LessonRow = {
  id: string;
  starts_at: string;
  kind: 'regular' | 'makeup' | 'compensation' | 'carryover';
  state: 'scheduled' | 'canceled' | 'done';
  class_status: string | null;
  student: { name_ko: string } | null;
  tutor: { name: string } | null;
};

const d = (v: string | null) => (v ? new Date(v) : null);

function product(e: Pick<Enrollment, 'weeks' | 'legacy_label' | 'weekly_count' | 'duration_min'> | null): string {
  if (!e) return '수강 정보 없음';
  const term = e.weeks ? courseName(e.weeks) : (e.legacy_label ?? '');
  return `${e.duration_min}분 주${e.weekly_count}회 ${term}`.trim();
}

export function toTaskSources(tasks: TaskRow[], leaves: LeaveRow[], noShows: NoShowRow[], plans: ReadonlyMap<string, PlanView> = new Map()): TaskSource[] {
  const out: TaskSource[] = [];
  for (const t of tasks) {
    const studentName = t.enrollment?.student?.name_ko ?? '(수강생 정보 없음)';
    const studentCode = t.enrollment?.student?.code ?? '';
    if (t.kind === 'new_student_matching') {
      if (!t.due_at) continue; // 매칭 업무는 기한이 항상 있음 (DB 트리거가 넣음)
      out.push({
        kind: 'new_student_matching',
        id: t.id,
        studentName,
        studentCode,
        product: product(t.enrollment),
        dueAt: new Date(t.due_at),
        tutorName: t.tutor?.name ?? null,
        tutorAssignedAt: d(t.tutor_assigned_at),
        studentNotifiedAt: d(t.student_notified_at),
        plan: (t.enrollment_id && plans.get(t.enrollment_id)) || null,
        enrollmentId: t.enrollment_id,
      });
    } else {
      const e = t.enrollment;
      out.push({
        kind: 'renewal_tutor_notice',
        id: t.id,
        studentName,
        studentCode,
        product: product(e),
        newPeriod: e ? `${short(e.start_date)}–${short(e.base_end_date)}` : '',
        tutorName: t.tutor?.name ?? null,
        tutorChangePlanned: t.tutor_change_planned,
        scheduleConfirmed: (t.enrollment?.plans ?? []).some((p) => p.state === 'confirmed'),
        enrollmentId: t.enrollment_id,
        tutorNotifiedAt: d(t.tutor_notified_at),
        tutorAcknowledgedAt: d(t.tutor_acknowledged_at),
        scheduleCheckedAt: d(t.schedule_checked_at),
        createdAt: new Date(t.created_at),
      });
    }
  }
  for (const l of leaves) {
    out.push({
      kind: 'long_leave_request',
      id: l.id,
      studentName: l.enrollment?.student?.name_ko ?? '(수강생 정보 없음)',
      studentCode: l.enrollment?.student?.code ?? '',
      from: short(l.leave_start),
      to: short(addDays(l.leave_start, l.days - 1)),
      days: l.days,
      reason: l.reason_kind,
      createdAt: new Date(l.created_at),
    });
  }
  for (const n of noShows) {
    if (!n.lesson) continue;
    out.push({
      kind: 'no_show_report',
      id: n.id,
      studentName: n.lesson.student?.name_ko ?? '(수강생)',
      tutorName: n.lesson.tutor?.name ?? '(강사)',
      lessonStartsAt: new Date(n.lesson.starts_at),
      reportedAt: new Date(n.reported_at),
    });
  }
  return out;
}

export function toTodayLessons(lessons: LessonRow[], openNoShowLessonIds: ReadonlySet<string>): FakeLesson[] {
  return [...lessons]
    .sort((a, b) => a.starts_at.localeCompare(b.starts_at))
    .map((l) => ({
      time: formatInZone(new Date(l.starts_at), 'Asia/Seoul').time,
      student: l.student?.name_ko ?? '(수강생)',
      tutor: l.tutor?.name ?? '(강사)',
      state: openNoShowLessonIds.has(l.id)
        ? '노쇼 신고'
        : l.state === 'done'
          ? '완료'
          : l.state === 'canceled'
            ? l.class_status?.startsWith('Student') ? '수강생 변경' : '취소'
            : l.kind === 'makeup'
              ? '보강'
              : '예정',
    }));
}

export type ImportCheckRow = {
  enrollment_id: string; sheet_total: number; sheet_used: number; lms_left: number; created_at: string;
  /** migration 1600 부터 */
  checked_at?: string | null; end_days?: number; end_reason?: string | null; weeks?: number | null;
  enrollment: { student: { name_ko: string; code: string } | null } | null;
};
export type UnknownOriginRow = { id: string; kind: 'makeup_booked' | 'makeup_open'; enrollment_id: string; created_at: string; lesson: { starts_at: string } | null; enrollment: { student: { name_ko: string; code: string } | null } | null };

/** 기존 수강생 입력 뒤 시트 대조 전 · 보강 원래 날짜 확인 필요 → 수강생(수강등록)마다 한 줄 */
export function toImportChecks(checks: ImportCheckRow[], origins: UnknownOriginRow[]): TaskSource[] {
  const out = new Map<string, Extract<TaskSource, { kind: 'import_check' }>>();
  const row = (eid: string, e: ImportCheckRow['enrollment'], created: string) => {
    if (!out.has(eid))
      out.set(eid, { kind: 'import_check', id: eid, studentName: e?.student?.name_ko ?? '(수강생 정보 없음)', studentCode: e?.student?.code ?? '', counts: null, unknownOrigins: [], createdAt: new Date(created) });
    return out.get(eid)!;
  };
  for (const c of checks) {
    const r = row(c.enrollment_id, c.enrollment, c.created_at);
    if (!c.checked_at) r.counts = { lmsLeft: c.lms_left, sheetLeft: c.sheet_total - c.sheet_used };
    if (c.end_days && !c.end_reason) r.endReason = { days: c.end_days, weeks: c.weeks ?? null };
  }
  for (const o of origins) {
    const label = o.kind === 'makeup_open' ? '미예약 보강' : `예약된 보강 ${o.lesson ? short(instantToKstDate(new Date(o.lesson.starts_at))) : ''}`.trim();
    row(o.enrollment_id, o.enrollment, o.created_at).unknownOrigins.push({ id: o.id, label });
  }
  return [...out.values()];
}

// 시트 대조 전 + 종료일 이유 미확인 (1600). 1600 전 DB는 칸이 없어 대조 전만 읽음
async function loadImportChecks(sb: SupabaseClient) {
  const who = 'enrollment:enrollments(student:students(name_ko, code))';
  const full = await sb
    .from('import_checks')
    .select(`enrollment_id, sheet_total, sheet_used, lms_left, created_at, checked_at, end_days, end_reason, weeks, ${who}`)
    .or('checked_at.is.null,and(end_days.neq.0,end_reason.is.null)');
  if (full.error?.code !== '42703' && full.error?.code !== 'PGRST204') return full;
  return sb.from('import_checks').select(`enrollment_id, sheet_total, sheet_used, lms_left, created_at, ${who}`).is('checked_at', null);
}

type ChangeNoticeRow = {
  created_at: string;
  event?: string;
  recipient_kind?: 'student' | 'tutor';
  change: { type?: string; student: { id: string; name_ko: string; code: string } | null; lesson: { starts_at: string; kind?: string } | null } | null;
  makeup: { student: { id: string; name_ko: string; code: string } | null } | null;
};
type OpenMakeupRow = { status?: string; makeup_stage?: string | null; created_at: string; tutor_answered_at?: string | null; student: { id: string; name_ko: string; code: string } | null; candidates?: { tutor_answer: string | null; proposed_by: string }[] | null };

/** 수업 변경·보강 (1700): 안 보낸 안내 · 강사 답 대기 보강 → 수강생마다 한 줄 */
/** 자동 메일을 못 보낸 안내 (20261108010000: 실패·주소 없음) → 운영진이 직접 보내야 함 */
export type EmailFailRow = { created_at: string; recipient_kind?: 'student' | 'tutor'; email_status?: string; makeup: { student: { id: string; name_ko: string; code: string } | null } | null; change?: { student: { id: string; name_ko: string; code: string } | null } | null };

/** 자동 메일 못 보냄: 수업 안내(lesson_notices) + 강사 통보 메일(tutor_updates, H26(127) — 그 수업이 끝날 때까지만) */
async function loadEmailFails(sb: SupabaseClient): Promise<{ data: EmailFailRow[] | null; error: unknown }> {
  const [a, b] = await Promise.all([
    sb.from('lesson_notices').select('created_at, recipient_kind, email_status, makeup:makeup_requests(student:students(id, name_ko, code)), change:change_requests(student:students(id, name_ko, code))')
      .in('email_status', ['failed', 'no_address']).neq('status', 'sent'),
    sb.from('tutor_updates').select('created_at, email_error, student:students(id, name_ko, code), mail:notifications(status)')
      .gt('visible_until', new Date().toISOString()),
  ]);
  if (a.error) return { data: null, error: a.error };
  type Tu = { created_at: string; email_error: string | null; student: { id: string; name_ko: string; code: string } | null; mail: { status: string } | null };
  const tu = b.error ? [] : ((b.data ?? []) as unknown as Tu[])
    .filter((x) => x.email_error || x.mail?.status === 'failed')
    .map((x): EmailFailRow => ({ created_at: x.created_at, recipient_kind: 'tutor', email_status: x.email_error ? 'no_address' : 'failed', makeup: null, change: { student: x.student } }));
  return { data: [...((a.data ?? []) as unknown as EmailFailRow[]), ...tu], error: null };
}

export function toLessonChanges(notices: ChangeNoticeRow[], makeups: OpenMakeupRow[], now: Date, emailFails: EmailFailRow[] = []): TaskSource[] {
  const out = new Map<string, Extract<TaskSource, { kind: 'lesson_change' }>>();
  const row = (s: { id: string; name_ko: string; code: string }, created: string) => {
    if (!out.has(s.id)) out.set(s.id, { kind: 'lesson_change', id: s.id, studentName: s.name_ko, studentCode: s.code, pendingNotices: 0, openMakeups: 0, lessonAt: null, createdAt: new Date(created) });
    return out.get(s.id)!;
  };
  for (const f of emailFails) {
    const st = f.change?.student ?? f.makeup?.student;   // 수업 취소 메일(학생 취소·강사 사정 취소)도 (11/9)
    if (!st) continue;
    const r = row(st, f.created_at);
    r.emailFailed = (r.emailFailed ?? 0) + 1;
    if (f.recipient_kind && !(r.emailFailedTo ??= []).includes(f.recipient_kind)) r.emailFailedTo.push(f.recipient_kind);
  }
  for (const n of notices) {
    const s = n.change?.student ?? n.makeup?.student;
    if (!s) continue;
    const r = row(s, n.created_at);
    r.pendingNotices += 1;
    if (n.event && !(r.noticeEvents ??= []).includes(n.event)) r.noticeEvents.push(n.event);
    if (n.recipient_kind && !(r.noticeTo ??= []).includes(n.recipient_kind)) r.noticeTo.push(n.recipient_kind);
    const at = n.change?.lesson ? new Date(n.change.lesson.starts_at) : null;
    if (at && at > now && (!r.lessonAt || at < r.lessonAt)) r.lessonAt = at;
    // 지난 수업이어도 안내 카드에는 그 수업 날짜를 보여 줌 (무슨 일인지 바로 알게)
    if (at && (!r.noticeLessonAt || at < r.noticeLessonAt)) {
      r.noticeLessonAt = at;
      r.noticeLessonKind = n.change?.lesson?.kind ?? null;
      r.noticeChangeType = n.change?.type ?? null;
    }
  }
  for (const m of makeups) {
    if (!m.student) continue;
    // 강사가 시간을 제안하고 수강생 선택을 기다리는 신청은 운영진 할 일 아님 (H26(134)). 수강생 '모두 안 돼요'·제안 시간 지남 → 보강 조율 필요
    if (m.status === 'countered') {
      if (m.makeup_stage !== 'admin') continue;
      const r = row(m.student, m.created_at);
      r.openMakeups += 1;
      r.answeredMakeups = (r.answeredMakeups ?? 0) + 1;
      r.suggestFailed = (r.suggestFailed ?? 0) + 1;
      continue;
    }
    const r = row(m.student, m.created_at);
    r.openMakeups += 1;
    if (m.tutor_answered_at) {
      r.answeredMakeups = (r.answeredMakeups ?? 0) + 1;
      // 강사가 수강생 후보 모두에 불가 → 운영진이 다른 일정 조율 (QA-08, 4500)
      const studentCands = (m.candidates ?? []).filter((c) => c.proposed_by === 'student');
      if (studentCands.length > 0 && studentCands.every((c) => c.tutor_answer === 'no')) r.declinedMakeups = (r.declinedMakeups ?? 0) + 1;
    }
    else if (!r.makeupWaitingSince || new Date(m.created_at) < r.makeupWaitingSince) r.makeupWaitingSince = new Date(m.created_at);
  }
  // 강사 답만 기다리는 보강 신청은 운영진 할 일에 올리지 않음 — 재촉 메일·자동 만료가 처리 (대표 11/9, D-38 대체)
  return [...out.values()].filter((r) => r.pendingNotices > 0 || (r.emailFailed ?? 0) > 0 || (r.answeredMakeups ?? 0) > 0);
}

/** 강사 답 칸(tutor_answered_at, migration 2000)이 없는 DB면 그 칸 없이 다시 읽음 */
async function loadOpenMakeups(sb: SupabaseClient) {
  const q = (cols: string) => sb.from('makeup_requests').select(cols).in('status', ['requested', 'countered']);
  // makeup_stage = DB 상태 계산 칸 (20261111160000). 없는 옛 DB 면 그 칸 없이
  let r = await q('status, makeup_stage, created_at, tutor_answered_at, student:students(id, name_ko, code), candidates:makeup_candidates(tutor_answer, proposed_by)');
  if (r.error) r = await q('status, created_at, tutor_answered_at, student:students(id, name_ko, code), candidates:makeup_candidates(tutor_answer, proposed_by)');
  return r.error?.code === '42703' ? q('created_at, student:students(id, name_ko, code)') : r;
}

/** Class Record 미기록 (2000): 강사마다 한 줄 */
export function toMissingRecords(rows: MissingRecord[]): TaskSource[] {
  const out = new Map<string, Extract<TaskSource, { kind: 'class_record_missing' }>>();
  for (const r of rows) {
    if (!out.has(r.tutorId)) out.set(r.tutorId, { kind: 'class_record_missing', id: r.tutorId, tutorName: r.tutorName, lessons: [], createdAt: r.startsAt });
    out.get(r.tutorId)!.lessons.push({ studentName: r.studentName, startsAt: r.startsAt });
  }
  return [...out.values()];
}

export type ExtensionReviewRow = {
  lesson_id: string; student_code: string; student_name: string; lesson_at: string; class_status: string;
  notice_at: string | null; end_date: string; requested_at: string;
};
/** 예외 연장 검토 카드 (H26(92) ⑤) */
export function toExtensionReviews(rows: ExtensionReviewRow[]): TaskSource[] {
  return rows.map((r) => ({
    kind: 'extension_review', id: r.lesson_id, studentName: r.student_name, studentCode: r.student_code, lessonAt: new Date(r.lesson_at),
    late: r.class_status === 'Tutor canceled late', noticeAt: r.notice_at ? new Date(r.notice_at) : null, endDate: r.end_date, createdAt: new Date(r.requested_at),
  }));
}

export type TimeOffRequestRow = {
  id: string; tutor_id: string; tutor_name: string; tutor_timezone: string; first_day: string; last_day: string; kst_from: string; kst_to: string;
  kind: 'planned' | 'urgent'; reason: string; late: boolean; classes: number; created_at: string;
};
/** 강사 휴무 신청 (H26(137)) */
export function toTimeOffRequests(rows: TimeOffRequestRow[]): TaskSource[] {
  return rows.map((r) => ({
    kind: 'time_off_request', id: r.id, tutorName: r.tutor_name, tutorTimezone: r.tutor_timezone, first: r.first_day, last: r.last_day,
    kstFrom: r.kst_from, kstTo: r.kst_to, planned: r.kind === 'planned', reason: r.reason, late: r.late, classes: r.classes, createdAt: new Date(r.created_at),
  }));
}

export type LeaveOpenRow = {
  student_id: string; starts_at: string; choice: 'undecided' | 'substitute' | 'wait'; sub_stage: 'asked' | 'tutor_ok' | 'confirmed' | null;
  /** 휴무 처리 밖에서 취소된 수업 (3200, R5) → 할 일에서 뺌 */
  lesson_gone_at?: string | null;
  off: { id: string; starts_at: string; ends_at: string; created_at: string; tutor: { name: string } | null } | null;
};
export type LeaveNoticeRow = { event?: string; leave: { student_id?: string; lesson_gone_at?: string | null; choice?: string; sub_stage?: string | null; off: LeaveOpenRow['off'] } | null };

/** 강사 휴무 처리 (1800·2500 새 순서): 아직 정하지 않았거나 답을 기다리는 수업 · 안 보낸 안내 → 휴무마다 한 줄 */
export function toTutorLeaves(rows: LeaveOpenRow[], notices: LeaveNoticeRow[], now: Date): TaskSource[] {
  const out = new Map<string, Extract<TaskSource, { kind: 'tutor_leave' }>>();
  const undecided = new Map<string, Set<string>>();
  // 1단계(대체강사 고르기·강사 답)가 남은 수강생은 2단계 글을 아직 보낼 수 없음
  const blocked = new Set<string>();
  const row = (o: NonNullable<LeaveOpenRow['off']>) => {
    if (!out.has(o.id))
      out.set(o.id, {
        kind: 'tutor_leave', id: o.id, tutorName: o.tutor?.name ?? '', from: instantToKstDate(new Date(o.starts_at)),
        to: addDays(instantToKstDate(new Date(o.ends_at)), -1), undecidedStudents: 0, tutorReply: 0, studentReply: 0, pendingNotices: 0,
        firstOpenAt: null, createdAt: new Date(o.created_at),
      });
    return out.get(o.id)!;
  };
  for (const r of rows) {
    if (!r.off || r.lesson_gone_at) continue;
    const t = row(r.off);
    if (r.choice === 'undecided') {
      const s = undecided.get(r.off.id) ?? new Set<string>();
      s.add(r.student_id);
      undecided.set(r.off.id, s);
      blocked.add(`${r.off.id}|${r.student_id}`);
      t.undecidedStudents = s.size;
      t.undecidedLessons = (t.undecidedLessons ?? 0) + 1;
    } else if (r.sub_stage === 'asked') {
      t.tutorReply += 1;
      blocked.add(`${r.off.id}|${r.student_id}`);
    } else if (r.sub_stage === 'tutor_ok') t.studentReply += 1;
    const at = new Date(r.starts_at);
    if (at > now && (!t.firstOpenAt || at < t.firstOpenAt)) t.firstOpenAt = at;
  }
  for (const n of notices) {
    if (!n.leave?.off || n.leave.lesson_gone_at) continue;
    const t = row(n.leave.off);
    t.pendingNotices += 1;
    const ns = (t.noticeSteps ??= { notify: 0, tutor: 0, confirm: 0 });
    if (n.event === 'leave_options' || n.event === 'sub_student') {
      // 2단계 글(휴무 안내 + 대체강사 제안)은 수강생마다 하나
      ns.notify += 1;
      if (n.event === 'sub_student') ns.proposeLessons = (ns.proposeLessons ?? 0) + 1;
      const sid = n.leave?.student_id;
      // 정해진 날짜부터 먼저 안내 (대표 10/30): 그 수업 자체가 미정·강사 답 대기면 아직 못 보냄. choice 를 못 읽는 옛 응답은 수강생 단위로
      const itemReady = n.leave?.choice ? n.leave.choice !== 'undecided' && n.leave.sub_stage !== 'asked' : !blocked.has(`${n.leave!.off!.id}|${sid}`);
      if (sid && itemReady && !(ns.proposeStudents ??= []).includes(sid)) ns.proposeStudents.push(sid);
    } else if (n.event === 'sub_ask') ns.tutor += 1;
    else if (n.event === 'sub_confirmed') ns.confirm += 1;
  }
  return [...out.values()];
}

export type EndingRow = {
  id: string;
  student_id: string;
  status?: string;
  weeks: number | null;
  legacy_label: string | null;
  weekly_count: number;
  duration_min: number;
  final_end_date: string;
  start_date?: string;
  previous_enrollment_id?: string | null;
  student: { name_ko: string; code: string; is_trial_account?: boolean | null } | null;
  /** 이 수강권의 모든 수업 (POL-RN-08: 정규·보강·보상·이월 다 셈, 2026-10-27 대표) */
  lessons: { id: string; kind: string; state: 'scheduled' | 'canceled' | 'done'; starts_at: string; class_status: string | null; makeup_of: string | null; voided_at: string | null; tutor: { name: string } | null }[];
  /** 시트에서 넘어온 날짜 미정 보강 (makeup_open) */
  migrated?: { kind: string }[];
  /** 강사 노쇼 무료 보상수업 (available = 날짜 안 잡음, 4100) */
  comps?: { status: string }[];
};

/**
 * 종료 임박 (POL-RN-08): 수강생마다 마지막 수강권(결제 확인·수강 중)만 보고, 지금 이후 예정 정규 수업이 2회 이하면 한 줄.
 * Class Record 완료 기록이 없어도 날짜로 셈(지난 예정 수업은 한 것으로 봄). 결제 확인된 재등록 수강권이 있으면 그쪽이 마지막이라 빠짐.
 * 정규 수업이 아직 하나도 없는 수강권(신규 매칭 전)은 신규 매칭 칸에서 다룸
 */
/** sent: 수강권 id → 재등록 안내 [보냄] 시각 (migration 1900, 없으면 빈 목록) */
/** reopened: 처리 내역에서 다시 연 수강권 id (자동 제외하지 않음, 3900) */
/** 남은 수업 (POL-RN-08): 지금 이후 예정 수업 + 날짜 미정 보강(취소 수업 보강권·시트 미예약 보강·날짜 안 잡은 보상수업) */
export function remainingOf(r: EndingRow, now: Date): { left: EndingRow['lessons']; owed: number } {
  const left = r.lessons.filter((l) => l.state === 'scheduled' && new Date(l.starts_at) > now).sort((a, b) => a.starts_at.localeCompare(b.starts_at));
  const booked = new Set(r.lessons.filter((l) => l.makeup_of && l.state !== 'canceled').map((l) => l.makeup_of));
  // 강사 노쇼는 '진행됨(done)' 상태라도 보강 권리가 있음 (수강생 홈과 같은 수, 4100) + 날짜 안 잡은 무료 보상수업
  const owed = r.lessons.filter((l) => (l.state === 'canceled' || l.class_status === 'Tutor no-show') && !l.voided_at && l.class_status
    && (grantsMakeup(l.class_status as ClassStatus) || l.class_status === 'Tutor long-term leave') && !booked.has(l.id)).length
    + (r.migrated ?? []).filter((m) => m.kind === 'makeup_open').length
    + (r.comps ?? []).filter((c) => c.status === 'available').length;
  return { left, owed };
}

export function toEndingSoon(rows: EndingRow[], now: Date, sent: Map<string, string> = new Map(), reopened: Set<string> = new Set()): TaskSource[] {
  const latest = new Map<string, EndingRow>();
  for (const r of rows) {
    const cur = latest.get(r.student_id);
    if (!cur || r.final_end_date > cur.final_end_date) latest.set(r.student_id, r);
  }
  const out: TaskSource[] = [];
  for (const r of latest.values()) {
    if (r.student?.is_trial_account) continue;
    // 운영진 할 일 = 재등록 안내 보내기. [보냄] 하면 끝 (대표 11/9: 마지막 필수 처리 뒤 자동으로 사라짐). 이후는 '이번 달 종료 예정' 명단에서 봄
    if (sent.has(r.id)) continue;
    // 종료일로부터 3일 뒤 자동 제외 (한국 날짜, 연장된 최종 종료일 기준).
    if (instantToKstDate(now) >= addDays(r.final_end_date, 3) && !reopened.has(r.id)) continue;
    // 정규 수업이 아직 없는 수강권(신규 매칭 전)은 제외. 기존 수강생 입력으로 넣은 '다 끝난 수강권'(수강 중, 남은 0회)은 재등록 대기로 보여 줌 (migration 2200)
    if (r.status !== 'active' && !r.lessons.some((l) => l.kind === 'regular')) continue;
    const { left, owed } = remainingOf(r, now);
    if (left.length + owed > RENEWAL_PROMPT.maxLessonsLeft) continue;
    const last = [...r.lessons].sort((a, b) => b.starts_at.localeCompare(a.starts_at))[0];
    out.push({
      kind: 'ending_soon',
      id: r.id,
      studentName: r.student?.name_ko ?? '(수강생 정보 없음)',
      studentCode: r.student?.code ?? '',
      product: product(r),
      lessonsLeft: left.length + owed,
      endsAt: endOfKstDay(r.final_end_date),
      tutorName: (left[0] ?? last)?.tutor?.name ?? null,
      durationMin: r.duration_min,
      weeklyCount: r.weekly_count,
      noticeSentAt: null,
    });
  }
  return out;
}

/**
 * 이번 달 종료 예정 명단 (대시보드 숫자 칸): 오늘~이달 말에 끝나는 수강권. 테스트용 뺌.
 * 결제 확인된 다음 수강권이 있으면 '재등록 완료', 안내 보냈으면 '안내 보냄', 남은 2회 이하인데 안 보냈으면 '재등록 안내 필요'
 */
export function monthEndings(rows: EndingRow[], now: Date, sent: Map<string, string> = new Map()): EndingItem[] {
  const today = instantToKstDate(now);
  const end = monthEnd(today);
  const out: EndingItem[] = [];
  for (const r of rows) {
    if (r.student?.is_trial_account || r.final_end_date < today || r.final_end_date > end) continue;
    if (r.status !== 'active' && !r.lessons.some((l) => l.kind === 'regular')) continue;
    const next = rows.find((x) => x.previous_enrollment_id === r.id);
    const { left, owed } = remainingOf(r, now);
    const sentAt = sent.get(r.id);
    const lessonsLeft = left.length + owed;
    out.push({
      enrollmentId: r.id, studentCode: r.student?.code ?? '', studentName: r.student?.name_ko ?? '(수강생)', endDate: r.final_end_date as KstDate,
      lessonsLeft, undated: owed, renewedStart: next ? (next.start_date as KstDate) : null,
      noticeSentOn: sentAt ? instantToKstDate(new Date(sentAt)) : null,
      state: next ? 'renewed' : sentAt ? 'sent' : lessonsLeft <= RENEWAL_PROMPT.maxLessonsLeft ? 'need' : 'none',
    });
  }
  return out.sort((a, b) => a.endDate.localeCompare(b.endDate) || a.studentCode.localeCompare(b.studentCode));
}

// migration 1500 전 DB에는 표가 없음 → 대시보드는 그대로 보이게 빈 목록
const missingTable = (e: { code?: string } | null) => !!e && (e.code === '42P01' || e.code === 'PGRST205');

const LESSON_COLS = 'id, starts_at, ends_at, kind, class_type, state, class_status, student:students(code, name_ko), tutor:tutors!lessons_tutor_id_fkey(name), original_tutor:tutors!lessons_original_tutor_id_fkey(name)';

/**
 * 수업 줄에 붙일 실제 기록 (11/13 대표 시안):
 *  - 취소된 수업 → 그 수업에 확정으로 연결된 보강(makeup_requests.source_lesson_id → confirmed_lesson_id)의 최신 시각.
 *    그 보강도 취소됐으면 그 보강에 연결된 다음 보강을 따라감(최대 4번). 끝까지 살아 있는 보강이 없으면 표시 안 함
 *  - 시간 변경 → 운영진이 확정된 보강 시간을 고친 기록(admin_makeup_logs reschedule)의 처음 시각. 기록이 없으면 표시 안 함
 * 읽지 못하면(옛 DB·권한) 빈 표시 — 수업 줄은 그대로 보임
 */
export async function loadLessonExtras(sb: SupabaseClient, rows: LessonListRow[]): Promise<{ makeups: Map<string, string>; moves: Map<string, string> }> {
  const makeups = new Map<string, string>();
  const moves = new Map<string, string>();
  const canceled = rows.filter((r) => r.state === 'canceled').map((r) => r.id);
  // origin: 지금 따라가는 수업 id → 처음 취소된 수업 id
  let origin = new Map(canceled.map((id) => [id, id]));
  for (let hop = 0; hop < 4 && origin.size > 0; hop++) {
    const req = await sb.from('makeup_requests').select('source_lesson_id, confirmed_lesson_id').eq('status', 'confirmed').in('source_lesson_id', [...origin.keys()]);
    if (req.error) break;
    const reqs = (req.data ?? []) as { source_lesson_id: string; confirmed_lesson_id: string }[];
    if (reqs.length === 0) break;
    const ls = await sb.from('lessons').select('id, starts_at, state').in('id', reqs.map((r) => r.confirmed_lesson_id));
    if (ls.error) break;
    const byId = new Map(((ls.data ?? []) as { id: string; starts_at: string; state: string }[]).map((l) => [l.id, l]));
    const next = new Map<string, string>();
    for (const [cur, first] of origin) {
      const linked = reqs.filter((r) => r.source_lesson_id === cur).map((r) => byId.get(r.confirmed_lesson_id)).filter((l): l is NonNullable<typeof l> => !!l);
      const live = linked.filter((l) => l.state !== 'canceled').sort((a, b) => b.starts_at.localeCompare(a.starts_at))[0];
      if (live) makeups.set(first, live.starts_at);
      else for (const l of linked) next.set(l.id, first);
    }
    origin = next;
  }
  const kept = rows.filter((r) => r.state !== 'canceled').map((r) => r.id);
  if (kept.length > 0) {
    const logs = await sb.from('admin_makeup_logs').select('lesson_id, old_starts_at, created_at').eq('action', 'reschedule').in('lesson_id', kept).order('created_at');
    if (!logs.error) for (const g of (logs.data ?? []) as { lesson_id: string; old_starts_at: string | null }[]) {
      if (g.old_starts_at && !moves.has(g.lesson_id)) moves.set(g.lesson_id, g.old_starts_at);
    }
  }
  return { makeups, moves };
}

/** 운영자 대시보드 데이터 읽기 (운영자 aal2 세션 필요 — 아니면 RLS 때문에 0건) */
export async function loadAdminBoard(sb: SupabaseClient, now: Date) {
  const today = instantToKstDate(now);
  const off = 'off:tutor_time_off(id, starts_at, ends_at, created_at, tutor:tutors(name))';
  const [tasks, leaves, noShows, lessons, checks, origins, changeNotices, openMakeups, emailFails, ending, leaveOpen, leaveNotices, renewalSent, closures, extReviews, active, unpaid, pays] = await Promise.all([
    sb
      .from('admin_tasks')
      .select(
        'id, kind, enrollment_id, due_at, created_at, tutor_assigned_at, student_notified_at, tutor_notified_at, tutor_acknowledged_at, schedule_checked_at, tutor_change_planned, tutor:tutors(name), enrollment:enrollments(weeks, legacy_label, weekly_count, duration_min, start_date, base_end_date, student:students(name_ko, code), plans:schedule_plans(state))',
      )
      .eq('status', 'open'),
    sb.from('long_leave_requests').select('id, leave_start, days, reason_kind, created_at, enrollment:enrollments(student:students(name_ko, code))').eq('status', 'pending'),
    sb
      .from('no_show_reports')
      .select('id, reported_at, lesson:lessons(id, starts_at, student:students(name_ko), tutor:tutors!lessons_tutor_id_fkey(name))')
      .eq('status', 'open'),
    sb.from('lessons').select(LESSON_COLS).eq('kst_date', today),
    loadImportChecks(sb),
    sb
      .from('migrated_items')
      .select('id, kind, enrollment_id, created_at, lesson:lessons(starts_at), enrollment:enrollments(student:students(name_ko, code))')
      .eq('origin_unknown', true)
      .is('origin_checked_at', null),
    sb
      .from('lesson_notices')
      .select('created_at, event, recipient_kind, change:change_requests(type, student:students(id, name_ko, code), lesson:lessons(starts_at, kind)), makeup:makeup_requests(student:students(id, name_ko, code))')
      .eq('status', 'pending'),
    loadOpenMakeups(sb),
    // 자동 메일 실패·주소 없음 — 운영진이 직접 보내고 [보냄] 했거나 다시 보내기로 발송되면 끝 (칸이 없는 DB면 빈 목록)
    loadEmailFails(sb),
    sb
      .from('enrollments')
      .select('id, student_id, status, weeks, legacy_label, weekly_count, duration_min, start_date, final_end_date, previous_enrollment_id, student:students(name_ko, code, is_trial_account), lessons!lessons_enrollment_id_fkey(id, kind, state, starts_at, class_status, makeup_of, voided_at, tutor:tutors!lessons_tutor_id_fkey(name)), migrated:migrated_items(kind), comps:compensations(status)')
      .in('status', ['confirmed', 'active']),
    sb.from('leave_items').select(`student_id, starts_at, choice, sub_stage, lesson_gone_at, ${off}`).or('choice.eq.undecided,sub_stage.in.(asked,tutor_ok)'),
    sb.from('lesson_notices').select(`event, leave:leave_items(student_id, lesson_gone_at, choice, sub_stage, ${off})`).eq('status', 'pending').not('leave_item_id', 'is', null),
    sb.from('renewal_notices').select('enrollment_id, sent_at'),
    sb.from('admin_task_closures').select('task_kind, task_id, signature, closed'),
    // 예외 연장 검토 (20261108020000 전 DB 는 함수가 없어 건너뜀)
    sb.rpc('admin_extension_reviews'),
    // 숫자 칸: '수강 중' = 수강생 목록(admin_students)과 같은 기준 — 끝나지 않은 수강권이 오늘 기간 안 (QA-05)
    sb.from('enrollments').select('student_id, student:students(is_trial_account)').not('status', 'in', '("completed","canceled")').lte('start_date', today).gte('final_end_date', today),
    sb.from('enrollments').select('id, student:students(is_trial_account)').eq('status', 'pending_payment'),
    sb.from('payments').select('enrollment_id, confirmed_at, paid_at, received_on, enrollment:enrollments(previous_enrollment_id, weeks, legacy_label, weekly_count, duration_min, student:students(code, name_ko, is_trial_account))')
      .gte('confirmed_at', `${today.slice(0, 8)}01T00:00:00+09:00`),
  ]);
  const error = tasks.error ?? leaves.error ?? noShows.error ?? lessons.error ?? (missingTable(checks.error) ? null : checks.error) ?? (missingTable(origins.error) ? null : origins.error) ?? ending.error
    ?? active.error ?? unpaid.error ?? pays.error;
  if (error) throw new Error(`데이터를 읽지 못했어요 (${error.code ?? error.message})`);
  const ns = (noShows.data ?? []) as unknown as (NoShowRow & { lesson: { id: string } | null })[];
  const taskRows = (tasks.data ?? []) as unknown as TaskRow[];
  const plans = await loadPlans(sb, taskRows.filter((t) => t.kind === 'new_student_matching' && t.enrollment_id).map((t) => t.enrollment_id!));
  const sent = new Map(renewalSent.error ? [] : (renewalSent.data ?? []).map((r) => [r.enrollment_id as string, r.sent_at as string]));
  // 재등록 안내 자동 메일이 정상 발송된 수강권도 '보냄' (함수가 없는 DB면 건너뜀)
  const mailSent = await sb.rpc('admin_renewal_mail_sent');
  // 강사 휴무 신청 (20261113150000 전 DB 는 함수가 없어 건너뜀)
  const timeOffReqs = await sb.rpc('admin_time_off_requests');
  if (!mailSent.error) for (const r of (mailSent.data ?? []) as { enrollment_id: string; sent_at: string }[]) if (!sent.has(r.enrollment_id)) sent.set(r.enrollment_id, r.sent_at);
  const endingRows = (ending.data ?? []) as unknown as EndingRow[];
  const trial = (r: { student?: { is_trial_account?: boolean | null } | { is_trial_account?: boolean | null }[] | null }) => {
    const st = Array.isArray(r.student) ? r.student[0] : r.student;
    return !!st?.is_trial_account;
  };
  // [카드 닫기] 없앰 (대표 11/9) — 새로 닫는 길은 예외 연장 검토 [검토 종료]뿐. 개편 전에 대표가 닫은 카드는 그대로 둠:
  // 같은 상태로 남아 있을 때만 숨고, 새 안내·변경이 생기면(내용이 바뀌면) 다시 보임 (운영 4건이 다시 떠 중복·불필요 카드가 되지 않게)
  const decided = (closures.data ?? []).filter((c) => c.closed);
  const todayRows = (lessons.data ?? []) as unknown as LessonListRow[];
  const todayExtras = await loadLessonExtras(sb, todayRows);
  return {
    tasks: filterClosedTasks(filterActionableTasks([
      ...toTaskSources(taskRows, (leaves.data ?? []) as unknown as LeaveRow[], ns, plans),
      ...toImportChecks((checks.data ?? []) as unknown as ImportCheckRow[], (origins.data ?? []) as unknown as UnknownOriginRow[]),
      ...toEndingSoon(endingRows, now, sent,
        new Set((closures.data ?? []).filter((c) => c.task_kind === 'ending_soon' && !c.closed).map((c) => c.task_id as string))),
      // 1700 전 DB(표·칸 없음)는 건너뜀
      ...(changeNotices.error ? [] : toLessonChanges((changeNotices.data ?? []) as unknown as ChangeNoticeRow[], (openMakeups.data ?? []) as unknown as OpenMakeupRow[], now,
        emailFails.error ? [] : (emailFails.data ?? []) as unknown as EmailFailRow[])),
      // 1800 전 DB는 건너뜀
      ...(leaveOpen.error || leaveNotices.error ? [] : toTutorLeaves((leaveOpen.data ?? []) as unknown as LeaveOpenRow[], (leaveNotices.data ?? []) as unknown as LeaveNoticeRow[], now)),
      // Class Record 미기록은 강사 Home 'Classes to record' 에만 (대표 11/9: 운영진 할 일에서 뺌)
      ...(extReviews.error ? [] : toExtensionReviews((extReviews.data ?? []) as ExtensionReviewRow[])),
      ...(timeOffReqs.error ? [] : toTimeOffRequests((timeOffReqs.data ?? []) as TimeOffRequestRow[])),
    ]), decided),
    today: toLessonItems(todayRows, new Set(ns.map((n) => n.lesson?.id).filter((x): x is string => !!x)), { ...todayExtras, now }),
    stats: {
      activeStudents: new Set(((active.data ?? []) as unknown as { student_id: string; student: { is_trial_account?: boolean } | null }[]).filter((r) => !trial(r)).map((r) => r.student_id)).size,
      unpaid: ((unpaid.data ?? []) as unknown as { student: { is_trial_account?: boolean } | null }[]).filter((r) => !trial(r)).length,
      registrations: monthRegistrations((pays.data ?? []) as unknown as PaymentRow[], today),
      endings: monthEndings(endingRows, now, sent),
    } satisfies DashboardStats,
  };
}

export type DashboardStats = { activeStudents: number; unpaid: number; registrations: RegistrationItem[]; endings: EndingItem[] };

/** 기간별 수업 목록 (한국 날짜 from~to) */
export async function loadLessonRange(sb: SupabaseClient, from: string, to: string): Promise<LessonItem[]> {
  const [l, ns] = await Promise.all([
    sb.from('lessons').select(LESSON_COLS).gte('kst_date', from).lte('kst_date', to).order('starts_at'),
    sb.from('no_show_reports').select('lesson_id').eq('status', 'open'),
  ]);
  if (l.error) throw new Error('수업을 읽지 못했어요.');
  const rows = (l.data ?? []) as unknown as LessonListRow[];
  const extras = await loadLessonExtras(sb, rows);
  return toLessonItems(rows, new Set((ns.data ?? []).map((r) => r.lesson_id as string)), { ...extras, now: new Date() });
}

/** 강사 휴무 신청 반려 (사유 필수, 강사 Home 에 보임) */
export async function rejectTimeOff(sb: SupabaseClient, id: string, reason: string): Promise<void> {
  const r = await sb.rpc('admin_time_off_reject', { p_request: id, p_reason: reason });
  if (r.error) throw new Error(r.error.message);
}
