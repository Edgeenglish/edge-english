// 수업 줄 (대시보드 '오늘 수업' · 수업 목록 · 강사 상세). 시각은 한국 시간 — 기준 이름은 상자 제목 옆에 한 번
import Link from 'next/link';
import type { LessonItem } from '@/lms/admin/dashboard';

export function LessonRows({ rows, studentHref, showDate, hideTutor }: { rows: LessonItem[]; studentHref: (code: string) => string; showDate?: (d: string) => string; hideTutor?: boolean }) {
  return (
    <ul>
      {rows.map((l) => (
        <li key={l.id} className="grid grid-cols-[auto_minmax(0,1fr)_auto] items-center gap-2 border-b border-[#e6e3ef] py-1.5 text-[13.5px] last:border-0">
          <span className="whitespace-nowrap tabular-nums text-[13px] text-[#6b6880]">{showDate ? `${showDate(l.date)} ` : ''}{l.time}</span>
          <span className="min-w-0 truncate">
            {l.studentCode ? <Link href={studentHref(l.studentCode)} className="text-[#1d1b2b] hover:underline">{l.studentName}</Link> : l.studentName}
            {!hideTutor && <span className="text-[#6b6880]"> · {l.tutorName}</span>}
            {l.kind !== '정규' && <span className="ml-1 rounded-[6px] border border-[#e6e3ef] px-1 text-[11.5px] text-[#6b6880]">{l.kind}</span>}
          </span>
          <span className={`whitespace-nowrap text-[12.5px] ${l.muted ? 'text-[#6b6880]' : l.state === '노쇼 신고' ? 'font-semibold text-[#c62b2b]' : 'font-semibold text-[#1d1b2b]'}`}>{l.state}</span>
        </li>
      ))}
    </ul>
  );
}
