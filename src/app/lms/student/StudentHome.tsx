'use client';

// 학생 마이페이지 A-1 (카드 쌓기형) — 휴대폰: 카드 순서대로 + 아래 탭 / PC: 왼쪽 메뉴 + 가운데 카드 + 오른쪽 현황·결제
// 판정은 모두 src/lms/student/home.ts (6시간 규칙은 rules/change.ts). 미리보기에서는 눌러도 저장·발송하지 않는다.

import { useMemo, useState } from 'react';
import books from '@/data/books.json';
import { diffDays, formatInZone, hoursBetween, type KstDate } from '@/lms/rules/dates';
import { fakeStudent } from '@/lms/student/fake-data';
import {
  cancelPreview,
  lessonsLeft,
  nextLesson,
  PAYMENT_METHOD_LABEL,
  pointsHistory,
  regularLessonsLeft,
  renewalPrompt,
  REQUEST_STATUS_LABEL,
  studentTodos,
  type RenewalState,
  type RequestStatus,
  type StudentLesson,
  type StudentRequest,
} from '@/lms/student/home';

type Tab = 'home' | 'schedule' | 'requests' | 'materials' | 'me';
type Overlay = null | { kind: 'request'; id: string } | { kind: 'payments' } | { kind: 'points' } | { kind: 'consent' } | { kind: 'cancel'; lessonId: string | null };

const TABS: { key: Tab; label: string; icon: string }[] = [
  { key: 'home', label: '홈', icon: 'M3 11l9-7 9 7v9a1 1 0 0 1-1 1h-5v-6H9v6H4a1 1 0 0 1-1-1z' },
  { key: 'schedule', label: '일정', icon: 'M5 4h14a2 2 0 0 1 2 2v13a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V6a2 2 0 0 1 2-2zM8 2v4M16 2v4M3 10h18' },
  { key: 'requests', label: '신청 내역', icon: 'M8 6h13M8 12h13M8 18h13M3 6h.01M3 12h.01M3 18h.01' },
  { key: 'materials', label: '학습자료', icon: 'M4 19V5a2 2 0 0 1 2-2h13v16H6a2 2 0 0 0-2 2z' },
  { key: 'me', label: '내 정보', icon: 'M12 12a4 4 0 1 0 0-8 4 4 0 0 0 0 8zM4 21c1.5-4 4.5-6 8-6s6.5 2 8 6' },
];

const STATUS_STYLE: Record<RequestStatus, string> = {
  tutor_reviewing: 'bg-[#fff1d6] text-[#8a5300]',
  admin_reviewing: 'bg-[#fff1d6] text-[#8a5300]',
  confirmed: 'bg-[#e3f5ea] text-[#13623a]',
  completed: 'bg-[#e3f5ea] text-[#13623a]',
};

const card = 'rounded-[16px] border border-[#e6e3ef] bg-white';

function kst(d: Date) {
  const f = formatInZone(d, 'Asia/Seoul');
  return { md: `${Number(f.date.slice(5, 7))}/${Number(f.date.slice(8, 10))}`, wd: '일월화수목금토'[new Date(`${f.date}T00:00:00Z`).getUTCDay()], time: f.time, date: f.date };
}
const fmtDate = (d: KstDate) => `${Number(d.slice(5, 7))}/${Number(d.slice(8, 10))}`;
const won = (n: number) => `${n.toLocaleString('ko-KR')}원`;

function Icon({ d, className = 'h-5 w-5' }: { d: string; className?: string }) {
  return (
    <svg aria-hidden viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth={2} strokeLinecap="round" strokeLinejoin="round" className={className}>
      {/* globals.css 의 '* { color }' 때문에 path 가 부모 색을 잃지 않도록 */}
      <path d={d} style={{ color: 'inherit' }} />
    </svg>
  );
}

