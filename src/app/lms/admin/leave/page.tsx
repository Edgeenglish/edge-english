import LeaveLive from './LeaveLive';

// 강사 휴무·대체강사 (2순위 ①, migration 1800). 로그인한 운영자(TOTP까지, aal2)만. ?off=<휴무 번호> 로 휴무를 바로 열 수 있음
export const dynamic = 'force-dynamic';

export default async function LeavePage({ searchParams }: { searchParams: Promise<{ off?: string }> }) {
  const { off } = await searchParams;
  return <LeaveLive offId={off} />;
}
