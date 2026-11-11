import { describe, expect, it } from 'vitest';
import { afterEmailCode, enabledSocial, looksLikeEmail, maskEmail, needsSocialChoice, PASSWORD_MIN, signupProblems, STRINGS } from './login-flow';

describe('로그인 다음 단계 (POL-AC-04·05)', () => {
  it('운영자는 TOTP까지 마쳐야 관리자 화면', () => {
    expect(afterEmailCode({ role: 'admin', aal: 'aal1', verifiedTotp: 1 })).toEqual({ kind: 'totp_verify' });
    expect(afterEmailCode({ role: 'admin', aal: 'aal1', verifiedTotp: 0 })).toEqual({ kind: 'totp_enroll' });
    expect(afterEmailCode({ role: 'admin', aal: 'aal2', verifiedTotp: 1 })).toEqual({ kind: 'go', to: '/lms/admin' });
  });
  it('수강생·강사는 메일 코드만으로 각자 화면', () => {
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
    expect(maskEmail('student@gmail.com')).toBe('stu****@gmail.com');
    expect(maskEmail('chlwlsdud@naver.com')).toBe('chl******@naver.com');
    expect(maskEmail('abcd@x.kr')).toBe('abc*@x.kr');
    expect(maskEmail('ab@x.kr')).toBe('a*@x.kr');
    expect(maskEmail('a@x.kr')).toBe('*@x.kr');
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

describe('로그인 뒤 바로가기 링크로 돌아가기 (11/8 보강 바로가기)', () => {
  it('수강생: 수강생 화면 주소만, 다른 역할·다른 사이트 주소는 무시', async () => {
    const { nextAfterLogin, isMakeupLink } = await import('./login-flow');
    expect(nextAfterLogin('/lms/student?makeup=abc', '/lms/student', 'student')).toBe('/lms/student?makeup=abc');
    expect(nextAfterLogin('/lms/admin', '/lms/student', 'student')).toBe('/lms/student');
    expect(nextAfterLogin('https://evil.example/lms/student', '/lms/student', 'student')).toBe('/lms/student');
    expect(nextAfterLogin('//evil.example', '/lms/student', 'student')).toBe('/lms/student');
    expect(nextAfterLogin(null, '/lms/tutor', 'tutor')).toBe('/lms/tutor');
    expect(nextAfterLogin('/lms/student?student=s1&makeup=abc', '/lms/admin', 'admin')).toBe('/lms/student?student=s1&makeup=abc');
    expect(isMakeupLink('/lms/student?makeup=abc')).toBe(true);
    expect(isMakeupLink('/lms/student')).toBe(false);
  });
});

describe('회원가입·간편 로그인 (H26(146)(150))', () => {
  it('가입 칸 검사: 이름·이메일·비밀번호 8자·필수 동의 2개', () => {
    const ok = { name: '김하준', email: 'a@b.co', password: '12345678', terms: true, privacy: true };
    expect(signupProblems(ok)).toEqual([]);
    expect(signupProblems({ ...ok, password: '1234567' })).toEqual(['password']);
    expect(signupProblems({ ...ok, name: ' ', email: 'x', privacy: false })).toEqual(['name', 'email', 'agree']);
    expect(PASSWORD_MIN).toBe(8);
  });
  it('켜진 간편 로그인만 버튼', () => {
    expect(enabledSocial({ kakao: false, email: true })).toEqual([]);
    expect(enabledSocial({ kakao: true }, true)).toEqual(['kakao', 'naver']);
    expect(enabledSocial({ kakao: false }, true)).toEqual(['naver']);
    expect(enabledSocial(undefined)).toEqual([]);
  });
  it('처음이에요 / 이미 회원이에요 는 회원 연결 없는 카카오·네이버 전용 계정만', () => {
    expect(needsSocialChoice({ role: null, providers: ['kakao'], choseNew: false })).toBe(true);
    expect(needsSocialChoice({ role: null, providers: ['custom:naver'], choseNew: false })).toBe(true);
    // 같은 인증 이메일로 기존 계정에 자동 연결됨 → 묻지 않음
    expect(needsSocialChoice({ role: 'student', providers: ['email', 'kakao'], choseNew: false })).toBe(false);
    // 이메일로 가입한 회원(수강 전)이 카카오를 붙인 경우도 묻지 않음
    expect(needsSocialChoice({ role: null, providers: ['email', 'kakao'], choseNew: false })).toBe(false);
    expect(needsSocialChoice({ role: null, providers: ['kakao'], choseNew: true })).toBe(false);
    expect(needsSocialChoice({ role: null, providers: ['email'], choseNew: false })).toBe(false);
  });
});
