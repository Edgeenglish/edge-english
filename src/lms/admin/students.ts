// 운영진 '수강생' 메뉴 — 목록·상세·정규 일정 수정·종료일 연장·안내 문구 (H26(44) ①~④, 4300)
// 시간 표기 원칙 (H26(43)): 모든 시각에 기준 시간대 이름. 운영진 화면 = 한국 시간을 분명히 + 수강생·강사 도시 시간.
// 서머타임·날짜·요일은 실제 수업 날짜로 계산한다 (IANA 시간대, 고정 시차 없음)

import { addDays, ampmEn, ampmKo, formatInZone, instantToKstDate, kstToInstant, weekdayOf, type KstDate } from '../rules/dates';
import { courseName } from '../rules/period';
import { bold, enBoth, enClock, enDateOf, enDay, enZoneName, koBoth, koSi, koZoneBracket, koZoneName } from './time-text';

export const WD_KO = ['일', '월', '화', '수', '목', '금', '토'] as const;
const WD_EN = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];

/** 시간대 이름 (한국어 화면): 'Asia/Seoul' → '한국 시간', 'America/Toronto' → '토론토 시간' (time-text.ts 와 같은 이름) */
export function koZone(tz: string): string {
  return koZoneName(tz);
}
/** 시간대 이름 (영어): 'KST' / 'Toronto Time' (time-text.ts 와 같은 이름) */
export function enZone(tz: string): string {
  return enZoneName(tz);
}

export const md = (d: string) => `${Number(d.slice(5, 7))}/${Number(d.slice(8, 10))}`;
/** '11/5(목)' */
export const mdw = (d: KstDate) => `${md(d)}(${WD_KO[weekdayOf(d)]})`;
/** 그 시간대의 '11/5(목) 오전 8:00' */
export function zoneLabel(at: Date, tz: string): string {
  const f = formatInZone(at, tz);
  return `${mdw(f.date)} ${ampmKo(f.time)}`;
}
/** 영어 'Thu, 5 Nov 8:00 AM' (기준 이름은 따로 붙임 — time-text.ts) */
export function enWhen(at: Date, tz: string): string {
  return `${enDay(at, tz)} ${enClock(at, tz)}`;
}

/**
 * 운영진 화면 시각: '11/5(목) 오후 10:00 (한국 시간) · Toronto 11/5(목) 오전 8:00 · Ho Chi Minh 11/5(목) 오후 8:00'
 * 수강생·강사가 한국 시간대면 그 부분은 생략 (같은 시각이라 두 번 쓰지 않음)
 */
export function kstWithZones(at: Date, zones: { label: string; tz: string }[]): string {
  const parts = [`${zoneLabel(at, 'Asia/Seoul')} 한국 시간`];
  const seen = new Set<string>(['Asia/Seoul']);
  for (const z of zones) {
    if (!z.tz || seen.has(z.tz)) continue;
    seen.add(z.tz);
    parts.push(`${zoneLabel(at, z.tz)} ${koZone(z.tz)}${z.label ? ` (${z.label})` : ''}`);
  }
  return parts.join(' / ');
}

/** 최종 종료 '1/26(화) 오후 11:59 한국 시간' + 해외 수강생이면 ' / 1/26(화) 오전 9:59 토론토 시간' */
export function finalEndText(finalEnd: KstDate, studentTz: string): string {
  const at = kstToInstant(finalEnd, '23:59');
  const kst = `${mdw(finalEnd)} ${ampmKo('23:59')} 한국 시간`;
  if (!studentTz || studentTz === 'Asia/Seoul') return kst;
  return `${kst} / ${zoneLabel(at, studentTz)} ${koZone(studentTz)}`;
}

export type Slot = { weekday: number; time: string };
export type SlotFull = Slot & { durationMin: number; tutorId: string; tutor: string; tutorTz: string; tutorCountry: string | null; from: KstDate; to: KstDate | null };

