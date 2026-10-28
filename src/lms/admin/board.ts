// 운영자 대시보드 A안 '처리할 일' 목록 만들기 (POL-OP-13·14, POL-LV-01, POL-TU-02)
// DB의 admin_tasks·long_leave_requests·no_show_reports 행을 화면 항목으로 바꾸고 급한 순서로 정렬한다.
// 화면 문구는 여기 한 곳에서 만든다.
// 표시 원칙 POL-OP-20: 대표 승인·판단 / 자동 처리 실패 / 일정 조율 실패 / 기한 임박 미해결만 올린다.
// 자동 처리로 완료가 확인된 업무는 목록에서 빠진다 (사람이 닫지 않아도 됨). 단순 정보는 여기 넣지 않는다.

import { formatInZone, hoursBetween } from '../rules/dates';
import { firstLessonAt, planAlert, type PlanView } from './confirm';

/** 수업 변경 안내 종류 → 카드 맨 위 '무슨 일' (lesson_notices.event, migration 1700) */
const CHANGE_EVENT_TEXT: Record<string, string> = {
  change: '수업 취소', makeup_ask: '보강 강사에게 묻기', makeup_confirmed: '보강 확정', makeup_voided: '보강 취소', revert: '취소 되돌림',
};
const noticeWho = (to: ('student' | 'tutor')[] = []) =>
  to.includes('student') && to.includes('tutor') ? '학생·강사' : to.includes('tutor') ? '강사' : to.includes('student') ? '학생' : '안내';

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
  /** 강사 답 대기·확정 일정안 (H22). 없으면 아직 강사·시간을 안 고름 */
  plan?: PlanView | null;
  /** 강사·시간 고르기 화면으로 갈 때 쓰는 수강등록 번호 */
  enrollmentId?: string;
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
  lessonsLeft: number;
  endsAt: Date; // 최종 종료일 23:59 KST (이월·고정 시간 마감, POL-RN-01·02)
  tutorName: string | null;
  /** 재등록 안내 문자 [보냄] 기록 (migration 1900). 없으면 안 보냄 */
  noticeSentAt: Date | null;
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

/** 기존 학생 입력 뒤 시트 대조 전 · 보강 원래 날짜 확인 필요 (D-52 확대판, 2026-10-24 대표 결정 ②④⑤). 확인하면 사라짐 */
export type ImportCheckTask = {
  kind: 'import_check';
  id: string; // 수강등록 번호
  studentName: string;
  studentCode: string;
  /** 시트 대조 전이면 LMS·시트 남은 수업 (대조 완료면 null) */
  counts: { lmsLeft: number; sheetLeft: number } | null;
  /** 원래 수업 날짜를 아직 확인하지 못한 보강 */
  unknownOrigins: { id: string; label: string }[];
  /** 종료일이 기간 계산과 다른데 이유를 안 고름 (대조 완료와 따로, 이유를 정해야 사라짐) */
  endReason?: { days: number; weeks: number | null } | null;
  createdAt: Date;
};

/** 수업 변경·보강: 안 보낸 안내 · 강사 답을 기다리는 보강 신청 (migration 1700). 학생마다 한 줄, [보냄]·확정하면 사라짐 */
export type LessonChangeTask = {
  kind: 'lesson_change';
  id: string; // 학생 번호(id)
  studentName: string;
  studentCode: string;
  pendingNotices: number;
  /** 안 보낸 안내의 종류(change·makeup_ask·…)와 받는 사람·수업 시각 — 카드에 '무슨 일 · 안내 보내기'로 (2026-10-28 대표) */
  noticeEvents?: string[];
  noticeTo?: ('student' | 'tutor')[];
  noticeLessonAt?: Date | null;
  openMakeups: number;
  /** 그중 강사가 강사 LMS에서 가능 여부를 답한 보강 신청 (운영진 확정 차례, migration 2000) */
  answeredMakeups?: number;
  /** 안 보낸 변경 안내가 있는 가장 가까운 수업 (지나기 전에 보내야 함) */
  lessonAt: Date | null;
  createdAt: Date;
};

/** 강사 휴무 처리 (migration 1800): 학생 선택 미확인 · 대체강사 답 대기 · 학생 OK 대기 · 안 보낸 안내. 휴무 1건당 한 줄, 다 처리하면 사라짐 */
export type TutorLeaveTask = {
  kind: 'tutor_leave';
  id: string; // 휴무 번호
  tutorName: string;
  from: string; // KST 날짜
  to: string;
  undecidedStudents: number;
  tutorReply: number;
  studentReply: number;
  pendingNotices: number;
  /** 안 보낸 안내를 휴무 화면 단계별로: 1 휴무 안내(leave_options) · 3 대체강사(sub_ask) · 4 학생 확정(sub_student·sub_confirmed) */
  noticeSteps?: { notify: number; tutor: number; confirm: number };
  /** 아직 처리 안 된 가장 가까운 수업 (지나기 전에 정해야 함) */
  firstOpenAt: Date | null;
  createdAt: Date;
};