export default function StudentHome({ nowIso, preview }: { nowIso: string; preview: boolean }) {
  const now = useMemo(() => new Date(nowIso), [nowIso]);
  const initial = useMemo(() => fakeStudent(now), [now]);
  const [lessons, setLessons] = useState<StudentLesson[]>(initial.lessons);
  const [creditsLeft, setCreditsLeft] = useState(initial.creditsLeft);
  const [makeupsOwed, setMakeupsOwed] = useState(initial.makeupsOwed);
  const [renewal, setRenewal] = useState<RenewalState>('not_requested');
  const [consents, setConsents] = useState(initial.pendingConsents);
  const [tab, setTab] = useState<Tab>('home');
  const [overlay, setOverlay] = useState<Overlay>(null);
  const [toast, setToast] = useState<string | null>(null);

  const s = initial;
  const todos = studentTodos({ pendingConsents: consents });
  const next = nextLesson(lessons, now);
  const left = lessonsLeft(lessons, makeupsOwed);
  const prompt = renewalPrompt(lessons, renewal, makeupsOwed);
  const dLeft = diffDays(formatInZone(now, 'Asia/Seoul').date, s.finalEndDate);
  const points = pointsHistory(s.points);
  const book = books.find((b) => b.title.replace(/\s/g, '') === s.textbook.title.replace(/\s/g, ''));

  function say(msg: string) {
    setToast(`${msg}${preview ? ' (미리보기: 실제로 저장되지 않아요)' : ''}`);
  }

  function confirmCancel(lesson: StudentLesson) {
    const d = cancelPreview({ lesson, now: new Date(), finalEndDate: s.finalEndDate, creditsLeft, holidays: new Set() }, null);
    if (!d.ok) return;
    setLessons((prev) => prev.map((l) => (l.id === lesson.id ? { ...l, state: 'canceled' } : l)));
    if (d.usesCredit) setCreditsLeft((c) => c - 1);
    if (d.makeupAllowed) setMakeupsOwed((n) => n + 1);
    setOverlay(null);
    say(d.consumesLesson ? '수업을 취소했어요. 수업 1회가 차감됐어요.' : '수업을 취소했어요. 보강 신청에서 시간을 골라 주세요.');
  }

  const nextCard = next && <NextLesson lesson={next} now={now} textbook={s.textbook} />;

  const renewalCard = prompt && (
    <section aria-label="재등록 안내" className="grid gap-2.5 rounded-[18px] border border-[#f0d27a] bg-[#fff4d6] p-4 lg:flex lg:items-center lg:gap-4">
      <div className="lg:flex-1">
        <h2 className="text-[15px] font-bold text-[#5c3b00]">수업이 {prompt.left}회 남았어요</h2>
        {prompt.mode === 'request' ? (
          <p className="mt-1 text-[13px] leading-relaxed text-[#5c3b00]">
            종료일 {fmtDate(s.finalEndDate)} 23:59까지 재등록 결제하면 남은 수업을 다음 등록으로 옮길 수 있고, 지금 고정 시간도 유지돼요.
          </p>
        ) : (
          <p className="mt-1 text-[13px] leading-relaxed text-[#5c3b00]">
            <b>재등록 신청 완료 · 결제 확인 중</b>이에요. 결제는 운영자가 직접 확인하고, 확인되면 이 안내가 사라져요. 마감은 {fmtDate(s.finalEndDate)} 23:59예요.
          </p>
        )}
      </div>
      {prompt.mode === 'request' ? (
        <button
          type="button"
          onClick={() => {
            setRenewal('requested');
            say('재등록을 신청했어요. 결제가 확인되면 안내가 사라져요.');
          }}
          className="min-h-[46px] rounded-[12px] bg-[#1b1442] px-5 text-[15px] font-bold text-white"
        >
          재등록 신청
        </button>
      ) : (
        <span className="justify-self-start rounded-full bg-white px-3 py-1.5 text-[13px] font-semibold text-[#8a5300]">결제 확인 대기</span>
      )}
    </section>
  );

  const statusTiles = (
    <section aria-label="수강 현황" className="grid grid-cols-3 gap-2">
      <Tile label="남은 수업" value={`${left.total}`} unit="회" sub={left.other ? `정규 ${left.regular} · 보강 ${left.other}` : `${s.totalLessons}회 중`} />
      <Tile label="변경권" value={`${creditsLeft}`} unit="개" sub={`이번 기간 ${s.creditsPerPeriod}개 중`} />
      <Tile label="수강 종료" value={dLeft > 0 ? `D-${dLeft}` : dLeft === 0 ? 'D-day' : '종료'} sub={`${fmtDate(s.finalEndDate)} (${kst(new Date(`${s.finalEndDate}T12:00:00+09:00`)).wd})`} />
    </section>
  );

  const actions = (
    <section aria-label="빠른 신청" className="grid grid-cols-2 gap-2">
      <button type="button" onClick={() => setOverlay({ kind: 'cancel', lessonId: null })} className={`${card} grid content-start gap-1.5 p-4 text-left`}>
        <Icon d={TABS[1].icon} className="h-[22px] w-[22px] text-[#5b3df0]" />
        <span className="text-[15px] font-bold">수업 변경·취소</span>
        <span className="text-[12px] leading-[1.55] text-[#55526a]">
          6시간 전: 변경권 1개 사용 · 보강 가능
          <br />
          6시간 이내: 수업 1회 차감 · 보강 불가 · 변경권 유지
        </span>
      </button>
      <button type="button" onClick={() => say('보강 신청 화면은 다음 단계에서 연결해요.')} className={`${card} grid content-start gap-1.5 p-4 text-left`}>
        <Icon d="M12 3a9 9 0 1 0 0 18 9 9 0 0 0 0-18zM12 7v5l3 2" className="h-[22px] w-[22px] text-[#5b3df0]" />
        <span className="text-[15px] font-bold">보강 신청</span>
        <span className="text-[12px] leading-[1.55] text-[#55526a]">
          보강할 수업 {makeupsOwed}회
          <br />
          강사 가능 시간 중 2~3개 골라 신청
        </span>
      </button>
    </section>
  );

  const requestList = (
    <section aria-label="신청 진행 상태" className={`${card} grid gap-1 p-4`}>
      <div className="flex items-center justify-between">
        <h2 className="text-[15px] font-bold">신청 진행 상태</h2>
        <button type="button" onClick={() => setTab('requests')} className="min-h-[36px] text-[13px] text-[#4b2fd6] underline">
          전체 ›
        </button>
      </div>
      {s.requests.map((r) => (
        <RequestRow key={r.id} r={r} onOpen={() => setOverlay({ kind: 'request', id: r.id })} />
      ))}
    </section>
  );

  const payBox = (
    <section aria-label="수강과 결제" className={`${card} px-4 pb-1.5 pt-4`}>
      <h2 className="mb-2 text-[15px] font-bold">수강·결제·적립금</h2>
      <LinkRow label="수강권" value={s.product} onClick={() => setOverlay({ kind: 'payments' })} />
      <LinkRow
        label="결제 내역"
        value={s.payments[0].confirmedOn ? `확인 완료 (${fmtDate(s.payments[0].confirmedOn)})` : '확인 중'}
        valueClass="text-[#13623a]"
        onClick={() => setOverlay({ kind: 'payments' })}
      />
      <LinkRow label="적립금 내역" value={won(points.balance)} valueClass="font-bold" onClick={() => setOverlay({ kind: 'points' })} />
    </section>
  );

  const todoBar = todos.length > 0 && (
    <button
      type="button"
      onClick={() => setOverlay({ kind: 'consent' })}
      className="flex min-h-[48px] items-center gap-2.5 rounded-[14px] border-[1.5px] border-[#f0a33a] bg-white px-3.5 py-2.5 text-left"
    >
      <span aria-hidden className="flex h-[22px] w-[22px] shrink-0 items-center justify-center rounded-full bg-[#f0a33a] text-[13px] font-bold text-white">
        {todos.length}
      </span>
      <span className="flex-1 text-[14px] leading-snug">
        <b>할 일</b> · {todos.length === 1 ? todos[0].label : `${todos.length}가지 확인이 필요해요`}
      </span>
      <span className="whitespace-nowrap text-[13px] text-[#8a5300]">확인 ›</span>
    </button>
  );

  const upcoming = lessons.filter((l) => l.state === 'scheduled' && l.startsAt.getTime() > now.getTime()).sort((a, b) => a.startsAt.getTime() - b.startsAt.getTime());

  return (
    <div className="mx-auto min-h-dvh max-w-[1280px] font-sans text-[#1d1b2b] lg:flex lg:gap-6 lg:px-6 lg:py-6">
      <nav aria-label="메뉴" className="hidden w-[220px] shrink-0 flex-col gap-1 lg:flex">
        <div className="px-3 pb-4 pt-1 text-[20px] font-bold text-[#09246b]">
          Edge<span className="text-[#5b3df0]">English</span>
        </div>
        {TABS.map((t) => (
          <button
            key={t.key}
            type="button"
            onClick={() => setTab(t.key)}
            aria-current={tab === t.key ? 'page' : undefined}
            className={`flex min-h-[46px] items-center gap-2.5 rounded-[12px] px-3 text-left text-[15px] ${tab === t.key ? 'bg-[#efeaff] font-bold text-[#3a22b0]' : ''}`}
          >
            <Icon d={t.icon} />
            {t.label}
          </button>
        ))}
        <span className="px-3 pt-5 text-[13px] text-[#55526a]">{s.name} 님</span>
      </nav>

      <div className="min-w-0 flex-1 pb-24 lg:pb-0">
        <header className="flex items-center justify-between px-5 pb-3 pt-[18px] lg:hidden">
          <span className="text-[17px] font-bold text-[#09246b]">
            Edge<span className="text-[#5b3df0]">English</span>
          </span>
          <span className="text-[13px] text-[#55526a]">{s.name} 님</span>
        </header>

        {preview && (
          <div className="mx-4 mb-3 grid gap-2 rounded-[12px] bg-[#fff8d6] px-3 py-2.5 text-[12.5px] text-[#5c4a00] lg:mx-0">
            <p>가상 데이터 미리보기예요. 눌러도 실제로 저장·발송되지 않아요. 아래에서 상태를 바꿔 볼 수 있어요.</p>
            <div className="flex flex-wrap gap-1.5">
              <PreviewChip on={consents.length > 0} onClick={() => setConsents(consents.length ? [] : initial.pendingConsents)}>
                할 일 {consents.length ? '있음' : '없음'}
              </PreviewChip>
              {(['not_requested', 'requested', 'payment_confirmed'] as const).map((r) => (
                <PreviewChip key={r} on={renewal === r} onClick={() => setRenewal(r)}>
                  재등록 {r === 'not_requested' ? '미신청' : r === 'requested' ? '신청함' : '결제 확인'}
                </PreviewChip>
              ))}
              <PreviewChip on={false} onClick={() => {
                  setLessons(initial.lessons);
                  setCreditsLeft(initial.creditsLeft);
                  setMakeupsOwed(initial.makeupsOwed);
                }}>
                수업 되돌리기
              </PreviewChip>
            </div>
          </div>
        )}

        {tab === 'home' && (
          <div className="grid gap-3.5 px-4 lg:grid-cols-[minmax(0,1fr)_340px] lg:items-start lg:gap-5 lg:px-0">
            <div className="grid min-w-0 gap-3.5">
              {todoBar}
              {nextCard}
              {renewalCard}
              <div className="lg:hidden">{statusTiles}</div>
              {actions}
              {requestList}
              <div className="lg:hidden">{payBox}</div>
            </div>
            <aside className="hidden gap-4 lg:grid">
              {statusTiles}
              {payBox}
            </aside>
          </div>
        )}

        {tab === 'schedule' && (
          <TabPage title="일정">
            <p className="text-[13px] text-[#55526a]">한국 시간 기준이에요.</p>
            {upcoming.map((l) => (
              <div key={l.id} className={`${card} flex items-center justify-between gap-3 p-4`}>
                <div>
                  <p className="text-[15px] font-semibold">
                    {kst(l.startsAt).md} ({kst(l.startsAt).wd}) {kst(l.startsAt).time}
                  </p>
                  <p className="text-[12.5px] text-[#6b6880]">
                    {l.minutes}분 · {l.tutorName} · {l.kind === 'regular' ? '정규' : l.kind === 'makeup' ? '보강' : '보상'}
                  </p>
                </div>
                <button type="button" onClick={() => setOverlay({ kind: 'cancel', lessonId: l.id })} className="min-h-[44px] rounded-[12px] border border-[#d9d5e8] px-3 text-[14px] font-semibold">
                  변경·취소
                </button>
              </div>
            ))}
            <h2 className="pt-2 text-[14px] font-bold text-[#55526a]">지난 수업</h2>
            {lessons
              .filter((l) => l.state !== 'scheduled' || l.startsAt.getTime() <= now.getTime())
              .sort((a, b) => b.startsAt.getTime() - a.startsAt.getTime())
              .map((l) => (
                <div key={l.id} className="flex justify-between border-b border-[#eeecf4] px-1 py-2.5 text-[14px]">
                  <span>
                    {kst(l.startsAt).md} ({kst(l.startsAt).wd}) {kst(l.startsAt).time}
                  </span>
                  <span className="text-[#6b6880]">{l.state === 'done' ? '진행' : l.state === 'canceled' ? '취소' : '진행 중'}</span>
                </div>
              ))}
          </TabPage>
        )}

        {tab === 'requests' && (
          <TabPage title="신청 내역">
            <section className={`${card} grid gap-1 p-4`}>
              {s.requests.map((r) => (
                <RequestRow key={r.id} r={r} onOpen={() => setOverlay({ kind: 'request', id: r.id })} />
              ))}
            </section>
            <h2 className="pt-2 text-[14px] font-bold text-[#55526a]">새로 신청하기</h2>
            <section className={`${card} px-4`}>
              {['보강 신청', '고정 요일·시간 변경', '강사·교재 변경 요청', ...(s.product.includes('24주') ? ['장기 연기 신청'] : [])].map((t) => (
                <button key={t} type="button" onClick={() => say(`'${t}' 화면은 다음 단계에서 연결해요.`)} className="flex min-h-[52px] w-full items-center justify-between border-b border-[#eeecf4] text-left text-[15px] last:border-0">
                  {t} <span className="text-[#8b88a0]">›</span>
                </button>
              ))}
            </section>
          </TabPage>
        )}

        {tab === 'materials' && (
          <TabPage title="학습자료">
            <section className={`${card} grid gap-3 p-4`}>
              <p className="text-[13px] font-bold text-[#5b3df0]">지금 수업 교재</p>
              <p className="text-[17px] font-bold">{s.textbook.title}</p>
              <p className="text-[13px] text-[#55526a]">
                {book ? `${book.category} · ${book.level.join('·')}` : ''} · 지난 수업 Unit {s.textbook.lastUnit}
              </p>
              <div className="grid grid-cols-2 gap-2">
                {book?.pdf && (
                  <a href={book.pdf} target="_blank" rel="noreferrer" className="flex min-h-[46px] items-center justify-center rounded-[12px] bg-[#5b3df0] text-[14px] font-bold text-white">
                    미리보기 열기
                  </a>
                )}
                {book?.buyLink && (
                  <a href={book.buyLink} target="_blank" rel="noreferrer" className="flex min-h-[46px] items-center justify-center rounded-[12px] border border-[#d9d5e8] text-[14px] font-semibold">
                    교재 구매
                  </a>
                )}
              </div>
              <p className="text-[12px] leading-relaxed text-[#55526a]">출판사 교재는 저작권 때문에 미리보기·구매 링크로 열려요.</p>
            </section>
            <a href="/books" className={`${card} flex min-h-[52px] items-center justify-between px-4 text-[15px] font-semibold`}>
              전체 교재 둘러보기 (홈페이지 교재 소개) <span className="text-[#8b88a0]">›</span>
            </a>
            <p className="px-1 text-[12.5px] text-[#55526a]">수업 노트·수업 기록·받은 자료는 다음 단계에서 연결해요.</p>
          </TabPage>
        )}

        {tab === 'me' && (
          <TabPage title="내 정보">
            <section className={`${card} px-4 pb-1.5 pt-2`}>
              <LinkRow label="결제 내역" value="" onClick={() => setOverlay({ kind: 'payments' })} />
              <LinkRow label="적립금 내역" value={won(points.balance)} onClick={() => setOverlay({ kind: 'points' })} />
              <LinkRow label="알림 설정 (보강 리마인더)" value="" onClick={() => say('알림 설정은 다음 단계에서 연결해요.')} />
              <LinkRow label="동의한 수업 안내" value="" onClick={() => say('동의 기록 화면은 다음 단계에서 연결해요.')} />
            </section>
          </TabPage>
        )}
      </div>

      <nav aria-label="아래 메뉴" className="fixed inset-x-0 bottom-0 z-10 grid grid-cols-5 border-t border-[#e6e3ef] bg-white pb-3 pt-1.5 lg:hidden">
        {TABS.map((t) => (
          <button
            key={t.key}
            type="button"
            onClick={() => setTab(t.key)}
            aria-current={tab === t.key ? 'page' : undefined}
            className={`flex min-h-[48px] flex-col items-center justify-center gap-0.5 text-[11px] ${tab === t.key ? 'font-bold text-[#5b3df0]' : 'text-[#55526a]'}`}
          >
            <Icon d={t.icon} />
            {t.label}
          </button>
        ))}
      </nav>

      {overlay && (
        <Sheet onClose={() => setOverlay(null)}>
          {overlay.kind === 'request' && <RequestDetail r={s.requests.find((r) => r.id === overlay.id)!} />}
          {overlay.kind === 'payments' && <Payments payments={s.payments} />}
          {overlay.kind === 'points' && <Points history={points} />}
          {overlay.kind === 'consent' && (
            <div className="grid gap-3">
              <h2 className="text-[18px] font-bold">새 수업 안내 확인</h2>
              <p className="text-[14px] leading-relaxed text-[#55526a]">수업 안내 확인·동의 화면은 시안(previews/consent-drafts) 확정 후 이 자리에 연결해요.</p>
              <button
                type="button"
                onClick={() => {
                  setConsents([]);
                  setOverlay(null);
                  say('동의했어요. 할 일 알림이 사라져요.');
                }}
                className="min-h-[50px] rounded-[14px] bg-[#5b3df0] text-[16px] font-bold text-white"
              >
                (미리보기) 동의 완료로 표시
              </button>
            </div>
          )}
          {overlay.kind === 'cancel' && (
            <CancelSheet
              key={overlay.lessonId ?? 'pick'}
              lessons={upcoming}
              lessonId={overlay.lessonId}
              onPick={(id) => setOverlay({ kind: 'cancel', lessonId: id })}
              now={now}
              creditsLeft={creditsLeft}
              finalEndDate={s.finalEndDate}
              regularLeft={regularLessonsLeft(lessons)}
              totalLeft={left.total}
              onConfirm={confirmCancel}
              onClose={() => setOverlay(null)}
            />
          )}
        </Sheet>
      )}

      {toast && (
        <div role="status" className="fixed inset-x-4 bottom-24 z-30 mx-auto max-w-md rounded-[12px] bg-[#1d1b2b] px-4 py-3 shadow-lg lg:bottom-6">
          <p className="text-[13.5px] text-white">{toast}</p>
          <button type="button" onClick={() => setToast(null)} className="mt-1 text-[12.5px] font-semibold text-[#c9bcff] underline">
            닫기
          </button>
        </div>
      )}
    </div>
  );
}

