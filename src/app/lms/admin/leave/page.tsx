import LeaveDemo from './LeaveDemo';
import LeaveLive from './LeaveLive';

// 강사 휴무·대체강사 (2순위 ①, migration 1800). 로그인한 운영자(TOTP까지, aal2)만. ?off=<휴무 번호> 로 휴무를 바로 열 수 있음, ?new=1 = 휴무 입력 칸부터
export const dynamic = 'force-dynamic';

export default async function LeavePage({ searchParams }: { searchParams: Promise<{ off?: string; new?: string; demo?: string }> }) {
  const { off, new: startNew, demo } = await searchParams;
  if (demo === '1') return <LeaveDemo nowIso={new Date().toISOString()} />;
  return <LeaveLive offId={off} startNew={startNew === '1'} />;
}