/** '화·목 오후 10:00' (시간이 요일마다 다르면 '화 오후 10:00 · 목 오후 9:00') */
export function slotsText(slots: Slot[]): string {
  if (slots.length === 0) return '없음';
  const sorted = [...slots].sort((a, b) => a.weekday - b.weekday || a.time.localeCompare(b.time));
  const times = new Set(sorted.map((s) => s.time));
  if (times.size === 1) return `${sorted.map((s) => WD_KO[s.weekday]).join('·')} ${ampmKo(sorted[0].time)}`;
  return sorted.map((s) => `${WD_KO[s.weekday]} ${ampmKo(s.time)}`).join(' · ');
}

/** 다음에 오는 그 요일 날짜 (오늘 포함) */
export function nextDateOf(weekday: number, from: KstDate): KstDate {
  const d = weekdayOf(from);
  return addDays(from, (weekday - d + 7) % 7);
}

/**
 * 정규 일정을 다른 시간대로: 요일마다 '다음 실제 수업 날짜'로 계산해 서머타임·날짜 넘어감을 반영.
 * 결과 예: '화·목 오전 8:00' / '월·수 오후 8:00' (현지 요일이 다르면 현지 요일로 표시) / 요일마다 시간이 다르면 각각
 */
export function slotsInZone(slots: Slot[], tz: string, from: KstDate, lang: 'ko' | 'en' = 'ko'): string {
  if (slots.length === 0) return lang === 'ko' ? '없음' : '—';
  const wd = lang === 'ko' ? WD_KO : WD_EN;
  const local = [...slots]
    .sort((a, b) => a.weekday - b.weekday)
    .map((s) => {
      const f = formatInZone(kstToInstant(nextDateOf(s.weekday, from), s.time), tz);
      return { weekday: weekdayOf(f.date), time: lang === 'en' ? ampmEn(f.time) : ampmKo(f.time) };
    });
  const times = new Set(local.map((s) => s.time));
  if (times.size === 1) return `${local.map((s) => wd[s.weekday]).join(lang === 'ko' ? '·' : '/')} ${local[0].time}`;
  return local.map((s) => `${wd[s.weekday]} ${s.time}`).join(' · ');
}

/** 수강권 표시 '3개월(12주) · 주 2회 · 40분' (옛 상품은 시트 표기 그대로) */
export function productText(e: { weeks: number | null; legacyLabel: string | null; weeklyCount: number; durationMin: number } | null): string {
  if (!e) return '수강권 없음';
  const term = e.weeks ? courseName(e.weeks) : (e.legacyLabel ?? '');
  return [term, `주 ${e.weeklyCount}회`, `${e.durationMin}분`].filter(Boolean).join(' · ');
}

/** pending = 결제 확인 전 (등록만 있고 수업·일정 없음, QA B-01: '수강 예정·0/4회'로 보이지 않게) */
export type StudentStatus = 'active' | 'upcoming' | 'pending' | 'ended' | 'none';
export const STATUS_TEXT: Record<StudentStatus, string> = { active: '수강 중', upcoming: '수강 예정', pending: '결제 확인 전', ended: '종료', none: '수강권 없음' };
/** DB 가 준 수강 상태 + 수강권 상태 → 화면 상태 (결제 대기는 따로) */
export function studentStatusOf(status: string, enrollmentStatus: string | null): StudentStatus {
  if (enrollmentStatus === 'pending_payment' && (status === 'upcoming' || status === 'active')) return 'pending';
  return (['active', 'upcoming', 'ended', 'none'].includes(status) ? status : 'none') as StudentStatus;
}

