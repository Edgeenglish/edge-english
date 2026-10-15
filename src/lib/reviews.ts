import { ReviewType } from '@/types/ReviewType';
import { maskContact, maskName } from '@/lib/reviewFormat';
import fallbackReviews from '@/data/reviews-fallback.json';

// 후기는 Google 시트 → Apps Script 공개 피드에서 가져옴 (docs/reviews-setup.md 참고)
// 피드 주소는 Vercel 환경변수 REVIEWS_FEED_URL 에만 저장 (서버에서만 읽음, 브라우저에 노출 안 됨)
const REVALIDATE_SECONDS = 300; // 5분마다 갱신

// 날짜는 YYYY-MM-DD, 기존 후기처럼 날짜를 모르면 빈 값
const isValidDate = (v: string) => v === '' || /^\d{4}-\d{2}-\d{2}$/.test(v);

function normalize(list: unknown): ReviewType[] {
  if (!Array.isArray(list)) throw new Error('후기 피드 형식이 올바르지 않습니다.');

  return list
    .filter((r) => r && typeof r.text === 'string' && r.text.trim())
    .map((r, i) => ({
      id: String(r.id || i),
      date: String(r.date ?? ''),
      name: maskName(String(r.name ?? '')),
      job: String(r.job ?? '').trim(),
      text: maskContact(String(r.text).trim()),
      highlight: maskContact(String(r.highlight ?? '').trim()),
    }))
    .filter((r) => isValidDate(r.date))
    .sort((a, b) => b.date.localeCompare(a.date)); // 최신순 (같은 날짜는 피드 순서 유지)
}

// 공개된 엣지영어 후기 (최신순)
export async function getReviews(): Promise<ReviewType[]> {
  const url = process.env.REVIEWS_FEED_URL;

  // 피드 주소가 없으면(로컬 개발 등) 기존 후기로 표시
  if (!url) return normalize(fallbackReviews);

  try {
    const res = await fetch(url, { next: { revalidate: REVALIDATE_SECONDS } });
    if (!res.ok) throw new Error(`후기 피드 응답 오류: ${res.status}`);
    const data = await res.json();
    if (data.error) throw new Error(`후기 피드 오류: ${data.error}`);
    return normalize(data.reviews);
  } catch (error) {
    // 배포(빌드) 중 Google이 응답하지 않으면 기존 후기로 빌드를 이어감
    if (process.env.NEXT_PHASE === 'phase-production-build') {
      console.error(error);
      return normalize(fallbackReviews);
    }
    // 운영 중에는 오류를 던져, 마지막으로 정상 생성된 페이지가 계속 보이게 함
    throw error;
  }
}
