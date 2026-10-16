// 운영자 대시보드 A안 '처리할 일' 목록 만들기 (POL-OP-13·14, POL-LV-01, POL-TU-02)
// DB의 admin_tasks·long_leave_requests·no_show_reports 행을 화면 항목으로 바꾸고 급한 순서로 정렬한다.
// 화면 문구는 여기 한 곳에서 만든다.

import { formatInZone, hoursBetween } from '../rules/dates';

export type MatchingTask = {
  kind: 'new_student_matching';
  id: string;
  studentName: string;
  studentCode: string;
  product: string; // 예: '50분 주2회 4주'
  dueAt: Date;
  tutorName: string | null;
  tutorAssignedAt: Date | null;
  studentNotifiedAt: Date | null;
};

export type RenewalTask = {
  kind: 'renewal_tutor_notice';
  id: string;
  studentName: string;
  studentCode: string;
  product: string;
  newPeriod: string; // 예: '10/20(화)–11/16(월)' (기한 안 재등록은 이전 종료 뒤 첫 정규 수업일부터, A25)
  tutorName: string | null;
  tutorChangePlanned: boolean;
  tutorNotifiedAt: Date | null;
  tutorAcknowledgedAt: Date | null;
  scheduleCheckedAt: Date | null;
  createdAt: Date;
};

export type LongLeaveTask = {
  kind: 'long_leave_request';
  id: string;
  studentName: string;
  studentCode: string;
  from: string;
  to: string;
  days: number;
  reason: 'health' | 'family_emergency' | 'business_trip' | 'other_special';
  createdAt: Date;
};

export type NoShowTask = {
  kind: 'no_show_report';
  id: string;
  studentName: string;
  tutorName: string;
  lessonStartsAt: Date;
  reportedAt: Date;
};

export type TaskSource = MatchingTask | RenewalTask | LongLeaveTask | NoShowTask;

export type Severity = 'urgent' | 'overdue' | 'due_soon' | 'open';
export type StepKey = 'assign_tutor' | 'notify_student' | 'notify_tutor' | 'tutor_ack' | 'check_schedule';

export type BoardItem = {
  id: string;
  kind: TaskSource['kind'];
  severity: Severity;
  tag: string;
  title: string;
  detail: string;
  due: string | null;
  steps: { key: StepKey; label: string; done: boolean }[];
  actions: { key: string; label: string; primary?: boolean; danger?: boolean }[];
};

const KST = 'Asia/Seoul';
const SEVERITY_RANK: Record<Severity, number> = { urgent: 0, overdue: 1, due_soon: 2, open: 3 };
const REASON_KO = { health: '건강', family_emergency: '가족 긴급 사정', business_trip: '출장', other_special: '기타 특별 사유' } as const;
const WD: Record<string, string> = { Sun: '일', Mon: '월', Tue: '화', Wed: '수', Thu: '목', Fri: '금', Sat: '토' };

function kstLabel(d: Date): string {
  const f = formatInZone(d, KST);
  return `${Number(f.date.slice(5, 7))}/${Number(f.date.slice(8, 10))}(${WD[f.weekday] ?? f.weekday}) ${f.time}`;
}

/** 기한 상태: 초과 / 24시간 안 / 여유 (DB 뷰 admin_task_board 와 같은 기준) */
export function dueSeverity(dueAt: Date | null, now: Date): Severity {
  if (!dueAt) return 'open';
  if (now.getTime() > dueAt.getTime()) return 'overdue';
  if (hoursBetween(now, dueAt) <= 24) return 'due_soon';
  return 'open';
}

export function dueText(dueAt: Date, now: Date): string {
  const h = hoursBetween(now, dueAt);
  if (h < 0) {
    const late = -h;
    return `기한 ${late >= 24 ? `${Math.floor(late / 24)}일` : `${Math.max(1, Math.floor(late))}시간`} 지남 · ${kstLabel(dueAt)}까지였음`;
  }
  if (h <= 24) return `${Math.max(1, Math.floor(h))}시간 남음 · ${kstLabel(dueAt)}까지`;
  return `${kstLabel(dueAt)}까지`;
}

