'use client';

// 홈페이지 방문 통계 (Vercel Web Analytics, 쿠키 없음 · 대표 11/26)
// 주소 뒤 ?… 값(학생 id 등)은 보내지 않고, 운영자 화면(/lms/admin)은 세지 않는다
import { Analytics } from '@vercel/analytics/next';

export default function SiteAnalytics() {
  return (
    <Analytics
      beforeSend={(e) => {
        const u = new URL(e.url);
        if (u.pathname.startsWith('/lms/admin')) return null;
        return { ...e, url: u.origin + u.pathname };
      }}
    />
  );
}
