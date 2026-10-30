// 강사 휴무·대체강사 화면 계산 (2순위 ①, migration 1800) — 처리·검사는 DB 함수가 하고, 여기는 묶기·상태 글·안내 문구만
// - 학생별로 한 번에 고르고, 필요하면 일부 날짜만 다르게 (2026-10-27 대표 Q1 A)
// - 대체강사는 강사 가능 → 학생 안내 → 학생 OK 뒤 확정 (Q2 A, 정책 원본 A41)
// - 학생에게는 처음부터 두 가지를 함께 안내 (① 대체강사 · 추천 / ② 기존 강사와 보강). 거절해야 ②를 알려주는 방식 아님 (2026-10-27 대표)
// - 안내는 학생·강사마다 한 번에 복사 (같은 학생의 여러 날짜를 한 메시지로), 보낸 뒤 [보냄]
// - 학생·대체강사에게 가는 글에 휴무 강사 이름을 쓰지 않음 (2026-10-27 대표)
// - 화면은 학생 한 명씩 단계대로. 2026-10-28 대표 새 순서 (정책 원본 H26(27), migration 2500):
//   1 대체 강사에게 묻기 → 2 학생에게 휴무 안내 · 대체 강사 제안 (글 하나) → 3 학생 답 입력 → 4 확정 안내 보내기
//   운영진이 대체강사 가능 여부를 먼저 확인하고, 학생은 한 번만 답함 ([좋아요] / [기존 강사와 보강])

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
  /** 대체강사 Meet 주소: 학생 확정 안내에 같이 (C11 '안내와 링크는 한 번에') */
  subTutorMeetUrl?: string | null;
  subStage: LvStage | null;
  /** 기존 강사 보강: 보강이 잡혔으면 그 시각 */
  makeupAt: Date | null;
  /** 기존 강사 보강: 보강 신청(강사 확인 중)이 있음 */
  makeupRequested: boolean;
  /** 보강 신청 대상 (수업 또는 시트 휴가 보강) */
  lessonId: string | null;
  migratedItemId: string | null;
  /** 휴무 처리 밖에서(학생 취소·변경) 수업이 취소됨 (3200, R5) → 처리할 것 없음 */
  lessonGone?: boolean;
};

export type LvNoticeEvent = 'leave_options' | 'sub_ask' | 'sub_student' | 'sub_confirmed';
export type LvNotice = { id: string; itemId: string; event: LvNoticeEvent; recipientKind: 'student' | 'tutor'; recipientId: string; status: 'pending' | 'sent' | 'not_needed'; sentAt: Date | null };

/** free = 보통 수업 시간 안에서 맡을 수 있는 횟수, busyDates = 못 하는 날짜(휴무·다른 수업·불가 답), offHours = 보통 시간 밖(골라도 됨, 2700) */
export type LvSubOption = { tutorId: string; name: string; timezone: string; free: number; busyDates: string[]; offHours: string[] };
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

/** 안 보낸 안내 '수업id|종류' (상태 글에서 '보내기 전'과 '답 기다리는 중'·'완료'를 가름, R2·R4) */
export function pendingNoticeKeys(notices: LvNotice[]): Set<string> {
  return new Set(notices.filter((n) => n.status === 'pending').map((n) => `${n.itemId}|${n.event}`));
}

