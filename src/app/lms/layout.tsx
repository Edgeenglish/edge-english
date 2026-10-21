import type { Metadata } from 'next';
import { notFound } from 'next/navigation';

// LMS 화면은 시험 중. LMS_PREVIEW=1 인 환경(로컬·시험용)에서만 열리고, 운영 사이트에서는 404
export const metadata: Metadata = { title: 'LMS', robots: { index: false, follow: false } };

export default function LmsLayout({ children }: { children: React.ReactNode }) {
  if (process.env.LMS_PREVIEW !== '1') notFound();
  return <div className="min-h-dvh bg-[#f6f5fa]">{children}</div>;
}
