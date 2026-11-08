'use client';

// 운영진 학생 목록: 수강 중 · 수강 예정 · 종료 구분 + 이름 검색 → 학생 상세 (H26(44) ②, 4300). 수강 상태는 등록 기간으로 계산(따로 입력 안 함)
import Link from 'next/link';
import { useMemo, useState } from 'react';
import { diffDays, instantToKstDate } from '@/lms/rules/dates';
import { matchStudent, md, productText, slotsText, STATUS_TEXT, type StudentRow, type StudentStatus } from '@/lms/admin/students';
import { AdminHeader, BottomNav, Icon } from '../ui';
import { Rich } from '@/app/lms/Rich';

const STATUS_STYLE: Record<StudentStatus, string> = {
  active: 'bg-[#e3f5ea] text-[#13623a]', upcoming: 'bg-[#efebff] text-[#5b3fe0]', pending: 'bg-[#fff1d6] text-[#8a5300]', ended: 'bg-[#f0eef6] text-[#6b6880]', none: 'bg-[#fff1d6] text-[#8a5300]',
};
type Tab = 'active' | 'upcoming' | 'ended' | 'all';
const TABS: { key: Tab; label: string }[] = [{ key: 'active', label: '수강 중' }, { key: 'upcoming', label: '수강 예정' }, { key: 'ended', label: '종료' }, { key: 'all', label: '전체' }];

