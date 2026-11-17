'use client';

import { usePathname } from 'next/navigation';
import { inSiteFrame } from '@/components/SiteChrome';

/** 로그인·학생 화면은 홈페이지 머리글·바닥글 사이에 들어가므로 화면 높이를 채우지 않음 (바닥글이 내용 바로 뒤에 오게) */
export default function LmsShell({ children }: { children: React.ReactNode }) {
  const path = usePathname();
  return <div className={`bg-[#f6f5fa] ${inSiteFrame(path) ? '' : 'min-h-dvh'}`}>{children}</div>;
}
