'use client';

import Link from 'next/link';
import { useMemo, useState } from 'react';
import { diffDays, instantToKstDate } from '@/lms/rules/dates';
import { fakeDirectory, type DirStudent } from '@/lms/admin/fake-directory';
import { AdminHeader, BottomNav, Icon } from '../ui';

const STATUS: Record<DirStudent['status'], [string, string]> = {
  active: ['수강 중', 'bg-[#e3f5ea] text-[#13623a]'],
  ending: ['종료 임박', 'bg-[#fff1d6] text-[#8a5300]'],
  waiting_match: ['매칭 대기', 'bg-[#efebff] text-[#5b3fe0]'],
};

export default function StudentList({ nowIso, initialQuery }: { nowIso: string; initialQuery: string }) {
  const now = useMemo(() => new Date(nowIso), [nowIso]);
  const today = instantToKstDate(now);
  const dir = useMemo(() => fakeDirectory(now), [now]);
  const [q, setQ] = useState(initialQuery);
  const key = q.trim().toLowerCase().replace(/\s+/g, '');
  const tutorName = (id: string | null) => dir.tutors.find((t) => t.id === id)?.name ?? '배정 전';
  const rows = dir.students.filter((s) => !key || [s.name, s.nameEn, s.code, s.email, tutorName(s.tutorId)].join(' ').toLowerCase().replace(/\s+/g, '').includes(key));

  return (
    <div className="mx-auto min-h-dvh max-w-[1280px] pb-24 lg:pb-8">
      <AdminHeader active="students" demo />
      <p className="mx-4 mt-3 rounded-[10px] bg-[#fff8d6] px-3 py-2 text-[13px] text-[#5c4a00] lg:mx-7">가상 데이터 미리보기예요.</p>
      <div className="grid gap-3 px-4 pt-3 lg:px-7">
        <label className="flex min-h-[48px] items-center gap-2 rounded-[12px] border border-[#e6e3ef] bg-white px-3">
          <Icon name="search" className="h-[18px] w-[18px] text-[#6b6880]" />
          <span className="sr-only">학생 찾기</span>
          <input
            type="search"
            autoFocus
            value={q}
            onChange={(e) => setQ(e.target.value)}
            placeholder="이름, 영문 이름, STU 번호, 이메일, 강사 이름"
            className="min-w-0 flex-1 bg-transparent text-[15px] text-[#1d1b2b] outline-none"
          />
        </label>
        <p className="text-[13px] text-[#6b6880]">{rows.length}명</p>
        <div className="grid gap-2 lg:grid-cols-2">
          {rows.map((s) => {
            const d = diffDays(today, s.periodEnd);
            return (
              <Link key={s.code} href={`/lms/admin/students/${s.code}?demo=1`} className="flex items-center gap-3 rounded-[14px] border border-[#e6e3ef] bg-white px-4 py-3">
                <span className="flex h-10 w-10 shrink-0 items-center justify-center rounded-full bg-[#efebff] text-[15px] font-bold text-[#5b3fe0]">{s.name.slice(-1)}</span>
                <span className="min-w-0 flex-1">
                  <span className="flex flex-wrap items-center gap-1.5">
                    <b className="text-[15px] text-[#1d1b2b]">{s.name}</b>
                    <span className="text-[12px] text-[#6b6880]">{s.code}</span>
                    <span className={`rounded-full px-2 py-0.5 text-[11.5px] font-bold ${STATUS[s.status][1]}`}>{STATUS[s.status][0]}</span>
                  </span>
                  <span className="block truncate text-[12.5px] text-[#6b6880]">
                    {s.product} · {tutorName(s.tutorId)} · 정규 {s.regularLeft}회 남음 · {s.status === 'waiting_match' ? '시작 전' : d >= 0 ? `종료 D-${d}` : '종료'}
                  </span>
                </span>
                <Icon name="chevron" className="h-4 w-4 text-[#b9b6c8]" />
              </Link>
            );
          })}
        </div>
      </div>
      <BottomNav active="students" demo />
    </div>
  );
}
