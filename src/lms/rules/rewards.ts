// 보상 적립금 장부 (POL-PAY-09, 정책 원본 A16~A18·G08)
// - LMS 원장 하나만 사용 (아임웹 회원 적립금 병행 안 함). 유효기간 없음.
// - 지급: 강사 6시간 미만 취소 1건당 1번만 (같은 수업 두 번 지급 방지)
// - 사용: 예약(보류) → 실제 결제 확인 후 확정 → 미결제·취소면 복구, 확정 후 환불되면 운영자가 복구
// - 모든 변화는 사건으로 한 줄씩 기록 (덮어쓰기 없음). DB에서는 reward_ledger·reward_redemptions 가 같은 역할

export type RewardEvent =
  | { kind: 'grant_tutor_late_cancel'; lessonId: string; amount: number }
  | { kind: 'hold'; redemptionId: string; amount: number }
  | { kind: 'release'; redemptionId: string; amount: number }
  | { kind: 'refund_restore'; redemptionId: string; amount: number };

type Redemption = { amount: number; state: 'held' | 'confirmed' | 'released' | 'restored'; paymentRef?: string };

export class RewardLedger {
  private readonly events: RewardEvent[] = [];
  private readonly redemptions = new Map<string, Redemption>();

  /** 쓸 수 있는 잔액 (예약 중인 금액은 빠짐) */
  balance(): number {
    return this.events.reduce((sum, e) => sum + (e.kind === 'hold' ? -e.amount : e.amount), 0);
  }

  /** 반환값: 새로 지급했는지 (같은 수업은 한 번만) */
  grantForTutorLateCancel(lessonId: string, amount: number): boolean {
    if (!Number.isInteger(amount) || amount <= 0) throw new Error('지급 금액이 올바르지 않습니다.');
    if (this.events.some((e) => e.kind === 'grant_tutor_late_cancel' && e.lessonId === lessonId)) return false;
    this.events.push({ kind: 'grant_tutor_late_cancel', lessonId, amount });
    return true;
  }

  /** 다음 결제에 쓰려고 예약 (아직 차감 확정 아님) */
  hold(redemptionId: string, amount: number): void {
    if (this.redemptions.has(redemptionId)) throw new Error('이미 처리한 사용 요청입니다.');
    if (!Number.isInteger(amount) || amount <= 0) throw new Error('사용 금액이 올바르지 않습니다.');
    if (amount > this.balance()) throw new Error('적립금 잔액이 부족합니다.');
    this.redemptions.set(redemptionId, { amount, state: 'held' });
    this.events.push({ kind: 'hold', redemptionId, amount });
  }

  /** 실제 결제(주문번호·입금 기록)를 확인한 뒤 확정. 같은 결제로 두 번 확정 불가 */
  confirm(redemptionId: string, paymentRef: string): void {
    const r = this.mustGet(redemptionId, 'held');
    if ([...this.redemptions.values()].some((x) => x.paymentRef === paymentRef)) throw new Error('이 결제에는 이미 적립금을 적용했습니다.');
    r.state = 'confirmed';
    r.paymentRef = paymentRef;
  }

  /** 결제하지 않았거나 취소된 예약을 되돌림 */
  release(redemptionId: string): void {
    const r = this.mustGet(redemptionId, 'held');
    r.state = 'released';
    this.events.push({ kind: 'release', redemptionId, amount: r.amount });
  }

  /** 확정 후 결제가 취소·환불되면 운영자가 적립금을 되돌림 */
  restoreAfterRefund(redemptionId: string): void {
    const r = this.mustGet(redemptionId, 'confirmed');
    r.state = 'restored';
    this.events.push({ kind: 'refund_restore', redemptionId, amount: r.amount });
  }

  history(): readonly RewardEvent[] {
    return this.events;
  }

  private mustGet(id: string, state: Redemption['state']): Redemption {
    const r = this.redemptions.get(id);
    if (!r) throw new Error('사용 요청을 찾을 수 없습니다.');
    if (r.state !== state) throw new Error(`이미 처리된 사용 요청입니다 (${r.state}).`);
    return r;
  }
}
