// 홈: 강사 채용 과정 5단계 (대표 11/25 시안 확정 — 리스트형 + 아이콘 + 5단계 강조)
const STEPS = [
  {
    title: '서면 인터뷰',
    desc: '기본 역량과 소통 능력 확인',
    icon: (
      <>
        <path d="M4 5h10a2 2 0 0 1 2 2v5a2 2 0 0 1-2 2H9l-4 3v-3H4a2 2 0 0 1-2-2V7a2 2 0 0 1 2-2z" />
        <path d="M18 9h2a2 2 0 0 1 2 2v5a2 2 0 0 1-2 2h-1v3l-4-3h-3" />
      </>
    ),
  },
  {
    title: '서류 심사',
    desc: '영어 교사 자격증·학위·티칭 경력 검증',
    icon: (
      <>
        <path d="M14 3H7a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2V8z" />
        <path d="M14 3v5h5" />
        <path d="m9 14 2 2 4-4" />
      </>
    ),
  },
  {
    title: '2:1 심층 면접',
    desc: '운영진 두 명이 직접 대화하고 꼼꼼하게 검증해요',
    icon: (
      <>
        <circle cx="9" cy="8" r="3.2" />
        <path d="M3 20c0-3.3 2.7-6 6-6s6 2.7 6 6" />
        <circle cx="17" cy="9" r="2.4" />
        <path d="M16 14.2c2.9.2 5 2.4 5 5.8" />
      </>
    ),
  },
  {
    title: '데모 레슨',
    desc: '티칭 실력은 물론, 책임감과 인성을 무엇보다 중요하게 봐요',
    icon: (
      <>
        <rect x="2.5" y="6" width="13" height="12" rx="2.5" />
        <path d="m15.5 10.5 6-3.5v10l-6-3.5z" />
      </>
    ),
  },
  {
    title: '채용 후 교육',
    desc: '직접 교육하고 2개월 집중 모니터링해요. 이 기간에도 탈락할 수 있어요',
    last: true,
    icon: (
      <>
        <path d="M12 3 4.5 6v5.5c0 4.6 3 8 7.5 9.5 4.5-1.5 7.5-4.9 7.5-9.5V6z" />
        <path d="m9 12 2.2 2.2L15.5 10" />
      </>
    ),
  },
];

export default function TutorHiring() {
  return (
    <section className="bg-[#F4F5F8] px-4.5 py-24 max-md:py-15">
      <div className="mx-auto max-w-[720px]">
        <p className="text-center text-base text-[#5D5A73] max-md:text-sm">
          좋은 선생님을 만나는 일, 엣지영어가 먼저 고민해요.
        </p>
        <h3 className="mt-2 text-center text-4xl font-bold !leading-snug text-[#17142B] max-md:text-2xl">
          운영진 둘이 직접
          <span className="md:hidden">
            <br />
          </span>{' '}
          면접 보고 골라요
        </h3>
        <p className="mt-3 text-center text-lg text-[#5D5A73] max-md:text-[15px]">
          모든 강사를 운영진 두 명이 직접 만나고, 고민 끝에 뽑아요.
        </p>

        <ol className="mt-10 flex flex-col gap-2.5 max-md:mt-7">
          {STEPS.map((s, i) => (
            <li
              key={s.title}
              className={`flex items-center gap-3 rounded-2xl px-4 py-3.5 ${s.last ? 'bg-[#ECE7FF]' : 'bg-white'}`}
            >
              <span className="grid size-7 shrink-0 place-items-center rounded-full bg-edge-purple text-sm font-bold text-white">
                {i + 1}
              </span>
              <svg
                viewBox="0 0 24 24"
                fill="none"
                stroke="currentColor"
                strokeWidth="1.8"
                strokeLinecap="round"
                strokeLinejoin="round"
                aria-hidden="true"
                className="size-6 shrink-0 text-edge-purple"
              >
                {s.icon}
              </svg>
              <span className="min-w-0">
                <span className="block text-lg font-bold text-[#17142B] max-md:text-base">{s.title}</span>
                <span className="mt-0.5 block text-base leading-snug text-[#5D5A73] max-md:text-sm">{s.desc}</span>
              </span>
            </li>
          ))}
        </ol>
      </div>
    </section>
  );
}
