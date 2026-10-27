// 강사 휴무·대체강사 화면 계산 (2순위 ①, migration 1800) — 처리·검사는 DB 함수가 하고, 여기는 묶기·상태 글·안내 문구만
// - 학생별로 한 번에 고르고, 필요하면 일부 날짜만 다르게 (2026-10-27 대표 Q1 A)
// - 대체강사는 강사 가능 → 학생 안내 → 학생 OK 뒤 확정 (Q2 A, 정책 원본 A41)
// - 학생에게는 처음부터 두 가지를 함께 안내 (① 대체강사 · 추천 / ② 기존 강사와 보강). 거절해야 ②를 알려주는 방식 아님 (2026-10-27 대표)
// - 안내는 학생·강사마다 한 번에 복사 (같은 학생의 여러 날짜를 한 메시지로), 보낸 뒤 [보냄]
// - 학생·대체강사에게 가는 글에 휴무 강사 이름을 쓰지 않음 (2026-10-27 대표)
// - 화면은 학생 한 명씩 단계대로 (안 1, 2026-10-27 대표 확정): 1 안내 → 2 학생 답 → 3 강사 확인 / 보강 날짜 → 4 확정

import { formatInZone, type KstDate } from '../rules/dates';
import { enAt, koAt, MAKEUP_SLOTS_MAX } from './lesson-change';

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
  /** 기존 강사 보강: 보강이 잡혔으면 그 시각 */
  makeupAt: Date | null;
  /** 기존 강사 보강: 보강 신청(강사 확인 중)이 있음 */
  makeupRequested: boolean;
  /** 보강 신청 대상 (수업 또는 시트 휴가 보강) */
  lessonId: string | null;
  migratedItemId: string | null;
};

export type LvNoticeEvent = 'leave_options' | 'sub_ask' | 'sub_student' | 'sub_confirmed';
export type LvNotice = { id: string; itemId: string; event: LvNoticeEvent; recipientKind: 'student' | 'tutor'; recipientId: string; status: 'pending' | 'sent' | 'not_needed'; sentAt: Date | null };

export type LvSubOption = { tutorId: string; name: string; timezone: string; free: number; busyDates: string[] };
/** 기존 강사 보강 후보: in_period 지금 수강기간 안 / after_end 종료일 뒤 평소 요일·시간 (확정하면 그날까지 자동 연장) */
export type LvMakeupOption = { section: 'in_period' | 'after_end'; startsAt: Date };

/** 학생 선택 안내의 두 가지 (대표 문구 2026-10-27). 나중에 학생 LMS 선택 화면도 이 글을 그대로 씀 */
export const LEAVE_OPTIONS = {
  substitute: {
    title: '⭐추천⭐ 원래 시간에 대체강사와 수업하기',
    lines: ['일정을 바꾸지 않고, 평소 수업 시간 그대로 수업하실 수 있어요.', '다른 강사의 영어와 수업 방식도 경험해 보실 수 있습니다.'],
  },
  wait: {
    title: '기존 강사와 보강하기',
    lines: ['기존 강사님이 돌아오신 뒤 수업하실 수 있어요. 가능한 보강 시간을 확인해 주세요.'],
  },
} as const;

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
  if (i.choice === 'undecided') return { text: '학생 선택 미확인', tone: 'todo' };
  if (i.choice === 'wait') {
    if (i.makeupAt) return { text: `기존 강사 보강 · ${koShort(i.makeupAt)}`, tone: 'done' };
    return i.makeupRequested ? { text: '기존 강사 보강 · 강사 확인 중', tone: 'wait' } : { text: '기존 강사 보강 · 날짜 미정', tone: 'wait' };
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
    makeupOpen: items.filter((i) => i.choice === 'wait' && !i.makeupAt && !i.makeupRequested).length,
    pendingNotices: pending,
  };
}

// ---------------------------------------------------------------------
// 안내 문구: 학생·강사마다 한 메시지로 (같은 학생·같은 대체강사의 날짜를 모음)
// ---------------------------------------------------------------------

export type LvMessage = { key: string; event: LvNoticeEvent; recipient: 'student' | 'tutor'; to: string; studentId: string; recipientId: string; noticeIds: string[]; status: 'pending' | 'sent'; text: string };

/** 아직 안 보낸 안내는 메시지로 묶고, 보낸 것은 최근 것만 따로 보여 줌 */
export function leaveMessages(items: LvItem[], notices: LvNotice[]): LvMessage[] {
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
    const recipient = g.notices[0].recipientKind;
    return {
      key,
      event: g.event,
      recipient,
      to: recipient === 'student' ? first.studentName : first.subTutorName ?? '대체강사',
      studentId: first.studentId,
      recipientId: g.notices[0].recipientId,
      noticeIds: g.notices.map((n) => n.id),
      status: g.status,
      text: leaveText(g.event, list, recipient),
    };
  });
}