export default function StudentList({ rows, nowIso, initialQuery, initialTab }: { rows: StudentRow[]; nowIso: string; initialQuery: string; initialTab?: string }) {
  const today = useMemo(() => instantToKstDate(new Date(nowIso)), [nowIso]);
  const [q, setQ] = useState(initialQuery);
  const [tab, setTab] = useState<Tab>(TABS.some((t) => t.key === initialTab) ? (initialTab as Tab) : 'active');
  const counts = { active: 0, upcoming: 0, ended: 0, all: rows.length } as Record<Tab, number>;
  // 결제 확인 전 학생은 '수강 예정' 칸에서 보임 (배지는 '결제 확인 전', B-01)
  const tabOf = (r: StudentRow): Tab => (r.status === 'pending' ? 'upcoming' : r.status === 'none' ? 'ended' : (r.status as Tab));
  for (const r of rows) counts[tabOf(r)] += 1;
  const searching = q.trim().length > 0;
  // 검색할 때는 상태와 상관없이 전체에서 찾음 (이름만 알고 찾는 경우)
  const list = rows.filter((r) => matchStudent(r, q) && (searching || tab === 'all' || tabOf(r) === tab));
  return (
    <div className="mx-auto min-h-dvh max-w-[1280px] pb-24 lg:pb-8">
      <AdminHeader active="students" demo={false} />
      <div className="grid gap-3 px-4 pt-3 lg:px-7">
        <label className="flex min-h-[48px] items-center gap-2 rounded-[12px] border border-[#e6e3ef] bg-white px-3">
          <Icon name="search" className="h-[18px] w-[18px] text-[#6b6880]" />
          <span className="sr-only">학생 찾기</span>
          <input type="search" value={q} onChange={(e) => setQ(e.target.value)} placeholder="이름, 영문 이름, STU 번호, 이메일, 강사"
            className="min-w-0 flex-1 bg-transparent text-[16px] text-[#1d1b2b] outline-none" />
        </label>
        <div role="tablist" aria-label="수강 상태" className="flex flex-wrap gap-1.5">
          {TABS.map((t) => (
            <button key={t.key} type="button" role="tab" aria-selected={tab === t.key && !searching} onClick={() => { setTab(t.key); setQ(''); }}
              className={`min-h-[40px] rounded-full px-3.5 text-[13.5px] font-semibold ${tab === t.key && !searching ? 'bg-[#1b1442] text-white' : 'border border-[#e6e3ef] bg-white text-[#1d1b2b]'}`}>
              {t.label} <span className={tab === t.key && !searching ? 'text-[#c9c0ff]' : 'text-[#6b6880]'}>{counts[t.key]}</span>
            </button>
          ))}
        </div>
        <div className="flex items-center justify-between gap-2">
          <p className="text-[13px] text-[#6b6880]">{searching ? `'${q.trim()}' 검색 ` : ''}{list.length}명</p>
          <Link href="/lms/admin/students/sheet" className="min-h-[36px] rounded-[8px] border border-[#e6e3ef] bg-white px-3 text-[13px] font-semibold leading-[34px] text-[#5b3fe0]">시트 Student Info 비교</Link>
        </div>
        {list.length === 0 && <p className="rounded-[14px] border border-[#e6e3ef] bg-white px-4 py-8 text-center text-[14px] text-[#6b6880]">해당하는 학생이 없어요.</p>}
        <div className="grid grid-cols-[minmax(0,1fr)] gap-2 lg:grid-cols-2">
          {list.map((s) => {
            const d = s.finalEndDate ? diffDays(today, s.finalEndDate) : null;
            const line2 = s.status === 'pending'
              // 결제 확인 전: 수업·일정이 아직 없음 — 결제 확인 뒤 N회 생성·강사 배정 (B-01)
              ? [productText(s.weeklyCount && s.durationMin ? { weeks: s.weeks, legacyLabel: s.legacyLabel, weeklyCount: s.weeklyCount, durationMin: s.durationMin } : null), '강사 배정 전', `결제 확인 후 수업 ${s.weeklyCount && s.weeks ? s.weeklyCount * s.weeks : ''}회 생성`, s.startDate ? `희망 시작 ${md(s.startDate)}` : null].filter(Boolean).join(' · ')
              : [
              s.tutor ?? (s.status === 'active' || s.status === 'upcoming' ? '강사 배정 전' : null),
              s.slots.length ? `${slotsText(s.slots)} *한국 시간*` : null,
              s.status === 'none' ? null : productText(s.weeklyCount && s.durationMin ? { weeks: s.weeks, legacyLabel: s.legacyLabel, weeklyCount: s.weeklyCount, durationMin: s.durationMin } : null),
              s.status === 'upcoming' && s.startDate ? `${md(s.startDate)} 시작` : s.status === 'active' && d !== null ? `종료 ${md(s.finalEndDate!)} (D-${d})` : s.status === 'ended' && s.finalEndDate ? `${md(s.finalEndDate)} 종료` : null,
            ].filter(Boolean).join(' · ');
            return (
              <Link key={s.id} href={`/lms/admin/students/${s.code}`} className="flex min-w-0 items-center gap-3 rounded-[14px] border border-[#e6e3ef] bg-white px-4 py-3">
                <span className="flex h-10 w-10 shrink-0 items-center justify-center rounded-full bg-[#efebff] text-[15px] font-bold text-[#5b3fe0]">{s.nameKo.slice(-1)}</span>
                <span className="min-w-0 flex-1">
                  <span className="flex flex-wrap items-center gap-1.5">
                    <b className="text-[15px] text-[#1d1b2b]">{s.nameKo}</b>
                    <span className="text-[12.5px] text-[#6b6880]">({s.nameEn})</span>
                    <span className="text-[12px] text-[#6b6880]">{s.code}</span>
                    <span className={`rounded-full px-2 py-0.5 text-[11.5px] font-bold ${STATUS_STYLE[s.status]}`}>{STATUS_TEXT[s.status]}</span>
                    {s.noticePending && <span className="rounded-full bg-[#fff1d6] px-2 py-0.5 text-[11.5px] font-bold text-[#8a5300]">일정 변경 안내 안 보냄</span>}
                  </span>
                  <span className="block truncate text-[12.5px] text-[#6b6880]"><Rich text={line2} /></span>
                </span>
                <Icon name="chevron" className="h-4 w-4 text-[#b9b6c8]" />
              </Link>
            );
          })}
        </div>
      </div>
      <BottomNav active="students" demo={false} />
    </div>
  );
}
