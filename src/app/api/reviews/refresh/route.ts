import { revalidatePath, revalidateTag } from 'next/cache';
import { REVIEWS_CACHE_TAG } from '@/lib/reviews';

// 관리 화면(Apps Script)이 후기를 등록·수정·숨김·삭제한 직후 호출 → 홈페이지 후기 즉시 갱신
// 비밀값은 Vercel 환경변수 REVIEWS_REFRESH_SECRET 과 관리 화면 Code.gs 의 REFRESH_SECRET 이 같아야 함
export async function POST(request: Request) {
  const secret = process.env.REVIEWS_REFRESH_SECRET;
  if (!secret) {
    return Response.json(
      { ok: false, error: 'REVIEWS_REFRESH_SECRET 미설정' },
      { status: 503 }
    );
  }

  const body = await request.json().catch(() => ({}));
  if (body?.secret !== secret) {
    return Response.json(
      { ok: false, error: '비밀값이 맞지 않습니다.' },
      { status: 401 }
    );
  }

  revalidateTag(REVIEWS_CACHE_TAG, { expire: 0 });
  revalidatePath('/');
  revalidatePath('/reviews');
  return Response.json({ ok: true });
}
