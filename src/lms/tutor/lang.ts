'use client';

// 강사 화면 언어 (2026-11-06 대표 결정, 정책 원본 H26(73) 수정판):
// - 실제 강사(해외, 한국어 안 씀)는 영어 고정 — 전환 버튼 없음
// - 운영진이 강사 화면을 볼 때(?tutor= 운영자 보기)만 한국어/English 전환, 고른 언어는 이 기기에 기억
// - 화면 라벨만 바뀜. 강사가 영어로 쓴 내용·운영진이 영어로 저장한 학생 정보는 그대로
import { createContext, useContext } from 'react';

export type Lang = 'en' | 'ko';
export const LangCtx = createContext<Lang>('en');
export const LANGS: readonly Lang[] = ['en', 'ko'];

/** t('English label', '한국어 라벨') — 영어가 기본, 한국어 글이 없으면 영어 그대로 */
export function useT(): (en: string, ko?: string) => string {
  const lang = useContext(LangCtx);
  return (en, ko) => (lang === 'ko' && ko ? ko : en);
}
export function useLang(): Lang {
  return useContext(LangCtx);
}