/** 한 줄 상태 글. pending = pendingNoticeKeys (없으면 안내 보냄 여부는 안 봄) */
export function itemStatus(i: LvItem, pending?: ReadonlySet<string>): { text: string; tone: 'todo' | 'wait' | 'done' } {
  if (i.lessonGone) return { text: '수업 취소·변경됨', tone: 'done' };
  if (i.choice === 'undecided') return { text: '대체 강사 고르기 필요', tone: 'todo' };
  if (i.choice === 'wait') {
    if (i.makeupAt) return { text: `기존 강사 보강 · ${koShort(i.makeupAt)}`, tone: 'done' };
    return i.makeupRequested ? { text: '기존 강사 보강 · 강사님 확인 기다리는 중', tone: 'wait' } : { text: '보강 · 날짜 잡기 전', tone: 'wait' };
  }
  const who = i.subTutorName ?? '대체강사';
  if (i.subStage === 'asked') {
    return pending?.has(`${i.id}|sub_ask`) ? { text: `${who} 강사님에게 문의 보내기 전`, tone: 'todo' } : { text: `${who} 강사님 답변 기다리는 중`, tone: 'todo' };
  }
  if (i.subStage === 'tutor_ok') return { text: `${who} 강사님 가능 · 학생 답 필요`, tone: 'todo' };
  // 배정 확정과 확정 안내 보냄은 다른 상태: 안내까지 보내야 완료 (R4)
  if (pending?.has(`${i.id}|sub_confirmed`)) return { text: `대체강사 ${who} 확정 · 확정 안내 보내기 전`, tone: 'todo' };
  return { text: `대체강사 ${who} 확정`, tone: 'done' };
}

