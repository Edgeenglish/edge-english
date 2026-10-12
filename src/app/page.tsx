'use client';

import RealReviews from '@/components/main/RealReviews';
import PointsTab from '@/components/main/DetailPointTab';
import MobileShortsSwiper from '@/components/main/MobileShortsSwiper';
import Link from 'next/link';
import Bubble from '@/components/common/bubble/Bubble';

export default function Home() {
  return (
    <div>
      {/* 섹션 1 */}
      <div className="mx-auto mb-[120px] mt-15 w-fit self-center px-4.5 max-md:mb-20 max-md:mt-10">
        <img
          src="/images/main/memoji.png"
          alt="memoji"
          width={304}
          height={168}
          className="mx-auto justify-self-center max-lg:mb-4 max-lg:w-[240px]"
        />
        <p
          className="mx-auto w-fit text-[32px] font-extrabold max-md:text-2xl"
          style={{
            background: 'linear-gradient(90deg, #FCB045, #FD1D1D, #833AB4)',
            WebkitBackgroundClip: 'text',
            WebkitTextFillColor: 'transparent',
          }}
        >
          시에나
          <span className="font-normal"> X </span>
          탠저린
        </p>

        {/* 타이틀 */}
        <>
          <h1 className="mt-[26px] text-center text-4xl font-bold leading-[120%] max-lg:text-4xl max-md:mt-5 max-md:text-[28px]">
            엣지영어는{' '}
            <span className="hidden max-md:inline">
              <br />
            </span>
            영어 교육 전문가들이 만든
          </h1>

          <div className="mx-auto mt-2 flex w-fit justify-center gap-4 max-md:mt-0 max-md:block">
            <div className="flex gap-4 max-md:items-end max-md:gap-1">
              <h1 className="content-center text-4xl font-bold max-lg:text-4xl max-md:text-[28px]">
                1:1 미국 · 캐나다 · 호주{' '}
              </h1>
              <div className="aspect-[109/57] w-[109px] max-lg:w-[70px]">
                <img
                  src="/images/main/flag.png"
                  alt="usa and canaga flags"
                  width={109}
                  height={57}
                />
              </div>
            </div>

            <h1 className="content-center text-4xl font-bold leading-[120%] max-lg:text-4xl max-md:text-[28px]">
              화상영어 브랜드입니다.
            </h1>
          </div>

          <h2 className="mt-8 text-center text-xl max-md:mt-6 max-md:text-base">
            13년차 영어 튜터 시에나 & 누적 조회수 300만+
            <span className="md:hidden">
              <br />
            </span>
            영어 콘텐츠 제작자 탠저린이 직접 운영해요.
          </h2>
        </>
      </div>

      {/* 섹션 2 탠저린샘의 10초 영어 pc */}
      <div className="max-md:hidden">
        <div className="bg-[#FFFAF6] bg-right-bottom bg-no-repeat px-4.5 text-center">
          <div className="mx-auto flex w-fit items-end gap-1 pt-[7.5rem]">
            <div className="min-w-0 flex-1 pb-[7.5rem]">
              <h2 className="text-4xl font-semibold text-[#140F33]">
                엣지영어 대표{' '}
                <span className="lg:hidden">
                  <br />
                </span>
                <span className="text-[#f80]">탠저린샘의 10초영어</span>
              </h2>
              <h3 className="mt-4 text-xl text-[#8e8e8e]">
                한국인이 자주 막히는 영어 표현,
                <span className="lg:hidden">
                  <br />
                </span>
                탠저린쌤이 빠르게 정리해드려요
              </h3>

              <div className="mt-10 flex gap-6">
                {['FkJ3hjifTzk', '_rRgqVq4gfw', 'Yj7pm_r38rc'].map((id) => {
                  return (
                    <div
                      className="aspect-[9/16] w-full max-w-[300px] overflow-hidden rounded-2xl bg-black max-lg:max-w-40"
                      key={id}
                    >
                      <iframe
                        src={`https://www.youtube.com/embed/${id}?autoplay=0`}
                        title="YouTube Shorts"
                        className="h-full w-full"
                        allow="accelerometer; autoplay; clipboard-write; encrypted-media; gyroscope; picture-in-picture"
                        allowFullScreen
                      />
                    </div>
                  );
                })}
              </div>

              <div className="mx-auto mt-6 w-fit">
                <Link
                  href="https://www.instagram.com/tangerine_english_/"
                  target="_blank"
                  className="btn h-14 rounded-lg border-none bg-edge-yellow px-8 py-4 font-bold"
                >
                  더 많은 표현 보러가기
                </Link>
              </div>
            </div>

            <div className="aspect-[404/788]">
              <img
                src="/images/main/shorts-bg.png"
                alt="탠저린샘"
                width={404}
                height={788}
                className="max-lg:w-[300px]"
              />
            </div>
          </div>
        </div>
        <div
          className="py-4 text-center"
          style={{
            background:
              'var(--g01, linear-gradient(90deg, #AA96FF -2.03%, #7D5FFF 102.29%))',
          }}
        >
          <p className="text-lg text-white">
            영어영문학전공 영어강사,{' '}
            <span className="font-semibold text-[#FFEB3B]">「탠저린의 써먹는 영어」</span>{' '}
            유튜브,인스타그램,블로그 운영 중
          </p>
        </div>
      </div>

      {/* 섹션 2 탠저린샘의 10초 영어 mobile */}
      <div className="bg-[#FFFAF6] bg-right-bottom bg-no-repeat text-center md:hidden">
        <h2 className="pt-10 text-[34px] font-semibold text-[#140F33]">
          엣지영어 대표 <br /> <span className="text-[#f80]">탠저린샘의 10초영어</span>
        </h2>
        <h3 className="mt-4 text-lg text-[#8e8e8e]">
          한국인이 자주 막히는 영어 표현, <br /> 탠저린쌤이 빠르게 정리해드려요
        </h3>

        {/* 탠저린쌤 */}
        <div className="flex-center mt-6">
          <img
            src="/images/main/mobile-shorts-bg.png"
            alt="탠저린샘"
            width={184}
            height={237}
          />
        </div>

        <div
          className="px-4.5 py-4 text-center"
          style={{
            background:
              'var(--g01, linear-gradient(90deg, #AA96FF -2.03%, #7D5FFF 102.29%))',
          }}
        >
          <p className="text-lg text-white">
            영어영문학전공 영어강사,{' '}
            <span className="font-semibold text-[#FFEB3B]">「탠저린의 써먹는 영어」</span>{' '}
            유튜브,인스타그램,블로그 운영 중
          </p>
        </div>

        {/* 숏츠 */}
        <MobileShortsSwiper />

        {/* 버튼 */}
        <div className="mx-auto mt-6 w-fit pb-15">
          <Link
            href="https://www.instagram.com/tangerine_english_/"
            target="_blank"
            className="btn h-14 rounded-lg border-none bg-edge-yellow px-8 py-4 font-bold"
          >
            더 많은 표현 보러가기
          </Link>
        </div>
      </div>

      {/* 섹션8 */}
      <div
        className="w-full px-4.5 py-15"
        style={{ background: 'linear-gradient(115deg, #F3F6F8 0%, #D9D0FF 100%)' }}
      >
        <div>
          <img
            className="mx-auto justify-self-center"
            src="/icons/main/check.svg"
            alt="보라색 체크 표시 아이콘"
            width={64}
            height={64}
          />
          <h3
            className="mx-auto mt-3 w-fit text-4xl font-bold leading-tight max-md:text-[32px]"
            style={{
              background: 'linear-gradient(89deg, #322585 19.7%, #7D5FFF 76.42%)',
              WebkitBackgroundClip: 'text',
              WebkitTextFillColor: 'transparent',
            }}
          >
            엣지영어만의{' '}
            <span className="md:hidden">
              <br />
            </span>
            특별한 디테일
          </h3>
          <h4 className="mx-auto mt-6 w-fit text-xl text-[#4A4A4A] max-md:text-[15px] max-md:leading-normal">
            한국인이 영어에서 느끼는 어려움을 누구보다 잘 아니까. <br /> 초급부터 고급까지
            모든 학습자를 만족 시키는 엣지 포인트!
          </h4>

          <div className="mt-15 max-md:mt-10">
            <PointsTab />
          </div>

          <div className="relative mx-auto mt-15 w-fit max-md:mt-10"></div>
        </div>
      </div>

      {/* 섹션 3 수업 절차 */}
      <div className="mx-auto my-[120px] w-fit text-center max-md:my-15 max-md:px-4.5">
        <h3 className="text-4xl font-bold text-[#140F33] max-md:text-[34px]">수업절차</h3>
        <div className="mt-10 flex items-center justify-center max-md:grid max-md:grid-cols-2 max-md:flex-wrap max-md:gap-6">
          {/* step 01 */}
          <div className="w-fit rounded-3xl border border-dashed border-edge-yellow p-1">
            <div className="flex aspect-square h-48 flex-col items-center justify-center gap-4 rounded-3xl bg-[#FFD4011A] p-6 max-lg:h-40 max-lg:p-2 max-md:h-33 max-md:p-4">
              <span className="badge border-none bg-[#AA96FF] p-2 font-montserrat text-xs font-medium text-white">
                STEP 01
              </span>
              <div>
                <p className="text-xl font-bold max-lg:tracking-[-0.8px] max-md:text-base">
                  수강 신청 및 결제
                </p>
                <p className="h-11 text-sm text-edge-gray max-md:text-xs"></p>
              </div>
            </div>
          </div>

          {/* arrow */}
          <div className="px-6 max-lg:px-1 max-md:hidden">
            <img
              src={'/icons/main/yellow-right-arrow.svg'}
              width={24}
              height={24}
              alt="yellow-right-arrow.svg"
            />
          </div>

          {/* step 02 */}
          <div className="w-fit rounded-3xl border border-dashed border-edge-yellow p-1">
            <div className="flex aspect-square h-48 flex-col items-center justify-center gap-4 rounded-3xl bg-[#FFD4011A] p-6 max-lg:h-40 max-lg:p-2 max-md:h-33 max-md:p-4">
              <span className="badge border-none bg-[#AA96FF] p-2 font-montserrat text-xs font-medium text-white">
                STEP 02
              </span>
              <div>
                <p className="text-xl font-bold max-md:text-base">
                  튜터 매칭 및<br />
                  수강 안내
                </p>
                <p className="h-11 text-sm text-edge-gray max-md:text-xs">
                  (최대 3일 소요)
                </p>
              </div>
            </div>
          </div>

          {/* arrow */}
          <div className="px-6 max-lg:px-1 max-md:hidden">
            <img
              src={'/icons/main/yellow-right-arrow.svg'}
              width={24}
              height={24}
              alt="yellow-right-arrow.svg"
            />
          </div>

          {/* step 03 */}
          <div className="w-fit rounded-3xl border border-dashed border-edge-yellow p-1">
            <div className="flex aspect-square h-48 flex-col items-center justify-center gap-4 rounded-3xl bg-[#FFD4011A] p-6 max-lg:h-40 max-lg:p-2 max-md:h-33 max-md:p-4">
              <span className="badge border-none bg-[#AA96FF] p-2 font-montserrat text-xs font-medium text-white">
                STEP 03
              </span>
              <div>
                <p className="text-xl font-bold max-md:text-base">수업 시작🎉</p>
                <p className="h-11 text-sm text-edge-gray max-md:text-xs"></p>
              </div>
            </div>
          </div>

          {/* arrow */}
          {/* <div className="px-6 max-lg:px-1 max-md:hidden">
            <img
              src={'/icons/main/yellow-right-arrow.svg'}
              width={24}
              height={24}
              alt="yellow-right-arrow.svg"
            />
          </div> */}

          {/* step 04 */}
          {/* <div className="w-fit rounded-3xl border border-dashed border-edge-yellow p-1">
            <div className="flex aspect-square h-48 flex-col items-center justify-center gap-4 rounded-3xl bg-[#FFD4011A] p-6 max-lg:h-40 max-lg:p-2 max-md:h-33 max-md:p-4">
              <span className="badge border-none bg-[#AA96FF] p-2 font-montserrat text-xs font-medium text-white">
                STEP 04
              </span>
              <div>
                <p className="text-xl font-bold max-md:text-base">수업 시작</p>
                <p className="h-11 text-sm text-edge-gray max-md:text-xs"></p>
              </div>
            </div>
          </div> */}
        </div>
      </div>

      {/* 섹션 4 화상영어 수강생들의 흔한 고민 */}
      <div
        className="p-[7.5rem] max-xl:p-16 max-md:px-4.5 max-md:py-15"
        style={{
          background: `linear-gradient(180deg, rgba(238,199,5,0.20) 0%, rgba(254,254,254,0.04) 100%), #FFFAF6`,
        }}
      >
        <div className="mx-auto max-w-[1200px]">
          <h3 className="text-center text-4xl font-medium text-[#140F33] max-md:text-2xl">
            화상영어 수강생들의 흔한 고민,
          </h3>
          <h4 className="mt-3 text-center text-4xl font-bold text-[#F80] max-md:text-2xl">
            엣지영어는 이렇게 해결합니다!
          </h4>

          <div className="mt-10 flex flex-col gap-4 px-15 max-md:px-2">
            {/* 말풍선 01 */}
            <div className="flex gap-2">
              <img
                src={'/icons/main/student01.png'}
                alt="student 1 memoji"
                width={96}
                height={96}
                className="h-24 shrink-0 self-end max-md:h-16 max-md:w-16"
              />
              <div className="chat chat-start flex-1">
                <div className="chat-bubble rounded-3xl bg-white px-7 py-4.5 text-xl font-semibold text-[#333] shadow-lg max-md:text-sm">
                  강사만 계속 말하는 것 같아요.
                </div>
              </div>
            </div>

            {/* 튜터 말풍선 01 */}
            <div className="flex gap-2">
              <div className="chat chat-end flex-1">
                <div className="chat-bubble rounded-3xl bg-edge-yellow px-7 py-4.5 text-xl font-semibold text-[#333] shadow-lg max-md:text-sm">
                  엣지영어 튜터는 학생의 말하기를 이끌어내도록 훈련된 원어민이에요. <br />{' '}
                  수업 중 함께 말할 수 있는 교재를 사용하니까, 듣기만 하는 수업과는
                  달라요!
                </div>
              </div>
              <img
                src={'/icons/main/tutor01.png'}
                alt="tutor memoji"
                width={96}
                height={96}
                className="h-24 shrink-0 self-end max-md:h-16 max-md:w-16"
              />
            </div>

            {/* 말풍선 02 */}
            <div className="flex gap-2">
              <img
                src={'/icons/main/student02.png'}
                alt="student 2 memoji"
                width={96}
                height={96}
                className="h-24 shrink-0 self-end max-md:h-16 max-md:w-16"
              />
              <div className="chat chat-start flex-1">
                <div className="chat-bubble rounded-3xl bg-white px-7 py-4.5 text-xl font-semibold text-[#333] shadow-lg max-md:text-sm">
                  강사의 발음이 아쉬워요.
                </div>
              </div>
            </div>

            {/* 튜터 말풍선 02 */}
            <div className="flex gap-2">
              <div className="chat chat-end flex-1">
                <div className="chat-bubble rounded-3xl bg-edge-yellow px-7 py-4.5 text-xl font-semibold text-[#333] shadow-lg max-md:text-sm">
                  엣지영어 강사는 100% 미국·캐나다·호주 출신 원어민으로, <br /> 어느 튜터를
                  만나도 깨끗한 원어민 발음을 배울 수 있어요.
                </div>
              </div>
              <img
                src={'/icons/main/tutor01.png'}
                alt="tutor memoji"
                width={96}
                height={96}
                className="h-24 shrink-0 self-end max-md:h-16 max-md:w-16"
              />
            </div>

            {/* 말풍선 03 */}
            <div className="flex gap-2">
              <img
                src={'/icons/main/student033.png'}
                alt="student 3 memoji"
                width={96}
                height={96}
                className="h-24 shrink-0 self-end max-md:h-16 max-md:w-16"
              />
              <div className="chat chat-start flex-1">
                <div className="chat-bubble rounded-3xl bg-white px-7 py-4.5 text-xl font-semibold text-[#333] shadow-lg max-md:text-sm">
                  강사의 전문성이 부족해 보여요.
                </div>
              </div>
            </div>

            {/* 튜터 말풍선 03 */}
            <div className="flex gap-2">
              <div className="chat chat-end flex-1">
                <div className="chat-bubble rounded-3xl bg-edge-yellow px-7 py-4.5 text-xl font-semibold text-[#333] shadow-lg max-md:text-sm">
                  엣지영어의 모든 강사는 TESOL/TEFL/CELTA(국제 영어 교육 자격증) 또는 교육 관련 학위를
                  보유하고 있으며, <br /> 철저한 5단계 검증 절차를 모두 통과한 선생님만
                  채용합니다.
                </div>
              </div>
              <img
                src={'/icons/main/tutor01.png'}
                alt="tutor memoji"
                width={96}
                height={96}
                className="h-24 shrink-0 self-end max-md:h-16 max-md:w-16"
              />
            </div>

            {/* 말풍선 04 */}
            <div className="flex gap-2">
              <img
                src={'/icons/main/student04.png'}
                alt="student 4 memoji"
                width={96}
                height={96}
                className="h-24 shrink-0 self-end max-md:h-16 max-md:w-16"
              />
              <div className="chat chat-start flex-1">
                <div className="chat-bubble rounded-3xl bg-white px-7 py-4.5 text-xl font-semibold text-[#333] shadow-lg max-md:text-sm">
                  수업 때 배운 표현을 다시 쓰고 싶은데, 정확히 뭐였는지 생각이 안 나요.
                </div>
              </div>
            </div>

            {/* 튜터 말풍선 04 */}
            <div className="flex gap-2">
              <div className="chat chat-end flex-1">
                <div className="chat-bubble rounded-3xl bg-edge-yellow px-7 py-4.5 text-xl font-semibold text-[#333] shadow-lg max-md:text-sm">
                  원하는 경우 수업을 녹화해 두고 언제든 다시 보며 복습할 수 있어요. <br />{' '}
                  놓친 부분도 확인하고 중요한 표현을 확실히 내 것으로 만들 수 있습니다.
                </div>
              </div>
              <img
                src={'/icons/main/tutor01.png'}
                alt="tutor memoji"
                width={96}
                height={96}
                className="h-24 shrink-0 self-end max-md:h-16 max-md:w-16"
              />
            </div>
          </div>
        </div>
      </div>

      {/* 섹션 5 pc 매번 작심삼일로 끝났다면? */}
      <div
        className="relative w-full bg-cover bg-center bg-no-repeat px-4.5 py-32 max-md:hidden"
        style={{ backgroundImage: "url('/images/main/we-can-help-bg.png')" }}
      >
        <p className="mx-auto w-fit pr-12 text-4xl font-bold text-edge-yellow">
          .&nbsp;&nbsp;&nbsp;.&nbsp;&nbsp;&nbsp;.&nbsp;&nbsp;&nbsp;.
        </p>
        <p
          className="text-center text-4xl font-bold !leading-normal text-white max-lg:text-4xl"
          style={{ textShadow: '0px 0px 10px rgba(0, 0, 0, 0.50)' }}
        >
          영어, 매번 작심삼일로 끝났다면? <br />
          포기하지 않도록 엣지영어가 도와드릴게요!
        </p>
        <p
          className="mt-8 text-center text-xl font-medium text-white max-xl:text-2xl max-lg:text-xl"
          style={{ textShadow: '0px 0px 10px rgba(0, 0, 0, 0.50)' }}
        >
          운영진들의 오랜 강사 경력과 노하우를 바탕으로 완성된 학습시스템을 소개합니다.
        </p>
      </div>

      {/* 섹션 5 mobile 매번 작심삼일로 끝났다면? */}
      <div
        className="aspect-[340/305] bg-cover bg-center px-4.5 py-15 md:hidden"
        style={{ backgroundImage: "url('/images/main/we-can-help-bg-mobile.png')" }}
      >
        <p className="mx-auto w-fit pr-5 text-xl font-bold text-edge-yellow">
          .&nbsp;&nbsp;&nbsp;.&nbsp;&nbsp;&nbsp;.&nbsp;&nbsp;&nbsp;.
        </p>
        <p
          className="text-center text-2xl font-bold text-white"
          style={{ textShadow: '0px 0px 10px rgba(0, 0, 0, 0.50)' }}
        >
          영어, 매번 작심삼일로 끝났다면? <br />
          포기하지 않도록 엣지영어가 <br /> 도와드릴게요!
        </p>
        <p
          className="mt-8 text-center font-medium text-white"
          style={{ textShadow: '0px 0px 10px rgba(0, 0, 0, 0.50)' }}
        >
          운영진들의 오랜 강사 경력과 노하우를 바탕으로
          <span className="md:hidden">
            <br />
          </span>
          완성된 학습시스템을 소개합니다.
        </p>
      </div>

      {/* 섹션 6 지속 가능한 영어 학습 시스템 */}
      <>
        {/* 포인트 1 */}
        <div className="bg-[#F3F6F8] px-4.5 pb-[140px] pt-[100px] max-md:py-15">
          <h3 className="pb-24 text-center text-4xl font-bold text-[#140F33] max-md:text-[32px]">
            지속 가능한{' '}
            <span className="md:hidden">
              <br />
            </span>
            영어 학습 시스템
          </h3>

          <div className="mx-auto max-w-[1080px] justify-between gap-16 md:flex">
            <div className="flex-1">
              <span className="block w-fit rounded-full border-none bg-edge-yellow px-4 py-3 font-bold leading-none text-[#333] max-md:px-4 max-md:py-2">
                포인트1
              </span>
              <h4 className="pt-4 text-3xl font-bold leading-[120%] text-[#140F33] max-lg:text-4xl max-md:text-2xl">
                고정제 수업으로 만드는 영어 루틴
              </h4>
              <p className="mt-8 text-lg leading-[140%] text-edge-gray max-lg:text-xl max-md:mt-6 max-md:text-base">
                정해진 요일과 시간에 꾸준히 진행되는 고정제 수업은 바쁜 일상 속에서도
                영어를 포기하지 않도록 강력한 동기부여가 됩니다.
              </p>
            </div>

            <div className="flex-center flex-1 max-md:mt-10">
              <img
                src={'/images/main/point01.png'}
                alt="point 01"
                width={580}
                height={400}
              />
            </div>
          </div>
        </div>

        {/* 포인트 2 */}
        <div className="px-4.5 pb-[140px] pt-[100px] max-md:py-15">
          <div className="mx-auto max-w-[1080px] flex-row-reverse justify-between gap-16 md:flex">
            <div className="flex-1">
              <span className="block w-fit rounded-full border-none bg-edge-yellow px-4 py-3 font-bold leading-none text-[#333] max-md:px-4 max-md:py-2">
                포인트2
              </span>
              <h4 className="pt-4 text-3xl font-bold leading-[120%] text-[#140F33] max-lg:text-4xl max-md:text-2xl">
                다양한 주제의 고퀄리티 교재 완비
              </h4>
              <p className="mt-8 text-lg leading-[140%] text-edge-gray max-lg:text-xl max-md:mt-6 max-md:text-base">
                비즈니스, 여행, 일상 등 다양한 상황의 영어를 연습할 수 있도록 세계적으로
                인정받은 교재를 사용합니다.
              </p>
              <p className="mt-2 text-lg text-[#a4a4a4] max-lg:text-xl max-md:mt-2 max-md:text-base">
                * 대부분 옥스포드 출판 교재 사용
              </p>
            </div>

            <div className="flex-center flex-1 max-md:mt-10">
              <img
                src={'/images/main/point02.png'}
                alt="point 02"
                width={580}
                height={400}
              />
            </div>
          </div>
        </div>

        {/* 포인트 3 */}
        <div className="bg-[#F3F6F8] px-4.5 pb-[140px] pt-[100px] max-md:py-15">
          <div className="mx-auto max-w-[1080px] justify-between gap-16 md:flex">
            <div className="flex-1">
              <span className="block w-fit rounded-full border-none bg-edge-yellow px-4 py-3 font-bold leading-none text-[#333] max-md:px-4 max-md:py-2">
                포인트3
              </span>
              <h4 className="pt-4 text-3xl font-bold leading-[120%] text-[#140F33] max-lg:text-4xl max-md:text-2xl">
                전원 미국·캐나다·호주 원어민 강사진
              </h4>
              <p className="mt-8 text-lg leading-[140%] text-edge-gray max-lg:text-xl max-md:mt-6 max-md:text-base">
                영어에는 다양한 억양이 있지만, 한국 학습자에게 가장 익숙한 북미·호주 발음을
                사용하는 튜터만으로 구성되어있어요.
              </p>
            </div>

            <div className="flex-center flex-1 max-md:mt-10">
              <img
                src={'/images/main/point03.png'}
                alt="point 03"
                width={580}
                height={400}
              />
            </div>
          </div>
        </div>
      </>

      {/* 섹션7 솔직 찐후기 */}
      <div className="py-[120px] text-center max-md:py-15">
        <p className="px-[140px] text-xl font-semibold text-edge-purple max-md:px-4.5">
          솔직 찐후기
        </p>
        <h3 className="mt-4 text-4xl font-bold text-[#140F33] max-md:px-4.5 max-md:text-[32px]">
          왜 모두 엣지영어에{' '}
          <span className="md:hidden">
            <br />
          </span>
          만족할까요?
        </h3>

        <RealReviews />

        <div className="relative mx-auto mt-15 w-fit max-md:mt-10">
          <div className="w-[228px] self-center text-center">
            <Bubble
              text="30초면 충분해요"
              bg="#333333"
              textClassName="text-white"
              left={5}
            />

            <Link
              href="https://forms.gle/arWZ6uzK3BFgaxM39"
              target="_blank"
              className="btn mx-auto mt-12 h-14 w-50 rounded-lg border-none bg-[#4A4A4A] px-14 py-5 font-bold text-white"
            >
              수강 신청하기
            </Link>
          </div>
        </div>
      </div>
    </div>
  );
}
