import StudentsLive from './StudentsLive';

// 수강생 메뉴 (H26(44) ②, migration 4300): 전체 수강생 목록 → 검색 → 수강생 상세 → 정보·정규 일정·종료일 수정. 로그인한 운영자(TOTP까지)만
export const dynamic = 'force-dynamic';

export default async function StudentsPage({ searchParams }: { searchParams: Promise<{ q?: string; tab?: string }> }) {
  const { q, tab } = await searchParams;
  return <StudentsLive initialQuery={q ?? ''} initialTab={tab} />;
}