function NextLesson({ lesson, now, textbook }: { lesson: StudentLesson; now: Date; textbook: { title: string; lastUnit: number } }) {
  const k = kst(lesson.startsAt);
  const days = diffDays(formatInZone(now, 'Asia/Seoul').date, k.date);
  const started = now.getTime() >= lesson.startsAt.getTime();
  const hours = hoursBetween(now, lesson.startsAt);
  const badge = started ? '진행 중' : hours < 24 ? `${Math.max(1, Math.round(hours))}시간 후` : days === 1 ? '내일' : `${days}일 후`;
  // 강사 미입장 신고: 시작 5분 뒤부터 (기능 위치 시안)
  const canReportNoShow = now.getTime() >= lesson.startsAt.getTime() + 5 * 60_000;
  return (
    <section aria-label="다음 수업" className="grid gap-3.5 rounded-[20px] bg-[#1b1442] p-5 text-white lg:rounded-[22px] lg:p-6">
      <div className="flex items-center justify-between">
        <span className="text-[13px] font-semibold text-[#c9c0ff]">다음 수업</span>
        <span className="rounded-full bg-[#ffd66b] px-2.5 py-1 text-[12px] font-semibold text-[#1b1442]">{badge}</span>
      </div>
      <div>
        <p className="text-[26px] font-bold tracking-tight text-white lg:text-[30px]">
          {Number(k.md.split('/')[0])}월 {Number(k.md.split('/')[1])}일 ({k.wd}) {k.time}
        </p>
        <p className="mt-1 text-[14px] text-[#d8d3f5]">
          {lesson.minutes}분 · {lesson.tutorName} · 한국 시간{lesson.kind === 'makeup' ? ' · 보강' : ''}
        </p>
      </div>
      <div className="grid gap-2.5 lg:grid-cols-2">
        <a href="/books" className="flex min-h-[44px] items-center justify-between gap-2.5 rounded-[12px] bg-[#2c2263] px-3.5 py-3 text-[14px] lg:order-2">
          <span className="flex items-center gap-2.5">
            <Icon d={TABS[3].icon} className="h-[18px] w-[18px] text-[#c9c0ff]" />
            <span className="text-white">
              교재 <b className="text-white">{textbook.title}</b> · Unit {textbook.lastUnit}
            </span>
          </span>
          <span className="whitespace-nowrap text-[13px] text-[#c9c0ff]">보기 ›</span>
        </a>
        <span
          aria-disabled
          title="Google Meet 주소는 실제 데이터 연결 후 표시"
          className="flex min-h-[50px] items-center justify-center gap-2 rounded-[14px] bg-white text-[16px] font-bold text-[#1b1442] lg:order-1"
        >
          <Icon d="M4 6h10a2 2 0 0 1 2 2v8a2 2 0 0 1-2 2H4a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2zM16 10l6-3v10l-6-3z" />
          수업 입장 (Google Meet)
        </span>
      </div>
      {canReportNoShow && (
        <button type="button" className="min-h-[44px] rounded-[12px] border border-[#6e62b8] text-[14px] font-semibold text-white">
          강사가 아직 안 들어왔어요
        </button>
      )}
    </section>
  );
}

