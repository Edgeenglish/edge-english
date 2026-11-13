// 강사 휴무 신청 (H26(137), 대표 11/13): Home 'Time off'. 날짜는 강사 현지 날짜, 규칙 검사는 DB (migration 20261113150000)
import type { SupabaseClient } from '@supabase/supabase-js';

export type TimeOffStatus = 'pending' | 'approved' | 'rejected';
export type TimeOffRow = {
  id: string;
  /** request = 강사 신청, leave = 운영진이 직접 넣은 휴무 (승인으로 보임) */
  source: 'request' | 'leave';
  status: TimeOffStatus;
  first: string;
  last: string;
  classes: number | null;
  rejectReason: string | null;
};
export type TimeOffList = { timezone: string; today: string; rows: TimeOffRow[]; year: { first: string; last: string }[] };
export type TimeOffPreview = { days: number; noticeDays: number; classes: { startsAt: Date; endsAt: Date; student: string }[] };
export type TimeOffKind = 'planned' | 'urgent';

/** 대표 11/13 확정: 3일 이상만 Home 신청 · 계획된 휴무는 14일 전 (DB lms_time_off_min_days·notice_days 와 같음) */
export const TIME_OFF_MIN_DAYS = 3;
export const TIME_OFF_NOTICE_DAYS = 14;

export type TimeOffActions = {
  list: () => Promise<TimeOffList | null>;
  preview: (first: string, last: string) => Promise<TimeOffPreview>;
  request: (first: string, last: string, kind: TimeOffKind, reason: string) => Promise<void>;
  withdraw: (id: string) => Promise<void>;
};

function check<T>(r: { data: T; error: { message: string } | null }): T {
  if (r.error) throw new Error(r.error.message);
  return r.data;
}
const missing = (code?: string) => code === 'PGRST202' || code === '42883';

export function parseTimeOffList(j: Record<string, unknown>): TimeOffList {
  const rows = (j.rows ?? []) as Record<string, unknown>[];
  return {
    timezone: String(j.timezone),
    today: String(j.today),
    rows: rows.map((r) => ({
      id: String(r.id),
      source: r.source === 'leave' ? 'leave' : 'request',
      status: r.status as TimeOffStatus,
      first: String(r.first),
      last: String(r.last),
      classes: typeof r.classes === 'number' ? r.classes : null,
      rejectReason: (r.reject_reason as string | null) ?? null,
    })),
    year: ((j.year ?? []) as { first: string; last: string }[]).map((y) => ({ first: String(y.first), last: String(y.last) })),
  };
}

export function timeOffActions(sb: SupabaseClient, tutorId: string | null): TimeOffActions {
  return {
    list: async () => {
      const r = await sb.rpc('tutor_time_off_list', { p_tutor: tutorId });
      if (missing(r.error?.code)) return null;
      return parseTimeOffList(check(r) as Record<string, unknown>);
    },
    preview: async (first, last) => {
      const j = check(await sb.rpc('tutor_time_off_preview', { p_tutor: tutorId, p_first: first, p_last: last })) as Record<string, unknown>;
      return {
        days: Number(j.days),
        noticeDays: Number(j.notice_days),
        classes: ((j.classes ?? []) as { starts_at: string; ends_at: string; student: string }[]).map((c) => ({ startsAt: new Date(c.starts_at), endsAt: new Date(c.ends_at), student: c.student })),
      };
    },
    request: async (first, last, kind, reason) => {
      check(await sb.rpc('tutor_time_off_request', { p_tutor: tutorId, p_first: first, p_last: last, p_kind: kind, p_reason: reason }));
    },
    withdraw: async (id) => {
      check(await sb.rpc('tutor_time_off_withdraw', { p_tutor: tutorId, p_request: id }));
    },
  };
}

/** 날짜 차이 (일) */
export function daysBetween(a: string, b: string): number {
  return Math.round((Date.parse(`${b}T00:00:00Z`) - Date.parse(`${a}T00:00:00Z`)) / 86_400_000);
}
