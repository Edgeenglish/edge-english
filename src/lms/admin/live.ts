// 운영자 대시보드 실제 데이터 (시험용 Supabase) — DB 행을 board.ts 의 TaskSource 로 바꾼다
// 읽기는 로그인한 운영자(aal2) 토큰으로 RLS 를 거친다. 쓰기(처리 버튼)는 서버 기능을 만든 뒤 연결 (POL-AC-07: 쓰기는 서버만)
// 표시 원칙 POL-OP-20: 열린 업무만 가져온다 (완료·취소된 업무는 목록에 오지 않음)

import type { SupabaseClient } from '@supabase/supabase-js';
import { addDays, formatInZone, instantToKstDate, type KstDate } from '../rules/dates';
import type { TaskSource } from './board';
import type { FakeLesson } from './fake-data';

const WD = ['일', '월', '화', '수', '목', '금', '토'];
const short = (d: KstDate) => `${Number(d.slice(5, 7))}/${Number(d.slice(8, 10))}(${WD[new Date(`${d}T00:00:00Z`).getUTCDay()]})`;

type Enrollment = { weeks: number | null; legacy_label: string | null; weekly_count: number; duration_min: number; start_date: string; base_end_date: string; student: { name_ko: string; code: string } | null };

export type TaskRow = {
  id: string;
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

function product(e: Enrollment | null): string {
  if (!e) return '수강 정보 없음';
  const term = e.weeks ? `${e.weeks}주` : (e.legacy_label ?? '');
  return `${e.duration_min}분 주${e.weekly_count}회 ${term}`.trim();
}

export function toTaskSources(tasks: TaskRow[], leaves: LeaveRow[], noShows: NoShowRow[]): TaskSource[] {
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

/** 시험용 DB에서 운영자 대시보드 데이터 읽기 (운영자 aal2 세션 필요 — 아니면 RLS 때문에 0건) */
export async function loadAdminBoard(sb: SupabaseClient, now: Date) {
  const today = instantToKstDate(now);
  const [tasks, leaves, noShows, lessons] = await Promise.all([
    sb
      .from('admin_tasks')
      .select(
        'id, kind, due_at, created_at, tutor_assigned_at, student_notified_at, tutor_notified_at, tutor_acknowledged_at, schedule_checked_at, tutor_change_planned, tutor:tutors(name), enrollment:enrollments(weeks, legacy_label, weekly_count, duration_min, start_date, base_end_date, student:students(name_ko, code))',
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
  ]);
  const error = tasks.error ?? leaves.error ?? noShows.error ?? lessons.error;
  if (error) throw new Error(`데이터를 읽지 못했어요 (${error.code ?? error.message})`);
  const ns = (noShows.data ?? []) as unknown as (NoShowRow & { lesson: { id: string } | null })[];
  return {
    tasks: toTaskSources((tasks.data ?? []) as unknown as TaskRow[], (leaves.data ?? []) as unknown as LeaveRow[], ns),
    today: toTodayLessons((lessons.data ?? []) as unknown as LessonRow[], new Set(ns.map((n) => n.lesson?.id).filter((x): x is string => !!x))),
  };
}