function Tile({ label, value, unit, sub }: { label: string; value: string; unit?: string; sub: string }) {
  return (
    <div className={`${card} p-3 lg:p-4`}>
      <p className="text-[12px] text-[#55526a]">{label}</p>
      <p className="mt-1 text-[22px] font-bold">
        {value}
        {unit && <span className="text-[13px] font-medium">{unit}</span>}
      </p>
      <p className="text-[11px] text-[#6b6880]">{sub}</p>
    </div>
  );
}

function RequestRow({ r, onOpen }: { r: StudentRequest; onOpen: () => void }) {
  return (
    <button type="button" onClick={onOpen} className="flex min-h-[56px] w-full items-center justify-between gap-2 border-b border-[#eeecf4] py-2 text-left last:border-0">
      <span>
        <span className="block text-[14px] font-semibold">{r.title}</span>
        <span className="block text-[12px] text-[#6b6880]">{r.kind === 'makeup' ? `내가 고른 후보 ${r.candidates.length}개 · 누르면 날짜 보기` : r.note}</span>
      </span>
      <span className="flex items-center gap-1.5">
        <span className={`whitespace-nowrap rounded-full px-2.5 py-1 text-[12px] font-semibold ${STATUS_STYLE[r.status]}`}>{REQUEST_STATUS_LABEL[r.status]}</span>
        <span className="text-[#8b88a0]">›</span>
      </span>
    </button>
  );
}

