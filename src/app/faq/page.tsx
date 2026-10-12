'use client';

import { useState } from 'react';
import Link from 'next/link';
import ScrollContainer from 'react-indiana-drag-scroll';
import rawFaqList from '@/data/faqs.json';

const KAKAO_CHANNEL_URL = 'https://pf.kakao.com/_blxgib/friend';

// 검색어와 일치하는 부분을 형광펜 색으로 표시
function highlight(text: string, keyword: string) {
  if (!keyword) return text;
  const escaped = keyword.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  const parts = text.split(new RegExp(`(${escaped})`, 'gi'));
  return parts.map((part, i) =>
    part.toLowerCase() === keyword.toLowerCase() ? (
      <mark key={i} className="rounded-sm bg-[#FFF176] px-0.5 text-inherit">
        {part}
      </mark>
    ) : (
      part
    )
  );
}

export default function FaqPage() {
  const [currentType, setCurrentType] = useState('all');
  const [searchText, setSearchText] = useState('');
  const keyword = searchText.trim();

  const filteredFaqList = rawFaqList
    .filter((faq) => currentType === 'all' || faq.type.includes(currentType))
    .filter((faq) => {
      if (!keyword) return true;
      const lower = keyword.toLowerCase();
      return (
        faq.question.toLowerCase().includes(lower) ||
        faq.answer.toLowerCase().includes(lower)
      );
    });

  return (
    <div className="mx-auto max-w-[1200px] px-4">
      <div className="mt-20 border-b border-[#A4A4A4] max-md:mt-8">
        <h1 className="pb-3 text-4xl font-bold max-md:text-[40px]">FAQ</h1>
      </div>

      {/* 검색 */}
      <div className="mt-8 flex items-center gap-2 rounded-full border border-[#A4A4A4] px-5 py-3 focus-within:border-edge-purple">
        <svg
          xmlns="http://www.w3.org/2000/svg"
          viewBox="0 0 24 24"
          fill="none"
          stroke="#777777"
          strokeWidth={2}
          className="h-5 w-5 shrink-0"
          aria-hidden="true"
        >
          <circle cx="11" cy="11" r="7" />
          <path d="m20 20-3.5-3.5" strokeLinecap="round" />
        </svg>
        <input
          type="search"
          value={searchText}
          onChange={(e) => setSearchText(e.target.value)}
          placeholder="궁금한 내용을 검색해 보세요"
          aria-label="FAQ 검색"
          className="w-full bg-transparent text-base outline-none"
        />
      </div>

      {/* 분류 */}
      <ScrollContainer className="mt-4 flex gap-2">
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
                <p className="font-medium">{highlight(faq.question, keyword)}</p>
              </div>
              <div className="collapse-content flex items-center gap-6 bg-[#FCFCFC] text-sm peer-checked:py-4 md:px-10">
                <div className="flex-center h-8 min-w-8 rounded-full bg-edge-purple font-montserrat text-lg font-bold text-white">
                  A
                </div>
                <p className="whitespace-pre-line text-[#4A4A4A]">
                  {highlight(faq.answer, keyword)}
                </p>
              </div>
            </div>
          );
        })}
        {/* ------ */}
      </div>

      {/* 검색 결과 없음 */}
      {filteredFaqList.length === 0 && (
        <p className="mt-8 text-center font-medium text-[#4A4A4A]">
          {keyword ? `‘${keyword}’에 대한 질문이 없어요` : '해당 분류에 질문이 없어요'}
        </p>
      )}

      {/* 문의 안내 */}
      <div className="mb-20 mt-8 flex flex-col items-center gap-4 rounded-2xl bg-edge-yellow px-6 py-8 text-center max-md:mb-10">
        <p className="text-lg font-bold">찾는 답이 없으신가요?</p>
        <Link
          href={KAKAO_CHANNEL_URL}
          target="_blank"
          className="rounded-full bg-[#3C1E1E] px-6 py-3 text-sm font-bold text-white"
        >
          카톡 채널로 문의하기
        </Link>
      </div>
    </div>
  );
}
