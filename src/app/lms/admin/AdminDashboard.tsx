'use client';

// 운영자 대시보드 A안 — 처리할 일 중심. 휴대폰: 운영 현황 → 요약 카드 → 급한 순서 목록 → 아래 탭 / PC: 왼쪽 목록 + 오른쪽 오늘 수업
// 2026-10-18 대표 반영: 운영 현황 3 + 처리할 일 요약 5(누르면 필터) + 필터(전체·긴급·오류만). 한 업무는 요약 한 칸·목록 한 줄에만 (중복 없음)
// 미리보기(preview)에서는 버튼을 눌러도 화면 안에서만 바뀌고 저장·발송하지 않는다.

import { useMemo, useState } from 'react';
import { buildBoard, CATEGORY_LABEL, categoryCounts, filterBoard, isUrgent, type BoardFilter, type BoardItem, type Category, type Severity, type TaskSource } from '@/lms/admin/board';
import { fakeTasks, type FakeLesson, type OpsStats } from '@/lms/admin/fake-data';

const TAG_STYLE: Record<Severity, string> = {
  urgent: 'bg-[#fde6e6] text-[#c62b2b]',
  overdue: 'bg-[#fde6e6] text-[#c62b2b]',
  due_soon: 'bg-[#fff1d6] text-[#a35b00]',
  open: 'bg-[#efebff] text-[#5b3fe0]',
};
const DUE_STYLE: Record<Severity, string> = {
  urgent: 'text-[#c62b2b]',
  overdue: 'text-[#c62b2b] font-bold',
  due_soon: 'text-[#a35b00] font-bold',
  open: 'text-[#6b6880]',
};
const LESSON_STYLE: Record<FakeLesson['state'], string> = {
  완료: 'bg-[#eeedf3] text-[#6b6880]',
  예정: 'bg-[#efebff] text-[#5b3fe0]',
  보강: 'bg-[#efebff] text-[#5b3fe0]',
  '노쇼 신고': 'bg-[#fde6e6] text-[#c62b2b]',
  '학생 변경': 'bg-[#fff1d6] text-[#a35b00]',
  취소: 'bg-[#eeedf3] text-[#6b6880]',
};

const WD = ['일', '월', '화', '수', '목', '금', '토'];

function applyAction(t: TaskSource, key: string, now: Date): TaskSource | null {
  switch (t.kind) {
    case 'new_student_matching': {
      const next = { ...t };
      if (key === 'assign_tutor') Object.assign(next, { tutorName: t.tutorName ?? '가상강사 Alex', tutorAssignedAt: now });
      if (key === 'notify_student') next.studentNotifiedAt = now;
      return next.tutorAssignedAt && next.studentNotifiedAt ? null : next;
    }
    case 'renewal_tutor_notice': {
      const next = { ...t };
      if (key === 'notify_tutor') next.tutorNotifiedAt = now;
      if (key === 'tutor_ack') next.tutorAcknowledgedAt = now;
      if (key === 'check_schedule') next.scheduleCheckedAt = now;
      return next.tutorNotifiedAt && next.tutorAcknowledgedAt && next.scheduleCheckedAt ? null : next;
    }
    default:
      return null; // 장기 연기 승인·거절, 노쇼 확정·지각 처리 → 목록에서 빠짐
  }
}

const DONE_MESSAGE: Record<string, string> = {
  assign_tutor: '강사를 배정했어요. 학생 안내가 남았어요.',
  notify_student: '학생 안내까지 끝나서 매칭 업무를 마쳤어요.',
  notify_tutor: '강사에게 통보했어요. 강사 확인을 기다려요.',
  remind_tutor: '강사에게 다시 알렸어요.',
  tutor_ack: '강사 확인을 기록했어요. 일정 조치가 남았어요.',
  check_schedule: '재등록 강사 확인 업무를 마쳤어요.',
  approve_leave: '장기 연기를 승인했어요. 종료일이 늘어나요.',
  renewal_contacted: '재등록 안내를 기록했어요.',
  makeup_nudged: '보강 신청 안내를 기록했어요.',
  retry_calendar: '캘린더에 다시 반영했어요.',
  fix_email: '이메일을 확인했어요.',
  check_payment: '결제를 확인했어요.',
  reject_leave: '장기 연기를 거절했어요. 학생에게 사유를 안내해 주세요.',
  tutor_arrived: '강사 지각으로 처리했어요.',
  confirm_no_show: '노쇼로 확정했어요. 보강 1회 + 보상 수업 1회가 생겨요.',
};