function LinkRow({ label, value, valueClass = 'font-semibold', onClick }: { label: string; value: string; valueClass?: string; onClick: () => void }) {
  return (
    <button type="button" onClick={onClick} className="flex min-h-[52px] w-full items-center justify-between border-t border-[#eeecf4] text-left text-[14px] first:border-0">
      <span className="text-[#55526a]">{label}</span>
      <span className={valueClass}>
        {value} <span className="font-normal text-[#8b88a0]">›</span>
      </span>
    </button>
  );
}

function PreviewChip({ on, onClick, children }: { on: boolean; onClick: () => void; children: React.ReactNode }) {
  return (
    <button type="button" onClick={onClick} className={`min-h-[32px] rounded-full border px-2.5 text-[12px] font-semibold ${on ? 'border-[#5c4a00] bg-[#5c4a00] text-white' : 'border-[#e0cf8a] bg-white'}`}>
      {children}
    </button>
  );
}

function TabPage({ title, children }: { title: string; children: React.ReactNode }) {
  return (
    <div className="grid gap-3 px-4 lg:max-w-[720px] lg:px-0">
      <h1 className="text-[22px] font-bold">{title}</h1>
      {children}
    </div>
  );
}

function Sheet({ onClose, children }: { onClose: () => void; children: React.ReactNode }) {
  return (
    <div className="fixed inset-0 z-20 flex items-end justify-center bg-black/40 lg:items-center" onClick={onClose}>
      <div role="dialog" aria-modal className="max-h-[90dvh] w-full max-w-[520px] overflow-y-auto rounded-t-[22px] bg-[#f6f5fa] p-5 lg:rounded-[22px]" onClick={(e) => e.stopPropagation()}>
        <button type="button" onClick={onClose} className="mb-2 min-h-[36px] text-[14px] text-[#55526a]">
          ‹ 닫기
        </button>
        {children}
      </div>
    </div>
  );
}

