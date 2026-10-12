'use client';

import { useEffect, useRef } from 'react';

const cards = [
  {
    content: (
      <>
        엣지영어 최고! 다른 플랫폼은 필리핀 선생님들이 많아서 발음이 조금 아쉬웠는데,
        여기서는{' '}
        <span className="bg-[#FFD4014D] font-semibold">
          미국, 캐나다 영어 선생님들에게서 본토 발음을 배울 수 있어서 너무 좋아요.
        </span>{' '}
        수업 들을 때마다 영어에 더 자신감이 생기는 느낌이에요!
      </>
    ),
    name: '직장인 유OO 님',
  },
  {
    content: (
      <>
        화상영어는{' '}
        <span className="bg-[#FFD4014D] font-semibold">
          처음이라 엄청 긴장했는데, 막상 수업 들어보니까 생각보다 훨씬 편하고 재밌었어요.
        </span>{' '}
        화면 너머 강사님이 밝게 인사해 주시고, 천천히 말해주시니까 금방 적응됐어요. 영어와
        외국인 울렁증이 심했던 저한텐 큰 도전이었는데, 지금은 수업 기다려지는 저 자신이
        신기해요.
      </>
    ),
    name: '김OO 님',
  },
  {
    content: (
      <>
        <span className="bg-[#FFD4014D] font-semibold">
          매주 같은 요일, 같은 시간에 수업이 있어서 영어 공부 루틴이 자연스럽게 생겼어요.
        </span>{' '}
        예전엔 영어가 늘 뒷전이었는데, 지금은 정해진 시간에 딱 집중할 수 있어서 빠지지
        않고 계속하게 되네요. 강사님이 지난 수업에서 다뤘던 표현도 먼저 다시 짚어주시니까,
        그때 배운 게 머릿속에 계속 남아요. 영어가 점점 몸에 익어가는 기분입니다!!
      </>
    ),
    name: '대학생 정OO 님',
  },
  {
    content: (
      <>
        오늘 강사님과{' '}
        <span className="bg-[#FFD4014D] font-semibold">
          첫 수업이었는데 생각했던 것보다 더 좋았어요.
        </span>{' '}
        자연스럽게 대화를 이어갈 수 있게 이끌어주셔서 40분이 금방 지나갔어요:)
      </>
    ),
    name: '직장인 김OO 님',
  },
  {
    content: (
      <>
        강사님께서 제가{' '}
        <span className="bg-[#FFD4014D] font-semibold">
          서투르게 말한 문장을 하나하나 워드에 적어 주시고, 같이 보면서 바로 고쳐
          주셨어요.
        </span>{' '}
        매 수업마다 제 문장을 함께 수정하고 따라 읽는 과정을 반복하다 보니, 어느새
        자연스럽게 영어 문장을 말하고 있는 제 모습을 발견했답니다. 평생 콤플렉스였던
        영어를 이렇게 재미있게 배울 수 있었다니, 정말 신기하고 감사할 따름입니다!
      </>
    ),
    name: '전업주부 최OO 님',
  },
  {
    content: (
      <>
        수업을 그냥 듣고 끝나는 게 아니라, 강사님이{' '}
        <span className="bg-[#FFD4014D] font-semibold">
          수업 후 유용한 표현들을 정리해서 피드백으로 보내주세요.
        </span>{' '}
        그날 배운 내용을 다시 복습해 주면 머릿속에 확실히 남아요. 덕분에 영어 실력이 더
        빨리 느는 것 같아요~!
      </>
    ),
    name: '직장인 이OO 님',
  },
];

export default function RealReviews() {
  const trackRef = useRef<HTMLDivElement>(null);
  const containerRef = useRef<HTMLDivElement>(null);
  const animationRef = useRef<number>(0);
  const position = useRef(0);
  const isPaused = useRef(false);

  // 카드 2배 복제(무한루프)
  const cardList = [...cards, ...cards];

  const SPEED = 1.2; // px per frame

  useEffect(() => {
    const track = trackRef.current as HTMLDivElement;
    if (!track) return;

    function animate() {
      if (!isPaused.current) {
        position.current -= SPEED;
        // 카드 1세트가 끝까지 가면 다시 처음으로
        if (Math.abs(position.current) >= track.scrollWidth / 2) {
          position.current = 0;
        }
        track.style.transform = `translateX(${position.current}px)`;
      }
      animationRef.current = requestAnimationFrame(animate);
    }
    animationRef.current = requestAnimationFrame(animate);
    return () => {
      if (animationRef.current) cancelAnimationFrame(animationRef.current);
    };
  }, []);

  // 마우스 오버 시 멈춤/해제
  useEffect(() => {
    const container = containerRef.current;
    if (!container) return;
    const pause = () => {
      isPaused.current = true;
    };
    const resume = () => {
      isPaused.current = false;
    };
    container.addEventListener('mouseenter', pause);
    container.addEventListener('mouseleave', resume);
    container.addEventListener('touchstart', pause);
    container.addEventListener('touchend', resume);
    return () => {
      container.removeEventListener('mouseenter', pause);
      container.removeEventListener('mouseleave', resume);
      container.removeEventListener('touchstart', pause);
      container.removeEventListener('touchend', resume);
    };
  }, []);

  return (
    <div ref={containerRef} className="relative w-full overflow-hidden py-8">
      <div
        ref={trackRef}
        className="flex gap-8"
        style={{
          willChange: 'transform',
        }}
      >
        {cardList.map((card, idx) => (
          <div
            key={idx}
            className="card card-lg w-[33.75rem] min-w-[33.75rem] rounded-3xl bg-base-100 bg-white shadow-sm"
          >
            <div className="card-body gap-4 rounded-3xl border text-center">
              <p className="content-center">{card.content}</p>
              <div className="card-actions justify-center">
                <button className="rounded-full border-none bg-[#FFEB00] px-6 py-2">
                  {card.name}
                </button>
              </div>
            </div>
          </div>
        ))}
      </div>
    </div>
  );
}
