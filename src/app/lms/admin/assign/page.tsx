import AssignDemo from './AssignDemo';
import AssignLive from './AssignLive';

// 저장된 학생에게 강사·시간 고르기 (신규 매칭 '강사·시간 고르기', 강사가 안 된다고 한 뒤 다른 안)
// 기본: 운영자(TOTP, aal2) — 시험용 Supabase / ?demo=1: 가상 데이터 (저장 안 함)
export const dynamic = 'force-dynamic';

export default async function AssignPage({ searchParams }: { searchParams: Promise<{ demo?: string; e?: string }> }) {
  const { demo, e } = await searchParams;
  return demo === '1' ? <AssignDemo nowIso={new Date().toISOString()} /> : <AssignLive enrollmentId={e ?? ''} />;
}
