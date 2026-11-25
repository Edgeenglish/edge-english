// 강사 임시 근무 지역 변경 → 새 수업 시간 고르기 (정책 원본 H26(218), migration 20261123140000)
// 판정·확정은 모두 DB. 여기는 화면용 모양 바꾸기 + 고르기 창의 자동 배정(같은 주 안, 매주 시간 → 날짜별)만
import type { SupabaseClient } from '@supabase/supabase-js';
import { formatInZone } from './rules/dates';

export type TtlState = 'proposed' | 'returned' | 'later' | 'confirmed' | 'admin' | 'admin_done';
export type TtlRow = { key: string; orig: Date; minutes: number; state: TtlState | null; newAt: Date | null; conflict: string | null };
export type TtlItem = {
  tutorId: string; tutor: string; studentId: string; student: string;
  city: string; timezone: string; from: string; to: string | null; rcPending: boolean; rows: TtlRow[];
};
export type TtlOptionRow = { key: string; orig: Date; minutes: number; state: TtlState | null; cands: Date[] };
export type TtlWeekly = { dow: number; time: string; sample: Date };
export type TtlOptions = { rows: TtlOptionRow[]; weekly: TtlWeekly[]; need: number; rcPending: boolean; proposed: boolean };
/** 한 회차 선택: 시각 · 'admin'(운영진에게 맡김) · 'later'(나중에 고르기) · null(아직 없음) */
export type TtlPick = Date | 'admin' | 'later' | null;
export type TtlResult = { ok: number; admin: number; sent: number; left: number };

type RawRow = { key: string; orig: string; minutes: number; state: TtlState | null; new?: string | null; conflict?: string | null; cands?: string[] };
type RawItem = { tutor_id: string; tutor: string; student_id: string; student: string; city: string; timezone: string; from: string; to: string | null; rc_pending: boolean; rows: RawRow[] };

const row = (r: RawRow): TtlRow => ({ key: r.key, orig: new Date(r.orig), minutes: r.minutes, state: r.state, newAt: r.new ? new Date(r.new) : null, conflict: r.conflict ?? null });
export const parseItems = (data: unknown): TtlItem[] => ((data as RawItem[]) ?? []).map((x) => ({
  tutorId: x.tutor_id, tutor: x.tutor, studentId: x.student_id, student: x.student, city: x.city, timezone: x.timezone,
  from: x.from, to: x.to, rcPending: !!x.rc_pending, rows: (x.rows ?? []).map(row),
}));
export function parseOptions(data: unknown): TtlOptions {
  const d = (data ?? {}) as { rows?: RawRow[]; weekly?: { dow: number; time: string; sample: string }[]; need?: number; rc_pending?: boolean; proposed?: boolean };
  return {
    rows: (d.rows ?? []).map((r) => ({ key: r.key, orig: new Date(r.orig), minutes: r.minutes, state: r.state, cands: (r.cands ?? []).map((c) => new Date(c)) })),
    weekly: (d.weekly ?? []).map((w) => ({ dow: w.dow, time: w.time, sample: new Date(w.sample) })),
    need: d.need ?? 0, rcPending: !!d.rc_pending, proposed: !!d.proposed,
  };
}

function check<T>(r: { data: T | null; error: { code?: string; message: string } | null }): T {
  if (r.error) throw new Error(r.error.message);
  return r.data as T;
}
const items = (picks: Record<string, TtlPick>) => Object.entries(picks).filter(([, v]) => v !== null)
  .map(([key, v]) => (v === 'admin' ? { key, admin: true } : v === 'later' ? { key, later: true } : { key, at: (v as Date).toISOString() }));
const result = (d: unknown): TtlResult => { const x = (d ?? {}) as Partial<TtlResult>; return { ok: x.ok ?? 0, admin: x.admin ?? 0, sent: x.sent ?? 0, left: x.left ?? 0 }; };

export type TtlActions = {
  items: () => Promise<TtlItem[]>;
  options: (item: TtlItem) => Promise<TtlOptions>;
  submit: (item: TtlItem, picks: Record<string, TtlPick>) => Promise<TtlResult>;
  /** 학생만: 강사가 보낸 시간 동의 / 다시 조정 */
  answer?: (item: TtlItem, agree: boolean) => Promise<TtlResult>;
};
/** 강사 화면 (tutorId = 운영자가 고른 강사, 강사 본인은 null) */
export const tutorTtl = (sb: SupabaseClient, tutorId: string | null): TtlActions => ({
  items: async () => parseItems(check(await sb.rpc('tutor_ttl_items', { p_tutor: tutorId }))),
  options: async (it) => parseOptions(check(await sb.rpc('tutor_ttl_options', { p_tutor: it.tutorId, p_student: it.studentId }))),
  submit: async (it, picks) => result(check(await sb.rpc('tutor_ttl_submit', { p_tutor: it.tutorId, p_student: it.studentId, p_items: items(picks) }))),
});
/** 학생 화면 (studentId = 운영자가 고른 학생, 학생 본인은 null) */
export const studentTtl = (sb: SupabaseClient, studentId: string | null): TtlActions => ({
  items: async () => parseItems(check(await sb.rpc('student_ttl_items', { p_student: studentId }))),
  options: async (it) => parseOptions(check(await sb.rpc('student_ttl_options', { p_student: it.studentId, p_tutor: it.tutorId }))),
  submit: async (it, picks) => result(check(await sb.rpc('student_ttl_submit', { p_student: it.studentId, p_tutor: it.tutorId, p_items: items(picks) }))),
  answer: async (it, agree) => result(check(await sb.rpc('student_ttl_answer', { p_student: it.studentId, p_tutor: it.tutorId, p_agree: agree }))),
});