function toItem(t: TaskSource, now: Date): BoardItem {
  switch (t.kind) {
    case 'new_student_matching': {
      const steps = [
        { key: 'assign_tutor' as const, label: t.tutorName ? `강사 배정 · ${t.tutorName}` : '강사 배정', done: !!t.tutorAssignedAt },
        { key: 'notify_student' as const, label: '학생에게 강사·첫 수업 안내', done: !!t.studentNotifiedAt },
      ];
      return {
        id: t.id,
        kind: t.kind,
        severity: dueSeverity(t.dueAt, now),
        tag: '신규 매칭',
        title: `${t.studentName} · ${t.product}`,
        detail: `${t.studentCode} · 결제 확인 후 3영업일 안에 강사 배정과 학생 안내까지`,
        due: dueText(t.dueAt, now),
        steps,
        actions: !t.tutorAssignedAt
          ? [{ key: 'assign_tutor', label: '강사 배정', primary: true }]
          : [{ key: 'notify_student', label: '학생 안내 완료', primary: true }],
      };
    }
    case 'renewal_tutor_notice': {
      const steps = [
        { key: 'notify_tutor' as const, label: '강사에게 연장·기간·일정 통보', done: !!t.tutorNotifiedAt },
        { key: 'tutor_ack' as const, label: '강사 확인', done: !!t.tutorAcknowledgedAt },
        { key: 'check_schedule' as const, label: '일정 조치', done: !!t.scheduleCheckedAt },
      ];
      const next = steps.find((s) => !s.done)?.key;
      const actions: BoardItem['actions'] =
        next === 'notify_tutor'
          ? [{ key: 'notify_tutor', label: '강사에게 통보', primary: true }]
          : next === 'tutor_ack'
            ? [
                { key: 'remind_tutor', label: '강사에게 다시 알림' },
                { key: 'tutor_ack', label: '강사 확인 대신 기록', primary: true },
              ]
            : [{ key: 'check_schedule', label: '일정 조치 완료', primary: true }];
      return {
        id: t.id,
        kind: t.kind,
        severity: 'open',
        tag: t.tutorChangePlanned ? '재등록 · 강사 변경' : '재등록 강사 확인',
        title: `${t.studentName} · ${t.tutorName ?? '담당 강사 미정'}`,
        detail: `${t.studentCode} · ${t.product} · 새 기간 ${t.newPeriod}${t.tutorChangePlanned ? ' · 강사 변경 예정이라 새 강사 배정 필요' : ''}`,
        due: t.tutorNotifiedAt && !t.tutorAcknowledgedAt ? `통보 후 ${Math.max(1, Math.floor(hoursBetween(t.tutorNotifiedAt, now)))}시간째 미확인` : null,
        steps,
        actions,
      };
    }
    case 'long_leave_request':
      return {
        id: t.id,
        kind: t.kind,
        severity: 'open',
        tag: '장기 연기 승인',
        title: `${t.studentName} · ${t.days}일`,
        detail: `${t.studentCode} · ${t.from} ~ ${t.to} · 사유: ${REASON_KO[t.reason]} · 증빙 확인 후 승인`,
        due: null,
        steps: [],
        actions: [
          { key: 'reject_leave', label: '거절' },
          { key: 'approve_leave', label: '증빙 확인 · 승인', primary: true },
        ],
      };
    case 'no_show_report':
      return {
        id: t.id,
        kind: t.kind,
        severity: 'urgent',
        tag: '노쇼 신고',
        title: `${t.studentName} · ${kstLabel(t.lessonStartsAt).split(' ')[1]} · ${t.tutorName}`,
        detail: `학생이 ${Math.max(1, Math.round(hoursBetween(t.reportedAt, now) * 60))}분 전에 '강사가 안 들어왔어요'를 눌렀어요.`,
        due: null,
        steps: [],
        actions: [
          { key: 'tutor_arrived', label: '강사 들어옴(지각)' },
          { key: 'confirm_no_show', label: '노쇼 확정', danger: true },
        ],
      };
  }
}

function sortKey(t: TaskSource): number {
  if (t.kind === 'new_student_matching') return t.dueAt.getTime();
  if (t.kind === 'no_show_report') return t.reportedAt.getTime();
  return t.createdAt.getTime();
}

/** 급한 순서: 노쇼 신고 → 기한 초과 → 24시간 안 → 나머지(기한 빠른 순, 오래된 순) */
export function buildBoard(tasks: TaskSource[], now: Date): BoardItem[] {
  return tasks
    .map((t) => ({ t, item: toItem(t, now) }))
    .sort((a, b) => SEVERITY_RANK[a.item.severity] - SEVERITY_RANK[b.item.severity] || sortKey(a.t) - sortKey(b.t))
    .map((x) => x.item);
}

/** 화면 위쪽 숫자 */
export function boardCounts(items: BoardItem[]) {
  return {
    total: items.length,
    overdue: items.filter((i) => i.severity === 'overdue' || i.severity === 'urgent').length,
    matching: items.filter((i) => i.kind === 'new_student_matching').length,
    renewal: items.filter((i) => i.kind === 'renewal_tutor_notice').length,
  };
}
