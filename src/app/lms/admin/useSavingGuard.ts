'use client';

// 저장 중 화면 이탈 막기 (R-20): 브라우저 닫기·새로고침은 beforeunload, 화면 안 링크(홈·메뉴)는 누르기 전에 확인.
// 저장 자체를 취소하지는 않음 — 이동해도 서버 처리는 끝까지 가므로, 돌아와서 다시 읽으면 결과가 보임
import { useEffect } from 'react';

export function useSavingGuard(active: boolean, message: string) {
  useEffect(() => {
    if (!active) return;
    const warn = (e: BeforeUnloadEvent) => { e.preventDefault(); e.returnValue = ''; };
    const click = (e: MouseEvent) => {
      const a = (e.target as HTMLElement | null)?.closest?.('a[href]');
      if (!a) return;
      if (!window.confirm(message)) { e.preventDefault(); e.stopPropagation(); }
    };
    window.addEventListener('beforeunload', warn);
    document.addEventListener('click', click, true);
    return () => {
      window.removeEventListener('beforeunload', warn);
      document.removeEventListener('click', click, true);
    };
  }, [active, message]);
}
