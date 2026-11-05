'use client';

// 저장 중 화면 이탈 막기 (R-20): 브라우저 닫기·새로고침은 beforeunload, 화면 안 링크(홈·메뉴)는 누르기 전에 확인,
// 브라우저·휴대폰 뒤로가기(popstate)는 임시 history 항목으로 붙잡아 확인창을 띄움.
// 저장 자체를 취소하지는 않음 — 이동해도 서버 처리는 끝까지 가고, 결과는 저장 중 기록(pending-saves)에 남아 위쪽 띠에서 확인
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
    // 뒤로가기: 지금 주소를 한 번 더 쌓아 두고, 뒤로 가면(popstate) 물어본 뒤 허락할 때만 진짜 뒤로
    let armed = true;
    let leaving = false;
    try { window.history.pushState({ lmsSavingGuard: true }, '', window.location.href); } catch { armed = false; }
    const pop = () => {
      if (!armed || leaving) return;
      if (window.confirm(message)) {
        leaving = true;
        window.history.back();   // 우리가 쌓은 항목은 이미 빠졌으므로 한 번 더 뒤로 = 원래 뒤로가기
      } else {
        try { window.history.pushState({ lmsSavingGuard: true }, '', window.location.href); } catch { /* 무시 */ }
      }
    };
    window.addEventListener('beforeunload', warn);
    document.addEventListener('click', click, true);
    window.addEventListener('popstate', pop);
    return () => {
      window.removeEventListener('beforeunload', warn);
      document.removeEventListener('click', click, true);
      window.removeEventListener('popstate', pop);
      // 저장이 끝나면 임시 항목을 치움 (사용자가 뒤로 두 번 눌러야 하는 일이 없게)
      if (armed && !leaving && window.history.state?.lmsSavingGuard) {
        armed = false;
        window.history.back();
      }
    };
  }, [active, message]);
}
