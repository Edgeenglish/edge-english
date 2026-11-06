'use client';

import { useState } from 'react';
import { applicationDate } from '@/lms/admin/form-applications';
import type { FormResponse } from '@/lms/admin/registration';

export default function ApplicationPicker({ applications, selected, onSelect, onManual }: {
  applications: FormResponse[]; selected: string | null; onSelect: (ref: string) => void; onManual: () => void;
}) {
  const [year, setYear] = useState('');
  const [month, setMonth] = useState('');
  const [day, setDay] = useState('');
  const dated = applications.map(a => ({ a, date: applicationDate(a) })).filter(x => x.date);
  const years = [...new Set(dated.map(x => x.date.slice(0, 4)))].sort().reverse();
  const months = [...new Set(dated.filter(x => x.date.startsWith(`${year}-`)).map(x => x.date.slice(5, 7)))].sort().reverse();
  const days = [...new Set(dated.filter(x => x.date.startsWith(`${year}-${month}-`)).map(x => x.date.slice(8, 10)))].sort().reverse();
  const matches = dated.filter(x => x.date === `${year}-${month}-${day}`).sort((a, b) => b.a.submittedAt.localeCompare(a.a.submittedAt));
  const cls = 'min-h-[44px] min-w-0 rounded-[10px] border border-[#e6e3ef] bg-white px-3 text-[14px] text-[#1d1b2b] disabled:opacity-40';
  return <section aria-label="구글폼 신청서" className="mb-3 grid gap-2">
    <div className="flex items-center justify-between gap-2"><strong className="text-[14px]">구글폼 신청서</strong>
      <button type="button" onClick={onManual} className="min-h-[44px] text-[13px] text-[#5b3fe0]">신청서 없이 직접 입력</button></div>
    <p className="text-[12.5px] text-[#6b6880]">제출일을 고른 뒤 학생 이름을 누르세요. (한국 시간)</p>
    <div className="grid grid-cols-3 gap-2">
      <select aria-label="신청 연도" value={year} onChange={e => { setYear(e.target.value); setMonth(''); setDay(''); }} className={cls}>
        <option value="">연도</option>{years.map(y => <option key={y} value={y}>{y}년</option>)}
      </select>
      <select aria-label="신청 월" disabled={!year} value={month} onChange={e => { setMonth(e.target.value); setDay(''); }} className={cls}>
        <option value="">월</option>{months.map(m => <option key={m} value={m}>{Number(m)}월</option>)}
      </select>
      <select aria-label="신청 날짜" disabled={!month} value={day} onChange={e => setDay(e.target.value)} className={cls}>
        <option value="">날짜</option>{days.map(d => <option key={d} value={d}>{Number(d)}일 ({dated.filter(x => x.date === `${year}-${month}-${d}`).length}건)</option>)}
      </select>
    </div>
    {day && <div className="grid gap-2" aria-label="해당 날짜 신청서">
      {matches.map(({ a }) => <button key={a.ref} type="button" aria-pressed={selected === a.ref} onClick={() => onSelect(a.ref)}
        className={`${cls} py-2 text-left ${selected === a.ref ? 'border-[#5b3fe0] bg-[#eeeaff]' : ''}`}>
        <b>{a.nameKo || a.nameEn || '이름 확인 필요'}</b><span className="ml-2 text-[12px] text-[#6b6880]">{new Date(a.submittedAt).toLocaleTimeString('ko-KR', { timeZone: 'Asia/Seoul', hour: '2-digit', minute: '2-digit' })}</span>
        {selected === a.ref && <span className="ml-2 text-[#5b3fe0]">불러옴 ✓</span>}
      </button>)}
    </div>}
    {applications.length === 0 && <p className="text-[13px] text-[#6b6880]">불러온 신청서가 없습니다.</p>}
  </section>;
}
