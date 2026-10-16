import { FAKE_TODAY } from '@/lms/admin/fake-data';
import AdminDashboard from './AdminDashboard';

// 운영자 대시보드 (시안 A: 처리할 일 중심, 2026-10-16 대표 확정)
// 지금은 가상 데이터 미리보기. 시험용 Supabase 연결·운영자 로그인 후 실제 데이터로 바꾼다 (docs/lms/supabase-test-setup.md)
export const dynamic = 'force-dynamic';

export default function AdminPage() {
  const now = new Date();
  return <AdminDashboard today={FAKE_TODAY} nowIso={now.toISOString()} preview />;
}
