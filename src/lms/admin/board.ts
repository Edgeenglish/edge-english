// 운영자 대시보드 A안 '처리할 일' 목록 만들기 (POL-OP-13·14, POL-LV-01, POL-TU-02)
// DB의 admin_tasks·long_leave_requests·no_show_reports 행을 화면 항목으로 바꾸고 급한 순서로 정렬한다.
// 화면 문구는 여기 한 곳에서 만든다.
// 표시 원칙 POL-OP-20: 대표 승인·판단 / 자동 처리 실패 / 일정 조율 실패 / 기한 임박 미해결만 올린다.
// 자동 처리로 완료가 확인된 업무는 목록에서 빠진다 (사람이 닫지 않아도 됨). 단순 정보는 여기 넣지 않는다.

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

/** 종료 임박: 남은 정규 수업 2회 이하인데 재등록 결제 확인 전 (학생 화면 재등록 안내와 같은 기준, POL-RN-08) */
export type EndingSoonTask = {
  kind: 'ending_soon';
  id: string;
  studentName: string;
  studentCode: string;
  product: string;
  regularLeft: number;
  endsAt: Date; // 최종 종료일 23:59 KST (이월·고정 시간 마감, POL-RN-01·02)
  tutorName: string | null;
};

/** 보강 미신청: 보강을 받을 수 있는 취소 수업이 있는데 학생이 아직 보강을 신청하지 않음. 기한 = 최종 종료일 (POL-PER-06) */
export type MakeupUnrequestedTask = {
  kind: 'makeup_unrequested';
  id: string;
  studentName: string;
  studentCode: string;
  canceledLesson: string; // 예: '10/13(화) 20:00'
  deadline: Date;
  tutorName: string | null;
};

/** 자동 처리 실패 (POL-OP-20 ②): 캘린더 반영 실패, 메일 반송, 결제 ↔ 수강등록 불일치 */
export type AutoFailureTask = {
  kind: 'auto_failure';
  id: string;
  what: 'calendar_sync' | 'email_bounce' | 'payment_mismatch';
  studentName: string;
  detail: string;
  occurredAt: Date;
};

export type TaskSource = MatchingTask | RenewalTask | LongLeaveTask | NoShowTask | EndingSoonTask | MakeupUnrequestedTask | AutoFailureTask;

/** 요약 카드 5개 = 처리할 일을 나누는 칸. 한 업무는 정확히 한 칸에만 들어감 (중복 없음) */
export type Category = 'matching' | 'tutor_ack' | 'ending' | 'makeup' | 'issue';

export const CATEGORY_LABEL: Record<Category, string> = {
  matching: '신규 학생 매칭',
  tutor_ack: '강사 확인 대기',
  ending: '종료 임박',
  makeup: '보강 미신청',
  issue: '오류·조치 필요',
};

export function categoryOf(kind: TaskSource['kind']): Category {
  switch (kind) {
    case 'new_student_matching':
      return 'matching';
    case 'renewal_tutor_notice':
      return 'tutor_ack';
    case 'ending_soon':
      return 'ending';
    case 'makeup_unrequested':
      return 'makeup';
    default:
      return 'issue'; // 노쇼 신고·자동 처리 실패·장기 연기 승인
  }
}

/** '오류만' 필터: 실제로 문제가 생긴 건 (노쇼 신고, 자동 처리 실패). 승인 대기는 오류가 아님 */
export function isError(kind: TaskSource['kind']): boolean {
  return kind === 'no_show_report' || kind === 'auto_failure';
}

export type Severity = 'urgent' | 'overdue' | 'due_soon' | 'open';
export type StepKey = 'assign_tutor' | 'notify_student' | 'notify_tutor' | 'tutor_ack' | 'check_schedule';

