'use client';

import Link from 'next/link';
import { usePathname } from 'next/navigation';
import { useState } from 'react';
import BubbleRightTail from './common/bubble/BubbleRightTail';
import BubbleTopTail from './common/bubble/BubbleTopTail';

export default function Header() {
  const pathName = usePathname();
  const [isDrawerOpen, setIsDrawerOpen] = useState(false);

  const closeDrawer = () => setIsDrawerOpen(false);

  return (
    <header className="flex-center sticky top-0 z-20 min-h-[70px] bg-white px-4 py-4">
      <div className="flex w-full items-center gap-12">
        <Link href="/">
          <img
            src="/images/logo.svg"
            alt="logo"
            className="min-w-20"
            width={80}
            height={24}
          />
        </Link>

        <div className="flex w-full items-center justify-between">
          <div className="flex gap-11 max-xl:gap-7 max-lg:gap-6 max-md:hidden">
            <Link
              href="/events"
              className={`text-nowrap ${pathName.startsWith('/events') ? 'font-bold' : 'font-medium text-edge-light'}`}
            >
              이벤트
            </Link>

            <Link
              href="/reviews"
              className={`text-nowrap ${pathName.startsWith('/reviews') ? 'font-bold' : 'font-medium text-edge-light'}`}
            >
              수강후기
            </Link>

            <Link
              href="/notice"
              className={`text-nowrap ${pathName.startsWith('/notice') ? 'font-bold' : 'font-medium text-edge-light'}`}
            >
              공지사항
            </Link>

            <Link
              href="/tutors"
              className={`text-nowrap ${pathName.startsWith('/tutors') ? 'font-bold' : 'font-medium text-edge-light'}`}
            >
              강사진
            </Link>

            <Link
              href="/books"
              className={`text-nowrap ${pathName.startsWith('/books') ? 'font-bold' : 'font-medium text-edge-light'}`}
            >
              교재
            </Link>

            <Link
              href="/faq"
              className={`text-nowrap ${pathName.startsWith('/faq') ? 'font-bold' : 'font-medium text-edge-light'}`}
            >
              자주 묻는 질문
            </Link>

            <Link
              href="/price"
              className={`text-nowrap ${pathName.startsWith('/price') ? 'font-bold' : 'font-medium text-edge-light'}`}
            >
              수업료
            </Link>
          </div>

          <div className="relative flex gap-2 max-md:hidden">
            <div className="max-lg:hidden">
              <BubbleRightTail
                text="회원가입 없이 간편 신청하기"
                bg="#1A1A1A"
                left={-205}
                top={4}
                textClassName="text-white text-sm"
              />
            </div>

            <Link
              href="https://forms.gle/arWZ6uzK3BFgaxM39"
              target="_blank"
              className="btn rounded-lg border-none bg-edge-yellow text-sm font-semibold text-[#333]"
            >
              수강신청
            </Link>
          </div>
        </div>
        {/* 모바일 햄버거 메뉴 */}
        <div className="drawer drawer-end min-h-8 w-auto min-w-8 md:hidden">
          <input
            id="hamburger-menu"
            type="checkbox"
            className="drawer-toggle"
            checked={isDrawerOpen}
            onChange={() => setIsDrawerOpen(!isDrawerOpen)}
          />
          <div className="drawer-content">
            <label htmlFor="hamburger-menu">
              <img
                alt="mobile hamburger menu icon"
                src="/icons/mobile-menu.svg"
                className="cursor-pointer"
                width={32}
                height={32}
              />
            </label>
          </div>
          <div className="drawer-side z-30">
            <label
              htmlFor="hamburger-menu"
              aria-label="close sidebar"
              className="drawer-overlay"
            />
            <ul className="menu min-h-full w-80 bg-white p-4 text-base-content">
              {/* 헤더 */}
              <li>
                <div className="flex justify-between hover:bg-white">
                  <Link href="/">
                    <img src="/images/logo.svg" alt="logo" width={80} height={24} />
                  </Link>
                  <img
                    alt="x icon"
                    src="/icons/x-btn.svg"
                    onClick={() => closeDrawer()}
                    width={32}
                    height={32}
                  />
                </div>
              </li>

              <li>
                <Link
                  href="/events"
                  className={`active:bg-white! text-nowrap py-4 text-[22px] font-bold ${pathName.startsWith('/events') ? 'text-edge-yellow' : ''}`}
                  onClick={() => closeDrawer()}
                >
                  이벤트
                </Link>
              </li>

              <li>
                <Link
                  href="/reviews"
                  className={`text-nowrap py-4 text-[22px] font-bold ${pathName.startsWith('/reviews') ? 'text-edge-yellow' : ''}`}
                  onClick={() => closeDrawer()}
                >
                  수강후기
                </Link>
              </li>

              <li>
                <Link
                  href="/notice"
                  className={`text-nowrap py-4 text-[22px] font-bold ${pathName.startsWith('/notice') ? 'text-edge-yellow' : ''}`}
                  onClick={() => closeDrawer()}
                >
                  공지사항
                </Link>
              </li>

              <li>
                <Link
                  href="/tutors"
                  className={`text-nowrap py-4 text-[22px] font-bold ${pathName.startsWith('/tutors') ? 'text-edge-yellow' : ']'}`}
                  onClick={() => closeDrawer()}
                >
                  강사진
                </Link>
              </li>

              <li>
                <Link
                  href="/books"
                  className={`text-nowrap py-4 text-[22px] font-bold ${pathName.startsWith('/books') ? 'text-edge-yellow' : ''}`}
                  onClick={() => closeDrawer()}
                >
                  교재
                </Link>
              </li>

              <li>
                <Link
                  href="/faq"
                  className={`text-nowrap py-4 text-[22px] font-bold ${pathName.startsWith('/faq') ? 'text-edge-yellow' : ''}`}
                  onClick={() => closeDrawer()}
                >
                  자주 묻는 질문
                </Link>
              </li>

              <li>
                <Link
                  href="/price"
                  className={`text-nowrap py-4 text-[22px] font-bold ${pathName.startsWith('/price') ? 'text-edge-yellow' : ''}`}
                  onClick={() => closeDrawer()}
                >
                  수업료
                </Link>
              </li>

              <li className="flex flex-row gap-2 py-8">
                <Link
                  href="https://forms.gle/arWZ6uzK3BFgaxM39"
                  target="_blank"
                  className="btn flex-1 rounded-lg border-none bg-edge-yellow text-sm font-semibold text-[#333]"
                >
                  수강신청
                </Link>
                <BubbleTopTail
                  text="30초 만에 시작하기!"
                  bg="#1A1A1A"
                  left={3}
                  top={84}
                  textClassName="text-white text-xs font-semibold"
                />
              </li>
            </ul>
          </div>
        </div>
      </div>
    </header>
  );
}
