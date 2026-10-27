// 강사 휴무·대체강사 화면 계산 (2순위 ①, migration 1800) — 처리·검사는 DB 함수가 하고, 여기는 묶기·상태 글·안내 문구만
// - 학생별로 한 번에 고르고, 필요하면 일부 날짜만 다르게 (2026-10-27 대표 Q1 A)
// - 대체강사는 강사 가능 → 학생 안내 → 학생 OK 뒤 확정 (Q2 A, 정책 원본 A41)
// - 안내는 학생·강사마다 한 번에 복사 (같은 학생의 여러 날짜를 한 메시지로), 보낸 뒤 [보냈어요]

import type { KstDate } from '../rules/dates';
import { enAt, koAt } from './lesson-change';

export type LvChoice = 'undecided' | 'substitute' | 'wait';
export type LvStage = 'asked' | 'tutor_ok' | 'confirmed';

export type LvTimeOff = { id: string; tutorId: string; tutorName: string; from: KstDate; to: KstDate; reason: string | null };

export type LvItem = {
  id: string;
  timeOffId: string;
  studentId: string;
  studentName: string;
  studentNameEn: string;
  studentCode: string;
  studentTz: string;
  durationMin: number;
  /** 시트에서 넘어온 휴가 보강이면 false (수업은 확정될 때 생김) */
  isLesson: boolean;
  startsAt: Date;
  choice: LvChoice;
  subTutorId: string | null;
  subTutorName: string | null;
  subTutorTz: string | null;
  subStage: LvStage | null;
  /** 기다림: 보강이 잡혔으면 그 시각 */
  makeupAt: Date | null;
};

export type LvNoticeEvent = 'sub_ask' | 'sub_student' | 'sub_confirmed';
export type LvNotice = { id: string; itemId: string; event: LvNoticeEvent; recipientId: string; status: 'pending' | 'sent' | 'not_needed'; sentAt: Date | null };

export type LvSubOption = { tutorId: string; name: string; timezone: string; free: number; busyDates: string[] };

export type LvStudentGroup = { studentId: string; studentName: string; studentCode: string; items: LvItem[] };

/** 학생별로 묶기 (첫 수업 빠른 학생부터, 학생 안에서는 날짜순) */
export function groupByStudent(items: LvItem[]): LvStudentGroup[] {
  const out = new Map<string, LvStudentGroup>();
  for (const i of [...items].sort((a, b) => +a.startsAt - +b.startsAt)) {
    const g = out.get(i.studentId) ?? { studentId: i.studentId, studentName: i.studentName, studentCode: i.studentCode, items: [] };
    g.items.push(i);
    out.set(i.studentId, g);
  }
  return [...out.values()];
}

/** 학생 카드의 고른 방식: 모두 같으면 그 방식, 섞였으면 'mixed' (일부 날짜만 다르게) */
export function groupChoice(items: LvItem[]): LvChoice | 'mixed' {
  const kinds = new Set(items.map((i) => (i.choice === 'substitute' ? `substitute:${i.subTutorId}` : i.choice)));
  if (kinds.size !== 1) return 'mixed';
  return items[0].choice;
}

/** 한 줄 상태 글 */
export function itemStatus(i: LvItem): { text: string; tone: 'todo' | 'wait' | 'done' } {
  if (i.choice === 'undecided') return { text: '미정 · 학생 답 대기', tone: 'todo' };
  if (i.choice === 'wait') {
    return i.makeupAt ? { text: `기다림 · 보강 ${koShort(i.makeupAt)}`, tone: 'done' } : { text: '기다림 · 보강 날짜 미정', tone: 'wait' };
  }
  const who = i.subTutorName ?? '대체강사';
  if (i.subStage === 'asked') return { text: `대체 ${who} · 강사 답 대기`, tone: 'todo' };
  if (i.subStage === 'tutor_ok') return { text: `대체 ${who} · 학생 OK 대기`, tone: 'todo' };
  return { text: `대체 ${who} · 확정`, tone: 'done' };
}

