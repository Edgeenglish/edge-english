import SheetCompareLive from './SheetCompareLive';

// ⑤ 기존 Google Sheets 'Student Info' → LMS: 학생별 시트 값 ↔ LMS 값 비교·승인 (H26(44) ⑤, migration 4310). ?student=STU-0004 로 한 학생만
export const dynamic = 'force-dynamic';

export default async function SheetPage({ searchParams }: { searchParams: Promise<{ student?: string }> }) {
  const { student } = await searchParams;
  return <SheetCompareLive studentParam={student} />;
}
