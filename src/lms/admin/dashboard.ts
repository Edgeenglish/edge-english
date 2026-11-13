// 운영진 대시보드 5차 (대표 2026-11-09): 숫자 칸 · 이번 달 등록/종료 예정 명단 · 기간별 수업 목록 · 강사 관리 · 공지
// DB 행 → 화면 값. 화면 글은 여기서 만든다. 시각은 모두 한국 시간(운영진 화면)

import { typeKo } from '../class-type';
import { addDays, ampmKo, formatInZone, instantToKstDate, weekdayOf, type KstDate } from '../rules/dates';
import { courseName } from '../rules/period';
import type { ClassStatus } from '../rules/status';
import { STATUS_PLAIN } from './lesson-change';

const WD = ['일', '월', '화', '수', '목', '금', '토'];
/** '11/9(월)' */
export const mdw = (d: KstDate) => `${Number(d.slice(5, 7))}/${Number(d.slice(8, 10))}(${WD[weekdayOf(d)]})`;
/** 이번 달 마지막 날 (한국 날짜) */
export function monthEnd(today: KstDate): KstDate {
  const y = Number(today.slice(0, 4));
  const m = Number(today.slice(5, 7));
  const last = new Date(Date.UTC(y, m, 0)).getUTCDate();
  return `${today.slice(0, 8)}${String(last).padStart(2, '0')}` as KstDate;
}
/** 그 주 월요일 */
export const mondayOf = (d: KstDate) => addDays(d, -((weekdayOf(d) + 6) % 7));

/** '3개월(12주) · 주 2회 · 40분' */
export function planText(e: { weeks: number | null; legacy_label: string | null; weekly_count: number; duration_min: number }): string {
  const term = e.weeks ? courseName(e.weeks) : (e.legacy_label ?? '');
  return [term, `주 ${e.weekly_count}회`, `${e.duration_min}분`].filter(Boolean).join(' · ');
}

// ---------------------------------------------------------------- 이번 달 등록 (결제 확인일 기준)
export type PaymentRow = {
  enrollment_id: string;
  confirmed_at: string;
  paid_at: string | null;
  received_on: string | null;
  enrollment: { previous_enrollment_id: string | null; weeks: number | null; legacy_label: string | null; weekly_count: number; duration_min: number;
    student: { code: string; name_ko: string; is_trial_account?: boolean | null } | null } | null;
};
export type RegistrationItem = { enrollmentId: string; studentCode: string; studentName: string; fresh: boolean; plan: string; paidOn: KstDate | null; confirmedOn: KstDate };

/** 이번 달(한국 날짜) 결제 확인된 등록. 테스트용 계정 뺌. 같은 수강권은 한 번만 */
export function monthRegistrations(rows: PaymentRow[], today: KstDate): RegistrationItem[] {
  const start = `${today.slice(0, 8)}01`;
  const end = monthEnd(today);
  const seen = new Set<string>();
  const out: RegistrationItem[] = [];
  for (const r of [...rows].sort((a, b) => a.confirmed_at.localeCompare(b.confirmed_at))) {
    const e = r.enrollment;
    const s = e?.student;
    if (!e || !s || s.is_trial_account || seen.has(r.enrollment_id)) continue;
    const confirmedOn = instantToKstDate(new Date(r.confirmed_at));
    if (confirmedOn < start || confirmedOn > end) continue;
    seen.add(r.enrollment_id);
    out.push({
      enrollmentId: r.enrollment_id, studentCode: s.code, studentName: s.name_ko, fresh: !e.previous_enrollment_id, plan: planText(e),
      paidOn: r.paid_at ? instantToKstDate(new Date(r.paid_at)) : (r.received_on as KstDate | null), confirmedOn,
    });
  }
  return out;
}

// ---------------------------------------------------------------- 이번 달 종료 예정
export type EndingItem = {
  enrollmentId: string; studentCode: string; studentName: string; endDate: KstDate; lessonsLeft: number; undated: number;
  /** 결제 확인된 다음 수강권 시작일 */
  renewedStart: KstDate | null;
  noticeSentOn: KstDate | null;
  state: 'renewed' | 'sent' | 'need' | 'none';
};
/** 상태 글 (명단 오른쪽) */
export const ENDING_STATE_TEXT = (e: EndingItem) =>
  e.state === 'renewed' ? '재등록 완료' : e.state === 'sent' ? `안내 보냄 ${mdw(e.noticeSentOn!)}` : e.state === 'need' ? '재등록 안내 필요' : '';

