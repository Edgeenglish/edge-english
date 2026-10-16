'use client';

import { useEffect, useRef, useState } from 'react';
import { ReviewType } from '@/types/ReviewType';
import { displayDate, displayName } from '@/lib/reviewFormat';

// 본문 안의 대표 문장을 굵게 표시
function ReviewText({ text, highlight }: { text: string; highlight: string }) {
  const index = highlight ? text.indexOf(highlight) : -1;
  if (index < 0) return <>{text}</>;

  return (
    <>
      {text.slice(0, index)}
      <span className="font-semibold text-[#333]">{highlight}</span>
      {text.slice(index + highlight.length)}
    </>
  );
}

export default function ReviewCard({
  review,
  clamp = false,
}: {
  review: ReviewType;
  clamp?: boolean; // true면 본문 5줄까지만 보이고 '더보기'
}) {
  const textRef = useRef<HTMLParagraphElement>(null);
  const [expanded, setExpanded] = useState(false);
  const [isOverflowing, setIsOverflowing] = useState(false);

  useEffect(() => {
    const el = textRef.current;
    if (!clamp || !el) return;

    // 펼친 상태에서는 다시 재지 않음 ('접기' 버튼 유지)
    const check = () => {
      if (el.classList.contains('line-clamp-5')) {
        setIsOverflowing(el.scrollHeight > el.clientHeight + 1);
      }
    };
    check();
    window.addEventListener('resize', check);
    return () => window.removeEventListener('resize', check);
  }, [clamp]);

  const isClamped = clamp && !expanded;

  return (
    <div className="flex h-full flex-col gap-4 break-keep rounded-3xl border bg-white p-7 text-left shadow-sm max-md:gap-3 max-md:rounded-[20px] max-md:p-5">
      {review.highlight && (
        <p className="text-[19px] font-bold leading-[145%] text-[#140F33] max-md:text-[17px]">
          “{review.highlight}”
        </p>
      )}

      <p
        ref={textRef}
        className={`whitespace-pre-line leading-[170%] text-edge-gray max-md:text-[15px] ${isClamped ? 'line-clamp-5' : ''}`}
      >
        <ReviewText text={review.text} highlight={review.highlight} />
      </p>

      {clamp && isOverflowing && (
        <button
          type="button"
          className="w-fit text-sm font-semibold text-edge-purple"
          onClick={() => setExpanded(!expanded)}
        >
          {expanded ? '접기' : '더보기'}
        </button>
      )}

      <div className="mt-auto flex items-center justify-between gap-2 pt-2">
        <p className="font-semibold">{displayName(review)}</p>
        {review.date && (
          <p className="text-sm text-edge-light">{displayDate(review.date)}</p>
        )}
      </div>
    </div>
  );
}
