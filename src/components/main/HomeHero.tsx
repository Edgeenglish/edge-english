import Link from 'next/link';

// 홈 첫 화면 (대표 11/25 시안 확정): 운영진 사진 + 레벨테스트 입구 + 실제 숫자 3개
const ICON = { fill: 'none', stroke: 'currentColor', strokeWidth: 1.7, strokeLinecap: 'round', strokeLinejoin: 'round' } as const;

const STATS = [
  {
    big: '13년+',
    small: '영어 교육 경력',
    icon: (
      <svg viewBox="0 0 24 24" aria-hidden="true" {...ICON}>
        <path d="m2 9 10-5 10 5-10 5z" />
        <path d="M6 11.5V16c0 1.4 2.7 3 6 3s6-1.6 6-3v-4.5" />
        <path d="M22 9v6" />
      </svg>
    ),
  },
  {
    big: '800만+',
    small: '영어 콘텐츠 누적 조회수',
    icon: (
      <svg viewBox="0 0 24 24" aria-hidden="true" {...ICON}>
        <circle cx="12" cy="12" r="9" />
        <path d="m10 8.5 5 3.5-5 3.5z" />
      </svg>
    ),
  },
  {
    big: '5단계 검증',
    small: '운영진이 직접 면접 보고 교육까지',
    icon: (
      <svg viewBox="0 0 24 24" aria-hidden="true" {...ICON}>
        <path d="M12 3 4.5 6v5.5c0 4.6 3 8 7.5 9.5 4.5-1.5 7.5-4.9 7.5-9.5V6z" />
        <path d="m9 12 2.2 2.2L15.5 10" />
      </svg>
    ),
  },
];

export default function HomeHero() {
  return (
    <section className="mx-auto mb-[120px] mt-6 max-w-[1120px] px-8 text-[#140F33] max-md:mb-20 max-md:mt-3 max-md:px-4">
      <div className="grid grid-cols-[1.05fr_.95fr] items-center gap-7 max-md:grid-cols-1 max-md:gap-[18px]">
        <div className="[word-break:keep-all]">
          <span className="inline-flex items-center gap-2 rounded-full bg-[#efebff] px-4 py-[9px] text-[15px] font-bold text-[#4a2fd6] max-md:px-3 max-md:py-[7px] max-md:text-[13px]">
            <img src="/images/main/flag.png" alt="" width={42} height={22} className="h-[22px] w-auto max-md:h-4" />
            미국·캐나다·호주 원어민 강사진
          </span>
          <h1 className="mt-5 text-[46px] font-extrabold !leading-[1.25] tracking-[-0.02em] max-md:mt-3.5 max-md:text-[29px]">
            영어를 가르치는 사람들이
            <br />
            <u className="no-underline [background:linear-gradient(transparent_82%,#7d5fff_82%,#7d5fff_90%,transparent_90%)]">직접 만든</u> 화상영어.
          </h1>
          <p className="mt-[18px] text-[17.5px] !leading-[1.65] text-[#3d3a52] max-md:mt-3 max-md:text-[15px]">
            성인 전문 1:1 원어민 화상영어.
            <br />
            강사 선발부터 수업 관리까지
            <br className="md:hidden" /> 영어 교육 전문가 두 사람이 직접 챙겨요.
          </p>
        </div>

        <figure className="relative m-0">
          <img
            src="/images/main/founders.webp"
            alt="엣지영어를 만든 사람들"
            width={1400}
            height={1050}
            fetchPriority="high"
            className="block h-auto w-full rounded-[26px] max-md:rounded-[20px]"
          />
          <figcaption className="absolute bottom-3.5 right-3.5 rounded-[14px] bg-white/90 px-3.5 py-2 text-center text-[12.5px] leading-[1.45]">
            엣지영어를 만든 사람들
            <br />
            <b>시에나 &amp; 탠저린</b>
          </figcaption>
        </figure>
      </div>

      <ul className="m-0 mt-7 grid list-none grid-cols-3 p-0 max-md:mx-2.5 max-md:mt-5">
        {STATS.map((s, i) => (
          <li
            key={s.big}
            className={`flex items-center justify-center gap-3.5 px-2 py-1.5 max-md:flex-col max-md:gap-1.5 max-md:px-1 max-md:text-center ${i > 0 ? 'border-l border-[#e6e3ef]' : ''}`}
          >
            <i className="block size-11 shrink-0 text-[#5b3df0] max-md:size-[30px]">{s.icon}</i>
            <span className="[word-break:keep-all]">
              <b className="block text-[30px] font-extrabold leading-[1.1] text-[#3b1fd0] max-md:text-[22px]">{s.big}</b>
              <small className="mt-0.5 block text-[14.5px] text-[#4a4760] max-md:text-[11.5px] max-md:leading-[1.35]">{s.small}</small>
            </span>
          </li>
        ))}
      </ul>

      <div className="mt-[26px] flex items-center justify-between gap-4 rounded-[22px] bg-[#efebff] px-[30px] py-[22px] max-md:mt-5 max-md:flex-col max-md:items-stretch max-md:rounded-[18px] max-md:p-[18px]">
        <p className="m-0 text-2xl font-extrabold leading-[1.4] max-md:text-xl">
          <b className="text-[#5b3df0]">무료 레벨테스트</b>하면
          <br />
          부족한 부분만 콕 짚어 드려요
        </p>
        <Link
          href="/level-test"
          className="shrink-0 whitespace-nowrap rounded-[14px] bg-[#5b3df0] px-8 py-4 text-center text-lg font-bold text-white max-md:px-4 max-md:py-3.5 max-md:text-base"
        >
          지금 시작하기
        </Link>
      </div>
    </section>
  );
}
