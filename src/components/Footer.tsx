import Link from 'next/link';
import TextDivider from './TextDivider';

export default function Footer() {
  return (
    <footer className="flex-center px-4 py-15 max-md:pt-10">
      <div className="w-full max-w-[1200px]">
        {/* 로고 */}
        {/* <Link href="/" className="inline-block">
          <img src="/images/logo.svg" alt="logo" width={80} height={24} />
        </Link> */}

        <p className="text-edge-gray">탠저린 영어</p>

        <div className="mt-4 flex items-center text-sm max-md:hidden">
          <p className="text-edge-gray">대표 : 이진솔</p>
          <TextDivider />
          <p className="text-edge-gray">
            문의 이메일 :{' '}
            <span className="font-montserrat text-edge-gray">support@edgeenglish.kr</span>
          </p>
        </div>

        <div className="mt-2 flex items-center text-sm text-edge-gray max-md:mt-1 max-md:hidden">
          <p className="text-edge-gray">
            주소 : [21345] 인천광역시 부평구 길주남로 143, 103동{' '}
          </p>
          <TextDivider />
          <p className="text-edge-gray">
            사업자등록번호 :{' '}
            <span className="font-montserrat text-edge-gray">897-75-00421</span>{' '}
          </p>
        </div>

        <div className="mt-2 flex items-center text-sm text-edge-gray max-md:mt-1 max-md:hidden">
          <p className="text-edge-gray">
            통신판매업 신고 : 신고 면제 사업자 (공정거래위원회 고시 기준){' '}
          </p>
          <TextDivider />
          <p className="text-edge-gray">
            개인정보 보호책임자 :{' '}
            <span className="font-montserrat text-edge-gray">이진솔</span>{' '}
          </p>
        </div>

        {/* 모바일 */}
        <div className="mt-4 text-sm md:hidden">
          <p className="text-edge-gray">대표 : 이진솔</p>
          <p className="mt-1 text-edge-gray">
            문의 이메일 :{' '}
            <span className="font-montserrat text-edge-gray">support@edgeenglish.kr</span>
          </p>
          <p className="mt-1 text-edge-gray">
            주소 : [21345] 인천광역시 부평구 길주남로 143, 103동{' '}
          </p>
          <p className="mt-1 text-edge-gray">
            사업자등록번호 :{' '}
            <span className="font-montserrat text-edge-gray">897-75-00421</span>{' '}
          </p>
          <p className="mt-1 text-edge-gray">
            통신판매업 신고 : 신고 면제 사업자 (공정거래위원회 고시 기준){' '}
          </p>
          <p className="mt-1 text-edge-gray">
            개인정보 보호책임자 :{' '}
            <span className="font-montserrat text-edge-gray">이진솔</span>{' '}
          </p>
        </div>

        <div className="mt-8 max-md:mt-6">
          <p className="font-montserrat text-[13px] text-edge-gray">
            copyright © 탠저린 영어 all rights reserved.
          </p>
        </div>

        <div className="mt-4">
          {/* <p className="font-montserrat text-lg font-extrabold leading-none text-edge-gray">
            010-5012-1553
          </p> */}
          <p className="mt-2 text-sm text-edge-gray">
            평일 09:00 ~ 18:00(점심시간 12:00~13:00), 주말/공휴일 휴무
          </p>
        </div>

        {/* sns */}
        <div className="mt-8 flex gap-3">
          <Link href="https://pf.kakao.com/_blxgib" target="_blank">
            <img src="/icons/footer/kakao.svg" alt="kakao" width={40} height={40} />
          </Link>
          <Link href="https://www.instagram.com/tangerine_english_" target="_blank">
            <img
              src="/icons/footer/instagram.svg"
              alt="instagram"
              width={40}
              height={40}
            />
          </Link>
          <Link href="/">
            <img src="/icons/footer/youtube.svg" alt="youtube" width={40} height={40} />
          </Link>
        </div>
      </div>
    </footer>
  );
}
