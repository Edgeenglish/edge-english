import NewStudentDemo from './NewStudentDemo';
import NewStudentLive from './NewStudentLive';

// 신규 학생 등록 (2026-10-18 대표 최종 시안)
// 기본: 로그인한 운영자(TOTP까지, aal2) — 시험용 Supabase 강사·일정 + 등록 저장 함수
// ?demo=1: 가상 신청서·강사·일정 미리보기 (저장 안 함)
export const dynamic = 'force-dynamic';

export default async function NewStudentPage({ searchParams }: { searchParams: Promise<{ demo?: string }> }) {
  const { demo } = await searchParams;
  return demo === '1' ? <NewStudentDemo nowIso={new Date().toISOString()} /> : <NewStudentLive />;
}