export type StudentRow = {
  id: string; code: string; nameKo: string; nameEn: string; displayName: string | null; email: string | null; timezone: string;
  status: StudentStatus; enrollmentStatus: string | null; startDate: KstDate | null; finalEndDate: KstDate | null;
  weeks: number | null; legacyLabel: string | null; weeklyCount: number | null; durationMin: number | null;
  leftRegular: number; tutor: string | null; slots: Slot[]; noticePending: boolean;
};
/* eslint-disable @typescript-eslint/no-explicit-any -- DB JSON → 화면 모양 */
export function parseStudentRows(j: any): StudentRow[] {
  return ((j ?? []) as any[]).map((s) => ({
    id: s.id, code: s.code, nameKo: s.name_ko, nameEn: s.name_en, displayName: s.display_name ?? null, email: s.email ?? null, timezone: s.timezone,
    status: studentStatusOf(s.status, s.enrollment_status ?? null), enrollmentStatus: s.enrollment_status ?? null, startDate: s.start_date ?? null, finalEndDate: s.final_end_date ?? null,
    weeks: s.weeks ?? null, legacyLabel: s.legacy_label ?? null, weeklyCount: s.weekly_count ?? null, durationMin: s.duration_min ?? null,
    leftRegular: Number(s.left_regular ?? 0), tutor: s.tutor ?? null, slots: (s.slots ?? []) as Slot[], noticePending: !!s.notice_pending,
  }));
}

/** 목록 검색: 이름·영문·Preferred·번호·이메일·강사, 띄어쓰기·대소문자 무시 */
export function matchStudent(s: StudentRow, q: string): boolean {
  const key = q.trim().toLowerCase().replace(/\s+/g, '');
  if (!key) return true;
  return [s.nameKo, s.nameEn, s.displayName, s.code, s.email, s.tutor].filter(Boolean).join(' ').toLowerCase().replace(/\s+/g, '').includes(key);
}

export type StudentProfile = {
  id: string; code: string | null; nameKo: string | null; nameEn: string; displayName: string | null; label: string;
  country: string | null; city: string | null; timezone: string; genderAge: string | null; email: string | null; phone: string | null; adminMemo: string | null;
  level: string | null; levelNote: string | null; levelAt: Date | null; levelBy: string | null;
  classType: string | null; textbook: string | null; classNoteUrl: string | null; correctionPref: string | null; selfIntroEn: string | null;
  job: string | null; hobbies: string | null; interests: string | null; improve: string | null; hopes: string | null;
  correctionStyle: 'immediate' | 'major_only' | null; correctionNote: string | null; classStyle: 'textbook' | 'free_talking' | 'not_sure' | null; classStyleNote: string | null;
  /** 강사가 첫 수업 후 확인한 실제 수업 방식 (4600) — 수강생 희망(classStyle)과 다른 칸 */
  tutorClassStyle: 'conversation' | 'textbook' | 'student_materials' | 'mixed' | null; tutorClassStyleMix: string[]; tutorMaterialsNote: string | null;
  tutorClassStyleAt: Date | null; tutorClassStyleBy: string | null;
  /** 강사가 첫 수업에서 직접 물어 적은 시각 (improve) */
  improveTutorAt: Date | null;
  answersAt: Date | null; lmsSince: KstDate | null;
};
export type Extension = { id: string; days: number; reason: string; note: string | null; auto: string | null; at: Date; by: string | null };
export type EnrollmentInfo = {
  id: string; seq: number; status: string; weeks: number | null; legacyLabel: string | null; weeklyCount: number; durationMin: number;
  startDate: KstDate; baseEndDate: KstDate; extensionDays: number; finalEndDate: KstDate; lessonsPurchased: number; lessonsCarriedIn: number;
  sheet: { total: number | null; used: number | null } | null; done: number; leftRegular: number; leftAll: number;
  /** 날짜 안 잡은 보강권·보상권 (수강생 홈 '남은 수업' 과 같은 기준, 4500). 옛 DB 는 0 */
  leftUnbooked: number; extensions: Extension[];
};
export type Upcoming = { id: string; kind: string; type?: string; seq: number | null; startsAt: Date; endsAt: Date; tutor: string; tutorTz: string; tutorId: string; substitute: boolean; leaveOpen: boolean };
export type RecentTopic = { startsAt: Date; tutor: string; topics: string; kind: string; substitute: boolean };
export type RegularChangeRec = {
  id: string; effectiveFrom: KstDate; oldSlots: Slot[]; newSlots: Slot[]; moved: MovedLesson[]; kept: KeptLesson[]; reason: string; at: Date;
  tutor: string; tutorTz: string; studentSentAt: Date | null; tutorSentAt: Date | null;
};
export type MovedLesson = { lessonId: string; seq: number | null; from: Date; fromEnd: Date; to: Date; toEnd: Date; problem: string | null };
export type KeptLesson = { lessonId: string; kind: string; seq: number | null; startsAt: Date; endsAt: Date; tutor: string; tutorTz: string; why: string };
export type ProfileEdit = { field: string; old: string | null; new: string | null; role: 'admin' | 'tutor' | 'student'; at: Date; by: string };
export type RecentLesson = { id: string; kind: string; type?: string; startsAt: Date; state: string; classStatus: string | null; tutor: string; tutorTz: string };
export type EnrollmentShort = {
  id: string; seq: number; status: string; weeks: number | null; legacyLabel: string | null; weeklyCount: number; durationMin: number; startDate: KstDate; finalEndDate: KstDate;
  lessonsPurchased: number; lessonsCarriedIn: number; amountDue: number; payments: { on: KstDate | null; method: string; amount: number; confirmed: boolean }[];
};
export type StudentDetailData = {
  student: StudentProfile; enrollment: EnrollmentInfo | null; slots: SlotFull[]; nextSlots: (Slot & { from: KstDate })[]; upcoming: Upcoming[]; recentTopics: RecentTopic[]; holidays: KstDate[];
  enrollments: EnrollmentShort[]; changes: RegularChangeRec[]; edits: ProfileEdit[]; recent: RecentLesson[]; loginEmail: string | null;
};

