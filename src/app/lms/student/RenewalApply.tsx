'use client';

// 학생 재등록 신청 창 (대표 11/21 시안 확정 https://claude.ai/artifact/SnN71zMF8AzWNrJEYgdV7F, migration 20261121100000)
// 1 기간 선택 → [다음](저장만) → 2 입금 · 신청 → [재등록 신청하기] 뒤에만 '재등록 신청 완료 · 입금 확인 중'
import { useState } from 'react';
import {
  KAKAO_CHANNEL, RENEWAL_PAY, RenewalError, bankAmount, maxPoints, parsePoints, renewalStage,
  type RenewalActions, type RenewalInfo, type RenewalMethod, type RenewalWeeks,
} from '@/lms/student/renewal-apply';

const won = (n: number) => `${n.toLocaleString('ko-KR')}원`;
const KEEP = '기존 수업 일정으로 이어서 등록됩니다.';
const ASK = '수업 횟수나 일정 변경을 원하시면 입금 전에 ';
const CARD_NOTE = '적립금은 계좌이체에만 적용돼요. 카드결제로 쓰시려면 ';

function Ask({ text = ASK }: { text?: string }) {
  return (
    <p className="text-[12.5px] leading-relaxed text-[#55526a]">
      {text}<a href={KAKAO_CHANNEL} target="_blank" rel="noopener noreferrer" className="font-bold text-[#5b3df0]">문의</a>해 주세요.
    </p>
  );
}
function Notice() {
  return (
    <p className="rounded-[12px] border border-[#f0d27a] bg-[#fff4d6] px-3.5 py-3 text-[13.5px] leading-relaxed text-[#5c3b00]">
      지금 재등록하시면<br />잔여 수업이 있다면 다음 수강 기간으로 이월되고, 기존 수업 요일·시간도 그대로 유지돼요.
      <br /><br />수업은 결제 완료 순서로 확정되며,<br />입금이 늦어지면 강사님의 가능 시간이 달라질 수 있습니다.
    </p>
  );
}
function Box({ title, children }: { title?: string; children: React.ReactNode }) {
  return (
    <div className="grid gap-2 rounded-[14px] border border-[#e6e3ef] bg-white px-4 py-3.5">
      {title && <h3 className="text-[13.5px] font-bold text-[#55526a]">{title}</h3>}
      {children}
    </div>
  );
}
function Row({ k, v }: { k: string; v: string }) {
  return (
    <div className="flex justify-between gap-3 text-[14.5px]">
      <span className="text-[#55526a]">{k}</span>
      <b className="text-right font-bold text-[#1d1b2b]">{v}</b>
    </div>
  );
}
function Steps({ n }: { n: 1 | 2 }) {
  return (
    <div className="flex items-center gap-2 text-[13px] font-bold text-[#8b88a0]">
      <span className={n === 1 ? 'text-[#5b3df0]' : ''}>1 기간 선택</span>
      <span aria-hidden>›</span>
      <span className={n === 2 ? 'text-[#5b3df0]' : ''}>2 입금 · 신청</span>
    </div>
  );
}
const btn = 'min-h-[48px] w-full rounded-[12px] bg-[#5b3df0] text-[16px] font-extrabold text-white disabled:bg-[#cfcbe0] disabled:text-[#6b6880]';
const Err = ({ text }: { text: string | null }) => (text ? <p className="text-[13px] font-semibold text-[#b3261e]">{text}</p> : null);

