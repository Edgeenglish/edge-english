import TutorsLive from './TutorsLive';

// 강사 관리 (대시보드 5차 시안): 강사 목록 → 강사 상세(시간대·담당 학생·다가오는 수업·[강사 화면 열기])
export const dynamic = 'force-dynamic';

export default async function TutorsPage({ searchParams }: { searchParams: Promise<{ t?: string }> }) {
  const { t } = await searchParams;
  return <TutorsLive tutorId={t ?? null} />;
}