function RequestDetail({ r }: { r: StudentRequest }) {
  const steps = ['신청', r.status === 'admin_reviewing' ? '운영자 확인' : '강사 확인', '확정'];
  const at = r.status === 'tutor_reviewing' || r.status === 'admin_reviewing' ? 1 : 2;
  const c = kst(r.createdAt);
  return (
    <div className="grid gap-3.5">
      <h2 className="text-[18px] font-bold">{r.title}</h2>
      <section className={`${card} grid gap-3.5 p-4`}>
        <div className="flex items-center justify-between">
          <span className="text-[13px] text-[#55526a]">지금 상태</span>
          <span className={`rounded-full px-3 py-1 text-[13px] font-semibold ${STATUS_STYLE[r.status]}`}>{REQUEST_STATUS_LABEL[r.status]}</span>
        </div>
        {at === 1 && (
          <p className="text-[14px] leading-relaxed">
            {r.status === 'tutor_reviewing' ? '강사가 아래 후보 중 하나를 고르면' : '운영자가 확인하면'} <b>이메일로 알려 드려요.</b> 지금 학생이 할 일은 없어요.
          </p>
        )}
        <ol className="flex gap-1.5">
          {steps.map((t, i) => (
            <li key={t} className="flex-1 text-center">
              <div className={`h-1.5 rounded ${i < at ? 'bg-[#5b3df0]' : i === at && at < 2 ? 'bg-[#f0a33a]' : i <= at ? 'bg-[#5b3df0]' : 'bg-[#e6e3ef]'}`} />
              <span className={`mt-1.5 block text-[12px] ${i <= at ? 'font-semibold' : 'text-[#8b88a0]'}`}>{t}</span>
            </li>
          ))}
        </ol>
      </section>
      {r.candidates.length > 0 && (
        <section className={`${card} grid gap-2.5 p-4`}>
          <h3 className="text-[15px] font-bold">내가 고른 보강 후보</h3>
          {r.candidates.map((d, i) => {
            const k = kst(d);
            return (
              <div key={i} className="flex items-center gap-3 rounded-[12px] border border-[#e6e3ef] px-3.5 py-3">
                <span className="text-[12px] font-bold text-[#5b3df0]">후보 {i + 1}</span>
                <span className="text-[16px] font-bold">
                  {k.md} ({k.wd}) {k.time}
                </span>
              </div>
            );
          })}
          <p className="text-[12px] text-[#55526a]">한국 시간</p>
        </section>
      )}
      <section className={`${card} grid gap-2 p-4 text-[14px]`}>
        <div className="flex justify-between">
          <span className="text-[#55526a]">내용</span>
          <span>{r.note}</span>
        </div>
        <div className="flex justify-between">
          <span className="text-[#55526a]">신청한 날</span>
          <span>
            {c.md} ({c.wd}) {c.time}
          </span>
        </div>
      </section>
    </div>
  );
}

