import { getReviewsWithSource } from '@/lib/reviews';

// 관리 화면이 '홈페이지 반영 완료/반영 중'을 표시할 때 확인하는 주소
// 공개 후기의 id 만 알려줌 (내용·이름 없음)
export const dynamic = 'force-dynamic';

export async function GET() {
  try {
    const { reviews, source } = await getReviewsWithSource();
    return Response.json(
      { source, ids: reviews.map((r) => r.id) },
      { headers: { 'Cache-Control': 'no-store' } }
    );
  } catch {
    return Response.json(
      { source: 'error', ids: [] },
      { status: 502, headers: { 'Cache-Control': 'no-store' } }
    );
  }
}
