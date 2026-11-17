import { describe, expect, it } from 'vitest';
import { homeForRole } from './home';

describe('homeForRole', () => {
  it('학생은 바로 학생 홈', () => expect(homeForRole('student')).toBe('/lms/student'));
  it('강사·운영자·연결 안 된 계정은 로그인 화면이 넘김', () => {
    expect(homeForRole('tutor')).toBeNull();
    expect(homeForRole('admin')).toBeNull();
    expect(homeForRole(null)).toBeNull();
  });
});