function Payments({ payments }: { payments: ReturnType<typeof fakeStudent>['payments'] }) {
  // 금액·카드 정보는 보여 주지 않음 (POL-PAY-11). 카드 영수증은 아임웹 주문조회로
  return (
    <div className="grid gap-3.5">
      <h2 className="text-[18px] font-bold">결제 내역</h2>
      {payments.map((p) => (
        <section key={p.id} className={`${card} grid gap-2.5 p-4 text-[14px]`}>
          <div className="flex items-center justify-between">
            <h3 className="text-[15px] font-bold">{p.current ? '지금 수강권' : '지난 수강권'}</h3>
            <span className={`rounded-full px-2.5 py-1 text-[12px] font-semibold ${p.confirmedOn ? 'bg-[#e3f5ea] text-[#13623a]' : 'bg-[#fff1d6] text-[#8a5300]'}`}>
              {p.confirmedOn ? '결제 확인 완료' : '결제 확인 중'}
            </span>
          </div>
          <Row k="수강권" v={p.product} />
          <Row k="수강 기간" v={`${fmtDate(p.periodStart)} ~ ${fmtDate(p.periodEnd)}`} />
          <Row k="결제 방법" v={PAYMENT_METHOD_LABEL[p.method]} />
          <Row k="확인한 날" v={p.confirmedOn ? `${fmtDate(p.confirmedOn)} · 운영자 확인` : '-'} />
          {p.method === 'card_imweb' && (
            <span aria-disabled title="아임웹 주문조회 주소 확인 후 연결" className="mt-1 flex min-h-[46px] items-center justify-center rounded-[12px] border border-[#d9d5e8] text-[14px] font-semibold text-[#55526a]">
              카드 영수증 · 주문 보기 (아임웹) ↗
            </span>
          )}
        </section>
      ))}
      <p className="text-[12px] leading-relaxed text-[#55526a]">결제 금액·카드 정보는 이 화면에 따로 표시하지 않아요 (아임웹 주문조회에서 확인). 결제는 운영자가 직접 확인해요.</p>
    </div>
  );
}

function Points({ history }: { history: ReturnType<typeof pointsHistory> }) {
  return (
    <div className="grid gap-3.5">
      <h2 className="text-[18px] font-bold">적립금 내역</h2>
      <section className="flex items-center justify-between rounded-[18px] bg-[#1b1442] p-4 text-white">
        <div>
          <p className="text-[13px] text-[#c9c0ff]">사용할 수 있는 적립금</p>
          <p className="mt-0.5 text-[26px] font-bold text-white">{won(history.balance)}</p>
        </div>
        <p className="text-right text-[12px] leading-relaxed text-[#d8d3f5]">
          유효기간 없음
          <br />
          재등록 결제 때 사용
        </p>
      </section>
      <section className={`${card} px-4`}>
        {history.rows.map((r) => (
          <div key={r.id} className="grid grid-cols-[1fr_auto] gap-x-3 border-b border-[#eeecf4] py-3 last:border-0">
            <span className="text-[14px]">{r.reason}</span>
            <b className={`text-right text-[14px] ${r.signed > 0 ? 'text-[#13623a]' : ''}`}>
              {r.signed > 0 ? '+' : '−'}
              {won(Math.abs(r.signed))}
            </b>
            <span className="text-[12px] text-[#6b6880]">{fmtDate(r.on)}</span>
            <span className="text-right text-[12px] text-[#6b6880]">잔액 {won(r.balanceAfter)}</span>
          </div>
        ))}
      </section>
      <p className="text-[12px] leading-relaxed text-[#55526a]">사용 신청은 재등록할 때 해요. 결제가 취소·환불되면 사용한 적립금은 다시 돌아와요.</p>
    </div>
  );
}