const at = (v: any): Date | null => (v ? new Date(v) : null);
export function parseProfile(s: any): StudentProfile {
  return {
    id: s.id, code: s.code ?? null, nameKo: s.name_ko ?? null, nameEn: s.name_en ?? '', displayName: s.display_name ?? null, label: s.label ?? s.name_en ?? '',
    country: s.country ?? null, city: s.city ?? null, timezone: s.timezone ?? 'Asia/Seoul', genderAge: s.gender_age ?? null, email: s.email ?? null, phone: s.phone ?? null,
    adminMemo: s.admin_memo ?? null, level: s.level ?? null, levelNote: s.level_note ?? null, levelAt: at(s.level_at), levelBy: s.level_by ?? null,
    classType: s.class_type ?? null, textbook: s.textbook ?? null, classNoteUrl: s.class_note_url ?? null, correctionPref: s.correction_pref ?? null, selfIntroEn: s.self_intro_en ?? null,
    job: s.job ?? null, hobbies: s.hobbies ?? null, interests: s.interests ?? null, improve: s.improve ?? null, hopes: s.hopes ?? null,
    correctionStyle: s.correction_style ?? null, correctionNote: s.correction_note ?? null, classStyle: s.class_style ?? null, classStyleNote: s.class_style_note ?? null,
    tutorClassStyle: s.tutor_class_style ?? null, tutorClassStyleMix: Array.isArray(s.tutor_class_style_mix) ? (s.tutor_class_style_mix as string[]) : [], tutorMaterialsNote: s.tutor_materials_note ?? null,
    tutorClassStyleAt: at(s.tutor_class_style_at), tutorClassStyleBy: s.tutor_class_style_by ?? null, improveTutorAt: at(s.improve_tutor_at),
    answersAt: at(s.answers_at), lmsSince: s.lms_since ?? null,
  };
}
export function parseEnrollment(e: any): EnrollmentInfo | null {
  if (!e) return null;
  return {
    id: e.id, seq: e.seq, status: e.status, weeks: e.weeks ?? null, legacyLabel: e.legacy_label ?? null, weeklyCount: e.weekly_count, durationMin: e.duration_min,
    startDate: e.start_date, baseEndDate: e.base_end_date, extensionDays: e.extension_days ?? 0, finalEndDate: e.final_end_date,
    lessonsPurchased: e.lessons_purchased ?? 0, lessonsCarriedIn: e.lessons_carried_in ?? 0,
    sheet: e.sheet ? { total: e.sheet.total ?? null, used: e.sheet.used ?? null } : null,
    done: Number(e.done ?? 0), leftRegular: Number(e.left_regular ?? 0), leftAll: Number(e.left_all ?? 0), leftUnbooked: Number(e.left_unbooked ?? 0),
    extensions: ((e.extensions ?? []) as any[]).map((x) => ({ id: x.id, days: x.days, reason: x.reason, note: x.note ?? null, auto: x.auto ?? null, at: new Date(x.at), by: x.by ?? null })),
  };
}
export const parseSlots = (j: any): SlotFull[] => ((j ?? []) as any[]).map((s) => ({
  weekday: s.weekday, time: s.time, durationMin: s.duration_min, tutorId: s.tutor_id, tutor: s.tutor, tutorTz: s.tutor_tz, tutorCountry: s.tutor_country ?? null, from: s.from, to: s.to ?? null,
}));
export const parseUpcoming = (j: any): Upcoming[] => ((j ?? []) as any[]).map((l) => ({
  id: l.id, kind: l.kind, type: l.type, seq: l.seq ?? null, startsAt: new Date(l.starts_at), endsAt: new Date(l.ends_at), tutor: l.tutor, tutorTz: l.tutor_tz, tutorId: l.tutor_id,
  substitute: !!l.substitute, leaveOpen: !!l.leave_open,
}));
export const parseTopics = (j: any): RecentTopic[] => ((j ?? []) as any[]).map((t) => ({ startsAt: new Date(t.starts_at), tutor: t.tutor, topics: t.topics, kind: t.kind, substitute: !!t.substitute }));
export const parseMoved = (j: any): MovedLesson[] => ((j ?? []) as any[]).map((m) => ({
  lessonId: m.lesson_id, seq: m.seq ?? null, from: new Date(m.from), fromEnd: new Date(m.from_end), to: new Date(m.to), toEnd: new Date(m.to_end), problem: m.problem ?? null,
}));
export const parseKept = (j: any): KeptLesson[] => ((j ?? []) as any[]).map((k) => ({
  lessonId: k.lesson_id, kind: k.kind, seq: k.seq ?? null, startsAt: new Date(k.starts_at), endsAt: new Date(k.ends_at), tutor: k.tutor, tutorTz: k.tutor_tz, why: k.why,
}));
export function parseDetail(j: any): StudentDetailData {
  return {
    student: parseProfile(j.student), enrollment: parseEnrollment(j.enrollment), slots: parseSlots(j.slots),
    nextSlots: ((j.next_slots ?? []) as any[]).map((s) => ({ weekday: s.weekday, time: s.time, from: s.from })),
    upcoming: parseUpcoming(j.upcoming), recentTopics: parseTopics(j.recent_topics), holidays: j.holidays ?? [],
    enrollments: ((j.enrollments ?? []) as any[]).map((e) => ({
      id: e.id, seq: e.seq, status: e.status, weeks: e.weeks ?? null, legacyLabel: e.legacy_label ?? null, weeklyCount: e.weekly_count, durationMin: e.duration_min,
      startDate: e.start_date, finalEndDate: e.final_end_date, lessonsPurchased: e.lessons_purchased ?? 0, lessonsCarriedIn: e.lessons_carried_in ?? 0, amountDue: e.amount_due ?? 0,
      payments: ((e.payments ?? []) as any[]).map((p) => ({ on: p.on ?? null, method: p.method, amount: p.amount ?? 0, confirmed: !!p.confirmed })),
    })),
    changes: ((j.changes ?? []) as any[]).map((c) => ({
      id: c.id, effectiveFrom: c.effective_from, oldSlots: c.old_slots ?? [], newSlots: c.new_slots ?? [], moved: parseMoved(c.moved), kept: parseKept(c.kept), reason: c.reason,
      at: new Date(c.at), tutor: c.tutor, tutorTz: c.tutor_tz, studentSentAt: at(c.student_sent_at), tutorSentAt: at(c.tutor_sent_at),
    })),
    edits: ((j.edits ?? []) as any[]).map((x) => ({ field: x.field, old: x.old ?? null, new: x.new ?? null, role: x.role, at: new Date(x.at), by: x.by })),
    recent: ((j.recent ?? []) as any[]).map((l) => ({ id: l.id, kind: l.kind, type: l.type, startsAt: new Date(l.starts_at), state: l.state, classStatus: l.class_status ?? null, tutor: l.tutor, tutorTz: l.tutor_tz })),
    loginEmail: j.login?.email ?? null,
  };
}