// ---------------------------------------------------------------- 수업 목록
export type LessonListRow = {
  id: string; starts_at: string; ends_at?: string | null; kind: string; class_type?: string | null; state: 'scheduled' | 'canceled' | 'done'; class_status: string | null;
  student: { code: string; name_ko: string } | null; tutor: { name: string } | null;
  /** 대체 강사 배정 전 원래 담당 (lessons.original_tutor_id) */
  original_tutor?: { name: string } | null;
};
/** tone: muted 흐린 글씨(완료) · alert 빨강(노쇼) · normal 굵게 */
export type LessonItem = {
  id: string; date: KstDate; time: string; studentName: string; studentCode: string; tutorName: string; kind: string; state: string; muted: boolean;
  tone: 'muted' | 'alert' | 'normal';
  /** 취소된 수업: 시각·학생 이름에 취소선 (상태 글자는 그대로) */
  struck: boolean;
  /** 이름 아래 작은 줄: 취소 사유 · 연결된 보강 · 대체 전 강사 · 시간 변경 */
  note: string | null;
};
/** 수업 줄에 붙일 기록 (실제 기록이 있을 때만) */
export type LessonExtras = {
  /** 취소된 수업 id → 실제로 연결된 보강의 최신 시작 시각 */
  makeups?: ReadonlyMap<string, string>;
  /** 수업 id → 운영진이 시간을 고치기 전 처음 시각 (admin_makeup_logs reschedule) */
  moves?: ReadonlyMap<string, string>;
  /** 지금 시각 — 예정 수업만 '진행 중'·'기록 전'으로 (확정된 완료·취소·노쇼는 시각으로 바꾸지 않음) */
  now?: Date;
};

/** 진행 상태: 예정 · 진행 중 · 기록 전 · 완료 · 취소 · 수강생 노쇼 · 강사 노쇼 · 노쇼 신고(열린 신고) */
export function lessonState(l: Pick<LessonListRow, 'state' | 'class_status' | 'starts_at' | 'ends_at'>, noShow = false, now?: Date): { text: string; tone: LessonItem['tone']; struck: boolean } {
  if (noShow) return { text: '노쇼 신고', tone: 'alert', struck: false };
  // 강사 노쇼는 DB 에서 state = done + class_status 'Tutor no-show' (수업 횟수 안 씀)
  if (l.class_status === 'Tutor no-show') return { text: '강사 노쇼', tone: 'alert', struck: false };
  if (l.class_status === 'Student no-show') return { text: '수강생 노쇼', tone: 'alert', struck: false };
  if (l.state === 'done') return { text: '완료', tone: 'muted', struck: false };
  if (l.state === 'canceled') return { text: '취소', tone: 'normal', struck: true };
  if (now) {
    const t = now.getTime();
    if (l.ends_at && t >= new Date(l.ends_at).getTime()) return { text: '기록 전', tone: 'normal', struck: false };
    if (t >= new Date(l.starts_at).getTime()) return { text: '진행 중', tone: 'normal', struck: false };
  }
  return { text: '예정', tone: 'normal', struck: false };
}

/** '11/20(금) 오후 8:00' (한국 시간) */
const kstWhen = (iso: string) => { const f = formatInZone(new Date(iso), 'Asia/Seoul'); return `${mdw(f.date as KstDate)} ${ampmKo(f.time)}`; };

/** 이름 아래 작은 줄 */
export function lessonNote(l: LessonListRow, extras: LessonExtras = {}): string | null {
  const parts: string[] = [];
  if (l.state === 'canceled') {
    const why = l.class_status ? STATUS_PLAIN[l.class_status as ClassStatus] : undefined;
    if (why) parts.push(why);
    const mk = extras.makeups?.get(l.id);
    if (mk) parts.push(`보강 ${kstWhen(mk)}`);
  } else {
    const orig = l.original_tutor?.name;
    if (orig && l.tutor?.name && orig !== l.tutor.name) parts.push(`${orig} → ${l.tutor.name}`);
    const old = extras.moves?.get(l.id);
    if (old && new Date(old).getTime() !== new Date(l.starts_at).getTime()) {
      const a = formatInZone(new Date(old), 'Asia/Seoul'); const b = formatInZone(new Date(l.starts_at), 'Asia/Seoul');
      parts.push(a.date === b.date ? `시간 변경 · ${ampmKo(a.time)} → ${ampmKo(b.time)}` : `시간 변경 · ${kstWhen(old)} → ${kstWhen(l.starts_at)}`);
    }
  }
  return parts.length ? parts.join(' · ') : null;
}

export function toLessonItems(rows: LessonListRow[], noShowIds: ReadonlySet<string> = new Set(), extras: LessonExtras = {}): LessonItem[] {
  return [...rows]
    .sort((a, b) => a.starts_at.localeCompare(b.starts_at))
    .map((l) => {
      const f = formatInZone(new Date(l.starts_at), 'Asia/Seoul');
      const st = lessonState(l, noShowIds.has(l.id), extras.now);
      return {
        id: l.id, date: f.date as KstDate, time: ampmKo(f.time), studentName: l.student?.name_ko ?? '(수강생)', studentCode: l.student?.code ?? '',
        tutorName: l.tutor?.name ?? '(강사)', kind: typeKo(l.class_type, l.kind), state: st.text, muted: st.tone === 'muted', tone: st.tone, struck: st.struck,
        note: lessonNote(l, extras),
      };
    });
}

