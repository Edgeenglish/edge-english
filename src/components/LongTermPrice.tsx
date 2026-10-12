'use client';

import { useState } from 'react';
import Bubble from '@/components/common/bubble/Bubble';

// ===== 엣지영어 수업료 (1개월 / 3개월 / 6개월) =====
// 수강료가 바뀌면 아래 PRICES의 1개월 가격 숫자만 고치면 돼요.
// 3개월·6개월 가격은 자동으로 계산돼요. (3개월: 5% 할인 / 6개월: 5% 할인 + 5만 원 추가 할인)

type Plan = 1 | 3 | 6;

const PRICES = [
  {
    minutes: '20',
    headerClass: 'rounded-t-2xl bg-edge-purple p-6',
    titleClass: 'text-2xl font-extrabold text-white max-md:text-base',
    numberClass: 'font-montserrat text-white',
    badgeClass: 'text-nowrap rounded bg-[#FFEDB8] p-2 font-medium max-md:text-xs',
    rows: [
      { label: '주 2회', count: 8, monthly: 178000 },
      { label: '주 3회', count: 12, monthly: 249000 },
      { label: '주 5회', count: 20, monthly: 370000 },
    ],
  },
  {
    minutes: '40',
    headerClass: 'rounded-t-2xl bg-edge-yellow p-6',
    titleClass: 'text-2xl font-extrabold max-md:text-base',
    numberClass: 'font-montserrat',
    badgeClass: 'text-nowrap rounded bg-[#7D5FFF1A] p-2 font-medium max-md:text-xs',
    rows: [
      { label: '주 2회', count: 8, monthly: 290000 },
      { label: '주 3회', count: 12, monthly: 420000, popular: true },
      { label: '주 5회', count: 20, monthly: 695000 },
    ],
  },
  {
    minutes: '50',
    headerClass: 'rounded-t-2xl bg-[#09246B] p-6',
    titleClass: 'text-2xl font-extrabold text-white max-md:text-base',
    numberClass: 'font-montserrat text-white',
    badgeClass: 'text-nowrap rounded bg-[#09246B1A] p-2 font-medium max-md:text-xs',
    rows: [
      { label: '주 1회', count: 4, monthly: 195000 },
      { label: '주 2회', count: 8, monthly: 355000 },
      { label: '주 3회', count: 12, monthly: 520000 },
    ],
  },
];

const ROW_BORDERS = [
  'flex items-center justify-between gap-3 border-x border-[#ddd] p-6',
  'flex items-center justify-between gap-3 border-x border-t border-[#ddd] p-6',
  'flex items-center justify-between gap-3 rounded-b-2xl border border-[#ddd] p-6',
];

const won = (n: number) => n.toLocaleString('ko-KR');

function calc(monthly: number, plan: Plan) {
  const regular = monthly * plan;
  if (plan === 1) return { regular, price: regular, perMonth: regular, save: 0 };
  let price = Math.round(regular * 0.95);
  if (plan === 6) price -= 50000;
  return { regular, price, perMonth: Math.round(price / plan), save: regular - price };
}

const TABS: { plan: Plan; title: string; sub: string; hot?: boolean }[] = [
  { plan: 1, title: '1개월', sub: '정가' },
  { plan: 3, title: '3개월', sub: '5% 할인' },
  { plan: 6, title: '6개월 혜택가', sub: '5% 할인 + 5만 원 추가 할인', hot: true },
];

function PopularBadge() {
  return (
    <div className="absolute -left-px -top-px flex items-center gap-1 whitespace-nowrap rounded-br-lg bg-edge-purple px-2.5 py-1 text-xs font-extrabold text-white">
      <svg xmlns="http://www.w3.org/2000/svg" width="12" height="12" viewBox="0 0 17 16" fill="none">
        <path
          d="M14.9751 7.17815L12.1626 9.60502L13.0195 13.2344C13.0668 13.4314 13.0546 13.638 12.9845 13.8281C12.9144 14.0182 12.7896 14.1833 12.6257 14.3025C12.4618 14.4217 12.2663 14.4896 12.0639 14.4977C11.8614 14.5059 11.6611 14.4538 11.4882 14.3481L8.33199 12.4056L5.17387 14.3481C5.00101 14.4532 4.80093 14.5048 4.59883 14.4963C4.39673 14.4879 4.20163 14.4199 4.03812 14.3008C3.8746 14.1817 3.74998 14.0169 3.67993 13.8272C3.60989 13.6374 3.59756 13.4312 3.64449 13.2344L4.50449 9.60502L1.69199 7.17815C1.53905 7.04596 1.42845 6.87166 1.37398 6.67699C1.31952 6.48232 1.32361 6.27592 1.38575 6.08356C1.44789 5.89121 1.56533 5.72142 1.72339 5.59541C1.88145 5.4694 2.07313 5.39274 2.27449 5.37502L5.96199 5.07752L7.38449 1.63502C7.46149 1.44741 7.59254 1.28693 7.76097 1.17398C7.92941 1.06104 8.12763 1.00073 8.33043 1.00073C8.53323 1.00073 8.73145 1.06104 8.89989 1.17398C9.06832 1.28693 9.19937 1.44741 9.27637 1.63502L10.6982 5.07752L14.3857 5.37502C14.5875 5.39208 14.7797 5.46831 14.9384 5.59415C15.097 5.71999 15.215 5.88984 15.2775 6.08243C15.34 6.27502 15.3443 6.48178 15.2899 6.6768C15.2354 6.87182 15.1246 7.04644 14.9714 7.17877L14.9751 7.17815Z"
          fill="white"
        />
      </svg>
      인기
    </div>
  );
}

