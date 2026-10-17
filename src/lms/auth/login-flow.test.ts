import { describe, expect, it } from 'vitest';
import { afterEmailCode, looksLikeEmail, maskEmail, STRINGS } from './login-flow';

describe('로그인 다음 단계 (POL-AC-04·05)', () => {
  it('운영자는 TOTP까지 마쳐야 관리자 화면', () => {
    expect(afterEmailCode({ role: 'admin', aal: 'aal1', verifiedTotp: 1 })).toEqual({ kind: 'totp_verify' });
    expect(afterEmailCode({ role: 'admin', aal: 'aal1', verifiedTotp: 0 })).toEqual({ kind: 'totp_enroll' });
    expect(afterEmailCode({ role: 'admin', aal: 'aal2', verifiedTotp: 1 })).toEqual({ kind: 'go', to: '/lms/admin' });
  });
  it('학생·강사는 메일 코드만으로 각자 화면', () => {
    expect(afterEmailCode({ role: 'student', aal: 'aal1', verifiedTotp: 0 })).toEqual({ kind: 'go', to: '/lms/student' });
    expect(afterEmailCode({ role: 'tutor', aal: 'aal1', verifiedTotp: 0 })).toEqual({ kind: 'go', to: '/lms/tutor' });
  });
  it('연결 안 된 계정은 어디로도 보내지 않음', () => {
    expect(afterEmailCode({ role: null, aal: 'aal1', verifiedTotp: 0 })).toEqual({ kind: 'not_linked' });
    expect(afterEmailCode({ role: null, aal: 'aal2', verifiedTotp: 1 })).toEqual({ kind: 'not_linked' });
  });
});

describe('이메일 표시·검사', () => {
  it('가린 이메일', () => {
    expect(maskEmail('student@gmail.com')).toBe('stu***@gmail.com');
    expect(maskEmail('ab@x.kr')).toBe('a***@x.kr');
  });
  it('형식 검사', () => {
    expect(looksLikeEmail(' a@b.co ')).toBe(true);
    expect(looksLikeEmail('a@b')).toBe(false);
  });
});

describe('한·영 문구', () => {
  it('두 언어의 문구 항목이 같음', () => {
    expect(Object.keys(STRINGS.en).sort()).toEqual(Object.keys(STRINGS.ko).sort());
  });
});