export function leaveText(event: LvNoticeEvent, items: LvItem[], recipient: 'student' | 'tutor' = event === 'sub_ask' || event === 'sub_confirmed' ? 'tutor' : 'student'): string {
  const i = items[0];
  const tz = i.subTutorTz ?? 'Asia/Seoul';
  const dates = items.map((x) => `- ${koAt(x.startsAt, x.studentTz)}`).join('\n');
  if (event === 'leave_options') {
    const o = LEAVE_OPTIONS;
    return [
      `[엣지영어] ${i.studentName}님, 담당 강사님 휴무로 아래 수업의 진행 방법을 골라 주세요.`,
      dates,
      [`① ${o.substitute.title}`, ...o.substitute.lines].join('\n'),
      [`② ${o.wait.title}`, ...o.wait.lines].join('\n'),
    ].join('\n\n');
  }
  if (event === 'sub_student') {
    // 대체강사 가능 확인 뒤 학생에게 강사·날짜 제안 (프로필은 이어서 따로 보냄) → 학생 OK → 확정 (2026-10-27 대표 최종)
    return [`[엣지영어] ${i.studentName}님, 담당 강사님 휴가 기간 수업을 대체강사 ${i.subTutorName} 강사님과 평소 시간에 진행하려고 해요. 아래 날짜 괜찮으신지 알려 주세요. 강사님 프로필도 함께 보내 드려요.`, dates].join('\n\n');
  }
  if (event === 'sub_ask') {
    return [
      `Substitute request - ${i.studentNameEn} (${i.durationMin} min), not confirmed yet`,
      'One of our Edge English tutors is on leave. Are you available to teach these classes?',
      ...items.map((x, n) => `${n + 1}) ${enAt(x.startsAt, tz)}`),
      "If you can't do all of them, please reply with the numbers you can do. Thank you!",
    ].join('\n');
  }
  if (recipient === 'student') {
    return [`[엣지영어] ${i.studentName}님, 아래 수업은 대체강사 ${i.subTutorName} 강사님과 평소 시간에 진행하는 것으로 확정됐어요. 이해해 주셔서 감사합니다.`, dates].join('\n\n');
  }
  return [
    `CONFIRMED substitute classes - ${i.studentNameEn} (${i.durationMin} min)`,
    ...items.map((x, n) => `${n + 1}) ${enAt(x.startsAt, tz)}`),
    'Please add them to your schedule. Thank you!',
  ].join('\n');
}

export const LV_EVENT_TEXT: Record<LvNoticeEvent, string> = {
  leave_options: '진행 방법 선택 안내',
  sub_ask: '대체강사 가능 확인',
  sub_student: '대체강사 제안 (프로필 함께)',
  sub_confirmed: '최종 확정 안내',
};

/** 기존 강사 보강: 학생에게 보강 가능한 날짜를 보내고 2개까지 고르게 함 (1개도 됨, 2026-10-27 대표 문구)
 *  날짜가 먼저 보이게 (2026-10-27 대표): 시간이 모두 같으면 시간은 위에 한 번, 날짜는 한 주(월~일)씩 한 줄
 *  시간이 섞이면 한 줄에 날짜 하나 + 그날 가능한 시간. 해외 학생은 현지 시각 */
export function makeupDatesText(studentName: string, studentTz: string, dates: Date[]): string {
  const tz = studentTz || 'Asia/Seoul';
  const head = `[엣지영어] ${studentName}님, 보강 가능한 날짜예요. 편한 날을 ${MAKEUP_SLOTS_MAX}개까지 골라 주세요.(없다면 1개만 고르셔도 괜찮아요)`;
  const local = tz === 'Asia/Seoul' ? '' : ' (현지 시간)';
  const days = new Map<string, { label: string; times: string[] }>();
  for (const d of [...dates].sort((a, b) => +a - +b)) {
    const f = formatInZone(d, tz);
    const day = days.get(f.date) ?? { label: `${Number(f.date.slice(5, 7))}/${Number(f.date.slice(8))}(${KO_WEEKDAY[f.weekday]})`, times: [] };
    const t = koTime(f.time);
    if (!day.times.includes(t)) day.times.push(t);
    days.set(f.date, day);
  }
  const list = [...days.entries()];
  const times = new Set(list.flatMap(([, v]) => v.times));
  if (times.size !== 1) return [head, list.map(([, v]) => `- ${v.label} ${v.times.join(' · ')}`).join('\n') + local].join('\n\n');
  // 한 주(월~일)씩 한 줄
  const weeks: string[][] = [];
  let key = '';
  for (const [date, v] of list) {
    const k = mondayOf(date);
    if (k !== key) { weeks.push([]); key = k; }
    weeks[weeks.length - 1].push(v.label);
  }
  return [head, [`⏰ 모두 평소 시간 ${[...times][0]}${local}`, ...weeks.map((w) => `- ${w.join(' · ')}`)].join('\n')].join('\n\n');
}