export type BoardItem = {
  id: string;
  kind: TaskSource['kind'];
  category: Category;
  error: boolean;
  /** 학생 상세로 가는 연결 (학생과 관계된 업무만) */
  studentCode: string | null;
  /** 검색용 글자 (학생·강사 이름, 번호, 내용) */
  searchText: string;
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

function toItem(t: TaskSource, now: Date): Omit<BoardItem, 'category' | 'error' | 'studentCode' | 'searchText'> {
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
    case 'ending_soon':
      return {
        id: t.id,
        kind: t.kind,
        severity: dueSeverity(t.endsAt, now),
        tag: '종료 임박',
        title: `${t.studentName} · 정규 ${t.regularLeft}회 남음`,
        detail: `${t.studentCode} · ${t.product}${t.tutorName ? ` · ${t.tutorName}` : ''} · 재등록 결제 확인 전 (학생 화면에 재등록 안내 표시 중)`,
        due: `종료 ${dueText(t.endsAt, now)}`,
        steps: [],
        actions: [{ key: 'renewal_contacted', label: '재등록 안내함', primary: true }],
      };
    case 'makeup_unrequested':
      return {
        id: t.id,
        kind: t.kind,
        severity: dueSeverity(t.deadline, now),
        tag: '보강 미신청',
        title: `${t.studentName} · ${t.canceledLesson} 수업분`,
        detail: `${t.studentCode}${t.tutorName ? ` · ${t.tutorName}` : ''} · 보강을 받을 수 있는데 아직 신청하지 않음`,
        due: `보강 기한 ${dueText(t.deadline, now)}`,
        steps: [],
        actions: [{ key: 'makeup_nudged', label: '학생에게 보강 신청 안내함', primary: true }],
      };
    case 'auto_failure': {
      const what = { calendar_sync: '캘린더 반영 실패', email_bounce: '메일 반송', payment_mismatch: '결제 금액 불일치' }[t.what];
      const action = {
        calendar_sync: { key: 'retry_calendar', label: '다시 반영' },
        email_bounce: { key: 'fix_email', label: '이메일 확인' },
        payment_mismatch: { key: 'check_payment', label: '결제 확인' },
      }[t.what];
      return {
        id: t.id,
        kind: t.kind,
        severity: 'overdue',
        tag: `오류 · ${what}`,
        title: t.studentName,
        detail: t.detail,
        due: `발생 ${kstLabel(t.occurredAt)}`,
        steps: [],
        actions: [{ ...action, primary: true }],
      };
    }
  }
}

function sortKey(t: TaskSource): number {
  switch (t.kind) {
    case 'new_student_matching':
      return t.dueAt.getTime();
    case 'no_show_report':
      return t.reportedAt.getTime();
    case 'ending_soon':
      return t.endsAt.getTime();
    case 'makeup_unrequested':
      return t.deadline.getTime();
    case 'auto_failure':
      return t.occurredAt.getTime();
    default:
      return t.createdAt.getTime();
  }
}

/** 급한 순서: 노쇼 신고 → 기한 초과 → 24시간 안 → 나머지(기한 빠른 순, 오래된 순) */
export function buildBoard(tasks: TaskSource[], now: Date): BoardItem[] {
  return tasks
    .map((t) => {
      const base = toItem(t, now);
      const studentCode = 'studentCode' in t && t.studentCode ? t.studentCode : null;
      const searchText = [base.tag, base.title, base.detail, studentCode, 'tutorName' in t ? t.tutorName : null].filter(Boolean).join(' ').toLowerCase();
      return { t, item: { ...base, category: categoryOf(t.kind), error: isError(t.kind), studentCode, searchText } };
    })
    .sort((a, b) => SEVERITY_RANK[a.item.severity] - SEVERITY_RANK[b.item.severity] || sortKey(a.t) - sortKey(b.t))
    .map((x) => x.item);
}

/** 필터: 전체 / 긴급(노쇼·기한 초과·24시간 안) / 오류만 / 요약 카드 한 칸 */
export type BoardFilter = 'all' | 'urgent' | 'error' | Category;

export function isUrgent(i: BoardItem): boolean {
  return i.severity !== 'open';
}

/** 검색: 학생·강사 이름, 학생 번호, 내용 (띄어쓰기 무시) */
export function searchBoard(items: BoardItem[], q: string): BoardItem[] {
  const k = q.trim().toLowerCase().replace(/\s+/g, '');
  if (!k) return items;
  return items.filter((i) => i.searchText.replace(/\s+/g, '').includes(k));
}

export function filterBoard(items: BoardItem[], f: BoardFilter): BoardItem[] {
  if (f === 'all') return items;
  if (f === 'urgent') return items.filter(isUrgent);
  if (f === 'error') return items.filter((i) => i.error);
  return items.filter((i) => i.category === f);
}

/** 요약 카드 5개의 숫자 (칸별 개수 + 그중 긴급 개수). 합계 = 전체 개수 */
export function categoryCounts(items: BoardItem[]): Record<Category, { n: number; urgent: number }> {
  const out = Object.fromEntries((Object.keys(CATEGORY_LABEL) as Category[]).map((c) => [c, { n: 0, urgent: 0 }])) as Record<Category, { n: number; urgent: number }>;
  for (const i of items) {
    out[i.category].n++;
    if (isUrgent(i)) out[i.category].urgent++;
  }
  return out;
}
