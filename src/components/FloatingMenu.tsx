'use client';

import Link from 'next/link';
import { usePathname } from 'next/navigation';

export default function FloatingMenu() {
  const pathName = usePathname();

  const scrollToTop = () => {
    window.scrollTo({
      top: 0,
      behavior: 'smooth', // 부드럽게 스크롤
    });
  };

  return (
    <div>
      {pathName === '/' && (
        <a
          href="https://forms.gle/cj9Ws5z3JoTwBT1U9"
            target="_blank"
            rel="noopener noreferrer"
          className="fixed bottom-4 left-1/2 z-[1] -translate-x-1/2 whitespace-nowrap rounded-full bg-edge-yellow px-6 py-3 font-semibold"
        >
          수강 신청하기
        </a>
      )}
      <div className="fixed bottom-[4.5rem] right-4.5 z-[19] flex flex-col gap-2 xs:bottom-10 xs:right-10">
        {/* 카카오 버튼 */}
        <Link
          href="https://pf.kakao.com/_blxgib/friend"
          target="_blank"
          className="rounded-full border-2 border-white bg-[#FFEB3B] p-[11px]"
          style={{ boxShadow: '0px 0px 10px 0px rgba(0, 0, 0, 0.11)' }}
        >
          <img
            src="/icons/floating/kakao-btn.svg"
            alt="kakao channel button"
            width={24}
            height={24}
          />
        </Link>

        {/* top 버튼 */}
        <button
          onClick={scrollToTop}
          className="rounded-full border border-[#F3F3F3] bg-white p-[11px]"
          style={{ boxShadow: '0px 0px 10px 0px rgba(0, 0, 0, 0.11)' }}
        >
          <img
            src="/icons/floating/top-btn.svg"
            alt="move to top button"
            width={24}
            height={24}
          />
        </button>
      </div>
    </div>
  );
}
