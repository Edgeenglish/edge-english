'use client';

import { useState } from 'react';
import Link from 'next/link';
import ScrollContainer from 'react-indiana-drag-scroll';
import rawFaqList from '@/data/faqs.json';

const KAKAO_CHANNEL_URL = 'https://pf.kakao.com/_blxgib/friend';

type Faq = (typeof rawFaqList)[number];

// 비슷한 말 묶음 (질문 제목에서만 사용)
const SYNONYM_GROUPS = [
  ['연기', '수강 정지', '정지', '일시정지', '휴강', '홀딩'],
  ['취소', '캔슬', '결석'],
  ['보강', '재수업', '다시 들'],
  ['이월', '남은 수업', '연장'],
  ['결제', '카드', '카드결제', '계좌이체', '입금', '할부'],
  ['영수증', '현금영수증', '수강확인증', '수강증', '소득공제'],
  ['환불'],
  ['줌', 'zoom', '구글미트', '구글 미트', 'google meet', 'meet', '어디에서'],
  ['녹화', '녹음', '녹화본'],
  ['교재', '책', '교과서'],
  ['숙제', '과제'],
  ['레벨', '수준', '초보', '왕초보'],
  ['지각', '늦음', '늦게', '늦을'],
  ['공휴일', '휴일', '명절', '연휴'],
  ['해외', '외국', '출국'],
  ['신청', '등록', '가입'],
  ['강사', '선생님', '튜터', '원어민'],
  ['체험', '무료수업', '트라이얼', '맛보기'],
  ['수강료', '가격', '비용', '요금'],
  ['노트', '수업 노트', '복습', '필기'],
  ['수업 링크', '강의실', '입장', '접속'],
];

// 띄어쓰기와 영어 대소문자 무시
const normalize = (text: string) => text.replace(/\s+/g, '').toLowerCase();

const NORMALIZED_GROUPS = SYNONYM_GROUPS.map((group) => group.map(normalize));

const findSynonyms = (term: string) =>
  NORMALIZED_GROUPS.find((group) => group.includes(term)) ?? [];

// 검색어를 단어로 나눔. 입력 전체가 비슷한 말(예: "남은 수업")이면 한 단어로 취급
function getSearchTerms(keyword: string) {
  const whole = normalize(keyword);
  if (!whole) return [];
  if (findSynonyms(whole).length > 0) return [whole];
  return keyword.split(/\s+/).filter(Boolean).map(normalize);
}

// 0: 질문 제목에서 모두 찾음, 1: 답변에서만 찾은 단어가 있음, null: 해당 없음
function getMatchRank(faq: Faq, terms: string[]) {
  const question = normalize(faq.question);
  const answer = normalize(faq.answer);
  let rank = 0;

  for (const term of terms) {
    const inQuestion =
      question.includes(term) ||
      findSynonyms(term).some((synonym) => question.includes(synonym));
    if (inQuestion) continue;
    if (answer.includes(term)) rank = 1;
    else return null;
  }
  return rank;
}

const escapeRegExp = (text: string) => text.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');

// 입력한 글자를 형광펜 색으로 표시 (띄어쓰기·대소문자 무시)
function highlight(text: string, terms: string[]) {
  if (terms.length === 0) return text;
  const pattern = [...terms]
    .sort((a, b) => b.length - a.length)
    .map((term) => Array.from(term).map(escapeRegExp).join('\\s*'))
    .join('|');
  const parts = text.split(new RegExp(`(${pattern})`, 'gi'));
  return parts.map((part, i) =>
    i % 2 === 1 ? (
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
  const terms = getSearchTerms(keyword);
  // 검색 중에는 ALL 버튼만 선택된 것처럼 표시
  const activeType = terms.length > 0 ? 'all' : currentType;

  // 검색 중에는 분류와 상관없이 전체 FAQ에서 찾고, 질문 제목 일치 결과를 먼저 보여 줌
  const filteredFaqList =
    terms.length > 0
      ? rawFaqList
          .map((faq) => ({ faq, rank: getMatchRank(faq, terms) }))
          .filter((item): item is { faq: Faq; rank: number } => item.rank !== null)
          .sort((a, b) => a.rank - b.rank)
          .map((item) => item.faq)
      : rawFaqList.filter(
          (faq) => currentType === 'all' || faq.type.includes(currentType)
        );

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
          className={`h-fit text-nowrap rounded-full px-4 py-2 text-sm font-bold max-md:px-4 max-md:py-2 ${activeType === 'all' ? 'bg-edge-yellow' : 'border'}`}
          onClick={() => setCurrentType('all')}
        >
          ALL
        </button>
        <button
          className={`h-fit text-nowrap rounded-full px-4 py-2 text-sm font-bold max-md:px-4 max-md:py-2 ${activeType === '수강 신청' ? 'bg-edge-yellow' : 'border'}`}
          onClick={() => setCurrentType('수강 신청')}
        >
          수강 신청
        </button>
        <button
          className={`h-fit text-nowrap rounded-full px-4 py-2 text-sm font-bold max-md:px-4 max-md:py-2 ${activeType === '수업 관련' ? 'bg-edge-yellow' : 'border'}`}
          onClick={() => setCurrentType('수업 관련')}
        >
          수업 관련
        </button>
        <button
          className={`h-fit text-nowrap rounded-full px-4 py-2 text-sm font-bold max-md:px-4 max-md:py-2 ${activeType === '수강권' ? 'bg-edge-yellow' : 'border'}`}
          onClick={() => setCurrentType('수강권')}
        >
          수강권
        </button>
        <button
          className={`h-fit text-nowrap rounded-full px-4 py-2 text-sm font-bold max-md:px-4 max-md:py-2 ${activeType === '결제' ? 'bg-edge-yellow' : 'border'}`}
          onClick={() => setCurrentType('결제')}
        >
          결제
        </button>
        <button
          className={`h-fit text-nowrap rounded-full px-4 py-2 text-sm font-bold max-md:px-4 max-md:py-2 ${activeType === '기타' ? 'bg-edge-yellow' : 'border'}`}
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
                <p className="font-medium">{highlight(faq.question, terms)}</p>
              </div>
              <div className="collapse-content flex items-center gap-6 bg-[#FCFCFC] text-sm peer-checked:py-4 md:px-10">
                <div className="flex-center h-8 min-w-8 rounded-full bg-edge-purple font-montserrat text-lg font-bold text-white">
                  A
                </div>
                <p className="whitespace-pre-line text-[#4A4A4A]">
                  {highlight(faq.answer, terms)}
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
