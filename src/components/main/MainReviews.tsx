'use client';

import Link from 'next/link';
import { Swiper, SwiperSlide } from 'swiper/react';
import { Pagination } from 'swiper/modules';
import 'swiper/css';
import 'swiper/css/pagination';
import ReviewCard from '@/components/reviews/ReviewCard';
import { ReviewType } from '@/types/ReviewType';

// 메인 후기 섹션: 최신 후기 6개 (PC 3열 그리드, 모바일 옆으로 넘김)
export default function MainReviews({ reviews }: { reviews: ReviewType[] }) {
  if (reviews.length === 0) return null;

  return (
    <div className="bg-[#F3F6F8] px-4.5 py-[120px] text-center max-md:px-0 max-md:py-15">
      <h3 className="text-4xl font-bold text-[#140F33] max-md:px-4.5 max-md:text-[28px]">
        엣지영어 수강생들에게 받은{' '}
        <span className="md:hidden">
          <br />
        </span>
        실제 내돈내산 후기
      </h3>
      <p className="mt-4 text-lg text-edge-gray max-md:px-4.5 max-md:text-[15px]">
        (오타까지 그대로 옮겨왔어요!)
      </p>

      {/* PC */}
      <div className="mx-auto mt-10 grid max-w-[1200px] grid-cols-3 items-stretch gap-6 max-lg:grid-cols-2 max-md:hidden">
        {reviews.map((review) => (
          <ReviewCard key={review.id} review={review} clamp />
        ))}
      </div>

      {/* 모바일 */}
      <div className="md:hidden">
        <Swiper
          modules={[Pagination]}
          pagination={{ clickable: true }}
          spaceBetween={12}
          slidesPerView={1.15}
          slidesOffsetBefore={18}
          slidesOffsetAfter={18}
          className="!pb-10 !pt-7"
        >
          {reviews.map((review) => (
            <SwiperSlide key={review.id} className="!h-auto">
              <ReviewCard review={review} clamp />
            </SwiperSlide>
          ))}
        </Swiper>
      </div>

      <div className="mx-auto mt-10 w-fit max-md:mt-4">
        <Link
          href="/reviews"
          className="btn h-14 rounded-lg border border-[#333] bg-white px-8 font-bold hover:bg-white max-md:h-12 max-md:px-6"
        >
          수강후기 전체 보기 →
        </Link>
      </div>
    </div>
  );
}