// ---------------------------------------------------------------- 상태·자동 배정
export type TtlStatus = { kind: 'open' | 'proposed' | 'returned' | 'partial' | 'admin' | 'done'; n: number; confirmed: number; admin: number; proposed: number; open: number };
export function ttlStatus(it: TtlItem): TtlStatus {
  const n = it.rows.length;
  const c = (s: TtlState) => it.rows.filter((r) => r.state === s).length;
  const confirmed = c('confirmed') + c('admin_done');
  const admin = c('admin');
  const proposed = c('proposed');
  const open = it.rows.filter((r) => r.state === null || r.state === 'later' || r.state === 'returned').length;
  const kind = confirmed === n ? 'done' : proposed ? 'proposed' : admin ? 'admin' : c('returned') ? 'returned' : confirmed ? 'partial' : 'open';
  return { kind, n, confirmed, admin, proposed, open };
}

/** 한국 기준 '요일-시각' (매주 시간 묶음 열쇠, DB lms_ttl_options weekly 와 같음) */
export const weekKey = (t: Date) => { const f = formatInZone(t, 'Asia/Seoul'); return `${new Date(`${f.date}T00:00:00Z`).getUTCDay()}-${f.time}`; };
const overlaps = (a: Date, am: number, b: Date, bm: number) => a.getTime() < b.getTime() + bm * 60000 && b.getTime() < a.getTime() + am * 60000;
function clash(t: Date, min: number, rows: TtlOptionRow[], picks: Record<string, TtlPick>, except: string) {
  return rows.some((r) => r.key !== except && picks[r.key] instanceof Date && overlaps(t, min, picks[r.key] as Date, r.minutes));
}
/** 매주 시간(weekKey 묶음)을 고르면 회차마다 그 주 안에서 맞는 첫 시각 (없으면 null = 조정 필요). 'later'·'admin' 으로 둔 회차는 그대로 */
export function autoAssign(rows: TtlOptionRow[], weekly: string[], keep: Record<string, TtlPick> = {}): Record<string, TtlPick> {
  const out: Record<string, TtlPick> = {};
  for (const r of rows) {
    if (keep[r.key] === 'later' || keep[r.key] === 'admin') { out[r.key] = keep[r.key]; continue; }
    out[r.key] = r.cands.find((t) => weekly.includes(weekKey(t)) && !clash(t, r.minutes, rows, out, r.key)) ?? null;
  }
  return out;
}
/** 한 회차를 바꿀 때 고를 수 있는 시각 (다른 회차 선택과 겹치지 않는 것) */
export const alternatives = (r: TtlOptionRow, rows: TtlOptionRow[], picks: Record<string, TtlPick>) =>
  r.cands.filter((t) => !clash(t, r.minutes, rows, picks, r.key));
/** 그 회차 선택에 문제가 있는지: none = 아직 시간 없음 · clash = 다른 회차와 겹침 · null = 됨 */
export function pickProblem(r: TtlOptionRow, rows: TtlOptionRow[], picks: Record<string, TtlPick>): 'none' | 'clash' | null {
  const v = picks[r.key];
  if (v === 'later' || v === 'admin') return null;
  if (!(v instanceof Date)) return 'none';
  return clash(v, r.minutes, rows, picks, r.key) ? 'clash' : null;
}

/** 운영진 확인 까닭 (DB lms_ttl_conflict 코드) */
export const CONFLICT: Record<string, [string, string]> = {
  outside: ['Outside the temporary location dates', '근무 지역 변경 기간 밖이에요'],
  week: ['Not in the same week', '같은 주가 아니에요'],
  end: ['After the course end date', '수강 종료일 뒤예요'],
  past: ['Time has passed', '이미 지난 시간이에요'],
  off: ['Tutor time off', '선생님 휴무예요'],
  hours: ['Not in the tutor’s hours', '선생님 가능 시간이 아니에요'],
  busy: ['Time already taken', '다른 수업과 겹쳐요'],
  student: ['The student has another class', '다른 수업과 겹쳐요'],
  asked: ['Edge English will arrange', '운영진이 시간을 정해요'],
  gone: ['Class changed', '수업이 바뀌었어요'],
};
