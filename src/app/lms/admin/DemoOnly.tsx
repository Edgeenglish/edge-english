import Link from 'next/link';

// 실제 데이터 연결 전 화면: 가상 미리보기로 안내 (가상 데이터를 실제처럼 보여 주지 않음)
export default function DemoOnly({ href, title }: { href: string; title: string }) {
  return (
    <main className="mx-auto max-w-[480px] px-6 py-16 text-center">
      <p className="text-[18px] font-bold text-[#1d1b2b]">{title}</p>
      <p className="mt-2 text-[14px] leading-relaxed text-[#6b6880]">이 화면은 아직 실제 데이터에 연결하기 전이에요. 화면 모양은 가상 데이터 미리보기로 볼 수 있어요.</p>
      <Link href={`${href}?demo=1`} className="mt-5 inline-flex min-h-[44px] items-center rounded-[12px] bg-[#7d5ffb] px-5 text-[14px] font-semibold text-white">
        가상 미리보기 보기
      </Link>
    </main>
  );
}
