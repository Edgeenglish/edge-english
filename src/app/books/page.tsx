'use client';

import { BookType } from '@/types/BookType';
import BookList from '../../components/books/BookList';
import rawBookList from '@/data/books.json';

const LEVEL_LIST = [
  {
    simbol: 'bronze',
    level: '입문 Beginner',
    describe: '기본적인 의사소통은 가능하지만 단어 위주로 뜨문뜨문 말해요',
  },
  {
    simbol: 'silver',
    level: '초급 Low-Intermediate',
    describe: '간단한 문장은 만들 수 있지만, 말이 길어지면 단어가 막 헷갈려요',
  },
  {
    simbol: 'gold',
    level: '중급 Intermediate',
    describe: '관계대명사나 구동사도 조금씩 말할 수 있고, 문장도 길어져요',
  },
  {
    simbol: 'platinum',
    level: '고급 Advanced',
    describe: '원어민과 토론도 가능하고, would, could 같은 표현도 자연스럽게 써요',
  },
];

export default function BooksPage() {
  const bookList = rawBookList as BookType[];

  return (
    <div>
      {/* 지금 내 영어 레벨, 어디쯤일까요? */}
      <div className="bg-[#F3F6F8] px-4 py-[60px]">
        <div className="mx-auto max-w-[912px]">
          <h1 className="text-center text-[32px] font-bold">
            지금 내 영어 레벨,
            <span className="md:hidden">
              <br />
            </span>
            어디쯤일까요?
          </h1>

          {/* 레벨 */}
          <div className="mt-8">
            <div className="grid grid-cols-2 gap-4">
              {LEVEL_LIST.map((item, idx) => (
                <div className="rounded border bg-white px-6 py-4" key={idx}>
                  <div className="items-center gap-2 break-words text-lg font-semibold md:flex">
                    <img
                      src={`/icons/books/${item.simbol}.png`}
                      alt={`${item.simbol} icon`}
                      width={32}
                      height={32}
                    />
                    <h2 className="mt-2">{item.level}</h2>
                  </div>
                  <p className="pt-2">{item.describe}</p>
                </div>
              ))}
            </div>
          </div>

          <p className="mt-6 text-center text-lg font-medium text-[#777777] max-md:text-base">
            수강 중 언제든지 교재를 변경할 수 있어요.{' '}
            <span className="md:hidden">
              <br />
            </span>
            부담 없이 시작해보세요!
          </p>
        </div>
      </div>

      <div className="mx-auto max-w-[1200px] px-4">
        <div className="mt-15 border-b border-[#A4A4A4] max-md:mt-16">
          <h1 className="pb-3 text-4xl font-bold max-md:text-[40px]">교재 소개</h1>
        </div>

        <div className="mt-12">
          <BookList bookList={bookList} />
        </div>
      </div>
    </div>
  );
}
