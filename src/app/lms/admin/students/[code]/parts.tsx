'use client';

// 수강생 상세 공통 조각: 창(Sheet), 줄(Row), 칸(Box), 복사 버튼, 스타일
import { useEffect, useRef, useState, type ReactNode } from 'react';

export const btnMain = 'min-h-[44px] rounded-[10px] bg-[#5b3fe0] px-4 text-[15px] font-semibold text-white disabled:opacity-40';
export const btnSub = 'min-h-[44px] rounded-[10px] border border-[#e6e3ef] bg-white px-4 text-[15px] font-semibold text-[#1d1b2b] disabled:opacity-40';
export const btnSmall = 'min-h-[36px] rounded-[8px] border border-[#e6e3ef] bg-white px-3 text-[13px] font-semibold text-[#5b3fe0] disabled:opacity-40';
export const input = 'w-full rounded-[10px] border border-[#d9d5e6] bg-white px-3 py-2.5 text-[16px] text-[#1d1b2b] disabled:bg-[#f3f1f8]';
export const label = 'mb-1 block text-[13px] font-semibold text-[#55526a]';

export function Row({ k, v, strong }: { k: ReactNode; v: ReactNode; strong?: boolean }) {
  return (
    <div className="flex justify-between gap-3 border-b border-[#f0eef6] py-2 text-[14px] last:border-0">
      <span className="shrink-0 text-[#6b6880]">{k}</span>
      <span className={`min-w-0 text-right break-words ${strong ? 'font-bold text-[#1d1b2b]' : 'text-[#1d1b2b]'}`}>{v}</span>
    </div>
  );
}

export function Box({ title, action, children }: { title: string; action?: ReactNode; children: ReactNode }) {
  return (
    <section className="rounded-[14px] border border-[#e6e3ef] bg-white px-4 py-3">
      <div className="mb-1 flex items-center justify-between gap-2">
        <h2 className="text-[12px] font-extrabold tracking-wider text-[#6b6880]">{title}</h2>
        {action}
      </div>
      {children}
    </section>
  );
}

/** 아래에서 올라오는 창 (휴대폰) / 가운데 창 (PC). 닫기 ✕, 바깥 누르면 닫힘. 휴대폰 뒤로가기도 창만 닫히게 history 에 한 칸
 *  dirty: 입력 중(저장 안 한 변경)이면 바깥 누름·✕·뒤로가기·화면 이탈 때 확인을 받고, 확인 없이는 닫지 않음
 *  (2026-11-06 대표: 프로필 수정 중 창이 갑자기 닫힘 — 뒤로가기 제스처·바깥 터치·화면 새로고침으로 입력이 사라지지 않게) */
export function Sheet({ title, onClose, children, wide, dirty = false }: { title: string; onClose: () => void; children: ReactNode; wide?: boolean; dirty?: boolean }) {
  const onCloseRef = useRef(onClose);
  onCloseRef.current = onClose;
  const dirtyRef = useRef(dirty);
  dirtyRef.current = dirty;
  const DISCARD = '입력 중인 내용이 있어요. 저장하지 않고 닫을까요?';
  useEffect(() => {
    const onPop = () => {
      if (dirtyRef.current && !window.confirm(DISCARD)) {
        // 뒤로가기(제스처 포함)로 빠져나간 history 칸을 다시 넣어 창을 유지
        window.history.pushState({ sheet: title }, '');
        return;
      }
      onCloseRef.current();
    };
    if (window.history.state?.sheet !== title) window.history.pushState({ sheet: title }, '');
    window.addEventListener('popstate', onPop);
    return () => window.removeEventListener('popstate', onPop);
  }, [title]);
  // 입력 중에 새로고침·탭 닫기 → 브라우저 확인창
  useEffect(() => {
    if (!dirty) return;
    const warn = (e: BeforeUnloadEvent) => e.preventDefault();
    window.addEventListener('beforeunload', warn);
    return () => window.removeEventListener('beforeunload', warn);
  }, [dirty]);
  const close = () => {
    if (dirtyRef.current && !window.confirm(DISCARD)) return;
    if (window.history.state?.sheet === title) window.history.back(); else onClose();
  };
  return (
    <div className="fixed inset-0 z-40 flex items-end justify-center bg-black/40 lg:items-center" onClick={close}>
      <div role="dialog" aria-modal="true" aria-label={title} onClick={(e) => e.stopPropagation()}
        className={`relative max-h-[92vh] w-full ${wide ? 'max-w-[860px]' : 'max-w-[640px]'} overflow-y-auto rounded-t-[20px] bg-[#f6f5fa] p-4 pb-8 lg:rounded-[20px]`}>
        <div className="mb-3 flex items-center justify-between gap-2 pr-10">
          <h2 className="text-[17px] font-bold text-[#1d1b2b]">{title}</h2>
        </div>
        <button type="button" aria-label="닫기" onClick={close}
          className="absolute right-3 top-3 flex h-[40px] w-[40px] items-center justify-center rounded-full bg-white text-[18px] text-[#1d1b2b]">✕</button>
        {children}
      </div>
    </div>
  );
}

export async function copyText(text: string): Promise<boolean> {
  try {
    await navigator.clipboard.writeText(text);
    return true;
  } catch {
    try {
      const ta = document.createElement('textarea');
      ta.value = text;
      ta.style.position = 'fixed';
      ta.style.opacity = '0';
      document.body.appendChild(ta);
      ta.select();
      const ok = document.execCommand('copy');
      document.body.removeChild(ta);
      return ok;
    } catch {
      return false;
    }
  }
}

export function CopyButton({ text, children = '복사', className = btnSmall }: { text: string; children?: ReactNode; className?: string }) {
  const [done, setDone] = useState<null | boolean>(null);
  return (
    <button type="button" className={className} onClick={async () => { setDone(await copyText(text)); setTimeout(() => setDone(null), 1500); }}>
      {done === true ? '복사됨 ✓' : done === false ? '복사 실패' : children}
    </button>
  );
}

export const WHO_ROLE: Record<string, string> = { admin: '운영진', tutor: '강사', student: '수강생 본인' };
