import DemoOnly from '../DemoOnly';
import Schedule from './Schedule';

// 이번 주 전체 수업 시간표 (한국 시간 기준 + 강사 현지 시간, 서머타임 자동 반영)
export const dynamic = 'force-dynamic';

export default async function SchedulePage({ searchParams }: { searchParams: Promise<{ demo?: string }> }) {
  const { demo } = await searchParams;
  if (demo !== '1') return <DemoOnly href="/lms/admin/schedule" title="이번 주 수업 시간표" />;
  return <Schedule nowIso={new Date().toISOString()} />;
}
