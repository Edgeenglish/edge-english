import ChangeLive from './ChangeLive';

// 수업 변경·보강 (1순위, migration 1700). 로그인한 운영자(TOTP까지, aal2)만. ?student=STU-0001 로 학생을 바로 열 수 있음
export const dynamic = 'force-dynamic';

export default async function ChangePage({ searchParams }: { searchParams: Promise<{ student?: string }> }) {
  const { student } = await searchParams;
  return <ChangeLive code={student} />;
}