export type LessonRange = 'today' | 'tomorrow' | 'week' | 'next' | 'pick';
export const RANGE_LABEL: Record<LessonRange, string> = { today: '오늘', tomorrow: '내일', week: '이번 주', next: '다음 주', pick: '기간 선택' };
/** 기간 버튼 → 한국 날짜 시작~끝 (이번 주 = 월~일) */
export function rangeDates(range: LessonRange, today: KstDate, pick?: { from: string; to: string }): { from: KstDate; to: KstDate } | null {
  const mon = mondayOf(today);
  switch (range) {
    case 'today': return { from: today, to: today };
    case 'tomorrow': return { from: addDays(today, 1), to: addDays(today, 1) };
    case 'week': return { from: mon, to: addDays(mon, 6) };
    case 'next': return { from: addDays(mon, 7), to: addDays(mon, 13) };
    case 'pick':
      if (!pick?.from || !pick.to || pick.to < pick.from) return null;
      return { from: pick.from as KstDate, to: pick.to as KstDate };
  }
}

// ---------------------------------------------------------------- 강사 관리
export type TutorItem = { id: string; name: string; timezone: string; trial: boolean; students: { code: string; name: string; trial: boolean }[] };
export type RegularRow = { tutor_id: string; effective_to: string | null; student: { id: string; code: string; name_ko: string; is_trial_account?: boolean | null } | null };

/** 담당 학생 = 지금 이어지는 정규 일정(적용 끝 없음·오늘 이후) 중 수강 중·예정인 학생 */
export function tutorItems(
  tutors: { id: string; name: string; timezone: string; active: boolean; is_trial_account?: boolean | null }[],
  regular: RegularRow[], enrolledStudentIds: ReadonlySet<string>, today: KstDate,
): TutorItem[] {
  return tutors
    .filter((t) => t.active)
    .map((t) => {
      const seen = new Map<string, { code: string; name: string; trial: boolean }>();
      for (const r of regular) {
        if (r.tutor_id !== t.id || !r.student || (r.effective_to && r.effective_to < today) || !enrolledStudentIds.has(r.student.id)) continue;
        seen.set(r.student.code, { code: r.student.code, name: r.student.name_ko, trial: !!r.student.is_trial_account });
      }
      return { id: t.id, name: t.name, timezone: t.timezone, trial: !!t.is_trial_account, students: [...seen.values()].sort((a, b) => a.code.localeCompare(b.code)) };
    })
    .sort((a, b) => Number(a.trial) - Number(b.trial) || a.name.localeCompare(b.name));
}

// ---------------------------------------------------------------- 공지
export type Audience = 'student' | 'tutor' | 'both';
export const AUDIENCE_TEXT: Record<Audience, string> = { student: '학생 전체', tutor: '강사 전체', both: '학생·강사 모두' };
export type Notice = { id: string; audience: Audience; title: string; body: string; startsOn: KstDate; endsOn: KstDate; endedAt: string | null };
export const NOTICE_TITLE_MAX = 60;
export const NOTICE_BODY_MAX = 2000;

export type NoticeState = 'live' | 'wait' | 'end';
export const NOTICE_STATE_TEXT: Record<NoticeState, string> = { live: '게시 중', wait: '게시 예정', end: '게시 종료' };
export function noticeState(n: Pick<Notice, 'startsOn' | 'endsOn' | 'endedAt'>, today: KstDate): NoticeState {
  if (n.endedAt || n.endsOn < today) return 'end';
  return n.startsOn > today ? 'wait' : 'live';
}
/** 게시 중·예정 먼저(최근 게시일 순), 종료는 아래 */
export function sortNotices(list: Notice[], today: KstDate): Notice[] {
  return [...list].sort((a, b) => Number(noticeState(a, today) === 'end') - Number(noticeState(b, today) === 'end') || b.startsOn.localeCompare(a.startsOn));
}
/** 저장 전 검사 (DB 함수도 같은 검사) — 오류 글, 없으면 null */
export function noticeError(f: { title: string; body: string; startsOn: string; endsOn: string }): string | null {
  if (!f.title.trim() || !f.body.trim()) return '제목과 내용을 넣어 주세요.';
  if (f.title.trim().length > NOTICE_TITLE_MAX) return '제목은 60자까지예요.';
  if (f.body.trim().length > NOTICE_BODY_MAX) return '내용은 2,000자까지예요.';
  if (!f.startsOn || !f.endsOn) return '게시일과 종료일을 넣어 주세요.';
  if (f.endsOn < f.startsOn) return '종료일이 게시일보다 빨라요.';
  return null;
}