const KO_WEEKDAY: Record<string, string> = { Sun: '일', Mon: '월', Tue: '화', Wed: '수', Thu: '목', Fri: '금', Sat: '토' };
function koTime(hhmm: string): string {
  const [h, m] = hhmm.split(':').map(Number);
  return `${h < 12 ? '오전' : '오후'} ${h % 12 === 0 ? 12 : h % 12}시${m ? ` ${m}분` : ''}`;
}
function mondayOf(date: string): string {
  const d = new Date(`${date}T00:00:00Z`);
  d.setUTCDate(d.getUTCDate() - ((d.getUTCDay() + 6) % 7));
  return d.toISOString().slice(0, 10);
}

// ---------------------------------------------------------------------
// 학생 한 명의 단계 (안 1): 지금 할 일이 있는 단계를 앞에서부터
// ---------------------------------------------------------------------

export type LvStep = 'notify' | 'answer' | 'tutor' | 'makeup' | 'confirm';
export const LV_STEP_TEXT: Record<LvStep | 'done', string> = {
  notify: '1 안내', answer: '2 학생 답', tutor: '3 강사 확인', makeup: '3 보강 날짜', confirm: '4 확정', done: '완료',
};

/** 학생 한 명의 할 일 묶음. 단계마다 해당 수업·안 보낸 안내 */
export type LvStudentWork = {
  notify: LvMessage[];
  /** 학생 답을 아직 못 받은 지금 이후 수업 */
  answer: LvItem[];
  /** 대체강사 확인 중 (강사별) */
  tutor: { subTutorId: string; subTutorName: string; items: LvItem[]; ask: LvMessage | null }[];
  /** 기존 강사 보강 날짜를 아직 안 정함 */
  makeup: LvItem[];
  /** 대체강사 가능 → 학생 안내·학생 OK / 확정 안내 / 기존 강사 보강 신청(강사 확인 중) */
  confirm: { studentMsg: LvMessage | null; tutorOk: LvItem[]; confirmedMsgs: LvMessage[]; makeupRequested: LvItem[] };
  steps: LvStep[];
};

export function studentWork(g: LvStudentGroup, messages: LvMessage[], now: Date): LvStudentWork {
  const mine = messages.filter((m) => m.status === 'pending' && m.studentId === g.studentId);
  const notify = mine.filter((m) => m.event === 'leave_options');
  const answer = g.items.filter((i) => i.choice === 'undecided' && i.startsAt > now);
  const tutorMap = new Map<string, LvStudentWork['tutor'][number]>();
  for (const i of g.items.filter((x) => x.choice === 'substitute' && x.subStage === 'asked')) {
    const t = tutorMap.get(i.subTutorId!) ?? { subTutorId: i.subTutorId!, subTutorName: i.subTutorName ?? '', items: [], ask: null };
    t.items.push(i);
    tutorMap.set(i.subTutorId!, t);
  }
  const tutor = [...tutorMap.values()].map((t) => ({ ...t, ask: mine.find((m) => m.event === 'sub_ask' && m.recipientId === t.subTutorId) ?? null }));
  const makeup = g.items.filter((i) => i.choice === 'wait' && !i.makeupAt && !i.makeupRequested);
  const confirm = {
    studentMsg: mine.find((m) => m.event === 'sub_student') ?? null,
    tutorOk: g.items.filter((i) => i.choice === 'substitute' && i.subStage === 'tutor_ok'),
    confirmedMsgs: mine.filter((m) => m.event === 'sub_confirmed'),
    makeupRequested: g.items.filter((i) => i.choice === 'wait' && !i.makeupAt && i.makeupRequested),
  };
  const steps: LvStep[] = [];
  if (notify.length) steps.push('notify');
  if (answer.length) steps.push('answer');
  if (tutor.length) steps.push('tutor');
  if (makeup.length) steps.push('makeup');
  if (confirm.studentMsg || confirm.tutorOk.length || confirm.confirmedMsgs.length || confirm.makeupRequested.length) steps.push('confirm');
  return { notify, answer, tutor, makeup, confirm, steps };
}
