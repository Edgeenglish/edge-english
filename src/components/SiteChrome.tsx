'use client';

import { usePathname } from 'next/navigation';

/** 홈페이지 틀(머리말·바닥글·떠 있는 메뉴)을 보일 화면
 * H26(206) 보충(11/17 대표 확정): 로그인·가입·학생 화면은 홈페이지 틀 안, 강사·운영자 화면은 지금 LMS 틀 그대로 */
export const inSiteFrame = (path: string | null) => !!path && (path.startsWith('/lms/login') || path.startsWith('/lms/student'));

export default function SiteChrome({ children, lms = false, footer = false }: { children: React.ReactNode; lms?: boolean; footer?: boolean }) {
  const pathName = usePathname();
  if (pathName?.startsWith('/lms')) {
    if (!lms || !inSiteFrame(pathName)) return null;
    // 학생 휴대폰 아래 고정 메뉴가 바닥글을 가리지 않게 메뉴 높이만큼 여백
    if (footer && pathName.startsWith('/lms/student')) return <div className="pb-[calc(76px+env(safe-area-inset-bottom))] lg:pb-0">{children}</div>;
  }
  return <>{children}</>;
}
