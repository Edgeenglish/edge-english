// 신규 학생 등록: 시험용 Supabase 실제 데이터 읽기 · 저장 (운영자 aal2 세션)
// - 읽기: 강사·가능 시간·수업·휴무 (운영자 읽기 RLS)
// - 저장: DB 함수 admin_register_student 하나 (표에 직접 쓰지 않음). 충돌이면 오류 상세(JSON)에 날짜 목록
// - 신청서(구글폼 응답) 연결은 아직 없음 → 빈 목록 (연결 방식은 대표 승인 후)

import type { SupabaseClient } from '@supabase/supabase-js';
import { addDays, instantToKstDate } from '../rules/dates';
import type { Busy } from '../rules/booking';
import type { RegTutor, savePayload } from './registration';

type Row = Record<string, unknown>;

async function all(q: () => { range: (a: number, b: number) => PromiseLike<{ data: Row[] | null; error: { message: string } | null }> }) {
  const out: Row[] = [];
  for (let from = 0; ; from += 1000) {
    const { data, error } = await q().range(from, from + 999);
    if (error) throw new Error(error.message);
    out.push(...(data ?? []));
    if (!data || data.length < 1000) return out;
  }
}

export async function loadRegTutors(sb: SupabaseClient, now: Date): Promise<RegTutor[]> {
  const today = instantToKstDate(now);
  const from = addDays(today, -14);
  const until = addDays(today, 200); // 24주 등록 + 여유
  const [tutors, avail, lessons, off] = await Promise.all([
    all(() => sb.from('tutors').select('id, name, country, timezone').eq('active', true).order('name')),
    all(() => sb.from('tutor_availability').select('tutor_id, weekday, start_local, end_local, timezone, effective_from, effective_to')),
    all(() => sb.from('lessons').select('id, tutor_id, kind, starts_at, ends_at, student:students(name_ko)').neq('state', 'canceled').gte('kst_date', from).lte('kst_date', until)),
    all(() => sb.from('tutor_time_off').select('id, tutor_id, starts_at, ends_at, reason').gte('ends_at', `${from}T00:00:00+09:00`)),
  ]);
  return tutors.map((t) => ({
    id: String(t.id),
    name: String(t.name),
    country: String(t.country),
    timezone: String(t.timezone),
    availability: avail
      .filter((a) => a.tutor_id === t.id)
      .map((a) => ({ weekday: Number(a.weekday), startLocal: String(a.start_local).slice(0, 5), endLocal: String(a.end_local).slice(0, 5), timezone: String(a.timezone), effectiveFrom: String(a.effective_from), effectiveTo: (a.effective_to as string | null) ?? null })),
    busy: [
      ...lessons
        .filter((l) => l.tutor_id === t.id)
        .map((l): Busy => ({ id: String(l.id), startsAt: new Date(String(l.starts_at)), endsAt: new Date(String(l.ends_at)), kind: l.kind === 'regular' ? 'regular' : 'makeup', label: (l.student as { name_ko?: string } | null)?.name_ko })),
      ...off.filter((o) => o.tutor_id === t.id).map((o): Busy => ({ id: String(o.id), startsAt: new Date(String(o.starts_at)), endsAt: new Date(String(o.ends_at)), kind: 'time_off', label: (o.reason as string | null) ?? '휴무' })),
    ].sort((a, b) => a.startsAt.getTime() - b.startsAt.getTime()),
  }));
}

export async function saveRegistration(sb: SupabaseClient, requestId: string, payload: ReturnType<typeof savePayload>) {
  const { data, error } = await sb.rpc('admin_register_student', { p_request_id: requestId, p: payload });
  if (error) {
    if (error.hint === 'schedule_conflict') {
      let conflicts: { date: string; time: string; reason: string }[] = [];
      try {
        conflicts = JSON.parse(error.details ?? '[]');
      } catch {
        /* 상세를 못 읽어도 메시지는 보여 줌 */
      }
      return { kind: 'error' as const, message: error.message, conflicts };
    }
    if (error.code === 'PGRST202') return { kind: 'error' as const, message: '등록 저장 함수가 아직 시험용 DB에 적용되지 않았어요 (적용은 대표 승인 후).' };
    if (error.code === '42501') return { kind: 'error' as const, message: '운영자 추가 인증(TOTP)이 필요해요. 다시 로그인해 주세요.' };
    return { kind: 'error' as const, message: error.message };
  }
  const r = data as {
    student_code: string;
    lessons: number;
    status: string;
    repeated?: boolean;
    plan_id?: string | null;
    plan_state?: 'proposed' | 'confirmed' | null;
    tutor_notice_id?: string | null;
    student_notice_id?: string | null;
  };
  return {
    kind: 'saved' as const,
    studentCode: r.student_code,
    lessons: r.lessons,
    status: r.status,
    repeated: !!r.repeated,
    planId: r.plan_id ?? null,
    planState: r.plan_state ?? null,
    tutorNoticeId: r.tutor_notice_id ?? null,
    studentNoticeId: r.student_notice_id ?? null,
  };
}

export async function studentsWithEmail(sb: SupabaseClient, email: string) {
  const { data, error } = await sb.rpc('admin_students_with_email', { p_email: email });
  return error ? [] : ((data ?? []) as { code: string; name_ko: string }[]);
}

