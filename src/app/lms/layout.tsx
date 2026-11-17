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
      {env === 'test' && (
        <div className="bg-gray-500 px-4 py-2 text-center text-white">
          <p className="text-sm font-bold text-white">{DB_ENV_LABEL[env].title}</p>
          <p className="text-xs text-white/90">{DB_ENV_LABEL[env].note}</p>
        </div>
      )}
      {children}
    </LmsShell>
  );
}