/** Class Record 미기록 (migration 2000): 강사 LMS 계정이 있는 강사의 수업이 끝나고 10분 지나도 기록 없음 (POL-TU-06). 강사마다 한 줄, 기록하면 사라짐 */
export type ClassRecordMissingTask = {
  kind: 'class_record_missing';
  id: string; // 강사 번호
  tutorName: string;
  lessons: { studentName: string; startsAt: Date }[];
  createdAt: Date;
};

export type TaskSource = MatchingTask | RenewalTask | LongLeaveTask | NoShowTask | EndingSoonTask | MakeupUnrequestedTask | AutoFailureTask | ImportCheckTask | LessonChangeTask | TutorLeaveTask | ClassRecordMissingTask;

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
  /** done: 끝난 단계(회색 ✓, 못 누름) · disabled: 앞 단계가 안 끝나 아직 못 누름 */
  actions: { key: string; label: string; primary?: boolean; danger?: boolean; href?: string; done?: boolean; disabled?: boolean }[];
  /** 신규 매칭의 일정안 — 화면이 PlanCard(확정·안내 복사)로 그림 */
  plan?: PlanView;
  /** 첫 수업 24시간 안인데 안내 미완료 → 목록 맨 위 (D-51-3) */
  top?: boolean;
  /** 기존 학생 입력: 원래 날짜 확인 필요 보강 — 화면이 날짜 입력칸으로 그림 */
  unknownOrigins?: { id: string; label: string }[];
  /** 기존 학생 입력: 종료일 이유 확인 — 화면이 이유 고르기로 그림 */
  endReason?: { days: number; weeks: number | null } | null;
  /** 종료 임박: 재등록 안내 문자 (복사) + [보냄] 기록 — 화면이 RenewalNotice로 그림 */
  renewal?: { text: string; sentAt: Date | null };
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

/**
 * 재등록 안내 문자 (2026-10-28 대표: 당분간 문자로 안내 → 복사해서 보냄). 마감 = 종료일 23:59 KST (POL-RN-01 이월 · POL-RN-02 고정 시간)
 * 남은 수업이 없으면 이월 문장은 뺌
 */
