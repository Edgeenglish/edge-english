import StudentDetailLive from './StudentDetailLive';

// 학생 한 명 (운영자 전용 — 결제·운영 메모도 보임). 정보 수정 · 정규 일정 수정 · 종료일 연장 · 안내 문구 (H26(44), migration 4300)
export const dynamic = 'force-dynamic';

export default async function StudentPage({ params }: { params: Promise<{ code: string }> }) {
  const { code } = await params;
  return <StudentDetailLive code={code} />;
}