export type RegularPreview = {
  ok: boolean; tutor: { id: string; name: string; timezone: string }; studentTimezone: string;
  enrollment: { id: string; finalEndDate: KstDate; durationMin: number }; oldSlots: Slot[]; newSlots: Slot[]; effectiveFrom: KstDate;
  moved: MovedLesson[]; kept: KeptLesson[]; skipped: { date: KstDate; time: string; why: string }[];
  problems: { lessonId: string; seq: number | null; date: KstDate; time: string; why: string; other: string | null }[]; lastDate: KstDate | null;
  /** 적용 시작일 뒤에 시작하는(아직 효력 전) 정규 일정 변경이 있어 저장하면 그 예정 변경이 취소됨 (A-03, 20261107) */
  cancelsPending: boolean;
};
export function parsePreview(j: any): RegularPreview {
  return {
    ok: !!j.ok, tutor: { id: j.tutor.id, name: j.tutor.name, timezone: j.tutor.timezone }, studentTimezone: j.student_timezone ?? 'Asia/Seoul',
    enrollment: { id: j.enrollment.id, finalEndDate: j.enrollment.final_end_date, durationMin: j.enrollment.duration_min },
    oldSlots: j.old_slots ?? [], newSlots: j.new_slots ?? [], effectiveFrom: j.effective_from, moved: parseMoved(j.moved), kept: parseKept(j.kept),
    skipped: ((j.skipped ?? []) as any[]).map((s) => ({ date: s.date, time: s.time, why: s.why })),
    problems: ((j.problems ?? []) as any[]).map((p) => ({ lessonId: p.lesson_id, seq: p.seq ?? null, date: p.date, time: p.time, why: p.why, other: p.other ?? null })),
    lastDate: j.last_date ?? null, cancelsPending: !!j.cancels_pending,
  };
}
/* eslint-enable @typescript-eslint/no-explicit-any */

