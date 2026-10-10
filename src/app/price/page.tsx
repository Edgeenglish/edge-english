import Bubble from '@/components/common/bubble/Bubble';
import Link from 'next/link';
import LongTermPrice from '@/components/LongTermPrice';

export default function PricePage() {
  return (
    <div className="bg-[#F3F6F8] py-[120px] max-md:py-[60px]">
      <div className="mx-auto flex max-w-[1200px] flex-col gap-10">
        {/* 타이틀 */}
      <div className="text-center">
          <p className="font-montserrat text-xl font-semibold text-[#AA96FF] max-md:text-base">
            100% 미국·캐나다·호주 강사만!
          </p>
          <h1 className="mt-4 text-4xl font-bold leading-tight max-md:text-2xl">
            프리미엄 <br /> <span className="text-[#5542A5]">원어민 1:1 화상영어 </span>
            수업료
          </h1>
        </div>

        {/* 수강료 (1개월 / 3개월 / 6개월) */}
        <LongTermPrice />

        {/* 수강 신청하기 버튼 */}
        <div className="w-[228px] self-center text-center">
          <Bubble
            text="회원가입 없이, 30초면 신청 끝"
            bg="#333333"
            textClassName="text-white"
          />

          <Link
            href="https://forms.gle/arWZ6uzK3BFgaxM39"
            target="_blank"
            className="btn mx-auto mt-10 h-14 w-50 rounded-lg border-none bg-[#4A4A4A] px-14 py-5 font-bold text-white"
          >
            수강 신청하기
          </Link>
        </div>
      </div>
    </div>
  );
}