export default function LongTermPrice() {
  const [plan, setPlan] = useState<Plan>(6);

  return (
    <>
      {/* 기간 선택 버튼 */}
      <div className="px-4 text-center">
        <div className="mt-6 flex flex-wrap justify-center gap-x-3 gap-y-14">
          {TABS.map((tab) => (
            <button
              key={tab.plan}
              type="button"
              onClick={() => setPlan(tab.plan)}
              className={
                plan === tab.plan
                  ? 'relative rounded-full border-2 border-edge-purple bg-edge-purple px-7 py-3 text-white max-md:px-5 max-md:py-2'
                  : 'relative rounded-full border-2 border-edge-purple bg-white px-7 py-3 text-edge-purple max-md:px-5 max-md:py-2'
              }
            >
              {tab.hot && (
                <span className="absolute -top-10 left-1/2 -translate-x-1/2 whitespace-nowrap rounded-lg bg-[#E5383B] px-3.5 py-1.5 text-sm font-extrabold text-white">
                  최대 할인
                  <span className="absolute left-1/2 top-full -translate-x-1/2 border-x-[6px] border-t-[6px] border-x-transparent border-t-[#E5383B]" />
                </span>
              )}
              <span
                className={
                  plan === tab.plan
                    ? 'block text-lg font-extrabold text-white max-md:text-base'
                    : 'block text-lg font-extrabold text-edge-purple max-md:text-base'
                }
              >
                {tab.title}
              </span>
              <span
                className={
                  plan === tab.plan
                    ? 'block text-xs font-semibold text-white'
                    : 'block text-xs font-semibold text-edge-purple'
                }
              >
                {tab.sub}
              </span>
            </button>
          ))}
        </div>
        <p className="mt-4 text-base text-[#888] max-md:text-sm">
          영어는 꾸준함이 답! 길게 할수록 더 저렴해요
        </p>
      </div>

      {/* 수강료 카드 */}
      <div className="flex gap-8 px-4 max-md:flex-col max-md:gap-12">
        {PRICES.map((group) => (
          <div
            key={group.minutes}
            className={
              group.minutes === '50'
                ? 'relative flex-1 rounded-2xl bg-white'
                : 'flex-1 rounded-2xl bg-white'
            }
          >
            {group.minutes === '50' && (
              <Bubble text="주 1회 수업은 50분 수업만 가능합니다." top={-27} bg="#A0F4FF" />
            )}

            <div className={group.headerClass}>
              <p className={group.titleClass}>
                <span className={group.numberClass}>{group.minutes}</span>분 화상영어
              </p>
            </div>

            {group.rows.map((row, i) => {
              const p = calc(row.monthly, plan);
              return (
                <div
                  key={row.label}
                  className={'popular' in row && row.popular ? ROW_BORDERS[i] + ' relative bg-[#7D5FFF0D]' : ROW_BORDERS[i]}
                >
                  {'popular' in row && row.popular && <PopularBadge />}
                  <div>
                    <span className={group.badgeClass}>{row.label}</span>
                    <p className="mt-4 whitespace-nowrap font-medium tracking-tight text-[#666] max-md:text-sm">
                      월 횟수 <span className="font-bold text-[#666]">{row.count}</span>회
                    </p>
                  </div>

                  <div className="flex gap-2">
                    {plan === 1 ? (
                      <p className="flex items-center gap-1 text-xl max-md:text-sm">
                        월
                        <span className="font-montserrat tabular-nums text-2xl font-extrabold max-md:text-lg">
                          {won(p.price)}
                        </span>
                        원
                      </p>
                    ) : (
                      <div className="flex flex-col items-end gap-0.5 text-right">
                        <span className="font-montserrat tabular-nums text-xs text-[#aaa] line-through">
                          월 {won(row.monthly)}원
                        </span>
                        <p className="flex items-center gap-1 text-xl max-md:text-sm">
                          월
                          <span
                            className={
                              plan === 6
                                ? 'font-montserrat tabular-nums text-2xl font-extrabold text-[#E5383B] max-md:text-lg'
                                : 'font-montserrat tabular-nums text-2xl font-extrabold text-edge-purple max-md:text-lg'
                            }
                          >
                            {won(p.perMonth)}
                          </span>
                          원
                        </p>
                        <span
                          className={
                            plan === 6
                              ? 'my-1 whitespace-nowrap rounded-full bg-[#FFE8E8] px-3 py-1 text-[15px] font-extrabold text-[#E5383B] max-md:text-sm'
                              : 'my-1 whitespace-nowrap rounded-full bg-[#7D5FFF1A] px-3 py-1 text-[15px] font-extrabold text-edge-purple max-md:text-sm'
                          }
                        >
                          총{' '}
                          <span
                            className={
                              plan === 6
                                ? 'font-montserrat tabular-nums text-[#E5383B]'
                                : 'font-montserrat tabular-nums text-edge-purple'
                            }
                          >
                            {won(p.save)}
                          </span>
                          원 절약
                        </span>
                        <p className="text-sm font-medium text-[#888] max-md:text-xs">
                          {plan}개월 결제 금액 <span className="font-montserrat tabular-nums text-[#888]">{won(p.price)}</span>원
                        </p>
                      </div>
                    )}
                  </div>
                </div>
              );
            })}
          </div>
        ))}
      </div>

      {/* 장기 수강 멘트 + 혜택 */}
      <div className="px-4">
        <div className="mt-6 text-center">
          <h2 className="text-3xl font-bold leading-tight max-md:text-xl">
            영어, 결국 <span className="text-[#5542A5]">오래 하는 사람</span>이 이겨요
          </h2>
          <p className="mt-4 leading-relaxed text-[#666] max-md:text-sm">
            매달 결제할 때마다 고민되셨죠? 한 번 등록해두면 수업 시간이 생활 루틴으로 자리 잡아요.
            <br className="max-md:hidden" /> 고민 없이 수업만 듣다 보면, 영어는 어느새 쌓여 있을 거예요.
          </p>
        </div>

        <div className="mt-10 grid grid-cols-[1fr_1.6fr] gap-6 max-md:grid-cols-1 max-md:gap-4">
          <div className="rounded-2xl border border-[#ddd] bg-white p-7 max-md:p-5">
            <span className="inline-block rounded-full bg-[#333] px-3 py-1 text-xs font-bold text-white">
              기본 혜택 · 모든 수강생
            </span>
            <p className="mt-3 text-xl font-extrabold max-md:text-lg">등록하시는 모든 분께</p>
            <p className="mt-3 text-[#333] max-md:text-sm">
              <span className="font-bold text-edge-purple">✓</span> 「화상영어 수업 핵심 표현」 Ebook 증정
            </p>
          </div>

          <div className="rounded-2xl border-2 border-edge-purple bg-white p-7 max-md:p-5">
            <span className="inline-block rounded-full bg-edge-purple px-3 py-1 text-xs font-bold text-white">
              6개월 등록 시 추가 혜택
            </span>
            <p className="mt-3 text-xl font-extrabold max-md:text-lg">
              엣지영어 대표가 직접 만든 <span className="text-edge-purple">Ebook 패키지 무료!</span>
            </p>
            <ul className="mt-3 flex flex-col gap-2 text-[#333] max-md:text-sm">
              <li>
                <span className="font-bold text-edge-purple">✓</span> 해외여행 실전 회화 ebook + 저자 직강 영상{' '}
                <span className="text-sm text-[#888]">(판매가 26,900원 상당)</span>
              </li>
              <li>
                <span className="font-bold text-edge-purple">✓</span> 헷갈리는 문법 핵심 정리본{' '}
                <span className="text-sm text-[#888]">(PDF)</span>
              </li>
              <li>
                <span className="font-bold text-edge-purple">✓</span> 스피킹에 무조건 도움 되는 영어 꿀팁 30개{' '}
                <span className="text-sm text-[#888]">(PDF)</span>
              </li>
              <li>
                <span className="font-bold text-edge-purple">✓</span> <b>최대 2주 휴강</b> 가능
              </li>
            </ul>
          </div>
        </div>
      </div>
    </>
  );
}
