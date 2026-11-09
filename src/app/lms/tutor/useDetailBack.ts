'use client';

import { useEffect, useRef } from 'react';

/** Back closes the current detail before leaving the tutor page. */
export function useDetailBack(open: boolean, onClose: () => void, canClose: () => boolean = () => true) {
  const current = useRef({ onClose, canClose });
  current.current = { onClose, canClose };
  const token = useRef<string | null>(null);
  const after = useRef<(() => void) | undefined>(undefined);
  const closing = useRef(false);
  useEffect(() => {
    if (!open) return;
    const id = crypto.randomUUID();
    token.current = id;
    const previous = window.history.state;
    const state = { ...previous, tutorDetail: id };
    window.history.pushState(state, '');
    const pop = () => {
      if (window.history.state?.tutorDetail === id) return;
      if (!closing.current && !current.current.canClose()) { window.history.pushState(state, ''); return; }
      closing.current = false;
      current.current.onClose();
      const next = after.current;
      after.current = undefined;
      next?.();
    };
    window.addEventListener('popstate', pop);
    return () => {
      window.removeEventListener('popstate', pop);
      if (window.history.state?.tutorDetail === id) window.history.replaceState(previous, '');
      token.current = null;
    };
  }, [open]);
  return (next?: () => void) => {
    if (!current.current.canClose()) return;
    if (token.current && window.history.state?.tutorDetail === token.current) {
      after.current = next;
      closing.current = true;
      window.history.back();
    } else { current.current.onClose(); next?.(); }
  };
}
