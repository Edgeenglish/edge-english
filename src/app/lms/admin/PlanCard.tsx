'use client';

// 신규 배정 일정안 카드 (시안 2차, D-51 2026-10-22 대표 승인)
// - 시간: 한국 / 강사 / 학생 세 줄, 현지 요일이 다르면 노란 표시
// - 답 대기: [가능하대요 → 확정] [안 된대요] [문구 다시 복사]
// - 확정: 강사·학생 안내 두 줄 (강사 줄 위). [복사]는 문구만 복사(기록 없음), 보낸 뒤 [보냄]를 눌러야 그쪽 '보냄'
//   (2026-10-22 대표 승인, A39(2) 갱신 — 복사만 하고 안 보내는 실수 방지). 양쪽 다 '보냄'이어야 매칭 업무 완료
// 복사가 막힌 기기에서는 문구를 보여 주고 길게 눌러 직접 복사

import { useState } from 'react';
import { proposalMessage, sentLabel, studentConfirmMessage, timeLines, tutorConfirmMessage, type Notice, type PlanView } from '@/lms/admin/confirm';

export type PlanHandlers = {
  confirm: () => Promise<void>;
  decline: () => Promise<void>;
  proposalCopied: () => Promise<void>;
  /** [보냄] — 그쪽 최종 안내를 보냄으로 기록 */
  noticeSent: (who: 'tutor' | 'student') => Promise<void>;
};

async function copyText(text: string): Promise<boolean> {
  try {
    await navigator.clipboard.writeText(text);
    return true;
  } catch {
    return false;
  }
}

export function TimeRows({ view }: { view: Pick<PlanView, 'slots' | 'startDate' | 'tutorTz' | 'studentTz'> }) {
  return (
    <dl className="grid grid-cols-[auto_1fr] gap-x-3 gap-y-1 text-[14.5px]">
      {timeLines(view).map((l) => (
        <div key={l.who} className="contents">
          <dt className="text-[#6b6880]">{l.who}</dt>
          <dd className={l.who === '한국' ? 'font-bold text-[#1d1b2b]' : 'text-[#1d1b2b]'}>
            {l.otherDay ? <span className="rounded-[6px] bg-[#fff1c2] px-1.5 font-bold text-[#6a4a00]">{l.text}</span> : l.text}
          </dd>
        </div>
      ))}
    </dl>
  );
}

