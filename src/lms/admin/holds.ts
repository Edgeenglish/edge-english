// 재등록 대기 자리 맡아 두기 (정책 원본 A22 · POL-RN-02, migration 1400 lms_slot_hold_hits 와 같은 규칙)
// 수업 중인 학생의 고정 시간은 그 학생의 마지막 수강 종료일 23:59 KST까지, 종료일 뒤 날짜에서도 다른 학생에게 주지 않는다.
// 종료일 안쪽은 실제 수업이 막으므로 종료일 다음 날부터만 만든다. 마감이 지나면 아무것도 만들지 않음

import type { Busy } from '../rules/booking';
import { addDays, diffDays, endOfKstDay, kstToInstant, weekdayOf, type KstDate } from '../rules/dates';

export type HoldSchedule = {
  id: string;
  tutorId: string;
  studentName: string;
  weekday: number;
  time: string; // 'HH:MM' 한국 시각
  durationMin: number;
  effectiveFrom: KstDate;
  effectiveTo: KstDate | null;
  lastEnd: KstDate; // 학생의 결제 확인·수강 중 등록 중 가장 늦은 종료일
};

const md = (d: KstDate) => `${Number(d.slice(5, 7))}/${Number(d.slice(8, 10))}`;

/** 강사별 '재등록 대기' 칸 (from~until 사이) */
export function holdBusy(rows: readonly HoldSchedule[], now: Date, until: KstDate): Map<string, Busy[]> {
  const out = new Map<string, Busy[]>();
  for (const r of rows) {
    if (now.getTime() >= endOfKstDay(r.lastEnd).getTime() + 1) continue;
    if (r.effectiveFrom > r.lastEnd || (r.effectiveTo !== null && r.effectiveTo < r.lastEnd)) continue;
    const list = out.get(r.tutorId) ?? [];
    for (let i = 1; i <= diffDays(r.lastEnd, until); i++) {
      const d = addDays(r.lastEnd, i);
      if (weekdayOf(d) !== r.weekday) continue;
      const startsAt = kstToInstant(d, r.time);
      list.push({ id: `hold-${r.id}-${d}`, startsAt, endsAt: new Date(startsAt.getTime() + r.durationMin * 60_000), kind: 'hold', label: `재등록 대기 · ${r.studentName} (${md(r.lastEnd)} 23:59까지)` });
    }
    out.set(r.tutorId, list);
  }
  return out;
}