function Row({ k, v }: { k: string; v: string }) {
  return (
    <div className="flex justify-between gap-3">
      <span className="text-[#55526a]">{k}</span>
      <span className="text-right">{v}</span>
    </div>
  );
}

function CancelSheet(props: {
  lessons: StudentLesson[];
  lessonId: string | null;
  onPick: (id: string) => void;
  now: Date;
  creditsLeft: number;
  finalEndDate: KstDate;
  regularLeft: number;
  totalLeft: number;
  onConfirm: (l: StudentLesson) => void;
  onClose: () => void;
}) {
  const [checked, setChecked] = useState(false);
  const lesson = props.lessons.find((l) => l.id === props.lessonId);

  if (!lesson) {
    return (
      <div className="grid gap-3">
        <h2 className="text-[18px] font-bold">어느 수업을 바꿀까요?</h2>
        {props.lessons.map((l) => {
          const k = kst(l.startsAt);
          const h = hoursBetween(props.now, l.startsAt);
          return (
            <button key={l.id} type="button" onClick={() => props.onPick(l.id)} className={`${card} flex min-h-[56px] items-center justify-between px-4 text-left`}>
              <span className="text-[15px] font-semibold">
                {k.md} ({k.wd}) {k.time}
              </span>
              <span className="text-[12.5px] text-[#6b6880]">{h < 6 ? '6시간 이내' : h < 24 ? `${Math.floor(h)}시간 후` : `${Math.floor(h / 24)}일 후`} ›</span>
            </button>
          );
        })}
      </div>
    );
  }

  const d = cancelPreview({ lesson, now: props.now, finalEndDate: props.finalEndDate, creditsLeft: props.creditsLeft, holidays: new Set() }, null);
  const k = kst(lesson.startsAt);
  const title = `${k.md} (${k.wd}) ${k.time} 수업을 취소할까요?`;

  if (!d.ok) {
    const msg =
      d.reason === 'policy_pending' ? '보상 수업 취소 규칙이 아직 정해지지 않았어요. 카카오톡으로 문의해 주세요.' : d.reason === 'already_started' ? '이미 시작한 수업은 취소할 수 없어요.' : '수강기간이 지난 수업이에요.';
    return (
      <div className="grid gap-3">
        <h2 className="text-[18px] font-bold">{title}</h2>
        <p className="text-[14px]">{msg}</p>
      </div>
    );
  }

  const hours = hoursBetween(props.now, lesson.startsAt);
  const needsCheck = d.consumesLesson; // 수업이 차감되면 한 번 더 확인
  const rows: [string, string][] = [
    ['수업 횟수', d.consumesLesson ? `1회 차감 (남은 ${props.totalLeft}회 → ${props.totalLeft - 1}회)` : '차감 안 됨'],
    ['보강', d.makeupAllowed ? `수강기간(~${fmtDate(props.finalEndDate)}) 안에 보강 가능` : '불가'],
    ['변경권', d.usesCredit ? `1개 사용 → 남은 ${props.creditsLeft - 1}개` : `차감 안 됨 (${props.creditsLeft}개 그대로)`],
  ];

  return (
    <div className="grid gap-3.5">
      <h2 className="text-[19px] font-bold">{d.timing === 'late' ? `수업 시작 ${hours < 1 ? '1시간 이내' : `${Math.floor(hours)}시간 전`}이에요` : title}</h2>
      <section className={`grid gap-2 rounded-[14px] p-3.5 text-[14px] leading-normal ${needsCheck ? 'border border-[#f3c2bb] bg-[#fff1ef] text-[#7a1d12]' : 'bg-[#f1eefc]'}`}>
        <p className={`font-bold ${needsCheck ? 'text-[#7a1d12]' : ''}`}>지금 취소하면</p>
        {rows.map(([a, b]) => (
          <div key={a} className="flex justify-between gap-3">
            <span className={needsCheck ? 'text-[#7a1d12]' : ''}>{a}</span>
            <b className={`text-right ${needsCheck ? 'text-[#7a1d12]' : ''}`}>{b}</b>
          </div>
        ))}
      </section>
      <p className="text-[12.5px] leading-relaxed text-[#55526a]">{d.studentMessage}</p>
      {needsCheck && (
        <label className="flex min-h-[44px] items-start gap-2.5 text-[14px] leading-normal">
          <input type="checkbox" checked={checked} onChange={(e) => setChecked(e.target.checked)} className="mt-0.5 h-5 w-5 accent-[#b3261e]" />
          수업 1회가 차감되고 보강이 없다는 것을 확인했어요
        </label>
      )}
      <button
        type="button"
        disabled={needsCheck && !checked}
        onClick={() => props.onConfirm(lesson)}
        className={`min-h-[52px] rounded-[14px] text-[16px] font-bold text-white disabled:opacity-40 ${needsCheck ? 'bg-[#b3261e]' : 'bg-[#5b3df0]'}`}
      >
        {needsCheck ? '1회 차감하고 취소' : '취소하고 보강 시간 고르기'}
      </button>
      <button type="button" onClick={props.onClose} className="min-h-[44px] text-[14px] text-[#55526a]">
        {d.timing === 'late' ? '수업 그대로 하기' : '취소 안 함'}
      </button>
    </div>
  );
}
