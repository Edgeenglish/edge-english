'use client';

// 학생·강사 홈 공지 (운영진 대시보드에서 게시). 게시 중인 공지만, 없으면 아무것도 안 보임
import { useEffect, useState } from 'react';
import { supabaseBrowser } from '@/lms/auth/client';
import { loadLiveNotices } from '@/lms/admin/dashboard-live';

export default function HomeNotices({ who, title, className = '' }: { who: 'student' | 'tutor'; title: string; className?: string }) {
  const [list, setList] = useState<{ id: string; title: string; body: string }[]>([]);
  useEffect(() => {
    const sb = supabaseBrowser();
    if (!sb) return;
    let stop = false;
    void sb.auth.getSession().then(({ data }) => {
      if (!data.session) return;
      void loadLiveNotices(sb, who).then((r) => { if (!stop) setList(r); });
    });
    return () => { stop = true; };
  }, [who]);
  if (list.length === 0) return null;
  return (
    <section aria-label={title} className={`overflow-hidden rounded-[18px] border-2 border-[#e6e3ef] bg-white ${className}`}>
      <h2 className="bg-[#f6f5fa] px-4 py-2.5 text-[16px] font-bold text-[#1d1b2b]">{title}</h2>
      <ul className="divide-y divide-[#eeedf3]">
        {list.map((n) => (
          <li key={n.id} className="px-4 py-3">
            <b className="block text-[15px] text-[#1d1b2b]">{n.title}</b>
            <p className="mt-0.5 whitespace-pre-line text-[14px] leading-relaxed text-[#3d3a52]">{n.body}</p>
          </li>
        ))}
      </ul>
    </section>
  );
}
