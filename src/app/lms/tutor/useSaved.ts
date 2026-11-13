'use client';

// 강사가 마지막에 고른 것(메뉴·탭·KST 열 등)을 이 기기에 기억 (2026-11-04 대표: 다음에 열어도 그대로)
import { useEffect, useState } from 'react';
import { prefOf, type PrefKey, type ScreenPrefs } from '@/lms/screen-prefs';

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

/**
 * 켬/끔을 강사 계정에 저장 (대표 11/13 A안, 기본 켬). 운영자 보기는 강사가 저장한 값을 보여 주고, 운영자가 누른 것은 저장하지 않음(save = null).
 * 계정에 아직 값이 없으면 예전에 이 기기에 기억해 둔 값(legacyKey)을 한 번 옮겨 저장 (강사 본인일 때만)
 */
export function useAccountToggle(key: PrefKey, load?: () => Promise<ScreenPrefs>, save?: ((key: PrefKey, value: string) => Promise<void>) | null, legacyKey?: string): [boolean, (on: boolean) => void] {
  const [on, setOn] = useState(true);
  useEffect(() => {
    let live = true;
    load?.().then((p) => {
      if (!live) return;
      if (p[key] === '1' || p[key] === '0') return setOn(prefOf(p, key, ['1', '0'] as const, '1') === '1');
      if (!save || !legacyKey) return;
      let old: string | null = null;
      try { old = localStorage.getItem(legacyKey); } catch { /* 저장 안 되는 브라우저 */ }
      if (old === '1' || old === '0') { setOn(old === '1'); void save(key, old).catch(() => { /* 다음에 다시 */ }); }
    }).catch(() => { /* 기본: 켬 */ });
    return () => { live = false; };
  }, [key, load, save, legacyKey]);
  return [on, (v: boolean) => { setOn(v); void save?.(key, v ? '1' : '0').catch(() => { /* 저장 실패해도 화면은 그대로 */ }); }];
}