/** 검사 결과 글 (운영진이 바로 고칠 수 있게 구체적으로) */
export function problemText(p: RegularPreview['problems'][number], tutor: { name: string; timezone: string }): string {
  const when = `${mdw(p.date)} ${ampmKo(p.time)}`;
  const local = tutor.timezone !== 'Asia/Seoul' ? ` 한국 시간 / ${ampmKo(formatInZone(kstToInstant(p.date, p.time), tutor.timezone).time)} ${koZone(tutor.timezone)}` : ' 한국 시간';
  switch (p.why) {
    case 'tutor_hours_range': return `${when}${local} — ${tutor.name} 강사 현지 오전 6:00~오후 10:30 밖의 시작 시각이에요.`;
    case 'tutor_unavailable': return `${when}${local} — ${tutor.name} 강사가 열어 둔 시간(My hours)이 아니에요.`;
    case 'tutor_time_off': return `${when} — ${tutor.name} 강사 휴무예요.`;
    case 'tutor_busy': return `${when} — ${tutor.name} 강사의 다른 수업과 겹쳐요 (휴식 10분 포함)${p.other ? `: ${p.other}` : ''}.`;
    case 'tutor_hold': return `${when} — 재등록 대기 중인 ${p.other ?? '다른 수강생'}의 고정 시간이에요.`;
    case 'after_end': return `${when} — 최종 종료일을 넘어요. 종료일은 연장하지 않아요 (대표 결정). 다른 요일·시간을 골라 주세요.`;
    default: return `${when} — ${p.why}`;
  }
}
export const KEPT_WHY: Record<string, string> = {
  before_from: '적용 전 수업 그대로', substitute: '대체 수업 그대로', makeup: '보강 확정 그대로', compensation: '보상 수업 그대로', leave_open: '강사 휴무 처리 중 그대로', other: '그대로',
  same: '요일·시각 그대로 (바뀌지 않음)',
};

