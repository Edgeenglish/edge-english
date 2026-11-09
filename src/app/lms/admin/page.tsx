import { fakeTodayPanel } from '@/lms/admin/fake-directory';
import { ampmKo } from '@/lms/rules/dates';
import AdminDashboard from './AdminDashboard';
import AdminLive from './AdminLive';

// 운영자 대시보드 (시안 A: 처리할 일 중심, 2026-10-16 대표 확정)
// 기본: 로그인한 운영자(TOTP까지, aal2)만 — 시험용 Supabase 실제 데이터 (AdminLive)
// ?demo=1: 가상 데이터 미리보기 (화면 모양 확인용, 데이터 연결 없음)
export const dynamic = 'force-dynamic';

export default async function AdminPage({ searchParams }: { searchParams: Promise<{ demo?: string }> }) {
  const { demo } = await searchParams;
  const now = new Date();
  if (demo === '1') {
    const today = fakeTodayPanel(now).map((l, i) => ({ id: `pv-${i}`, date: '', time: ampmKo(l.time), studentName: l.student, studentCode: '', tutorName: l.tutor, kind: l.state === '보강' ? '보강' : '정규', state: l.state === '보강' ? '예정' : l.state, muted: l.state === '완료' || l.state === '취소' || l.state === '수강생 변경' }));
    return <AdminDashboard today={today} stats={null} nowIso={now.toISOString()} preview />;
  }
  return <AdminLive />;
}