export default function RenewalApply(props: {
  info: RenewalInfo;
  actions: RenewalActions;
  /** 저장·신청 뒤 새 상태 (홈 카드도 같이 바뀜) */
  onChanged: (i: RenewalInfo) => void;
  /** '40분 · 주 2회' 옆에 보일 정규 수업 (학생 시간) */
  slotsText: string | null;
  tutors: string;
  /** 날짜 글 '12월 15일(화)' (보이는 시간대) */
  dateText: (d: Date) => string;
  /** 한국 날짜 'YYYY-MM-DD' → '12/1(화)' */
  kstDayText: (d: string) => string;
}) {
  const { info, actions } = props;
  const stage = renewalStage(info);
  const req = info.request;
  const [step, setStep] = useState<1 | 2>(stage === 'draft' ? 2 : 1);
  const [weeks, setWeeks] = useState<RenewalWeeks | null>(req?.weeks ?? null);
  const [pointsText, setPointsText] = useState(req && req.points > 0 ? req.points.toLocaleString('ko-KR') : '');
  const [method, setMethod] = useState<RenewalMethod>('bank_transfer');
  const [payer, setPayer] = useState('');
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<{ field: string | null; text: string } | null>(null);
  const [copied, setCopied] = useState(false);

  const plan = info.plans.find((p) => p.weeks === weeks) ?? null;
  const points = parsePoints(pointsText);
  const max = maxPoints(info.pointsBalance, plan?.price ?? null);
  const pointsErr = points === null ? '숫자만 넣어 주세요' : points > max ? `최대 ${won(max)}까지 쓸 수 있어요` : null;
  const endText = info.lastLessonAt ? props.dateText(info.lastLessonAt) : info.finalEndDate ? props.kstDayText(info.finalEndDate) : '';
  const course = `${info.durationMin}분 · 주 ${info.weeklyCount}회`;

  async function refresh() {
    const n = await actions.info();
    if (n) props.onChanged(n);
  }
  async function next() {
    if (!weeks || points === null || pointsErr) return;
    setBusy(true); setErr(null);
    try {
      await actions.save(weeks, points);
      await refresh();
      setStep(2);
    } catch (e) {
      setErr({ field: e instanceof RenewalError ? e.field : null, text: e instanceof Error ? e.message : '저장하지 못했어요.' });
    } finally { setBusy(false); }
  }
  async function submit() {
    if (!req || !payer.trim()) return;
    setBusy(true); setErr(null);
    try {
      await actions.submit(req.id, method, payer);
      await refresh();
    } catch (e) {
      setErr({ field: e instanceof RenewalError ? e.field : null, text: e instanceof Error ? e.message : '신청하지 못했어요.' });
      if (e instanceof RenewalError && e.field === 'points') { await refresh(); setStep(1); }
    } finally { setBusy(false); }
  }
  async function copy() {
    try { await navigator.clipboard.writeText(RENEWAL_PAY.bank.replace(/^\S+\s/, '')); setCopied(true); } catch { /* 복사 안 되는 화면 */ }
  }

  const current = (
    <Box title="현재 수업">
      <Row k="수업" v={course} />
      {props.tutors && <Row k="담당 강사" v={props.tutors} />}
      {props.slotsText && <Row k="정규 수업" v={props.slotsText} />}
      {endText && <Row k="수강 종료일" v={endText} />}
    </Box>
  );
  const title = <h2 className="text-[20px] font-extrabold text-[#1d1b2b]">재등록 신청</h2>;

  if (stage === 'renewed') {
    return (
      <div className="grid gap-3.5">
        {title}
        <p className="text-[15px] font-extrabold text-[#1f7a4d]">✓ 재등록 완료</p>
        {info.next && (
          <Box title="다음 수강 기간">
            <Row k="기간" v={`${props.kstDayText(info.next.startDate)} ~ ${props.kstDayText(info.next.finalEndDate)}`} />
          </Box>
        )}
      </div>
    );
  }
  if (stage === 'late') {
    return (
      <div className="grid gap-3.5">
        {title}
        {current}
        <p className="rounded-[12px] border border-[#f0d27a] bg-[#fff4d6] px-3.5 py-3 text-[13.5px] leading-relaxed text-[#5c3b00]">
          수강 종료일이 지나 기존 강사님·수업 시간이 바뀔 수 있어요.<br />재등록은 카카오톡으로 문의해 주세요.
        </p>
        <a href={KAKAO_CHANNEL} target="_blank" rel="noopener noreferrer" className={`${btn} flex items-center justify-center`}>카카오톡으로 문의하기</a>
      </div>
    );
  }
  if (stage === 'submitted' && req) {
    const bank = req.method === 'bank_transfer';
    return (
      <div className="grid gap-3.5">
        {title}
        <p className="text-[15px] font-extrabold text-[#1f7a4d]">✓ 재등록 신청 완료 · 입금 확인 중</p>
        <Box title="신청 내역">
          <Row k="수강 기간" v={info.plans.find((p) => p.weeks === req.weeks)?.title ?? `${req.weeks}주`} />
          <Row k="수업" v={`${course}${props.tutors ? ` · ${props.tutors}` : ''}`} />
          {props.slotsText && <Row k="정규 수업" v={props.slotsText} />}
          <Row k="결제" v={`${bank ? '계좌이체' : '카드결제'} ${won(bank ? bankAmount(req.price, req.points) : req.price)}`} />
          {req.points > 0 && <Row k="사용 적립금" v={won(req.points)} />}
          <Row k={bank ? '입금자명' : '결제자명'} v={req.payerName ?? ''} />
          {req.submittedAt && <Row k="신청일" v={props.dateText(req.submittedAt)} />}
        </Box>
        <Ask text="바꿀 내용이 있으면 " />
      </div>
    );
  }
  if (info.plans.length === 0) {
    return (
      <div className="grid gap-3.5">
        {title}
        {current}
        <Ask text="재등록은 카카오톡으로 " />
      </div>
    );
  }

  if (step === 1) {
    const usePoints = info.pointsBalance > 0;
    return (
      <div className="grid gap-3.5">
        {title}
        <Steps n={1} />
        <div className="grid gap-3.5 lg:grid-cols-[minmax(0,1fr)_minmax(0,1.4fr)] lg:items-start lg:gap-5">
          {current}
          <div className="grid gap-3">
            <p className="text-[14px] font-semibold text-[#1d1b2b]">{KEEP}</p>
            <div className="grid gap-2" role="radiogroup" aria-label="수강 기간">
              {info.plans.map((p) => {
                const on = weeks === p.weeks;
                return (
                  <button key={p.weeks} type="button" role="radio" aria-checked={on} onClick={() => setWeeks(p.weeks)}
                    className={`grid gap-0.5 rounded-[12px] border-[1.5px] px-3.5 py-3 text-left text-[14px] ${on ? 'border-[#5b3df0] shadow-[inset_0_0_0_1px_#5b3df0]' : 'border-[#e6e3ef]'} ${p.best ? 'bg-[#f7f5fd]' : 'bg-white'}`}>
                    <span className={`text-[15px] font-extrabold ${p.best ? 'text-[#5b3df0]' : 'text-[#1d1b2b]'}`}>{p.title}{p.sub ? ` | ${p.sub}` : ''}{on ? ' ✓' : ''}</span>
                    <span className="font-bold text-[#1d1b2b]">
                      {won(p.price)}{p.perMonth && <small className="ml-1 text-[12.5px] font-semibold text-[#55526a]">(월 {p.weeks === 24 ? '약 ' : ''}{won(p.perMonth)})</small>}
                    </span>
                    {p.save && <span className="text-[13px] font-bold text-[#5b3df0]">{p.save}</span>}
                  </button>
                );
              })}
            </div>
            {usePoints && (
              <Box title="적립금">
                <Row k="보유 적립금" v={won(info.pointsBalance)} />
                <label className="flex items-center gap-2 text-[14.5px]">
                  <span className="flex-1 text-[#55526a]">사용할 적립금</span>
                  <input id="renew-points" inputMode="numeric" value={pointsText} placeholder="0"
                    onChange={(e) => setPointsText(e.target.value)}
                    className="min-h-[42px] w-[120px] rounded-[10px] border-[1.5px] border-[#e6e3ef] px-3 text-right text-[16px] font-bold" />
                  <span>원</span>
                </label>
                <Err text={pointsErr ?? (err?.field === 'points' ? err.text : null)} />
                <p className="text-[12.5px] leading-relaxed text-[#55526a]">
                  최대 {won(max)} · {CARD_NOTE}<a href={KAKAO_CHANNEL} target="_blank" rel="noopener noreferrer" className="font-bold text-[#5b3df0]">문의</a>해 주세요.
                </p>
                {plan && points !== null && !pointsErr && (
                  <>
                    <div className="border-t border-[#e6e3ef] pt-2"><Row k="계좌이체" v={won(bankAmount(plan.price, points))} /></div>
                    <Row k="카드결제" v={won(plan.price)} />
                  </>
                )}
              </Box>
            )}
            <Notice />
            <Err text={err && err.field !== 'points' ? err.text : null} />
            <button type="button" className={btn} disabled={!weeks || points === null || !!pointsErr || busy} onClick={next}>다음</button>
            <Ask />
          </div>
        </div>
      </div>
    );
  }

  // 2단계 · 입금 · 신청
  if (!req) return null;
  const reqPlan = info.plans.find((p) => p.weeks === req.weeks);
  const payBox = (
    <Box title={`결제 금액 · ${reqPlan?.title ?? ''}`}>
      <div className="grid gap-1 text-[14.5px]">
        <span className="text-[12.5px] font-bold text-[#55526a]">계좌이체</span>
        <span className="text-[22px] font-extrabold">{won(bankAmount(req.price, req.points))}</span>
        {req.points > 0 && <span className="text-[12.5px] text-[#55526a]">{won(req.price)} − 적립금 {won(req.points)}</span>}
        <span className="flex flex-wrap items-center gap-1.5">
          {RENEWAL_PAY.bank}
          <button type="button" onClick={copy} disabled={copied}
            className={`rounded-[8px] px-2.5 py-1 text-[12.5px] font-bold ${copied ? 'bg-[#e6e3ef] text-[#6b6880]' : 'bg-[#f0ecff] text-[#5b3df0]'}`}>
            {copied ? '복사함 ✓' : '복사'}
          </button>
        </span>
        <span>{RENEWAL_PAY.holder}</span>
      </div>
      <div className="grid gap-1 border-t border-[#e6e3ef] pt-2.5 text-[14.5px]">
        <span className="text-[12.5px] font-bold text-[#55526a]">카드결제</span>
        <span className="text-[22px] font-extrabold">{won(req.price)}</span>
        {req.points > 0 && (
          <span className="text-[12.5px] text-[#55526a]">
            {CARD_NOTE}<a href={KAKAO_CHANNEL} target="_blank" rel="noopener noreferrer" className="font-bold text-[#5b3df0]">문의</a>해 주세요.
          </span>
        )}
        <a href={RENEWAL_PAY.card} target="_blank" rel="noopener noreferrer" className="font-bold text-[#5b3df0]">카드로 결제하기 ›</a>
      </div>
    </Box>
  );
  const nameLabel = method === 'card_link' ? '결제자명' : '입금자명';
  const form = (
    <Box title="결제한 뒤 적어 주세요">
      <div className="grid gap-1.5 text-[14px]">
        <span>결제 방법</span>
        <div className="flex gap-2" role="radiogroup" aria-label="결제 방법">
          {(['bank_transfer', 'card_link'] as const).map((m) => (
            <button key={m} type="button" role="radio" aria-checked={method === m} onClick={() => setMethod(m)}
              className={`min-h-[42px] flex-1 rounded-[10px] border-[1.5px] text-[14px] font-bold ${method === m ? 'border-[#5b3df0] bg-[#f7f5fd] text-[#5b3df0]' : 'border-[#e6e3ef] text-[#1d1b2b]'}`}>
              {m === 'bank_transfer' ? '계좌이체' : '카드결제'}
            </button>
          ))}
        </div>
      </div>
      <label className="grid gap-1.5 text-[14px]">
        <span>{nameLabel}</span>
        <input id="renew-payer" value={payer} onChange={(e) => setPayer(e.target.value)} maxLength={50}
          className="min-h-[44px] rounded-[10px] border-[1.5px] border-[#e6e3ef] px-3 text-[16px]" />
      </label>
      <Err text={err ? err.text : null} />
    </Box>
  );
  return (
    <div className="grid gap-3.5">
      {title}
      <Steps n={2} />
      <button type="button" onClick={() => { setErr(null); setStep(1); }} className="justify-self-start text-[13px] font-bold text-[#5b3df0]">‹ 기간·적립금 바꾸기</button>
      <div className="grid gap-3.5 lg:grid-cols-2 lg:items-start lg:gap-5">
        <div className="grid gap-3">{payBox}<Notice /></div>
        <div className="grid gap-3">
          {form}
          <button type="button" className={btn} disabled={!payer.trim() || busy} onClick={submit}>재등록 신청하기</button>
          <Ask />
        </div>
      </div>
    </div>
  );
}
