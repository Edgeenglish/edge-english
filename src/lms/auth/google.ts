import type { User } from '@supabase/supabase-js';

// QA 전 운영 노출 금지. 운영 공개는 별도 승인 후 이 허용 범위를 변경한다.
export function googleAllowed(supabaseUrl: string | undefined, hostname: string): boolean {
  try {
    return new URL(supabaseUrl ?? '').origin === 'https://kyeimjozkcqbgkepwrnv.supabase.co'
      && ['edge-english-git-lms-test-support-2126.vercel.app', 'localhost', '127.0.0.1'].includes(hostname);
  } catch {
    return false;
  }
}

/** 서버가 확인한 Google identity + 연결 시작 때의 영구 계정 ID가 모두 맞아야 성공. */
export function googleCallbackVerified(user: Pick<User, 'id' | 'identities'> | null, expectedUserId: string | null): boolean {
  return !!user && (!expectedUserId || user.id === expectedUserId)
    && !!user.identities?.some((identity) => identity.provider === 'google');
}

// Google 계정은 기존 '빈 소셜 계정 삭제 후 연결' 경로를 절대 타지 않는다.
export function canDiscardSocialAccount(providers: string[]): boolean {
  return providers.length > 0 && !providers.includes('google') && !providers.includes('email');
}
