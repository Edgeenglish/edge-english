'use client';

import { useState } from 'react';
import ReviewCard from '@/components/reviews/ReviewCard';
import { ReviewType } from '@/types/ReviewType';

const PAGE_SIZE = 12; // '후기 더 보기' 한 번에 보여줄 개수

// 전체 후기: PC 3열 벽돌 배치, 모바일 1열
export default function ReviewList({ reviews }: { reviews: ReviewType[] }) {
  const [visibleCount, setVisibleCount] = useState(PAGE_SIZE);

  if (reviews.length === 0) {
    return <p className="mt-15 text-edge-gray">아직 등록된 후기가 없어요.</p>;
  }

  return (
    <>
      <div className="mx-auto mt-12 max-w-[1200px] columns-3 gap-6 max-lg:columns-2 max-md:mt-8 max-md:columns-1">
        {reviews.slice(0, visibleCount).map((review) => (
          <div key={review.id} className="mb-6 break-inside-avoid max-md:mb-4">
            <ReviewCard review={review} />
          </div>
        ))}
      </div>

      {visibleCount < reviews.length && (
        <button
          type="button"
          className="btn mt-6 h-14 rounded-lg border border-[#333] bg-white px-8 font-bold hover:bg-white max-md:h-12"
          onClick={() => setVisibleCount(visibleCount + PAGE_SIZE)}
        >
          후기 더 보기
        </button>
      )}
    </>
  );
}
