import { FAKE_TODAY } from '@/lms/admin/fake-data';
import AdminDashboard from './AdminDashboard';
import AdminLive from './AdminLive';

// 운영자 대시보드 (시안 A: 처리할 일 중심, 2026-10-16 대표 확정)
// 기본: 로그인한 운영자(TOTP까지, aal2)만 — 시험용 Supabase 실제 데이터 (AdminLive)
// ?demo=1: 가상 데이터 미리보기 (화면 모양 확인용, 데이터 연결 없음)
export const dynamic = 'force-dynamic';

export default async function AdminPage({ searchParams }: { searchParams: Promise<{ demo?: string }> }) {
  const { demo } = await searchParams;
  if (demo === '1') return <AdminDashboard today={FAKE_TODAY} nowIso={new Date().toISOString()} preview />;
  return <AdminLive />;
}
