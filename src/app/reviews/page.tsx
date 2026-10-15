import ReviewList from '@/components/reviews/ReviewList';
import { getReviews } from '@/lib/reviews';

// 후기 시트 변경을 5분마다 반영 (재배포 불필요)
export const revalidate = 300;

export default async function ReviewsPage() {
  const reviews = await getReviews();

  return (
    <div className="px-4.5 pb-[120px] pt-20 text-center max-md:pb-15 max-md:pt-10">
      <p className="text-xl font-semibold text-edge-purple max-md:text-base">수강후기</p>
      <h1 className="mt-4 break-keep text-4xl font-bold text-[#140F33] max-md:text-[28px]">
        엣지영어 수강생들의{' '}
        <span className="md:hidden">
          <br />
        </span>
        진짜 이야기
      </h1>
      <p className="mt-4 text-lg text-edge-gray max-md:text-[15px]">
        카카오톡으로 받은 후기를 최신순으로 모았어요.
      </p>

      <ReviewList reviews={reviews} />
    </div>
  );
}
