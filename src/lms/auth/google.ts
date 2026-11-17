import type { User } from '@supabase/supabase-js';

// 시험 프로젝트는 시험 사이트·로컬에서만, 운영 프로젝트는 운영 주소에서만 (11/17 대표 '응').
// 운영 버튼은 운영 Supabase 에서 Google 이 켜져 있을 때만 보인다 (enabledSocial).
const ALLOWED: Record<string, string[]> = {
  'https://kyeimjozkcqbgkepwrnv.supabase.co': ['edge-english-git-lms-test-support-2126.vercel.app', 'localhost', '127.0.0.1'],
  'https://mfamixejxydodclhglbc.supabase.co': ['edgeenglish.kr', 'www.edgeenglish.kr'],
};
export function googleAllowed(supabaseUrl: string | undefined, hostname: string): boolean {
  try {
    return (ALLOWED[new URL(supabaseUrl ?? '').origin] ?? []).includes(hostname);
  } catch {
    return false;
  }
}

/** 서버가 확인한 Google identity + 연결 시작 때의 영구 계정 ID가 모두 맞아야 성공. */
export function googleCallbackVerified(user: Pick<User, 'id' | 'identities'> | null, expectedUserId: string | null): boolean {
  return !!user && (!expectedUserId || user.id === expectedUserId)
    && !!user.identities?.some((identity) => identity.provider === 'google');
}

// '이미 회원이에요': 방금 간편 로그인으로 생긴 빈 계정(이메일 없음)만 지우고 기존 계정에 연결한다.
// 회원 연결(app_users)이 있는 계정은 DB 함수 lms_discard_new_social_account 가 지우지 않는다.
export function canDiscardSocialAccount(providers: string[]): boolean {
  return providers.length > 0 && !providers.includes('email');
}
