// 운영자 대시보드 실제 데이터 (시험용 Supabase) — DB 행을 board.ts 의 TaskSource 로 바꾼다
// 읽기는 로그인한 운영자(aal2) 토큰으로 RLS 를 거친다. 쓰기(처리 버튼)는 서버 기능을 만든 뒤 연결 (POL-AC-07: 쓰기는 서버만)
// 표시 원칙 POL-OP-20: 열린 업무만 가져온다 (완료·취소된 업무는 목록에 오지 않음)

import type { SupabaseClient } from '@supabase/supabase-js';
import { addDays, endOfKstDay, formatInZone, instantToKstDate, type KstDate } from '../rules/dates';
import { courseName } from '../rules/period';
import { grantsMakeup, type ClassStatus } from '../rules/status';
import { RENEWAL_PROMPT } from '../student/home';
import type { TaskSource } from './board';
import type { PlanView } from './confirm';
import { loadPlans } from './confirm-live';
import type { FakeLesson, OpsStats } from './fake-data';
import { loadMissingRecords, type MissingRecord } from '../tutor/live';

const WD = ['일', '월', '화', '수', '목', '금', '토'];
const short = (d: KstDate) => `${Number(d.slice(5, 7))}/${Number(d.slice(8, 10))}(${WD[new Date(`${d}T00:00:00Z`).getUTCDay()]})`;

type Enrollment = { weeks: number | null; legacy_label: string | null; weekly_count: number; duration_min: number; start_date: string; base_end_date: string; student: { name_ko: string; code: string } | null };

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
    const studentName = t.enrollment?.student?.name_ko ?? '(학생 정보 없음)';
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
      studentName: l.enrollment?.student?.name_ko ?? '(학생 정보 없음)',
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
      studentName: n.lesson.student?.name_ko ?? '(학생)',
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
      student: l.student?.name_ko ?? '(학생)',
      tutor: l.tutor?.name ?? '(강사)',
      state: openNoShowLessonIds.has(l.id)
        ? '노쇼 신고'
        : l.state === 'done'
          ? '완료'
          : l.state === 'canceled'
            ? l.class_status?.startsWith('Student') ? '학생 변경' : '취소'
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

