// 운영자 화면의 강사 현지 시각 = 그 시각에 강사가 있는 지역 (해외 이동 기간, 정책 원본 H26(173)(176))
//  강사 Home·강사 메일과 같은 규칙 (src/lms/tutor/travel.ts zoneAt = DB lms_tutor_tz_at)
//  이동 기간은 DB 함수 tutor_travel_periods (운영자는 어느 강사든 읽음)
import type { SupabaseClient } from '@supabase/supabase-js';
import { parsePeriod, zoneAt, type TravelPeriod } from '../tutor/travel';

/** 강사별 이동 기간. 읽지 못하면 빈 목록 (= 평소 시간대) */
export async function loadTutorTravel(sb: SupabaseClient, tutorIds: string[]): Promise<Map<string, TravelPeriod[]>> {
  const ids = [...new Set(tutorIds.filter(Boolean))];
  const out = new Map<string, TravelPeriod[]>();
  await Promise.all(ids.map(async (id) => {
    const { data, error } = await sb.rpc('tutor_travel_periods', { p_tutor: id });
    if (!error && Array.isArray(data) && data.length) out.set(id, data.map(parsePeriod));
  }));
  return out;
}

/** 그 시각의 강사 시간대를 돌려주는 함수 (이동 기간이 없으면 늘 평소 시간대) */
export const tutorZoneFn = (periods: readonly TravelPeriod[] | undefined, home: string) =>
  (t: Date) => (periods?.length ? zoneAt([...periods], t, home) : home);
