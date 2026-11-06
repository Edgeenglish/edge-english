'use client';

// 강사가 마지막에 고른 것(메뉴·탭·KST 열 등)을 이 기기에 기억 (2026-11-04 대표: 다음에 열어도 그대로)
import { useEffect, useState } from 'react';

/** 켬/끔을 이 기기에 기억 (기본 켬) */
export function useSavedToggle(key: string): [boolean, (on: boolean) => void] {
  const [on, set] = useSavedValue<'1' | '0'>(key, '1', ['1', '0']);
  return [on === '1', (v: boolean) => set(v ? '1' : '0')];
}

/** 고른 값 하나를 이 기기에 기억. allowed 밖의 값이 저장돼 있으면 기본값 */
export function useSavedValue<T extends string>(key: string, initial: T, allowed: readonly T[]): [T, (v: T) => void] {
  const [v, setV] = useState<T>(initial);
  useEffect(() => {
    try {
      const s = localStorage.getItem(key) as T | null;
      if (s && allowed.includes(s)) setV(s);
    } catch { /* 저장 안 되는 브라우저 */ }
  }, [key]); // eslint-disable-line react-hooks/exhaustive-deps
  return [v, (x: T) => {
    setV(x);
    try { localStorage.setItem(key, x); } catch { /* 저장 안 되는 브라우저 */ }
  }];
}
