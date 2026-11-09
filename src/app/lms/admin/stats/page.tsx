import { AdminHeader, BottomNav } from '../ui';

// 통계 (대시보드 5차 시안: 메뉴만, 화면은 준비 중)
export default function StatsPage() {
  return (
    <div className="mx-auto min-h-dvh max-w-[1280px] pb-24 lg:pb-8">
      <AdminHeader active="stats" demo={false} />
      <div className="px-4 pt-3 lg:px-7 lg:pt-5">
        <section className="grid place-items-center rounded-[14px] border border-[#e6e3ef] bg-white py-20 text-center">
          <b className="text-[18px] text-[#1d1b2b]">통계</b>
          <span className="text-[14px] text-[#6b6880]">준비 중</span>
        </section>
      </div>
      <BottomNav active="stats" demo={false} />
    </div>
  );
}
