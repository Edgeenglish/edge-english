import { describe, expect, it } from 'vitest';
import { homeForRole } from './home';

describe('homeForRole', () => {
  it('학생은 학생 홈, 강사는 강사 홈', () => {
    expect(homeForRole('student')).toBe('/lms/student');
    expect(homeForRole('tutor')).toBe('/lms/tutor');
  });
  it('운영자는 인증 앱 확인을 끝냈을 때만 운영자 화면, 아니면 로그인 화면', () => {
    expect(homeForRole('admin', true)).toBe('/lms/admin');
    expect(homeForRole('admin', false)).toBeNull();
  });
  it('연결 안 된 계정은 로그인 화면', () => expect(homeForRole(null)).toBeNull());
});
