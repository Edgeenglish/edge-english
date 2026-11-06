import ImportDemo from './ImportDemo';
import ImportLive from './ImportLive';

// 기존 학생 간단 입력 (D-52)
// 기본: 로그인한 운영자(TOTP까지, aal2) — 강사·일정 + 입력 저장 함수 (migration 1300)
// ?demo=1: 가상 강사·일정 미리보기 (저장 안 함)
export const dynamic = 'force-dynamic';

export default async function ImportPage({ searchParams }: { searchParams: Promise<{ demo?: string }> }) {
  const { demo } = await searchParams;
  return demo === '1' ? <ImportDemo nowIso={new Date().toISOString()} /> : <ImportLive />;
}