function koShort(at: Date): string {
  const f = new Intl.DateTimeFormat('en-CA', { timeZone: 'Asia/Seoul', month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit', hourCycle: 'h23' }).formatToParts(at);
  const p = Object.fromEntries(f.map((x) => [x.type, x.value]));
  return `${Number(p.month)}/${Number(p.day)} ${p.hour}:${p.minute}`;
}

/** 휴무 한 건의 요약 (대시보드 카드와 같은 기준) */
export function leaveSummary(all: LvItem[], notices: LvNotice[]) {
  const items = all.filter((i) => !i.lessonGone);
  const gone = new Set(all.filter((i) => i.lessonGone).map((i) => i.id));
  const pending = notices.filter((n) => n.status === 'pending' && !gone.has(n.itemId)).length;
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

export type LvMessage = {
  key: string; event: LvNoticeEvent; recipient: 'student' | 'tutor'; to: string; studentId: string; recipientId: string; itemIds: string[]; noticeIds: string[]; status: 'pending' | 'sent'; text: string;
  /** noticeIds 와 같은 순서의 수업 id */
  noticeItems?: string[];
  /** 보낸 시각: 한 번에 보낸 글은 같은 시각 → 보낸 글은 그 묶음 그대로 (대표 10/30: 보낸 원문·번호 고정) */
  sentAt?: Date | null;
};

/** 아직 안 보낸 안내는 메시지로 묶고, 보낸 것은 최근 것만 따로 보여 줌 */
export function leaveMessages(items: LvItem[], notices: LvNotice[]): LvMessage[] {
  const byId = new Map(items.map((i) => [i.id, i]));
  const groups = new Map<string, { event: LvNoticeEvent; status: 'pending' | 'sent'; notices: LvNotice[]; items: LvItem[] }>();
  for (const n of notices) {
    if (n.status === 'not_needed') continue;
    const it = byId.get(n.itemId);
    // 안 보낸 글에서는 취소된 수업을 뺌. 보낸 글은 보낸 그대로
    if (!it || (it.lessonGone && n.status === 'pending')) continue;
    // 학생에게 가는 대체강사 글은 대체강사마다 따로 (날짜마다 대체강사가 다를 수 있음). 보낸 글은 보낸 묶음(같은 보낸 시각)마다
    const key = `${n.status}|${n.event}|${it.studentId}|${n.recipientId}|${n.event === 'sub_student' || n.event === 'sub_confirmed' ? it.subTutorId ?? '' : ''}|${n.status === 'sent' ? n.sentAt?.toISOString() ?? '' : ''}`;
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
      itemIds: [...new Set(g.items.map((i) => i.id))],
      noticeIds: g.notices.map((n) => n.id),
      noticeItems: g.notices.map((n) => n.itemId),
      sentAt: g.notices[0].sentAt,
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
    return [`[엣지영어] ${i.studentName}님, 아래 수업은 대체강사 ${i.subTutorName} 강사님과 평소 시간에 진행하는 것으로 확정됐어요. 이해해 주셔서 감사합니다.`, dates,
      ...(i.subTutorMeetUrl ? [`수업 입장: ${i.subTutorMeetUrl}`] : [])].join('\n\n');
  }
  return [
    `CONFIRMED substitute classes - ${i.studentNameEn} (${i.durationMin} min)`,
    ...items.map((x, n) => `${n + 1}) ${enAt(x.startsAt, tz)}`),
    'Please add them to your schedule. Thank you!',
  ].join('\n');
}

export const LV_EVENT_TEXT: Record<LvNoticeEvent, string> = {
  leave_options: '진행 방법 선택 안내',
  sub_ask: '대체강사에게 수업 가능 여부 묻기',
  sub_student: '학생에게 대체강사 안내하고 동의받기 (프로필 함께)',
  sub_confirmed: '확정 안내',
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

export type LvStep = 'tutor' | 'propose' | 'answer' | 'confirm';
export const LV_STEP_TEXT: Record<LvStep | 'done', string> = {
  tutor: '수업별 대체 강사 찾기', propose: '학생한테 기존 강사 휴무 안내하기', answer: '학생 답변 기록', confirm: '확정 안내 보내기', done: '완료',
};

/** 2단계 글: 휴무 안내 + 대체강사 제안을 한 번에 (2026-10-28 대표 시안 승인). 대체강사 날짜는 강사 이름과 함께, 나머지는 보강 */
export type LvProposal = { status: 'pending' | 'sent'; noticeIds: string[]; itemIds: string[]; text: string };

/** period: 휴무 기간 — 학생이 그 기간을 피해 보강을 잡을 수 있게 같이 알림 (2026-10-28 대표) */
/** 학생 LMS 주소 (2단계 글 맨 끝). 운영진 화면과 같은 사이트 */
export const studentLmsLink = () => `${typeof window === 'undefined' ? '' : window.location.origin}/lms/student`;

// 2단계 글 (2026-10-28 대표 문구): 날짜만 알리고, 강사 프로필 확인·답은 학생 LMS에서 (A안 한 번에 답)
export function proposalText(studentName: string, items: LvItem[], _period?: { from: KstDate; to: KstDate }, link = studentLmsLink()): string {
  const subs = items.some((i) => i.choice === 'substitute');
  const out = [
    `[엣지영어] 안녕하세요, ${studentName}님! \n다름이 아니라 담당 강사님 휴무로 부득이하게 아래 날짜에는 수업을 진행하기 어렵게 되었어요.🥲`,
    items.map((i) => `- ${koAt(i.startsAt, i.studentTz)}`).join('\n'),
  ];
  if (subs) out.push('추천드리는 방법은, 원래 시간에 대체강사와 수업하는 거예요!\n일정을 바꾸지 않고, 평소 수업 시간 그대로 수업하실 수 있어요.\n다른 강사의 영어와 수업 방식도 경험해 보실 수 있습니다:)');
  out.push(subs ? '아래 링크에서 강사님 프로필을 확인하시고, 원하시는 수업 방법을 편하게 선택해 주세요. \n감사합니다🙇‍♀️' : '아래 링크에서 보강 날짜를 편하게 골라 주세요. \n감사합니다🙇‍♀️');
  out.push(link);
  return out.join('\n\n');
}

/** 학생 한 명의 할 일 묶음. 단계마다 해당 수업·안내 */
export type LvStudentWork = {
  /** 1단계: 대체강사(또는 '대체 강사 없음 → 보강')를 아직 안 고른 지금 이후 수업 */
  pick: LvItem[];
  /** 1단계: 대체강사 답 기다리는 중 (강사별) */
  tutor: { subTutorId: string; subTutorName: string; items: LvItem[]; ask: LvMessage | null }[];
  /** 휴무 안내 글: 아직 안 보낸 것 (정해진 날짜만) */
  proposal: LvProposal | null;
  /** 보낸 휴무 안내 (보낸 묶음마다 원문 그대로) */
  sentProposals: LvProposal[];
  /** 3단계: 대체강사 가능 → 학생 답 기다리는 수업 (2단계 글을 보낸 뒤) */
  answer: LvItem[];
  /** 4단계: 확정 안내 · 기존 강사 보강 날짜 미정 · 보강 신청(강사 확인 중) */
  confirm: { confirmedMsgs: LvMessage[]; makeup: LvItem[]; makeupRequested: LvItem[] };
  steps: LvStep[];
};

/** 보낸 기록을 '한 번에 보낸 묶음'으로: 보낸 시각이 앞 기록과 몇 초 안이면 같은 묶음 (3300 전에는 한 건씩 기록해 시각이 조금씩 다름) */
const SAME_SEND_MS = 5000;
export function sentBatches<T>(list: T[], at: (x: T) => Date | null): T[][] {
  const sorted = [...list].sort((a, b) => +(at(a) ?? 0) - +(at(b) ?? 0));
  const out: T[][] = [];
  let last: number | null = null;
  for (const x of sorted) {
    const t = +(at(x) ?? 0);
    if (last === null || t - last > SAME_SEND_MS) out.push([]);
    out[out.length - 1].push(x);
    last = t;
  }
  return out;
}

export function studentWork(g: LvStudentGroup, messages: LvMessage[], now: Date, period?: { from: KstDate; to: KstDate }): LvStudentWork {
  const mine = messages.filter((m) => m.studentId === g.studentId);
  const pending = mine.filter((m) => m.status === 'pending');
  // 휴무 처리 밖에서 취소된 수업은 할 일에서 뺌 (R5)
  const items = g.items.filter((i) => !i.lessonGone);
  const future = items.filter((i) => i.startsAt > now);
  const pick = future.filter((i) => i.choice === 'undecided');
  const tutorMap = new Map<string, LvStudentWork['tutor'][number]>();
  for (const i of items.filter((x) => x.choice === 'substitute' && x.subStage === 'asked')) {
    const t = tutorMap.get(i.subTutorId!) ?? { subTutorId: i.subTutorId!, subTutorName: i.subTutorName ?? '', items: [], ask: null };
    t.items.push(i);
    tutorMap.set(i.subTutorId!, t);
  }
  const tutor = [...tutorMap.values()].map((t) => ({ ...t, ask: pending.find((m) => m.event === 'sub_ask' && m.recipientId === t.subTutorId) ?? null }));

  // 휴무 안내 글(leave_options + sub_student): 정해진 날짜부터 먼저 (대표 10/30: 미정 날짜가 있어도 준비된 날짜는 진행). 미정·강사 답 대기 날짜는 정해지면 따로
  const isProp = (m: LvMessage) => m.event === 'leave_options' || m.event === 'sub_student';
  const ready = future.filter((i) => i.choice === 'wait' || (i.choice === 'substitute' && i.subStage !== 'asked'));
  const readyIds = new Set(ready.map((i) => i.id));
  const pendNotices = pending.filter(isProp).flatMap((m) => m.noticeIds.map((id, k) => [id, m.noticeItems?.[k] ?? ''] as const)).filter(([, it]) => readyIds.has(it));
  const unsent = new Set(pendNotices.map(([, it]) => it));
  const pendItems = ready.filter((i) => unsent.has(i.id));
  const proposal: LvProposal | null = pendItems.length
    ? { status: 'pending', noticeIds: pendNotices.map(([id]) => id), itemIds: pendItems.map((i) => i.id), text: proposalText(g.studentName, pendItems, period) }
    : null;
  // 보낸 휴무 안내: 보낸 묶음마다 그대로
  const byId = new Map(g.items.map((i) => [i.id, i]));
  const sentProposals: LvProposal[] = sentBatches(mine.filter((x) => x.status === 'sent' && isProp(x)), (m) => m.sentAt ?? null).map((ms) => {
    const its = [...new Set(ms.flatMap((m) => m.itemIds))].map((id) => byId.get(id)!).filter(Boolean).sort((x, y) => +x.startsAt - +y.startsAt);
    return { status: 'sent', noticeIds: ms.flatMap((m) => m.noticeIds), itemIds: its.map((i) => i.id), text: proposalText(g.studentName, its, period) };
  });
  const answer = items.filter((i) => i.choice === 'substitute' && i.subStage === 'tutor_ok' && !unsent.has(i.id));
  const confirm = {
    confirmedMsgs: pending.filter((m) => m.event === 'sub_confirmed'),
    makeup: items.filter((i) => i.choice === 'wait' && !i.makeupAt && !i.makeupRequested && !unsent.has(i.id)),
    makeupRequested: items.filter((i) => i.choice === 'wait' && !i.makeupAt && i.makeupRequested),
  };
  const steps: LvStep[] = [];
  if (pick.length || tutor.length) steps.push('tutor');
  if (proposal) steps.push('propose');
  if (answer.length) steps.push('answer');
  if (confirm.confirmedMsgs.length || confirm.makeup.length || confirm.makeupRequested.length) steps.push('confirm');
  return { pick, tutor, proposal, sentProposals, answer, confirm, steps };
}

// ---------------------------------------------------------------------
// 재등록 대기 학생 (2026-10-27 대표): 재등록하면 휴무에 걸리는 날짜. 수업이 아니라 처리 목록에는 안 넣고 보여 주기·글 복사만
// ---------------------------------------------------------------------

export type LvRenewal = { studentId: string; studentName: string; studentCode: string; endDate: KstDate; startsAt: Date; durationMin: number };
export type LvRenewalGroup = { studentId: string; studentName: string; studentCode: string; endDate: KstDate; dates: { startsAt: Date; durationMin: number }[] };

export function groupRenewals(rows: LvRenewal[]): LvRenewalGroup[] {
  const out = new Map<string, LvRenewalGroup>();
  for (const r of [...rows].sort((a, b) => +a.startsAt - +b.startsAt)) {
    const g = out.get(r.studentId) ?? { studentId: r.studentId, studentName: r.studentName, studentCode: r.studentCode, endDate: r.endDate, dates: [] };
    g.dates.push({ startsAt: r.startsAt, durationMin: r.durationMin });
    out.set(r.studentId, g);
  }
  return [...out.values()];
}

const md = (d: KstDate) => `${Number(d.slice(5, 7))}/${Number(d.slice(8))}`;

/** 재등록 안내에 덧붙일 글 (대표 확인 2026-10-27: 새 기간이 휴무와 겹치는 학생에게 미리 알림) */
export function renewalLeaveText(from: KstDate, to: KstDate): string {
  return `참고로 담당 강사님이 ${md(from)}~${md(to)} 휴가예요. 이 기간 수업은 ① ⭐추천⭐ 대체강사와 원래 시간에 하시거나 ② 강사님 복귀 뒤 보강으로 하실 수 있고, 수업 횟수는 그대로예요. 어느 쪽이 편하신지 같이 알려 주세요.`;
}

/** 대체강사에게 같이 물어볼 날짜 (재등록하면) — 강사가 정해지기 전이라 한국 시간 */
export function renewalTutorText(g: LvRenewalGroup): string {
  return g.dates.map((d) => `- ${enAt(d.startsAt, 'Asia/Seoul')} (${d.durationMin} min) (if the student renews)`).join('\n');
}

// ---------------------------------------------------------------------
// 강사별 묶음 문의 (R17, 2026-10-30 시안 승인): 같은 대체강사에게 여러 학생 수업을 한 메시지로. 답은 수업마다 (admin_leave_sub_ok)
// ---------------------------------------------------------------------

/** pending = 아직 안 보낸 문의(안 보낸 수업만) · sent = 보낸 문의 원문(보낸 묶음마다, 번호 고정) · numbers = 답 기다리는 수업이 보낸 글의 몇 번인지 */
export type LvAskMsg = { noticeIds: string[]; itemIds: string[]; text: string; sentAt: Date | null };
export type LvTutorBundle = { subTutorId: string; subTutorName: string; items: LvItem[]; pending: LvAskMsg | null; sent: LvAskMsg[]; numbers: Record<string, string>; status: 'pending' | 'sent' };

export function tutorBundles(items: LvItem[], notices: LvNotice[], now: Date): LvTutorBundle[] {
  const byId = new Map(items.map((i) => [i.id, i]));
  const out = new Map<string, LvItem[]>();
  for (const i of items) {
    if (i.lessonGone || i.choice !== 'substitute' || i.subStage !== 'asked' || !i.subTutorId || i.startsAt <= now) continue;
    out.set(i.subTutorId, [...(out.get(i.subTutorId) ?? []), i]);
  }
  const sortIts = (ids: string[]) => [...new Set(ids)].map((id) => byId.get(id)).filter((x): x is LvItem => !!x).sort((a, b) => +a.startsAt - +b.startsAt);
  return [...out.entries()].map(([id, list]) => {
    const its = sortIts(list.map((i) => i.id));
    const asked = new Set(its.map((i) => i.id));
    const mineAsk = notices.filter((n) => n.event === 'sub_ask' && n.recipientId === id);
    const pend = mineAsk.filter((n) => n.status === 'pending' && asked.has(n.itemId));
    const pendIts = sortIts(pend.map((n) => n.itemId));
    // 보낸 문의: 같은 보낸 시각 = 한 번에 보낸 글. 답 기다리는 수업이 든 글만
    const sent = sentBatches(mineAsk.filter((x) => x.status === 'sent'), (n) => n.sentAt)
      .map((ns) => { const bi = sortIts(ns.map((n) => n.itemId)); return { noticeIds: ns.map((n) => n.id), itemIds: bi.map((i) => i.id), text: subAskBundleText(bi), sentAt: ns[0].sentAt }; })
      .filter((m) => m.itemIds.some((x) => asked.has(x)));
    const numbers: Record<string, string> = {};
    for (const m of sent) m.itemIds.forEach((x, n) => { if (asked.has(x)) numbers[x] = `${n + 1}번`; });
    return {
      subTutorId: id, subTutorName: its[0].subTutorName ?? '', items: its, sent, numbers,
      pending: pendIts.length ? { noticeIds: pend.map((n) => n.id), itemIds: pendIts.map((i) => i.id), text: subAskBundleText(pendIts), sentAt: null } : null,
      status: pendIts.length ? 'pending' : 'sent',
    };
  });
}

/** 묶음 문의 글: 휴무 강사 이름은 안 씀, 가능한 것만 답해 달라고 (2026-10-27 대표 규칙 그대로) */
export function subAskBundleText(items: LvItem[]): string {
  const tz = items[0].subTutorTz ?? 'Asia/Seoul';
  return [
    'Substitute request - not confirmed yet',
    'One of our Edge English tutors is on leave. Are you available to teach these classes?',
    ...items.map((x, n) => `${n + 1}) ${enAt(x.startsAt, tz)} · ${x.studentNameEn} · ${x.durationMin} min`),
    "If you can't do all of them, please reply with the numbers you can do. Thank you!",
  ].join('\n');
}

/** 학생 목록 묶음: 운영진이 할 것 / 답 기다림 / 끝남 (R15·R29) */
export function studentPhase(w: LvStudentWork): 'todo' | 'wait' | 'done' {
  if (w.pick.length || w.tutor.some((t) => t.ask) || w.proposal?.status === 'pending' || w.confirm.confirmedMsgs.length || w.confirm.makeup.length) return 'todo';
  if (w.tutor.length || w.answer.length || w.confirm.makeupRequested.length) return 'wait';
  return 'done';
}
