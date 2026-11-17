import type { Metadata } from 'next';
import { notFound } from 'next/navigation';
import { DB_ENV_LABEL, dbEnv } from '@/lms/auth/db-env';
import LmsShell from './LmsShell';

// LMS 화면은 시험 중. LMS_PREVIEW=1 인 환경(로컬·시험용·운영 DB 전용 lms-prod)에서만 열리고, 운영 사이트에서는 404
export const metadata: Metadata = { title: 'LMS', robots: { index: false, follow: false } };

export default function LmsLayout({ children }: { children: React.ReactNode }) {
  if (process.env.LMS_PREVIEW !== '1') notFound();
  const env = dbEnv(process.env.NEXT_PUBLIC_SUPABASE_URL);
  return (
    <LmsShell>
      {/* 운영 DB 띠는 학생·강사·처음 온 사람에게 보이면 안 됨 (2026-11-17 대표 긴급). 시험 사이트 회색 띠만 표시 */}
      {/* 시험 사이트 표시는 한 줄로 얇게 (11/17 대표 '접어줘') */}
      {env === 'test' && <p className="bg-gray-500 py-[3px] text-center text-[11px] font-semibold leading-tight text-white">{DB_ENV_LABEL[env].title}</p>}
      {children}
    </LmsShell>
  );
}
