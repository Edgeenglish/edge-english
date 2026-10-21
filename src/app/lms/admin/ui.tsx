// 운영자 화면 공통: 아이콘, 위쪽 메뉴(PC), 아래 탭(휴대폰)
// ?demo=1(가상 데이터 미리보기)을 메뉴 이동 때도 유지한다

import Link from 'next/link';

const PATHS = {
  home: 'M3 11l9-7 9 7v9a1 1 0 0 1-1 1h-5v-6H9v6H4a1 1 0 0 1-1-1z',
  calendar: 'M5 4h14a2 2 0 0 1 2 2v13a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V6a2 2 0 0 1 2-2zM8 2v4M16 2v4M3 10h18',
  users: 'M16 21v-2a4 4 0 0 0-4-4H6a4 4 0 0 0-4 4v2M9 11a4 4 0 1 0 0-8 4 4 0 0 0 0 8zM22 21v-2a4 4 0 0 0-3-3.87M16 3.13a4 4 0 0 1 0 7.75',
  userPlus: 'M16 21v-2a4 4 0 0 0-4-4H5a4 4 0 0 0-4 4v2M8.5 11a4 4 0 1 0 0-8 4 4 0 0 0 0 8zM20 8v6M23 11h-6',
  clock: 'M12 22a10 10 0 1 0 0-20 10 10 0 0 0 0 20zM12 6v6l4 2',
  hourglass: 'M6 2h12M6 22h12M7 2v4l5 6-5 6v4M17 2v4l-5 6 5 6v4',
  repeat: 'M17 1l4 4-4 4M3 11V9a4 4 0 0 1 4-4h14M7 23l-4-4 4-4M21 13v2a4 4 0 0 1-4 4H3',
  alert: 'M10.29 3.86 1.82 18a2 2 0 0 0 1.71 3h16.94a2 2 0 0 0 1.71-3L13.71 3.86a2 2 0 0 0-3.42 0zM12 9v4M12 17h.01',
  search: 'M11 19a8 8 0 1 0 0-16 8 8 0 0 0 0 16zM21 21l-4.35-4.35',
  chart: 'M3 3v18h18M7 15l4-4 3 3 5-6',
  more: 'M5 12h.01M12 12h.01M19 12h.01',
  chevron: 'M9 18l6-6-6-6',
} as const;

export type IconName = keyof typeof PATHS;

export function Icon({ name, className = 'h-5 w-5' }: { name: IconName; className?: string }) {
  return (
    <svg aria-hidden viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth={2} strokeLinecap="round" strokeLinejoin="round" className={className}>
      {/* globals.css 의 '* { color }' 때문에 path 가 부모 색을 잃지 않도록 */}
      <path d={PATHS[name]} style={{ color: 'inherit' }} />
    </svg>
  );
}

export type AdminTab = 'home' | 'schedule' | 'students';

const TABS: { key: AdminTab; label: string; href: string; icon: IconName }[] = [
  { key: 'home', label: '홈', href: '/lms/admin', icon: 'home' },
  { key: 'schedule', label: '일정', href: '/lms/admin/schedule', icon: 'calendar' },
  { key: 'students', label: '학생', href: '/lms/admin/students', icon: 'users' },
];

const withDemo = (href: string, demo: boolean) => (demo ? `${href}?demo=1` : href);

/** PC 위쪽 메뉴 (휴대폰에서는 숨김 — 아래 탭 사용) */
export function TopNav({ active, demo }: { active: AdminTab; demo: boolean }) {
  return (
    <nav aria-label="운영 메뉴" className="hidden gap-1 lg:flex">
      {TABS.map((t) => (
        <Link
          key={t.key}
          href={withDemo(t.href, demo)}
          aria-current={active === t.key ? 'page' : undefined}
          className={`flex min-h-[38px] items-center gap-1.5 rounded-[10px] px-3 text-[13.5px] font-semibold ${
            active === t.key ? 'bg-[#efebff] text-[#5b3fe0]' : 'text-[#6b6880]'
          }`}
        >
          <Icon name={t.icon} className="h-[18px] w-[18px]" />
          {t.label}
        </Link>
      ))}
    </nav>
  );
}

/** 휴대폰 아래 탭 */
export function BottomNav({ active, demo }: { active: AdminTab; demo: boolean }) {
  return (
    <nav aria-label="메뉴" className="fixed inset-x-0 bottom-0 z-10 grid grid-cols-3 border-t border-[#e6e3ef] bg-white lg:hidden">
      {TABS.map((t) => (
        <Link
          key={t.key}
          href={withDemo(t.href, demo)}
          aria-current={active === t.key ? 'page' : undefined}
          className={`flex min-h-[54px] flex-col items-center justify-center gap-0.5 text-[12px] font-semibold ${active === t.key ? 'text-[#7d5fff]' : 'text-[#6b6880]'}`}
        >
          <Icon name={t.icon} />
          {t.label}
        </Link>
      ))}
    </nav>
  );
}

/** 운영자 화면 위쪽 막대 */
export function AdminHeader({ active, demo, right }: { active: AdminTab; demo: boolean; right?: React.ReactNode }) {
  return (
    <header className="sticky top-0 z-10 flex items-center gap-3 border-b border-[#e6e3ef] bg-white px-4 py-3 lg:px-7">
      <span className="text-[15px] font-extrabold tracking-tight text-[#09246b]">
        Edge<span className="text-[#7d5fff]">English</span> <span className="text-[#09246b]">운영</span>
      </span>
      <TopNav active={active} demo={demo} />
      <span className="flex-1" />
      {right}
    </header>
  );
}
