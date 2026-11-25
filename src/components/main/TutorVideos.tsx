'use client';

import { useCallback, useEffect, useRef, useState } from 'react';
import type { TeacherVideo } from '@/lib/teacher-videos';

// 홈: '엣지영어에서는 이런 선생님들과 수업해요' (대표 11/25 시안 확정)
// 카드 = 썸네일 + 영상 제목(선생님 이름은 안 씀). 눌러야 그 영상만 불러와 홈페이지 안 팝업에서 재생 (인스타·유튜브로 나가지 않음)
export default function TutorVideos({ videos }: { videos: TeacherVideo[] }) {
  const [openId, setOpenId] = useState<string | null>(null);
  const trigger = useRef<HTMLElement | null>(null);
  const closeBtn = useRef<HTMLButtonElement>(null);
  const open = videos.find((v) => v.id === openId) ?? null;

  const close = useCallback(() => {
    setOpenId(null);
    trigger.current?.focus();
  }, []);

  useEffect(() => {
    if (!open) return;
    const prev = document.body.style.overflow;
    document.body.style.overflow = 'hidden'; // 팝업 뒤 화면이 스크롤되지 않게 (닫으면 보던 자리 그대로)
    closeBtn.current?.focus();
    const onKey = (e: KeyboardEvent) => e.key === 'Escape' && close();
    window.addEventListener('keydown', onKey);
    return () => {
      document.body.style.overflow = prev;
      window.removeEventListener('keydown', onKey);
    };
  }, [open, close]);

  if (videos.length === 0) return null;

  return (
    <section className="bg-gradient-to-b from-white to-[#FAF8FF] px-4.5 py-24 max-md:py-15">
      <div className="mx-auto max-w-[900px] text-center [word-break:keep-all]">
        <h3 className="text-4xl font-extrabold !leading-snug text-[#140F33] max-md:text-[25px]">
          엣지영어에서는
          <br />
          이런 선생님들과 수업해요.
        </h3>
        <p className="mt-5 text-lg font-bold text-[#3b1fd0] max-md:text-[15px]">
          영상 속 선생님들은 모두 실제 엣지영어 강사님들이세요!
        </p>
        <p className="mt-3.5 text-[17px] text-[#3d3a52] max-md:text-[14.5px]">
          저희도 영어를 가르치지만, 여전히 영어를 배우는 사람이기도 해요.
        </p>
        <p className="mt-1.5 text-[17px] !leading-relaxed text-[#3d3a52] max-md:text-[14.5px]">
          그래서 <b className="text-[#140F33]">저희 스스로도 영어를 배우고 싶다는 생각이 드는 선생님들만</b> 정말 고심해서 선발했어요. :)
        </p>

        <ul className="mt-9 grid grid-cols-3 md:mx-auto md:max-w-[780px] gap-[18px] max-md:-mx-4.5 max-md:mt-6 max-md:flex max-md:snap-x max-md:snap-mandatory max-md:gap-3 max-md:overflow-x-auto max-md:px-4.5 max-md:pb-3 max-md:[scroll-padding-left:18px]">
          {videos.map((v) => (
            <li key={v.id} className="max-md:w-[58%] max-md:shrink-0 max-md:snap-start">
              <button
                type="button"
                onClick={(e) => {
                  trigger.current = e.currentTarget;
                  setOpenId(v.id);
                }}
                aria-label={`${v.title} 재생`}
                className="group relative block aspect-[3/4] w-full overflow-hidden rounded-[20px] bg-[#3b1fd0] text-left shadow-[0_6px_18px_rgba(59,31,208,0.10)] max-md:aspect-[9/14] max-md:rounded-[18px]"
              >
                {/* 유튜브 쇼츠 썸네일은 가로 그림 가운데에 세로 화면이 있어서, 양옆 검은 띠를 잘라 내려고 키움 */}
                <img
                  src={v.thumb}
                  alt=""
                  loading="lazy"
                  className="absolute inset-0 h-full w-full scale-[1.4] object-cover transition-transform duration-300 group-hover:scale-[1.46]"
                />
                <span className="absolute inset-0 grid place-items-center">
                  <svg viewBox="0 0 24 24" aria-hidden="true" className="size-14 max-md:size-12">
                    <circle cx="12" cy="12" r="12" fill="rgba(255,255,255,0.92)" />
                    <path d="m10 7.8 6 4.2-6 4.2z" fill="#3b1fd0" />
                  </svg>
                </span>
                <span className="line-clamp-2 absolute inset-x-0 bottom-0 bg-gradient-to-b from-transparent to-[#140F33]/80 px-4 pb-4 pt-9 text-base font-bold !leading-snug text-white max-md:px-3 max-md:pb-3 max-md:pt-7 max-md:text-sm">
                  {v.title}
                </span>
              </button>
            </li>
          ))}
        </ul>
      </div>

      {open && (
        <div
          role="dialog"
          aria-modal="true"
          aria-label={open.title}
          className="fixed inset-0 z-[60] grid place-items-center bg-[#0e0a24]/75 p-4"
          onClick={close}
        >
          <div className="relative w-full max-w-[340px] rounded-[20px] bg-[#140F33] p-3.5 pt-[54px] text-white shadow-2xl" onClick={(e) => e.stopPropagation()}>
            <button
              ref={closeBtn}
              type="button"
              onClick={close}
              aria-label="닫기"
              className="absolute right-2 top-1.5 grid size-11 place-items-center rounded-full bg-white/15 text-base"
            >
              ✕
            </button>
            <div className="mx-auto aspect-[9/16] max-h-[78dvh] overflow-hidden rounded-[14px] bg-black">
              <iframe
                key={open.id}
                src={`https://www.youtube-nocookie.com/embed/${open.id}?autoplay=1&rel=0&playsinline=1&modestbranding=1`}
                title={open.title}
                className="h-full w-full"
                allow="autoplay; encrypted-media; picture-in-picture; fullscreen"
                allowFullScreen
              />
            </div>
            <p className="mx-1 mt-3 text-center text-[14.5px] font-bold !leading-snug">{open.title}</p>
          </div>
        </div>
      )}
    </section>
  );
}