export function renewalMessage(name: string, lessonsLeft: number, endsAt: Date): string {
  const f = formatInZone(endsAt, KST);
  const day = `${Number(f.date.slice(5, 7))}월 ${Number(f.date.slice(8, 10))}일(${WD[f.weekday] ?? f.weekday})`;
  return [
    `[엣지영어] ${name}님, ${lessonsLeft > 0 ? `수업이 ${lessonsLeft}회 남았어요.` : '이번 수강기간 수업이 모두 끝나 가요.'} (종료일 ${day})`,
    `종료일 ${day} 밤 11시 59분까지 재등록 결제를 마치시면 ${lessonsLeft > 0 ? '남은 수업은 다음 수강기간으로 이어지고, ' : ''}지금 수업 요일·시간도 그대로 유지돼요.`,
    '재등록을 원하시면 편하게 답장 주세요. 😊',
  ].join('\n\n');
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
      if (t.plan) return planItem(t, t.plan, now);
      // 할 일 목록(○ 강사 배정 · ○ 학생 안내)은 버튼과 같은 말이라 안 보임 — 지금 할 일은 버튼 하나로 (2026-10-28 대표)
      return {
        id: t.id,
        kind: t.kind,
        severity: dueSeverity(t.dueAt, now),
        tag: '신규 매칭',
        title: `${t.studentName} · ${t.product}`,
        detail: t.tutorName ? `${t.studentCode} · ${t.tutorName}` : t.studentCode,
        due: dueText(t.dueAt, now),
        steps: [],
        // 두 단계 버튼을 늘 같이 보임. 끝난 단계는 회색 ✓, 앞 단계가 안 끝난 버튼은 못 누름 (2026-10-28 대표)
        actions: [
          t.tutorAssignedAt
            ? { key: 'assign_tutor', label: '강사 배정', done: true }
            : t.enrollmentId
              ? { key: 'pick_schedule', label: '강사 배정', primary: true, href: `/lms/admin/assign?e=${t.enrollmentId}` }
              : { key: 'assign_tutor', label: '강사 배정', primary: true },
          t.studentNotifiedAt
            ? { key: 'notify_student', label: '수업 컨펌 완료', done: true }
            : { key: 'notify_student', label: '수업 컨펌 완료', primary: !!t.tutorAssignedAt, disabled: !t.tutorAssignedAt },
        ],
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
        detail: `${t.studentCode} · ${t.from} ~ ${t.to} · 사유: ${REASON_KO[t.reason]}`,
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
        title: `${t.studentName} · 수업 ${t.lessonsLeft}회 남음`,
        detail: `${t.studentCode} · ${t.product}${t.tutorName ? ` · ${t.tutorName}` : ''}`,
        due: `종료 ${dueText(t.endsAt, now)}`,
        steps: [],
        actions: [],
        renewal: { text: renewalMessage(t.studentName, t.lessonsLeft, t.endsAt), sentAt: t.noticeSentAt },
      };
    case 'makeup_unrequested':
      return {
        id: t.id,
        kind: t.kind,
        severity: dueSeverity(t.deadline, now),
        tag: '보강 미신청',
        title: `${t.studentName} · ${t.canceledLesson} 수업분`,
        detail: `${t.studentCode}${t.tutorName ? ` · ${t.tutorName}` : ''}`,
        due: `보강 기한 ${dueText(t.deadline, now)}`,
        steps: [],
        actions: [{ key: 'makeup_nudged', label: '학생에게 보강 신청 안내함', primary: true }],
      };
    case 'import_check': {
      const diff = t.counts ? t.counts.lmsLeft - t.counts.sheetLeft : 0;
      const parts = [
        t.counts && (diff === 0 ? `남은 수업 ${t.counts.lmsLeft}회 (시트와 같음) · 입력 내용을 시트와 한 번 대조해 주세요` : `남은 수업 LMS ${t.counts.lmsLeft}회 · 시트 ${t.counts.sheetLeft}회 (${diff > 0 ? '+' : ''}${diff}) · 차이 원인을 확인해 주세요`),
        t.unknownOrigins.length > 0 && `보강 원래 수업 날짜 확인 필요 ${t.unknownOrigins.length}건`,
        t.endReason && `종료일이 기간 계산보다 ${Math.abs(t.endReason.days)}일 ${t.endReason.days > 0 ? '늦은' : '빠른'} 이유 확인 필요`,
      ].filter(Boolean);
      return {
        id: t.id,
        kind: t.kind,
        severity: 'open',
        tag: t.counts ? (diff === 0 ? '시트 대조' : `시트 대조 · ${Math.abs(diff)}회 차이`) : t.endReason ? '종료일 이유 확인' : '보강 날짜 확인',
        title: t.studentName,
        detail: `${t.studentCode} · ${parts.join(' · ')}`,
        due: null,
        steps: [],
        actions: t.counts ? [{ key: 'import_checked', label: '대조 완료', primary: true }] : [],
        unknownOrigins: t.unknownOrigins,
        endReason: t.endReason ?? null,
      };
    }
    case 'lesson_change':
      return {
        id: t.id,
        kind: t.kind,
        severity: t.lessonAt ? dueSeverity(t.lessonAt, now) : 'open',
        tag: t.pendingNotices > 0 ? `${CHANGE_EVENT_TEXT[t.noticeEvents?.[0] ?? ''] ?? '수업 변경'} · 안내 보내기` : (t.answeredMakeups ?? 0) > 0 ? '보강 강사 답 옴 · 확정' : '보강 강사 답 대기',
        title: t.studentName,
        detail: [
          t.pendingNotices > 0 && (t.noticeLessonAt ?? t.lessonAt) && `${kstLabel((t.noticeLessonAt ?? t.lessonAt)!)} 수업`,
          t.pendingNotices > 0 && `${noticeWho(t.noticeTo)} ${t.pendingNotices}건`,
          t.pendingNotices === 0 && t.lessonAt && `${kstLabel(t.lessonAt)} 수업`,
          t.pendingNotices > 0 && (t.answeredMakeups ?? 0) > 0 && `보강 강사 답 옴 ${t.answeredMakeups}건`,
          t.pendingNotices > 0 && t.openMakeups - (t.answeredMakeups ?? 0) > 0 && `보강 강사 답 대기 ${t.openMakeups - (t.answeredMakeups ?? 0)}건`,
          t.pendingNotices === 0 && (t.answeredMakeups ?? 0) > 0 && t.openMakeups > (t.answeredMakeups ?? 0) && `보강 강사 답 대기 ${t.openMakeups - (t.answeredMakeups ?? 0)}건`,
        ].filter(Boolean).join(' · '),
        due: null,
        steps: [],
        actions: [{ key: 'open_change', label: '열기', primary: true, href: `/lms/admin/change?student=${encodeURIComponent(t.studentCode)}` }],
      };
    case 'tutor_leave': {
      // 휴무 화면 단계 이름 그대로 (같은 것은 어디서나 같은 이름 — 2026-10-28 대표)
      const ns = t.noticeSteps ?? { notify: 0, tutor: 0, confirm: 0 };
      const other = t.pendingNotices - ns.notify - ns.tutor - ns.confirm;
      const parts = [
        ns.notify > 0 && `1 기존 강사 휴무 안내 ${ns.notify}건`,
        t.undecidedStudents > 0 && `2 학생 선호 방법 입력 ${t.undecidedStudents}명`,
        (t.tutorReply > 0 || ns.tutor > 0) && `3 대체 강사에게 묻기 ${t.tutorReply || ns.tutor}회`,
        (t.studentReply > 0 || ns.confirm > 0) && `4 학생에게 확정 받기 ${t.studentReply > 0 ? `${t.studentReply}회` : `안내 ${ns.confirm}건`}`,
        other > 0 && `안내 보내기 ${other}건`,
      ].filter(Boolean) as string[];
      const day = (d: string) => `${Number(d.slice(5, 7))}/${Number(d.slice(8, 10))}`;
      return {
        id: t.id,
        kind: t.kind,
        severity: t.firstOpenAt ? dueSeverity(t.firstOpenAt, now) : 'open',
        tag: `강사 휴무 · ${parts[0] ?? '처리 중'}`,
        title: `${t.tutorName} 휴무 ${day(t.from)}~${day(t.to)}`,
        detail: parts.join(' · '),
        due: t.firstOpenAt ? `첫 수업 ${kstLabel(t.firstOpenAt)}` : null,
        steps: [],
        actions: [{ key: 'open_leave', label: '열기', primary: true, href: `/lms/admin/leave?off=${encodeURIComponent(t.id)}` }],
      };
    }
    case 'class_record_missing':
      return {
        id: t.id,
        kind: t.kind,
        severity: 'overdue',
        tag: `Class Record 미기록 ${t.lessons.length}회`,
        title: t.tutorName,
        detail: t.lessons.map((l) => `${kstLabel(l.startsAt)} ${l.studentName}`).join(' · '),
        due: null,
        steps: [],
        actions: [{ key: 'open_tutor', label: '열기', primary: true, href: `/lms/tutor?tutor=${encodeURIComponent(t.id)}` }],
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

/** 일정안이 있는 신규 매칭 (D-51-3 경고 시각). 버튼은 PlanCard 가 그림 */
function planItem(t: MatchingTask, p: PlanView, now: Date): Omit<BoardItem, 'category' | 'error' | 'studentCode' | 'searchText'> {
  const alert = planAlert(p, now);
  const tutorUnsent = p.tutorNotice?.status !== 'sent';
  const studentUnsent = p.studentNotice?.status !== 'sent';
  const tag =
    p.state === 'proposed'
      ? alert === 'no_reply' ? '강사 답 확인 필요' : '강사 답 대기'
      : tutorUnsent && studentUnsent ? '양쪽 안내 안 함' : tutorUnsent ? '강사 안내 안 함' : '학생 안내 안 함';
  const first = firstLessonAt(p);
  return {
    id: t.id,
    kind: t.kind,
    severity: alert === 'top' || alert === 'urgent' || alert === 'check' ? 'urgent' : alert === 'no_reply' ? 'due_soon' : p.state === 'proposed' ? dueSeverity(t.dueAt, now) : 'open',
    tag,
    title: `${t.studentName}${p.studentPlace ? ` · ${p.studentPlace.split(' ')[0]}` : ''}`,
    detail: `${p.tutorName}${first ? ` · 첫 수업 ${kstLabel(first)}` : ''}`,
    due: p.state === 'proposed' ? dueText(t.dueAt, now) : alert === 'top' ? '첫 수업 24시간 안 — 지금 보내 주세요' : null,
    steps: [],
    actions: [],
    plan: p,
    top: alert === 'top',
  };
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
    .sort((a, b) => Number(!!b.item.top) - Number(!!a.item.top) || SEVERITY_RANK[a.item.severity] - SEVERITY_RANK[b.item.severity] || sortKey(a.t) - sortKey(b.t))
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