export default function PlanCard({ view, handlers, showTimes = true }: { view: PlanView; handlers: PlanHandlers; showTimes?: boolean }) {
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState('');
  const [manual, setManual] = useState<{ text: string; done?: () => Promise<void> } | null>(null);
  const [copied, setCopied] = useState<('tutor' | 'student')[]>([]);
  const [asking, setAsking] = useState(false);

  async function run(f: () => Promise<void>) {
    if (busy) return;
    setBusy(true);
    setErr('');
    try {
      await f();
    } catch (e) {
      setErr(e instanceof Error ? e.message : '처리하지 못했어요.');
    } finally {
      setBusy(false);
    }
  }
  // 제안 문구: 복사 = 제안 보냄 기록 (A39(1) 그대로). 복사가 막히면 문구를 보여 주고 직접 복사 후 기록
  async function copyThen(text: string, record: () => Promise<void>) {
    if (await copyText(text)) return run(record);
    setManual({ text, done: record });
  }
  // 최종 안내: 복사만 (기록 없음). 보낸 뒤 [보냄]
  async function copyOnly(who: 'tutor' | 'student', text: string) {
    if (await copyText(text)) setCopied((c) => [...c, who]);
    else setManual({ text });
  }

  const rows: { who: 'tutor' | 'student'; label: string; n: Notice | null; text: string }[] = [
    { who: 'tutor', label: '강사 · WhatsApp', n: view.tutorNotice, text: tutorConfirmMessage(view) },
    { who: 'student', label: '학생 · 카톡', n: view.studentNotice, text: studentConfirmMessage(view) },
  ];

  return (
    <div className="grid gap-2.5">
      {showTimes && <TimeRows view={view} />}
      {view.state === 'proposed' ? (
        <>
          <p className="text-[13px] text-[#6b6880]">{view.proposalSentAt ? `제안 보냄 ${sentLabel(view.proposalSentAt)}` : '강사에게 아직 제안 안 함'}</p>
          <div className="grid grid-cols-2 gap-2">
            <button type="button" disabled={busy} onClick={() => run(handlers.confirm)} className="col-span-2 min-h-[50px] rounded-[12px] bg-[#7d5ffb] text-[15.5px] font-bold text-white disabled:bg-[#cfc4ff]">
              가능하대요 → 확정
            </button>
            {asking ? (
              <div className="col-span-2 rounded-[12px] bg-[#fff5f3] px-3 py-2.5">
                <p className="text-[13.5px] text-[#8a2a1b]">이 안을 닫을까요? 닫은 뒤 다른 강사·시간으로 다시 제안해요.</p>
                <div className="mt-2 flex gap-2">
                  <button type="button" disabled={busy} onClick={() => run(handlers.decline)} className="min-h-[42px] flex-1 rounded-[10px] bg-[#c4321f] text-[14px] font-bold text-white">
                    닫기
                  </button>
                  <button type="button" onClick={() => setAsking(false)} className="min-h-[42px] flex-1 rounded-[10px] border border-[#e6e3ef] bg-white text-[14px] text-[#1d1b2b]">
                    그대로 두기
                  </button>
                </div>
              </div>
            ) : (
              <>
                <button type="button" onClick={() => setAsking(true)} className="min-h-[46px] rounded-[12px] border border-[#e6e3ef] bg-white text-[14px] text-[#1d1b2b]">
                  안 된대요
                </button>
                <button type="button" disabled={busy} onClick={() => copyThen(proposalMessage(view), handlers.proposalCopied)} className="min-h-[46px] rounded-[12px] border border-[#e6e3ef] bg-white text-[14px] text-[#1d1b2b]">
                  {view.proposalSentAt ? '문구 다시 복사' : '제안 문구 복사'}
                </button>
              </>
            )}
          </div>
        </>
      ) : (
        <div className="grid gap-2">
          {rows.map(({ who, label, n, text }) => {
            const sent = n?.status === 'sent';
            return (
              <div key={who} className={`rounded-[12px] border px-3 py-2.5 ${sent ? 'border-[#cfe9db] bg-[#f2fbf6]' : 'border-[#f2c4bd] bg-[#fff5f3]'}`}>
                <div className="flex items-center gap-2">
                  <div className="min-w-0 flex-1">
                    <b className="block text-[14.5px] text-[#1d1b2b]">{label}</b>
                    <span className={`text-[12.5px] ${sent ? 'text-[#1f6b44]' : 'text-[#8a2a1b]'}`}>
                      {sent && n?.sentAt
                        ? `보냄 ${sentLabel(n.sentAt)}`
                        : n?.status === 'failed' || n?.status === 'unknown'
                          ? '발송 확인 필요'
                          : '안 보냄'}
                    </span>
                  </div>
                  <div className="flex shrink-0 gap-1.5">
                    <button type="button" disabled={!n} onClick={() => copyOnly(who, text)}
                      className={`min-h-[44px] rounded-[10px] border px-3 text-[14px] ${copied.includes(who) ? 'border-[#c9c6d6] bg-[#d9d6e3] font-bold text-[#4a4760]' : 'border-[#e6e3ef] bg-white text-[#1d1b2b]'}`}>
                      {copied.includes(who) ? '복사함 ✓' : '복사'}
                    </button>
                    {sent ? (
                      <button type="button" disabled className="min-h-[44px] rounded-[10px] border border-[#c9c6d6] bg-[#d9d6e3] px-3 text-[14px] font-bold text-[#4a4760]">
                        보냄 ✓
                      </button>
                    ) : (
                      <button
                        type="button"
                        disabled={busy || !n}
                        onClick={() => run(() => handlers.noticeSent(who))}
                        className="min-h-[44px] rounded-[10px] bg-[#7d5ffb] px-3 text-[14px] font-bold text-white disabled:bg-[#cfc4ff]"
                      >
                        보냄
                      </button>
                    )}
                  </div>
                </div>
              </div>
            );
          })}
        </div>
      )}
      {manual && (
        <div className="rounded-[12px] border border-[#e6e3ef] bg-white p-3">
          <p className="text-[13px] text-[#6b6880]">
            이 기기에서는 자동 복사가 안 돼요. 아래 글을 길게 눌러 복사해 주세요.{manual.done ? ' 복사한 뒤 [복사했어요]를 눌러 주세요.' : ''}
          </p>
          <textarea readOnly value={manual.text} rows={6} onFocus={(e) => e.currentTarget.select()} className="mt-2 w-full rounded-[10px] border border-[#e6e3ef] p-2 text-[13.5px] text-[#1d1b2b]" />
          <button
            type="button"
            onClick={() => {
              const d = manual.done;
              setManual(null);
              if (d) run(d);
            }}
            className="mt-2 min-h-[44px] w-full rounded-[10px] bg-[#7d5ffb] text-[14px] font-bold text-white"
          >
            {manual.done ? '복사했어요' : '닫기'}
          </button>
        </div>
      )}
      {err && <p className="text-[13px] text-[#b3261e]">{err}</p>}
    </div>
  );
}
