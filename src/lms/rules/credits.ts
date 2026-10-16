// 변경권 장부 (POL-CHG-03) — 기간마다 지급, 사용·복구는 '사건'으로만 기록 (덮어쓰기 없음)
// 같은 수업에 같은 사유로 두 번 차감되지 않도록 (lessonId, reason) 을 한 번만 받는다.
// DB에서는 credit_ledger 의 unique(lesson_id, reason) 제약이 같은 역할을 한다.

export type CreditEntry = {
  periodIndex: number;
  lessonId: string;
  reason: 'student_change' | 'restore_by_admin';
  delta: -1 | 1;
};

export class CreditLedger {
  private readonly entries: CreditEntry[] = [];

  constructor(private readonly grantedPerPeriod: number) {}

  balance(periodIndex: number): number {
    return this.entries.filter((e) => e.periodIndex === periodIndex).reduce((sum, e) => sum + e.delta, this.grantedPerPeriod);
  }

  /** 반환값: 실제로 새로 기록했는지 (이미 같은 기록이 있으면 false — 두 번 눌러도 한 번만 차감) */
  record(entry: CreditEntry): boolean {
    if (this.entries.some((e) => e.lessonId === entry.lessonId && e.reason === entry.reason)) return false;
    const next = this.balance(entry.periodIndex) + entry.delta;
    if (next < 0) throw new Error('변경권이 남아 있지 않습니다.');
    if (next > this.grantedPerPeriod) throw new Error('지급된 개수보다 많이 복구할 수 없습니다.');
    this.entries.push(entry);
    return true;
  }

  history(): readonly CreditEntry[] {
    return this.entries;
  }
}
