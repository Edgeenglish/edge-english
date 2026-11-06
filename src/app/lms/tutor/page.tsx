import TutorDemo from './TutorDemo';
import TutorLive from './TutorLive';

// 강사 화면 (② 강사 LMS, migration 2000): 수업 일정 · Class Record 입력 · 보강 가능 여부 답 (영어, 휴대폰 우선)
// 강사 본인 로그인, 또는 운영자(TOTP 완료)가 ?tutor=강사id 로 그대로 보기·대신 입력. ?demo=1 은 가짜 데이터 미리보기
export const dynamic = 'force-dynamic';

export default async function TutorPage({ searchParams }: { searchParams: Promise<{ demo?: string; tutor?: string }> }) {
  const { demo, tutor } = await searchParams;
  if (demo === '1') return <TutorDemo nowIso={new Date().toISOString()} />;
  return <TutorLive tutorParam={tutor} />;
}
