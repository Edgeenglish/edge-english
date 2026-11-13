// 수업 줄 (대시보드 '오늘 수업' · 강사 상세). 시각은 한국 시간 — 기준 이름은 상자 제목 옆에 한 번
// 상태는 PC·휴대폰 모두 오른쪽 같은 자리, 사유·변경 내용만 이름 아래 (대표 11/13). 취소된 수업은 시각·학생 이름에만 취소선
import Link from 'next/link';
import type { LessonItem } from '@/lms/admin/dashboard';

/** 상태 글자: 완료 흐린 글씨 · 노쇼 빨강 · 나머지 굵게 (의미는 항상 글자로) */
export const lessonStateClass = (l: Pick<LessonItem, 'tone'>) =>
  l.tone === 'muted' ? 'text-[#6b6880]' : l.tone === 'alert' ? 'font-semibold text-[#c62b2b]' : 'font-semibold text-[#1d1b2b]';
export const STRIKE = 'line-through decoration-[1.5px]';

export function LessonRows({ rows, studentHref, showDate, hideTutor }: { rows: LessonItem[]; studentHref: (code: string) => string; showDate?: (d: string) => string; hideTutor?: boolean }) {
  return (
    <ul>
      {rows.map((l) => (
        <li key={l.id} className="grid grid-cols-[auto_minmax(0,1fr)_auto] items-start gap-2 border-b border-[#e6e3ef] py-1.5 text-[13.5px] last:border-0">
          <span className={`whitespace-nowrap tabular-nums text-[13px] text-[#6b6880] ${l.struck ? STRIKE : ''}`}>{showDate ? `${showDate(l.date)} ` : ''}{l.time}</span>
          <span className="min-w-0">
            <span className="block truncate">
              {l.studentCode ? <Link href={studentHref(l.studentCode)} className={`text-[#1d1b2b] hover:underline ${l.struck ? STRIKE : ''}`}>{l.studentName}</Link> : <span className={l.struck ? STRIKE : ''}>{l.studentName}</span>}
              {!hideTutor && <span className="text-[#6b6880]"> · {l.tutorName}</span>}
              {l.kind !== '정규' && <span className="ml-1 rounded-[6px] border border-[#e6e3ef] px-1 text-[11.5px] text-[#6b6880]">{l.kind}</span>}
            </span>
            {l.note && <span className="block text-[12px] leading-snug text-[#6b6880]">{l.note}</span>}
          </span>
          <span className={`whitespace-nowrap text-[12.5px] ${lessonStateClass(l)}`}>{l.state}</span>
        </li>
      ))}
    </ul>
  );
}
