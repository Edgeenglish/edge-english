'use client';

// 홈페이지 방문 통계 불러오기 (규칙은 src/lib/tracking.ts)
import { usePathname } from 'next/navigation';
import { useEffect, useRef } from 'react';
import { CLARITY_ID, GA_ID, isTrackablePage, track, trackingMode } from '@/lib/tracking';

function loadScript(src: string) {
  const s = document.createElement('script');
  s.async = true;
  s.src = src;
  document.head.appendChild(s);
}

export default function SiteAnalytics() {
  const path = usePathname();
  const loaded = useRef({ ga: false, clarity: false });

  useEffect(() => {
    const m = trackingMode();
    if (m === 'off' || !isTrackablePage()) {
      // 홈페이지에서 LMS·운영자 보기로 넘어가면 Clarity 기록을 멈춤
      if (loaded.current.clarity) window.clarity?.('stop');
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
    // 자동 수집 이벤트(스크롤·바깥 링크 등)도 주소 뒤 ?값 없이 보내도록 매 페이지 주소를 먼저 고정
    window.gtag?.('set', { page_location: window.location.origin + path, page_referrer: document.referrer ? new URL(document.referrer).origin : '' });
    window.gtag?.('event', 'page_view', { page_location: window.location.origin + path, page_path: path, page_title: document.title });
  }, [path]);

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

  return null;
}