export default function AdminDashboard({
  nowIso,
  today,
  preview,
  tasks: liveTasks,
  stats,
  onLogout,
}: {
  nowIso: string;
  today: FakeLesson[];
  preview: boolean;
  /** 실제 데이터 (없으면 가상 데이터 미리보기) */
  tasks?: TaskSource[];
  /** 운영 현황 3개 (없으면 '—') */
  stats?: OpsStats | null;
  onLogout?: () => void;
}) {
  const now = useMemo(() => new Date(nowIso), [nowIso]);
  const [tasks, setTasks] = useState<TaskSource[]>(() => liveTasks ?? fakeTasks(now));
  const [toast, setToast] = useState<string | null>(null);
  const [doneCount, setDoneCount] = useState(0);
  const items = useMemo(() => buildBoard(tasks, now), [tasks, now]);
  const [filter, setFilter] = useState<BoardFilter>('all');
  const byCat = categoryCounts(items);
  const shown = filterBoard(items, filter);
  const urgentCount = items.filter(isUrgent).length;
  const errorCount = items.filter((i) => i.error).length;
  const dateLabel = `${now.toLocaleDateString('ko-KR', { timeZone: 'Asia/Seoul', month: 'long', day: 'numeric' })} (${WD[new Date(now.getTime() + 9 * 3600e3).getUTCDay()]})`;

  function act(item: BoardItem, key: string) {
    if (!preview) {
      // 실제 데이터: 처리(쓰기)는 서버 기능으로만 (POL-AC-07). 서버 기능을 만들기 전에는 보기만
      setToast('처리 버튼은 서버 저장 기능을 만든 뒤 연결돼요. 지금은 실제 데이터 보기만 가능해요.');
      return;
    }
    setTasks((prev) => {
      const out: TaskSource[] = [];
      for (const t of prev) {
        if (t.id !== item.id) out.push(t);
        else if (key === 'remind_tutor') out.push(t);
        else {
          const next = applyAction(t, key, new Date());
          if (next) out.push(next);
          else setDoneCount((c) => c + 1);
        }
      }
      return out;
    });
    setToast(`${DONE_MESSAGE[key] ?? '처리했어요.'}${preview ? ' (미리보기: 실제 저장·발송 없음)' : ''}`);
  }

  return (
    <div className="mx-auto min-h-dvh max-w-[1280px] pb-20 lg:pb-8">
      <header className="sticky top-0 z-10 flex items-center gap-3 border-b border-[#e6e3ef] bg-white px-4 py-3 lg:px-7">
        <span className="text-[15px] font-extrabold tracking-tight text-[#09246b]">
          Edge<span className="text-[#7d5fff]">English</span> <span className="text-[#09246b]">운영</span>
        </span>
        <span className="flex-1" />
        <span className="text-[13px] text-[#6b6880]">{dateLabel}</span>
        {onLogout && (
          <button type="button" onClick={onLogout} className="min-h-[40px] rounded-[10px] border border-[#e6e3ef] px-3 text-[13px] font-semibold text-[#1d1b2b]">
            로그아웃
          </button>
        )}
        <button
          type="button"
          disabled
          title="신규 학생 등록 화면은 시안 선택 후 개발"
          className="hidden min-h-[40px] cursor-not-allowed rounded-[10px] bg-[#7d5fff]/50 px-3 text-[13px] font-semibold text-white lg:block"
        >
          + 학생 등록 (준비 중)
        </button>
      </header>

      {!preview && (
        <p className="mx-4 mt-3 rounded-[10px] bg-[#e3f5ea] px-3 py-2 text-[13px] text-[#13623a] lg:mx-7">
          시험용 DB의 실제 데이터예요 (가상 학생). 지금은 보기만 되고, 처리 버튼은 서버 저장 기능을 만든 뒤 연결돼요.
        </p>
      )}
      {preview && (
        <p className="mx-4 mt-3 rounded-[10px] bg-[#fff8d6] px-3 py-2 text-[13px] text-[#5c4a00] lg:mx-7">
          가상 데이터 미리보기예요. 버튼을 눌러도 실제로 저장되거나 학생·강사에게 발송되지 않아요. (실제 데이터: 로그인 후 /lms/admin)
        </p>
      )}

      <div className="grid gap-4 px-4 pt-3 lg:grid-cols-[minmax(0,1fr)_360px] lg:items-start lg:gap-5 lg:px-7 lg:pt-5">
        <section aria-label="운영 현황" className="grid grid-cols-3 gap-2 lg:col-span-2">
          {[
            ['수강 중 학생', stats ? `${stats.activeStudents}명` : '—', ''],
            ['이번 주 수업', stats ? `${stats.weekLessons.done} / ${stats.weekLessons.total}` : '—', '진행 / 전체'],
            ['이번 달 등록', stats ? `${stats.monthEnrollments.fresh + stats.monthEnrollments.renewal}건` : '—', stats ? `신규 ${stats.monthEnrollments.fresh} · 재등록 ${stats.monthEnrollments.renewal}` : ''],
          ].map(([label, v, sub]) => (
            <div key={label} className="rounded-[14px] bg-[#f1eefc] px-3 py-2.5">
              <span className="block text-[12px] text-[#6b6880]">{label}</span>
              <b className="block text-[18px] tabular-nums text-[#1d1b2b] lg:text-[20px]">{v}</b>
              {sub && <span className="block text-[11.5px] text-[#6b6880]">{sub}</span>}
            </div>
          ))}
        </section>

        <section aria-label="처리할 일 요약" className="grid grid-cols-2 gap-2 sm:grid-cols-3 lg:col-span-2 lg:grid-cols-5">
          {(Object.keys(CATEGORY_LABEL) as Category[]).map((c) => {
            const { n, urgent } = byCat[c];
            const on = filter === c;
            return (
              <button
                key={c}
                type="button"
                aria-pressed={on}
                onClick={() => setFilter(on ? 'all' : c)}
                className={`rounded-[14px] border bg-white px-3 py-2.5 text-left ${on ? 'border-[#7d5fff] shadow-[0_0_0_2px_#e4ddff]' : 'border-[#e6e3ef]'}`}
              >
                <span className="block text-[12.5px] text-[#6b6880]">{CATEGORY_LABEL[c]}</span>
                <b className={`block text-[22px] tabular-nums ${n === 0 ? 'text-[#b9b6c8]' : urgent ? 'text-[#c62b2b]' : 'text-[#1d1b2b]'}`}>{n}</b>
                <span className={`block text-[11.5px] ${urgent ? 'font-semibold text-[#c62b2b]' : 'text-[#b9b6c8]'}`}>{urgent ? `긴급 ${urgent}` : n ? '여유' : '없음'}</span>
              </button>
            );
          })}
        </section>

        <section aria-label="처리할 일" className="grid min-w-0 gap-2.5">
          <div className="flex flex-wrap items-center justify-between gap-2">
            <h2 className="text-[12px] font-extrabold tracking-wider text-[#6b6880]">
              {filter === 'all' || filter === 'urgent' || filter === 'error' ? '지금 처리할 일 · 급한 순서' : `${CATEGORY_LABEL[filter]} · 급한 순서`}
            </h2>
            <div role="group" aria-label="필터" className="flex gap-1.5">
              {([
                ['all', `전체 ${items.length}`],
                ['urgent', `긴급 ${urgentCount}`],
                ['error', `오류만 ${errorCount}`],
              ] as const).map(([f, label]) => (
                <button
                  key={f}
                  type="button"
                  aria-pressed={filter === f}
                  onClick={() => setFilter(f)}
                  className={`min-h-[34px] rounded-full border px-3 text-[12.5px] font-semibold ${
                    filter === f ? 'border-[#1d1b2b] bg-[#1d1b2b] text-white' : 'border-[#e6e3ef] bg-white text-[#1d1b2b]'
                  }`}
                >
                  {label}
                </button>
              ))}
            </div>
          </div>
          {items.length > 0 && shown.length === 0 && (
            <p className="rounded-[14px] border border-[#e6e3ef] bg-white px-4 py-6 text-center text-[13px] text-[#6b6880]">이 조건에 맞는 일이 없어요.</p>
          )}
          {items.length === 0 && (
            <div className="rounded-[14px] border border-[#e6e3ef] bg-white px-4 py-8 text-center">
              <p className="text-[15px] font-bold text-[#13804b]">처리할 일이 없어요</p>
              <p className="mt-1 text-[13px] text-[#6b6880]">오늘 {doneCount}건을 마쳤어요.</p>
            </div>
          )}
          {shown.map((item) => (
            <article key={item.id} className="grid gap-2 rounded-[14px] border border-[#e6e3ef] bg-white px-3.5 py-3">
              <div className="flex flex-wrap items-center gap-2">
                <span className={`rounded-full px-2 py-0.5 text-[12px] font-bold ${TAG_STYLE[item.severity]}`}>
                  {item.severity === 'overdue' && !item.error ? `${item.tag} · 기한 초과` : item.tag}
                </span>
                <h3 className="text-[15px] font-bold text-[#1d1b2b]">{item.title}</h3>
              </div>
              <p className="text-[12.5px] text-[#6b6880]">{item.detail}</p>
              {item.due && <p className={`text-[13px] ${DUE_STYLE[item.severity]}`}>{item.due}</p>}
              {item.steps.length > 0 && (
                <ul className="flex flex-wrap gap-x-3 gap-y-1">
                  {item.steps.map((s) => (
                    <li key={s.key} className={`text-[13px] ${s.done ? 'text-[#13804b]' : 'text-[#6b6880]'}`}>
                      <span aria-hidden className={s.done ? 'text-[#13804b]' : 'text-[#b9b6c8]'}>
                        {s.done ? '✓' : '○'}
                      </span>{' '}
                      {s.label}
                      <span className="sr-only">{s.done ? ' (완료)' : ' (남음)'}</span>
                    </li>
                  ))}
                </ul>
              )}
              <div className="flex flex-wrap gap-1.5">
                {item.actions.map((a) => (
                  <button
                    key={a.key}
                    type="button"
                    onClick={() => act(item, a.key)}
                    className={`min-h-[40px] rounded-[10px] border px-3 text-[13.5px] font-semibold ${
                      a.danger
                        ? 'border-[#c62b2b] bg-[#c62b2b] text-white'
                        : a.primary
                          ? 'border-[#7d5fff] bg-[#7d5fff] text-white'
                          : 'border-[#e6e3ef] bg-white text-[#1d1b2b]'
                    }`}
                  >
                    {a.label}
                  </button>
                ))}
              </div>
            </article>
          ))}
        </section>

        <aside aria-label="오늘 수업" className="hidden rounded-[14px] border border-[#e6e3ef] bg-white px-4 py-3.5 lg:block">
          <h2 className="text-[12px] font-extrabold tracking-wider text-[#6b6880]">오늘 수업</h2>
          {today.length === 0 && <p className="py-3 text-[13px] text-[#6b6880]">오늘 수업이 없어요.</p>}
          <ul>
            {today.map((l, i) => (
              <li key={i} className="grid grid-cols-[52px_1fr_auto] items-center gap-2 border-b border-[#e6e3ef] py-2 last:border-0">
                <span className="text-[13px] tabular-nums text-[#6b6880]">{l.time}</span>
                <span className="text-[14px] text-[#1d1b2b]">
                  {l.student} · {l.tutor}
                </span>
                <span className={`rounded-full px-2 py-0.5 text-[12px] font-bold ${LESSON_STYLE[l.state]}`}>{l.state}</span>
              </li>
            ))}
          </ul>
        </aside>
      </div>

      {toast && (
        <div role="status" className="fixed inset-x-4 bottom-20 z-20 mx-auto max-w-md rounded-[12px] bg-[#1d1b2b] px-4 py-3 shadow-lg lg:bottom-6">
          <p className="text-[13.5px] text-white">{toast}</p>
          <button type="button" onClick={() => setToast(null)} className="mt-1 text-[12.5px] font-semibold text-[#c9bcff] underline">
            닫기
          </button>
        </div>
      )}

      <nav aria-label="메뉴" className="fixed inset-x-0 bottom-0 grid grid-cols-4 border-t border-[#e6e3ef] bg-white lg:hidden">
        {['홈', '학생', '일정', '더보기'].map((t, i) => (
          <span key={t} className={`py-2.5 text-center text-[12px] font-semibold ${i === 0 ? 'text-[#7d5fff]' : 'text-[#b9b6c8]'}`}>
            {t}
            {i > 0 && <span className="block text-[10px] text-[#b9b6c8]">준비 중</span>}
          </span>
        ))}
      </nav>
    </div>
  );
}
