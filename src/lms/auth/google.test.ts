import { describe, expect, it } from 'vitest';
import type { UserIdentity } from '@supabase/supabase-js';
import { canDiscardSocialAccount, googleAllowed, googleCallbackVerified } from './google';
import { afterEmailCode, enabledSocial, needsSocialChoice, STRINGS } from './login-flow';

const testUrl = 'https://kyeimjozkcqbgkepwrnv.supabase.co';
const testHost = 'edge-english-git-lms-test-support-2126.vercel.app';
const identity = (provider: string) => ({ provider } as UserIdentity);

describe('Google 공개 제한', () => {
  it('시험 DB와 고정 시험 주소가 모두 맞아야 허용', () => {
    expect(googleAllowed(testUrl, testHost)).toBe(true);
    expect(googleAllowed(testUrl, 'localhost')).toBe(true);
    expect(googleAllowed('https://mfamixejxydodclhglbc.supabase.co', testHost)).toBe(false);
    expect(googleAllowed(testUrl, 'edgeenglish.kr')).toBe(false);
    expect(googleAllowed('https://mfamixejxydodclhglbc.supabase.co', 'edgeenglish.kr')).toBe(true);
    expect(googleAllowed('https://mfamixejxydodclhglbc.supabase.co', 'www.edgeenglish.kr')).toBe(true);
    expect(googleAllowed('https://mfamixejxydodclhglbc.supabase.co', 'localhost')).toBe(false);
    expect(googleAllowed(testUrl, `${testHost}.example.com`)).toBe(false);
    expect(googleAllowed(undefined, testHost)).toBe(false);
  });
  it('백엔드만 켜져도 운영에 버튼이 나오지 않고 기존 순서는 유지', () => {
    expect(enabledSocial({ kakao: true, google: true }, true)).toEqual(['kakao', 'naver']);
    expect(enabledSocial({ kakao: true, google: true }, true, true)).toEqual(['kakao', 'naver', 'google']);
    expect(enabledSocial({ google: false }, true, true)).toEqual(['naver']);
  });
});

describe('Google 연결 후 영구 계정 보존', () => {
  const existing = { id: 'existing-account', identities: [identity('email'), identity('google')] };
  it('같은 계정에 Google identity가 붙은 경우만 연결 성공', () => {
    expect(googleCallbackVerified(existing, existing.id)).toBe(true);
    expect(googleCallbackVerified(existing, 'other-account')).toBe(false);
    expect(googleCallbackVerified({ ...existing, identities: [identity('email')] }, existing.id)).toBe(false);
    expect(googleCallbackVerified(null, existing.id)).toBe(false);
  });
  it('재로그인·신규 가입도 서버에서 확인한 Google identity가 있어야 성공', () => {
    expect(googleCallbackVerified(existing, null)).toBe(true);
    expect(googleCallbackVerified({ ...existing, identities: [] }, null)).toBe(false);
  });
  it('이메일이 붙은 계정은 빈 소셜 계정 삭제 경로 금지, 간편 로그인만 있는 새 계정은 가능', () => {
    for (const providers of [['email', 'google'], ['email', 'kakao'], []]) {
      expect(canDiscardSocialAccount(providers)).toBe(false);
    }
    expect(canDiscardSocialAccount(['google'])).toBe(true);
    expect(canDiscardSocialAccount(['kakao'])).toBe(true);
    expect(canDiscardSocialAccount(['custom:naver'])).toBe(true);
  });
  it('기존 학생·가입 전 회원·새 Google 회원을 구별', () => {
    expect(needsSocialChoice({ role: 'student', providers: ['google'], choseNew: false })).toBe(false);
    expect(needsSocialChoice({ role: null, providers: ['email', 'google'], choseNew: false })).toBe(false);
    expect(needsSocialChoice({ role: null, providers: ['google'], choseNew: false })).toBe(true);
    expect(needsSocialChoice({ role: null, providers: ['google'], choseNew: true })).toBe(false);
  });
  it('Google 로그인도 운영자의 MFA를 우회하지 않음', () => {
    expect(afterEmailCode({ role: 'admin', aal: 'aal1', verifiedTotp: 1 })).toEqual({ kind: 'totp_verify' });
    expect(afterEmailCode({ role: 'student', aal: 'aal1', verifiedTotp: 0 })).toEqual({ kind: 'go', to: '/lms/student' });
  });
  it('로그인·회원가입에 한국어와 영어 Google 문구 제공', () => {
    expect(STRINGS.ko.social.google).toContain('Google');
    expect(STRINGS.en.social.google).toContain('Google');
  });
});
