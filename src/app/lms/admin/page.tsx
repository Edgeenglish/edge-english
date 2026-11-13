import { fakeDirectory } from '@/lms/admin/fake-directory';
import { toLessonItems, type LessonListRow } from '@/lms/admin/dashboard';
import { instantToKstDate } from '@/lms/rules/dates';
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
    // 가상 수업으로 실제와 같은 줄 만들기 (취소·연결된 보강·대체·시간 변경·기록 전 모양 확인용)
    const dir = fakeDirectory(now);
    const todays = dir.lessons.filter((l) => instantToKstDate(l.startsAt) === instantToKstDate(now));
    const lastPast = [...todays].reverse().find((l) => l.state === 'done' && !l.noShow && l.startsAt.getTime() + l.minutes * 60_000 <= now.getTime());
    const firstDone = todays.find((l) => l.state === 'done' && !l.noShow && l !== lastPast);
    const demoCancel = todays.find((l) => l.state === 'done' && !l.noShow && l !== lastPast && l !== firstDone);
    if (demoCancel) demoCancel.state = 'canceled';
    const rows: LessonListRow[] = todays.map((l) => ({
      id: l.id, starts_at: l.startsAt.toISOString(), ends_at: new Date(l.startsAt.getTime() + l.minutes * 60_000).toISOString(), kind: l.kind, class_type: null,
      state: l === lastPast ? 'scheduled' : l.state, class_status: l.state === 'canceled' ? 'Student canceled in advance' : null,
      student: { code: '', name_ko: dir.students.find((s) => s.code === l.studentCode)?.name ?? '(수강생)' },
      tutor: { name: dir.tutors.find((t) => t.id === l.tutorId)?.name ?? '(강사)' },
      original_tutor: l === firstDone ? { name: 'Emma' } : null,
    }));
    const makeups = new Map(todays.filter((l) => l.state === 'canceled').map((l) => [l.id, new Date(l.startsAt.getTime() + 7 * 86400_000).toISOString()]));
    const moves = new Map(todays.filter((l) => l.kind === 'makeup').map((l) => [l.id, new Date(l.startsAt.getTime() - 3600_000).toISOString()]));
    const today = toLessonItems(rows, new Set(todays.filter((l) => l.noShow).map((l) => l.id)), { makeups, moves, now });
    return <AdminDashboard today={today} stats={null} nowIso={now.toISOString()} preview />;
  }
  return <AdminLive />;
}