/** 기존 학생 입력 뒤 시트 대조 전 · 보강 원래 날짜 확인 필요 → 학생(수강등록)마다 한 줄 */
export function toImportChecks(checks: ImportCheckRow[], origins: UnknownOriginRow[]): TaskSource[] {
  const out = new Map<string, Extract<TaskSource, { kind: 'import_check' }>>();
  const row = (eid: string, e: ImportCheckRow['enrollment'], created: string) => {
    if (!out.has(eid))
      out.set(eid, { kind: 'import_check', id: eid, studentName: e?.student?.name_ko ?? '(학생 정보 없음)', studentCode: e?.student?.code ?? '', counts: null, unknownOrigins: [], createdAt: new Date(created) });
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
type OpenMakeupRow = { created_at: string; tutor_answered_at?: string | null; student: { id: string; name_ko: string; code: string } | null };

/** 수업 변경·보강 (1700): 안 보낸 안내 · 강사 답 대기 보강 → 학생마다 한 줄 */
export function toLessonChanges(notices: ChangeNoticeRow[], makeups: OpenMakeupRow[], now: Date): TaskSource[] {
  const out = new Map<string, Extract<TaskSource, { kind: 'lesson_change' }>>();
  const row = (s: { id: string; name_ko: string; code: string }, created: string) => {
    if (!out.has(s.id)) out.set(s.id, { kind: 'lesson_change', id: s.id, studentName: s.name_ko, studentCode: s.code, pendingNotices: 0, openMakeups: 0, lessonAt: null, createdAt: new Date(created) });
    return out.get(s.id)!;
  };
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
    const r = row(m.student, m.created_at);
    r.openMakeups += 1;
    if (m.tutor_answered_at) r.answeredMakeups = (r.answeredMakeups ?? 0) + 1;
    else if (!r.makeupWaitingSince || new Date(m.created_at) < r.makeupWaitingSince) r.makeupWaitingSince = new Date(m.created_at);
  }
  return [...out.values()];
}

/** 강사 답 칸(tutor_answered_at, migration 2000)이 없는 DB면 그 칸 없이 다시 읽음 */
async function loadOpenMakeups(sb: SupabaseClient) {
  const q = (cols: string) => sb.from('makeup_requests').select(cols).in('status', ['requested', 'countered']);
  const r = await q('created_at, tutor_answered_at, student:students(id, name_ko, code)');
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
  // 1단계(대체강사 고르기·강사 답)가 남은 학생은 2단계 글을 아직 보낼 수 없음
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
      // 2단계 글(휴무 안내 + 대체강사 제안)은 학생마다 하나
      ns.notify += 1;
      if (n.event === 'sub_student') ns.proposeLessons = (ns.proposeLessons ?? 0) + 1;
      const sid = n.leave?.student_id;
      // 정해진 날짜부터 먼저 안내 (대표 10/30): 그 수업 자체가 미정·강사 답 대기면 아직 못 보냄. choice 를 못 읽는 옛 응답은 학생 단위로
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
  student: { name_ko: string; code: string } | null;
  /** 이 수강권의 모든 수업 (POL-RN-08: 정규·보강·보상·이월 다 셈, 2026-10-27 대표) */
  lessons: { id: string; kind: string; state: 'scheduled' | 'canceled' | 'done'; starts_at: string; class_status: string | null; makeup_of: string | null; voided_at: string | null; tutor: { name: string } | null }[];
  /** 시트에서 넘어온 날짜 미정 보강 (makeup_open) */
  migrated?: { kind: string }[];
};

/**
 * 종료 임박 (POL-RN-08): 학생마다 마지막 수강권(결제 확인·수강 중)만 보고, 지금 이후 예정 정규 수업이 2회 이하면 한 줄.
 * Class Record 완료 기록이 없어도 날짜로 셈(지난 예정 수업은 한 것으로 봄). 결제 확인된 재등록 수강권이 있으면 그쪽이 마지막이라 빠짐.
 * 정규 수업이 아직 하나도 없는 수강권(신규 매칭 전)은 신규 매칭 칸에서 다룸
 */
/** sent: 수강권 id → 재등록 안내 [보냄] 시각 (migration 1900, 없으면 빈 목록) */
export function toEndingSoon(rows: EndingRow[], now: Date, sent: Map<string, string> = new Map()): TaskSource[] {
  const latest = new Map<string, EndingRow>();
  for (const r of rows) {
    const cur = latest.get(r.student_id);
    if (!cur || r.final_end_date > cur.final_end_date) latest.set(r.student_id, r);
  }
  const out: TaskSource[] = [];
  for (const r of latest.values()) {
    // 정규 수업이 아직 없는 수강권(신규 매칭 전)은 제외. 기존 학생 입력으로 넣은 '다 끝난 수강권'(수강 중, 남은 0회)은 재등록 대기로 보여 줌 (migration 2200)
    if (r.status !== 'active' && !r.lessons.some((l) => l.kind === 'regular')) continue;
    const left = r.lessons.filter((l) => l.state === 'scheduled' && new Date(l.starts_at) > now).sort((a, b) => a.starts_at.localeCompare(b.starts_at));
    // 날짜 미정 보강: 보강 권리가 있는 취소 수업 중 살아 있는 보강이 없는 것 + 시트에서 넘어온 미예약 보강
    const booked = new Set(r.lessons.filter((l) => l.makeup_of && l.state !== 'canceled').map((l) => l.makeup_of));
    const owed = r.lessons.filter((l) => l.state === 'canceled' && !l.voided_at && l.class_status
      && (grantsMakeup(l.class_status as ClassStatus) || l.class_status === 'Tutor long-term leave') && !booked.has(l.id)).length
      + (r.migrated ?? []).filter((m) => m.kind === 'makeup_open').length;
    if (left.length + owed > RENEWAL_PROMPT.maxLessonsLeft) continue;
    const last = [...r.lessons].sort((a, b) => b.starts_at.localeCompare(a.starts_at))[0];
    out.push({
      kind: 'ending_soon',
      id: r.id,
      studentName: r.student?.name_ko ?? '(학생 정보 없음)',
      studentCode: r.student?.code ?? '',
      product: product(r),
      lessonsLeft: left.length + owed,
      endsAt: endOfKstDay(r.final_end_date),
      tutorName: (left[0] ?? last)?.tutor?.name ?? null,
      noticeSentAt: sent.has(r.id) ? new Date(sent.get(r.id)!) : null,
    });
  }
  return out;
}

// migration 1500 전 DB에는 표가 없음 → 대시보드는 그대로 보이게 빈 목록
const missingTable = (e: { code?: string } | null) => !!e && (e.code === '42P01' || e.code === 'PGRST205');

/** 시험용 DB에서 운영자 대시보드 데이터 읽기 (운영자 aal2 세션 필요 — 아니면 RLS 때문에 0건) */
export async function loadAdminBoard(sb: SupabaseClient, now: Date) {
  const today = instantToKstDate(now);
  const off = 'off:tutor_time_off(id, starts_at, ends_at, created_at, tutor:tutors(name))';
  const [tasks, leaves, noShows, lessons, checks, origins, changeNotices, openMakeups, ending, leaveOpen, leaveNotices, renewalSent, missing] = await Promise.all([
    sb
      .from('admin_tasks')
      .select(
        'id, kind, enrollment_id, due_at, created_at, tutor_assigned_at, student_notified_at, tutor_notified_at, tutor_acknowledged_at, schedule_checked_at, tutor_change_planned, tutor:tutors(name), enrollment:enrollments(weeks, legacy_label, weekly_count, duration_min, start_date, base_end_date, student:students(name_ko, code))',
      )
      .eq('status', 'open'),
    sb.from('long_leave_requests').select('id, leave_start, days, reason_kind, created_at, enrollment:enrollments(student:students(name_ko, code))').eq('status', 'pending'),
    sb
      .from('no_show_reports')
      .select('id, reported_at, lesson:lessons(id, starts_at, student:students(name_ko), tutor:tutors!lessons_tutor_id_fkey(name))')
      .eq('status', 'open'),
    sb
      .from('lessons')
      .select('id, starts_at, kind, state, class_status, student:students(name_ko), tutor:tutors!lessons_tutor_id_fkey(name)')
      .eq('kst_date', today),
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
    sb
      .from('enrollments')
      .select('id, student_id, status, weeks, legacy_label, weekly_count, duration_min, final_end_date, student:students(name_ko, code), lessons!lessons_enrollment_id_fkey(id, kind, state, starts_at, class_status, makeup_of, voided_at, tutor:tutors!lessons_tutor_id_fkey(name)), migrated:migrated_items(kind)')
      .in('status', ['confirmed', 'active']),
    sb.from('leave_items').select(`student_id, starts_at, choice, sub_stage, lesson_gone_at, ${off}`).or('choice.eq.undecided,sub_stage.in.(asked,tutor_ok)'),
    sb.from('lesson_notices').select(`event, leave:leave_items(student_id, lesson_gone_at, choice, sub_stage, ${off})`).eq('status', 'pending').not('leave_item_id', 'is', null),
    sb.from('renewal_notices').select('enrollment_id, sent_at'),
    loadMissingRecords(sb),
  ]);
  const error = tasks.error ?? leaves.error ?? noShows.error ?? lessons.error ?? (missingTable(checks.error) ? null : checks.error) ?? (missingTable(origins.error) ? null : origins.error) ?? ending.error;
  if (error) throw new Error(`데이터를 읽지 못했어요 (${error.code ?? error.message})`);
  const ns = (noShows.data ?? []) as unknown as (NoShowRow & { lesson: { id: string } | null })[];
  const taskRows = (tasks.data ?? []) as unknown as TaskRow[];
  const plans = await loadPlans(sb, taskRows.filter((t) => t.kind === 'new_student_matching' && t.enrollment_id).map((t) => t.enrollment_id!));
  return {
    tasks: [
      ...toTaskSources(taskRows, (leaves.data ?? []) as unknown as LeaveRow[], ns, plans),
      ...toImportChecks((checks.data ?? []) as unknown as ImportCheckRow[], (origins.data ?? []) as unknown as UnknownOriginRow[]),
      ...toEndingSoon((ending.data ?? []) as unknown as EndingRow[], now,
        // 1900 전 DB는 표가 없음 → 보냄 기록 없이
        new Map(renewalSent.error ? [] : (renewalSent.data ?? []).map((r) => [r.enrollment_id as string, r.sent_at as string]))),
      // 1700 전 DB(표·칸 없음)는 건너뜀
      ...(changeNotices.error ? [] : toLessonChanges((changeNotices.data ?? []) as unknown as ChangeNoticeRow[], (openMakeups.data ?? []) as unknown as OpenMakeupRow[], now)),
      // 1800 전 DB는 건너뜀
      ...(leaveOpen.error || leaveNotices.error ? [] : toTutorLeaves((leaveOpen.data ?? []) as unknown as LeaveOpenRow[], (leaveNotices.data ?? []) as unknown as LeaveNoticeRow[], now)),
      // 2000 전 DB는 null
      ...toMissingRecords(missing ?? []),
    ],
    today: toTodayLessons((lessons.data ?? []) as unknown as LessonRow[], new Set(ns.map((n) => n.lesson?.id).filter((x): x is string => !!x))),
  };
}

/** 상단 운영 현황 3개: 수강 중 학생 · 이번 주(월~일, KST) 수업 진행/전체 · 이번 달 결제 확인된 등록(신규/재등록) */
export async function loadOpsStats(sb: SupabaseClient, now: Date): Promise<OpsStats | null> {
  const today = instantToKstDate(now);
  const dow = new Date(`${today}T00:00:00Z`).getUTCDay();
  const monday = addDays(today, -((dow + 6) % 7));
  const monthStart = `${today.slice(0, 8)}01`;
  const [active, week, pays] = await Promise.all([
    sb.from('enrollments').select('student_id').eq('status', 'active'),
    sb.from('lessons').select('state').gte('kst_date', monday).lte('kst_date', addDays(monday, 6)).neq('state', 'canceled'),
    sb.from('payments').select('enrollment:enrollments(previous_enrollment_id)').gte('confirmed_at', `${monthStart}T00:00:00+09:00`),
  ]);
  if (active.error || week.error || pays.error) return null;
  const p = (pays.data ?? []) as unknown as { enrollment: { previous_enrollment_id: string | null } | null }[];
  return {
    activeStudents: new Set((active.data ?? []).map((r) => r.student_id)).size,
    weekLessons: { done: (week.data ?? []).filter((r) => r.state === 'done').length, total: (week.data ?? []).length },
    monthEnrollments: { fresh: p.filter((r) => !r.enrollment?.previous_enrollment_id).length, renewal: p.filter((r) => !!r.enrollment?.previous_enrollment_id).length },
  };
}
