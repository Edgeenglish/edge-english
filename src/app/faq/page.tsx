'use client';

import { useState } from 'react';
import ScrollContainer from 'react-indiana-drag-scroll';
import rawFaqList from '@/data/faqs.json';

export default function FaqPage() {
  const [currentType, setCurrentType] = useState('all');

  const filteredFaqList =
    currentType === 'all'
      ? rawFaqList
      : rawFaqList.filter((faq) => faq.type.includes(currentType));

  return (
    <div className="mx-auto max-w-[1200px] px-4">
      <div className="mt-20 border-b border-[#A4A4A4] max-md:mt-8">
        <h1 className="pb-3 text-4xl font-bold max-md:text-[40px]">FAQ</h1>
      </div>

      {/* 분류 */}
      <ScrollContainer className="mt-8 flex gap-2">
        <button
          className={`h-fit text-nowrap rounded-full px-4 py-2 text-sm font-bold max-md:px-4 max-md:py-2 ${currentType === 'all' ? 'bg-edge-yellow' : 'border'}`}
          onClick={() => setCurrentType('all')}
        >
          ALL
        </button>
        <button
          className={`h-fit text-nowrap rounded-full px-4 py-2 text-sm font-bold max-md:px-4 max-md:py-2 ${currentType === '수강 신청' ? 'bg-edge-yellow' : 'border'}`}
          onClick={() => setCurrentType('수강 신청')}
        >
          수강 신청
        </button>
        <button
          className={`h-fit text-nowrap rounded-full px-4 py-2 text-sm font-bold max-md:px-4 max-md:py-2 ${currentType === '수업 관련' ? 'bg-edge-yellow' : 'border'}`}
          onClick={() => setCurrentType('수업 관련')}
        >
          수업 관련
        </button>
        <button
          className={`h-fit text-nowrap rounded-full px-4 py-2 text-sm font-bold max-md:px-4 max-md:py-2 ${currentType === '수강권' ? 'bg-edge-yellow' : 'border'}`}
          onClick={() => setCurrentType('수강권')}
        >
          수강권
        </button>
        <button
          className={`h-fit text-nowrap rounded-full px-4 py-2 text-sm font-bold max-md:px-4 max-md:py-2 ${currentType === '결제' ? 'bg-edge-yellow' : 'border'}`}
          onClick={() => setCurrentType('결제')}
        >
          결제
        </button>
        <button
          className={`h-fit text-nowrap rounded-full px-4 py-2 text-sm font-bold max-md:px-4 max-md:py-2 ${currentType === '기타' ? 'bg-edge-yellow' : 'border'}`}
          onClick={() => setCurrentType('기타')}
        >
          기타
        </button>
      </ScrollContainer>

      {/* 아코디언 */}
      <div className="relative z-0 mt-8 overflow-x-auto">
        {/* drawer 위로 올라오지 않게 하기 위해 relatvie와 z-index 추가 */}

        {/* ------ */}
        {filteredFaqList.map((faq) => {
          return (
            <div
              className={`collapse collapse-arrow rounded-none border-b`}
              key={faq.index}
            >
              <input type="checkbox" className="peer" />
              <div className="collapse-title flex h-17 items-center gap-6 bg-white py-2 md:px-10">
                <div className="flex-center h-8 min-w-8 rounded-full bg-[#777777] font-montserrat text-lg font-bold text-edge-yellow">
                  Q
                </div>
                <p className="font-medium">{faq.question}</p>
              </div>
              <div className="collapse-content flex items-center gap-6 bg-[#FCFCFC] text-sm peer-checked:py-4 md:px-10">
                <div className="flex-center h-8 min-w-8 rounded-full bg-edge-purple font-montserrat text-lg font-bold text-white">
                  A
                </div>
                <p className="whitespace-pre-line text-[#4A4A4A]">{faq.answer}</p>
              </div>
            </div>
          );
        })}
        {/* ------ */}
      </div>
    </div>
  );
}
