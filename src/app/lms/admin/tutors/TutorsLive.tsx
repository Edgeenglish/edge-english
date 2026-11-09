'use client';

// 강사 관리 (대시보드 5차): 목록(이름·도시·담당 학생 수, 검색) → 상세(시간대·담당 학생·다가오는 수업·[강사 화면 열기])
// 담당 학생 = 지금 이어지는 정규 일정 기준. 체험용 강사·학생은 '체험용' 표시
import Link from 'next/link';
import { useEffect, useState } from 'react';
import { loadTutors, loadTutorUpcoming } from '@/lms/admin/dashboard-live';
import { mdw, type LessonItem, type TutorItem } from '@/lms/admin/dashboard';
import { koZoneCity } from '@/lms/admin/places';
import { AdminHeader, BottomNav, Icon } from '../ui';
import { useAdminSb } from '../useAdmin';
import { LessonRows } from '../LessonRows';

const box = 'min-w-0 rounded-[14px] border border-[#e6e3ef] bg-white px-4 py-3';
const trialTag = <span className="ml-1 text-[12px] font-normal text-[#6b6880]">체험용</span>;
const studentHref = (code: string) => `/lms/admin/students/${encodeURIComponent(code)}`;

export default function TutorsLive({ tutorId }: { tutorId: string | null }) {
  const { sb, error } = useAdminSb();
  const [tutors, setTutors] = useState<TutorItem[] | null>(null);
  const [upcoming, setUpcoming] = useState<LessonItem[] | null>(null);
  const [err, setErr] = useState<string | null>(null);
  const [q, setQ] = useState('');

  useEffect(() => {
    if (!sb) return;
    loadTutors(sb, new Date()).then(setTutors).catch((e) => setErr(e instanceof Error ? e.message : '강사 정보를 읽지 못했어요.'));
  }, [sb]);
  useEffect(() => {
    if (!sb || !tutorId) return;
    setUpcoming(null);
    loadTutorUpcoming(sb, tutorId, new Date()).then(setUpcoming).catch(() => setUpcoming([]));
  }, [sb, tutorId]);

  const t = tutorId ? tutors?.find((x) => x.id === tutorId) : null;
  const k = q.trim().toLowerCase();
  const list = (tutors ?? []).filter((x) => !k || x.name.toLowerCase().includes(k));

  return (
    <div className="mx-auto min-h-dvh max-w-[1280px] pb-24 lg:pb-8">
      <AdminHeader active="home" demo={false} />
      <div className="grid gap-3 px-4 pt-3 lg:max-w-[760px] lg:px-7 lg:pt-5">
        <Link href={tutorId ? '/lms/admin/tutors' : '/lms/admin'} className="min-h-[32px] w-fit text-[13.5px] font-semibold text-[#5b3fe0]">← {tutorId ? '강사 관리' : '홈'}</Link>
        {(error || err) && <p className="text-[13px] text-[#c62b2b]">{error ?? err}</p>}
        {!tutors && !error && !err && <p className="py-10 text-center text-[14px] text-[#6b6880]">불러오는 중…</p>}

        {tutors && !tutorId && (
          <section aria-label="강사 관리" className={box}>
            <h1 className="mb-2 text-[15px] font-bold text-[#1d1b2b]">강사 관리</h1>
            <label className="mb-1 flex min-h-[40px] items-center gap-2 rounded-[10px] border border-[#e6e3ef] px-2.5">
              <Icon name="search" className="h-4 w-4 text-[#6b6880]" />
              <span className="sr-only">강사 찾기</span>
              <input type="search" value={q} onChange={(e) => setQ(e.target.value)} placeholder="강사 이름" className="min-w-0 flex-1 bg-transparent text-[16px] outline-none lg:text-[14px]" />
            </label>
            {list.length === 0 && <p className="py-4 text-center text-[13px] text-[#6b6880]">찾는 강사가 없어요.</p>}
            <ul>
              {list.map((x) => (
                <li key={x.id} className="border-b border-[#e6e3ef] last:border-0">
                  <Link href={`/lms/admin/tutors?t=${x.id}`} className="grid grid-cols-[minmax(0,1fr)_auto] items-center gap-x-2.5 px-0.5 py-2.5 hover:bg-[#f4f2fa]">
                    <span className="font-semibold text-[#1d1b2b]">{x.name}{x.trial && trialTag}</span>
                    <span aria-hidden className="row-span-2 font-bold text-[#6b6880]">›</span>
                    <span className="text-[12.5px] text-[#6b6880]">{koZoneCity(x.timezone)} · 담당 학생 {x.students.length}명</span>
                  </Link>
                </li>
              ))}
            </ul>
          </section>
        )}

        {tutors && tutorId && !t && <p className="py-6 text-center text-[14px] text-[#6b6880]">강사를 찾지 못했어요.</p>}
        {t && (
          <section aria-label={`${t.name} 강사`} className={box}>
            <div className="mb-2 flex flex-wrap items-center gap-2">
              <h1 className="text-[16px] font-bold text-[#1d1b2b]">{t.name}{t.trial && trialTag}</h1>
              <Link href={`/lms/tutor?tutor=${t.id}`} className="ml-auto inline-flex min-h-[36px] items-center rounded-[10px] bg-[#7d5ffb] px-3 text-[13px] font-semibold text-white">강사 화면 열기</Link>
            </div>
            <dl className="grid grid-cols-[88px_1fr] gap-x-2.5 gap-y-1.5 text-[13.5px]">
              <dt className="text-[#6b6880]">시간대</dt>
              <dd>{koZoneCity(t.timezone)} ({t.timezone})</dd>
              <dt className="text-[#6b6880]">담당 학생</dt>
              <dd className="flex flex-wrap gap-x-2 gap-y-1">
                {t.students.length === 0 ? '없음' : t.students.map((s) => (
                  <Link key={s.code} href={studentHref(s.code)} className="font-semibold text-[#5b3fe0]">{s.name} <span className="font-normal text-[#6b6880]">{s.code}</span>{s.trial && trialTag}</Link>
                ))}
              </dd>
            </dl>
            <div className="mt-3 flex items-center gap-2 text-[12.5px] font-extrabold text-[#6b6880]">다가오는 수업 <span className="font-normal">한국 시간</span></div>
            {!upcoming && <p className="py-2 text-[13px] text-[#6b6880]">불러오는 중…</p>}
            {upcoming && upcoming.length === 0 && <p className="py-2 text-[13px] text-[#6b6880]">예정 수업이 없어요.</p>}
            {upcoming && upcoming.length > 0 && <LessonRows rows={upcoming} studentHref={studentHref} showDate={(d) => mdw(d as never)} hideTutor />}
          </section>
        )}
      </div>
      <BottomNav active="home" demo={false} />
    </div>
  );
}
