'use client';

// 홈페이지 방문 통계 불러오기 (규칙은 src/lib/tracking.ts)
import { usePathname } from 'next/navigation';
import Link from 'next/link';
import { useEffect, useRef, useState } from 'react';
import { CLARITY_ID, GA_ID, isPublicPath, needsConsentBanner, setConsent, track, trackingMode } from '@/lib/tracking';

function loadScript(src: string) {
  const s = document.createElement('script');
  s.async = true;
  s.src = src;
  document.head.appendChild(s);
}

export default function SiteAnalytics() {
  const path = usePathname();
  const loaded = useRef({ ga: false, clarity: false });
  const [chosen, setChosen] = useState(0); // 배너에서 고르면 다시 계산
  const [banner, setBanner] = useState(false);
  useEffect(() => setBanner(needsConsentBanner()), [chosen]);

  useEffect(() => {
    const m = trackingMode();
    if (m === 'off' || !isPublicPath(path)) {
      // 홈페이지에서 LMS 로 넘어가면 Clarity 기록을 멈춤
      if (loaded.current.clarity && !isPublicPath(path)) window.clarity?.('stop');
      return;
    }
    if (GA_ID && !loaded.current.ga) {
      loaded.current.ga = true;
      window.dataLayer = window.dataLayer || [];
      window.gtag = function gtag() {
        // eslint-disable-next-line prefer-rest-params
        window.dataLayer!.push(arguments);
      };
      window.gtag('js', new Date());
      window.gtag('config', GA_ID, { send_page_view: false, ...(m === 'debug' ? { debug_mode: true } : {}) });
      loadScript(`https://www.googletagmanager.com/gtag/js?id=${GA_ID}`);
    }
    if (CLARITY_ID && m === 'on') {
      if (!loaded.current.clarity) {
        loaded.current.clarity = true;
        const c = function clarity() {
          // eslint-disable-next-line prefer-rest-params
          ((c as unknown as { q: unknown[] }).q = (c as unknown as { q?: unknown[] }).q || []).push(arguments);
        };
        window.clarity = c;
        loadScript(`https://www.clarity.ms/tag/${CLARITY_ID}`);
      } else {
        window.clarity?.('start');
      }
    }
    // 페이지 보기 (주소 뒤 ?값은 보내지 않음)
    window.gtag?.('event', 'page_view', { page_location: window.location.origin + path, page_path: path, page_title: document.title });
  }, [path, chosen]);

  // 수강신청(구글 설문지)·카톡 채널 링크 누름은 화면마다 코드를 고치지 않고 여기서 한 번에 셈
  useEffect(() => {
    const onClick = (e: MouseEvent) => {
      const a = (e.target as HTMLElement | null)?.closest?.('a');
      const href = a?.getAttribute('href') ?? '';
      if (href.includes('forms.gle') || href.includes('docs.google.com/forms')) track('apply_click', { page_path: window.location.pathname });
      else if (href.includes('pf.kakao.com')) track('kakao_click', { page_path: window.location.pathname });
    };
    document.addEventListener('click', onClick, true);
    return () => document.removeEventListener('click', onClick, true);
  }, []);

  if (!banner || !isPublicPath(path)) return null;
  const choose = (v: 'yes' | 'no') => {
    setConsent(v);
    setChosen((n) => n + 1);
  };
  // 방문 통계 동의 배너 (대표 11/26): 작게, 동의·거부 같은 모양, 거부해도 이용 제한 없음, 국외 이전 안내 + 자세히(처리방침)
  return (
    <div role="region" aria-label="방문 통계 동의" className="fixed inset-x-0 bottom-0 z-[30] border-t border-[#e2e0ee] bg-white px-4 py-3 shadow-[0_-4px_16px_rgba(0,0,0,0.06)]">
      <div className="mx-auto flex max-w-[960px] items-center gap-3 max-md:flex-col max-md:items-stretch max-md:gap-2">
        <p className="flex-1 text-[13px] leading-snug text-[#3d3a52]">
          본 웹사이트는 서비스 개선 및 이용 통계 분석을 위해 쿠키를 사용합니다.{' '}
          <Link href="/privacy#stats" className="font-semibold text-[#5b3df0] underline">자세히</Link>
        </p>
        <div className="flex shrink-0 gap-2">
          <button type="button" onClick={() => choose('no')} className="min-h-[40px] flex-1 rounded-[10px] border border-[#5b3df0] px-5 text-[14px] font-bold text-[#5b3df0]">거부</button>
          <button type="button" onClick={() => choose('yes')} className="min-h-[40px] flex-1 rounded-[10px] border border-[#5b3df0] px-5 text-[14px] font-bold text-[#5b3df0]">동의</button>
        </div>
      </div>
    </div>
  );
}