/** 수업 종류 한국어 */
// 수업 종류 한국어 (H26(138)): DB type 이 없을 때 kind 로 — 이름은 class-type.ts 하나
export const KIND_KO: Record<string, string> = { regular: '정규', makeup: '보강', migrated_makeup: '보강', compensation: '보상수업', carryover: '지난 수강기간에서 이월된 수업', migrated_extra: '정규' };

export type RegularNoticeCtx = {
  studentNameKo: string; studentNameEn: string; studentTz: string; tutorName: string; tutorTz: string; durationMin: number;
  effectiveFrom: KstDate; newSlots: Slot[]; moved: MovedLesson[];
};

/** ③ 수강생용 카카오톡 문구 (한국어, 수강생 도시 시간 + 한국 시간) */
export function regularNoticeKo(c: RegularNoticeCtx): string {
  const abroad = c.studentTz && c.studentTz !== 'Asia/Seoul';
  const lines = c.moved.map((m) => `- ${koBoth(m.to, c.studentTz)}`);
  return [
    `[엣지영어] ${c.studentNameKo}님, 정규 수업 시간이 ${mdw(c.effectiveFrom)}부터 바뀌어요.`,
    `새 정규 수업: ${abroad ? `${koSi(slotsInZone(c.newSlots, c.studentTz, c.effectiveFrom))} ${koZoneBracket(c.studentTz)} / ${koSi(slotsText(c.newSlots))} ${koZoneBracket('Asia/Seoul')}` : `${koSi(slotsText(c.newSlots))} ${koZoneBracket('Asia/Seoul')}`} · ${c.durationMin}분 · ${c.tutorName} 강사님`,
    `바뀐 수업 ${c.moved.length}회:\n${lines.join('\n')}`,
    '이미 확정된 보강·대체 수업은 그대로예요. 날짜나 시간이 요청하신 것과 다르면 바로 알려주세요.',
  ].join('\n\n');
}

/** ③ 강사용 WhatsApp 문구 (영어, 강사 도시 시간 + KST) */
export function regularNoticeEn(c: RegularNoticeCtx): string {
  const kst = !c.tutorTz || c.tutorTz === 'Asia/Seoul';
  const line = (t: Date) => enBoth(t, c.tutorTz);
  return [
    // 적용일은 한국 날짜 기준이라 'KST' 를 밝히고, 해외 강사에게는 첫 바뀐 수업의 현지 날짜·시각을 같이 (QA-09)
    `SCHEDULE CHANGE - ${c.studentNameEn} (${c.durationMin} min), from ${enDateOf(c.effectiveFrom)} ${bold('KST')}${!kst && c.moved.length > 0 ? ` — first changed class: ${line(c.moved[0].to)}` : ''}`,
    `New regular time: ${kst ? `${slotsInZone(c.newSlots, 'Asia/Seoul', c.effectiveFrom, 'en')} ${bold('KST')}` : `${slotsInZone(c.newSlots, c.tutorTz, c.effectiveFrom, 'en')} ${bold(enZoneName(c.tutorTz))} / ${slotsInZone(c.newSlots, 'Asia/Seoul', c.effectiveFrom, 'en')} ${bold('KST')}`}`,
    `Changed classes (${c.moved.length}):\n${c.moved.map((m) => `- ${line(m.to)}`).join('\n')}`,
    'Confirmed make-up and cover classes stay as they are. Please update your schedule. Thank you!',
  ].join('\n\n');
}

/** 날짜 선택지: 오늘부터 최종 종료일까지 (한국 날짜) */
export function dateOptions(from: KstDate, to: KstDate): KstDate[] {
  const out: KstDate[] = [];
  for (let d = from; d <= to && out.length < 400; d = addDays(d, 1)) out.push(d);
  return out;
}
export const todayKst = (now: Date) => instantToKstDate(now);