function koShort(at: Date): string {
  const f = new Intl.DateTimeFormat('en-CA', { timeZone: 'Asia/Seoul', month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit', hourCycle: 'h23' }).formatToParts(at);
  const p = Object.fromEntries(f.map((x) => [x.type, x.value]));
  return `${Number(p.month)}/${Number(p.day)} ${p.hour}:${p.minute}`;
}

/** 휴무 한 건의 요약 (대시보드 카드와 같은 기준) */
export function leaveSummary(items: LvItem[], notices: LvNotice[]) {
  const pending = notices.filter((n) => n.status === 'pending').length;
  return {
    undecidedStudents: new Set(items.filter((i) => i.choice === 'undecided').map((i) => i.studentId)).size,
    tutorReply: items.filter((i) => i.choice === 'substitute' && i.subStage === 'asked').length,
    studentReply: items.filter((i) => i.choice === 'substitute' && i.subStage === 'tutor_ok').length,
    makeupOpen: items.filter((i) => i.choice === 'wait' && !i.makeupAt).length,
    pendingNotices: pending,
  };
}

// ---------------------------------------------------------------------
// 안내 문구: 학생·강사마다 한 메시지로 (같은 학생·같은 대체강사의 날짜를 모음)
// ---------------------------------------------------------------------

export type LvMessage = { key: string; event: LvNoticeEvent; recipient: 'student' | 'tutor'; to: string; noticeIds: string[]; status: 'pending' | 'sent'; text: string };

/** 아직 안 보낸 안내는 메시지로 묶고, 보낸 것은 최근 것만 따로 보여 줌 */
export function leaveMessages(items: LvItem[], notices: LvNotice[], originalTutorName: string): LvMessage[] {
  const byId = new Map(items.map((i) => [i.id, i]));
  const groups = new Map<string, { event: LvNoticeEvent; status: 'pending' | 'sent'; notices: LvNotice[]; items: LvItem[] }>();
  for (const n of notices) {
    if (n.status === 'not_needed') continue;
    const it = byId.get(n.itemId);
    if (!it) continue;
    const key = `${n.status}|${n.event}|${it.studentId}|${n.recipientId}`;
    const g = groups.get(key) ?? { event: n.event, status: n.status, notices: [], items: [] };
    g.notices.push(n);
    g.items.push(it);
    groups.set(key, g);
  }
  return [...groups.entries()].map(([key, g]) => {
    const list = [...g.items].sort((a, b) => +a.startsAt - +b.startsAt);
    const first = list[0];
    const recipient = g.event === 'sub_student' ? 'student' : 'tutor';
    return {
      key,
      event: g.event,
      recipient,
      to: recipient === 'student' ? first.studentName : first.subTutorName ?? '대체강사',
      noticeIds: g.notices.map((n) => n.id),
      status: g.status,
      text: leaveText(g.event, list, originalTutorName),
    };
  });
}

export function leaveText(event: LvNoticeEvent, items: LvItem[], originalTutorName: string): string {
  const i = items[0];
  const tz = i.subTutorTz ?? 'Asia/Seoul';
  if (event === 'sub_student') {
    return [
      `[엣지영어] ${i.studentName}님, ${originalTutorName} 강사님 휴무로 아래 수업을 ${i.subTutorName} 강사님이 같은 시간에 진행할 수 있어요.`,
      items.map((x) => `- ${koAt(x.startsAt, x.studentTz)}`).join('\n'),
      `${i.subTutorName} 강사님 수업으로 진행해도 괜찮으신지 알려주세요. 원하시면 ${originalTutorName} 강사님이 돌아온 뒤 보강으로 진행할 수도 있어요.`,
    ].join('\n\n');
  }
  if (event === 'sub_ask') {
    return [
      `Substitute request - ${i.studentNameEn} (${i.durationMin} min), not confirmed yet`,
      `${originalTutorName} is on leave. Are you available to teach these classes?`,
      ...items.map((x, n) => `${n + 1}) ${enAt(x.startsAt, tz)}`),
    ].join('\n');
  }
  return [
    `CONFIRMED substitute classes - ${i.studentNameEn} (${i.durationMin} min)`,
    ...items.map((x, n) => `${n + 1}) ${enAt(x.startsAt, tz)}`),
    'Please add them to your schedule. Thank you!',
  ].join('\n');
}

export const LV_EVENT_TEXT: Record<LvNoticeEvent, string> = {
  sub_ask: '대체강사 가능 확인',
  sub_student: '학생 대체강사 안내',
  sub_confirmed: '대체강사 확정 안내',
};
