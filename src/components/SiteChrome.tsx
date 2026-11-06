'use client';

import { usePathname } from 'next/navigation';

/** 홈페이지 머리말·바닥글·떠 있는 메뉴. LMS 화면(/lms)에서는 숨김 */
export default function SiteChrome({ children }: { children: React.ReactNode }) {
  const pathName = usePathname();
  if (pathName?.startsWith('/lms')) return null;
  return <>{children}</>;
}
